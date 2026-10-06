// =============================================================================
// vec_ingress_arb.sv — Dual-Input Ingress Arbitrator (Vector Unit, v2)
//
// Arbitrates between two capsule sources and validates incoming data
// against the current operation's contract requirements before pushing
// to the operand queue.
//
// v2 changes from v1:
//   - operand_role transparency: the operand_role field in bs_capsule_t is
//     passed through unmodified in out_cap_o. The arbiter does NOT check or
//     consume operand_role — dispatch to src0/src1 latch is handled by the
//     vector_unit FSM based on capsule.operand_role after queue pop.
//   - Layout check comment updated: sentinel 0xF rejection retained.
//
// Two input sources:
//   Source A: SRAM resident path — capsule assembled from L2 data + sidecar
//   Source B: Tensor/Vector fast path — capsule forwarded directly
//
// Validation checks (applied to whichever source is selected):
//   1. block_size ∈ {16, 32}
//   2. scale_format ∈ {E8M0, E4M3}
//   3. scale_epoch matches expected value (from ctrl)
//   4. layout_tag is consumable by the current primitive
//   5. fwd_eligible == 1 (fast path source only)
//   6. multi_consumer == 0 (fast path source only)
//
// NOT checked here (handled by vector_unit FSM):
//   - operand_role: dispatch to src0/src1 is a consumer-side decision
//
// On validation failure:
//   - Miss reason is reported via miss_reason_o
//   - Capsule is NOT pushed to operand queue
//   - No implicit high-precision materialization
//   - PE residency/path-select layer handles fallback
//
// Priority: fast path > resident (configurable via parameter).
//   Rationale: fast path capsules are transient and have no storage backing;
//   dropping them is more costly than delaying a resident fetch.
//
// Author:  H-Tensor Project
// Version: 2.0 (R8 — operand_role transparent passthrough)
// =============================================================================

module vec_ingress_arb
    import pe_pkg::*;
    import vec_pkg::*;
#(
    // Priority: 1 = fast path preferred, 0 = resident preferred
    parameter bit FAST_PATH_PRIORITY = 1'b1
) (
    input  logic            clk_i,
    input  logic            rst_ni,

    // ── Source A: SRAM Resident Path ──
    input  logic            resident_valid_i,
    output logic            resident_ready_o,
    input  bs_capsule_t     resident_cap_i,

    // ── Source B: Fast Path (from Tensor or another Vector) ──
    input  logic            fpath_valid_i,
    output logic            fpath_ready_o,
    input  bs_capsule_t     fpath_cap_i,

    // ── Current Operation Context (from vec_desc_decode) ──
    input  vec_ctrl_t       ctrl_i,
    input  logic            ctrl_valid_i,       // a descriptor is active

    // ── Output: to operand queue ──
    output logic            out_valid_o,
    input  logic            out_ready_i,
    output bs_capsule_t     out_cap_o,

    // ── Miss / Error Reporting ──
    output logic            miss_valid_o,       // a capsule was rejected
    output fp_miss_reason_e miss_reason_o,      // why it was rejected
    output logic            miss_from_fpath_o   // was the rejected capsule from fast path?
);

    // =========================================================================
    // Per-source validation
    //
    // Each source is independently checked against the current operation's
    // contract requirements. The checks are purely combinational.
    // =========================================================================
    fp_miss_reason_e resident_miss, fpath_miss;
    logic            resident_ok,   fpath_ok;

    // ── Capsule contract checker (reusable for both sources) ──
    //
    // CL-2 fix: changed from "format legality" to "precise contract match".
    // The original v2 checked is_valid_block_size(cap.block_size) which only
    // verifies "is it 16 or 32?", not "does it match the current descriptor?".
    // A block_size=16 capsule arriving for a block_size=32 operation is a
    // CONTRACT MISMATCH, not just a format error.
    //
    // This fix strengthens the triad check to:
    //   block_size:    must EXACTLY match ctrl.block_size
    //   scale_format:  must EXACTLY match ctrl.scale_format
    //   scale_epoch:   must EXACTLY match ctrl.scale_epoch (unchanged)
    //
    function automatic fp_miss_reason_e check_capsule(
        input bs_capsule_t  cap,
        input vec_ctrl_t    ctrl,
        input logic         is_fpath   // fast-path-specific checks
    );
        // Check order matches priority: first failure wins.

        // 1. Block size — PRECISE MATCH against current descriptor (CL-2 fix)
        //    Old: is_valid_block_size(cap.block_size) — only checks {16,32}
        //    New: cap.block_size == ctrl.block_size — checks exact match
        if (cap.block_size != ctrl.block_size)
            return MISS_BLOCK_SIZE;

        // 2. Scale format — PRECISE MATCH against current descriptor (CL-2 fix)
        //    Old: is_valid_scale_format(cap.scale_format) — only checks {E8M0,E4M3}
        //    New: cap.scale_format == ctrl.scale_format — checks exact match
        if (cap.scale_format != ctrl.scale_format)
            return MISS_SCALE_FORMAT;

        // 3. Scale epoch consistency — already precise in v2 (unchanged)
        if (cap.scale_epoch != ctrl.scale_epoch)
            return MISS_EPOCH;

        // 4. Layout compatibility
        if (cap.layout_tag == 4'hF)   // 0xF = reserved/invalid
            return MISS_LAYOUT;

        // 5. Fast-path-specific: forwarding eligibility
        if (is_fpath && !cap.fwd_eligible)
            return MISS_NOFWD;

        // 6. Fast-path-specific: multi-consumer conflict
        if (is_fpath && cap.multi_consumer)
            return MISS_MULTI_CONSUMER;

        return MISS_NONE;
    endfunction

    always_comb begin
        resident_miss = MISS_NONE;
        resident_ok   = 1'b0;
        fpath_miss    = MISS_NONE;
        fpath_ok      = 1'b0;

        if (ctrl_valid_i) begin
            if (resident_valid_i) begin
                resident_miss = check_capsule(resident_cap_i, ctrl_i, 1'b0);
                resident_ok   = (resident_miss == MISS_NONE);
            end
            if (fpath_valid_i) begin
                fpath_miss = check_capsule(fpath_cap_i, ctrl_i, 1'b1);
                fpath_ok   = (fpath_miss == MISS_NONE);
            end
        end
    end

    // =========================================================================
    // Arbitration: select between validated sources
    //
    // Priority logic:
    //   If both sources are valid and pass checks, priority parameter decides.
    //   If only one passes, it wins regardless of priority.
    //   If neither passes, no output.
    //
    // Ready backpressure:
    //   The winning source gets ready when out_ready_i is asserted.
    //   The losing source (or a failed source) does NOT get ready —
    //   it retries next cycle or the PE decides to redirect.
    // =========================================================================
    logic            sel_fpath;       // 1 = select fast path, 0 = select resident
    logic            sel_valid;       // selected source has valid data
    bs_capsule_t     sel_cap;

    always_comb begin
        sel_fpath = 1'b0;
        sel_valid = 1'b0;
        sel_cap   = '0;

        if (fpath_ok && resident_ok) begin
            // Both valid: use priority
            sel_fpath = FAST_PATH_PRIORITY;
            sel_valid = 1'b1;
            sel_cap   = FAST_PATH_PRIORITY ? fpath_cap_i : resident_cap_i;
        end else if (fpath_ok) begin
            sel_fpath = 1'b1;
            sel_valid = 1'b1;
            sel_cap   = fpath_cap_i;
        end else if (resident_ok) begin
            sel_fpath = 1'b0;
            sel_valid = 1'b1;
            sel_cap   = resident_cap_i;
        end
    end

    // =========================================================================
    // Output handshake
    // =========================================================================
    assign out_valid_o = sel_valid;
    assign out_cap_o   = sel_cap;

    // Ready signals: only the selected & valid source gets ready
    assign fpath_ready_o    = sel_valid && sel_fpath && out_ready_i;
    assign resident_ready_o = sel_valid && !sel_fpath && out_ready_i;

    // =========================================================================
    // Miss reporting
    //
    // Report a miss when a source presents a valid capsule that fails checks.
    // Priority: report fast path miss first (since it's more urgent — the
    // capsule may be lost if not consumed).
    //
    // The miss is reported as a 1-cycle combinational pulse. The PE layer
    // captures it for path-select decisions and counter increments.
    // =========================================================================
    always_comb begin
        miss_valid_o     = 1'b0;
        miss_reason_o    = MISS_NONE;
        miss_from_fpath_o = 1'b0;

        if (ctrl_valid_i) begin
            if (fpath_valid_i && !fpath_ok) begin
                // Fast path capsule rejected
                miss_valid_o      = 1'b1;
                miss_reason_o     = fpath_miss;
                miss_from_fpath_o = 1'b1;
            end else if (resident_valid_i && !resident_ok) begin
                // Resident capsule rejected
                miss_valid_o      = 1'b1;
                miss_reason_o     = resident_miss;
                miss_from_fpath_o = 1'b0;
            end
        end
    end

endmodule

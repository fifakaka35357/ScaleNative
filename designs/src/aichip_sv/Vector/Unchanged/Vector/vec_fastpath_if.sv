// =============================================================================
// vec_fastpath_if.sv — Vector-Side Fast Path Endpoint (Vector Unit, v2)
//
// Encapsulates the Tensor↔Vector fast path ingress and egress protocol
// from the Vector Unit's perspective. This module is a protocol wrapper,
// NOT a data transform — it handles handshake, validation, and routing
// but does not modify capsule contents.
//
// v2 note:
//   bs_capsule_t now includes operand_role. This field is fully transparent
//   to fastpath_if — it flows through ingress and egress unmodified.
//   No logic changes were required.
//
// Two independent sub-interfaces:
//
//   INGRESS (Tensor/other → Vector):
//     Receives capsules from the PE fast path fabric, performs legality
//     checks, and presents accepted capsules to vec_ingress_arb.
//     Rejected capsules generate miss_reason for PE fallback.
//
//   EGRESS (Vector → Tensor/other):
//     Receives result capsules from vec_result_packer, checks forwarding
//     eligibility, and presents to the PE fast path fabric.
//     If the target is not ready or conditions aren't met, the capsule
//     is returned to the Vector Unit for keep-local / writeback.
//
// ─────────────────────────────────────────────────────────────────────
// TENSOR UNIT INTEGRATION NOTES (for future tensor_fastpath_if.sv):
//
//   The Tensor-side endpoint must implement the mirror of this interface:
//
//   Tensor EGRESS → Vector INGRESS:
//     tensor_fastpath_if drives:
//       t2v_valid_o, t2v_cap_o     (capsule from Tensor result packer)
//     vec_fastpath_if drives:
//       t2v_ready_o                (backpressure from Vector ingress)
//       t2v_miss_valid_o           (capsule rejected)
//       t2v_miss_reason_o          (why rejected)
//
//   Vector EGRESS → Tensor INGRESS:
//     vec_fastpath_if drives:
//       v2t_valid_o, v2t_cap_o     (capsule from Vector result packer)
//     tensor_fastpath_if drives:
//       v2t_ready_i                (backpressure from Tensor ingress)
//       v2t_miss_valid_i           (capsule rejected by Tensor)
//       v2t_miss_reason_i          (why rejected)
//
//   PE-level fast path fabric (tv_fastpath_fabric.sv) sits between
//   the two endpoints and handles:
//     - Cross-clock-domain if needed (same domain in current PE, no CDC)
//     - Per-hop epoch/block_size/scale_format checking (optional)
//     - Flush / replay coordination
//     - Backpressure propagation
//     - Miss reason aggregation for PE counters
//
//   For testing without Tensor Unit, a lightweight capsule
//   stimulus/sink stub can drive the t2v_*/v2t_* ports directly.
//
//   Signal naming convention:
//     t2v_ = Tensor-to-Vector direction
//     v2t_ = Vector-to-Tensor direction
//     _i   = input to this module
//     _o   = output from this module
// ─────────────────────────────────────────────────────────────────────
//
// Author:  H-Tensor Project
// Version: 2.0 (R8 — operand_role transparent, header update)
// =============================================================================

module vec_fastpath_if
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic            clk_i,
    input  logic            rst_ni,

    // =========================================================================
    // Tensor → Vector (INGRESS)
    //
    // External ports: connected to PE fast path fabric or Tensor stub.
    // These carry capsules FROM the Tensor Unit (or another producer)
    // TO the Vector Unit for processing.
    // =========================================================================

    // ── External: from PE fabric / Tensor ──
    input  logic            t2v_valid_i,        // capsule available
    output logic            t2v_ready_o,        // Vector can accept
    input  bs_capsule_t     t2v_cap_i,          // capsule data

    // ── External: miss feedback to PE fabric ──
    output logic            t2v_miss_valid_o,   // capsule rejected
    output fp_miss_reason_e t2v_miss_reason_o,  // rejection reason

    // ── Internal: to vec_ingress_arb fast path input ──
    output logic            ing_valid_o,        // validated capsule ready
    input  logic            ing_ready_i,        // ingress arb can accept
    output bs_capsule_t     ing_cap_o,          // capsule to arb

    // ── Ingress control ──
    input  logic            vec_busy_i,         // Vector Unit pipeline active
    input  logic            queue_full_i,       // operand queue is full

    // =========================================================================
    // Vector → Tensor (EGRESS)
    //
    // External ports: connected to PE fast path fabric or Tensor stub.
    // These carry result capsules FROM the Vector Unit TO the next consumer.
    // =========================================================================

    // ── External: to PE fabric / Tensor ──
    output logic            v2t_valid_o,        // result capsule available
    input  logic            v2t_ready_i,        // target can accept
    output bs_capsule_t     v2t_cap_o,          // capsule data

    // ── External: miss feedback from PE fabric (target rejected) ──
    input  logic            v2t_miss_valid_i,   // target rejected our capsule
    input  fp_miss_reason_e v2t_miss_reason_i,  // why target rejected

    // ── Internal: from vec_result_packer ──
    input  logic            egr_valid_i,        // result capsule ready
    output logic            egr_ready_o,        // fast path can accept
    input  bs_capsule_t     egr_cap_i,          // result capsule

    // ── Egress result feedback to vector_unit ──
    output logic            egr_accepted_o,     // capsule was taken by target
    output logic            egr_rejected_o,     // capsule was rejected (keep-local)
    output fp_miss_reason_e egr_reject_reason_o // why (from target miss feedback)
);

    // =========================================================================
    // ─── INGRESS PATH ────────────────────────────────────────────────────────
    //
    // Validation is lightweight here because vec_ingress_arb does the full
    // contract check (epoch, block_size, scale_format, layout, etc.).
    // This module only checks conditions that should prevent the capsule
    // from even reaching the arbiter:
    //   1. Vector Unit is busy and queue is full → MISS_BUSY
    //   2. Capsule forwarding not eligible → MISS_NOFWD
    //
    // All other semantic checks are deferred to vec_ingress_arb where the
    // current operation context (vec_ctrl_t) is available.
    // =========================================================================

    logic ing_pre_ok;
    fp_miss_reason_e ing_pre_miss;

    always_comb begin
        ing_pre_ok   = 1'b1;
        ing_pre_miss = MISS_NONE;

        if (t2v_valid_i) begin
            // Check 1: Queue capacity
            if (queue_full_i) begin
                ing_pre_ok   = 1'b0;
                ing_pre_miss = MISS_BUSY;
            end
            // Check 2: Forwarding eligibility
            else if (!t2v_cap_i.fwd_eligible) begin
                ing_pre_ok   = 1'b0;
                ing_pre_miss = MISS_NOFWD;
            end
        end
    end

    // ── Ingress output ──
    // Pass to arbiter if pre-checks pass; backpressure from arbiter
    assign ing_valid_o = t2v_valid_i && ing_pre_ok;
    assign ing_cap_o   = t2v_cap_i;

    // Ready: accept when pre-ok AND downstream (arbiter) is ready
    assign t2v_ready_o = ing_pre_ok && ing_ready_i;

    // ── Miss reporting ──
    // Report miss when a valid capsule is rejected at this stage.
    // Note: additional misses from vec_ingress_arb are reported separately
    // through vec_ingress_arb.miss_* ports — the PE aggregates both.
    assign t2v_miss_valid_o  = t2v_valid_i && !ing_pre_ok;
    assign t2v_miss_reason_o = ing_pre_miss;

    // =========================================================================
    // ─── EGRESS PATH ─────────────────────────────────────────────────────────
    //
    // Eligibility checking before presenting to fast path fabric:
    //   1. fwd_eligible must be set in the result capsule
    //   2. multi_consumer must be 0 (exclusive forwarding only)
    //   3. dest_hint should indicate Tensor or Vector (not SRAM/NoC)
    //
    // If any condition fails, the capsule is NOT presented to the fabric.
    // Instead, egr_rejected_o is asserted so vector_unit routes it to
    // keep-local or writeback.
    //
    // If the fabric accepts and then the target rejects (v2t_miss_valid_i),
    // the rejection is reported back so vector_unit can handle fallback.
    // =========================================================================

    logic egr_eligible;

    always_comb begin
        egr_eligible = 1'b0;

        if (egr_valid_i) begin
            egr_eligible = egr_cap_i.fwd_eligible
                        && !egr_cap_i.multi_consumer
                        && (egr_cap_i.dest_hint inside {DEST_TENSOR, DEST_VECTOR});
        end
    end

    // ── Egress output ──
    assign v2t_valid_o = egr_valid_i && egr_eligible;
    assign v2t_cap_o   = egr_cap_i;

    // Ready: accept from result packer when eligible AND fabric ready,
    // OR when not eligible (capsule will be rejected immediately, freeing pipe).
    assign egr_ready_o = egr_eligible ? v2t_ready_i : 1'b1;

    // ── Egress result feedback ──
    // accepted: capsule was presented and target consumed it this cycle
    assign egr_accepted_o = v2t_valid_o && v2t_ready_i && !v2t_miss_valid_i;

    // rejected: either not eligible locally, or target miss
    always_comb begin
        egr_rejected_o     = 1'b0;
        egr_reject_reason_o = MISS_NONE;

        if (egr_valid_i) begin
            if (!egr_eligible) begin
                // Local eligibility failure
                egr_rejected_o = 1'b1;
                if (!egr_cap_i.fwd_eligible)
                    egr_reject_reason_o = MISS_NOFWD;
                else if (egr_cap_i.multi_consumer)
                    egr_reject_reason_o = MISS_MULTI_CONSUMER;
                else
                    egr_reject_reason_o = MISS_POLICY_ESCAPE;
            end else if (v2t_miss_valid_i) begin
                // Target rejected our capsule
                egr_rejected_o      = 1'b1;
                egr_reject_reason_o = v2t_miss_reason_i;
            end
        end
    end

    // =========================================================================
    // Debug / Observability (simulation only)
    // =========================================================================
`ifndef SYNTHESIS
    // Log ingress misses
    always_comb begin
        if (t2v_valid_i && !ing_pre_ok)
            $info("[vec_fastpath_if] Ingress miss: reason=%s",
                  ing_pre_miss.name());
    end

    // Log egress rejections
    always_comb begin
        if (egr_valid_i && egr_rejected_o)
            $info("[vec_fastpath_if] Egress rejected: reason=%s",
                  egr_reject_reason_o.name());
    end
`endif

endmodule

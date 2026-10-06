// =============================================================================
// vec_operand_queue.sv — Operand Capsule Queue (Vector Unit)
//
// Small register-based FIFO (depth = VEC_OQ_DEPTH, default 6) that buffers
// capsules between the ingress arbiter and the datapath pipeline.
//
// v6.0 Round 2 changes (structural simplification):
//   - REMOVED zero-latency combinational bypass path.
//     Pre-v6 code allowed push_cap_i to pass straight through to pop_cap_o
//     in the same cycle when FIFO was empty AND pop_ready_i was asserted.
//     This created a latent combinational-loop risk because pop_ready_i in
//     vector_unit.sv is derived from role_match (which inspects pop_cap_o),
//     forming the chain:
//        push_cap_i -> pop_cap_o (via bypass) -> role_match -> pop_ready_i
//                                                               -> bypass_active
//                                                               -> pop_cap_o
//     Whether this loop is flagged or silently broken depends on the
//     synthesis tool's heuristics — unacceptable for any production path.
//   - Behavior change: push-to-empty now incurs 1-cycle latency
//     (push at cycle N → pop_valid_o asserted at cycle N+1). This is an
//     intentional and accepted trade-off at the Vector Unit level; see
//     v6.0 planning notes. Multi-cycle throughput is unaffected.
//   - No change to port interface, depth, or flush semantics.
//
// Historical changes (retained for traceability):
//   v2 from v1:
//     - VEC_OQ_DEPTH: 4 → 6 (margin for block_size=32 dual-op 4-capsule burst)
//     - Removed dead signals (do_push, do_pop, bypass) — only do_push_eff,
//       do_pop_eff, bypass_active were used by sequential and output logic.
//     - Capsule carries operand_role field (transparent to queue).
//       The queue stores complete bs_capsule_t including operand_role.
//       vector_unit reads capsule.operand_role after pop for latch dispatch.
//
// Purpose:
//   - Isolate fast path backpressure from pipeline timing
//   - Absorb resident fetch latency variation
//   - Buffer capsules for multi-capsule operand collection (block_size=32)
//   - Support flush on soft_reset or error recovery
//
// Architecture (v6.0):
//   Standard 1-cycle circular FIFO with wr_ptr / rd_ptr and valid count.
//   All push-to-pop traffic incurs ≥1 cycle of storage latency.
//   Output is always driven from mem[rd_ptr_q] when !empty.
//
// Flush behavior:
//   flush_i resets wr_ptr, rd_ptr, and count to 0 on next clock edge.
//   Data in registers becomes stale but unreachable (valid = 0).
//   Used on soft_reset and error recovery.
//
// Author:  H-Tensor Project
// Version: 6.0 (Round 2 — zero-latency bypass removed, standard 1-cycle FIFO)
// =============================================================================

module vec_operand_queue
    import pe_pkg::*;
    import vec_pkg::*;
#(
    parameter int DEPTH = VEC_OQ_DEPTH   // default 6 (v2)
) (
    input  logic            clk_i,
    input  logic            rst_ni,
    input  logic            flush_i,      // synchronous flush (soft_reset / error)

    // ── Push interface (from vec_ingress_arb) ──
    input  logic            push_valid_i,
    output logic            push_ready_o,
    input  bs_capsule_t     push_cap_i,

    // ── Pop interface (to datapath pipeline) ──
    output logic            pop_valid_o,
    input  logic            pop_ready_i,
    output bs_capsule_t     pop_cap_o,

    // ── Status ──
    output logic [$clog2(DEPTH):0] count_o,   // number of entries (0..DEPTH)
    output logic                   full_o,
    output logic                   empty_o
);

    // =========================================================================
    // Pointer and count registers
    // =========================================================================
    localparam int PTR_W = $clog2(DEPTH);

    logic [PTR_W-1:0] wr_ptr_q, rd_ptr_q;
    logic [PTR_W:0]   count_q;

    // =========================================================================
    // Storage
    // =========================================================================
    bs_capsule_t mem [DEPTH];

    // =========================================================================
    // Status signals
    // =========================================================================
    logic fifo_full;
    logic fifo_empty;

    assign fifo_full  = (count_q == (PTR_W+1)'(DEPTH));
    assign fifo_empty = (count_q == '0);

    assign full_o  = fifo_full;
    assign empty_o = fifo_empty;
    assign count_o = count_q;

    // =========================================================================
    // Push / Pop handshake
    //
    // push_ready: can accept if not full
    // pop_valid:  has data if not empty (standard 1-cycle FIFO semantics)
    //
    // v6.0 Round 2: removed combinational bypass that previously allowed
    // push_cap_i to skip FIFO storage when empty+pop_ready. See file header
    // for the combinational-loop rationale behind the removal.
    // =========================================================================
    assign push_ready_o = !fifo_full;

    // Effective push: enqueue to FIFO whenever push is valid and not full.
    //   (No more "not bypassed" carve-out — bypass path has been removed.)
    logic do_push_eff;
    assign do_push_eff = push_valid_i && !fifo_full;

    // Effective pop: dequeue from FIFO (only when FIFO has entries).
    //   Unchanged from pre-v6 — this was always the correct expression for
    //   FIFO-backed pop; it's only the bypass arm that went away.
    logic do_pop_eff;
    assign do_pop_eff = !fifo_empty && pop_ready_i;

    // =========================================================================
    // Output MUX
    //
    // Standard FIFO read: output from mem[rd_ptr_q] when not empty; otherwise
    // quiesce (valid=0, capsule=0).
    //
    // v6.0 Round 2: the pre-v6 bypass branch (outputting push_cap_i directly
    // when empty) has been removed.
    // =========================================================================
    always_comb begin
        if (!fifo_empty) begin
            pop_valid_o = 1'b1;
            pop_cap_o   = mem[rd_ptr_q];
        end else begin
            pop_valid_o = 1'b0;
            pop_cap_o   = '0;
        end
    end

    // =========================================================================
    // Sequential Logic: FIFO state update
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        // [STEP5 slang] async reset (rst_ni) split from synchronous flush — the
        // yosys-slang synth frontend rejects ORing flush_i (no edge in the
        // sensitivity list) into the async-reset `if`. Behavior is identical:
        // flush_i was already synchronous. Both branches must stay in sync.
        if (!rst_ni) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            count_q  <= '0;
        end else if (flush_i) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            count_q  <= '0;
        end else begin
            // Write: push to FIFO when push is valid and not full
            if (do_push_eff) begin
                mem[wr_ptr_q] <= push_cap_i;
                wr_ptr_q      <= (wr_ptr_q == PTR_W'(DEPTH - 1)) ? '0 : wr_ptr_q + PTR_W'(1);
            end

            // Read: pop from FIFO
            if (do_pop_eff) begin
                rd_ptr_q <= (rd_ptr_q == PTR_W'(DEPTH - 1)) ? '0 : rd_ptr_q + PTR_W'(1);
            end

            // Count update
            case ({do_push_eff, do_pop_eff})
                2'b10:   count_q <= count_q + (PTR_W+1)'(1);
                2'b01:   count_q <= count_q - (PTR_W+1)'(1);
                default: ; // 2'b00 or 2'b11: count unchanged
            endcase
        end
    end

    // =========================================================================
    // Assertions (simulation only)
    // =========================================================================
`ifndef SYNTHESIS
    // FIFO should never overflow
    always_ff @(posedge clk_i) begin
        if (rst_ni && !flush_i) begin
            if (push_valid_i && fifo_full && !do_pop_eff)
                $error("[vec_operand_queue] Push while full — capsule lost!");
            if (count_q > (PTR_W+1)'(DEPTH))
                $error("[vec_operand_queue] Count exceeded DEPTH — pointer corruption!");
        end
    end
`endif

endmodule

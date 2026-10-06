// =============================================================================
// cp_completion.sv — Completion Event Router (PE v4, D4: done_tag pass-through)
//
// Routes execution unit done signals (+ ctx_id + tag) AND NOP/BARRIER immediate
// done signals into per-context events:
//   comp_done[i]  — ctx i's operation completed (any source)
//   comp_chain[i] — ctx i's desc_current had CHAIN_NEXT=1
//   irq_set[i]    — ctx i's desc_current had IRQ_ON_DONE=1
//
// Also produces per-ctx done vectors for the scheduler:
//   done_vec[i], done_tens[i], done_dma[i] — which unit completed for ctx i
//
// D4/R7.1: done_tag pass-through — exec units return the tag allocated at
//   issue time. Scheduler uses this for direct tag dealloc (no reverse lookup).
//   Tags are per-unit (not per-ctx), so they pass through without demux.
//
// All outputs are combinational (1-cycle pulses matching the done inputs).
// =============================================================================

module cp_completion
    import pe_pkg::*;
(
    // ── Execution Unit Done Signals ──
    input  logic              vec_done_i,
    input  logic [1:0]        vec_done_ctx_i,
    input  logic [TAG_W-1:0]  vec_done_tag_i,     // D4: tag return
    input  logic              tens_done_i,
    input  logic [1:0]        tens_done_ctx_i,
    input  logic [TAG_W-1:0]  tens_done_tag_i,    // D4: tag return
    input  logic              dma_done_i,
    input  logic [1:0]        dma_done_ctx_i,
    input  logic [TAG_W-1:0]  dma_done_tag_i,     // D4: tag return

    // ── NOP/BARRIER Immediate Done (from scheduler) ──
    //    These descriptors complete instantly at issue time.
    //    Routed here so their CHAIN_NEXT/IRQ flags are processed.
    input  logic [NUM_CTX-1:0] nop_done_i,

    // ── Descriptor Flags (from desc_current word 0 per ctx) ──
    //    Used to check CHAIN_NEXT and IRQ_ON_DONE.
    //    At done time, slot_current still holds the inflight descriptor
    //    (promotion happens on the next clock edge, driven by comp_done).
    input  logic [31:0] current_word0_i [NUM_CTX],

    // ── Per-Ctx Completion Events (to command_processor slot FSM) ──
    output logic [NUM_CTX-1:0] comp_done_o,
    output logic [NUM_CTX-1:0] comp_chain_o,

    // ── Per-Ctx Done Vectors (to scheduler state machine) ──
    output logic [NUM_CTX-1:0] done_vec_o,
    output logic [NUM_CTX-1:0] done_tens_o,
    output logic [NUM_CTX-1:0] done_dma_o,

    // ── D4: Per-Unit Done Tags (to scheduler for tag dealloc) ──
    //    Pass-through from exec units. Valid when |done_*_o is asserted.
    output logic [TAG_W-1:0]   done_vec_tag_o,
    output logic [TAG_W-1:0]   done_tens_tag_o,
    output logic [TAG_W-1:0]   done_dma_tag_o,

    // ── IRQ Set Pulses (to cp_csr) ──
    output logic [NUM_CTX-1:0] irq_set_o
);

    // =========================================================================
    // Decode Flags from desc_current header (word 0)
    // =========================================================================
    desc_flags_t flags [NUM_CTX];

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            automatic desc_header_t h = get_header(current_word0_i[i]);
            flags[i] = h.flags;
        end
    end

    // =========================================================================
    // Done Demux: unit done + ctx_id → per-ctx one-hot
    // D4: Tags pass through unmodified (per-unit, not per-ctx).
    // =========================================================================
    assign done_vec_tag_o  = vec_done_tag_i;
    assign done_tens_tag_o = tens_done_tag_i;
    assign done_dma_tag_o  = dma_done_tag_i;

    always_comb begin
        done_vec_o  = '0;
        done_tens_o = '0;
        done_dma_o  = '0;

        if (vec_done_i)  done_vec_o[vec_done_ctx_i]   = 1'b1;
        if (tens_done_i) done_tens_o[tens_done_ctx_i]  = 1'b1;
        if (dma_done_i)  done_dma_o[dma_done_ctx_i]    = 1'b1;
    end

    // =========================================================================
    // Completion Events
    //
    // comp_done[i]:  any unit completed for ctx i (exec units OR NOP/BARRIER)
    // comp_chain[i]: comp_done[i] AND flags.chain_next
    // irq_set[i]:    comp_done[i] AND flags.irq_on_done
    //
    // Note: At the time comp_done fires, slot_current still holds the
    // inflight descriptor because this module is combinational and the
    // slot update is sequential. So flags are read from the correct
    // descriptor — this is the core P6 fix.
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            comp_done_o[i]  = done_vec_o[i] | done_tens_o[i] | done_dma_o[i]
                            | nop_done_i[i];
            comp_chain_o[i] = comp_done_o[i] & flags[i].chain_next;
            irq_set_o[i]    = comp_done_o[i] & flags[i].irq_on_done;
        end
    end

endmodule

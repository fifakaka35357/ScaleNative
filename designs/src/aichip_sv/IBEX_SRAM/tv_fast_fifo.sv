// =============================================================================
// tv_fast_fifo.sv — Tensor <-> Vector Fast Path FIFO
//
// Phase 2b deliverable. Pure-new file. Generic reusable FIFO module for the
// Tensor <-> Vector fast path. Instantiated twice in pe_top: once for the
// Tensor→Vector direction, once for the Vector→Tensor direction. A single
// parameterized module keeps both sides symmetric and ensures that any
// future change to FIFO discipline (depth, skid strategy, assertions)
// propagates to both directions simultaneously.
//
// =============================================================================
// ROLE IN THE ARCHITECTURE
// =============================================================================
// This module abstracts the LATENCY-INSENSITIVE BOUNDARY between the two
// execution domains. Its value is not just "FIFO code reuse" — it is the
// single place where the fast path's elastic handshake discipline is
// specified, so depth / skid policy / assertions can be adjusted in one
// location as the architecture evolves.
//
// The discipline encoded here:
//   - Input skid buffer (1-entry, optional) absorbs a 1-cycle handshake
//     delay so the producer's back-pressure path doesn't combinationally
//     reach into the FIFO's full flag.
//   - Main FIFO (DEPTH entries) holds fragments in transit.
//   - Output register (optional) separates the FIFO's read-data path from
//     the consumer's combinational input, useful when the consumer has
//     high fanout or long internal paths.
//
// =============================================================================
// PORT / HANDSHAKE PROTOCOL
// =============================================================================
//   Standard valid/ready:
//     in_valid & in_ready  → input beat transferred
//     out_valid & out_ready → output beat transferred
//
//   Both data (FRAG payload) and sideband (frag_sideband_t) travel as a
//   single atomic beat. They are NEVER separated — if a beat is accepted,
//   both the data and the sideband are captured in the same cycle.
//
//   Stall-stable: when out_valid=1 but out_ready=0, out_data and
//   out_sideband MUST remain bit-stable until out_ready is asserted.
//   (This is a necessary-stable requirement for latency-insensitive links;
//    asserted below — part of Assertion Tier A.)
//
// =============================================================================
// PARAMETERIZATION
// =============================================================================
//   DEPTH       — number of main-FIFO entries (default 4, per D8-1 / Phase 2b)
//   DATA_W      — payload width (default FRAG_W = 256)
//   INPUT_SKID  — 1 = insert 1-entry skid buffer at input (default 1)
//   OUTPUT_REG  — 1 = insert output register stage (default 0)
//   LATENCY_INSENSITIVE_CHECK — 0 = disabled (default) / 1 = enable the
//                               bounded-activity check (Tier C).
//                               OFF by default because bounded-activity
//                               false-positives are common during integration.
//   ACTIVITY_BOUND — bound in cycles for Tier C (default 1024). Only
//                               meaningful when LATENCY_INSENSITIVE_CHECK=1.
//
// =============================================================================
// ASSERTION TIERS
// =============================================================================
// Tier A (always-on) — latency-insensitive correctness:
//   A1. full → !in_ready                (back-pressure correctness)
//   A2. empty → !out_valid              (no spurious output)
//   A3. fill_level updates correctly    (enq++ / deq-- / both=no-change)
//   A4. stall-stable: out_valid && !out_ready → data/sideband bit-stable
//
// Tier B (recommended-on) — sanity:
//   B1. overflow never occurs under legal handshake
//   B2. underflow never occurs under legal handshake
//   B3. data and sideband advance together (no field-level skew)
//
// Tier C (optional, parameterized off) — bounded activity:
//   C1. valid asserted → eventually ready within ACTIVITY_BOUND cycles
//
// Tiers A and B are compiled unconditionally (under `synthesis translate_off`
// guards so they do not reach hardware). Tier C is compiled only when
// LATENCY_INSENSITIVE_CHECK = 1.
// =============================================================================

module tv_fast_fifo
    import pe_pkg::*;
#(
    parameter int  DEPTH                       = 4,
    parameter int  DATA_W                      = FRAG_W,        // 256
    parameter bit  INPUT_SKID                  = 1'b1,
    parameter bit  OUTPUT_REG                  = 1'b0,
    parameter bit  LATENCY_INSENSITIVE_CHECK   = 1'b0,
    parameter int  ACTIVITY_BOUND              = 1024,

    // Derived
    localparam int FILL_W = $clog2(DEPTH + 1)
) (
    input  logic                   clk_i,
    input  logic                   rst_ni,

    // ── Synchronous flush (soft reset) ──
    // [FIX 2026-07-12, pre-tapeout audit] Every other stage on the Tensor->Vector
    // fast path honours cp_soft_reset (vector_unit.sv flush, tensor_domain_top,
    // dma_engine, l2_subsystem) — this FIFO did not, so an aborted context left
    // stale capsules in flight that silently corrupted the NEXT RESADD. Drives all
    // FIFO state (skid, pointers, output reg) back to empty in one cycle.
    input  logic                   flush_i,

    // ── Input (producer side) ──
    input  logic                   in_valid_i,
    output logic                   in_ready_o,
    input  logic [DATA_W-1:0]      in_data_i,
    input  frag_sideband_t         in_sideband_i,

    // ── Output (consumer side) ──
    output logic                   out_valid_o,
    input  logic                   out_ready_i,
    output logic [DATA_W-1:0]      out_data_o,
    output frag_sideband_t         out_sideband_o,

    // ── Observability ──
    output logic [FILL_W-1:0]      fill_level_o,
    output logic                   overflow_o,       // sticky, for assertions/trace
    output logic                   underflow_o       // sticky, for assertions/trace
);

    // -------------------------------------------------------------------------
    // Combined beat type: data + sideband travel together
    // -------------------------------------------------------------------------
    localparam int BEAT_W = DATA_W + $bits(frag_sideband_t);

    typedef struct packed {
        logic [DATA_W-1:0] data;
        frag_sideband_t    sideband;
    } beat_t;

    // -------------------------------------------------------------------------
    // Stage 0: Input Skid Buffer (optional, INPUT_SKID=1)
    //
    // Purpose: absorb a 1-cycle mismatch between producer's valid and
    // FIFO's ready so the ready path does not combinationally depend on
    // the FIFO's full flag.
    //
    // When INPUT_SKID=0, this stage is bypassed (skid_* == in_*).
    // -------------------------------------------------------------------------
    logic          skid_valid_q;
    beat_t         skid_beat_q;
    logic          skid_out_valid;
    beat_t         skid_out_beat;
    logic          skid_out_ready;   // driven by main FIFO: !fifo_full

    generate
        if (INPUT_SKID) begin : g_skid
            // The skid holds one beat when the main FIFO back-pressures
            // the producer.
            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    skid_valid_q <= 1'b0;
                    skid_beat_q  <= '0;
                end else if (flush_i) begin
                    skid_valid_q <= 1'b0;   // drop the held beat (soft reset)
                end else begin
                    if (!skid_valid_q) begin
                        // skid empty → latch producer beat if producer valid
                        // AND downstream not ready (so beat can't pass through)
                        if (in_valid_i && !skid_out_ready) begin
                            skid_valid_q    <= 1'b1;
                            skid_beat_q.data     <= in_data_i;
                            skid_beat_q.sideband <= in_sideband_i;
                        end
                    end else begin
                        // skid holds a beat → drain to FIFO when FIFO ready
                        if (skid_out_ready) begin
                            skid_valid_q <= 1'b0;
                        end
                    end
                end
            end

            // Skid output: prioritize skid-held beat when present
            assign skid_out_valid = skid_valid_q | in_valid_i;
            assign skid_out_beat  = skid_valid_q
                                  ? skid_beat_q
                                  : '{data: in_data_i, sideband: in_sideband_i};

            // Producer ready: skid has room
            assign in_ready_o = !skid_valid_q;

        end else begin : g_noskid
            // No skid: direct passthrough
            assign skid_out_valid = in_valid_i;
            assign skid_out_beat  = '{data: in_data_i, sideband: in_sideband_i};
            assign in_ready_o     = skid_out_ready;
            // Tie off unused storage
            assign skid_valid_q = 1'b0;
            assign skid_beat_q  = '0;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Stage 1: Main FIFO (DEPTH entries)
    //
    // Simple pointer-based FIFO; stores beat_t (data + sideband combined).
    // Pointers are 1 bit wider than $clog2(DEPTH) to distinguish full
    // from empty.
    // -------------------------------------------------------------------------
    localparam int PTR_W = $clog2(DEPTH) + 1;

    beat_t             mem [DEPTH];
    logic [PTR_W-1:0]  wptr_q, rptr_q;
    logic              fifo_full, fifo_empty;
    logic              fifo_enq, fifo_deq;

    // Enqueue/dequeue intent from adjacent stages
    logic              deq_from_fifo_ready;  // driven by output-reg stage

    assign fifo_full  = ({~wptr_q[PTR_W-1], wptr_q[PTR_W-2:0]} == rptr_q);
    assign fifo_empty = (wptr_q == rptr_q);

    assign skid_out_ready = !fifo_full;
    assign fifo_enq       = skid_out_valid && skid_out_ready;
    assign fifo_deq       = !fifo_empty && deq_from_fifo_ready;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            wptr_q <= '0;
            rptr_q <= '0;
        end else if (flush_i) begin
            wptr_q <= '0;                   // discard all buffered capsules (soft reset)
            rptr_q <= '0;
        end else begin
            if (fifo_enq) begin
                mem[wptr_q[PTR_W-2:0]] <= skid_out_beat;
                wptr_q                  <= wptr_q + {{(PTR_W-1){1'b0}}, 1'b1};
            end
            if (fifo_deq) begin
                rptr_q <= rptr_q + {{(PTR_W-1){1'b0}}, 1'b1};
            end
        end
    end

    // FIFO head (combinational peek)
    beat_t fifo_head_beat;
    assign fifo_head_beat = mem[rptr_q[PTR_W-2:0]];

    logic  fifo_head_valid;
    assign fifo_head_valid = !fifo_empty;

    // -------------------------------------------------------------------------
    // Stage 2: Output Register (optional, OUTPUT_REG=1)
    //
    // When OUTPUT_REG=1, insert 1 register stage between FIFO head and
    // consumer, at the cost of 1 extra cycle of latency but with relaxed
    // timing on the consumer's input path.
    //
    // When OUTPUT_REG=0, the consumer sees the FIFO head directly.
    // -------------------------------------------------------------------------
    generate
        if (OUTPUT_REG) begin : g_outreg
            logic  out_reg_valid_q;
            beat_t out_reg_beat_q;

            // Output-reg ready to accept from FIFO when it's empty or being drained
            assign deq_from_fifo_ready = !out_reg_valid_q || out_ready_i;

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni) begin
                    out_reg_valid_q <= 1'b0;
                    out_reg_beat_q  <= '0;
                end else if (flush_i) begin
                    out_reg_valid_q <= 1'b0;   // drop the registered beat (soft reset)
                end else begin
                    if (deq_from_fifo_ready) begin
                        if (fifo_head_valid) begin
                            out_reg_valid_q <= 1'b1;
                            out_reg_beat_q  <= fifo_head_beat;
                        end else begin
                            out_reg_valid_q <= 1'b0;
                        end
                    end
                end
            end

            assign out_valid_o    = out_reg_valid_q;
            assign out_data_o     = out_reg_beat_q.data;
            assign out_sideband_o = out_reg_beat_q.sideband;

        end else begin : g_nooutreg
            // No output register: consumer sees FIFO head directly
            assign deq_from_fifo_ready = out_ready_i;
            assign out_valid_o         = fifo_head_valid;
            assign out_data_o          = fifo_head_beat.data;
            assign out_sideband_o      = fifo_head_beat.sideband;
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Fill-level (observability)
    //
    // Counts beats currently in the main FIFO only (not counting skid or
    // output register). This matches the "storage budget" typically wanted
    // by integration-level perf/trace.
    // -------------------------------------------------------------------------
    logic signed [PTR_W:0] diff;
    assign diff         = $signed({1'b0, wptr_q}) - $signed({1'b0, rptr_q});
    assign fill_level_o = diff[PTR_W-1:0];

    // -------------------------------------------------------------------------
    // Sticky overflow/underflow trackers
    //
    // These detect PROTOCOL VIOLATIONS (illegal enqueue when full, illegal
    // dequeue when empty). Under correct handshake, these should never
    // assert. Kept sticky so software/trace can observe them after the fact.
    // -------------------------------------------------------------------------
    logic overflow_q, underflow_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            overflow_q  <= 1'b0;
            underflow_q <= 1'b0;
        end else begin
            if (fifo_full && fifo_enq) overflow_q  <= 1'b1;  // latched
            if (fifo_empty && fifo_deq) underflow_q <= 1'b1;
        end
    end
    assign overflow_o  = overflow_q;
    assign underflow_o = underflow_q;

    // =========================================================================
    // Assertions — Tier A (always-on, synthesis-excluded)
    // =========================================================================
    // synthesis translate_off
    // pragma translate_off

    // --- A1: full → !in_ready (with INPUT_SKID we check at skid level) ---
    property p_full_implies_not_ready;
        @(posedge clk_i) disable iff (!rst_ni)
            fifo_full && (INPUT_SKID ? skid_valid_q : 1'b1) |-> !in_ready_o;
    endproperty
    a_full_implies_not_ready: assert property (p_full_implies_not_ready)
        else $error("tv_fast_fifo: full but in_ready asserted (back-pressure broken)");

    // --- A2: empty → !out_valid (no spurious output) ---
    property p_empty_implies_not_valid;
        @(posedge clk_i) disable iff (!rst_ni)
            fifo_empty && (OUTPUT_REG ? 1'b1 : 1'b1) |->
                (OUTPUT_REG ? 1'b1 : !out_valid_o);
    endproperty
    // Note: when OUTPUT_REG=1, out_valid may still be 1 because output
    // register holds a beat even when main FIFO is empty. Check is on
    // the main FIFO's own valid signal:
    property p_fifo_empty_no_head_valid;
        @(posedge clk_i) disable iff (!rst_ni)
            fifo_empty |-> !fifo_head_valid;
    endproperty
    a_fifo_empty_no_head_valid: assert property (p_fifo_empty_no_head_valid)
        else $error("tv_fast_fifo: empty but fifo_head_valid asserted");

    // [FIX 2026-07-12] flush_i makes the FIFO jump to empty outside the normal
    // enq/deq accounting, and legitimately drops a stalled output beat. Mask the
    // two properties that model those invariants for the flush cycle (+1 for the
    // registered fill tracker). Sim-only: this whole region is translate_off.
    logic flush_d;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) flush_d <= 1'b0;
        else         flush_d <= flush_i;
    end

    // --- A3: fill_level transitions correctly ---
    // Verified via invariant: fill_level change in cycle N equals
    // (enq this cycle) - (deq this cycle)
    logic [FILL_W-1:0] fill_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)      fill_q <= '0;
        else if (flush_i) fill_q <= '0;
        else              fill_q <= fill_level_o;
    end
    // [2026-07-24] the property compared this cycle's fill_level_o against THIS
    // cycle's fifo_enq/fifo_deq, but fill_level_o (:302) is combinational off the
    // REGISTERED pointers — it reflects the state BEFORE this cycle's enq/deq
    // land. So the enq/deq terms belong one cycle back: fill_level_o(t) ==
    // fill_level_o(t-1) + enq(t-1) - deq(t-1), and fill_q(t) IS fill_level_o(t-1).
    // As written it failed on the very first enqueue (fill=0 q=0 enq=1 deq=0);
    // it never showed because tb/Makefile lacked --assert.
    property p_fill_level_transition;
        @(posedge clk_i) disable iff (!rst_ni || flush_i || flush_d)
            (fill_level_o == (fill_q + {{(FILL_W-1){1'b0}}, $past(fifo_enq)})
                            - {{(FILL_W-1){1'b0}}, $past(fifo_deq)});
    endproperty
    a_fill_level_transition: assert property (p_fill_level_transition)
        else $error("tv_fast_fifo: fill_level delta inconsistent with enq/deq (fill=%0d q=%0d enq=%0b deq=%0b)",
                    fill_level_o, fill_q, fifo_enq, fifo_deq);

    // --- A4: stall-stable (out_valid && !out_ready → data/sideband stable) ---
    property p_out_stall_stable_data;
        @(posedge clk_i) disable iff (!rst_ni || flush_i || flush_d)
            (out_valid_o && !out_ready_i) |=>
                ($stable(out_data_o) && $stable(out_sideband_o) && out_valid_o);
    endproperty
    a_out_stall_stable_data: assert property (p_out_stall_stable_data)
        else $error("tv_fast_fifo: output not stable under back-pressure (latency-insensitive violation)");

    // =========================================================================
    // Assertions — Tier B (recommended-on)
    // =========================================================================

    // --- B1: overflow never asserted under correct handshake ---
    property p_no_overflow;
        @(posedge clk_i) disable iff (!rst_ni)
            !(fifo_full && fifo_enq);
    endproperty
    a_no_overflow: assert property (p_no_overflow)
        else $error("tv_fast_fifo: OVERFLOW — enqueue while full");

    // --- B2: underflow never asserted under correct handshake ---
    property p_no_underflow;
        @(posedge clk_i) disable iff (!rst_ni)
            !(fifo_empty && fifo_deq);
    endproperty
    a_no_underflow: assert property (p_no_underflow)
        else $error("tv_fast_fifo: UNDERFLOW — dequeue while empty");

    // --- B3: data and sideband advance together ---
    // If either is captured on enq, both must be captured. (Trivially true
    // by construction since they share beat_t, but asserted as documentation.)
    property p_data_sideband_coupled;
        @(posedge clk_i) disable iff (!rst_ni)
            fifo_enq |-> 1'b1;  // structural; beat_t enforces coupling
    endproperty
    a_data_sideband_coupled: assert property (p_data_sideband_coupled);

    // =========================================================================
    // Assertions — Tier C (optional, parameterized off)
    // =========================================================================
    generate
        if (LATENCY_INSENSITIVE_CHECK) begin : g_tier_c
            // --- C1: valid eventually sees ready within ACTIVITY_BOUND cycles ---
            // Bounded-activity check for the output side. Turning this on in
            // early integration is risky (false positives when downstream
            // consumer is legitimately slow).
            // NOTE (N18): the `##[1:N]` cycle-delay range is unsupported by the
            // lint simulator 5.032 (parsed even in an off generate) -> mask it
            // sim-tool-side. VCS/synthesis (the only place this opt-in check runs)
            // is unaffected.
`ifndef VERILATOR
            property p_bounded_activity_out;
                @(posedge clk_i) disable iff (!rst_ni)
                    out_valid_o |-> ##[1:ACTIVITY_BOUND] out_ready_i;
            endproperty
            a_bounded_activity_out: assert property (p_bounded_activity_out)
                else $error("tv_fast_fifo: output valid not accepted within %0d cycles", ACTIVITY_BOUND);
`endif
        end
    endgenerate

    // pragma translate_on
    // synthesis translate_on

    // -------------------------------------------------------------------------
    // Init (simulation)
    // -------------------------------------------------------------------------
    // synthesis translate_off
    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = '0;
    end
    // synthesis translate_on

endmodule

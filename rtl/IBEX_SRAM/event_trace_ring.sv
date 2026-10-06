// =============================================================================
// event_trace_ring.sv — Event Trace Ring Buffer (D8/R7.3)
//
// Records recent system events with 16-bit timestamps into a SRAM-based
// circular buffer. IBEX reads captured events via MMIO index+data pattern.
//
// Architecture:
//   - Register-file ring buffer: TRACE_DEPTH entries × 32 bits
//   - Single write port: accepts one pre-formatted trace_entry_t per cycle
//   - Module stamps 16-bit free-running timestamp on write
//   - Write pointer wraps (circular), overflow flag sticky
//   - Freeze mode: halts recording while preserving buffer contents
//   - MMIO read: combinational indexed access into ring buffer
//
// Event collection and priority encoding is external (D9 integration).
// This module is purely storage + control + timestamp.
//
// MMIO Register Map (at cp_csr high-half):
//   0x130  TRACE_CTRL    RW  {28'b0, ovf_irq_en, clear, freeze, enable}
//   0x134  TRACE_STATUS  RO  {14'b0, overflow, count[TRACE_AW:0],
//                              {(16-TRACE_AW){1'b0}}, wr_ptr[TRACE_AW-1:0]}
//   0x138  TRACE_INDEX   RW  {26'b0, rd_index[TRACE_AW-1:0]}
//   0x13C  TRACE_DATA    RO  trace_mem[rd_index] (32-bit trace_entry_t)
//
// Usage flow (IBEX driver):
//   1. Write TRACE_CTRL.enable = 1  → start recording
//   2. (events are recorded automatically by HW event collector)
//   3. Write TRACE_CTRL.freeze = 1  → snapshot buffer
//   4. Read TRACE_STATUS → get wr_ptr, count, overflow
//   5. For i in [0..count-1]:
//        Write TRACE_INDEX = (wr_ptr - count + i) & (DEPTH-1)
//        Read  TRACE_DATA  → trace_entry_t
//   6. Write TRACE_CTRL.clear = 1   → reset ring
// =============================================================================

module event_trace_ring
    import pe_pkg::*;
(
    input  logic          clk_i,
    input  logic          rst_ni,
    input  logic          soft_reset_i,

    // ── Trace Write Port (from event collector in command_processor) ──
    //
    // trace_entry_i carries event_type, ctx_id, payload.
    // The timestamp field is IGNORED and overwritten by this module's
    // internal free-running counter.
    input  logic          trace_valid_i,
    input  trace_entry_t  trace_entry_i,

    // ── MMIO Control Inputs (from cp_csr registers) ──
    input  logic          trace_enable_i,     // recording enabled
    input  logic          trace_freeze_i,     // freeze (halt writes, keep data)
    input  logic          trace_clear_i,      // clear pulse (reset ptr + overflow)

    // ── MMIO Read Port (from cp_csr) ──
    input  logic [TRACE_AW-1:0] trace_rd_index_i,
    output logic [31:0]         trace_rd_data_o,

    // ── Status Outputs (to cp_csr) ──
    output logic [TRACE_AW-1:0] trace_wr_ptr_o,
    output logic                trace_overflow_o,
    output logic [TRACE_AW:0]   trace_count_o
);

    // =========================================================================
    // Internal Storage
    //
    // Register-file implementation. For TRACE_DEPTH=64, this is 64×32 = 2048
    // flip-flops. Acceptable for PE debug infrastructure; if area-critical,
    // can be replaced with a 1RW SRAM macro in future.
    // =========================================================================
    logic [31:0] trace_mem [TRACE_DEPTH];

    // =========================================================================
    // Write Pointer & Overflow
    // =========================================================================
    logic [TRACE_AW-1:0] wr_ptr_q;
    logic                overflow_q;       // sticky: ring has wrapped at least once
    logic [TRACE_AW:0]   count_q;          // entries written, saturates at TRACE_DEPTH

    assign trace_wr_ptr_o   = wr_ptr_q;
    assign trace_overflow_o = overflow_q;
    assign trace_count_o    = count_q;

    // =========================================================================
    // 16-bit Free-Running Timestamp Counter
    //
    // Increments every cycle when enabled. Wraps at 65536 (natural overflow).
    // Provides relative timing between events. Resolution = 1 clock cycle.
    // Continues counting even when frozen (freeze only stops writes).
    // =========================================================================
    logic [15:0] ts_cnt_q;

    // =========================================================================
    // Write Logic
    //
    // Conditions for writing:
    //   1. trace_valid_i asserted (event collector has an event)
    //   2. trace_enable_i = 1 (TRACE_CTRL.enable)
    //   3. trace_freeze_i = 0 (not frozen)
    //
    // On write:
    //   - Stamp entry with current timestamp
    //   - Write to trace_mem[wr_ptr]
    //   - Advance wr_ptr (modular, wraps via truncation)
    //   - If wr_ptr wraps past DEPTH → set overflow
    //   - Increment count (saturates at DEPTH)
    // =========================================================================
    logic do_write;
    assign do_write = trace_valid_i && trace_enable_i && !trace_freeze_i;

    // Stamped entry: replace timestamp field with internal counter
    trace_entry_t entry_stamped;
    always_comb begin
        entry_stamped.timestamp  = ts_cnt_q;
        entry_stamped.event_type = trace_entry_i.event_type;
        entry_stamped.ctx_id     = trace_entry_i.ctx_id;
        entry_stamped.payload    = trace_entry_i.payload;
    end

    // =========================================================================
    // Read Logic (combinational, indexed)
    //
    // IBEX sets TRACE_INDEX, then reads TRACE_DATA on next cycle.
    // The read is combinational from the register file — no pipeline.
    // =========================================================================
    assign trace_rd_data_o = trace_mem[trace_rd_index_i];

    // =========================================================================
    // Sequential Logic
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            wr_ptr_q   <= '0;
            overflow_q <= 1'b0;
            count_q    <= '0;
            ts_cnt_q   <= '0;
            // Note: trace_mem not cleared on reset (don't care contents).
            // Software should check count_q before reading.
        end else if (soft_reset_i || trace_clear_i) begin
            // Clear: reset write pointer and overflow, preserve timestamp
            wr_ptr_q   <= '0;
            overflow_q <= 1'b0;
            count_q    <= '0;
            // Timestamp continues running (not reset) for global timing coherence.
            // trace_mem contents become stale but count=0 prevents reading them.
            ts_cnt_q   <= ts_cnt_q + 16'd1;
        end else begin
            // Timestamp always increments when enabled
            if (trace_enable_i)
                ts_cnt_q <= ts_cnt_q + 16'd1;

            // Write event to ring buffer
            if (do_write) begin
                trace_mem[wr_ptr_q] <= entry_stamped;

                // Advance write pointer (wraps via truncation to TRACE_AW bits)
                wr_ptr_q <= wr_ptr_q + TRACE_AW'(1);

                // Overflow: set when pointer wraps back to 0
                if (wr_ptr_q == TRACE_AW'(TRACE_DEPTH - 1))
                    overflow_q <= 1'b1;

                // Count: saturates at TRACE_DEPTH
                if (count_q != (TRACE_AW+1)'(TRACE_DEPTH))
                    count_q <= count_q + (TRACE_AW+1)'(1);
            end
        end
    end

    // =========================================================================
    // Assertions (synthesis-off)
    // =========================================================================
`ifndef SYNTHESIS
    // trace_entry_t must be exactly 32 bits
    initial begin
        assert ($bits(trace_entry_t) == 32)
            else $fatal(1, "trace_entry_t is %0d bits, expected 32", $bits(trace_entry_t));
    end

    // Write pointer must be in range
    // [2026-07-24] the bound was `TRACE_AW'(TRACE_DEPTH)`, which truncates
    // TRACE_DEPTH to the POINTER's own width: for TRACE_DEPTH=64, TRACE_AW=6 and
    // 6'(64) == 6'd0, so the check read `wr_ptr_q < 0` and was UNCONDITIONALLY
    // false. It never showed because tb/Makefile lacked --assert (Verilator was
    // discarding every assertion). Widened by one bit like the two sibling
    // properties below already do.
    a_wr_ptr_range: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        {1'b0, wr_ptr_q} < (TRACE_AW+1)'(TRACE_DEPTH)
    ) else $error("[TRACE] wr_ptr=%0d out of range [0..%0d)", wr_ptr_q, TRACE_DEPTH);

    // Count must not exceed TRACE_DEPTH
    a_count_range: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        count_q <= (TRACE_AW+1)'(TRACE_DEPTH)
    ) else $error("[TRACE] count=%0d exceeds TRACE_DEPTH=%0d", count_q, TRACE_DEPTH);

    // Overflow implies count == TRACE_DEPTH
    a_overflow_implies_full: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        overflow_q |-> (count_q == (TRACE_AW+1)'(TRACE_DEPTH))
    ) else $error("[TRACE] overflow set but count=%0d != DEPTH=%0d", count_q, TRACE_DEPTH);

    // Clear resets ptr and overflow
    a_clear_resets: assert property (
        @(posedge clk_i)
        (trace_clear_i && !soft_reset_i) |=> (wr_ptr_q == '0) && !overflow_q && (count_q == '0)
    ) else $error("[TRACE] clear did not reset state");

    // Cover: ring wraps (overflow transition 0→1)
    //   Guarded from Verilator: the `##1` cycle-delay sequence in a cover
    //   property is unsupported by Verilator 5.032 (same class as the N18
    //   `|-> ##1` timing SVA in mac_fp_accumulator). Sim/formal-only; no
    //   functional or synthesis impact.
`ifndef VERILATOR
    c_overflow_event: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        !overflow_q ##1 overflow_q
    );
`endif

    // Cover: freeze halts writes
    c_freeze_blocks_write: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        trace_valid_i && trace_enable_i && trace_freeze_i && !do_write
    );
`endif

endmodule

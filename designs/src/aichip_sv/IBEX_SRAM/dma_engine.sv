// =============================================================================
// dma_engine.sv — DMA Engine (PE v4, R7.4: 2D strided + memset, D4: done_tag)
//
// Modes:
//   FILL:   NoC ingress → ingress FIFO → L2 RW port (single-bank write)
//   EVICT:  L2 RW port (single-bank read) → egress FIFO → NoC egress
//   MEMSET: Constant value → L2 RW port (no NoC, R7.4)
//
// 2D Strided Transfer (R7.4):
//   When outer_count > 1: nested loop over outer × inner iterations.
//   Inner loop: len_rows × 16 words (same as 1D).
//   Between outer iterations: base_row += stride_rows.
//   When outer_count == 0 or 1: degrades to 1D (backward compatible).
//
// AGU computes per-word L2 addresses:
//   bank_sel  = wcount[3:0]   (word-interleaved across 16 banks)
//   row_addr  = cur_base_row + wcount[BANK_AW-1+4:4]
//               (every 16 words advances to next row)
//
// Total words per inner iteration: len_rows × 16 (one row = 16 words = 64B)
// Total words overall: outer_count × len_rows × 16
//
// FIFOs are register-based (8 entries × 32b), not SRAM-based.
// =============================================================================

module dma_engine
    import pe_pkg::*;
#(
    parameter int FIFO_DEPTH = 8
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Control ──
    input  logic        soft_reset_i,       // P13: from pe_top

    // ── CP Command ──
    input  logic        cmd_valid_i,
    output logic        cmd_ready_o,
    input  dma_cmd_t    cmd_i,

    // ── L2 RW Port — Fill (write to L2) ──
    output logic                              fill_req_o,
    input  logic                              fill_gnt_i,
    output logic [L2_BANK_SEL_W-1:0]         fill_bank_o,
    output logic [L2_BANK_AW-1:0]            fill_row_o,
    output logic [31:0]                       fill_wdata_o,
    output logic [3:0]                        fill_be_o,

    // ── L2 RW Port — Evict (read from L2) ──
    output logic                              evict_req_o,
    input  logic                              evict_gnt_i,
    input  logic                              evict_rvalid_i,
    output logic [L2_BANK_SEL_W-1:0]         evict_bank_o,
    output logic [L2_BANK_AW-1:0]            evict_row_o,
    input  logic [31:0]                       evict_rdata_i,

    // ── NoC Ingress (AXI-Stream style) ──
    input  logic        noc_ing_valid_i,
    output logic        noc_ing_ready_o,
    input  logic [31:0] noc_ing_data_i,
    input  logic        noc_ing_last_i,

    // ── NoC Egress (AXI-Stream style) ──
    output logic        noc_egr_valid_o,
    input  logic        noc_egr_ready_i,
    output logic [31:0] noc_egr_data_o,
    output logic        noc_egr_last_o,

    // ── Completion ──
    output logic        done_o,
    output logic [1:0]  done_ctx_o,
    output logic [TAG_W-1:0] done_tag_o           // D4: return scoreboard tag
);

    // =========================================================================
    // FSM States
    // =========================================================================
    typedef enum logic [2:0] {
        ST_IDLE         = 3'd0,
        ST_FILL_RUN     = 3'd1,
        ST_EVICT_REQ    = 3'd2,   // issuing L2 reads
        ST_EVICT_DRAIN  = 3'd3,   // draining egress FIFO to NoC
        ST_DONE         = 3'd4,
        ST_MEMSET_RUN   = 3'd5,   // R7.4: constant fill to L2
        ST_OUTER_ADVANCE = 3'd6   // R7.4: advance to next outer iteration
    } dma_state_e;

    dma_state_e state_q, state_d;

    // =========================================================================
    // Command Register
    // =========================================================================
    dma_cmd_t cmd_q;
    assign cmd_ready_o = (state_q == ST_IDLE);
    assign done_ctx_o  = cmd_q.ctx_id;
    assign done_tag_o  = cmd_q.tag;              // D4: tag passthrough

    // =========================================================================
    // Word Counter + AGU
    //
    // Inner loop: total_words = len_rows × 16 (each row = 16 words)
    // For each word:
    //   bank_sel = wcount[3:0]            (word-interleaved)
    //   row_addr = cur_base_row + wcount[MSB:4]  (16 words per row)
    //
    // R7.4 Outer loop:
    //   outer_cnt tracks current outer iteration (0-based).
    //   eff_outer_count = max(outer_count, 1): normalize 0→1 for 1D compat.
    //   cur_base_row advances by stride_rows between outer iterations.
    //   wcount resets to 0 at each outer iteration start.
    // =========================================================================
    logic [19:0] wcount_q, wcount_d;     // inner word counter
    logic [19:0] total_words;            // inner loop word count

    assign total_words = {cmd_q.len_rows, 4'b0};  // len_rows << 4

    // R7.4: 2D outer loop state
    logic [15:0] outer_cnt_q;                      // current outer iteration (0-based)
    logic [15:0] eff_outer_count;                   // effective outer count (0/1 → 1)
    logic [L2_BANK_AW-1:0] cur_base_row_q;         // current base row (advances per iter)

    assign eff_outer_count = (cmd_q.outer_count <= 16'd1) ? 16'd1 : cmd_q.outer_count;

    logic inner_done;                               // inner iteration complete
    assign inner_done = (wcount_q >= total_words);

    logic outer_done;                               // all outer iterations complete
    assign outer_done = (outer_cnt_q >= eff_outer_count - 16'd1);

    logic [L2_BANK_SEL_W-1:0] agu_bank;
    logic [L2_BANK_AW-1:0]    agu_row;

    assign agu_bank = wcount_q[L2_BANK_SEL_W-1:0];
    assign agu_row  = cur_base_row_q + wcount_q[L2_BANK_AW-1+4:4];

    // =========================================================================
    // Ingress FIFO (NoC → L2 fill path)
    // =========================================================================
    logic [31:0] ing_fifo [FIFO_DEPTH];
    logic [$clog2(FIFO_DEPTH):0] ing_wptr_q, ing_rptr_q;
    logic [$clog2(FIFO_DEPTH):0] ing_count;
    logic ing_full, ing_empty;

    assign ing_count = ing_wptr_q - ing_rptr_q;
    assign ing_full  = (ing_count == FIFO_DEPTH[$clog2(FIFO_DEPTH):0]);
    assign ing_empty = (ing_count == '0);

    // Push: NoC → FIFO (when not full and in FILL_RUN state)
    logic ing_push, ing_pop;

    // [FIX 2026-07-12, pre-tapeout audit] Flush the ingress FIFO whenever the engine
    // is idle. Guarantees every FILL command starts from an empty FIFO, so a NoC that
    // over-sends (protocol violation) cannot leave straggler words behind to corrupt
    // the next transfer — nor stall the final (inner_done && ing_empty) exit check.
    // No push can occur in ST_IDLE (ing_push is only driven in ST_FILL_RUN), so this
    // never races a write.
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ing_wptr_q <= '0;
        end else if (soft_reset_i) begin  // [STEP5 slang] sync soft_reset_i split from async reset
            ing_wptr_q <= '0;
        end else if (state_q == ST_IDLE) begin
            ing_wptr_q <= '0;
        end else if (ing_push) begin
            ing_fifo[ing_wptr_q[$clog2(FIFO_DEPTH)-1:0]] <= noc_ing_data_i;
            ing_wptr_q <= ing_wptr_q + 1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) ing_rptr_q <= '0;
        else if (soft_reset_i) ing_rptr_q <= '0;  // [STEP5 slang] sync soft_reset_i split from async reset
        else if (state_q == ST_IDLE) ing_rptr_q <= '0;
        else if (ing_pop) ing_rptr_q <= ing_rptr_q + 1;
    end

    logic [31:0] ing_rdata;
    assign ing_rdata = ing_fifo[ing_rptr_q[$clog2(FIFO_DEPTH)-1:0]];

    // =========================================================================
    // Egress FIFO (L2 evict → NoC path)
    // =========================================================================
    logic [31:0] egr_fifo [FIFO_DEPTH];
    logic [$clog2(FIFO_DEPTH):0] egr_wptr_q, egr_rptr_q;
    logic [$clog2(FIFO_DEPTH):0] egr_count;
    logic egr_full, egr_empty;

    assign egr_count = egr_wptr_q - egr_rptr_q;
    assign egr_full  = (egr_count == FIFO_DEPTH[$clog2(FIFO_DEPTH):0]);
    assign egr_empty = (egr_count == '0);

    logic egr_push, egr_pop;
    logic [31:0] egr_push_data;   // P7c: MUXed between hold register and direct rdata

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            egr_wptr_q <= '0;
        end else if (soft_reset_i) begin  // [STEP5 slang] sync soft_reset_i split from async reset
            egr_wptr_q <= '0;
        end else if (egr_push) begin
            egr_fifo[egr_wptr_q[$clog2(FIFO_DEPTH)-1:0]] <= egr_push_data;
            egr_wptr_q <= egr_wptr_q + 1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) egr_rptr_q <= '0;
        else if (soft_reset_i) egr_rptr_q <= '0;  // [STEP5 slang] sync soft_reset_i split from async reset
        else if (egr_pop) egr_rptr_q <= egr_rptr_q + 1;
    end

    logic [31:0] egr_rdata;
    assign egr_rdata = egr_fifo[egr_rptr_q[$clog2(FIFO_DEPTH)-1:0]];

    // =========================================================================
    // P7c / [C2]: Evict Holding FIFO (depth 2)
    //
    // Bridges the gap when L2 returns rvalid but the egress FIFO is full.
    // Without it, rvalid data is lost (SRAM does not hold its output).
    //
    // [C2 vec-l2-port-reg] Depth raised 1→2. With the L2 read registered
    // (sram_1rw1r_wrapper OUT_REG=1 → 2-cycle read) TWO evict reads are in flight
    // when egr_full closes req; the old single-entry hold caught the first
    // straggler and DROPPED the second (capture needed !hold_valid). Since
    // evict_received_q counts egr_push (not raw rvalid), a dropped word wedges it
    // below total_words forever → ST_EVICT_DRAIN deadlock. A depth-2 hold absorbs
    // both stragglers. (Regression: tb/test_dma_evict_bp.py.)
    //
    // Protocol (egr accepts ≤1 push/cycle; hold-drain has priority):
    //   - Drain:   !hq_empty && !egr_full         → pop head → egr_push
    //   - Enqueue: rvalid that can't be pushed this cycle (egr_full, OR the egr
    //              slot is taken by a concurrent drain) && !hq_full
    //   - Direct:  rvalid && !egr_full && hq_empty → straight to egr (no hold)
    //
    // Invariant: evict_req is gated on hq_empty, so once the hold holds anything
    //   no new read issues; at ≤2-cycle latency at most 2 reads are in flight →
    //   the hold never exceeds 2 and never drops. (Holds for any read latency.)
    // =========================================================================
    logic [31:0] hq [2];        // hold data, FIFO order
    logic        hq_wsel_q;     // write slot (toggles 0/1)
    logic        hq_rsel_q;     // read slot (toggles 0/1)
    logic [1:0]  hq_cnt_q;      // occupancy 0..2
    logic        hq_empty, hq_full;
    assign hq_empty = (hq_cnt_q == 2'd0);
    assign hq_full  = (hq_cnt_q == 2'd2);

    logic hq_deq, hq_enq;
    assign hq_deq = !hq_empty && !egr_full;                                // drain head → egr
    assign hq_enq = evict_rvalid_i && !hq_full && (egr_full || !hq_empty); // hold a stuck rvalid

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            hq_wsel_q <= 1'b0; hq_rsel_q <= 1'b0; hq_cnt_q <= 2'd0;
            hq[0] <= '0; hq[1] <= '0;
        end else if (soft_reset_i) begin  // [STEP5 slang] sync soft_reset_i split from async reset
            hq_wsel_q <= 1'b0; hq_rsel_q <= 1'b0; hq_cnt_q <= 2'd0;
        end else begin
            if (hq_enq) begin
                hq[hq_wsel_q] <= evict_rdata_i;
                hq_wsel_q     <= ~hq_wsel_q;
            end
            if (hq_deq)
                hq_rsel_q <= ~hq_rsel_q;
            // occupancy: +enq (gated !hq_full) −deq (gated !hq_empty) → stays 0..2,
            // enq+deq same cycle nets 0 (independent slots, FIFO order preserved)
            hq_cnt_q <= hq_cnt_q + (hq_enq ? 2'd1 : 2'd0) - (hq_deq ? 2'd1 : 2'd0);
        end
    end

    // =========================================================================
    // Egress push logic (P7c: priority MUX)
    //
    // Priority: holding register drains first (it's blocking the pipeline),
    // then direct rvalid captures.
    // =========================================================================
    always_comb begin
        egr_push      = 1'b0;
        egr_push_data = evict_rdata_i;  // default

        if (!hq_empty && !egr_full) begin
            // Drain holding FIFO head → egress FIFO (priority over a direct rvalid)
            egr_push      = 1'b1;
            egr_push_data = hq[hq_rsel_q];
        end else if (evict_rvalid_i && !egr_full && hq_empty) begin
            // Direct capture: rvalid → egress FIFO (normal path, hold empty)
            egr_push      = 1'b1;
            egr_push_data = evict_rdata_i;
        end
        // Any rvalid not pushed here (egr_full, or the slot taken by a drain) is
        //   enqueued into the depth-2 hold (hq_enq above). evict_req is gated on
        //   hq_empty, so in-flight reads never exceed the hold's 2 slots.
    end

    // =========================================================================
    // Evict read tracking
    //
    // P7b fix: evict_received_q counts actual FIFO pushes (egr_push),
    // NOT raw rvalid events. This ensures the "all received" check matches
    // the actual data available for NoC egress.
    // =========================================================================
    logic [19:0] evict_issued_q, evict_received_q;
    logic        evict_all_issued, evict_all_received;

    assign evict_all_issued  = (evict_issued_q >= total_words);
    assign evict_all_received = (evict_received_q >= total_words);

    // =========================================================================
    // FSM
    //
    // R7.4: 2D outer loop handled via ST_OUTER_ADVANCE transition state.
    //   When inner iteration completes and outer_done is false:
    //     → ST_OUTER_ADVANCE (1 cycle): advance base_row, reset wcount
    //     → return to appropriate RUN state
    //   When outer_done: → ST_DONE
    // =========================================================================
    always_comb begin
        state_d   = state_q;
        wcount_d  = wcount_q;

        fill_req_o    = 1'b0;
        fill_bank_o   = agu_bank;
        fill_row_o    = agu_row;
        fill_wdata_o  = ing_rdata;
        fill_be_o     = 4'hF;

        evict_req_o   = 1'b0;
        evict_bank_o  = agu_bank;
        evict_row_o   = agu_row;

        noc_ing_ready_o = 1'b0;
        noc_egr_valid_o = 1'b0;
        noc_egr_data_o  = egr_rdata;
        noc_egr_last_o  = 1'b0;

        ing_push = 1'b0;
        ing_pop  = 1'b0;
        // egr_push/egr_pop handled by dedicated comb blocks
        egr_pop  = 1'b0;

        done_o = 1'b0;

        case (state_q)
            // -----------------------------------------------------------------
            ST_IDLE: begin
                if (cmd_valid_i) begin
                    wcount_d = '0;
                    case (cmd_i.opcode)
                        OP_DMA_FILL:   state_d = ST_FILL_RUN;
                        OP_DMA_EVICT:  state_d = ST_EVICT_REQ;
                        OP_DMA_MEMSET: state_d = ST_MEMSET_RUN;
                        default:       state_d = ST_DONE;
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // FILL: NoC → ingress FIFO → L2 write
            //
            // Two concurrent streams:
            //   1. NoC → FIFO push (when FIFO not full)
            //   2. FIFO → L2 write (when FIFO not empty and L2 grants)
            // R7.4: inner_done triggers outer advance or completion.
            // -----------------------------------------------------------------
            ST_FILL_RUN: begin
                // Stream 1: Accept from NoC into FIFO
                noc_ing_ready_o = !ing_full;
                if (noc_ing_valid_i && !ing_full)
                    ing_push = 1'b1;

                // Stream 2: Drain FIFO to L2
                if (!ing_empty && !inner_done) begin
                    fill_req_o = 1'b1;
                    if (fill_gnt_i) begin
                        ing_pop  = 1'b1;
                        wcount_d = wcount_q + 20'd1;
                    end
                end

                // Inner iteration complete.
                //
                // [FIX 2026-07-12, pre-tapeout audit] 2D FILL deadlock.
                //   Old code waited for (inner_done && ing_empty) before the outer
                //   advance. But the NoC streams outer x len_rows x 16 words as ONE
                //   continuous burst, so at an inner boundary the FIFO legitimately
                //   still holds words belonging to the NEXT outer iteration — while
                //   ing_pop is gated by !inner_done, so it can never drain. The FSM
                //   locked up forever on the first inner boundary of any 2D transfer
                //   (outer_count > 1). 1D happened to be safe (pushes <= total_words),
                //   which is why the smoke test passed.
                //   The carry-over is correct by construction: ST_OUTER_ADVANCE only
                //   resets wcount and advances cur_base_row; the FIFO pointers persist,
                //   so the buffered words are drained against the NEW row base.
                if (inner_done) begin
                    if (!outer_done)
                        state_d = ST_OUTER_ADVANCE;   // FIFO carries over — do NOT wait for empty
                    else if (ing_empty)
                        state_d = ST_DONE;            // last word popped => FIFO empty by construction
                end
            end

            // -----------------------------------------------------------------
            // MEMSET: Constant value → L2 write (no NoC)
            //
            // R7.4: Like FILL but wdata = cmd_q.memset_val, no FIFO needed.
            // Direct write to L2, one word per grant.
            // -----------------------------------------------------------------
            ST_MEMSET_RUN: begin
                fill_wdata_o = cmd_q.memset_val;  // override: constant pattern

                if (!inner_done) begin
                    fill_req_o = 1'b1;
                    if (fill_gnt_i)
                        wcount_d = wcount_q + 20'd1;
                end

                if (inner_done) begin
                    if (outer_done)
                        state_d = ST_DONE;
                    else
                        state_d = ST_OUTER_ADVANCE;
                end
            end

            // -----------------------------------------------------------------
            // EVICT: L2 read → egress FIFO → NoC
            //
            // Phase 1 (ST_EVICT_REQ): Issue L2 reads, push rvalid to FIFO
            // Phase 2 (ST_EVICT_DRAIN): Drain remaining FIFO to NoC
            // Both phases overlap via FIFO buffering.
            // -----------------------------------------------------------------
            ST_EVICT_REQ: begin
                // Issue L2 reads
                if (!evict_all_issued && !egr_full && hq_empty) begin
                    evict_req_o = 1'b1;
                    if (evict_gnt_i)
                        wcount_d = wcount_q + 20'd1;
                end

                // Drain FIFO to NoC concurrently
                if (!egr_empty) begin
                    noc_egr_valid_o = 1'b1;
                    noc_egr_last_o  = (egr_count == 1) && evict_all_received
                                      && outer_done;
                    if (noc_egr_ready_i)
                        egr_pop = 1'b1;
                end

                // Move to drain phase when all reads issued
                if (evict_all_issued)
                    state_d = ST_EVICT_DRAIN;
            end

            ST_EVICT_DRAIN: begin
                // Drain to NoC
                if (!egr_empty) begin
                    noc_egr_valid_o = 1'b1;
                    noc_egr_last_o  = (egr_count == 1) && evict_all_received
                                      && outer_done;
                    if (noc_egr_ready_i)
                        egr_pop = 1'b1;
                end

                // Inner complete: all received and FIFO+hold empty
                if (evict_all_received && egr_empty && hq_empty) begin
                    if (outer_done)
                        state_d = ST_DONE;
                    else
                        state_d = ST_OUTER_ADVANCE;
                end
            end

            // -----------------------------------------------------------------
            // R7.4: OUTER_ADVANCE — 1-cycle transition state
            //
            // Advances cur_base_row, resets wcount, increments outer_cnt.
            // Sequential block handles the actual register updates.
            // Returns to the appropriate RUN state based on opcode.
            // -----------------------------------------------------------------
            ST_OUTER_ADVANCE: begin
                wcount_d = '0;  // reset inner counter for next iteration
                case (cmd_q.opcode)
                    OP_DMA_FILL:   state_d = ST_FILL_RUN;
                    OP_DMA_EVICT:  state_d = ST_EVICT_REQ;
                    OP_DMA_MEMSET: state_d = ST_MEMSET_RUN;
                    default:       state_d = ST_DONE;
                endcase
            end

            // -----------------------------------------------------------------
            ST_DONE: begin
                done_o  = 1'b1;
                state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase

        // ── R2.1 (C4): Suppress all outputs during soft_reset ──
        if (soft_reset_i) begin
            fill_req_o  = 1'b0;
            evict_req_o = 1'b0;
            done_o      = 1'b0;
        end
    end

    // =========================================================================
    // Sequential
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin                          // P13: soft_reset clears all
            state_q          <= ST_IDLE;
            cmd_q            <= '0;
            wcount_q         <= '0;
            evict_issued_q   <= '0;
            evict_received_q <= '0;
            outer_cnt_q      <= '0;
            cur_base_row_q   <= '0;
        end else if (soft_reset_i) begin  // [STEP5 slang] sync soft_reset_i split from async reset
            state_q          <= ST_IDLE;
            cmd_q            <= '0;
            wcount_q         <= '0;
            evict_issued_q   <= '0;
            evict_received_q <= '0;
            outer_cnt_q      <= '0;
            cur_base_row_q   <= '0;
        end else begin
            state_q  <= state_d;
            wcount_q <= wcount_d;

            // Latch command + initialize 2D state
            if (state_q == ST_IDLE && cmd_valid_i) begin
                cmd_q          <= cmd_i;
                outer_cnt_q    <= '0;
                cur_base_row_q <= cmd_i.l2_row;  // first iteration starts at base
            end

            // R7.4: Outer loop advance
            if (state_q == ST_OUTER_ADVANCE) begin
                outer_cnt_q    <= outer_cnt_q + 16'd1;
                cur_base_row_q <= cur_base_row_q + cmd_q.stride_rows[L2_BANK_AW-1:0];
            end

            // Evict counters
            if (state_q == ST_IDLE || state_q == ST_OUTER_ADVANCE) begin
                evict_issued_q   <= '0;
                evict_received_q <= '0;
            end else begin
                if (evict_req_o && evict_gnt_i)
                    evict_issued_q <= evict_issued_q + 20'd1;

                // P7b fix: count actual FIFO captures, not raw rvalid events.
                if (egr_push)
                    evict_received_q <= evict_received_q + 20'd1;
            end
        end
    end

    // =========================================================================
    // Soft_reset + 2D notes:
    //
    // soft_reset: comb override suppresses done_o/fill_req_o/evict_req_o.
    //   Sequential block resets all state including outer_cnt/cur_base_row.
    //
    // 2D backward compat: outer_count=0 or 1 in descriptor → eff_outer=1,
    //   outer_done is immediately true after first inner iteration → 1D.
    //   Existing 1D descriptors (ext_len=1 with word[4]=anything) get
    //   outer_count from word[4][15:0]. If SW doesn't set it, it's likely 0
    //   or small → works correctly (0→1D, 1→1D).
    //
    // MEMSET: OP_DMA_MEMSET writes cmd_q.memset_val to every word address
    //   in the L2 region. No NoC involvement. Useful for zero-init, pattern
    //   fill, scratchpad clearing. 2D stride supported.
    // =========================================================================

endmodule

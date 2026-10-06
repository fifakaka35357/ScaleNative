// =============================================================================
// pe_assertions.sv — SystemVerilog Assertions for PE (v5, Phase 6b)
//
// ⚠ KNOWN GATE GAP ([C-MX STORE ⑦] review F1, 2026-07-11): this file is NOT
//   covered by any CI gate. It is absent from tb/elaborate_smoke.sh and from
//   every cocotb VERILOG_SOURCES list, and Verilator cannot elaborate it even
//   with --bbox-unsup (pre-existing `##[m:n]` cycle-delay ranges and the
//   §10.16c `sequence` blocks are unsupported, e.g. :954). A T39 lint target
//   was attempted and abandoned for this reason. Consequence: changes here are
//   only checked by code review until the file is compiled by an SVA-capable
//   simulator/formal tool. The bind block at the bottom MUST be kept in sync
//   with the port list by hand (the [C-MX ⑦] vec_rw_half_sel/vec_rw_bank_mask
//   pair is connected from pe_top wires :224-225).
//
//   (Round 5B: comprehensive update for P1.1/P5/P6/P10/P13 compatibility)
//   (R1: updated §10.4 for CTX_BLOCKED/DONE/ERROR, auto-promote, doorbell advisory)
//   (R2B: §10.2 $error upgrade, §10.13 ring_cfg range)
//   (R3D: §10.14 ctx_error_isolation, §10.15 poison-never-issued,
//         §10.16 error→clear→recovery flow)
//   (R4.2: §10.12 bounded liveness upgrade, §10.17 credit bounds,
//          §10.18 watchdog, §10.19 credit-state consistency)
//   (R5.4: §10.20 perf counter monotonicity/saturation,
//          §10.21 tens yield fairness — post-Phase-4 renamed, see below)
//   (R7.4/D2: §10.22 DMA 2D strided transfer correctness)
//   (D5/R7.1: §10.23 multi-credit tag consistency)
//   (D7/R7.2: §10.24 event system correctness)
//   (D7/R7.2: §10.24 event system assertions, §10.4 CTX_WAIT_EVENT transitions)
//   (D9/R7.3: §10.25 trace ring assertions)
//
// Phase 6b changes:
//   [PHASE6b-01] Propagate Phase-4 yield rename through this file:
//                  (v4 name)       -> (post-Phase-4 name)
//                  vec_yield_mode  -> tens_yield_mode
//                  vec_quota_n     -> tens_quota_n
//                  vec_consec_cnt  -> tens_consec_cnt
//                  vec_yield       -> tens_yield
//                All four renames apply in three places:
//                  (a) module port declarations at top
//                  (b) §10.21 assertion body (the 5 sva properties)
//                  (c) the bind-connection block at the bottom
//                Semantics: this assertion checks that the Tens yield
//                state machine in l2_rw_arbiter respects the quota_n
//                boundary and resets cleanly when fired. It was named
//                "vec_yield" in v4 because v4 had Vec as the highest-
//                priority master. Post-Phase 3 B2 role swap, Tens is
//                the highest-priority master, and Phase 4 unified the
//                terminology across all files.
//   [PHASE6b-02] No other fixes needed: pe_assertions does not probe
//                L2 data-path widths (so Phase 3 B2 wdata/rdata swap
//                is invisible here); event_wake hierarchical reference
//                at i_cp.i_scheduler.event_wake still works because
//                Phase 4 kept the internal wire alongside the new
//                event_wake_o formal port.
//
// Bind module: attached to pe_top via `bind` statement (see bottom of file).
// Covers all assertion categories from README §10:
//
//   §10.1  Ring Overrun           (P10: uses ring_size_log2)
//   §10.2  L2 Same-Row RO/RW Conflict
//   §10.3  Region Bounds Check
//   §10.4  CP Context Legal Transitions (P13: soft_reset aware)
//   §10.5  Arbiter All-or-Nothing
//   §10.6  Backpressure Stability (P13: soft_reset aware)
//   §10.7  Per-Ctx Slot Consistency (P5/P6: completion-driven lifecycle)
//   §10.8  Descriptor ext_len Bounds (P1.1: new)
//   §10.9  Soft Reset Completeness (P13: new)
//   §10.10 Scoreboard Consistency  (new)
//   §10.11 R1: Slot State Vis Consistency
//   §10.12 R4.2: Bounded Liveness (upgraded from R1 cover → assert)
//   §10.13 R2.3: Ring Configuration Range
//   §10.14 R3D: Context Error Isolation
//   §10.15 R3D: Poison Never Issued to Exec Units
//   §10.16 R3D: Error → Clear → Recovery Flow
//   §10.17 R4.2: Credit Counter Bounds
//   §10.18 R4.2: Watchdog Progress Counter
//   §10.19 R4.2: Credit-State Consistency
//   §10.20 R5.4: Perf Counter Monotonicity & Saturation
//   §10.21 R5.4: Vec Yield Fairness
//   §10.22 R7.4/D2: DMA 2D Strided Transfer Correctness
//   §10.23 D5/R7.1: Multi-Credit Tag Consistency
//   §10.24 D7/R7.2: Event System Correctness
//   §10.25 D9/R7.3: Trace Ring Integrity
//
// Simulation only — all assertions gated by `ifndef SYNTHESIS`.
// =============================================================================

`ifndef SYNTHESIS

module pe_assertions
    import pe_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // ── CP / CSR observability ──
    input logic [RING_PTR_W-1:0]  ring_head  [NUM_CTX],
    input logic [RING_PTR_W-1:0]  ring_tail  [NUM_CTX],
    input logic [3:0]             ring_size_log2 [NUM_CTX],  // P10: per-ctx ring size
    input logic [NUM_CTX-1:0]     doorbell_pulse,
    input ctx_state_e             ctx_state  [NUM_CTX],
    input logic                   cp_enable,
    input logic                   cp_soft_reset,             // P13: soft reset signal
    input logic [NUM_CTX-1:0]     clear_error,               // R3.2c: clear error signal

    // ── Scheduler observability ──
    input logic                   vec_cmd_valid,
    input logic                   tens_cmd_valid,
    input logic                   dma_cmd_valid,
    input logic                   vec_cmd_ready,
    input logic                   tens_cmd_ready,
    input logic                   dma_cmd_ready,

    // ── Execution unit done ──
    input logic                   vec_done,
    input logic [1:0]             vec_done_ctx,
    input logic                   tens_done,
    input logic [1:0]             tens_done_ctx,
    input logic                   dma_done,
    input logic [1:0]             dma_done_ctx,

    // ── L2 RO arbiter observability ──
    input logic                   vec_ro_req,
    input logic                   vec_ro_gnt,
    input logic [L2_BANK_AW-1:0] vec_ro_row,
    // [PHASE3-B2 §10.5-RO FIX, 2026-09-05] vec RO half-select.
    // Post-B2 the vec RO master is NARROW (8 banks), so §10.5's RO arm must
    // judge per half, exactly as its RW twin already does.
    // 🔴 Do NOT reuse vec_rw_half_sel here: vector_unit_top.sv:132-138 drives
    //    BOTH ro_half_sel_o and rw_half_sel_o from the same half_sel_q reg
    //    today, so the wrong bind would be silently correct and would rot on
    //    the first divergence. Bind the RO wire by name.
    input logic                   vec_ro_half_sel,
    input logic                   tens_ro_req,
    input logic                   tens_ro_gnt,
    input logic [L2_BANK_AW-1:0] tens_ro_row,

    // ── L2 RW arbiter observability ──
    input logic                   vec_rw_req,
    input logic                   vec_rw_gnt,
    input logic [L2_BANK_AW-1:0] vec_rw_row,
    // [C-MX STORE ⑦] vec RW half-select + per-bank mask (the vector_unit_top
    // 8-bit half mask): compact-MX payload writes are NARROW (FP4 2 banks /
    // FP8 4 banks), so §10.5 must judge per MASKED bank, not all-or-nothing.
    // Bind site: vector_unit_top.rw_half_sel_o / rw_bank_mask_o (= the
    // l2_rw_arbiter vec_half_sel_i / vec_bank_mask_i inputs).
    input logic                   vec_rw_half_sel,
    input logic [(L2_NUM_BANKS/2)-1:0] vec_rw_bank_mask,
    input logic                   tens_rw_req,
    input logic                   tens_rw_gnt,
    input logic [L2_BANK_AW-1:0] tens_rw_row,
    input logic                   dma_fill_req,
    input logic                   dma_fill_gnt,
    input logic                   dma_evict_req,
    input logic                   dma_evict_gnt,

    // ── Per-bank SRAM signals (from l2_subsystem) ──
    input logic               l2_pa_csb  [L2_NUM_BANKS],
    input logic               l2_pa_web  [L2_NUM_BANKS],
    input logic [L2_BANK_AW-1:0] l2_pa_addr [L2_NUM_BANKS],
    input logic               l2_pb_csb  [L2_NUM_BANKS],
    input logic [L2_BANK_AW-1:0] l2_pb_addr [L2_NUM_BANKS],

    // ── Per-ctx slot state (from command_processor) ──
    input slot_state_e        slot_current_state [NUM_CTX],
    input slot_state_e        slot_next_state    [NUM_CTX],

    // ── Slot lifecycle events (from command_processor) ──
    input logic [NUM_CTX-1:0] fetch_fill_valid,   // fetch completed a descriptor
    input logic [NUM_CTX-1:0] comp_done,          // execution completed for ctx

    // ── Descriptor slot data (for ext_len validation) ──
    input logic [31:0]        slot_current_word0 [NUM_CTX],

    // ── R1: Derived slot state from scheduler ──
    input slot_state_e        slot_state_vis [NUM_CTX],

    // ── R1: Scheduler can_issue (for auto-promote / blocked checks) ──
    input logic [NUM_CTX-1:0] can_issue,

    // ── R3D: Error path observability (from scheduler) ──
    input logic                error_valid,     // pulse: error descriptor consumed
    input logic [CTX_ID_W-1:0] error_ctx,       // which ctx errored
    input err_class_e          error_class,      // err_class for diagnostics
    input logic                issue_ok,         // any successful issue this cycle
    input logic [CTX_ID_W-1:0] issue_ctx,        // which ctx was issued

    // ── R4.2: Credit counter observability (from scheduler) ──
    input logic [SCOREBOARD_CREDIT_W-1:0] vec_credit,
    input logic [SCOREBOARD_CREDIT_W-1:0] tens_credit,
    input logic [SCOREBOARD_CREDIT_W-1:0] dma_credit,

    // ── R4.2: Watchdog observability (from scheduler) ──
    input logic [WD_CNT_W-1:0]  wd_cnt       [NUM_CTX],    // per-ctx counter value
    input logic [NUM_CTX-1:0]   wd_timeout,                  // per-ctx timeout flags
    input logic [WD_CNT_W-1:0]  wd_threshold,                // threshold from CSR

    // ── R5.4: Performance counter observability (from scheduler) ──
    input logic [PERF_CNT_W-1:0] perf_ctx_blocked [NUM_CTX],
    input logic [PERF_CNT_W-1:0] perf_ctx_barrier [NUM_CTX],
    input logic [PERF_CNT_W-1:0] perf_ctx_starved [NUM_CTX],
    input logic [PERF_CNT_W-1:0] perf_total_issue,
    input logic [PERF_CNT_W-1:0] perf_total_done,

    // ── R5.4: L2 perf counter observability (from l2_rw_arbiter) ──
    input logic [PERF_CNT_W-1:0] perf_l2_conflict,
    input logic [9:0]            perf_l2_vec_stall,
    input logic [9:0]            perf_l2_tens_stall,
    input logic [9:0]            perf_l2_dma_stall,

    // ── R5.4: Yield observability (from l2_rw_arbiter) ──
    input logic                  perf_cnt_en,
    input logic [1:0]            tens_yield_mode,
    input logic [3:0]            tens_quota_n,
    input logic [3:0]            tens_consec_cnt,
    input logic                  tens_yield,

    // ── R7.4/D2: DMA 2D observability (from dma_engine) ──
    input logic [2:0]            dma_state,           // dma_state_e encoded
    input logic [19:0]           dma_wcount,           // inner word counter
    input logic [15:0]           dma_outer_cnt,        // current outer iteration
    input logic [15:0]           dma_eff_outer_count,  // effective outer count
    input logic [L2_BANK_AW-1:0] dma_cur_base_row,    // current base row
    input logic                  dma_inner_done,       // inner loop complete
    input logic                  dma_outer_done,       // all outer loops complete
    input dma_cmd_t              dma_cmd_q,            // latched command
    input logic                  noc_ing_ready,        // for memset no-NoC check

    // ── D5/R7.1: Multi-credit tag observability (from scheduler) ──
    input logic [TAG_MAX-1:0]    vec_tag_valid,        // per-tag inflight bitmap
    input logic [TAG_MAX-1:0]    tens_tag_valid,
    input logic [TAG_MAX-1:0]    dma_tag_valid,
    input logic [CTX_ID_W-1:0]  vec_tag_ctx  [TAG_MAX], // tag→ctx mapping
    input logic [CTX_ID_W-1:0]  tens_tag_ctx [TAG_MAX],
    input logic [CTX_ID_W-1:0]  dma_tag_ctx  [TAG_MAX],
    input logic [TAG_W-1:0]     vec_done_tag,          // returned tag on done
    input logic [TAG_W-1:0]     tens_done_tag,
    input logic [TAG_W-1:0]     dma_done_tag,

    // D7/R7.2: Event system observability (from scheduler)
    input logic [EVT_W-1:0]     event_pending [NUM_CTX],  // sticky event accumulator
    input logic [EVT_W-1:0]     wait_mask     [NUM_CTX],  // stored OP_WAIT mask
    input logic [NUM_CTX-1:0]   event_wake,               // per-ctx wake signal
    input logic [NUM_CTX-1:0]   event_clear,              // per-ctx SW clear pulse
    input logic [7:0]           sel_opcode_raw,           // scheduler sel_opcode for WAIT check

    // ── D9/R7.3: Trace ring observability (from event_trace_ring) ──
    input logic [TRACE_AW-1:0] trace_wr_ptr,
    input logic                trace_overflow,
    input logic [TRACE_AW:0]   trace_count,
    input logic                trace_valid,              // event collector output
    input logic                trace_enable,             // TRACE_CTRL.enable
    input logic                trace_freeze,             // TRACE_CTRL.freeze
    input logic                trace_clear               // TRACE_CTRL.clear pulse
);

    // =========================================================================
    // §10.1 Ring Overrun
    //
    // On doorbell write, verify that new tail doesn't collide with head.
    // P10: uses ring_size_log2 to compute per-ctx ring mask (power-of-2).
    // =========================================================================
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_ring_overrun

            logic [RING_PTR_W-1:0] ring_mask;
            assign ring_mask = (RING_PTR_W'(1) << ring_size_log2[ctx])
                             - RING_PTR_W'(1);

            // Masked head: only valid bits within ring size
            logic [RING_PTR_W-1:0] head_masked, tail_masked;
            assign head_masked = ring_head[ctx] & ring_mask;
            assign tail_masked = ring_tail[ctx] & ring_mask;

            // Ring full: next tail position would equal head
            // (tail wrapped by ring_mask would collide with head)
            property ring_no_overrun;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                doorbell_pulse[ctx] |->
                    (tail_masked != ((head_masked - RING_PTR_W'(1)) & ring_mask));
            endproperty

            a_ring_no_overrun: assert property (ring_no_overrun)
                else $error("[PE_ASSERT §10.1] CTX%0d ring overrun: tail=%0d head=%0d (mask=0x%0h)",
                            ctx, ring_tail[ctx], ring_head[ctx], ring_mask);
        end
    endgenerate

    // =========================================================================
    // §10.2 L2 Same-Row RO/RW Write Conflict
    //
    // Per-bank: if both Port 0 (RW, write) and Port 1 (RO) are active,
    // they must NOT address the same row. (Same-row read+write on
    // different ports of 1RW1R SRAM is undefined behavior in sky130.)
    // =========================================================================
    generate
        for (genvar bi = 0; bi < L2_NUM_BANKS; bi++) begin : gen_l2_conflict

            logic ro_active, rw_write_active;
            assign ro_active       = ~l2_pb_csb[bi];                // Port 1 active
            assign rw_write_active = ~l2_pa_csb[bi] & ~l2_pa_web[bi]; // Port 0 write

            property no_same_row_rw_conflict;
                @(posedge clk_i) disable iff (!rst_ni)
                (ro_active && rw_write_active) |->
                    (l2_pb_addr[bi] != l2_pa_addr[bi]);
            endproperty

            a_no_rw_conflict: assert property (no_same_row_rw_conflict)
                else $error("[PE_ASSERT §10.2] L2 Bank %0d: RO read @row %0d vs RW write @row %0d — same-row conflict (undefined behavior in sky130 1RW1R)!",
                              bi, l2_pb_addr[bi], l2_pa_addr[bi]);
        end
    endgenerate

    // =========================================================================
    // §10.3 Region Bounds Check
    //
    // On command issue (valid & ready), verify that the physical row
    // derived from the command is within L2 total capacity.
    // =========================================================================
    localparam int L2_MAX_ROW = (1 << L2_BANK_AW);
    // 🔴🔴 [2026-09-01 修错断言] 三处边界比较原写 `L2_MAX_ROW[L2_BANK_AW-1:0]` ——
    //   L2_MAX_ROW = 1<<9 = 512，取低 9 位 **恒为 0** ⇒ 比较坍缩成 `row < 0`
    //   ⇒ 这三条断言在【每一次合法访问】上都必红。实测：本文件 2026-09-01 首次进入
    //   编译面后立刻触发 `a_tens_ro_bounds`，报文逐字「Tens RO row **0** out of L2 range」
    //   —— row 0 越界，这个报文本身就是判据自证。
    //   ⇒ 按在盘修法 `(W+1)'(BOUND)` 加宽到 L2_BANK_AW+1 位，让 512 放得下。
    //   🔴 **改的是断言，不是 RTL**（`不许改 RTL 去迁就断言`）。同族三处一起改：
    //      a_vec_ro_bounds · a_vec_rw_bounds · a_tens_ro_bounds

    property vec_ro_row_in_bounds;
        @(posedge clk_i) disable iff (!rst_ni)
        (vec_ro_req && vec_ro_gnt) |->
            (vec_ro_row < (L2_BANK_AW+1)'(L2_MAX_ROW));
    endproperty
    a_vec_ro_bounds: assert property (vec_ro_row_in_bounds)
        else $error("[PE_ASSERT §10.3] Vec RO row %0d out of L2 range", vec_ro_row);

    property vec_rw_row_in_bounds;
        @(posedge clk_i) disable iff (!rst_ni)
        (vec_rw_req && vec_rw_gnt) |->
            (vec_rw_row < (L2_BANK_AW+1)'(L2_MAX_ROW));
    endproperty
    a_vec_rw_bounds: assert property (vec_rw_row_in_bounds)
        else $error("[PE_ASSERT §10.3] Vec RW row %0d out of L2 range", vec_rw_row);

    property tens_ro_row_in_bounds;
        @(posedge clk_i) disable iff (!rst_ni)
        (tens_ro_req && tens_ro_gnt) |->
            (tens_ro_row < (L2_BANK_AW+1)'(L2_MAX_ROW));
    endproperty
    a_tens_ro_bounds: assert property (tens_ro_row_in_bounds)
        else $error("[PE_ASSERT §10.3] Tens RO row %0d out of L2 range", tens_ro_row);

    // =========================================================================
    // §10.4 CP Context Legal Transitions
    //
    // R1 updates:
    //   - WAIT_VEC/TENS/DMA can exit to CTX_ERROR (R3/R4 watchdog)
    //   - IDLE can exit via doorbell OR auto-promote (slot non-empty)
    //   - Added: doorbell_after_enable advisory warning (R1.3)
    //
    // P13: soft_reset is a valid reason to leave any state.
    // =========================================================================
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_ctx_transition

            // WAIT_VEC → !WAIT_VEC requires vec_done(matching) OR soft_reset
            // R1 forward-compat: also allow transition to CTX_ERROR (R3/R4)
            property wait_vec_correct_wakeup;
                @(posedge clk_i) disable iff (!rst_ni)
                ($past(ctx_state[ctx]) == CTX_WAIT_VEC) &&
                (ctx_state[ctx] != CTX_WAIT_VEC)
                |->
                ($past(vec_done) && $past(vec_done_ctx) == ctx[1:0]) ||
                $past(cp_soft_reset) ||
                (ctx_state[ctx] == CTX_ERROR);  // R1: forward-compat for R3/R4
            endproperty
            a_wait_vec_wakeup: assert property (wait_vec_correct_wakeup)
                else $error("[PE_ASSERT §10.4] CTX%0d left WAIT_VEC without vec_done, soft_reset, or ERROR", ctx);

            property wait_tens_correct_wakeup;
                @(posedge clk_i) disable iff (!rst_ni)
                ($past(ctx_state[ctx]) == CTX_WAIT_TENS) &&
                (ctx_state[ctx] != CTX_WAIT_TENS)
                |->
                ($past(tens_done) && $past(tens_done_ctx) == ctx[1:0]) ||
                $past(cp_soft_reset) ||
                (ctx_state[ctx] == CTX_ERROR);
            endproperty
            a_wait_tens_wakeup: assert property (wait_tens_correct_wakeup)
                else $error("[PE_ASSERT §10.4] CTX%0d left WAIT_TENS without tens_done, soft_reset, or ERROR", ctx);

            property wait_dma_correct_wakeup;
                @(posedge clk_i) disable iff (!rst_ni)
                ($past(ctx_state[ctx]) == CTX_WAIT_DMA) &&
                (ctx_state[ctx] != CTX_WAIT_DMA)
                |->
                ($past(dma_done) && $past(dma_done_ctx) == ctx[1:0]) ||
                $past(cp_soft_reset) ||
                (ctx_state[ctx] == CTX_ERROR);
            endproperty
            a_wait_dma_wakeup: assert property (wait_dma_correct_wakeup)
                else $error("[PE_ASSERT §10.4] CTX%0d left WAIT_DMA without dma_done, soft_reset, or ERROR", ctx);

            // R1: IDLE can transition via doorbell OR auto-promote (slot non-empty)
            property idle_needs_doorbell_or_slot;
                @(posedge clk_i) disable iff (!rst_ni)
                ($past(ctx_state[ctx]) == CTX_IDLE) &&
                (ctx_state[ctx] != CTX_IDLE)
                |->
                $past(doorbell_pulse[ctx]) ||
                ($past(slot_current_state[ctx]) != SLOT_EMPTY) ||
                ($past(slot_next_state[ctx]) != SLOT_EMPTY);
            endproperty
            a_idle_exit: assert property (idle_needs_doorbell_or_slot)
                else $error("[PE_ASSERT §10.4] CTX%0d left IDLE without doorbell or slot data", ctx);

            // R1.3: Advisory — doorbell before enable is handled by auto-promote
            // but is still unusual driver behavior worth flagging
            property doorbell_after_enable;
                @(posedge clk_i) disable iff (!rst_ni)
                doorbell_pulse[ctx] |-> cp_enable;
            endproperty
            a_doorbell_enable: assert property (doorbell_after_enable)
                else $warning("[PE_ASSERT R1.3] CTX%0d: doorbell before enable, auto-promote will handle", ctx);

            // R3.2c: CTX_ERROR can exit via soft_reset OR CLEAR_ERROR
            property error_exit_valid;
                @(posedge clk_i) disable iff (!rst_ni)
                ($past(ctx_state[ctx]) == CTX_ERROR) &&
                (ctx_state[ctx] != CTX_ERROR)
                |->
                $past(cp_soft_reset) || $past(clear_error[ctx]);
            endproperty
            a_error_exit: assert property (error_exit_valid)
                else $error("[PE_ASSERT §10.4] CTX%0d left CTX_ERROR without soft_reset or clear_error", ctx);

            // D7: CTX_WAIT_EVENT → !CTX_WAIT_EVENT requires event_wake OR soft_reset OR error
            property wait_event_correct_wakeup;
                @(posedge clk_i) disable iff (!rst_ni)
                ($past(ctx_state[ctx]) == CTX_WAIT_EVENT) &&
                (ctx_state[ctx] != CTX_WAIT_EVENT)
                |->
                $past(event_wake[ctx]) ||
                $past(cp_soft_reset) ||
                (ctx_state[ctx] == CTX_ERROR);
            endproperty
            a_wait_event_wakeup: assert property (wait_event_correct_wakeup)
                else $error("[PE_ASSERT §10.4] CTX%0d left CTX_WAIT_EVENT without event_wake, soft_reset, or ERROR", ctx);

        end
    endgenerate

    // =========================================================================
    // §10.5 Arbiter Half-Stripe Exactness (RO)
    //
    // [PHASE3-B2 §10.5-RO FIX, 2026-09-05]
    // The old text read "When vec_ro_gnt is asserted, ALL 16 banks' Port 1
    // must be active." That is the v4 role model, in which Vec was the WIDE
    // master. Phase3-B2 swapped the roles (l2_ro_arbiter.sv:5-24, :87-99):
    // Tens became the wide 16-bank master and Vec the NARROW 8-bank master
    // selected by vec_half_sel_i. Since vec_all_win = vec_req_i & ~tens_req_i
    // (:147), a vec grant implies tens_hit == '0 (:87), so the unselected half
    // has no winner and falls to pb_csb_o[i] = 1'b1 (:167). The old form was
    // therefore STRUCTURALLY UNSATISFIABLE for 8 of its 16 instances on every
    // vec RO grant -- it could only ever pass vacuously.
    //
    // The RW twin below was already corrected to be half- and mask-aware under
    // [C-MX STORE (7)]; the RO arm was left behind and stayed broken because no
    // pe_top bench dispatched a Vector command until test_fastlane_duty.py, so
    // vec_ro_gnt was never high and the arm never evaluated non-vacuously.
    // It fired on its first ever exposure (2026-09-05), exactly as predicted by
    // backlog #55(2) (PROJECT_RULES.md:1556) -- this is #55(2)'s runtime
    // confirmation, NOT a new finding. The fix is to the ASSERTION, not the RTL.
    // git evidence: `git log -S vec_grant_activates_bank` = ONE commit (6a0fd06,
    // 2026-06-14 baseline), never edited since; at that same commit
    // l2_ro_arbiter.sv is already byte-for-byte the post-B2 Vec-narrow form.
    // So the assertion entered version control already contradicting the RTL
    // beside it. The RW twin was rewritten later, in 37bcca0 (2026-07-18).
    //
    // Two arms, which together pin all 16 banks (strictly STRONGER than the old
    // form, which pinned none because it could never hold):
    //   (a) SELECTED   half -> bank MUST be active     (pb_csb == 0)
    //   (b) UNSELECTED half -> bank MUST be deselected (pb_csb == 1)
    // No mask term: unlike l2_rw_arbiter (vec_bank_mask_i), l2_ro_arbiter has
    // no per-bank mask at all (grep 'mask' in that file: zero hits) -- its whole
    // selected half always fires.
    // =========================================================================

    generate
        for (genvar bi = 0; bi < L2_NUM_BANKS; bi++) begin : gen_vec_all_or_nothing
            localparam bit BI_HI = (bi >= L2_NUM_BANKS/2);

            // (a) selected half must be ACTIVE
            property vec_grant_activates_bank;
                @(posedge clk_i) disable iff (!rst_ni)
                (vec_ro_gnt && (vec_ro_half_sel == BI_HI)) |-> (~l2_pb_csb[bi]);
            endproperty
            a_vec_all_bank: assert property (vec_grant_activates_bank)
                else $error("[PE_ASSERT §10.5] Vec RO granted (half_sel=%0d) but selected bank %0d not activated",
                            vec_ro_half_sel, bi);

            // (b) unselected half must be DESELECTED -- recovers the coverage
            //     arm (a) would otherwise drop, and doubles as a MIS-BIND
            //     detector for vec_ro_half_sel: tb/Makefile carries a global
            //     -Wno-PINMISSING, so an unbound input would read constant 0
            //     with NO diagnostic and make arm (a) vacuous for bi=8..15 --
            //     silently deleting the very instance that just fired.
            property vec_grant_deselects_other_half;
                @(posedge clk_i) disable iff (!rst_ni)
                (vec_ro_gnt && (vec_ro_half_sel != BI_HI)) |-> (l2_pb_csb[bi]);
            endproperty
            a_vec_other_half_idle: assert property (vec_grant_deselects_other_half)
                else $error("[PE_ASSERT §10.5] Vec RO granted (half_sel=%0d) but off-half bank %0d is active",
                            vec_ro_half_sel, bi);
        end
    endgenerate

    // Vec RW: mask-aware bank activation on grant.
    // [C-MX STORE ⑦] The vec RW master is a HALF-stripe master with a per-bank
    // mask, and the compact-MX store legitimately writes narrow masks (FP4
    // 8'h03 / FP8 8'h0F). The old all-or-nothing form (grant -> ALL 16 banks
    // active) is therefore wrong on two counts: it ignored the half select and
    // it required unmasked banks. New form: granted -> every MASKED bank of
    // the SELECTED half must be active; unmasked banks are unconstrained
    // (bank-hole reuse by DMA is legal and desirable).
    generate
        for (genvar bi = 0; bi < L2_NUM_BANKS; bi++) begin : gen_vec_rw_all_or_nothing
            localparam bit BI_HI      = (bi >= L2_NUM_BANKS/2);
            localparam int BI_IN_HALF = BI_HI ? (bi - L2_NUM_BANKS/2) : bi;

            property vec_rw_grant_activates_bank;
                @(posedge clk_i) disable iff (!rst_ni)
                (vec_rw_gnt && (vec_rw_half_sel == BI_HI)
                            && vec_rw_bank_mask[BI_IN_HALF]) |-> (~l2_pa_csb[bi]);
            endproperty
            a_vec_rw_all_bank: assert property (vec_rw_grant_activates_bank)
                else $error("[PE_ASSERT §10.5] Vec RW granted but masked bank %0d not activated", bi);
        end
    endgenerate

    // =========================================================================
    // §10.6 Backpressure Stability
    //
    // When a master asserts req and doesn't get gnt, req must remain
    // asserted next cycle (no req withdrawal before grant).
    //
    // P13: soft_reset is allowed to withdraw requests mid-flight.
    // =========================================================================

    // Vec RO
    property stable_vec_ro_req;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_ro_req && !vec_ro_gnt) |=> vec_ro_req;
    endproperty
    a_stable_vec_ro: assert property (stable_vec_ro_req)
        else $error("[PE_ASSERT §10.6] vec_ro_req withdrawn before grant");

    // Vec RW
    property stable_vec_rw_req;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_rw_req && !vec_rw_gnt) |=> vec_rw_req;
    endproperty
    a_stable_vec_rw: assert property (stable_vec_rw_req)
        else $error("[PE_ASSERT §10.6] vec_rw_req withdrawn before grant");

    // Tens RO
    property stable_tens_ro_req;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_ro_req && !tens_ro_gnt) |=> tens_ro_req;
    endproperty
    a_stable_tens_ro: assert property (stable_tens_ro_req)
        else $error("[PE_ASSERT §10.6] tens_ro_req withdrawn before grant");

    // Tens RW
    property stable_tens_rw_req;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_rw_req && !tens_rw_gnt) |=> tens_rw_req;
    endproperty
    a_stable_tens_rw: assert property (stable_tens_rw_req)
        else $error("[PE_ASSERT §10.6] tens_rw_req withdrawn before grant");

    // DMA Fill
    property stable_dma_fill_req;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_fill_req && !dma_fill_gnt) |=> dma_fill_req;
    endproperty
    a_stable_dma_fill: assert property (stable_dma_fill_req)
        else $error("[PE_ASSERT §10.6] dma_fill_req withdrawn before grant");

    // DMA Evict
    property stable_dma_evict_req;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_evict_req && !dma_evict_gnt) |=> dma_evict_req;
    endproperty
    a_stable_dma_evict: assert property (stable_dma_evict_req)
        else $error("[PE_ASSERT §10.6] dma_evict_req withdrawn before grant");

    // CP command valid/ready stability
    property stable_vec_cmd_valid;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_cmd_valid && !vec_cmd_ready) |=> vec_cmd_valid;
    endproperty
    a_stable_vec_cmd: assert property (stable_vec_cmd_valid)
        else $error("[PE_ASSERT §10.6] vec_cmd_valid withdrawn before ready");

    property stable_tens_cmd_valid;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_cmd_valid && !tens_cmd_ready) |=> tens_cmd_valid;
    endproperty
    a_stable_tens_cmd: assert property (stable_tens_cmd_valid)
        else $error("[PE_ASSERT §10.6] tens_cmd_valid withdrawn before ready");

    property stable_dma_cmd_valid;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_cmd_valid && !dma_cmd_ready) |=> dma_cmd_valid;
    endproperty
    a_stable_dma_cmd: assert property (stable_dma_cmd_valid)
        else $error("[PE_ASSERT §10.6] dma_cmd_valid withdrawn before ready");

    // =========================================================================
    // §10.7 Per-Ctx Slot Consistency (Completion-Driven Lifecycle)
    //
    // Round 1 redesign: promote is now driven by comp_done, not sched_consume.
    //
    //   fetch_fill_valid[i] → fills current (if EMPTY) or next (if current
    //                         occupied). Cannot overwrite a non-EMPTY slot.
    //   comp_done[i]        → reads current's flags, then promotes next→current
    //                         or clears current. Requires current != EMPTY.
    //
    // Key invariant: fetch_fill and comp_done for the same ctx should not
    // both attempt to write current in the same cycle. The RTL handles this
    // with a two-step combinational priority (comp_done first, then fetch_fill
    // checks the updated state), but we assert the structural precondition.
    // =========================================================================
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_slot_consistency

            // §10.7.1: comp_done requires current is occupied
            // (you can't complete a descriptor that doesn't exist)
            property comp_done_requires_current;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                comp_done[ctx] |->
                    (slot_current_state[ctx] != SLOT_EMPTY);
            endproperty
            a_comp_done_current: assert property (comp_done_requires_current)
                else $error("[PE_ASSERT §10.7] CTX%0d comp_done fired but current is EMPTY", ctx);

            // §10.7.2: fetch_fill cannot overwrite a VALID next slot
            // (fetch should only target EMPTY slots; double-fill is a bug)
            property no_next_overwrite;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                fetch_fill_valid[ctx] |->
                    // Either current was EMPTY (fill goes to current) or
                    // next was EMPTY (fill goes to next).
                    // After comp_done priority: use the "nxt" state in the RTL,
                    // but from the assertion's view, at least one slot must
                    // have room. Simplified: next must be EMPTY unless current
                    // is also EMPTY (in which case fill targets current).
                    (slot_current_state[ctx] == SLOT_EMPTY) ||
                    (slot_next_state[ctx] == SLOT_EMPTY);
            endproperty
            a_no_next_overwrite: assert property (no_next_overwrite)
                else $error("[PE_ASSERT §10.7] CTX%0d fetch_fill but both slots occupied", ctx);

            // §10.7.3: slot_next can only become VALID from EMPTY
            // (no direct VALID→VALID transition without going through EMPTY)
            property next_fill_from_empty;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (slot_next_state[ctx] == SLOT_VALID) &&
                ($past(slot_next_state[ctx]) != SLOT_VALID)
                |->
                ($past(slot_next_state[ctx]) == SLOT_EMPTY);
            endproperty
            a_next_from_empty: assert property (next_fill_from_empty)
                else $error("[PE_ASSERT §10.7] CTX%0d next became VALID from non-EMPTY state", ctx);

        end
    endgenerate

    // =========================================================================
    // §10.8 Descriptor ext_len Bounds Check (P1.1)
    //
    // When a descriptor is in current slot (VALID state), its ext_len
    // field (word0[11:8]) must not exceed DESC_MAX_EXT (= 4 in v4).
    // =========================================================================
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_ext_len_check

            logic [3:0] current_ext_len;
            assign current_ext_len = slot_current_word0[ctx][11:8];

            property ext_len_in_bounds;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (slot_current_state[ctx] == SLOT_VALID) |->
                    (current_ext_len <= DESC_MAX_EXT[3:0]);
            endproperty

            a_ext_len_bounds: assert property (ext_len_in_bounds)
                else $error("[PE_ASSERT §10.8] CTX%0d ext_len=%0d exceeds DESC_MAX_EXT=%0d",
                            ctx, current_ext_len, DESC_MAX_EXT);
        end
    endgenerate

    // =========================================================================
    // §10.9 Soft Reset Completeness (P13)
    //
    // One cycle after soft_reset asserts, all slot states must be EMPTY
    // and all ctx_states must be IDLE.
    // =========================================================================

    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_soft_reset_check

            property soft_reset_clears_slots;
                @(posedge clk_i) disable iff (!rst_ni)
                cp_soft_reset |=>
                    (slot_current_state[ctx] == SLOT_EMPTY) &&
                    (slot_next_state[ctx] == SLOT_EMPTY);
            endproperty
            a_soft_reset_slots: assert property (soft_reset_clears_slots)
                else $error("[PE_ASSERT §10.9] CTX%0d slots not cleared 1 cycle after soft_reset", ctx);

            property soft_reset_clears_ctx;
                @(posedge clk_i) disable iff (!rst_ni)
                cp_soft_reset |=>
                    (ctx_state[ctx] == CTX_IDLE);
            endproperty
            a_soft_reset_ctx: assert property (soft_reset_clears_ctx)
                else $error("[PE_ASSERT §10.9] CTX%0d ctx_state not IDLE 1 cycle after soft_reset", ctx);

        end
    endgenerate

    // =========================================================================
    // §10.10 Scoreboard Consistency
    //
    // If vec_busy is asserted in the scheduler, at least one ctx should
    // be in WAIT_VEC. Similarly for tens and dma. This is a soft check
    // (warning, not error) because there may be 1-cycle transient windows.
    // =========================================================================

    // These require access to scheduler internals (vec_busy_q etc.).
    // Since the bind already reaches into i_cp, we can observe ctx_state
    // and check the converse: if any ctx is in WAIT_VEC, at least one
    // execution unit should be busy (no "phantom wait").

    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_scoreboard_check

            // If a ctx has been in WAIT_VEC for 2+ cycles, vec should not
            // have produced done for this ctx without the state changing.
            // (This catches "stuck in WAIT" bugs.)
            // Liveness: eventually, the WAIT state should resolve.
            // Using a generous bound for simulation (4096 cycles).
            property wait_vec_eventually_resolves;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (ctx_state[ctx] == CTX_WAIT_VEC) |->
                    ##[1:4096] (ctx_state[ctx] != CTX_WAIT_VEC);
            endproperty
            // Note: not asserted in formal — use as cover in simulation
            c_wait_vec_liveness: cover property (wait_vec_eventually_resolves);

            property wait_tens_eventually_resolves;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (ctx_state[ctx] == CTX_WAIT_TENS) |->
                    ##[1:4096] (ctx_state[ctx] != CTX_WAIT_TENS);
            endproperty
            c_wait_tens_liveness: cover property (wait_tens_eventually_resolves);

            property wait_dma_eventually_resolves;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (ctx_state[ctx] == CTX_WAIT_DMA) |->
                    ##[1:4096] (ctx_state[ctx] != CTX_WAIT_DMA);
            endproperty
            c_wait_dma_liveness: cover property (wait_dma_eventually_resolves);

        end
    endgenerate

    // =========================================================================
    // §10.11 R1: Slot State Vis Consistency
    //
    // The derived slot_state_vis must be consistent with can_issue:
    //   SLOT_READY  → can_issue must be true
    //   SLOT_BLOCKED + ctx active → can_issue must be false
    // =========================================================================
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_slot_vis_check

            property vis_ready_implies_can_issue;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (slot_state_vis[ctx] == SLOT_READY) |-> can_issue[ctx];
            endproperty
            a_vis_ready: assert property (vis_ready_implies_can_issue)
                else $error("[PE_ASSERT §10.11] CTX%0d slot_state_vis=READY but can_issue=0", ctx);

            property vis_blocked_implies_no_issue;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (slot_state_vis[ctx] == SLOT_BLOCKED) |-> !can_issue[ctx];
            endproperty
            a_vis_blocked: assert property (vis_blocked_implies_no_issue)
                else $error("[PE_ASSERT §10.11] CTX%0d slot_state_vis=BLOCKED but can_issue=1", ctx);

        end
    endgenerate

    // =========================================================================
    // §10.12 R4.2: Bounded Liveness (upgraded from R1 cover → assert)
    //
    // If any ctx has can_issue=1 and CP is enabled, an issue MUST occur
    // within NUM_CTX cycles (RR worst-case full scan). If it doesn't,
    // there's a logic bug in the RR or issue path.
    //
    // The check uses issue_ok (covers all issue types including NOP/BARRIER/
    // error) rather than cmd_valid&ready (which misses immediate-done ops).
    //
    // Consequent allows can_issue to drop (ctx lost eligibility due to
    // resource change or another ctx consuming the resource first).
    // =========================================================================
    property bounded_liveness;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (|can_issue && cp_enable) |->
            ##[0:NUM_CTX] (issue_ok || !(|can_issue));
    endproperty
    a_bounded_liveness: assert property (bounded_liveness)
        else $error("[PE_ASSERT §10.12] Liveness violation: can_issue asserted for >%0d cycles without issue",
                    NUM_CTX);

    // =========================================================================
    // §10.13 R2.3: Ring Configuration Range
    //
    // After cp_csr clamping, ring_size_log2 must be in [RING_CFG_MIN..RING_CFG_MAX].
    // If it isn't, the clamping logic is broken.
    // =========================================================================
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_ring_cfg_check
            property ring_cfg_in_range;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                ring_size_log2[ctx] >= RING_CFG_MIN &&
                ring_size_log2[ctx] <= RING_CFG_MAX;
            endproperty
            a_ring_cfg_range: assert property (ring_cfg_in_range)
                else $error("[PE_ASSERT §10.13] CTX%0d ring_size_log2=%0d out of [%0d..%0d]",
                           ctx, ring_size_log2[ctx], RING_CFG_MIN, RING_CFG_MAX);
        end
    endgenerate

    // =========================================================================
    // Additional Liveness / Sanity Checks
    // =========================================================================

    // Scoreboard mutual exclusion: at most one command issued per cycle
    property at_most_one_issue;
        @(posedge clk_i) disable iff (!rst_ni)
        $onehot0({vec_cmd_valid & vec_cmd_ready,
                  tens_cmd_valid & tens_cmd_ready,
                  dma_cmd_valid & dma_cmd_ready});
    endproperty
    a_one_issue: assert property (at_most_one_issue)
        else $error("[PE_ASSERT extra] Multiple commands issued in same cycle");

    // Done signals: at most one done per cycle
    // (single-outstanding per unit, but catches bugs)
    property at_most_one_done;
        @(posedge clk_i) disable iff (!rst_ni)
        $onehot0({vec_done, tens_done, dma_done});
    endproperty
    a_one_done: assert property (at_most_one_done)
        else $warning("[PE_ASSERT extra] Multiple done signals in same cycle");

    // No done signal during soft_reset (exec units should suppress done)
    property no_done_during_soft_reset;
        @(posedge clk_i) disable iff (!rst_ni)
        cp_soft_reset |-> !(vec_done || tens_done || dma_done);
    endproperty
    a_no_done_reset: assert property (no_done_during_soft_reset)
        else $error("[PE_ASSERT extra] Done signal asserted during soft_reset");

    // =========================================================================
    // §10.14 R3D: Context Error Isolation
    //
    // CTX_ERROR in ctx[i] must NOT prevent ctx[j] (j≠i) from issuing.
    // If ctx[j] has can_issue=1 and CP is enabled, the presence of
    // CTX_ERROR in other contexts must not block ctx[j]'s issue path.
    //
    // Implementation: for each ctx pair (i,j), if ctx[i] is in CTX_ERROR
    // and ctx[j] has can_issue=1, then ctx[j] must successfully issue
    // within NUM_CTX cycles (RR worst-case). This is a stronger variant
    // of §10.12 (HOL blocking) specifically targeting error isolation.
    // =========================================================================
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_error_iso
            for (genvar j = 0; j < NUM_CTX; j++) begin : gen_error_iso_pair
                if (i != j) begin : gen_cross_pair

                    // Liveness: ctx[j] can_issue must not be starved by ctx[i] ERROR
                    property error_does_not_block_other;
                        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                        (ctx_state[i] == CTX_ERROR && can_issue[j] && cp_enable) |->
                            ##[0:NUM_CTX] (issue_ok && issue_ctx == j[CTX_ID_W-1:0])
                            or
                            ##[0:NUM_CTX] (!can_issue[j]);  // lost eligibility (resource freed elsewhere)
                    endproperty
                    a_error_iso: assert property (error_does_not_block_other)
                        else $error("[PE_ASSERT §10.14] CTX%0d in ERROR blocks CTX%0d issue", i, j);

                end
            end
        end
    endgenerate

    // Safety: CTX_ERROR ctx must not have can_issue=1
    // (scheduler should never select a CTX_ERROR ctx for issue)
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_error_no_issue
            property error_ctx_not_issuable;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                ctx_state[ctx] == CTX_ERROR |-> !can_issue[ctx];
            endproperty
            a_error_no_issue: assert property (error_ctx_not_issuable)
                else $error("[PE_ASSERT §10.14] CTX%0d in CTX_ERROR but can_issue=1", ctx);
        end
    endgenerate

    // =========================================================================
    // §10.15 R3D: Poison Never Issued to Execution Units
    //
    // A poisoned descriptor must NEVER result in a valid command to any
    // execution unit. The scheduler's is_error_sel guard must prevent
    // vec/tens/dma_cmd_valid from asserting on poisoned descriptors.
    //
    // Check: if error_valid fires (meaning an error desc was consumed),
    // no exec unit cmd_valid should be asserted in the same cycle.
    // =========================================================================
    property poison_never_dispatched;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        error_valid |->
            !(vec_cmd_valid || tens_cmd_valid || dma_cmd_valid);
    endproperty
    a_poison_no_dispatch: assert property (poison_never_dispatched)
        else $error("[PE_ASSERT §10.15] Error descriptor dispatched to exec unit (cmd_valid high during error_valid)");

    // Stronger variant: error_valid must imply issue_ok (error desc was consumed)
    property error_implies_issue;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        error_valid |-> issue_ok;
    endproperty
    a_error_implies_issue: assert property (error_implies_issue)
        else $error("[PE_ASSERT §10.15] error_valid asserted without issue_ok");

    // error_valid must imply CTX_ERROR on next cycle
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_error_to_ctx_error
            property error_causes_ctx_error;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (error_valid && error_ctx == ctx[CTX_ID_W-1:0]) |=>
                    ctx_state[ctx] == CTX_ERROR;
            endproperty
            a_error_to_ctx_error: assert property (error_causes_ctx_error)
                else $error("[PE_ASSERT §10.15] CTX%0d: error_valid fired but CTX_ERROR not entered", ctx);
        end
    endgenerate

    // =========================================================================
    // §10.16 R3D: Error → Clear → Recovery Flow
    //
    // Verifies the full SW recovery sequence:
    //   1. error_valid → CTX_ERROR (checked in §10.15)
    //   2. CTX_ERROR is sticky (doesn't spontaneously clear)
    //   3. clear_error[i] while CTX_ERROR → CTX_IDLE (checked in §10.4)
    //   4. After CTX_IDLE, doorbell can re-arm → CTX_RUNNABLE
    //
    // §10.16a: CTX_ERROR stickiness — must not leave without clear_error or reset
    //   (Already covered by §10.4 error_exit_valid, but add explicit cover)
    //
    // §10.16b: clear_error only effective in CTX_ERROR
    //   (clear_error while not in CTX_ERROR is harmless but shouldn't cause
    //    unexpected transitions)
    //
    // §10.16c: Full recovery cover — exercises the complete bring-up path
    // =========================================================================

    // §10.16a: CTX_ERROR stickiness (no spurious exit)
    // Note: this overlaps with §10.4 error_exit_valid but provides a
    // cleaner error message specific to the sticky-error contract.
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_error_sticky
            property error_is_sticky;
                @(posedge clk_i) disable iff (!rst_ni)
                (ctx_state[ctx] == CTX_ERROR) &&
                !clear_error[ctx] && !cp_soft_reset
                |=>
                ctx_state[ctx] == CTX_ERROR;
            endproperty
            a_error_sticky: assert property (error_is_sticky)
                else $error("[PE_ASSERT §10.16a] CTX%0d: CTX_ERROR cleared without clear_error or soft_reset", ctx);
        end
    endgenerate

    // §10.16b: clear_error outside CTX_ERROR causes no state change
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_clear_error_nop
            property clear_error_nop_when_not_error;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (clear_error[ctx] && ctx_state[ctx] != CTX_ERROR)
                |=>
                // State should not change due to clear_error alone
                // (other transitions like doorbell/comp_done may happen,
                //  but clear_error itself is a NOP)
                ctx_state[ctx] != CTX_IDLE ||
                $past(ctx_state[ctx]) == CTX_IDLE;  // was already IDLE
            endproperty
            // Cover only — asserting this is too strict (other transitions
            // can coincide). The important thing is that clear_error doesn't
            // cause CTX_ERROR-related side effects when not in CTX_ERROR.
            c_clear_nop: cover property (clear_error_nop_when_not_error);
        end
    endgenerate

    // §10.16c: Full recovery cover property
    //   error_valid → ##[1:$] CTX_ERROR → ##[1:$] clear_error → ##1 CTX_IDLE
    //   → ##[1:$] doorbell → ##[0:2] CTX_RUNNABLE
    //
    // 🔴🔴 [2026-09-01] 本段用 `ifndef VERILATOR 守卫 —— **它是本文件唯一编不过的一段**。
    //   实测（Verilator 5.032 + --bbox-unsup）：全文件只剩 1 个错误
    //     `pe_assertions.sv:966:30: Invalid statement under AstProperty`
    //   即 `sequence ... endsequence` 声明在 generate 块里不被支持（本文件头注 :8 早已点名
    //   「§10.16c `sequence` blocks are unsupported, e.g. :954」，并据此**放弃**了 T39 lint 目标）。
    //   🔴 **头注写「abandoned」时面对的是一片错误；2026-09-01 实测只差这一处。**
    //   ⇒ 守卫这一段（内容**全是 cover，零 assert** ⇒ 断言覆盖零损失），本文件即可编译，
    //     `pe_top` 的断言从「99 条装饰」变成「**96 条真跑 + 3 条被 --bbox-unsup 黑盒**」。
    //   🔴 被黑盒的那 3 条**按名字登记**（欠账 #48）：`a_no_done_reset` / `a_soft_reset_ctx` /
    //     `a_vis_blocked` —— 它们**编得过但不检查**，这是 fail-open，不许算进守门数。
    `ifndef VERILATOR
    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_recovery_cover
            // Cover: complete error→recovery→re-arm path observed
            sequence error_then_clear;
                (error_valid && error_ctx == ctx[CTX_ID_W-1:0])
                ##[1:64] (clear_error[ctx] && ctx_state[ctx] == CTX_ERROR);
            endsequence

            sequence clear_then_idle;
                (clear_error[ctx] && ctx_state[ctx] == CTX_ERROR)
                ##1 (ctx_state[ctx] == CTX_IDLE);
            endsequence

            sequence idle_then_rearm;
                (ctx_state[ctx] == CTX_IDLE)
                ##[1:32] doorbell_pulse[ctx]
                ##[0:2]  (ctx_state[ctx] == CTX_RUNNABLE);
            endsequence

            c_full_recovery: cover property (
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                error_then_clear ##0 clear_then_idle ##0 idle_then_rearm
            );
        end
    endgenerate
    `endif  // VERILATOR —— §10.16c 守卫结束（见上方 2026-09-01 头注）

    // =========================================================================
    // §10.17 R4.2: Credit Counter Bounds
    //
    // Credit counters must never exceed their configured maximum and must
    // never underflow below 0. Violations indicate:
    //   - Overflow (credit > MAX): spurious done without prior issue, or
    //     double-return of a single credit
    //   - Underflow (credit wraps to large value): issue without available
    //     credit, or can_issue check bypassed
    //
    // With CREDIT_W widened by 1 bit (R4A+), overflow is detectable as
    // credit > MAX rather than silently wrapping.
    // =========================================================================

    property vec_credit_in_bounds;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        vec_credit <= SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_VEC);
    endproperty
    a_vec_credit_bounds: assert property (vec_credit_in_bounds)
        else $error("[PE_ASSERT §10.17] vec_credit=%0d exceeds MAX=%0d (overflow)",
                    vec_credit, SCOREBOARD_CREDITS_VEC);

    property tens_credit_in_bounds;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        tens_credit <= SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_TENS);
    endproperty
    a_tens_credit_bounds: assert property (tens_credit_in_bounds)
        else $error("[PE_ASSERT §10.17] tens_credit=%0d exceeds MAX=%0d (overflow)",
                    tens_credit, SCOREBOARD_CREDITS_TENS);

    property dma_credit_in_bounds;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        dma_credit <= SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_DMA);
    endproperty
    a_dma_credit_bounds: assert property (dma_credit_in_bounds)
        else $error("[PE_ASSERT §10.17] dma_credit=%0d exceeds MAX=%0d (overflow)",
                    dma_credit, SCOREBOARD_CREDITS_DMA);

    // Credit must be at MAX after soft_reset (all credits returned)
    property credits_reset_to_max;
        @(posedge clk_i) disable iff (!rst_ni)
        cp_soft_reset |=>
            (vec_credit  == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_VEC)) &&
            (tens_credit == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_TENS)) &&
            (dma_credit  == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_DMA));
    endproperty
    a_credits_reset: assert property (credits_reset_to_max)
        else $error("[PE_ASSERT §10.17] Credits not reset to MAX after soft_reset");

    // =========================================================================
    // §10.18 R4.2: Watchdog Progress Counter
    //
    // Verifies watchdog counter behavior:
    //   - Counter is 0 in inactive states (IDLE/DONE/ERROR)
    //   - Timeout flag correctly reflects counter == threshold
    //   - Timeout causes CTX_ERROR (covered by §10.15 error_causes_ctx_error,
    //     but add watchdog-specific checks here)
    //   - Threshold == 0 disables watchdog (no timeout even if counter wraps)
    // =========================================================================

    generate
        for (genvar ctx = 0; ctx < NUM_CTX; ctx++) begin : gen_wd_check

            // Counter must be 0 when ctx is inactive -- FROM THE SECOND CYCLE ON.
            //
            // [§10.18 ENTRY-CYCLE EXEMPTION, 2026-09-05] The old form demanded
            // wd_cnt==0 on the VERY FIRST cycle of an inactive state. That is not
            // the invariant the RTL implements:
            //   * wd_cnt_q and ctx_state_q live in the SAME always_ff
            //     (cp_scheduler.sv:878);
            //   * the counter block (:890-901) decides from the OLD ctx_state_q,
            //     so on the edge a ctx leaves an active state it takes ONE LAST
            //     increment;
            //   * the DONE-detect arc (:944-951) writes CTX_DONE on that same edge.
            //   => entering inactive ALWAYS carries the last increment (measured =1).
            //   The invariant the RTL actually guarantees is cp_scheduler.sv:898-900's
            //   UNCONDITIONAL `wd_cnt_q[i] <= '0` in the else branch, i.e. zero from
            //   the SECOND cycle of inactivity onward. That is what we assert now.
            //
            // Why this was never seen before: every pe_top bench exits on the NoC
            // completion token, not on CTX_DONE, and in a single-ring load that token
            // comes from the ring's own trailing DMA_EVICT whose done_o waits for
            // dma_engine ST_DONE -- so ctx0 reached CTX_DONE about 3 cycles AFTER the
            // bench stopped clocking. Proven, not assumed: adding 64 idle cycles after
            // the token to a SINGLE-context arm (S-K4) reproduces the identical
            // signature (CTX0 / wd_cnt=1 / CTX_DONE) 3 cycles after the arm's report
            // -- soc600_prereg §38.10, verdict WD-VEHICLE. Two contexts were the
            // vehicle, not the cause.
            //
            // 🔴 Deliberately NOT written as `|-> ##[0:1] (...)`: ##[0:1] belongs to
            //   the construct family that tb/Makefile's --bbox-unsup can SILENTLY
            //   black-box (debt #48), which would disable this check with no
            //   diagnostic. The $past form below is already used and proven live in
            //   this same file (§10.4 at :371/:383/:395/:408/:430/:441).
            property wd_zero_when_inactive;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                ((ctx_state[ctx] inside {CTX_IDLE, CTX_DONE, CTX_ERROR}) &&
                 ($past(ctx_state[ctx]) == CTX_IDLE ||
                  $past(ctx_state[ctx]) == CTX_DONE ||
                  $past(ctx_state[ctx]) == CTX_ERROR)) |->
                    (wd_cnt[ctx] == '0);
            endproperty
            a_wd_inactive_zero: assert property (wd_zero_when_inactive)
                else $error("[PE_ASSERT §10.18] CTX%0d: wd_cnt=%0d nonzero in inactive state %s (2nd+ cycle)",
                           ctx, wd_cnt[ctx], ctx_state[ctx].name());

            // 🔴 COMPENSATION for the one cycle the exemption gives up.
            // The residue is only HARMFUL if it equals the threshold, because
            // wd_cnt_q's ONLY reader is wd_timeout (cp_scheduler.sv:739-740), and
            // wd_error_valid (:750) masks CTX_ERROR but NOT CTX_DONE. So a ctx that
            // finished normally could be turned into CTX_ERROR+ERR_WATCHDOG if
            // WD_THRESHOLD were programmed to 1 (cp_csr.sv:538 does not clamp it).
            // Today's thresholds (bench 4096, reset default 0xFFFF) make it
            // unreachable, so this is green by vacuity right now.
            // 🔴 CTX_ERROR is deliberately EXCLUDED: the reset default threshold is
            //   0xFFFF and the counter saturates at 0xFFFF (cp_scheduler.sv:896), so
            //   on a genuine timeout wd_timeout legitimately stays high entering ERROR.
            // 🔴 ITS POSITIVE CONTROL HAS NOT BEEN RUN (it needs a micro-arm that
            //   programs WD_THRESHOLD=1). Per debt #48's lesson, DO NOT count this
            //   assertion in any guard tally until that control has been executed.
            //   Registered as debt #124.
            property wd_no_timeout_when_inactive;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (ctx_state[ctx] inside {CTX_IDLE, CTX_DONE}) |-> !wd_timeout[ctx];
            endproperty
            a_wd_no_timeout_inactive: assert property (wd_no_timeout_when_inactive)
                else $error("[PE_ASSERT §10.18] CTX%0d: wd_timeout asserted in inactive state %s",
                           ctx, ctx_state[ctx].name());

            // Timeout flag must match counter == threshold (when threshold != 0)
            property wd_timeout_correct;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                wd_timeout[ctx] == ((wd_cnt[ctx] == wd_threshold) &&
                                    (wd_threshold != '0));
            endproperty
            a_wd_timeout_match: assert property (wd_timeout_correct)
                else $error("[PE_ASSERT §10.18] CTX%0d: wd_timeout mismatch (cnt=%0d, threshold=%0d)",
                           ctx, wd_cnt[ctx], wd_threshold);

            // Threshold == 0 must never produce timeout
            property wd_disabled_no_timeout;
                @(posedge clk_i) disable iff (!rst_ni)
                (wd_threshold == '0) |-> !wd_timeout[ctx];
            endproperty
            a_wd_disabled: assert property (wd_disabled_no_timeout)
                else $error("[PE_ASSERT §10.18] CTX%0d: watchdog timeout with threshold=0", ctx);

            // Timeout must drive CTX_ERROR on next cycle (if not already ERROR)
            property wd_timeout_to_error;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (wd_timeout[ctx] && ctx_state[ctx] != CTX_ERROR) |=>
                    ctx_state[ctx] == CTX_ERROR;
            endproperty
            a_wd_to_error: assert property (wd_timeout_to_error)
                else $error("[PE_ASSERT §10.18] CTX%0d: watchdog timeout did not cause CTX_ERROR", ctx);

        end
    endgenerate

    // =========================================================================
    // §10.19 R4.2: Credit-State Consistency
    //
    // Cross-checks between credit counters and context states:
    //
    //   - If ANY ctx is in WAIT_VEC, vec_credit < MAX (at least 1 consumed)
    //   - If vec_credit == MAX (idle), no ctx should be in WAIT_VEC
    //   - Issue to vec requires vec_credit > 0 (enforced by can_issue,
    //     but assert here catches bypass bugs)
    //
    // These are steady-state invariants. Transient 1-cycle windows after
    // done (credit returned but state not yet updated) are excluded by
    // checking $past of state or using |=> sequencing.
    // =========================================================================

    // If all vec credits are available, no ctx should be WAIT_VEC
    // (Allow 1-cycle transient: done returns credit but state updates same cycle)
    property vec_idle_no_waiters;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_credit == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_VEC)) |->
            !(ctx_state[0] == CTX_WAIT_VEC ||
              ctx_state[1] == CTX_WAIT_VEC ||
              ctx_state[2] == CTX_WAIT_VEC ||
              ctx_state[3] == CTX_WAIT_VEC);
    endproperty
    a_vec_idle_no_wait: assert property (vec_idle_no_waiters)
        else $warning("[PE_ASSERT §10.19] vec_credit at MAX but ctx in WAIT_VEC (transient?)");

    property tens_idle_no_waiters;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_credit == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_TENS)) |->
            !(ctx_state[0] == CTX_WAIT_TENS ||
              ctx_state[1] == CTX_WAIT_TENS ||
              ctx_state[2] == CTX_WAIT_TENS ||
              ctx_state[3] == CTX_WAIT_TENS);
    endproperty
    a_tens_idle_no_wait: assert property (tens_idle_no_waiters)
        else $warning("[PE_ASSERT §10.19] tens_credit at MAX but ctx in WAIT_TENS (transient?)");

    property dma_idle_no_waiters;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_credit == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_DMA)) |->
            !(ctx_state[0] == CTX_WAIT_DMA ||
              ctx_state[1] == CTX_WAIT_DMA ||
              ctx_state[2] == CTX_WAIT_DMA ||
              ctx_state[3] == CTX_WAIT_DMA);
    endproperty
    a_dma_idle_no_wait: assert property (dma_idle_no_waiters)
        else $warning("[PE_ASSERT §10.19] dma_credit at MAX but ctx in WAIT_DMA (transient?)");

    // Issue to exec unit requires credit available (catches can_issue bypass)
    property vec_issue_has_credit;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_cmd_valid && vec_cmd_ready) |-> (vec_credit > '0);
    endproperty
    a_vec_issue_credit: assert property (vec_issue_has_credit)
        else $error("[PE_ASSERT §10.19] vec command issued with vec_credit=0");

    property tens_issue_has_credit;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_cmd_valid && tens_cmd_ready) |-> (tens_credit > '0);
    endproperty
    a_tens_issue_credit: assert property (tens_issue_has_credit)
        else $error("[PE_ASSERT §10.19] tens command issued with tens_credit=0");

    property dma_issue_has_credit;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_cmd_valid && dma_cmd_ready) |-> (dma_credit > '0);
    endproperty
    a_dma_issue_credit: assert property (dma_issue_has_credit)
        else $error("[PE_ASSERT §10.19] dma command issued with dma_credit=0");

    // =========================================================================
    // §10.20 R5.4: Performance Counter Monotonicity & Saturation
    //
    // All perf counters are 32-bit (or 10-bit) saturating: they must never
    // decrease (except on reset) and must never exceed their max value.
    //
    // Monotonicity: counter[t+1] >= counter[t] (when not reset)
    //   This catches counter underflow bugs (e.g., decrement-without-increment).
    //
    // Saturation: counter == MAX → counter stays MAX (no wrap to 0)
    //   This catches missing saturation guards.
    //
    // Barrier ⊆ Blocked: ctx_barrier_stalls[i] <= ctx_blocked_cycles[i]
    //   Barrier stall is strictly a subset of blocked cycles.
    //
    // Issue ≥ Done (over long term):
    //   Covered as a $warning: total_done > total_issue is suspicious
    //   (possible only if done signals fire without matching issues).
    // =========================================================================

    // ── CP-side 32-bit counters: monotonicity (per-ctx) ──
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_perf_mono

            // Helper: delayed values for monotonicity check
            logic [PERF_CNT_W-1:0] blocked_prev, barrier_prev, starved_prev;

            always_ff @(posedge clk_i or negedge rst_ni) begin
                if (!rst_ni || cp_soft_reset) begin
                    blocked_prev <= '0;
                    barrier_prev <= '0;
                    starved_prev <= '0;
                end else begin
                    blocked_prev <= perf_ctx_blocked[i];
                    barrier_prev <= perf_ctx_barrier[i];
                    starved_prev <= perf_ctx_starved[i];
                end
            end

            // Monotonicity: current >= previous (or reset just happened)
            property blocked_monotonic;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                perf_ctx_blocked[i] >= blocked_prev;
            endproperty
            a_blocked_mono: assert property (blocked_monotonic)
                else $error("[PE_ASSERT §10.20] CTX%0d blocked_cycles decreased: %0d → %0d",
                            i, blocked_prev, perf_ctx_blocked[i]);

            property barrier_monotonic;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                perf_ctx_barrier[i] >= barrier_prev;
            endproperty
            a_barrier_mono: assert property (barrier_monotonic)
                else $error("[PE_ASSERT §10.20] CTX%0d barrier_stalls decreased: %0d → %0d",
                            i, barrier_prev, perf_ctx_barrier[i]);

            property starved_monotonic;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                perf_ctx_starved[i] >= starved_prev;
            endproperty
            a_starved_mono: assert property (starved_monotonic)
                else $error("[PE_ASSERT §10.20] CTX%0d starved_cycles decreased: %0d → %0d",
                            i, starved_prev, perf_ctx_starved[i]);

            // Barrier ⊆ Blocked: barrier can never exceed blocked
            property barrier_subset_blocked;
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                perf_ctx_barrier[i] <= perf_ctx_blocked[i];
            endproperty
            a_barrier_subset: assert property (barrier_subset_blocked)
                else $error("[PE_ASSERT §10.20] CTX%0d barrier(%0d) > blocked(%0d)",
                            i, perf_ctx_barrier[i], perf_ctx_blocked[i]);

        end
    endgenerate

    // ── CP-side 32-bit global counters: monotonicity ──
    logic [PERF_CNT_W-1:0] issue_prev, done_prev;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || cp_soft_reset) begin
            issue_prev <= '0;
            done_prev  <= '0;
        end else begin
            issue_prev <= perf_total_issue;
            done_prev  <= perf_total_done;
        end
    end

    property issue_monotonic;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        perf_total_issue >= issue_prev;
    endproperty
    a_issue_mono: assert property (issue_monotonic)
        else $error("[PE_ASSERT §10.20] total_issue decreased: %0d → %0d",
                    issue_prev, perf_total_issue);

    property done_monotonic;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        perf_total_done >= done_prev;
    endproperty
    a_done_mono: assert property (done_monotonic)
        else $error("[PE_ASSERT §10.20] total_done decreased: %0d → %0d",
                    done_prev, perf_total_done);

    // Advisory: done should not persistently exceed issue
    property done_le_issue;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        perf_total_done <= perf_total_issue;
    endproperty
    a_done_le_issue: assert property (done_le_issue)
        else $warning("[PE_ASSERT §10.20] total_done(%0d) > total_issue(%0d) — spurious done?",
                      perf_total_done, perf_total_issue);

    // ── L2-side 32-bit conflict counter: monotonicity ──
    logic [PERF_CNT_W-1:0] l2_conflict_prev;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni || cp_soft_reset)
            l2_conflict_prev <= '0;
        else
            l2_conflict_prev <= perf_l2_conflict;
    end

    property l2_conflict_monotonic;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        perf_l2_conflict >= l2_conflict_prev;
    endproperty
    a_l2_conflict_mono: assert property (l2_conflict_monotonic)
        else $error("[PE_ASSERT §10.20] l2_conflict decreased: %0d → %0d",
                    l2_conflict_prev, perf_l2_conflict);

    // ── Counter frozen when perf_cnt_en == 0 ──
    property counters_frozen_when_disabled;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        !perf_cnt_en |-> (perf_total_issue == $past(perf_total_issue));
    endproperty
    a_frozen_when_disabled: assert property (counters_frozen_when_disabled)
        else $error("[PE_ASSERT §10.20] perf counters changed while perf_cnt_en=0");

    // =========================================================================
    // §10.21 R5.4: Vec Yield Fairness Assertions
    //
    // When yield is active (mode==1), verify:
    //   1. tens_consec_cnt never exceeds tens_quota_n + 1
    //      (quota check fires at cnt >= quota_n, cnt resets next cycle)
    //   2. tens_yield signal is correctly computed
    //   3. Mode 0 (disabled) → tens_yield must be 0
    //   4. Yield fires → tens_consec_cnt resets next cycle
    // =========================================================================

    // Mode 0: yield must never assert
    property yield_disabled_mode0;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_yield_mode == 2'd0) |-> !tens_yield;
    endproperty
    a_yield_disabled: assert property (yield_disabled_mode0)
        else $error("[PE_ASSERT §10.21] tens_yield asserted while yield_mode=0");

    // Consecutive count bounded: cnt <= quota_n + 1
    // (can reach quota_n, then yield fires same cycle, counter resets next)
    property consec_cnt_bounded;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_yield_mode == 2'd1) |->
            (tens_consec_cnt <= tens_quota_n + 4'd1);
    endproperty
    a_consec_bounded: assert property (consec_cnt_bounded)
        else $error("[PE_ASSERT §10.21] tens_consec_cnt=%0d exceeds quota_n+1=%0d",
                    tens_consec_cnt, tens_quota_n + 4'd1);

    // Yield fires → counter resets next cycle
    property yield_resets_counter;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        tens_yield |=> (tens_consec_cnt == '0);
    endproperty
    a_yield_resets: assert property (yield_resets_counter)
        else $error("[PE_ASSERT §10.21] tens_consec_cnt not reset after yield");

    // Cover: yield actually fires (functional coverage)
    c_yield_fires: cover property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        tens_yield && vec_rw_req
    );

    // Cover: yield fires while tens is waiting (primary use case)
    c_yield_helps_tens: cover property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        tens_yield && tens_rw_req && tens_rw_gnt
    );

    // =========================================================================
    // §10.22 R7.4/D2: DMA 2D Strided Transfer Assertions
    //
    // Verify correctness of the nested AGU loop:
    //   1. outer_cnt bounded: always < eff_outer_count
    //   2. eff_outer_count normalization: 0/1 in cmd → 1 effective
    //   3. cur_base_row bounded: must not exceed L2 address space
    //   4. MEMSET mode: no ingress FIFO activity (NoC not used)
    //   5. 1D backward compat: outer_count ≤ 1 → single outer iteration
    //   6. inner word count bounded: wcount < total_words during active states
    // =========================================================================

    // DMA state encoding aliases (match dma_engine FSM)
    localparam logic [2:0] DMA_ST_IDLE          = 3'd0;
    localparam logic [2:0] DMA_ST_FILL_RUN      = 3'd1;
    localparam logic [2:0] DMA_ST_EVICT_REQ     = 3'd2;
    localparam logic [2:0] DMA_ST_EVICT_DRAIN   = 3'd3;
    localparam logic [2:0] DMA_ST_DONE          = 3'd4;
    localparam logic [2:0] DMA_ST_MEMSET_RUN    = 3'd5;
    localparam logic [2:0] DMA_ST_OUTER_ADVANCE = 3'd6;

    logic dma_active;
    assign dma_active = (dma_state != DMA_ST_IDLE) && (dma_state != DMA_ST_DONE);

    // ── eff_outer_count normalization ──
    // Regardless of cmd.outer_count, effective must be >= 1
    property dma_eff_outer_ge1;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        dma_active |-> (dma_eff_outer_count >= 16'd1);
    endproperty
    a_dma_eff_outer_ge1: assert property (dma_eff_outer_ge1)
        else $error("[PE_ASSERT §10.22] eff_outer_count=0 while DMA active");

    // ── outer_cnt bounded ──
    property dma_outer_cnt_bounded;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        dma_active |-> (dma_outer_cnt < dma_eff_outer_count);
    endproperty
    a_dma_outer_bounded: assert property (dma_outer_cnt_bounded)
        else $error("[PE_ASSERT §10.22] outer_cnt(%0d) >= eff_outer(%0d)",
                    dma_outer_cnt, dma_eff_outer_count);

    // ── cur_base_row within L2 address space ──
    // cur_base_row + len_rows - 1 must not exceed L2_TOTAL_ROWS
    property dma_base_row_in_range;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        dma_active |->
            ({1'b0, dma_cur_base_row} + {1'b0, dma_cmd_q.len_rows[L2_BANK_AW-1:0]}
             <= (L2_BANK_AW+1)'(L2_TOTAL_ROWS));
    endproperty
    a_dma_row_range: assert property (dma_base_row_in_range)
        else $warning("[PE_ASSERT §10.22] DMA cur_base_row+len_rows exceeds L2 range");

    // ── MEMSET: no ingress FIFO push ──
    // When in MEMSET_RUN state, NoC ingress should not be accepted
    property dma_memset_no_noc_ing;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_state == DMA_ST_MEMSET_RUN) |-> !noc_ing_ready;
    endproperty
    a_dma_memset_no_noc: assert property (dma_memset_no_noc_ing)
        else $error("[PE_ASSERT §10.22] noc_ing_ready asserted during MEMSET");

    // ── Outer advance: wcount resets to 0 ──
    property dma_outer_advance_resets_wcount;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_state == DMA_ST_OUTER_ADVANCE) |=> (dma_wcount == '0);
    endproperty
    a_dma_wcount_reset: assert property (dma_outer_advance_resets_wcount)
        else $error("[PE_ASSERT §10.22] wcount not reset after OUTER_ADVANCE");

    // ── 1D backward compat: outer_count ≤ 1 → no OUTER_ADVANCE state ──
    property dma_1d_no_outer_advance;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_cmd_q.outer_count <= 16'd1) |->
            (dma_state != DMA_ST_OUTER_ADVANCE);
    endproperty
    a_dma_1d_compat: assert property (dma_1d_no_outer_advance)
        else $error("[PE_ASSERT §10.22] OUTER_ADVANCE entered with outer_count<=1");

    // ── Cover: 2D transfer actually happens ──
    c_dma_2d_transfer: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        (dma_state == DMA_ST_OUTER_ADVANCE)
    );

    // ── Cover: memset completes ──
    c_dma_memset_done: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        (dma_state == DMA_ST_MEMSET_RUN) ##[1:$] (dma_state == DMA_ST_DONE)
    );

    // =========================================================================
    // §10.23 D5/R7.1: Multi-Credit Tag Consistency
    //
    // Verifies tag scoreboard invariants for the multi-credit system:
    //
    //   A. Tag-credit sync: $countones(tag_valid) == MAX - credit
    //      (inflight tag count must match credit deficit)
    //   B. Tag reset: all tag_valid = 0 after soft_reset
    //   C. Done tag was valid: tag being freed was actually in-flight
    //   D. Done tag→ctx match: tag's recorded ctx matches done_ctx
    //   E. No duplicate ctx: per-unit, no two valid tags map to same ctx
    //      (each ctx has at most 1 inflight op per unit)
    //   F. Cover: multi-credit operation (2+ tags valid simultaneously)
    //
    // All assertions are structural invariants, not timing properties.
    // =========================================================================

    // ── §10.23.A: Tag-Credit Synchronization ──
    //
    // Inflight count = popcount(tag_valid) must equal (MAX_CREDITS - credit).
    // Violation means tag alloc/dealloc and credit inc/dec went out of sync.
    property vec_tag_credit_sync;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        $countones(vec_tag_valid) ==
            (SCOREBOARD_CREDITS_VEC - int'(vec_credit));
    endproperty
    a_vec_tag_credit_sync: assert property (vec_tag_credit_sync)
        else $error("[PE_ASSERT §10.23A] vec tag popcount=%0d but credit deficit=%0d",
                    $countones(vec_tag_valid),
                    SCOREBOARD_CREDITS_VEC - int'(vec_credit));

    property tens_tag_credit_sync;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        $countones(tens_tag_valid) ==
            (SCOREBOARD_CREDITS_TENS - int'(tens_credit));
    endproperty
    a_tens_tag_credit_sync: assert property (tens_tag_credit_sync)
        else $error("[PE_ASSERT §10.23A] tens tag popcount=%0d but credit deficit=%0d",
                    $countones(tens_tag_valid),
                    SCOREBOARD_CREDITS_TENS - int'(tens_credit));

    property dma_tag_credit_sync;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        $countones(dma_tag_valid) ==
            (SCOREBOARD_CREDITS_DMA - int'(dma_credit));
    endproperty
    a_dma_tag_credit_sync: assert property (dma_tag_credit_sync)
        else $error("[PE_ASSERT §10.23A] dma tag popcount=%0d but credit deficit=%0d",
                    $countones(dma_tag_valid),
                    SCOREBOARD_CREDITS_DMA - int'(dma_credit));

    // ── §10.23.B: Tag Reset ──
    //
    // After soft_reset, all tag_valid bitmaps must be 0 (no inflight ops).
    property tags_reset_to_zero;
        @(posedge clk_i) disable iff (!rst_ni)
        cp_soft_reset |=>
            (vec_tag_valid  == '0) &&
            (tens_tag_valid == '0) &&
            (dma_tag_valid  == '0);
    endproperty
    a_tags_reset: assert property (tags_reset_to_zero)
        else $error("[PE_ASSERT §10.23B] tag_valid not cleared after soft_reset");

    // ── §10.23.C: Done Tag Was Valid ──
    //
    // When an exec unit fires done, the returned tag must have been valid
    // (in-flight). Violation means spurious done or tag corruption.
    property vec_done_tag_was_valid;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_done) |-> vec_tag_valid[vec_done_tag];
    endproperty
    a_vec_done_tag_valid: assert property (vec_done_tag_was_valid)
        else $error("[PE_ASSERT §10.23C] vec done tag=%0d was not valid (spurious done?)",
                    vec_done_tag);

    property tens_done_tag_was_valid;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_done) |-> tens_tag_valid[tens_done_tag];
    endproperty
    a_tens_done_tag_valid: assert property (tens_done_tag_was_valid)
        else $error("[PE_ASSERT §10.23C] tens done tag=%0d was not valid (spurious done?)",
                    tens_done_tag);

    property dma_done_tag_was_valid;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_done) |-> dma_tag_valid[dma_done_tag];
    endproperty
    a_dma_done_tag_valid: assert property (dma_done_tag_was_valid)
        else $error("[PE_ASSERT §10.23C] dma done tag=%0d was not valid (spurious done?)",
                    dma_done_tag);

    // ── §10.23.D: Done Tag→Ctx Match ──
    //
    // The tag's recorded ctx_id must match the done_ctx from the exec unit.
    // Violation means tag→ctx table corruption or wrong tag returned.
    property vec_done_tag_ctx_match;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (vec_done && vec_tag_valid[vec_done_tag]) |->
            (vec_tag_ctx[vec_done_tag] == vec_done_ctx);
    endproperty
    a_vec_done_ctx_match: assert property (vec_done_tag_ctx_match)
        else $error("[PE_ASSERT §10.23D] vec done tag=%0d ctx_map=%0d != done_ctx=%0d",
                    vec_done_tag, vec_tag_ctx[vec_done_tag], vec_done_ctx);

    property tens_done_tag_ctx_match;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (tens_done && tens_tag_valid[tens_done_tag]) |->
            (tens_tag_ctx[tens_done_tag] == tens_done_ctx);
    endproperty
    a_tens_done_ctx_match: assert property (tens_done_tag_ctx_match)
        else $error("[PE_ASSERT §10.23D] tens done tag=%0d ctx_map=%0d != done_ctx=%0d",
                    tens_done_tag, tens_tag_ctx[tens_done_tag], tens_done_ctx);

    property dma_done_tag_ctx_match;
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        (dma_done && dma_tag_valid[dma_done_tag]) |->
            (dma_tag_ctx[dma_done_tag] == dma_done_ctx);
    endproperty
    a_dma_done_ctx_match: assert property (dma_done_tag_ctx_match)
        else $error("[PE_ASSERT §10.23D] dma done tag=%0d ctx_map=%0d != done_ctx=%0d",
                    dma_done_tag, dma_tag_ctx[dma_done_tag], dma_done_ctx);

    // ── §10.23.E: No Duplicate Ctx per Unit ──
    //
    // Each ctx has at most 1 inflight op per unit (enforced by CTX_WAIT_*
    // state machine). For valid tags on the SAME unit, no two should map
    // to the same ctx. Uses combinational scan (TAG_MAX is small, ≤8).
    generate
        for (genvar u = 0; u < 3; u++) begin : gen_tag_unique_ctx
            for (genvar t1 = 0; t1 < TAG_MAX; t1++) begin : gen_t1
                for (genvar t2 = t1 + 1; t2 < TAG_MAX; t2++) begin : gen_t2

                    if (u == 0) begin : vec_dup
                        property vec_no_dup_ctx;
                            @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                            (vec_tag_valid[t1] && vec_tag_valid[t2]) |->
                                (vec_tag_ctx[t1] != vec_tag_ctx[t2]);
                        endproperty
                        a_vec_no_dup: assert property (vec_no_dup_ctx)
                            else $error(
                                "[PE_ASSERT §10.23E] vec tags %0d,%0d both map to ctx=%0d",
                                t1, t2, vec_tag_ctx[t1]);
                    end

                    if (u == 1) begin : tens_dup
                        property tens_no_dup_ctx;
                            @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                            (tens_tag_valid[t1] && tens_tag_valid[t2]) |->
                                (tens_tag_ctx[t1] != tens_tag_ctx[t2]);
                        endproperty
                        a_tens_no_dup: assert property (tens_no_dup_ctx)
                            else $error(
                                "[PE_ASSERT §10.23E] tens tags %0d,%0d both map to ctx=%0d",
                                t1, t2, tens_tag_ctx[t1]);
                    end

                    if (u == 2) begin : dma_dup
                        property dma_no_dup_ctx;
                            @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                            (dma_tag_valid[t1] && dma_tag_valid[t2]) |->
                                (dma_tag_ctx[t1] != dma_tag_ctx[t2]);
                        endproperty
                        a_dma_no_dup: assert property (dma_no_dup_ctx)
                            else $error(
                                "[PE_ASSERT §10.23E] dma tags %0d,%0d both map to ctx=%0d",
                                t1, t2, dma_tag_ctx[t1]);
                    end

                end
            end
        end
    endgenerate

    // ── §10.23.F: Cover — multi-credit operation ──
    //
    // Verify that 2+ tags are simultaneously inflight on a single unit.
    // This proves multi-credit is exercised (not just single-credit legacy).
    c_vec_multi_credit: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        ($countones(vec_tag_valid) >= 2)
    );
    c_tens_multi_credit: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        ($countones(tens_tag_valid) >= 2)
    );
    c_dma_multi_credit: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        ($countones(dma_tag_valid) >= 2)
    );

    // =========================================================================
    // §10.24: Event System Correctness (D7/R7.2)
    //
    // Validates the event-based WAIT opcode mechanism:
    //   A. Event pending cleared on reset
    //   B. OP_WAIT → CTX_WAIT_EVENT transition
    //   C. Event wake implies match (pending & mask != 0)
    //   D. CTX_WAIT_EVENT always has nonzero wait_mask
    //   E. Event clear pulse → event_pending goes to 0
    //   F. Reserved event bits always zero
    //   G. Cover: event wake from each source type
    // =========================================================================

    // ── §10.24.A: Event Pending Reset ──
    //
    // After reset or soft_reset, all event_pending must be cleared.
    a_event_pending_reset: assert property (
        @(posedge clk_i)
        (cp_soft_reset) |=> (event_pending[0] == '0) &&
                         (event_pending[1] == '0) &&
                         (event_pending[2] == '0) &&
                         (event_pending[3] == '0)
    ) else $error("[PE_ASSERT §10.24A] event_pending not cleared after soft_reset");

    // ── §10.24.B: OP_WAIT → CTX_WAIT_EVENT ──
    //
    // When scheduler issues OP_WAIT (issue_ok with opcode==OP_WAIT),
    // the target ctx must transition to CTX_WAIT_EVENT on next cycle.
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_wait_transition
            a_opwait_transition: assert property (
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (issue_ok && issue_ctx == CTX_ID_W'(i) &&
                 sel_opcode_raw == OP_WAIT)
                |=> (ctx_state[i] == CTX_WAIT_EVENT)
            ) else $error("[PE_ASSERT §10.24B] ctx%0d: OP_WAIT issued but not in CTX_WAIT_EVENT", i);
        end
    endgenerate

    // ── §10.24.C: Event Wake Implies Match ──
    //
    // event_wake[i] must only be asserted when ctx is in CTX_WAIT_EVENT
    // and (event_pending | event_set) & wait_mask != 0.
    // We verify the weaker invariant: wake → ctx was in CTX_WAIT_EVENT.
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_wake_valid
            a_event_wake_valid: assert property (
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                event_wake[i] |-> (ctx_state[i] == CTX_WAIT_EVENT)
            ) else $error("[PE_ASSERT §10.24C] ctx%0d: event_wake but not in CTX_WAIT_EVENT", i);
        end
    endgenerate

    // ── §10.24.D: CTX_WAIT_EVENT Requires Nonzero Mask ──
    //
    // If a ctx is in CTX_WAIT_EVENT, its wait_mask must be nonzero.
    // A zero mask would cause permanent deadlock (never matches).
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_mask_nonzero
            a_wait_mask_nonzero: assert property (
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                (ctx_state[i] == CTX_WAIT_EVENT) |-> (wait_mask[i] != '0)
            ) else $error("[PE_ASSERT §10.24D] ctx%0d: CTX_WAIT_EVENT with zero wait_mask (deadlock)", i);
        end
    endgenerate

    // ── §10.24.E: Event Clear → Pending Cleared ──
    //
    // When SW issues event_clear[i], event_pending[i] must be zero next cycle.
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_event_clear
            a_event_clear_effect: assert property (
                @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
                event_clear[i] |=> (event_pending[i] == '0)
            ) else $error("[PE_ASSERT §10.24E] ctx%0d: event_clear pulse but pending not cleared", i);
        end
    endgenerate

    // ── §10.24.F: Reserved Event Bits Always Zero ──
    //
    // Bits [7:5] of event_pending must always be 0 (no event sources mapped).
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_reserved_bits
            a_event_reserved_zero: assert property (
                @(posedge clk_i) disable iff (!rst_ni)
                event_pending[i][EVT_W-1:5] == '0
            ) else $error("[PE_ASSERT §10.24F] ctx%0d: reserved event bits [7:5] nonzero (0x%02x)",
                          i, event_pending[i]);
        end
    endgenerate

    // ── §10.24.G: Cover — Event Wake from Each Source ──
    //
    // Prove that wake-up is exercisable from each event source type.
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_event_covers
            c_wake_from_done_vec: cover property (
                @(posedge clk_i) disable iff (!rst_ni)
                (ctx_state[i] == CTX_WAIT_EVENT) && event_wake[i] &&
                (event_pending[i][EVT_DONE_VEC] & wait_mask[i][EVT_DONE_VEC])
            );
            c_wake_from_done_tens: cover property (
                @(posedge clk_i) disable iff (!rst_ni)
                (ctx_state[i] == CTX_WAIT_EVENT) && event_wake[i] &&
                (event_pending[i][EVT_DONE_TENS] & wait_mask[i][EVT_DONE_TENS])
            );
            c_wake_from_done_dma: cover property (
                @(posedge clk_i) disable iff (!rst_ni)
                (ctx_state[i] == CTX_WAIT_EVENT) && event_wake[i] &&
                (event_pending[i][EVT_DONE_DMA] & wait_mask[i][EVT_DONE_DMA])
            );
            c_wake_from_doorbell: cover property (
                @(posedge clk_i) disable iff (!rst_ni)
                (ctx_state[i] == CTX_WAIT_EVENT) && event_wake[i] &&
                (event_pending[i][EVT_DOORBELL] & wait_mask[i][EVT_DOORBELL])
            );
            c_wake_from_irq: cover property (
                @(posedge clk_i) disable iff (!rst_ni)
                (ctx_state[i] == CTX_WAIT_EVENT) && event_wake[i] &&
                (event_pending[i][EVT_IRQ] & wait_mask[i][EVT_IRQ])
            );
        end
    endgenerate

    // =========================================================================
    // §10.25 D9/R7.3: Trace Ring Integrity
    //
    // Validates the event trace ring buffer behavior:
    //   A. Write pointer range (always < TRACE_DEPTH)
    //   B. Count range (0..TRACE_DEPTH)
    //   C. Overflow implies count == TRACE_DEPTH
    //   D. Clear resets state
    //   E. Freeze blocks writes (wr_ptr stable when frozen)
    //   F. Count monotonic when no clear (never decreases)
    //   G. Cover: trace event recorded during active tracing
    // =========================================================================

    // ── §10.25.A: Write Pointer Range ──
    // [2026-07-24] same truncated-bound defect as event_trace_ring.sv:186 was
    // (TRACE_AW'(TRACE_DEPTH) == 6'(64) == 0 ⇒ `ptr < 0` ⇒ unconditionally false).
    // Fixed here too even though this file is currently bound into NO gate, so it
    // does not re-set the trap for whoever wires it up.
    a_trace_wr_ptr_range: assert property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        {1'b0, trace_wr_ptr} < (TRACE_AW+1)'(TRACE_DEPTH)
    ) else $error("[PE_ASSERT §10.25A] trace_wr_ptr=%0d out of range", trace_wr_ptr);

    // ── §10.25.B: Count Range ──
    a_trace_count_range: assert property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        trace_count <= (TRACE_AW+1)'(TRACE_DEPTH)
    ) else $error("[PE_ASSERT §10.25B] trace_count=%0d exceeds DEPTH=%0d",
                  trace_count, TRACE_DEPTH);

    // ── §10.25.C: Overflow Implies Full ──
    a_trace_overflow_full: assert property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset)
        trace_overflow |-> (trace_count == (TRACE_AW+1)'(TRACE_DEPTH))
    ) else $error("[PE_ASSERT §10.25C] trace overflow but count=%0d != %0d",
                  trace_count, TRACE_DEPTH);

    // ── §10.25.D: Clear Resets State ──
    a_trace_clear_resets: assert property (
        @(posedge clk_i) disable iff (!rst_ni)
        trace_clear |=> (trace_wr_ptr == '0) && !trace_overflow && (trace_count == '0)
    ) else $error("[PE_ASSERT §10.25D] trace_clear did not reset state");

    // ── §10.25.E: Freeze Blocks Writes ──
    //
    // When frozen, wr_ptr and count must not change (no new events recorded).
    a_trace_freeze_stable: assert property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset || trace_clear)
        (trace_freeze && !$past(trace_clear)) |->
            (trace_wr_ptr == $past(trace_wr_ptr)) &&
            (trace_count  == $past(trace_count))
    ) else $error("[PE_ASSERT §10.25E] trace state changed while frozen");

    // ── §10.25.F: Count Monotonic (no clear) ──
    //
    // Between clears, count only increases or stays the same.
    a_trace_count_monotonic: assert property (
        @(posedge clk_i) disable iff (!rst_ni || cp_soft_reset || trace_clear)
        trace_count >= $past(trace_count)
    ) else $error("[PE_ASSERT §10.25F] trace_count decreased: %0d → %0d",
                  $past(trace_count), trace_count);

    // ── §10.25.G: Cover — Event Recorded ──
    c_trace_event_recorded: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        trace_valid && trace_enable && !trace_freeze
    );

    // ── §10.25.H: Cover — Ring Wraps ──
    c_trace_ring_wraps: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        !trace_overflow ##1 trace_overflow
    );

endmodule

// =============================================================================
// Bind Statement
//
// Usage: include this file in testbench compilation.
// The bind attaches pe_assertions to pe_top instance automatically.
//
// Note: The per-bank SRAM signals require hierarchical references
// into l2_subsystem. If your simulator doesn't support deep bind,
// you can instantiate pe_assertions manually in your testbench
// with explicit cross-module references.
// =============================================================================

bind pe_top pe_assertions i_assertions (
    .clk_i             ( clk_i                          ),
    .rst_ni            ( rst_ni                         ),

    // CP / CSR
    .ring_head         ( i_cp.ring_head                 ),
    .ring_tail         ( i_cp.ring_tail                 ),
    .ring_size_log2    ( i_cp.ring_size_log2            ),  // P10
    .doorbell_pulse    ( i_cp.doorbell_pulse            ),
    .ctx_state         ( i_cp.ctx_state                 ),
    .cp_enable         ( i_cp.cp_enable                 ),
    .cp_soft_reset     ( cp_soft_reset                  ),  // P13: pe_top-level wire
    .clear_error       ( i_cp.clear_error               ),  // R3.2c: from cp_csr

    // Scheduler commands
    .vec_cmd_valid     ( vec_cmd_valid                  ),
    .tens_cmd_valid    ( tens_cmd_valid                 ),
    .dma_cmd_valid     ( dma_cmd_valid                  ),
    .vec_cmd_ready     ( vec_cmd_ready                  ),
    .tens_cmd_ready    ( tens_cmd_ready                 ),
    .dma_cmd_ready     ( dma_cmd_ready                  ),

    // Done
    .vec_done          ( vec_done                       ),
    .vec_done_ctx      ( vec_done_ctx                   ),
    .tens_done         ( tens_done                      ),
    .tens_done_ctx     ( tens_done_ctx                  ),
    .dma_done          ( dma_done                       ),
    .dma_done_ctx      ( dma_done_ctx                   ),

    // L2 RO
    .vec_ro_req        ( vec_ro_req                     ),
    .vec_ro_gnt        ( vec_ro_gnt                     ),
    .vec_ro_row        ( vec_ro_row                     ),
    // [PHASE3-B2 §10.5-RO FIX] half-aware §10.5 RO arm; wire driven by
    // vector_unit_top.ro_half_sel_o (pe_top.sv:247/:611). MUST be the RO wire.
    .vec_ro_half_sel   ( vec_ro_half_sel                ),
    .tens_ro_req       ( tens_ro_req                    ),
    .tens_ro_gnt       ( tens_ro_gnt                    ),
    .tens_ro_row       ( tens_ro_row                    ),

    // L2 RW
    .vec_rw_req        ( vec_rw_req                     ),
    .vec_rw_gnt        ( vec_rw_gnt                     ),
    .vec_rw_row        ( vec_rw_row                     ),
    // [C-MX STORE ⑦] mask-aware §10.5 (pe_top.sv:224-225 wires, driven by
    // vector_unit_top.rw_half_sel_o/.rw_bank_mask_o)
    .vec_rw_half_sel   ( vec_rw_half_sel                ),
    .vec_rw_bank_mask  ( vec_rw_bank_mask               ),
    .tens_rw_req       ( tens_rw_req                    ),
    .tens_rw_gnt       ( tens_rw_gnt                    ),
    .tens_rw_row       ( tens_rw_row                    ),
    .dma_fill_req      ( dma_fill_req                   ),
    .dma_fill_gnt      ( dma_fill_gnt                   ),
    .dma_evict_req     ( dma_evict_req                  ),
    .dma_evict_gnt     ( dma_evict_gnt                  ),

    // Per-bank SRAM (hierarchical into l2_subsystem)
    .l2_pa_csb         ( i_l2.pa_csb                    ),
    .l2_pa_web         ( i_l2.pa_web                    ),
    .l2_pa_addr        ( i_l2.pa_addr                   ),
    .l2_pb_csb         ( i_l2.pb_csb                    ),
    .l2_pb_addr        ( i_l2.pb_addr                   ),

    // Slot state (hierarchical into command_processor)
    .slot_current_state ( i_cp.slot_current_state       ),
    .slot_next_state    ( i_cp.slot_next_state          ),

    // Slot lifecycle events (hierarchical into command_processor)
    .fetch_fill_valid   ( i_cp.fetch_fill_valid         ),
    .comp_done          ( i_cp.comp_done                ),

    // Descriptor word0 for ext_len validation
    .slot_current_word0 ( '{i_cp.slot_current[0][0],
                            i_cp.slot_current[1][0],
                            i_cp.slot_current[2][0],
                            i_cp.slot_current[3][0]}    ),

    // R1: Derived slot state from scheduler
    .slot_state_vis     ( i_cp.slot_state_vis           ),

    // R1: Scheduler can_issue
    .can_issue          ( i_cp.i_scheduler.can_issue    ),

    // R3D: Error path observability
    .error_valid        ( i_cp.error_valid              ),
    .error_ctx          ( i_cp.error_ctx                ),
    .error_class        ( i_cp.error_class              ),
    .issue_ok           ( i_cp.i_scheduler.issue_ok     ),
    .issue_ctx          ( i_cp.i_scheduler.sel_ctx      ),

    // R4.2: Credit counter observability
    .vec_credit         ( i_cp.i_scheduler.vec_credit_q  ),
    .tens_credit        ( i_cp.i_scheduler.tens_credit_q ),
    .dma_credit         ( i_cp.i_scheduler.dma_credit_q  ),

    // R4.2: Watchdog observability
    .wd_cnt             ( i_cp.i_scheduler.wd_cnt_q     ),
    .wd_timeout         ( i_cp.i_scheduler.wd_timeout    ),
    .wd_threshold       ( i_cp.i_scheduler.wd_threshold_i ),

    // R5.4: CP-side perf counter observability
    .perf_ctx_blocked   ( i_cp.i_scheduler.perf_ctx_blocked_q  ),
    .perf_ctx_barrier   ( i_cp.i_scheduler.perf_ctx_barrier_q  ),
    .perf_ctx_starved   ( i_cp.i_scheduler.perf_ctx_starved_q  ),
    .perf_total_issue   ( i_cp.i_scheduler.perf_total_issue_q  ),
    .perf_total_done    ( i_cp.i_scheduler.perf_total_done_q   ),

    // R5.4: L2-side perf counter observability
    .perf_l2_conflict   ( i_l2.i_rw_arb.l2_conflict_q   ),
    .perf_l2_vec_stall  ( i_l2.i_rw_arb.l2_vec_stall_q  ),
    .perf_l2_tens_stall ( i_l2.i_rw_arb.l2_tens_stall_q ),
    .perf_l2_dma_stall  ( i_l2.i_rw_arb.l2_dma_stall_q  ),

    // R5.4: Yield observability
    .perf_cnt_en        ( i_cp.perf_cnt_en               ),
    .tens_yield_mode     ( i_cp.tens_yield_mode             ),
    .tens_quota_n        ( i_cp.tens_quota_n                ),
    .tens_consec_cnt     ( i_l2.i_rw_arb.tens_consec_cnt_q ),
    .tens_yield          ( i_l2.i_rw_arb.tens_yield         ),

    // R7.4/D2: DMA 2D observability
    .dma_state          ( i_dma.state_q                   ),
    .dma_wcount         ( i_dma.wcount_q                  ),
    .dma_outer_cnt      ( i_dma.outer_cnt_q               ),
    .dma_eff_outer_count( i_dma.eff_outer_count           ),
    .dma_cur_base_row   ( i_dma.cur_base_row_q            ),
    .dma_inner_done     ( i_dma.inner_done                ),
    .dma_outer_done     ( i_dma.outer_done                ),
    .dma_cmd_q          ( i_dma.cmd_q                     ),
    .noc_ing_ready      ( noc_ing_ready_o                 ),

    // D5/R7.1: Multi-credit tag observability
    .vec_tag_valid      ( i_cp.i_scheduler.vec_tag_valid_q  ),
    .tens_tag_valid     ( i_cp.i_scheduler.tens_tag_valid_q ),
    .dma_tag_valid      ( i_cp.i_scheduler.dma_tag_valid_q  ),
    .vec_tag_ctx        ( i_cp.i_scheduler.vec_tag_ctx_q    ),
    .tens_tag_ctx       ( i_cp.i_scheduler.tens_tag_ctx_q   ),
    .dma_tag_ctx        ( i_cp.i_scheduler.dma_tag_ctx_q    ),
    .vec_done_tag       ( vec_done_tag                       ),
    .tens_done_tag      ( tens_done_tag                      ),
    .dma_done_tag       ( dma_done_tag                       ),

    // D7/R7.2: Event system observability
    .event_pending      ( i_cp.i_scheduler.event_pending_q  ),
    .wait_mask          ( i_cp.i_scheduler.wait_mask_q      ),
    .event_wake         ( i_cp.i_scheduler.event_wake       ),
    .event_clear        ( i_cp.i_scheduler.event_clear_i    ),
    .sel_opcode_raw     ( i_cp.i_scheduler.sel_opcode       ),

    // D9/R7.3: Trace ring observability
    .trace_wr_ptr       ( i_cp.i_trace.wr_ptr_q             ),
    .trace_overflow     ( i_cp.i_trace.overflow_q            ),
    .trace_count        ( i_cp.i_trace.count_q               ),
    .trace_valid        ( i_cp.trace_valid                   ),
    .trace_enable       ( i_cp.trace_enable                  ),
    .trace_freeze       ( i_cp.trace_freeze                  ),
    .trace_clear        ( i_cp.trace_clear                   )
);

`endif // SYNTHESIS

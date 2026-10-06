// =============================================================================
// cp_csr.sv — CP MMIO Register Block (PE v5, Phase 4)
//   (R2A+R2B+R3C+R4.3+R5.3+D7+D9 baseline)
//
// Phase 4 changes:
//   [PHASE4-07] SW ABI field rename in MMIO register 0x2F (PERF_CTRL):
//                 reg_tens_yield_mode  -> reg_tens_yield_mode
//                 reg_tens_quota_n     -> reg_tens_quota_n
//               Output port rename to match:
//                 tens_yield_mode_o    -> tens_yield_mode_o
//                 tens_quota_n_o       -> tens_quota_n_o
//               BIT LAYOUT IS UNCHANGED. MMIO 0x2F still:
//                 [0]     perf_cnt_en
//                 [5:4]   yield_mode  (was vec_yield_mode, now tens_yield_mode)
//                 [11:8]  quota_n     (was vec_quota_n, now tens_quota_n)
//               SW drivers need to update variable names but NO bit-layout
//               changes. This is a documentation-only ABI change for SW.
//   [PHASE4-hygiene] Move w1c_clear declaration to top of enclosing block
//               (was a v4 declaration-after-statement error).
//
// OBI slave presenting CP configuration and status to IBEX.
// All registers are 32-bit aligned. 1-cycle read latency (always grant).
//
// D7: 512B MMIO range (9-bit addr). High half (0x100-0x1FF) adds
//     tag/credit observability and event system registers.
// D9: Trace ring control registers (TRACE_CTRL/STATUS/INDEX/DATA).
//
// Register Map — Low Half (0x00-0xFF):
//
//   Offset  Name              RW    Description
//   ──────  ────              ──    ───────────
//   0x00    CP_CTRL           RW    [0] enable, [1] soft_reset
//   0x04    CP_STATUS         RO    per-ctx state (4-bit nibble-aligned)
//   0x08    CP_IRQ            RW    [11:0] IRQ pending (W1C)
//   0x0C    CP_IRQ_MASK       RW    [11:0] IRQ mask (1=enabled, default all-1)
//   0x10-0x4F  CTXn_RING_*   RW    Ring base/cfg/doorbell/head (4 ctx × 0x10)
//   0x60-0x6C  CTXn_DBG      RO    Last opcode + head/tail snapshot
//   0x70    PE_POWER_CTRL     RW    [2:0] clk_en per unit
//   0x74    RING_WARN         RW    ring_cfg clamp sticky (W1C)
//   0x78    CP_SLOT_STATUS    RO    per-ctx slot_state_e packed
//   0x7C    CTX_TAIL_WARN     RW    tail clamp sticky (W1C)
//   0x80-0x9C  REGION_TABLE   RW    4 × {base_row, num_rows}
//   0xA0    SCOREBOARD        RO    per-unit busy flags
//   0xA4-0xB0  CTXn_ERR      W1C   Error class + opcode snapshot
//   0xB4    CLEAR_ERROR       WO    [3:0] per-ctx CTX_ERROR→CTX_IDLE
//   0xB8    WD_THRESHOLD      RW    Watchdog threshold (0=disabled)
//   0xBC    PERF_CTRL         RW    perf_cnt_en + yield config
//   0xC0-0xFC  Perf counters  RO    blocked/barrier/starved/issue/done/L2
//
// Register Map — High Half (0x100-0x1FF, D5+D7):
//
//   0x100   VEC_TAG_STATUS    RO    [7:0] vec tag inflight bitmap
//   0x104   TENS_TAG_STATUS   RO    [7:0] tens tag inflight bitmap
//   0x108   DMA_TAG_STATUS    RO    [7:0] dma tag inflight bitmap
//   0x10C   CREDIT_STATUS     RO    {dma[2:0],1'b0,tens[2:0],1'b0,vec[2:0]}
//   0x110   EVENT_STATUS_0    RO    [7:0] ctx0 event_pending
//   0x114   EVENT_STATUS_1    RO    [7:0] ctx1 event_pending
//   0x118   EVENT_STATUS_2    RO    [7:0] ctx2 event_pending
//   0x11C   EVENT_STATUS_3    RO    [7:0] ctx3 event_pending
//   0x120   EVENT_CLEAR       WO    [3:0] per-ctx event clear (W1C)
//   0x130   TRACE_CTRL        RW    {28'b0, ovf_irq_en, clear, freeze, enable}
//   0x134   TRACE_STATUS      RO    {overflow, count[TRACE_AW:0], wr_ptr[TRACE_AW-1:0]}
//   0x138   TRACE_INDEX       RW    {26'b0, rd_index[TRACE_AW-1:0]}
//   0x13C   TRACE_DATA        RO    trace_mem[rd_index] (32-bit trace_entry_t)
// =============================================================================

module cp_csr
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── OBI Slave Interface (from addr_decoder) ──
    input  logic        req_i,
    output logic        gnt_o,
    output logic        rvalid_o,
    input  logic [8:0]  addr_i,       // byte offset within 512B (D7: was 256B)
    input  logic        we_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        err_o,

    // ── CP Control ──
    output logic        cp_enable_o,
    output logic        cp_soft_reset_o,

    // ── Per-Ctx Ring Configuration ──
    output logic [11:0] ring_base_o     [NUM_CTX],    // L1D byte addr
    output logic [3:0]  ring_size_log2_o [NUM_CTX],   // log2(entry count)
    output logic [RING_PTR_W-1:0] ring_tail_o [NUM_CTX],   // tail ptr (from doorbell)
    output logic [NUM_CTX-1:0]    doorbell_pulse_o,         // 1-cycle pulse on write

    // ── Per-Ctx Ring Head (from fetch engine, read-only) ──
    input  logic [RING_PTR_W-1:0] ring_head_i [NUM_CTX],

    // ── Context States (from scheduler, read-only) ──
    input  ctx_state_e  ctx_state_i [NUM_CTX],

    // ── Region Table ──
    output region_entry_t region_table_o [NUM_REGIONS],

    // ── Scoreboard (from scheduler, read-only) ──
    input  logic        vec_busy_i,
    input  logic        tens_busy_i,
    input  logic        dma_busy_i,

    // ── R2.8: Power Control (to pe_top, v4: register only) ──
    output logic        vec_clk_en_o,
    output logic        tens_clk_en_o,
    output logic        dma_clk_en_o,

    // ── IRQ ──
    input  logic [NUM_CTX-1:0] irq_set_i,    // from completion (pulse)
    output logic               irq_o,        // OR of all pending IRQs

    // ── R2.7b: Slot State Visibility (from scheduler, combinational) ──
    input  slot_state_e  slot_state_vis_i [NUM_CTX],

    // ── R2.7: Issue Snapshot (from scheduler, pulse on issue) ──
    input  logic                issue_snap_valid_i,
    input  logic [CTX_ID_W-1:0] issue_snap_ctx_i,
    input  logic [7:0]          issue_snap_opcode_i,
    input  logic [3:0]          issue_snap_ext_len_i,

    // ── R3.2b: Error (from scheduler, pulse on poisoned desc) ──
    input  logic                error_valid_i,
    input  logic [CTX_ID_W-1:0] error_ctx_i,
    input  err_class_e          error_class_i,

    // ── R3.2c: Clear Error (to scheduler) ──
    output logic [NUM_CTX-1:0]  clear_error_o,  // pulse: CLEAR_ERROR write

    // ── R4.1: Watchdog Threshold (to scheduler) ──
    output logic [WD_CNT_W-1:0] wd_threshold_o,

    // ── R4.3: Watchdog timeout (from scheduler, per-ctx pulse) ──
    input  logic [NUM_CTX-1:0]  wd_timeout_i,

    // ── R5.1: CP-side Perf Counters (from scheduler) ──
    input  logic [PERF_CNT_W-1:0] perf_ctx_blocked_i   [NUM_CTX],
    input  logic [PERF_CNT_W-1:0] perf_ctx_barrier_i   [NUM_CTX],
    input  logic [PERF_CNT_W-1:0] perf_ctx_starved_i   [NUM_CTX],
    input  logic [PERF_CNT_W-1:0] perf_total_issue_i,
    input  logic [PERF_CNT_W-1:0] perf_total_done_i,

    // ── R5.2: L2-side Perf Counters (from l2_rw_arbiter via pe_top) ──
    input  logic [PERF_CNT_W-1:0] perf_l2_conflict_i,
    input  logic [9:0]            perf_l2_vec_stall_i,
    input  logic [9:0]            perf_l2_tens_stall_i,
    input  logic [9:0]            perf_l2_dma_stall_i,

    // ── R5.3: Performance/Yield Control (to scheduler + l2_rw_arbiter) ──
    output logic                  perf_cnt_en_o,
    output logic [1:0]            tens_yield_mode_o,
    output logic [3:0]            tens_quota_n_o,

    // ── D7: Tag + Credit Observability (from scheduler) ──
    input  logic [TAG_MAX-1:0]             vec_tag_valid_i,
    input  logic [TAG_MAX-1:0]             tens_tag_valid_i,
    input  logic [TAG_MAX-1:0]             dma_tag_valid_i,
    input  logic [SCOREBOARD_CREDIT_W-1:0] vec_credit_i,
    input  logic [SCOREBOARD_CREDIT_W-1:0] tens_credit_i,
    input  logic [SCOREBOARD_CREDIT_W-1:0] dma_credit_i,

    // ── D7: Event System ──
    output logic [NUM_CTX-1:0]             irq_pending_per_ctx_o,
    output logic [NUM_CTX-1:0]             event_clear_o,       // D7: W1C pulse per-ctx
    input  logic [EVT_W-1:0]              event_pending_i [NUM_CTX],

    // ── D9/R7.3: Trace Ring Control ──
    output logic                           trace_enable_o,
    output logic                           trace_freeze_o,
    output logic                           trace_clear_o,       // 1-cycle pulse
    output logic [TRACE_AW-1:0]            trace_rd_index_o,
    input  logic [31:0]                    trace_rd_data_i,
    input  logic [TRACE_AW-1:0]            trace_wr_ptr_i,
    input  logic                           trace_overflow_i,
    input  logic [TRACE_AW:0]              trace_count_i
);

    // =========================================================================
    // OBI Handshake (always grant, 1-cycle rvalid)
    // =========================================================================
    assign gnt_o = req_i;
    assign err_o = 1'b0;

    logic rvalid_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) rvalid_q <= 1'b0;
        else         rvalid_q <= req_i;
    end
    assign rvalid_o = rvalid_q;

    // =========================================================================
    // Register Storage
    // =========================================================================

    // CP_CTRL (0x00)
    logic        reg_enable;
    logic        reg_soft_reset;

    // CP_IRQ (0x08) — multi-source IRQ pending (write-1-to-clear)
    //   [3:0]  IRQ_ON_DONE     (from completion, desc_flags.irq_on_done)
    //   [7:4]  IRQ_ON_ERROR    (from error_valid — poisoned/OOB/bad_param)
    //   [11:8] IRQ_ON_WATCHDOG (from wd_timeout)
    logic [IRQ_TOTAL_W-1:0] reg_irq_pending;

    // CP_IRQ_MASK (0x0C) — per-source-per-ctx enable (1 = IRQ enabled)
    //   Same layout as CP_IRQ. Default: all-1 (all sources enabled).
    logic [IRQ_TOTAL_W-1:0] reg_irq_mask;

    // Per-ctx ring config
    logic [11:0]              reg_ring_base [NUM_CTX];
    logic [3:0]               reg_ring_cfg  [NUM_CTX];
    logic [RING_PTR_W-1:0]    reg_ring_tail [NUM_CTX];

    // Region Table
    region_entry_t reg_region [NUM_REGIONS];

    // R2.3: Per-ctx ring_cfg clamp warning (sticky, W1C)
    logic [NUM_CTX-1:0] reg_ring_warn;

    // R2.2: Per-ctx tail out-of-range warning (sticky, W1C)
    logic [NUM_CTX-1:0] reg_tail_warn;

    // R2.2/R2.3: Per-ctx ring_mask (derived from clamped ring_cfg)
    //   Single source of truth via pe_pkg::ring_mask_from_log2
    logic [RING_PTR_W-1:0] ctx_ring_mask [NUM_CTX];

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++)
            ctx_ring_mask[i] = ring_mask_from_log2(reg_ring_cfg[i]);
    end

    // R2.7: Per-ctx debug snapshot — latched on each issue
    //   {last_opcode[7:0], ext_len[3:0], reserved[3:0], head[PTR_W-1:0], tail[PTR_W-1:0]}
    logic [7:0]            reg_dbg_opcode  [NUM_CTX];
    logic [3:0]            reg_dbg_ext_len [NUM_CTX];

    // R2.8: PE_POWER_CTRL — clock gate enables (v4: register only, ICG in R6)
    logic [2:0] reg_power_ctrl;  // [0] vec_clk_en, [1] tens_clk_en, [2] dma_clk_en

    // R3.2c: Per-ctx error register (latched on error_valid, W1C via CLEAR_ERROR)
    //   Layout: {err_class[3:0], opcode[7:0], ext_len[3:0], 12'b0, head[RING_PTR_W-1:0]}
    logic [31:0] reg_ctx_err [NUM_CTX];

    // R4.1: Watchdog threshold register (0 = disabled, default = 16'hFFFF)
    logic [WD_CNT_W-1:0] reg_wd_threshold;
    assign wd_threshold_o = reg_wd_threshold;

    // R5.3: PERF_CTRL register @0xBC
    //   [0]    perf_cnt_en    — enable perf counters (default 1)
    //   [5:4]  tens_yield_mode — 0=disabled, 1=quota-based (default 0)
    //   [11:8] tens_quota_n    — quota N for yield (default 0)
    logic        reg_perf_cnt_en;
    logic [1:0]  reg_tens_yield_mode;
    logic [3:0]  reg_tens_quota_n;

    assign perf_cnt_en_o    = reg_perf_cnt_en;
    assign tens_yield_mode_o = reg_tens_yield_mode;
    assign tens_quota_n_o    = reg_tens_quota_n;

    // D9/R7.3: Trace ring control registers
    //   TRACE_CTRL @0x130: {28'b0, ovf_irq_en, clear, freeze, enable}
    //   TRACE_INDEX @0x138: {26'b0, rd_index[TRACE_AW-1:0]}
    logic        reg_trace_enable;
    logic        reg_trace_freeze;
    logic        reg_trace_ovf_irq_en;   // reserved for future overflow IRQ
    logic [TRACE_AW-1:0] reg_trace_rd_index;

    assign trace_enable_o   = reg_trace_enable;
    assign trace_freeze_o   = reg_trace_freeze;
    assign trace_rd_index_o = reg_trace_rd_index;

    // =========================================================================
    // Write Logic
    //
    // R2.2b: IRQ uses set-priority pattern (set always wins over W1C clear)
    // R2.2:  Doorbell tail masked with ctx_ring_mask; out-of-range → sticky warn
    // R2.3:  ring_cfg clamped to [RING_CFG_MIN..RING_CFG_MAX]; clamp → sticky warn
    // =========================================================================
    logic [NUM_CTX-1:0] doorbell_wr;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            reg_enable     <= 1'b0;
            reg_soft_reset <= 1'b0;
            reg_irq_pending <= '0;
            reg_irq_mask    <= {IRQ_TOTAL_W{1'b1}};  // R4.3: all IRQs enabled by default

            for (int i = 0; i < NUM_CTX; i++) begin
                reg_ring_base[i] <= '0;
                reg_ring_cfg[i]  <= RING_CFG_MIN;  // R2.3: reset to minimum legal value
                reg_ring_tail[i] <= '0;
            end

            for (int i = 0; i < NUM_REGIONS; i++) begin
                reg_region[i] <= '0;
            end

            reg_ring_warn <= '0;
            reg_tail_warn <= '0;

            for (int i = 0; i < NUM_CTX; i++) begin
                reg_dbg_opcode[i]  <= '0;
                reg_dbg_ext_len[i] <= '0;
            end

            reg_power_ctrl <= 3'b111;  // R2.8: all clocks enabled by default

            for (int i = 0; i < NUM_CTX; i++)
                reg_ctx_err[i] <= '0;

            reg_wd_threshold <= {WD_CNT_W{1'b1}};  // R4.1: default = max (65535 cycles)

            // R5.3: PERF_CTRL defaults
            reg_perf_cnt_en    <= 1'b1;     // counters enabled by default
            reg_tens_yield_mode <= 2'b0;     // yield disabled
            reg_tens_quota_n    <= 4'b0;     // quota = 0

            // D9: Trace ring defaults
            reg_trace_enable     <= 1'b0;   // trace disabled at reset
            reg_trace_freeze     <= 1'b0;
            reg_trace_ovf_irq_en <= 1'b0;
            reg_trace_rd_index   <= '0;
        end else begin
            // ── R4.3: IRQ set-priority pattern (expanded for 3 sources) ──
            //
            // 12-bit pending: [3:0] done, [7:4] error, [11:8] watchdog
            //
            // Set sources (combined into single set vector):
            //   - irq_set_i[3:0]         → done[3:0]  (from completion)
            //   - error_valid_i           → error[error_ctx_i]
            //   - wd_timeout_i[3:0]       → watchdog[3:0] (from scheduler)
            //
            // R2.2b: set-priority pattern preserved — set always wins over W1C.
            begin
                // [PHASE4-hygiene] All declarations at top of block
                // (was a v4 declaration-after-statement error caught by
                //  pyslang; fixed as part of Phase 4 B-chain).
                //
                // Build 12-bit set vector from all sources
                logic [IRQ_TOTAL_W-1:0] irq_set_all;
                // W1C clear: 12-bit from IBEX write to CP_IRQ (0x08)
                logic [IRQ_TOTAL_W-1:0] w1c_clear;

                irq_set_all = '0;
                w1c_clear   = '0;

                // Done: direct from completion router
                irq_set_all[IRQ_DONE_BASE +: NUM_CTX] = irq_set_i;

                // Error: addressed by error_ctx
                if (error_valid_i)
                    irq_set_all[IRQ_ERR_BASE + error_ctx_i] = 1'b1;

                // Watchdog: per-ctx timeout (only set on first timeout,
                // i.e., when ctx is not already in CTX_ERROR)
                irq_set_all[IRQ_WD_BASE +: NUM_CTX] = wd_timeout_i;

                if (req_i & we_i && !addr_i[8] && addr_i[7:2] == 6'h02) begin
                    // be_i[0] covers [7:0], be_i[1] covers [15:8]
                    if (be_i[0]) w1c_clear[7:0]                   = wdata_i[7:0];
                    if (be_i[1]) w1c_clear[IRQ_TOTAL_W-1:8]       = wdata_i[IRQ_TOTAL_W-1:8];
                end

                // Apply: clear first, then set (set wins on conflict)
                reg_irq_pending <= (reg_irq_pending & ~w1c_clear) | irq_set_all;
            end

            // R2.7: Latch issue snapshot into per-ctx debug register
            if (issue_snap_valid_i) begin
                reg_dbg_opcode[issue_snap_ctx_i]  <= issue_snap_opcode_i;
                reg_dbg_ext_len[issue_snap_ctx_i] <= issue_snap_ext_len_i;
            end

            // R3.2c: Latch error info into per-ctx CTX_ERR register
            //   Only updates on error_valid; once latched, stays until CLEAR_ERROR.
            //   Layout: {err_class[31:28], opcode[27:20], ext_len[19:16], 12'b0, head[3:0]}
            if (error_valid_i) begin
                reg_ctx_err[error_ctx_i] <= {error_class_i,
                                              issue_snap_opcode_i,
                                              issue_snap_ext_len_i,
                                              {(16-RING_PTR_W){1'b0}},
                                              ring_head_i[error_ctx_i]};
            end

            // Soft reset: auto-clear after 1 cycle
            if (reg_soft_reset)
                reg_soft_reset <= 1'b0;

            // IBEX writes (low half only — high half is mostly read-only)
            if (req_i & we_i & !addr_i[8]) begin
                case (addr_i[7:2])  // word-aligned offset

                    // 0x00: CP_CTRL
                    6'h00: begin
                        if (be_i[0]) begin
                            reg_enable     <= wdata_i[0];
                            reg_soft_reset <= wdata_i[1];
                        end
                    end

                    // 0x08: CP_IRQ (W1C) — handled above in set-priority block
                    // 6'h02: intentionally no action here

                    // 0x0C: CP_IRQ_MASK — R4.3: per-source-per-ctx enable
                    6'h03: begin
                        if (be_i[0]) reg_irq_mask[7:0]                  <= wdata_i[7:0];
                        if (be_i[1]) reg_irq_mask[IRQ_TOTAL_W-1:8]     <= wdata_i[IRQ_TOTAL_W-1:8];
                    end

                    // ── CTX0 ── (0x10-0x1C)
                    6'h04: if (be_i[0] | be_i[1]) reg_ring_base[0] <= wdata_i[11:0];
                    6'h05: begin  // CTX0_RING_CFG — R2.3: clamp
                        if (be_i[0]) begin
                            automatic logic [3:0] raw  = wdata_i[3:0];
                            automatic logic [3:0] safe = clamp_ring_cfg(raw);
                            reg_ring_cfg[0] <= safe;
                            if (raw != safe) reg_ring_warn[0] <= 1'b1;
                        end
                    end
                    6'h06: begin  // CTX0_DOORBELL — R2.2: mask tail
                        if (be_i[0]) begin
                            automatic logic [RING_PTR_W-1:0] raw_tail  = wdata_i[RING_PTR_W-1:0];
                            automatic logic [RING_PTR_W-1:0] safe_tail = raw_tail & ctx_ring_mask[0];
                            reg_ring_tail[0] <= safe_tail;
                            if (raw_tail != safe_tail) reg_tail_warn[0] <= 1'b1;
                        end
                    end

                    // ── CTX1 ── (0x20-0x2C)
                    6'h08: if (be_i[0] | be_i[1]) reg_ring_base[1] <= wdata_i[11:0];
                    6'h09: begin
                        if (be_i[0]) begin
                            automatic logic [3:0] raw  = wdata_i[3:0];
                            automatic logic [3:0] safe = clamp_ring_cfg(raw);
                            reg_ring_cfg[1] <= safe;
                            if (raw != safe) reg_ring_warn[1] <= 1'b1;
                        end
                    end
                    6'h0A: begin
                        if (be_i[0]) begin
                            automatic logic [RING_PTR_W-1:0] raw_tail  = wdata_i[RING_PTR_W-1:0];
                            automatic logic [RING_PTR_W-1:0] safe_tail = raw_tail & ctx_ring_mask[1];
                            reg_ring_tail[1] <= safe_tail;
                            if (raw_tail != safe_tail) reg_tail_warn[1] <= 1'b1;
                        end
                    end

                    // ── CTX2 ── (0x30-0x3C)
                    6'h0C: if (be_i[0] | be_i[1]) reg_ring_base[2] <= wdata_i[11:0];
                    6'h0D: begin
                        if (be_i[0]) begin
                            automatic logic [3:0] raw  = wdata_i[3:0];
                            automatic logic [3:0] safe = clamp_ring_cfg(raw);
                            reg_ring_cfg[2] <= safe;
                            if (raw != safe) reg_ring_warn[2] <= 1'b1;
                        end
                    end
                    6'h0E: begin
                        if (be_i[0]) begin
                            automatic logic [RING_PTR_W-1:0] raw_tail  = wdata_i[RING_PTR_W-1:0];
                            automatic logic [RING_PTR_W-1:0] safe_tail = raw_tail & ctx_ring_mask[2];
                            reg_ring_tail[2] <= safe_tail;
                            if (raw_tail != safe_tail) reg_tail_warn[2] <= 1'b1;
                        end
                    end

                    // ── CTX3 ── (0x40-0x4C)
                    6'h10: if (be_i[0] | be_i[1]) reg_ring_base[3] <= wdata_i[11:0];
                    6'h11: begin
                        if (be_i[0]) begin
                            automatic logic [3:0] raw  = wdata_i[3:0];
                            automatic logic [3:0] safe = clamp_ring_cfg(raw);
                            reg_ring_cfg[3] <= safe;
                            if (raw != safe) reg_ring_warn[3] <= 1'b1;
                        end
                    end
                    6'h12: begin
                        if (be_i[0]) begin
                            automatic logic [RING_PTR_W-1:0] raw_tail  = wdata_i[RING_PTR_W-1:0];
                            automatic logic [RING_PTR_W-1:0] safe_tail = raw_tail & ctx_ring_mask[3];
                            reg_ring_tail[3] <= safe_tail;
                            if (raw_tail != safe_tail) reg_tail_warn[3] <= 1'b1;
                        end
                    end

                    // ── R2.8: PE_POWER_CTRL (0x70) ──
                    6'h1C: begin
                        if (be_i[0]) reg_power_ctrl <= wdata_i[2:0];
                    end

                    // ── R2.3: RING_WARN (0x74) — W1C ──
                    6'h1D: begin
                        if (be_i[0]) begin
                            for (int i = 0; i < NUM_CTX; i++)
                                if (wdata_i[i]) reg_ring_warn[i] <= 1'b0;
                        end
                    end

                    // ── R2.2: CTX_TAIL_WARN (0x7C) — W1C ──
                    6'h1F: begin
                        if (be_i[0]) begin
                            for (int i = 0; i < NUM_CTX; i++)
                                if (wdata_i[i]) reg_tail_warn[i] <= 1'b0;
                        end
                    end

                    // 0x80-0x9C: Region Table
                    6'h20: if (be_i[0] | be_i[1]) reg_region[0].base_row <= wdata_i[15:0];
                    6'h21: if (be_i[0] | be_i[1]) reg_region[0].num_rows <= wdata_i[15:0];
                    6'h22: if (be_i[0] | be_i[1]) reg_region[1].base_row <= wdata_i[15:0];
                    6'h23: if (be_i[0] | be_i[1]) reg_region[1].num_rows <= wdata_i[15:0];
                    6'h24: if (be_i[0] | be_i[1]) reg_region[2].base_row <= wdata_i[15:0];
                    6'h25: if (be_i[0] | be_i[1]) reg_region[2].num_rows <= wdata_i[15:0];
                    6'h26: if (be_i[0] | be_i[1]) reg_region[3].base_row <= wdata_i[15:0];
                    6'h27: if (be_i[0] | be_i[1]) reg_region[3].num_rows <= wdata_i[15:0];

                    // ── R3.2c: CLEAR_ERROR (0xB4) — per-ctx error clear ──
                    //   Write bit[i]=1 → clear CTX_ERR[i] + pulse clear_error_o[i]
                    //   (scheduler transitions CTX_ERROR → CTX_IDLE on clear_error)
                    6'h2D: begin
                        if (be_i[0]) begin
                            for (int i = 0; i < NUM_CTX; i++) begin
                                if (wdata_i[i])
                                    reg_ctx_err[i] <= '0;
                            end
                        end
                    end

                    // ── R4.1: WD_THRESHOLD (0xB8) — watchdog threshold ──
                    //   [WD_CNT_W-1:0] threshold value. 0 = watchdog disabled.
                    //   Takes effect immediately; running counters NOT reset.
                    //   SW should write 0→disable before reconfiguring if needed.
                    6'h2E: if (be_i[0] | be_i[1])
                               reg_wd_threshold <= wdata_i[WD_CNT_W-1:0];

                    // ── R5.3: PERF_CTRL (0xBC) ──
                    //   [0]    perf_cnt_en
                    //   [5:4]  tens_yield_mode
                    //   [11:8] tens_quota_n
                    6'h2F: begin
                        if (be_i[0]) begin
                            reg_perf_cnt_en    <= wdata_i[0];
                            reg_tens_yield_mode <= wdata_i[5:4];
                        end
                        if (be_i[1])
                            reg_tens_quota_n <= wdata_i[11:8];
                    end

                    default: ; // ignore writes to undefined offsets
                endcase
            end

            // D9: High-half writes (TRACE_CTRL, TRACE_INDEX)
            if (req_i & we_i & addr_i[8]) begin
                case (addr_i[7:2])
                    // 0x130: TRACE_CTRL {28'b0, ovf_irq_en, clear, freeze, enable}
                    6'h0C: begin
                        if (be_i[0]) begin
                            reg_trace_enable     <= wdata_i[0];
                            reg_trace_freeze     <= wdata_i[1];
                            // wdata_i[2] = clear → handled as pulse below
                            reg_trace_ovf_irq_en <= wdata_i[3];
                        end
                    end
                    // 0x138: TRACE_INDEX {26'b0, rd_index[TRACE_AW-1:0]}
                    6'h0E: begin
                        if (be_i[0])
                            reg_trace_rd_index <= wdata_i[TRACE_AW-1:0];
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // R2.2 Simulation Warning: Tail Out-of-Range Detection
    // =========================================================================
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni) begin
            for (int i = 0; i < NUM_CTX; i++) begin
                if (doorbell_wr[i]) begin
                    automatic logic [RING_PTR_W-1:0] raw_t = wdata_i[RING_PTR_W-1:0];
                    if (raw_t != (raw_t & ctx_ring_mask[i]))
                        $warning("[cp_csr R2.2] CTX%0d: tail=0x%h exceeds ring_mask=0x%h, clamped to 0x%h",
                                 i, raw_t, ctx_ring_mask[i], raw_t & ctx_ring_mask[i]);
                end
            end
        end
    end
`endif

    // =========================================================================
    // Doorbell Pulse Generation (combinational, 1-cycle)
    // =========================================================================
    always_comb begin
        doorbell_wr = '0;
        if (req_i & we_i & be_i[0] & !addr_i[8]) begin
            case (addr_i[7:2])
                6'h06: doorbell_wr[0] = 1'b1;   // CTX0_DOORBELL
                6'h0A: doorbell_wr[1] = 1'b1;   // CTX1_DOORBELL
                6'h0E: doorbell_wr[2] = 1'b1;   // CTX2_DOORBELL
                6'h12: doorbell_wr[3] = 1'b1;   // CTX3_DOORBELL
                default: ;
            endcase
        end
    end

    assign doorbell_pulse_o = doorbell_wr;

    // =========================================================================
    // R3.2c: Clear Error Pulse Generation (combinational, 1-cycle)
    //
    // Writing CLEAR_ERROR[i]=1 emits a pulse to scheduler → CTX_ERROR→CTX_IDLE.
    // =========================================================================
    always_comb begin
        clear_error_o = '0;
        if (req_i & we_i & be_i[0] && addr_i[7:2] == 6'h2D && !addr_i[8]) begin
            clear_error_o = wdata_i[NUM_CTX-1:0];
        end
    end

    // =========================================================================
    // D7: Event Clear Pulse Generation (combinational, 1-cycle)
    //
    // Writing EVENT_CLEAR (0x120) with bit[i]=1 clears all event_pending bits
    // for ctx[i]. Pulse routes to scheduler → event_pending_q[i] <= '0.
    //
    // This allows SW to clear stale events without going through CLEAR_ERROR.
    // =========================================================================
    always_comb begin
        event_clear_o = '0;
        if (req_i & we_i & be_i[0] && addr_i[8] && addr_i[7:2] == 6'h08) begin
            event_clear_o = wdata_i[NUM_CTX-1:0];
        end
    end

    // =========================================================================
    // D9: Trace Clear Pulse Generation (combinational, 1-cycle)
    //
    // Writing TRACE_CTRL (0x130) with bit[2]=1 emits a 1-cycle clear pulse.
    // trace_clear_o routes to event_trace_ring → reset wr_ptr + overflow.
    // =========================================================================
    always_comb begin
        trace_clear_o = 1'b0;
        if (req_i & we_i & be_i[0] && addr_i[8] && addr_i[7:2] == 6'h0C) begin
            trace_clear_o = wdata_i[2];
        end
    end

    // =========================================================================
    // Read Logic (registered addr for 1-cycle latency)
    //
    // D7: addr_q expanded to 9-bit for 512B MMIO range.
    //   addr_q[8]   = high-half selector (0x100-0x1FF)
    //   addr_q[7:2] = register index within half
    // =========================================================================
    logic [8:0] addr_q;
    always_ff @(posedge clk_i) begin
        if (req_i) addr_q <= addr_i;
    end

    always_comb begin
        rdata_o = 32'h0;

        if (!addr_q[8]) begin
        // ── Low half: 0x00-0xFF (existing registers) ──
        case (addr_q[7:2])
            // 0x00: CP_CTRL
            6'h00: rdata_o = {30'b0, reg_soft_reset, reg_enable};

            // 0x04: CP_STATUS — D6: use 4-bit per ctx (nibble-aligned)
            // P8 fix: upgraded from 2-bit → 3-bit. D6: 3-bit → 4-bit for CTX_WAIT_EVENT(8).
            //   Layout: [3:0]=ctx0, [7:4]=ctx1, [11:8]=ctx2, [15:12]=ctx3
            6'h01: begin
                for (int i = 0; i < NUM_CTX; i++)
                    rdata_o[i*4 +: 4] = ctx_state_i[i][3:0];
            end

            // 0x08: CP_IRQ (12-bit: [3:0] done, [7:4] error, [11:8] watchdog)
            6'h02: rdata_o = {{(32-IRQ_TOTAL_W){1'b0}}, reg_irq_pending};

            // 0x0C: CP_IRQ_MASK (R4.3)
            6'h03: rdata_o = {{(32-IRQ_TOTAL_W){1'b0}}, reg_irq_mask};

            // CTX0: 0x10-0x1C
            6'h04: rdata_o = {20'b0, reg_ring_base[0]};
            6'h05: rdata_o = {28'b0, reg_ring_cfg[0]};
            6'h06: rdata_o = {{(32-RING_PTR_W){1'b0}}, reg_ring_tail[0]};
            6'h07: rdata_o = {{(32-RING_PTR_W){1'b0}}, ring_head_i[0]};

            // CTX1: 0x20-0x2C
            6'h08: rdata_o = {20'b0, reg_ring_base[1]};
            6'h09: rdata_o = {28'b0, reg_ring_cfg[1]};
            6'h0A: rdata_o = {{(32-RING_PTR_W){1'b0}}, reg_ring_tail[1]};
            6'h0B: rdata_o = {{(32-RING_PTR_W){1'b0}}, ring_head_i[1]};

            // CTX2: 0x30-0x3C
            6'h0C: rdata_o = {20'b0, reg_ring_base[2]};
            6'h0D: rdata_o = {28'b0, reg_ring_cfg[2]};
            6'h0E: rdata_o = {{(32-RING_PTR_W){1'b0}}, reg_ring_tail[2]};
            6'h0F: rdata_o = {{(32-RING_PTR_W){1'b0}}, ring_head_i[2]};

            // CTX3: 0x40-0x4C
            6'h10: rdata_o = {20'b0, reg_ring_base[3]};
            6'h11: rdata_o = {28'b0, reg_ring_cfg[3]};
            6'h12: rdata_o = {{(32-RING_PTR_W){1'b0}}, reg_ring_tail[3]};
            6'h13: rdata_o = {{(32-RING_PTR_W){1'b0}}, ring_head_i[3]};

            // Region Table: 0x80-0x9C
            6'h20: rdata_o = {16'b0, reg_region[0].base_row};
            6'h21: rdata_o = {16'b0, reg_region[0].num_rows};
            6'h22: rdata_o = {16'b0, reg_region[1].base_row};
            6'h23: rdata_o = {16'b0, reg_region[1].num_rows};
            6'h24: rdata_o = {16'b0, reg_region[2].base_row};
            6'h25: rdata_o = {16'b0, reg_region[2].num_rows};
            6'h26: rdata_o = {16'b0, reg_region[3].base_row};
            6'h27: rdata_o = {16'b0, reg_region[3].num_rows};

            // Scoreboard: 0xA0
            6'h28: rdata_o = {29'b0, dma_busy_i, tens_busy_i, vec_busy_i};

            // ── R3.2c: CTX0-3_ERR (0xA4-0xB0) ──
            //   {err_class[31:28], opcode[27:20], ext_len[19:16], 12'b0, head[3:0]}
            6'h29: rdata_o = reg_ctx_err[0];
            6'h2A: rdata_o = reg_ctx_err[1];
            6'h2B: rdata_o = reg_ctx_err[2];
            6'h2C: rdata_o = reg_ctx_err[3];

            // ── R3.2c: CLEAR_ERROR (0xB4) ── read returns 0 (WO register)
            6'h2D: rdata_o = 32'h0;

            // ── R4.1: WD_THRESHOLD (0xB8) ──
            6'h2E: rdata_o = {{(32-WD_CNT_W){1'b0}}, reg_wd_threshold};

            // ── R2.7: CTX0-3_DBG (0x60-0x6C) ──
            //   Packing: {opcode[7:0], ext_len[3:0], reserved[3:0],
            //              head[PTR_W-1:0], tail[PTR_W-1:0]}
            //   head/tail are live (not snapshotted) for maximum visibility.
            6'h18: rdata_o = {reg_dbg_opcode[0], reg_dbg_ext_len[0], 4'b0,
                              {(8-RING_PTR_W){1'b0}}, ring_head_i[0],
                              {(8-RING_PTR_W){1'b0}}, reg_ring_tail[0]};
            6'h19: rdata_o = {reg_dbg_opcode[1], reg_dbg_ext_len[1], 4'b0,
                              {(8-RING_PTR_W){1'b0}}, ring_head_i[1],
                              {(8-RING_PTR_W){1'b0}}, reg_ring_tail[1]};
            6'h1A: rdata_o = {reg_dbg_opcode[2], reg_dbg_ext_len[2], 4'b0,
                              {(8-RING_PTR_W){1'b0}}, ring_head_i[2],
                              {(8-RING_PTR_W){1'b0}}, reg_ring_tail[2]};
            6'h1B: rdata_o = {reg_dbg_opcode[3], reg_dbg_ext_len[3], 4'b0,
                              {(8-RING_PTR_W){1'b0}}, ring_head_i[3],
                              {(8-RING_PTR_W){1'b0}}, reg_ring_tail[3]};

            // ── R2.8: PE_POWER_CTRL (0x70) ──
            6'h1C: rdata_o = {29'b0, reg_power_ctrl};

            // ── R2.3: RING_WARN (0x74) ──
            6'h1D: rdata_o = {28'b0, reg_ring_warn};

            // ── R2.7b: CP_SLOT_STATUS (0x78) ──
            //   Per-ctx 2-bit slot_state_e: [1:0]=ctx0, [3:2]=ctx1,
            //   [5:4]=ctx2, [7:6]=ctx3
            6'h1E: begin
                for (int i = 0; i < NUM_CTX; i++)
                    rdata_o[i*2 +: 2] = slot_state_vis_i[i][1:0];
            end

            // ── R2.2: CTX_TAIL_WARN (0x7C) ──
            6'h1F: rdata_o = {28'b0, reg_tail_warn};

            // ── R5.3: PERF_CTRL (0xBC) ──
            6'h2F: rdata_o = {20'b0, reg_tens_quota_n, 2'b0,
                              reg_tens_yield_mode, 3'b0, reg_perf_cnt_en};

            // ── R5.1: CTX0-3_BLOCKED_CYC (0xC0-0xCC) ──
            6'h30: rdata_o = perf_ctx_blocked_i[0];
            6'h31: rdata_o = perf_ctx_blocked_i[1];
            6'h32: rdata_o = perf_ctx_blocked_i[2];
            6'h33: rdata_o = perf_ctx_blocked_i[3];

            // ── R5.1: CTX0-3_BARRIER_CYC (0xD0-0xDC) ──
            6'h34: rdata_o = perf_ctx_barrier_i[0];
            6'h35: rdata_o = perf_ctx_barrier_i[1];
            6'h36: rdata_o = perf_ctx_barrier_i[2];
            6'h37: rdata_o = perf_ctx_barrier_i[3];

            // ── R5.1: CTX0-3_STARVED_CYC (0xE0-0xEC) ──
            6'h38: rdata_o = perf_ctx_starved_i[0];
            6'h39: rdata_o = perf_ctx_starved_i[1];
            6'h3A: rdata_o = perf_ctx_starved_i[2];
            6'h3B: rdata_o = perf_ctx_starved_i[3];

            // ── R5.1: TOTAL_ISSUE_CNT (0xF0) ──
            6'h3C: rdata_o = perf_total_issue_i;

            // ── R5.1: TOTAL_DONE_CNT (0xF4) ──
            6'h3D: rdata_o = perf_total_done_i;

            // ── R5.2: L2_CONFLICT_CNT (0xF8) ──
            6'h3E: rdata_o = perf_l2_conflict_i;

            // ── R5.2: L2_STALL_PACKED (0xFC) ──
            //   {dma_stall[9:0], tens_stall[9:0], vec_stall[9:0], 2'b0}
            6'h3F: rdata_o = {perf_l2_dma_stall_i,
                              perf_l2_tens_stall_i,
                              perf_l2_vec_stall_i, 2'b0};

            default: rdata_o = 32'h0;
        endcase
        end else begin
        // ── High half: 0x100-0x1FF (D5/D7 registers) ──
        case (addr_q[7:2])
            // 0x100: VEC_TAG_STATUS (RO) — [TAG_MAX-1:0] vec tag bitmap
            6'h00: rdata_o = {{(32-TAG_MAX){1'b0}}, vec_tag_valid_i};

            // 0x104: TENS_TAG_STATUS (RO) — [TAG_MAX-1:0] tens tag bitmap
            6'h01: rdata_o = {{(32-TAG_MAX){1'b0}}, tens_tag_valid_i};

            // 0x108: DMA_TAG_STATUS (RO) — [TAG_MAX-1:0] dma tag bitmap
            6'h02: rdata_o = {{(32-TAG_MAX){1'b0}}, dma_tag_valid_i};

            // 0x10C: CREDIT_STATUS (RO) — packed credit counters
            //   [CREDIT_W-1:0]          vec_credit
            //   [CREDIT_W+CREDIT_W:CREDIT_W+1] tens_credit (1-bit gap)
            //   [2*CREDIT_W+1+CREDIT_W:2*(CREDIT_W+1)]  dma_credit
            6'h03: rdata_o = {20'b0,
                              dma_credit_i, 1'b0,
                              tens_credit_i, 1'b0,
                              vec_credit_i};

            // 0x110-0x11C: EVENT_STATUS[0-3] (RO) — per-ctx event_pending
            6'h04: rdata_o = {{(32-EVT_W){1'b0}}, event_pending_i[0]};
            6'h05: rdata_o = {{(32-EVT_W){1'b0}}, event_pending_i[1]};
            6'h06: rdata_o = {{(32-EVT_W){1'b0}}, event_pending_i[2]};
            6'h07: rdata_o = {{(32-EVT_W){1'b0}}, event_pending_i[3]};

            // 0x120: EVENT_CLEAR (WO) — read returns 0
            6'h08: rdata_o = 32'h0;

            // 0x130: TRACE_CTRL (RW) — {28'b0, ovf_irq_en, clear_ro=0, freeze, enable}
            6'h0C: rdata_o = {28'b0, reg_trace_ovf_irq_en, 1'b0,
                              reg_trace_freeze, reg_trace_enable};

            // 0x134: TRACE_STATUS (RO)
            //   [31]              overflow (sticky)
            //   [22:16]          count[TRACE_AW:0] (0..TRACE_DEPTH)
            //   [TRACE_AW-1+8:8] (unused, same as count)
            //   [TRACE_AW-1:0]   wr_ptr
            6'h0D: begin
                rdata_o = '0;
                rdata_o[31]             = trace_overflow_i;
                rdata_o[16+:TRACE_AW+1] = trace_count_i;
                rdata_o[0+:TRACE_AW]    = trace_wr_ptr_i;
            end

            // 0x138: TRACE_INDEX (RW) — {26'b0, rd_index[TRACE_AW-1:0]}
            6'h0E: rdata_o = {{(32-TRACE_AW){1'b0}}, reg_trace_rd_index};

            // 0x13C: TRACE_DATA (RO) — trace_mem[rd_index]
            6'h0F: rdata_o = trace_rd_data_i;

            default: rdata_o = 32'h0;
        endcase
        end
    end

    // =========================================================================
    // Output Assignments
    // =========================================================================
    assign cp_enable_o     = reg_enable;
    assign cp_soft_reset_o = reg_soft_reset;

    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_ring_out
            assign ring_base_o[i]      = reg_ring_base[i];
            assign ring_size_log2_o[i] = reg_ring_cfg[i];
            assign ring_tail_o[i]      = reg_ring_tail[i];
        end
    endgenerate

    generate
        for (genvar i = 0; i < NUM_REGIONS; i++) begin : gen_region_out
            assign region_table_o[i] = reg_region[i];
        end
    endgenerate

    // IRQ: OR of all masked pending bits (R4.3: mask-gated)
    assign irq_o = |(reg_irq_pending & reg_irq_mask);

    // D7: Per-ctx masked IRQ pending (for event system EVT_IRQ)
    //
    // For each ctx, OR the masked done/error/watchdog IRQ bits.
    // This feeds cp_scheduler event_set[i][EVT_IRQ].
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_irq_per_ctx
            assign irq_pending_per_ctx_o[i] =
                (reg_irq_pending[IRQ_DONE_BASE + i] & reg_irq_mask[IRQ_DONE_BASE + i]) |
                (reg_irq_pending[IRQ_ERR_BASE  + i] & reg_irq_mask[IRQ_ERR_BASE  + i]) |
                (reg_irq_pending[IRQ_WD_BASE   + i] & reg_irq_mask[IRQ_WD_BASE   + i]);
        end
    endgenerate

    // R2.8: Power control outputs (v4: register only, ICG instantiation in R6)
    assign vec_clk_en_o  = reg_power_ctrl[0];
    assign tens_clk_en_o = reg_power_ctrl[1];
    assign dma_clk_en_o  = reg_power_ctrl[2];

endmodule

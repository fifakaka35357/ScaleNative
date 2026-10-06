// =============================================================================
// tensor_unit_top.sv — Tensor Execution Domain Wrapper Top (512b)
//
// [STEP4-E2E, increment 3c] The wrapper now instantiates the REAL Tensor unit
// (Tensor/tensor_unit_top) behind the stable PE-facing interface, replacing the
// traffic-gen stub. It composes three tested pieces (plan §9 D-E2E-1/2/5):
//
//   1. tensor_operand_stream (3b) — on a command it streams the operand tile
//      from L2 (the wrapper's L2 RO master) into the real Tensor's internal
//      weight/activation/scale SRAM via its dma_*_wr_* ports.
//   2. tensor_cmd_mmio_seq (3a) — once the operands are resident (load_done),
//      it drives the MMIO start sequence (Class A = OUT_FWD_VEC_NATIVE) and
//      waits for tu_tile_done.
//   3. the real Tensor/tensor_unit_top — runs the GEMM and egresses one
//      bs_capsule_t per row, which this wrapper forwards on the fast-path
//      egress port (-> tv_fast_fifo -> Vector, wired in pe_top increment 4).
//
// Sequencing FSM: IDLE -> STREAM (load operands) -> MMIO (run GEMM) -> done.
// The Tensor no longer writes L2 (results egress as capsules), so the wrapper's
// L2 RW master ports are tied off. SRAM destination rows used by the streamer
// equal the MMIO WGT/ACT/SCL_BASE values (base coupling): wgt/act bank base =
// src_row, scale bank base = 0. Operand row counts / L2 source bases are derived
// from the command here and TUNED against the real GEMM at the E2E (increment 5).
// =============================================================================

// NOTE: this wrapper is named `tensor_domain_top` (not tensor_unit_top) to avoid
// a module-name collision with the REAL Tensor/tensor_unit_top it instantiates.
// pe_top instantiates `tensor_domain_top i_tens`.
module tensor_domain_top
    import pe_pkg::*;
    import tensor_pkg::*;
#(
    parameter int T_ROWS  = 16,
    parameter int T_COLS  = 16,
    parameter int T_DW    = 16,
    parameter int T_ADDRW = 12
) (
    // ── Clock / Reset ──
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          soft_reset_i,
    input  logic                          test_en_i,     // DFT: bypass soft reset in scan mode

    // ── Command Interface (from cp_scheduler) ──
    input  logic                          cmd_valid_i,
    output logic                          cmd_ready_o,
    input  tens_cmd_t                     cmd_i,

    // ── L2 RO Port (FULL_STRIPE_W = 512b, 16 banks) — used by the streamer ──
    output logic                          ro_req_o,
    input  logic                          ro_gnt_i,
    input  logic                          ro_rvalid_i,
    output logic [L2_BANK_AW-1:0]         ro_row_o,
    input  logic [FULL_STRIPE_W-1:0]      ro_rdata_i,

    // ── L2 RW Port (retired — Tensor egresses capsules, does not write L2) ──
    output logic                          rw_req_o,
    input  logic                          rw_gnt_i,
    output logic [L2_BANK_AW-1:0]         rw_row_o,
    output logic [L2_NUM_BANKS-1:0]       rw_bank_mask_o,
    output logic [FULL_STRIPE_W-1:0]      rw_wdata_o,

    // ── Fast Path Egress (Tensor → Vector), full bs_capsule_t (Q1) ──
    output logic                          t2v_valid_o,
    input  logic                          t2v_ready_i,
    output bs_capsule_t                   t2v_cap_o,
    output logic                          t2v_escape_o,

    // ── Completion ──
    output logic                          done_o,
    output logic [CTX_ID_W-1:0]           done_ctx_o,
    output logic [TAG_W-1:0]              done_tag_o,

    // ── Status / Observability ──
    output logic                          unit_idle_o,
    output logic                          contract_violation_o
);
    // =========================================================================
    // Sequencing FSM: IDLE -> STREAM (load operands) -> MMIO (run GEMM)
    // =========================================================================
    typedef enum logic [1:0] { W_IDLE, W_STREAM, W_MMIO } wstate_e;
    wstate_e   ws_q, ws_d;
    tens_cmd_t cmd_q;
    logic      mmio_fired_q, mmio_fired_d;

    logic str_load_done, str_busy;
    logic mmio_cmd_ready, mmio_done;

    // =========================================================================
    // [FIX 2026-07-12, pre-tapeout audit] Domain-level soft reset.
    //
    // soft_reset_i was declared but SWALLOWED by the lint tie-off below, so a
    // firmware CP_CTRL[1] abort left the entire Tensor domain running: the
    // wrapper FSM stayed mid-tile, cmd_ready_o stuck at 0 => the CP could never
    // issue another tensor command without a hard reset, and a stale mmio done
    // could still fire and corrupt CP credits. Vector / DMA / L2 all honour
    // cp_soft_reset (command_processor.sv:103 "exec units need soft_reset to
    // abort inflight operations") — the Tensor domain now does too.
    //
    // The real Tensor core (tensor_unit_top) has no soft-reset port and is a
    // frozen, cell-exact-verified block, so we abort it the standard way: gate
    // its reset. soft_reset_i is a registered CSR output (cp_csr), hence
    // glitch-free, and its deassertion is clock-aligned => synchronous release.
    // =========================================================================
    // [2026-07-12 DFT contract] test_en_i bypasses the soft reset.
    //
    // Same hazard as the clock gates: during scan shift, soft_reset_i is driven by
    // a cp_csr flop that is ITSELF on the scan chain, so it toggles pseudo-randomly
    // as the pattern shifts in. Without this override it would asynchronously reset
    // every flop in the Tensor domain mid-shift and destroy the scan pattern. The
    // tape-out partner runs their own DFT insertion on this RTL, so the override has
    // to live here.
    logic dom_rst_n;
    assign dom_rst_n = rst_ni && !(soft_reset_i && !test_en_i);

    // Do not advertise readiness or completion while the abort is in flight.
    assign cmd_ready_o = (ws_q == W_IDLE) && !soft_reset_i;

    logic str_start;
    assign str_start      = (ws_q == W_IDLE) && cmd_valid_i;   // 1-cycle kick
    logic mmio_cmd_valid;
    assign mmio_cmd_valid = (ws_q == W_MMIO) && !mmio_fired_q;

    always_comb begin
        ws_d         = ws_q;
        mmio_fired_d = mmio_fired_q;
        unique case (ws_q)
            W_IDLE:   if (cmd_valid_i) ws_d = W_STREAM;
            W_STREAM: if (str_load_done) begin ws_d = W_MMIO; mmio_fired_d = 1'b0; end
            W_MMIO: begin
                if (mmio_cmd_valid && mmio_cmd_ready) mmio_fired_d = 1'b1;
                if (mmio_done)                        ws_d = W_IDLE;
            end
            default: ws_d = W_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge dom_rst_n) begin
        if (!dom_rst_n) begin
            ws_q <= W_IDLE; cmd_q <= '0; mmio_fired_q <= 1'b0;
        end else begin
            ws_q <= ws_d; mmio_fired_q <= mmio_fired_d;
            if (ws_q == W_IDLE && cmd_valid_i) cmd_q <= cmd_i;
        end
    end

    // =========================================================================
    // Operand-tile shape (derived from the command; TUNED at the E2E, §9.5).
    //   row counts: weights/acts = param_K rows, scales = 1 row.
    //   L2 source: contiguous regions starting at src_row.
    //   SRAM dest: wgt/act bank base = src_row, scale bank base = 0 — these MUST
    //   equal the MMIO WGT/ACT/SCL_BASE the start FSM programs (base coupling).
    // =========================================================================
    logic [15:0] n_wgt, n_act, n_scl;
    assign n_wgt = cmd_q.param_K;
    assign n_act = cmd_q.param_K;
    assign n_scl = 16'd1;

    logic [L2_BANK_AW-1:0] l2_wgt_base, l2_act_base, l2_scl_base;
    assign l2_wgt_base = cmd_q.src_row;
    assign l2_act_base = cmd_q.src_row + L2_BANK_AW'(n_wgt);
    assign l2_scl_base = cmd_q.src_row + L2_BANK_AW'(n_wgt) + L2_BANK_AW'(n_act);

    logic [T_ADDRW-1:0] sram_wgt_base, sram_act_base, sram_scl_base;
    assign sram_wgt_base = T_ADDRW'(cmd_q.src_row);
    assign sram_act_base = T_ADDRW'(cmd_q.src_row);
    assign sram_scl_base = '0;

    // =========================================================================
    // 3b — operand streamer (drives L2 RO + the Tensor DMA write ports)
    // =========================================================================
    logic               dma_wgt_en,  dma_act_en,  dma_scale_en;
    logic [T_ADDRW-1:0] dma_wgt_addr, dma_act_addr, dma_scale_addr;
    logic [T_DW-1:0]    dma_wgt_data [T_COLS];
    logic [T_DW-1:0]    dma_act_data [T_ROWS];
    logic [7:0]         dma_scl_wgt  [T_COLS];
    logic [7:0]         dma_scl_act  [T_ROWS];

    tensor_operand_stream #(.ADDR_WIDTH(T_ADDRW), .DATA_WIDTH(T_DW), .LANES(T_COLS)) u_stream (
        .clk_i,
        .rst_ni        ( dom_rst_n     ),   // [FIX 2026-07-12] abort on cp_soft_reset
        .start_i       ( str_start     ),
        .busy_o        ( str_busy      ),
        .load_done_o   ( str_load_done ),
        .n_wgt_i       ( n_wgt ), .n_act_i ( n_act ), .n_scl_i ( n_scl ),
        .l2_wgt_base_i ( l2_wgt_base ), .l2_act_base_i ( l2_act_base ), .l2_scl_base_i ( l2_scl_base ),
        .sram_wgt_base_i( sram_wgt_base ), .sram_act_base_i( sram_act_base ), .sram_scl_base_i( sram_scl_base ),
        .ro_req_o, .ro_gnt_i, .ro_rvalid_i, .ro_row_o, .ro_rdata_i,
        .dma_wgt_wr_en_o( dma_wgt_en ), .dma_wgt_wr_addr_o( dma_wgt_addr ), .dma_wgt_wr_data_o( dma_wgt_data ),
        .dma_act_wr_en_o( dma_act_en ), .dma_act_wr_addr_o( dma_act_addr ), .dma_act_wr_data_o( dma_act_data ),
        .dma_scale_wr_en_o( dma_scale_en ), .dma_scale_wr_addr_o( dma_scale_addr ),
        .dma_scale_wr_data_wgt_o( dma_scl_wgt ), .dma_scale_wr_data_act_o( dma_scl_act )
    );

    // =========================================================================
    // 3a — MMIO start sequence (gated by load_done via the sequencing FSM)
    // =========================================================================
    logic        mmio_wr_valid;
    logic [7:0]  mmio_wr_addr;
    logic [31:0] mmio_wr_data;

    tensor_cmd_mmio_seq #(.ADDR_WIDTH(T_ADDRW)) u_mmio (
        .clk_i,
        .rst_ni          ( dom_rst_n      ),   // [FIX 2026-07-12] abort on cp_soft_reset
        .cmd_valid_i     ( mmio_cmd_valid ),
        .cmd_ready_o     ( mmio_cmd_ready ),
        .cmd_i           ( cmd_q          ),
        .tile_done_i     ( tu_tile_done   ),
        .mmio_wr_valid_o ( mmio_wr_valid  ),
        .mmio_wr_addr_o  ( mmio_wr_addr   ),
        .mmio_wr_data_o  ( mmio_wr_data   ),
        .done_o          ( mmio_done      ),
        .done_ctx_o      ( done_ctx_o     ),
        .done_tag_o      ( done_tag_o     ),
        .busy_o          ( /* unused */   )
    );

    // [FIX 2026-07-12] Never emit a completion while an abort is in flight — a
    // stale done would credit the CP for a context it just cancelled.
    assign done_o = mmio_done && !soft_reset_i;

    // =========================================================================
    // Real Tensor Unit
    // =========================================================================
    logic tu_busy, tu_tile_done, tu_capture_done, tu_scan_done, tu_wb_done;
    logic [31:0] tu_mmio_rd_data;

    // unused-input tie-offs (native store / scale-row are not wired in this phase)
    // [3a-1 S4 2026-08-03] `sparse_tensor_frag_t sparse_zero` 声明与赋值已删
    //   （其唯一消费点 = 下方三条 sparse ingress tie，同 commit 删除）。

    tensor_unit_top u_tensor (
        .clk    ( clk_i     ),
        .rst_n  ( dom_rst_n ),   // [FIX 2026-07-12] cp_soft_reset aborts the core
                                 // (the core is frozen/cell-exact-verified and has
                                 //  no soft-reset port; reset gating is the abort)

        // MMIO command (writes from the start FSM; read side unused)
        .mmio_wr_valid ( mmio_wr_valid ),
        .mmio_wr_addr  ( mmio_wr_addr  ),
        .mmio_wr_data  ( mmio_wr_data  ),
        .mmio_rd_addr  ( 8'd0          ),
        .mmio_rd_data  ( tu_mmio_rd_data ),
        .counter_clear ( 1'b0 ),

        // DMA operand load (from the streamer)
        .dma_wgt_wr_en   ( dma_wgt_en   ),
        .dma_wgt_wr_addr ( dma_wgt_addr ),
        .dma_wgt_wr_data ( dma_wgt_data ),
        .dma_act_wr_en   ( dma_act_en   ),
        .dma_act_wr_addr ( dma_act_addr ),
        .dma_act_wr_data ( dma_act_data ),
        .dma_scale_wr_en       ( dma_scale_en   ),
        .dma_scale_wr_addr     ( dma_scale_addr ),
        .dma_scale_wr_data_wgt ( dma_scl_wgt    ),
        .dma_scale_wr_data_act ( dma_scl_act    ),

        // [3a-1 S4] sparse ingress 三条 tie 已删（端口已不存在）

        // egress capsule -> fast-path egress
        .egress_frag_capsule   ( t2v_cap_o    ),
        .egress_frag_escape    ( t2v_escape_o ),
        .egress_frag_valid     ( t2v_valid_o  ),
        .egress_frag_ready     ( t2v_ready_i  ),
        .egress_frag_row_idx   ( /* unused */ ),
        .egress_frag_last_row  ( /* unused */ ),
        .egress_frag_out_class ( /* unused */ ),
        .egress_frag_out_fmt   ( /* unused */ ),
        .egress_frag_epoch     ( /* unused */ ),

        // native store (Class B) — unused (we use Class A egress)
        .native_wr_en   ( /* unused */ ),
        .native_wr_addr ( /* unused */ ),
        .native_wr_data ( /* unused */ ),

        // [P4/D-CONV-BASE] converter-based widened FP writeback — unused here
        .ofu_wr_en      ( /* unused (CONVERTER_BASED) */ ),
        .ofu_wr_addr    ( /* unused (CONVERTER_BASED) */ ),
        .ofu_wr_data    ( /* unused (CONVERTER_BASED) */ ),
        .pmac_ofu_digest( /* unused (CONVERTER_PER_MAC) */ ),

        // status
        .tu_busy         ( tu_busy         ),
        .tu_tile_done    ( tu_tile_done    ),
        .tu_capture_done ( tu_capture_done ),
        .tu_scan_done    ( tu_scan_done    ),
        .tu_wb_done      ( tu_wb_done      )
    );

    // =========================================================================
    // L2 RW retired; status
    // =========================================================================
    assign rw_req_o       = 1'b0;
    assign rw_row_o       = '0;
    assign rw_bank_mask_o = '0;
    assign rw_wdata_o     = '0;

    assign unit_idle_o          = (ws_q == W_IDLE) && !str_busy && !tu_busy && !done_o;
    assign contract_violation_o = 1'b0;

    // synthesis translate_off
    // verilator lint_off UNUSED
    // [FIX 2026-07-12] soft_reset_i removed from the tie-off — it is now REAL
    // (dom_rst_n / cmd_ready_o / done_o). cmd_i was also wrongly listed here
    // despite being used at the FSM capture (cmd_q <= cmd_i); dropped too.
    wire _unused = &{1'b0, rw_gnt_i, tu_mmio_rd_data,
                     tu_capture_done, tu_scan_done, tu_wb_done};
    // verilator lint_on UNUSED
    // synthesis translate_on
endmodule

// ============================================================================
// tb_cp_pe_fetch_e2e.sv — STEP4-E2E §11.2 (D-E2E-BENCH pe_top-level fetch bench).
//
// Drives the REAL command_processor (cp_csr + cp_desc_fetch + cp_scheduler +
// cp_completion + dual-slot FSM + trace ring) to FETCH and ISSUE one ctx0
// descriptor from a behavioral L1D, with NO ibex CPU. This finally exercises the
// layer P1 mocked: MMIO ring/region programming, descriptor fetch + validation,
// the completion-driven slot lifecycle, auto-promote, and CTX_DONE/CTX_ERROR.
//
// pe_top itself cannot be driven without ibex (its data-OBI master is an ibex
// output; L1D has no preload port) — so this thin top wires command_processor's
// clean MMIO slave + L1D fetch port directly. A tiny behavioral L1D RAM serves
// the descriptor with the real 1-cycle latency + {bank1,bank0} 64b packing.
// ============================================================================
module tb_cp_pe_fetch_e2e
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,

    // ── command_processor MMIO slave (tb programs ring/region/doorbell) ──
    input  logic         mmio_req_i,
    input  logic [8:0]   mmio_addr_i,
    input  logic         mmio_we_i,
    input  logic [3:0]   mmio_be_i,
    input  logic [31:0]  mmio_wdata_i,
    output logic         mmio_gnt_o,
    output logic         mmio_rvalid_o,
    output logic [31:0]  mmio_rdata_o,

    // ── descriptor image (8x32) + ring base (for behavioral L1D addressing) ──
    input  logic [255:0] desc_i,
    input  logic [11:0]  ring_base_i,         // byte addr; matches MMIO CTX0_RING_BASE

    // ── T2V capsule injection (the STORE operand) ──
    input  logic         cap_valid_i,
    output logic         cap_ready_o,
    input  logic [BS_CAP_PAYLOAD_W-1:0] cap_payload_i,
    input  logic [1:0]   cap_role_i,
    input  logic [1:0]   cap_block_size_i,
    input  logic [2:0]   cap_scale_format_i,
    input  logic [7:0]   cap_inline_scale_i,
    input  logic [7:0]   cap_scale_epoch_i,
    input  logic         cap_fwd_i,
    output logic         miss_valid_o,
    output logic [3:0]   miss_reason_o,

    // ── L2 RW capture (tb model; P2 covers the real l2 landing) ──
    input  logic         rw_gnt_i,
    output logic         rw_req_o,
    output logic         rw_half_sel_o,
    output logic [L2_BANK_AW-1:0]    rw_row_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,

    // ── observability ──
    output logic         vec_cmd_valid_o,
    output logic         issue_half_sel_o,
    output logic [7:0]   issue_opcode_o,
    output logic         issue_src1_resident_o,    // [T3-FF/FF1] resident SRC1 select
    output logic [15:0]  issue_src1_scale_ref_o,   // [T3-FF/FF1] per-residual abs block exp
    output logic [L2_BANK_AW-1:0] issue_sidecar_base_o, // [T3-FF/FF3b-c] xlat'd physical scale-sidecar row
    output logic         vec_done_o,
    output logic         vu_err_o,
    output logic [2:0]   vu_state_o,
    output logic [3:0]   ctx0_state_o,        // ctx_state_e of ctx0 (CTX_DONE=7? see enum)
    output logic         cp_err_valid_o,
    output logic [3:0]   cp_err_class_o,
    output logic         cp_irq_o
);

    // =========================================================================
    // command_processor <-> vector_unit_top wiring
    // =========================================================================
    logic                  l1d_req;
    logic [L1D_BANK_AW-1:0] l1d_addr;
    logic [63:0]           l1d_rdata;
    logic                  l1d_rvalid;

    logic        vec_cmd_valid, vec_cmd_ready;
    vec_cmd_t    vec_cmd;
    logic        tens_cmd_valid_unused, dma_cmd_valid_unused;
    tens_cmd_t   tens_cmd_unused;
    dma_cmd_t    dma_cmd_unused;

    logic              vu_done;
    logic [1:0]        vu_done_ctx;
    logic [TAG_W-1:0]  vu_done_tag;
    logic              cp_soft_reset;

    assign vec_cmd_valid_o  = vec_cmd_valid;
    assign issue_half_sel_o = vec_cmd.contract.half_sel;
    assign issue_opcode_o   = vec_cmd.opcode;
    assign issue_src1_resident_o  = vec_cmd.contract.src1_resident;   // [T3-FF/FF1]
    assign issue_src1_scale_ref_o = vec_cmd.contract.src1_scale_ref;  // [T3-FF/FF1]
    assign issue_sidecar_base_o   = vec_cmd.sidecar_base;             // [T3-FF/FF3b-c]
    assign vec_done_o       = vu_done;

    // debug taps (read-only hierarchical refs)
    assign ctx0_state_o   = i_cp.ctx_state[0];
    assign cp_err_valid_o = i_cp.error_valid;
    assign cp_err_class_o = i_cp.error_class;
    assign vu_state_o     = u_vec.u_vector_unit.state_q;

    // ── injected capsule ──
    bs_capsule_t cap;
    fp_miss_reason_e miss_reason;
    always_comb begin
        cap                    = '0;
        cap.payload            = cap_payload_i;
        cap.elem_fmt           = ELEM_BFP_INTERNAL;
        cap.block_size         = block_size_sel_e'(cap_block_size_i);
        cap.scale_format       = scale_format_e'(cap_scale_format_i);
        cap.layout_tag         = 4'd0;
        cap.inline_scale       = {24'd0, cap_inline_scale_i};
        cap.scale_inline_valid = 1'b1;
        cap.scale_epoch        = cap_scale_epoch_i;
        cap.fwd_eligible       = cap_fwd_i;
        cap.operand_role       = operand_role_e'(cap_role_i);
    end
    assign miss_reason_o = miss_reason;

    // =========================================================================
    // Behavioral L1D descriptor RAM — 1-cycle latency, {bank1=odd, bank0=even}.
    // l1d_addr = (ring_base + head*32 + pair*8) >> 3; head=0 -> k = addr - base_w.
    // =========================================================================
    logic                  req_q;
    logic [L1D_BANK_AW-1:0] addr_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin req_q <= 1'b0; addr_q <= '0; end
        else        begin req_q <= l1d_req; addr_q <= l1d_addr; end
    end
    assign l1d_rvalid = req_q;

    logic [31:0] dw [8];
    always_comb for (int i = 0; i < 8; i++) dw[i] = desc_i[i*32 +: 32];
    logic [L1D_BANK_AW-1:0] base_w, kidx;
    assign base_w = ring_base_i[11:3];
    assign kidx   = addr_q - base_w;
    always_comb begin
        unique case (kidx)
            'd0:     l1d_rdata = {dw[1], dw[0]};
            'd1:     l1d_rdata = {dw[3], dw[2]};
            'd2:     l1d_rdata = {dw[5], dw[4]};
            'd3:     l1d_rdata = {dw[7], dw[6]};
            default: l1d_rdata = 64'd0;
        endcase
    end

    // =========================================================================
    // L2 RW capture (tb model)
    // =========================================================================
    logic [(L2_NUM_BANKS/2)-1:0] vu_rw_mask;

    // =========================================================================
    // Real command_processor
    // =========================================================================
    command_processor i_cp (
        .clk_i, .rst_ni,
        .mmio_req_i, .mmio_gnt_o, .mmio_rvalid_o, .mmio_addr_i, .mmio_we_i,
        .mmio_be_i, .mmio_wdata_i, .mmio_rdata_o, .mmio_err_o ( ),

        .l1d_addr_o   ( l1d_addr   ),
        .l1d_req_o    ( l1d_req    ),
        .l1d_rdata_i  ( l1d_rdata  ),
        .l1d_rvalid_i ( l1d_rvalid ),

        .vec_cmd_valid_o ( vec_cmd_valid ),
        .vec_cmd_o       ( vec_cmd ),
        .vec_cmd_ready_i ( vec_cmd_ready ),
        .tens_cmd_valid_o( tens_cmd_valid_unused ),
        .tens_cmd_o      ( tens_cmd_unused ),
        .tens_cmd_ready_i( 1'b1 ),
        .dma_cmd_valid_o ( dma_cmd_valid_unused ),
        .dma_cmd_o       ( dma_cmd_unused ),
        .dma_cmd_ready_i ( 1'b1 ),

        .vec_done_i     ( vu_done ),
        .vec_done_ctx_i ( vu_done_ctx ),
        .vec_done_tag_i ( vu_done_tag ),
        .tens_done_i    ( 1'b0 ), .tens_done_ctx_i ( 2'd0 ), .tens_done_tag_i ( '0 ),
        .dma_done_i     ( 1'b0 ), .dma_done_ctx_i  ( 2'd0 ), .dma_done_tag_i  ( '0 ),

        .irq_o          ( cp_irq_o ),
        .cp_soft_reset_o( cp_soft_reset ),

        .perf_l2_conflict_i  ( '0 ), .perf_l2_vec_stall_i ( '0 ),
        .perf_l2_tens_stall_i( '0 ), .perf_l2_dma_stall_i ( '0 ),
        .perf_cnt_en_o     ( ), .tens_yield_mode_o ( ), .tens_quota_n_o ( ),
        .vec_clk_en_o      ( ), .tens_clk_en_o ( ), .dma_clk_en_o ( )
    );

    // =========================================================================
    // Real vector_unit_top
    // =========================================================================
    vector_unit_top u_vec (
        .clk_i, .rst_ni, .soft_reset_i ( cp_soft_reset ),
        .cmd_valid_i ( vec_cmd_valid ), .cmd_ready_o ( vec_cmd_ready ), .cmd_i ( vec_cmd ),
        .ro_req_o ( ), .ro_gnt_i ( 1'b0 ), .ro_rvalid_i ( 1'b0 ),
        .ro_half_sel_o ( ), .ro_row_o ( ), .ro_rdata_i ( '0 ),
        .rw_req_o ( rw_req_o ), .rw_gnt_i ( rw_gnt_i ), .rw_half_sel_o ( rw_half_sel_o ),
        .rw_row_o ( rw_row_o ), .rw_bank_mask_o ( vu_rw_mask ), .rw_wdata_o ( rw_wdata_o ),
        .t2v_valid_i ( cap_valid_i ), .t2v_ready_o ( cap_ready_o ), .t2v_cap_i ( cap ),
        .t2v_miss_valid_o ( miss_valid_o ), .t2v_miss_reason_o ( miss_reason ),
        .v2t_valid_o ( ), .v2t_ready_i ( 1'b0 ), .v2t_cap_o ( ),
        .v2t_miss_valid_i ( 1'b0 ), .v2t_miss_reason_i ( MISS_NONE ),
        .done_o ( vu_done ), .done_ctx_o ( vu_done_ctx ), .done_tag_o ( vu_done_tag ),
        .unit_idle_o ( ), .contract_violation_o ( vu_err_o ), .err_code_o ( )
    );

endmodule

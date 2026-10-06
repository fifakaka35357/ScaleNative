// ============================================================================
// tb_l2_vec_store_readback.sv — STEP4-E2E §11 (D-E2E-BENCH P2 integration).
//
// Wires the REAL vector_unit_top.rw -> REAL l2_subsystem.vec_rw and proves an
// actual Vector STORE (half_sel=1) physically lands in L2 banks 8-15. The tb
// drives vec_cmd(STORE) directly (P1 already proved the cp_scheduler->wrapper
// half_sel latch), injects the SRC0 operand capsules on t2v, captures the unit's
// own rw_wdata at the write, then reads back each physical bank via dma_evict and
// compares to the CAPTURED wdata (no recomputed datapath numerics).
// ============================================================================
module tb_l2_vec_store_readback
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,

    // vec_cmd(STORE) drive
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic         half_sel_i,
    input  logic [8:0]   dst_row_i,

    // t2v capsule injection
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

    // observability
    output logic         rw_req_o,
    output logic         rw_half_sel_o,
    output logic [8:0]   rw_row_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,
    output logic         done_o,
    output logic         err_o,
    output logic         idle_o,

    // dma_evict single-bank readback
    input  logic         dma_evict_req_i,
    input  logic [L2_BANK_SEL_W-1:0] dma_evict_bank_i,
    input  logic [L2_BANK_AW-1:0]    dma_evict_row_i,
    output logic         dma_evict_gnt_o,
    output logic         dma_evict_rvalid_o,
    output logic [31:0]  dma_evict_rdata_o
);
    // ── vec_cmd(STORE) ──
    vec_cmd_t vcmd;
    always_comb begin
        vcmd                       = '0;
        vcmd.opcode                = OP_VEC_STORE;
        vcmd.dst_row               = dst_row_i;
        vcmd.contract.half_sel     = half_sel_i;
    end

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

    // ── Vector RW -> L2 vec_rw wires ──
    logic                        vrw_req, vrw_gnt, vrw_half;
    logic [L2_BANK_AW-1:0]       vrw_row;
    logic [(L2_NUM_BANKS/2)-1:0] vrw_mask;
    logic [HALF_STRIPE_W-1:0]    vrw_wdata;
    assign rw_req_o      = vrw_req;
    assign rw_half_sel_o = vrw_half;
    assign rw_row_o      = vrw_row;
    assign rw_wdata_o    = vrw_wdata;

    vector_unit_top u_vec (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ),
        .cmd_valid_i ( cmd_valid_i ), .cmd_ready_o ( cmd_ready_o ), .cmd_i ( vcmd ),
        // L2 RO unused
        .ro_req_o ( ), .ro_gnt_i ( 1'b0 ), .ro_rvalid_i ( 1'b0 ),
        .ro_half_sel_o ( ), .ro_row_o ( ), .ro_rdata_i ( '0 ),
        // L2 RW -> real l2_subsystem
        .rw_req_o       ( vrw_req   ),
        .rw_gnt_i       ( vrw_gnt   ),
        .rw_half_sel_o  ( vrw_half  ),
        .rw_row_o       ( vrw_row   ),
        .rw_bank_mask_o ( vrw_mask  ),
        .rw_wdata_o     ( vrw_wdata ),
        // fast path ingress
        .t2v_valid_i ( cap_valid_i ), .t2v_ready_o ( cap_ready_o ), .t2v_cap_i ( cap ),
        .t2v_miss_valid_o ( miss_valid_o ), .t2v_miss_reason_o ( miss_reason ),
        // egress unused
        .v2t_valid_o ( ), .v2t_ready_i ( 1'b0 ), .v2t_cap_o ( ),
        .v2t_miss_valid_i ( 1'b0 ), .v2t_miss_reason_i ( MISS_NONE ),
        .done_o ( done_o ), .done_ctx_o ( ), .done_tag_o ( ),
        .unit_idle_o ( idle_o ), .contract_violation_o ( err_o ), .err_code_o ( )
    );

    l2_subsystem #(.NUM_BANKS(L2_NUM_BANKS), .BANK_AW(L2_BANK_AW)) i_l2 (
        .clk_i, .rst_ni,
        .tens_ro_req_i ( 1'b0 ), .tens_ro_row_i ( '0 ), .tens_ro_gnt_o ( ),
        .tens_ro_rvalid_o ( ), .tens_ro_rdata_o ( ),
        .tens_rw_req_i ( 1'b0 ), .tens_rw_row_i ( '0 ), .tens_rw_bank_mask_i ( '0 ),
        .tens_rw_wdata_i ( '0 ), .tens_rw_gnt_o ( ),
        .vec_ro_req_i ( 1'b0 ), .vec_ro_row_i ( '0 ), .vec_ro_half_sel_i ( 1'b0 ),
        .vec_ro_gnt_o ( ), .vec_ro_rvalid_o ( ), .vec_ro_rdata_o ( ),
        // Vector RW from the real unit
        .vec_rw_req_i ( vrw_req ), .vec_rw_row_i ( vrw_row ), .vec_rw_half_sel_i ( vrw_half ),
        .vec_rw_bank_mask_i ( vrw_mask ), .vec_rw_wdata_i ( vrw_wdata ), .vec_rw_gnt_o ( vrw_gnt ),
        .dma_fill_req_i ( 1'b0 ), .dma_fill_bank_i ( '0 ), .dma_fill_row_i ( '0 ),
        .dma_fill_wdata_i ( '0 ), .dma_fill_be_i ( '0 ), .dma_fill_gnt_o ( ),
        .dma_evict_req_i ( dma_evict_req_i ), .dma_evict_bank_i ( dma_evict_bank_i ),
        .dma_evict_row_i ( dma_evict_row_i ), .dma_evict_gnt_o ( dma_evict_gnt_o ),
        .dma_evict_rvalid_o ( dma_evict_rvalid_o ), .dma_evict_rdata_o ( dma_evict_rdata_o ),
        .soft_reset_i ( 1'b0 ), .tens_yield_mode_i ( 2'd0 ), .tens_quota_n_i ( 4'd0 ),
        .perf_cnt_en_i ( 1'b0 ), .perf_l2_conflict_o ( ), .perf_l2_vec_stall_o ( ),
        .perf_l2_tens_stall_o ( ), .perf_l2_dma_stall_o ( )
    );

endmodule

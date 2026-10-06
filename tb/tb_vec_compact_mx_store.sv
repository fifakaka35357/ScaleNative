// ============================================================================
// tb_vec_compact_mx_store.sv — ⑦ compact-MX L2-store (CompactMX_Store_Impl_Spec).
//
// Wires the REAL vector_unit_top (RO + RW) to the REAL l2_subsystem and proves
// a block-scaled OP_VEC_STORE physically lands as the COMPACT encoding:
//   - MXFP4: 64b requantized payload / window, bank mask 8'h03
//   - MXFP8: 128b payload / window, bank mask 8'h0F
//   - per-window block scale via scale-sidecar READ-MODIFY-WRITE
//     (E8M0 8b dense lanes for block32 / NVFP4 16b signed ref_exp for block16)
// while a default-contract STORE keeps the legacy full-mask 256b write with no
// sidecar traffic. The tb presets L2 rows via dma_fill (RMW-preservation
// evidence), drives vec_cmd(STORE + contract) directly, injects SRC0 capsules
// on t2v, and reads every physical bank back via dma_evict.
// ============================================================================
module tb_vec_compact_mx_store
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,

    // ── vec_cmd(STORE + architectural contract) drive ──
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic         half_sel_i,
    input  logic [3:0]   elem_fmt_i,        // contract.elem_fmt ('0 = legacy default)
    input  logic [1:0]   block_log2_i,      // contract.block_size_log2 (BS_16=0/BS_32=1)
    input  logic [8:0]   dst_row_i,
    input  logic [8:0]   sidecar_base_i,    // physical scale-sidecar row (cmd.sidecar_base)

    // ── t2v SRC0 capsule injection ──
    input  logic         cap_valid_i,
    output logic         cap_ready_o,
    input  logic [BS_CAP_PAYLOAD_W-1:0] cap_payload_i,
    input  logic [15:0]  cap_scale_ref_i,   // capsule absolute block exponent
    input  logic         cap_abs_i,         // inline_scale[8] (ABS_EXP_PRESENT)
    input  logic [7:0]   cap_inline_scale_i,
    output logic         miss_valid_o,
    output logic [3:0]   miss_reason_o,

    // ── observability ──
    output logic         rw_req_o,
    output logic         rw_gnt_o,
    output logic         rw_half_sel_o,
    output logic [8:0]   rw_row_o,
    output logic [7:0]   rw_bank_mask_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,
    output logic         done_o,
    output logic         err_o,
    output logic         idle_o,

    // ── dma_fill preset (pattern rows) ──
    input  logic         dma_fill_req_i,
    input  logic [L2_BANK_SEL_W-1:0] dma_fill_bank_i,
    input  logic [L2_BANK_AW-1:0]    dma_fill_row_i,
    input  logic [31:0]  dma_fill_wdata_i,
    output logic         dma_fill_gnt_o,

    // ── dma_evict single-bank readback ──
    input  logic         dma_evict_req_i,
    input  logic [L2_BANK_SEL_W-1:0] dma_evict_bank_i,
    input  logic [L2_BANK_AW-1:0]    dma_evict_row_i,
    output logic         dma_evict_gnt_o,
    output logic         dma_evict_rvalid_o,
    output logic [31:0]  dma_evict_rdata_o
);

    // ── vec_cmd(STORE) with a drivable contract ──
    vec_cmd_t vcmd;
    always_comb begin
        vcmd                          = '0;
        vcmd.opcode                   = OP_VEC_STORE;
        vcmd.dst_row                  = dst_row_i;
        vcmd.contract.half_sel        = half_sel_i;
        vcmd.contract.elem_fmt        = elem_fmt_e'(elem_fmt_i);
        vcmd.contract.block_size_log2 = block_size_log2_e'(block_log2_i);
        vcmd.sidecar_base             = sidecar_base_i;
    end

    // ── injected SRC0 capsule; block_size/scale_format track the command's
    //    block size (ingress arb exact-match): block16 -> E4M3 (NVFP4),
    //    block32 -> E8M0 (OCP-MX) — the vec_cmd_to_desc D12 derivation. ──
    bs_capsule_t cap;
    fp_miss_reason_e miss_reason;
    always_comb begin
        cap                    = '0;
        cap.payload            = cap_payload_i;
        cap.elem_fmt           = ELEM_BFP_INTERNAL;
        cap.block_size         = (block_log2_i == 2'd1) ? BLOCK_SIZE_32 : BLOCK_SIZE_16;
        cap.scale_format       = (block_log2_i == 2'd1) ? SCALE_E8M0    : SCALE_E4M3;
        cap.layout_tag         = 4'd0;
        cap.scale_ref          = cap_scale_ref_i;
        cap.inline_scale       = {23'd0, cap_abs_i, cap_inline_scale_i};
        cap.scale_inline_valid = 1'b1;
        cap.scale_epoch        = 8'd0;
        cap.fwd_eligible       = 1'b1;
        cap.operand_role       = OP_SRC0;
    end
    assign miss_reason_o = miss_reason;

    // ── Vector RO/RW <-> L2 wires ──
    logic                        ro_req, ro_gnt, ro_rvalid, ro_half;
    logic [L2_BANK_AW-1:0]       ro_row;
    logic [HALF_STRIPE_W-1:0]    ro_rdata;
    logic                        rw_req, rw_gnt, rw_half;
    logic [L2_BANK_AW-1:0]       rw_row;
    logic [(L2_NUM_BANKS/2)-1:0] rw_mask;
    logic [HALF_STRIPE_W-1:0]    rw_wdata;
    assign rw_req_o       = rw_req;
    assign rw_gnt_o       = rw_gnt;
    assign rw_half_sel_o  = rw_half;
    assign rw_row_o       = rw_row;
    assign rw_bank_mask_o = rw_mask;
    assign rw_wdata_o     = rw_wdata;

    vector_unit_top u_vec (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ),
        .cmd_valid_i ( cmd_valid_i ), .cmd_ready_o ( cmd_ready_o ), .cmd_i ( vcmd ),
        // L2 RO — scale-sidecar RMW read
        .ro_req_o ( ro_req ), .ro_gnt_i ( ro_gnt ), .ro_rvalid_i ( ro_rvalid ),
        .ro_half_sel_o ( ro_half ), .ro_row_o ( ro_row ), .ro_rdata_i ( ro_rdata ),
        // L2 RW — compact payload + sidecar write-back
        .rw_req_o ( rw_req ), .rw_gnt_i ( rw_gnt ), .rw_half_sel_o ( rw_half ),
        .rw_row_o ( rw_row ), .rw_bank_mask_o ( rw_mask ), .rw_wdata_o ( rw_wdata ),
        // fast-path SRC0
        .t2v_valid_i ( cap_valid_i ), .t2v_ready_o ( cap_ready_o ), .t2v_cap_i ( cap ),
        .t2v_miss_valid_o ( miss_valid_o ), .t2v_miss_reason_o ( miss_reason ),
        // egress unused (STORE fwd_eligible=0 -> keep-local L2 path)
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
        // Vector RO — sidecar RMW read phase
        .vec_ro_req_i ( ro_req ), .vec_ro_row_i ( ro_row ), .vec_ro_half_sel_i ( ro_half ),
        .vec_ro_gnt_o ( ro_gnt ), .vec_ro_rvalid_o ( ro_rvalid ), .vec_ro_rdata_o ( ro_rdata ),
        // Vector RW — payload + sidecar writes
        .vec_rw_req_i ( rw_req ), .vec_rw_row_i ( rw_row ), .vec_rw_half_sel_i ( rw_half ),
        .vec_rw_bank_mask_i ( rw_mask ), .vec_rw_wdata_i ( rw_wdata ), .vec_rw_gnt_o ( rw_gnt ),
        // DMA fill — pattern preset
        .dma_fill_req_i ( dma_fill_req_i ), .dma_fill_bank_i ( dma_fill_bank_i ),
        .dma_fill_row_i ( dma_fill_row_i ), .dma_fill_wdata_i ( dma_fill_wdata_i ),
        .dma_fill_be_i ( 4'hF ), .dma_fill_gnt_o ( dma_fill_gnt_o ),
        // DMA evict — readback
        .dma_evict_req_i ( dma_evict_req_i ), .dma_evict_bank_i ( dma_evict_bank_i ),
        .dma_evict_row_i ( dma_evict_row_i ), .dma_evict_gnt_o ( dma_evict_gnt_o ),
        .dma_evict_rvalid_o ( dma_evict_rvalid_o ), .dma_evict_rdata_o ( dma_evict_rdata_o ),
        .soft_reset_i ( 1'b0 ), .tens_yield_mode_i ( 2'd0 ), .tens_quota_n_i ( 4'd0 ),
        .perf_cnt_en_i ( 1'b0 ), .perf_l2_conflict_o ( ), .perf_l2_vec_stall_o ( ),
        .perf_l2_tens_stall_o ( ), .perf_l2_dma_stall_o ( )
    );

endmodule

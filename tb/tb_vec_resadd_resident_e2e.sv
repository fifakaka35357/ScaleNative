// ============================================================================
// tb_vec_resadd_resident_e2e.sv — STEP4-E2E §11.4 (D-E2E-BENCH SRC1 producer).
//
// Proves the HARDWARE SRC1 (residual) producer: a RESADD with desc.src1_resident
// reads the residual from L2 via the Vector's own RO master (the activated
// vec_ingress_arb Source A), tags it OP_SRC1, and adds it to the fast-path SRC0
// — no tb-injected SRC1. DUT = vector_unit_top + REAL l2_subsystem; the residual
// is preloaded in L2 (dma_fill) in the half_sel-selected half; SRC0 is injected
// on t2v; the RESADD result is written back to L2 and checked bit-exact.
// ============================================================================
module tb_vec_resadd_resident_e2e
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,

    // vec_cmd(RESADD, resident SRC1)
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic         half_sel_i,
    input  logic [1:0]   block_log2_i,    // contract.block_size_log2 (BS_16=0 / BS_32=1)
    input  logic [8:0]   dst_row_i,
    input  logic [8:0]   src1_row_i,      // residual L2 row (resident SRC1)
    input  logic         resident_i,      // contract.src1_resident
    input  logic [15:0]  src1_scale_ref_i, // [HW-REVIEW T3] resident SRC1 absolute block exp
    input  logic [15:0]  len_rows_i,       // [T3-FF/FF3b-c] N blocks (block_count); 0/1 = single-block
    input  logic [8:0]   sidecar_base_i,   // [T3-FF/FF3b-c] physical scale-sidecar base row
    input  logic         rw_stall_i,       // [T3-FF/FF3b-c] mask the RW grant seen by the Vector
                                           //   (force an L2_WB write-stall to exercise FOLD-5)

    // SRC0 capsule injection (fast path)
    input  logic         cap_valid_i,
    output logic         cap_ready_o,
    input  logic [BS_CAP_PAYLOAD_W-1:0] cap_payload_i,
    input  logic [7:0]   cap_inline_scale_i,
    output logic         miss_valid_o,
    output logic [3:0]   miss_reason_o,

    // residual preload via dma_fill (one bank/cycle)
    input  logic         dma_fill_req_i,
    input  logic [L2_BANK_SEL_W-1:0] dma_fill_bank_i,
    input  logic [L2_BANK_AW-1:0]    dma_fill_row_i,
    input  logic [31:0]  dma_fill_wdata_i,
    output logic         dma_fill_gnt_o,

    // observability
    output logic         rw_req_o,
    output logic         rw_half_sel_o,
    output logic [L2_BANK_AW-1:0]    rw_row_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,
    output logic         done_o,
    output logic         err_o,
    output logic [3:0]   err_code_o,       // [T3-FF/FF3b-c] vec_error_e (for FOLD-5 code assert)
    output logic         idle_o,
    output logic [3:0]   vu_state_o,       // [T3-FF/FF3b-c] widened for VST_BLK_SETUP=8
    // [HW-REVIEW T3] result capsule scale taps (writeback-symmetry W1 teeth)
    output logic [15:0]  result_scale_ref_o,
    output logic [31:0]  result_inline_scale_o
);
    assign vu_state_o = u_vec.u_vector_unit.state_q;
    assign result_scale_ref_o    = u_vec.u_vector_unit.result_cap_q.scale_ref;
    assign result_inline_scale_o = u_vec.u_vector_unit.result_cap_q.inline_scale;

    // ── vec_cmd(RESADD, resident SRC1) ──
    vec_cmd_t vcmd;
    always_comb begin
        vcmd                          = '0;
        vcmd.opcode                   = OP_VEC_RESADD;
        vcmd.src_row                  = src1_row_i;          // residual row (-> desc.src1_ref)
        vcmd.dst_row                  = dst_row_i;
        vcmd.contract.half_sel        = half_sel_i;
        vcmd.contract.src1_resident   = resident_i;
        vcmd.contract.block_size_log2 = block_size_log2_e'(block_log2_i);  // BS_16->E4M3
        vcmd.contract.fwd_eligible    = 1'b1;
        vcmd.contract.src1_scale_ref  = src1_scale_ref_i;  // [HW-REVIEW T3] per-residual abs exp
        vcmd.len_rows                 = len_rows_i;         // [T3-FF/FF3b-c] N blocks (-> block_count)
        vcmd.sidecar_base             = sidecar_base_i;     // [T3-FF/FF3b-c] physical sidecar row
    end

    // ── SRC0 capsule (block16/E4M3, or block32/E8M0 for FF2) ──
    bs_capsule_t cap;
    fp_miss_reason_e miss_reason;
    always_comb begin
        cap                    = '0;
        cap.payload            = cap_payload_i;
        cap.elem_fmt           = ELEM_BFP_INTERNAL;
        // [T3-FF/FF2] SRC0 block_size/scale_format track the command's block size so a
        // block32 (E8M0) RESADD gets matching block32/E8M0 SRC0 capsules (the ingress
        // arb exact-match on {block_size,scale_format}). block16 -> E4M3 (NVFP4), as before.
        cap.block_size         = (block_log2_i == 2'd1) ? BLOCK_SIZE_32 : BLOCK_SIZE_16;
        cap.scale_format       = (block_log2_i == 2'd1) ? SCALE_E8M0    : SCALE_E4M3;
        cap.layout_tag         = 4'd0;
        cap.inline_scale       = {24'd0, cap_inline_scale_i};   // bit8=0 -> SRC0 uses legacy byte
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
    assign rw_req_o = rw_req; assign rw_half_sel_o = rw_half;
    assign rw_row_o = rw_row; assign rw_wdata_o = rw_wdata;

    // [T3-FF/FF3b-c] FOLD-5 stimulus: when rw_stall_i, the Vector sees rw_gnt=0 (the L2 still
    // grants on the real port, but the Vector's view is masked) so an L2_WB hangs -> FOLD-5.
    logic rw_gnt_vu;
    assign rw_gnt_vu = rw_gnt & ~rw_stall_i;

    vector_unit_top u_vec (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ),
        .cmd_valid_i ( cmd_valid_i ), .cmd_ready_o ( cmd_ready_o ), .cmd_i ( vcmd ),
        // L2 RO — resident SRC1 read
        .ro_req_o ( ro_req ), .ro_gnt_i ( ro_gnt ), .ro_rvalid_i ( ro_rvalid ),
        .ro_half_sel_o ( ro_half ), .ro_row_o ( ro_row ), .ro_rdata_i ( ro_rdata ),
        // L2 RW — result write-back
        .rw_req_o ( rw_req ), .rw_gnt_i ( rw_gnt_vu ), .rw_half_sel_o ( rw_half ),
        .rw_row_o ( rw_row ), .rw_bank_mask_o ( rw_mask ), .rw_wdata_o ( rw_wdata ),
        // fast-path SRC0
        .t2v_valid_i ( cap_valid_i ), .t2v_ready_o ( cap_ready_o ), .t2v_cap_i ( cap ),
        .t2v_miss_valid_o ( miss_valid_o ), .t2v_miss_reason_o ( miss_reason ),
        .v2t_valid_o ( ), .v2t_ready_i ( 1'b0 ), .v2t_cap_o ( ),
        .v2t_miss_valid_i ( 1'b0 ), .v2t_miss_reason_i ( MISS_NONE ),
        .done_o ( done_o ), .done_ctx_o ( ), .done_tag_o ( ),
        .unit_idle_o ( idle_o ), .contract_violation_o ( err_o ), .err_code_o ( err_code_o )
    );

    l2_subsystem #(.NUM_BANKS(L2_NUM_BANKS), .BANK_AW(L2_BANK_AW)) i_l2 (
        .clk_i, .rst_ni,
        .tens_ro_req_i ( 1'b0 ), .tens_ro_row_i ( '0 ), .tens_ro_gnt_o ( ),
        .tens_ro_rvalid_o ( ), .tens_ro_rdata_o ( ),
        .tens_rw_req_i ( 1'b0 ), .tens_rw_row_i ( '0 ), .tens_rw_bank_mask_i ( '0 ),
        .tens_rw_wdata_i ( '0 ), .tens_rw_gnt_o ( ),
        // Vector RO from the resident reader
        .vec_ro_req_i ( ro_req ), .vec_ro_row_i ( ro_row ), .vec_ro_half_sel_i ( ro_half ),
        .vec_ro_gnt_o ( ro_gnt ), .vec_ro_rvalid_o ( ro_rvalid ), .vec_ro_rdata_o ( ro_rdata ),
        // Vector RW result
        .vec_rw_req_i ( rw_req ), .vec_rw_row_i ( rw_row ), .vec_rw_half_sel_i ( rw_half ),
        .vec_rw_bank_mask_i ( rw_mask ), .vec_rw_wdata_i ( rw_wdata ), .vec_rw_gnt_o ( rw_gnt ),
        // DMA fill — residual preload
        .dma_fill_req_i ( dma_fill_req_i ), .dma_fill_bank_i ( dma_fill_bank_i ),
        .dma_fill_row_i ( dma_fill_row_i ), .dma_fill_wdata_i ( dma_fill_wdata_i ),
        .dma_fill_be_i ( 4'hF ), .dma_fill_gnt_o ( dma_fill_gnt_o ),
        .dma_evict_req_i ( 1'b0 ), .dma_evict_bank_i ( '0 ), .dma_evict_row_i ( '0 ),
        .dma_evict_gnt_o ( ), .dma_evict_rvalid_o ( ), .dma_evict_rdata_o ( ),
        .soft_reset_i ( 1'b0 ), .tens_yield_mode_i ( 2'd0 ), .tens_quota_n_i ( 4'd0 ),
        .perf_cnt_en_i ( 1'b0 ), .perf_l2_conflict_o ( ), .perf_l2_vec_stall_o ( ),
        .perf_l2_tens_stall_o ( ), .perf_l2_dma_stall_o ( )
    );

endmodule

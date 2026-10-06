// ============================================================================
// tb_soc_e2e.sv — STEP4-E2E Phase D: hybrid full chain.
//
//   tens_cmd(GEMM) -> tensor_domain_top -> [packer] -> tv_fast_fifo --\
//                                                                      mux --> vector_unit_top.t2v
//                                            tb-injected SRC1 capsule --/        (RESADD) -> L2 RW
//
// The real Tensor GEMM egresses SRC0-tagged block16 capsules into the FIFO. The
// tb forwards the FIRST one (GEMM result row 0) through the FIFO into the Vector
// (the real GEMM->packer->FIFO->RESADD path for SRC0), snoops its fields for the
// oracle, then flips the mux to inject the SRC1 (residual) capsule directly (the
// real Tensor egress hardwires operand_role=OP_SRC0, so it cannot supply SRC1 —
// §9.7). The Vector RESADD writes the sum to the L2 RW port, checked bit-exact vs
// resadd_fastpath_golden(captured_src0, src0_exp, injected_src1, src1_exp).
//
// Tensor operands come from an L2 RO model; the Vector write-back is captured on
// the L2 RW port. Everything uses clk_i/rst_ni (IBEX-side convention).
// ============================================================================
module tb_soc_e2e
    import pe_pkg::*;
    import tensor_pkg::*;
    import vec_pkg::*;
(
    input  logic                     clk_i,
    input  logic                     rst_ni,

    // ── Tensor command (GEMM) ──
    input  logic                     tcmd_valid_i,
    output logic                     tcmd_ready_o,
    input  logic [L2_BANK_AW-1:0]    t_src_row_i,
    input  logic [L2_BANK_AW-1:0]    t_dst_row_i,
    input  logic [15:0]              t_param_K_i,
    input  logic [7:0]               t_scale_epoch_i,

    // ── Tensor L2 RO model (512b) ──
    output logic                     ro_req_o,
    input  logic                     ro_gnt_i,
    input  logic                     ro_rvalid_i,
    output logic [L2_BANK_AW-1:0]    ro_row_o,
    input  logic [FULL_STRIPE_W-1:0] ro_rdata_i,

    // ── Vector command (RESADD) ──
    input  logic                     vcmd_valid_i,
    output logic                     vcmd_ready_o,
    input  logic [1:0]               v_block_size_log2_i,
    input  logic [7:0]               v_scale_epoch_i,
    input  logic [8:0]               v_dst_row_i,

    // ── SRC1 injection (residual capsule) ──
    input  logic                     sel_inject_i,       // 0 = forward FIFO (SRC0), 1 = inject SRC1
    input  logic                     src1_valid_i,
    input  logic [BS_CAP_PAYLOAD_W-1:0] src1_payload_i,
    input  logic [7:0]               src1_iscale_i,      // E4M3 scale byte
    input  logic [7:0]               src1_epoch_i,
    input  logic [15:0]              src1_scale_ref_i,   // [T3] SRC1 absolute block exp
    input  logic                     src1_abs_i,         // [T3] SRC1 inline_scale[8] (ABS_EXP_PRESENT)

    // ── Vector L2 RW capture ──
    input  logic                     rw_gnt_i,
    output logic                     rw_req_o,
    output logic                     rw_half_sel_o,
    output logic [L2_BANK_AW-1:0]    rw_row_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,

    // ── SRC0 snoop (mux output = what the Vector ingests) ──
    output logic                     vec_t2v_valid_o,
    output logic                     vec_t2v_ready_o,
    output logic [BS_CAP_PAYLOAD_W-1:0] snoop_payload_o,
    output logic [2:0]               snoop_sfmt_o,
    output logic [1:0]               snoop_bsize_o,
    output logic [31:0]              snoop_iscale_o,
    output logic [15:0]              snoop_scale_ref_o,  // [T3] SRC0 absolute block exp
    output logic [1:0]               snoop_role_o,
    output logic [7:0]               snoop_epoch_o,

    // ── Status ──
    output logic                     t_done_o,
    output logic                     v_done_o,
    output logic                     v_miss_o,
    output logic [3:0]               v_miss_reason_o,
    output logic                     v_err_o,
    output logic [3:0]               v_err_code_o
);
    // =========================================================================
    // Tensor command
    // =========================================================================
    tens_cmd_t tcmd;
    always_comb begin
        tcmd                      = '0;
        tcmd.opcode               = OP_TENS_GEMM;
        tcmd.src_row              = t_src_row_i;
        tcmd.dst_row              = t_dst_row_i;
        tcmd.param_K              = t_param_K_i;
        tcmd.contract.scale_epoch = t_scale_epoch_i;
    end

    bs_capsule_t  tens_cap;
    logic         tens_t2v_valid, tens_t2v_ready, tens_t2v_escape;

    tensor_domain_top u_tens (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ), .test_en_i ( 1'b0 ),
        .cmd_valid_i ( tcmd_valid_i ),
        .cmd_ready_o ( tcmd_ready_o ),
        .cmd_i       ( tcmd         ),
        .ro_req_o, .ro_gnt_i, .ro_rvalid_i, .ro_row_o, .ro_rdata_i,
        .rw_req_o ( ), .rw_gnt_i ( 1'b0 ), .rw_row_o ( ), .rw_bank_mask_o ( ), .rw_wdata_o ( ),
        .t2v_valid_o ( tens_t2v_valid  ),
        .t2v_ready_i ( tens_t2v_ready  ),
        .t2v_cap_o   ( tens_cap        ),
        .t2v_escape_o( tens_t2v_escape ),
        .done_o      ( t_done_o ),
        .done_ctx_o  ( ), .done_tag_o ( ),
        .unit_idle_o ( ), .contract_violation_o ( )
    );

    // =========================================================================
    // tv_fast_fifo carrying the whole bs_capsule_t (Q1)
    // =========================================================================
    localparam int CAP_W = $bits(bs_capsule_t);
    bs_capsule_t  fifo_cap;
    logic         fifo_out_valid, fifo_out_ready;
    logic [CAP_W-1:0] fifo_out_bits;
    assign fifo_cap = bs_capsule_t'(fifo_out_bits);

    tv_fast_fifo #(.DATA_W(CAP_W)) u_fifo (
        .clk_i, .rst_ni,
        .flush_i       ( 1'b0           ),   // no soft-reset in this hybrid-chain bench
        .in_valid_i    ( tens_t2v_valid ),
        .in_ready_o    ( tens_t2v_ready ),
        .in_data_i     ( tens_cap       ),
        .in_sideband_i ( '0             ),
        .out_valid_o   ( fifo_out_valid ),
        .out_ready_i   ( fifo_out_ready ),
        .out_data_o    ( fifo_out_bits  ),
        .out_sideband_o( ),
        .fill_level_o  ( ), .overflow_o ( ), .underflow_o ( )
    );

    // =========================================================================
    // SRC1 injected capsule (built from flat fields, role=OP_SRC1, block16 E4M3)
    // =========================================================================
    bs_capsule_t src1_cap;
    always_comb begin
        src1_cap                    = '0;
        src1_cap.payload            = src1_payload_i;
        src1_cap.elem_fmt           = ELEM_BFP_INTERNAL;
        src1_cap.block_size         = BLOCK_SIZE_16;
        src1_cap.scale_format       = SCALE_E4M3;
        src1_cap.layout_tag         = 4'd0;
        // [T3] SRC1 carries an absolute block exp (scale_ref) gated by src1_abs_i (bit8).
        src1_cap.scale_ref          = src1_scale_ref_i;
        src1_cap.inline_scale       = {23'd0, src1_abs_i, src1_iscale_i};
        src1_cap.scale_inline_valid = 1'b1;
        src1_cap.scale_epoch        = src1_epoch_i;
        src1_cap.fwd_eligible       = 1'b1;
        src1_cap.multi_consumer     = 1'b0;
        src1_cap.operand_role       = OP_SRC1;
        src1_cap.dest_hint          = DEST_VECTOR;
        src1_cap.producer           = DOMAIN_TENSOR;
    end

    // =========================================================================
    // Capsule MUX into the Vector t2v ingress: SRC0 (FIFO) then SRC1 (inject)
    // =========================================================================
    bs_capsule_t vec_in_cap;
    logic        vec_in_valid, vec_t2v_ready;
    assign vec_in_cap   = sel_inject_i ? src1_cap : fifo_cap;
    assign vec_in_valid = sel_inject_i ? src1_valid_i : fifo_out_valid;
    // pop the FIFO only while forwarding (sel=0); inject path does not pop it
    assign fifo_out_ready = (!sel_inject_i) && vec_t2v_ready;

    assign vec_t2v_valid_o = vec_in_valid;
    assign vec_t2v_ready_o = vec_t2v_ready;
    assign snoop_payload_o = vec_in_cap.payload;
    assign snoop_sfmt_o    = vec_in_cap.scale_format;
    assign snoop_bsize_o   = vec_in_cap.block_size;
    assign snoop_iscale_o  = vec_in_cap.inline_scale;
    assign snoop_scale_ref_o = vec_in_cap.scale_ref;     // [T3] SRC0 absolute block exp
    assign snoop_role_o    = vec_in_cap.operand_role;
    assign snoop_epoch_o   = vec_in_cap.scale_epoch;

    // =========================================================================
    // Vector command (RESADD)
    // =========================================================================
    vec_cmd_t vcmd;
    always_comb begin
        vcmd                          = '0;
        vcmd.opcode                   = OP_VEC_RESADD;
        vcmd.dst_row                  = v_dst_row_i;
        vcmd.contract.block_size_log2 = block_size_log2_e'(v_block_size_log2_i);
        vcmd.contract.scale_epoch     = v_scale_epoch_i;
        vcmd.contract.fwd_eligible    = 1'b1;
    end

    fp_miss_reason_e v_miss_reason;
    vec_error_e      v_err_code;
    assign v_miss_reason_o = v_miss_reason;
    assign v_err_code_o    = v_err_code;

    vector_unit_top u_vec (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ),
        .cmd_valid_i ( vcmd_valid_i ),
        .cmd_ready_o ( vcmd_ready_o ),
        .cmd_i       ( vcmd         ),

        // L2 RO — unused by RESADD
        .ro_req_o ( ), .ro_gnt_i ( 1'b0 ), .ro_rvalid_i ( 1'b0 ),
        .ro_half_sel_o ( ), .ro_row_o ( ), .ro_rdata_i ( '0 ),

        // L2 RW — write-back capture
        .rw_req_o       ( rw_req_o      ),
        .rw_gnt_i       ( rw_gnt_i      ),
        .rw_half_sel_o  ( rw_half_sel_o ),
        .rw_row_o       ( rw_row_o      ),
        .rw_bank_mask_o ( ),
        .rw_wdata_o     ( rw_wdata_o    ),

        // fast-path ingress (mux output)
        .t2v_valid_i       ( vec_in_valid  ),
        .t2v_ready_o       ( vec_t2v_ready ),
        .t2v_cap_i         ( vec_in_cap    ),
        .t2v_miss_valid_o  ( v_miss_o      ),
        .t2v_miss_reason_o ( v_miss_reason ),

        // fast-path egress — unused
        .v2t_valid_o ( ), .v2t_ready_i ( 1'b0 ), .v2t_cap_o ( ),
        .v2t_miss_valid_i ( 1'b0 ), .v2t_miss_reason_i ( MISS_NONE ),

        .done_o     ( v_done_o ),
        .done_ctx_o ( ), .done_tag_o ( ),
        .unit_idle_o ( ),
        .contract_violation_o ( v_err_o ),
        .err_code_o ( v_err_code )
    );
endmodule

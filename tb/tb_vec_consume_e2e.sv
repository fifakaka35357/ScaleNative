// ============================================================================
// tb_vec_consume_e2e.sv — STEP4-E2E (inc 5, stage 1) Vector-consumption harness.
//
// Drives the REAL vector_unit_top with a vec_cmd(OP_VEC_RESADD) and two
// fast-path operand capsules (SRC0, SRC1) injected on t2v, and exposes the L2
// RW write-back for checking vs resadd_fastpath_golden. The capsules are built
// from flat fields here (the FIFO is separately proven by tb_fastpath_link).
// ============================================================================
module tb_vec_consume_e2e
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,

    // command (vec_cmd RESADD)
    input  logic         cmd_valid_i,
    output logic         cmd_ready_o,
    input  logic [1:0]   block_size_log2_i,
    input  logic [7:0]   scale_epoch_i,
    input  logic [8:0]   dst_row_i,
    // [T3-FF/FF3b-c] streaming/resident fields (default 0 -> non-resident, as before)
    input  logic         src1_resident_i,
    input  logic [8:0]   src1_row_i,
    input  logic [15:0]  len_rows_i,
    input  logic [8:0]   sidecar_base_i,

    // capsule injection (t2v ingress)
    input  logic         cap_valid_i,
    output logic         cap_ready_o,
    input  logic [BS_CAP_PAYLOAD_W-1:0] cap_payload_i,
    input  logic [1:0]   cap_role_i,          // operand_role_e
    input  logic [1:0]   cap_block_size_i,    // block_size_sel_e
    input  logic [2:0]   cap_scale_format_i,  // scale_format_e
    input  logic [7:0]   cap_inline_scale_i,
    input  logic [7:0]   cap_scale_epoch_i,
    input  logic         cap_fwd_i,
    output logic         miss_valid_o,
    output logic [3:0]   miss_reason_o,

    // L2 RW model
    input  logic         rw_gnt_i,
    output logic         rw_req_o,
    output logic [L2_BANK_AW-1:0]    rw_row_o,
    output logic         rw_half_sel_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,

    output logic         done_o,
    output logic         err_o,
    output logic [3:0]   err_code_o,
    output logic         idle_o,
    output logic [3:0]   vu_state_o        // [T3-FF/FF3b-c] for streaming-state assertions
);
    // ── build the vec_cmd ──
    vec_cmd_t vcmd;
    always_comb begin
        vcmd                          = '0;
        vcmd.opcode                   = OP_VEC_RESADD;
        vcmd.dst_row                  = dst_row_i;
        vcmd.src_row                  = src1_row_i;          // [T3-FF] residual row (-> src1_ref)
        vcmd.contract.block_size_log2 = block_size_log2_e'(block_size_log2_i);
        vcmd.contract.scale_epoch     = scale_epoch_i;
        vcmd.contract.fwd_eligible    = 1'b1;
        vcmd.contract.src1_resident   = src1_resident_i;     // [T3-FF/FF3b-c]
        vcmd.len_rows                 = len_rows_i;           // [T3-FF/FF3b-c] -> block_count
        vcmd.sidecar_base             = sidecar_base_i;       // [T3-FF/FF3b-c]
    end

    // ── build the injected capsule ──
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
        cap.multi_consumer     = 1'b0;
        cap.operand_role       = operand_role_e'(cap_role_i);
    end
    assign miss_reason_o = miss_reason;

    vector_unit_top i_vec (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ),

        .cmd_valid_i ( cmd_valid_i ),
        .cmd_ready_o ( cmd_ready_o ),
        .cmd_i       ( vcmd        ),

        // L2 RO — unused by RESADD
        .ro_req_o      (        ), .ro_gnt_i ( 1'b0 ), .ro_rvalid_i ( 1'b0 ),
        .ro_half_sel_o (        ), .ro_row_o (      ), .ro_rdata_i  ( '0   ),

        // L2 RW — write-back capture
        .rw_req_o       ( rw_req_o      ),
        .rw_gnt_i       ( rw_gnt_i      ),
        .rw_half_sel_o  ( rw_half_sel_o ),
        .rw_row_o       ( rw_row_o      ),
        .rw_bank_mask_o (               ),
        .rw_wdata_o     ( rw_wdata_o    ),

        // fast-path ingress (capsule injection)
        .t2v_valid_i       ( cap_valid_i  ),
        .t2v_ready_o       ( cap_ready_o  ),
        .t2v_cap_i         ( cap          ),
        .t2v_miss_valid_o  ( miss_valid_o ),
        .t2v_miss_reason_o ( miss_reason  ),

        // fast-path egress — unused
        .v2t_valid_o       (           ),
        .v2t_ready_i       ( 1'b0      ),
        .v2t_cap_o         (           ),
        .v2t_miss_valid_i  ( 1'b0      ),
        .v2t_miss_reason_i ( MISS_NONE ),

        .done_o     ( done_o ),
        .done_ctx_o (        ),
        .done_tag_o (        ),

        .unit_idle_o          ( idle_o ),
        .contract_violation_o ( err_o  ),
        .err_code_o           ( err_code_o )
    );

    assign vu_state_o = i_vec.u_vector_unit.state_q;  // [T3-FF/FF3b-c]
endmodule

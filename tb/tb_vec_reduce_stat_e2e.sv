// ============================================================================
// tb_vec_reduce_stat_e2e.sv — REDUCE_STAT (VEC_RMSNORM_PARTIAL) end-to-end
// harness for prereg soc600_prereg_20260902.md §70 + §74.1 (待-2 / #285 ⑬⑭).
//
// Instantiates the REAL vector_unit directly (NOT vector_unit_top: the command
// path vec_cmd_to_desc maps only LOAD/STORE/ACT/RESADD, so RMSNORM_PARTIAL is
// unreachable from a vec_cmd — vec_cmd_to_desc.sv; this is the "CP not wired"
// scope boundary of §70.1) and issues a VEC_RMSNORM_PARTIAL descriptor on
// desc_i. SRC0 capsules ride t2v with an E8M0 scale on the ABSOLUTE-exponent
// path (inline_scale[BS_ABS_EXP_BIT] = 1, scale_ref = signed block exponent,
// vec_scale_adapter E8M0 abs branch), so each lane enters the reduce cluster
// as (payload lane16, block exponent) with is_zero = (lane16 == 0).
//
// The scalar result leaves on the keep-local L2 write (desc fwd_eligible = 0,
// rw_gnt tied 1): payload[20:0] = mant, payload[30:21] = exp
// (vec_result_packer reduce path). is_nan / is_inf only exist in the result
// capsule's status_flags[1:0] (no consumer in vector_unit), so they are read
// here by HIERARCHICAL REFERENCE into u_vu.result_cap_q (prereg §70.3
// MINOR-5). A missing / renamed field fails ELABORATION (fail-closed), it can
// never read as a silent 0.
//
// The harness is written against names that exist both before and after the
// S-STAT v1.2 RTL change (J1 runs it on the pre-fix RTL).
// ============================================================================
module tb_vec_reduce_stat_e2e
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic                         clk_i,
    input  logic                         rst_ni,

    // ── descriptor (VEC_RMSNORM_PARTIAL, E8M0, keep-local L2 result) ──
    input  logic                         desc_valid_i,
    output logic                         desc_ready_o,
    input  logic                         block32_i,      // 1 = BLOCK_SIZE_32 (2 passes)
    input  logic [15:0]                  dst_row_i,
    input  logic [TAG_W-1:0]             tag_i,

    // ── t2v SRC0 capsule injection ──
    input  logic                         cap_valid_i,
    output logic                         cap_ready_o,
    input  logic [BS_CAP_PAYLOAD_W-1:0]  cap_payload_i,
    input  logic [15:0]                  cap_scale_ref_i, // signed block exponent
    output logic                         miss_valid_o,
    output logic [3:0]                   miss_reason_o,

    // ── observability ──
    output logic                         rw_req_o,
    output logic [L2_BANK_AW-1:0]        rw_row_o,
    output logic [15:0]                  rw_bank_mask_o,
    output logic [511:0]                 rw_wdata_o,
    output logic                         ro_req_o,
    output logic                         v2t_valid_o,
    output logic                         done_o,
    output logic                         err_valid_o,
    output logic [3:0]                   err_code_o,
    output logic [7:0]                   cap_status_flags_o   // u_vu.result_cap_q.status_flags
);

    // ── descriptor: what vec_cmd_to_desc would build, with prim = RMSNORM_PARTIAL ──
    vec_exec_desc_t desc;
    always_comb begin
        desc                  = '0;
        desc.ctx_id           = '0;
        desc.tag              = tag_i;
        desc.op_class         = 3'(VCLASS_REDUCE);
        desc.primitive_id     = 6'(VEC_RMSNORM_PARTIAL);
        desc.elem_fmt         = ELEM_BFP_INTERNAL;
        desc.block_size       = block32_i ? BLOCK_SIZE_32 : BLOCK_SIZE_16;
        desc.scale_format     = SCALE_E8M0;
        desc.layout_tag       = 4'd0;
        desc.dst_ref          = dst_row_i;
        desc.scale_epoch      = 8'd0;
        desc.dest_hint        = DEST_SRAM;
        desc.fwd_eligible     = 1'b0;           // result -> keep-local L2 write
        desc.multi_consumer   = 1'b0;
        desc.src1_resident    = 1'b0;
        desc.block_count      = 16'd1;
    end

    // ── SRC0 capsule: block_size / scale_format track the descriptor (ingress
    //    arb exact-match); E8M0 byte 127 (not the 0xFF NaN code) + ABS bit ──
    bs_capsule_t cap;
    fp_miss_reason_e miss_reason;
    always_comb begin
        cap                    = '0;
        cap.payload            = cap_payload_i;
        cap.elem_fmt           = ELEM_BFP_INTERNAL;
        cap.block_size         = block32_i ? BLOCK_SIZE_32 : BLOCK_SIZE_16;
        cap.scale_format       = SCALE_E8M0;
        cap.layout_tag         = 4'd0;
        cap.scale_ref          = cap_scale_ref_i;
        cap.inline_scale       = 32'(1 << BS_ABS_EXP_BIT) | 32'd127;
        cap.scale_inline_valid = 1'b1;
        cap.scale_epoch        = 8'd0;
        cap.fwd_eligible       = 1'b1;
        cap.operand_role       = OP_SRC0;
        cap.tag                = tag_i;
    end
    assign miss_reason_o = miss_reason;

    vec_error_e                  err_code;
    logic [PERF_CNT_W-1:0]       perf_unused [VEC_NUM_PERF_CNTS];
    assign err_code_o = err_code;

    vector_unit u_vu (
        .clk_i             ( clk_i        ),
        .rst_ni            ( rst_ni       ),
        .soft_reset_i      ( 1'b0         ),
        .desc_valid_i      ( desc_valid_i ),
        .desc_ready_o      ( desc_ready_o ),
        .desc_i            ( desc         ),
        // L2 RO: never used (no resident SRC1, no compact sidecar)
        .ro_req_o          ( ro_req_o     ),
        .ro_gnt_i          ( 1'b0         ),
        .ro_rvalid_i       ( 1'b0         ),
        .ro_row_o          (              ),
        .ro_rdata_i        ( '0           ),
        // L2 RW: always granted
        .rw_req_o          ( rw_req_o       ),
        .rw_gnt_i          ( 1'b1           ),
        .rw_row_o          ( rw_row_o       ),
        .rw_bank_mask_o    ( rw_bank_mask_o ),
        .rw_wdata_o        ( rw_wdata_o     ),
        // fast path SRC0
        .t2v_valid_i       ( cap_valid_i  ),
        .t2v_ready_o       ( cap_ready_o  ),
        .t2v_cap_i         ( cap          ),
        .t2v_miss_valid_o  ( miss_valid_o ),
        .t2v_miss_reason_o ( miss_reason  ),
        // egress unused (fwd_eligible = 0)
        .v2t_valid_o       ( v2t_valid_o  ),
        .v2t_ready_i       ( 1'b0         ),
        .v2t_cap_o         (              ),
        .v2t_miss_valid_i  ( 1'b0         ),
        .v2t_miss_reason_i ( MISS_NONE    ),
        .done_o            ( done_o       ),
        .done_ctx_o        (              ),
        .done_tag_o        (              ),
        .err_valid_o       ( err_valid_o  ),
        .err_code_o        ( err_code     ),
        .busy_o            (              ),
        .perf_cnt_o        ( perf_unused  ),
        .perf_cnt_en_i     ( 1'b0         )
    );

    // §70.3 MINOR-5: hierarchical read of the latched result capsule's flags
    // ([0] = NaN, [1] = Inf; vec_result_packer status_flags).
    assign cap_status_flags_o = u_vu.result_cap_q.status_flags;

endmodule

// ============================================================================
// tb_lane_renorm_precise.sv — D10 chain harness: vec_lane_array -> vec_renorm_quant
//
// Proves the D10 propagation claim (deliverable #3): a per-operand mant_corr
// renorm17 +1 EXP BUMP in the lane is picked up by the UNCHANGED vec_renorm_quant
// as a higher block max-exponent, which then re-aligns every lane to it ("renorm
// 移位 + 抬 shared exp"). Lanes 0..14 are driven with operand set A, lane 15 with
// set B, so the block max-exp and the per-lane realignment are both observable.
// Oracle: Model/bfp_golden.lane_resadd_precise_golden + renorm_block_golden.
// ============================================================================
module tb_lane_renorm_precise
    import pe_pkg::*;
    import vec_pkg::*;
(
    // operand set A (lanes 0..14) and B (lane 15)
    input  logic signed [VEC_MANT_W-1:0] m0_a, m1_a, m0_b, m1_b,
    input  logic signed [VEC_EXP_W-1:0]  e0_a, e1_a, e0_b, e1_b,
    input  vec_lane_op_e lane_op_i,
    input  logic         e4m3_precise_i,
    input  logic [7:0]   mant_corr_s0_i, mant_corr_s1_i,
    input  logic         round_rne_i,
    // renorm observation
    output logic signed [VEC_EXP_W-1:0]  shared_exp_o,
    output logic                         escape_o, scale_changed_o,
    output logic signed [VEC_MANT_W-1:0] p0_o, p15_o
);
    vec_elem_t           s0 [VEC_LANES];
    vec_elem_t           s1 [VEC_LANES];
    vec_lane_result_t    lr [VEC_LANES];
    logic                lvo;
    vec_renorm_result_t  rr;
    vec_ctrl_t           ctrl;
    vec_internal_scale_t orig;

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            s0[i] = VEC_ELEM_ZERO; s1[i] = VEC_ELEM_ZERO;   // note: is_zero defaults 1
            if (i == VEC_LANES-1) begin
                s0[i].mant = m0_b; s0[i].exp = e0_b; s0[i].sign = m0_b[VEC_MANT_W-1]; s0[i].is_zero = 1'b0;
                s1[i].mant = m1_b; s1[i].exp = e1_b; s1[i].sign = m1_b[VEC_MANT_W-1]; s1[i].is_zero = 1'b0;
            end else begin
                s0[i].mant = m0_a; s0[i].exp = e0_a; s0[i].sign = m0_a[VEC_MANT_W-1]; s0[i].is_zero = 1'b0;
                s1[i].mant = m1_a; s1[i].exp = e1_a; s1[i].sign = m1_a[VEC_MANT_W-1]; s1[i].is_zero = 1'b0;
            end
        end
        ctrl            = '0;
        ctrl.block_size = BLOCK_SIZE_16;
        ctrl.renorm_en  = 1'b1;
        ctrl.lane_en    = 1'b1;
        ctrl.lane_op    = lane_op_i;
        orig            = VEC_SCALE_IDENTITY;   // exp_adj=0 -> scale_changed = (max_exp!=0)
    end

    // [C9] standalone contract: in-place shift-control fallback
    logic [5:0] ext_ad_tie [VEC_LANES];
    logic       ext_ss_tie [VEC_LANES];
    logic signed [VEC_MANT_W:0] ext_neg_tie [VEC_LANES];  // [T1b]
    logic signed [VEC_SHIFT_WIDTH-1:0] ext_so_tie [VEC_LANES];  // [LANE2]
    logic                              ext_sk_tie [VEC_LANES];  // [LANE2]
    for (genvar gi = 0; gi < VEC_LANES; gi++) begin : gen_ext_tie
        assign ext_ad_tie[gi] = '0;
        assign ext_ss_tie[gi] = 1'b0;
        assign ext_neg_tie[gi] = '0;
        assign ext_so_tie[gi] = '0;   // [LANE2] standalone: internal align
        assign ext_sk_tie[gi] = 1'b0; // [LANE2]
    end

    vec_lane_array u_lanes (
        .src0_i              ( s0             ),
        .src1_i              ( s1             ),
        .lane_op_i           ( lane_op_i      ),
        .valid_i             ( 1'b1           ),
        .e4m3_precise_i      ( e4m3_precise_i ),
        .mant_corr_s0_i      ( mant_corr_s0_i ),
        .mant_corr_s1_i      ( mant_corr_s1_i ),
        .precise_round_rne_i ( round_rne_i    ),
        .ext_shift_ctrl_valid_i ( 1'b0        ),
        .ext_abs_diff_i      ( ext_ad_tie     ),
        .ext_shift_src1_i    ( ext_ss_tie     ),
        .ext_src1_neg_valid_i ( 1'b0        ),  // [T1b] in-place fallback
        .ext_eff_src1_mant_i  ( ext_neg_tie ),
        .ext_shift_out_i      ( ext_so_tie  ),  // [LANE2] ALIGN_INTERNAL=1 default
        .ext_shift_sticky_i   ( ext_sk_tie  ),  // [LANE2]
        .result_o            ( lr             ),
        .valid_o             ( lvo            )
    );

    vec_renorm_quant u_renorm (
        .lane_results_i ( lr   ),
        .ctrl_i         ( ctrl ),
        .valid_i        ( 1'b1 ),
        .orig_scale_i   ( orig ),
        .result_o       ( rr   )
    );

    assign shared_exp_o    = rr.new_scale.exp_adj;
    assign escape_o        = rr.escape_needed;
    assign scale_changed_o = rr.scale_changed;
    assign p0_o            = rr.packed_mant[0*VEC_MANT_W  +: VEC_MANT_W];
    assign p15_o           = rr.packed_mant[15*VEC_MANT_W +: VEC_MANT_W];
endmodule

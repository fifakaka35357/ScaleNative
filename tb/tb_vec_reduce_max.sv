// ============================================================================
// tb_vec_reduce_max.sv — harness for the VEC_REDUCE_MAX path (TIER-2 review fix)
// ============================================================================
//
// Drives 16 src0 elements through vec_lane_array -> vec_reduce_cluster, with the
// lane micro-op and reduce mode DERIVED from VEC_REDUCE_MAX via the real pe/vec
// _pkg helpers (lane_op_from_primitive / reduce_mode_from_primitive). The src1
// operand is hard-wired to VEC_ELEM_ZERO, exactly mimicking vector_unit's
// need_src1==0 drive for a single-operand reduction (vector_unit.sv:597).
//
// This means the bug and its fix live entirely in the helper mapping: pre-fix
// VEC_REDUCE_MAX -> LANE_MAX makes the lane compute max(src0, 0), ReLU-clamping
// every negative element to a zero whose exp=0 then beats real (negative-exp)
// elements in the exp-first reduce tree => the scalar max collapses to 0 for any
// block whose true maximum is negative, or any negative-exponent block with
// positive elements. Post-fix VEC_REDUCE_MAX -> LANE_REDUCE_P passes elements
// through unchanged (shared block exponent preserved), so the tree's same-exp
// signed-mantissa pair_max returns the correct value-max.
//
// Combinational; cocotb reads result_o after a settle delay.
// ============================================================================

module tb_vec_reduce_max
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  vec_elem_t          src0_i [VEC_LANES],
    output vec_reduce_result_t result_o
);
    // src1 = VEC_ELEM_ZERO on every lane (faithful to vector_unit need_src1==0).
    vec_elem_t src1_z [VEC_LANES];
    for (genvar i = 0; i < VEC_LANES; i++) begin : g_z
        assign src1_z[i] = VEC_ELEM_ZERO;
    end

    // lane_op / reduce_mode come from the REAL helper — the thing under test.
    vec_lane_op_e     lop;
    vec_reduce_mode_e rmode;
    assign lop   = lane_op_from_primitive(VEC_REDUCE_MAX);
    assign rmode = reduce_mode_from_primitive(VEC_REDUCE_MAX);

    vec_lane_result_t lane_results [VEC_LANES];
    logic             lane_valid;

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

    vec_lane_array u_lane (
        .src0_i              (src0_i),
        .src1_i              (src1_z),
        .lane_op_i           (lop),
        .valid_i             (1'b1),
        .e4m3_precise_i      (1'b0),
        .mant_corr_s0_i      (8'd128),
        .mant_corr_s1_i      (8'd128),
        .precise_round_rne_i (1'b0),
        .ext_shift_ctrl_valid_i (1'b0),
        .ext_abs_diff_i      (ext_ad_tie),
        .ext_shift_src1_i    (ext_ss_tie),
        .ext_src1_neg_valid_i ( 1'b0        ),  // [T1b] in-place fallback
        .ext_eff_src1_mant_i  ( ext_neg_tie ),
        .ext_shift_out_i      ( ext_so_tie  ),  // [LANE2] ALIGN_INTERNAL=1 default
        .ext_shift_sticky_i   ( ext_sk_tie  ),  // [LANE2]
        .result_o            (lane_results),
        .valid_o             (lane_valid)
    );

    // S-STAT v1.2 (prereg §74.1.2): raw mant unsigned, raw exp 12-bit (= STAT_EXP_W;
    // spelled VEC_EXP_W+2 so this tb also elaborates against the pre-fix vec_pkg)
    logic [REDUCE_STAT_W-1:0]        stat_m_unused;
    logic signed [VEC_EXP_W+1:0]     stat_e_unused;

    vec_reduce_cluster u_red (
        .lane_results_i  (lane_results),
        .mode_i          (rmode),
        .valid_i         (1'b1),
        .result_o        (result_o),
        .stat_raw_mant_o (stat_m_unused),
        .stat_raw_exp_o  (stat_e_unused)
    );
endmodule

// ============================================================================
// tb_lane_resadd_precise.sv — D10 lane-level harness for E4M3 precise RESADD
//
// Flattens vec_lane_array (16-lane, vec_elem_t array ports) into scalar ports
// for two driven lanes (0 and 1; the rest are forced to VEC_ELEM_ZERO). Two
// lanes are exercised so the cocotb test can confirm the per-lane mant_corr
// leaves are independent while the mant_corr scalars are shared (broadcast) —
// the exact wiring D10 introduces. Pure combinational; the test reads outputs
// after a settle delay. Oracle: Model/bfp_golden.lane_resadd_precise_golden.
// ============================================================================
module tb_lane_resadd_precise
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── lane 0 operands ──
    input  logic signed [VEC_MANT_W-1:0] m0_0, m1_0,
    input  logic signed [VEC_EXP_W-1:0]  e0_0, e1_0,
    input  logic                         z0_0, z1_0,
    // ── lane 1 operands ──
    input  logic signed [VEC_MANT_W-1:0] m0_1, m1_1,
    input  logic signed [VEC_EXP_W-1:0]  e0_1, e1_1,
    input  logic                         z0_1, z1_1,
    // ── control ──
    input  vec_lane_op_e lane_op_i,
    input  logic         e4m3_precise_i,
    input  logic [7:0]   mant_corr_s0_i, mant_corr_s1_i,
    input  logic         round_rne_i,
    // ── lane 0 result ──
    output logic signed [VEC_MANT_W-1:0] r0_mant,
    output logic signed [VEC_EXP_W-1:0]  r0_exp,
    output logic                         r0_sign, r0_zero, r0_ovf,
    // ── lane 1 result ──
    output logic signed [VEC_MANT_W-1:0] r1_mant,
    output logic signed [VEC_EXP_W-1:0]  r1_exp,
    output logic                         r1_sign, r1_zero, r1_ovf
);
    vec_elem_t        s0  [VEC_LANES];
    vec_elem_t        s1  [VEC_LANES];
    vec_lane_result_t res [VEC_LANES];
    logic             vo;

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            s0[i] = VEC_ELEM_ZERO;
            s1[i] = VEC_ELEM_ZERO;
        end
        // lane 0
        s0[0].mant = m0_0; s0[0].exp = e0_0; s0[0].sign = m0_0[VEC_MANT_W-1]; s0[0].is_zero = z0_0;
        s1[0].mant = m1_0; s1[0].exp = e1_0; s1[0].sign = m1_0[VEC_MANT_W-1]; s1[0].is_zero = z1_0;
        // lane 1
        s0[1].mant = m0_1; s0[1].exp = e0_1; s0[1].sign = m0_1[VEC_MANT_W-1]; s0[1].is_zero = z0_1;
        s1[1].mant = m1_1; s1[1].exp = e1_1; s1[1].sign = m1_1[VEC_MANT_W-1]; s1[1].is_zero = z1_1;
    end

    // [C9] standalone contract: no parent-registered shift controls -> the
    // in-place fallback (vec_pkg::vec_lane_shift_ctrl) runs, bit-identical
    // to the pre-C9 inline code.
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
        .ext_shift_ctrl_valid_i ( 1'b0        ),  // [C9] in-place fallback
        .ext_abs_diff_i      ( ext_ad_tie     ),
        .ext_shift_src1_i    ( ext_ss_tie     ),
        .ext_src1_neg_valid_i ( 1'b0        ),  // [T1b] in-place fallback
        .ext_eff_src1_mant_i  ( ext_neg_tie ),
        .ext_shift_out_i      ( ext_so_tie  ),  // [LANE2] ALIGN_INTERNAL=1 default
        .ext_shift_sticky_i   ( ext_sk_tie  ),  // [LANE2]
        .result_o            ( res            ),
        .valid_o             ( vo             )
    );

    assign r0_mant = res[0].mant; assign r0_exp  = res[0].exp;
    assign r0_sign = res[0].sign; assign r0_zero = res[0].is_zero; assign r0_ovf = res[0].overflow;
    assign r1_mant = res[1].mant; assign r1_exp  = res[1].exp;
    assign r1_sign = res[1].sign; assign r1_zero = res[1].is_zero; assign r1_ovf = res[1].overflow;
endmodule

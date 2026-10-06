// ============================================================================
// vec_reduce_max_combine.sv — block32 cross-pass REDUCE_MAX combine (HW-REVIEW T2)
// ============================================================================
//
// Pure combinational. For a block32 (2-pass) VEC_REDUCE_MAX, each pass produces a
// 16-element half-max (vec_reduce_result_t) at that pass's LOCAL block exponent.
// The two half-maxes must be combined into the 32-element max. The two nodes carry
// per-pass exponents (the existence of vec_renorm_xpass / global_max_exp proves the
// passes can have different local exps), so the combine must compare VALUES, not
// exponents-first: value = signed mant * 2^exp.
//
// The previous inline combine (vector_unit.sv) used a SIGN-BLIND exp-first compare
// (pick larger exp; tie -> larger mant) — the exact defect the TIER-2 work removed
// from vec_reduce_cluster.pair_max and vec_lane_array.LANE_MAX, but missed here
// (merge-gate finding). A high-exp NEGATIVE half then wrongly beat a low-exp
// POSITIVE half, silently returning the wrong (more-negative) max on a supported
// softmax-prep config.
//
// Fix: align the lower-exp node to the higher exponent (arithmetic right shift,
// magnitude only matters for the compare) and signed-compare; emit the ORIGINAL
// winning node's (mant, exp) — no precision loss. Mirrors pair_max exactly.
// Flags follow the prior combine (is_nan/is_inf OR, valid AND).
// ============================================================================

module vec_reduce_max_combine
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  vec_reduce_result_t a_i,   // pass-0 half-max
    input  vec_reduce_result_t b_i,   // pass-1 half-max
    output vec_reduce_result_t y_o    // value-correct 32-element max
);
    logic signed [VEC_EXP_W+1:0] ediff;   // widened (M37-Vec): no 10-bit wrap
    logic [5:0]                  amt;
    logic signed [REDUCE_W-1:0]  aa, bb;
    logic                        a_wins;

    always_comb begin
        ediff = (VEC_EXP_W+2)'(signed'(a_i.exp)) - (VEC_EXP_W+2)'(signed'(b_i.exp));
        if (ediff >= (VEC_EXP_W+2)'(0)) begin
            amt = (ediff > (VEC_EXP_W+2)'(REDUCE_W)) ? 6'(REDUCE_W) : 6'(ediff);
            aa  = a_i.mant;
            bb  = b_i.mant >>> amt;
        end else begin
            amt = (-ediff > (VEC_EXP_W+2)'(REDUCE_W)) ? 6'(REDUCE_W) : 6'(-ediff);
            aa  = a_i.mant >>> amt;
            bb  = b_i.mant;
        end
        a_wins = (aa >= bb);

        y_o.mant   = a_wins ? a_i.mant : b_i.mant;
        y_o.exp    = a_wins ? a_i.exp  : b_i.exp;
        y_o.is_nan = a_i.is_nan | b_i.is_nan;
        y_o.is_inf = a_i.is_inf | b_i.is_inf;
        y_o.valid  = a_i.valid  & b_i.valid;
    end

endmodule

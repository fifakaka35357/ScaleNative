// ============================================================================
// vec_renorm_xpass.sv — block32 cross-pass renorm re-alignment (HW-REVIEW T2)
// ============================================================================
//
// Pure combinational. For a block32 (2-pass) renorm-class primitive, vec_renorm_
// quant aligns each 16-lane window to that PASS's LOCAL max exponent and reports
// that local max as new_scale.exp_adj. The two windows are then emitted under ONE
// shared block exponent = global = max(exp0, exp1). The window whose local
// exponent is BELOW global must therefore have EVERY lane mantissa right-shifted
// by (global - local), toward zero — otherwise a consumer reading
// value = mant * 2^global silently inflates that whole 16-lane window by
// 2^(global-local). The previous inline combine in vector_unit relabeled the
// lower window at global WITHOUT this re-shift (HW review 2026-06-20, TIER-2):
// a gross 2^|ΔE| magnitude error of half the block, not a sub-LSB precision loss.
//
// This module re-aligns BOTH windows to global_exp_i (the higher-exp window's
// delta is 0 — an exact no-op). After it, the two-pass block32 result equals the
// conceptual single renorm over all 32 elements aligned to the global max
// (modulo a bounded double-rounding from the two successive toward-zero shifts).
//
// Toward-zero (truncate-magnitude) shift matches vec_renorm_quant.mant_tz_shift
// and vec_tz_shifter: arithmetic >>> then add back 1 when the value is negative
// and any shifted-out bit was set.
// ============================================================================

module vec_renorm_xpass
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic [BS_CAP_PAYLOAD_W-1:0]   win0_i,        // pass-0 mants, aligned to exp0_i
    input  logic signed [VEC_EXP_W-1:0]   exp0_i,        // pass-0 local max exponent
    input  logic [BS_CAP_PAYLOAD_W-1:0]   win1_i,        // pass-1 mants, aligned to exp1_i
    input  logic signed [VEC_EXP_W-1:0]   exp1_i,        // pass-1 local max exponent
    input  logic signed [VEC_EXP_W-1:0]   global_exp_i,  // = max(exp0_i, exp1_i)
    output logic [2*BS_CAP_PAYLOAD_W-1:0] packed_o       // [255:0]=win0@global, [511:256]=win1@global
);

    // Toward-zero right shift of one signed VEC_MANT_W mantissa (matches
    // vec_renorm_quant.mant_tz_shift / vec_tz_shifter convention exactly).
    function automatic logic signed [VEC_MANT_W-1:0] mant_tz_shift(
        input logic signed [VEC_MANT_W-1:0] val,
        input logic [5:0]                   amt
    );
        logic signed [VEC_MANT_W-1:0] shifted;
        logic [VEC_MANT_W-1:0]        mask;
        logic                          residue;
        if (amt == 6'd0)            return val;
        if (amt >= 6'(VEC_MANT_W))  return '0;
        shifted = val >>> amt;
        mask    = (VEC_MANT_W'(1) << amt) - VEC_MANT_W'(1);
        residue = |(val & $unsigned(mask));
        return shifted + VEC_MANT_W'({{(VEC_MANT_W-1){1'b0}}, (val[VEC_MANT_W-1] & residue)});
    endfunction

    // (global - local), clamped to [0,63]. Always >= 0 since global = max(...);
    // the clamp defends against any out-of-range exponent producing a wrap.
    function automatic logic [5:0] delta_amt(
        input logic signed [VEC_EXP_W-1:0] local_exp,
        input logic signed [VEC_EXP_W-1:0] glob
    );
        logic signed [VEC_EXP_W+1:0] d;
        d = (VEC_EXP_W+2)'(signed'(glob)) - (VEC_EXP_W+2)'(signed'(local_exp));
        if (d <= (VEC_EXP_W+2)'(0))       return 6'd0;
        else if (d > (VEC_EXP_W+2)'(63))  return 6'd63;
        else                              return 6'(d);
    endfunction

    logic [5:0] amt0, amt1;
    assign amt0 = delta_amt(exp0_i, global_exp_i);
    assign amt1 = delta_amt(exp1_i, global_exp_i);

    for (genvar i = 0; i < VEC_LANES; i++) begin : g_align
        assign packed_o[i*VEC_MANT_W +: VEC_MANT_W] =
            mant_tz_shift($signed(win0_i[i*VEC_MANT_W +: VEC_MANT_W]), amt0);
        assign packed_o[BS_CAP_PAYLOAD_W + i*VEC_MANT_W +: VEC_MANT_W] =
            mant_tz_shift($signed(win1_i[i*VEC_MANT_W +: VEC_MANT_W]), amt1);
    end

endmodule

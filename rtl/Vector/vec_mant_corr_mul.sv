// ============================================================================
// vec_mant_corr_mul.sv — D10 E4M3 precise-mode mantissa correction (per lane)
// ============================================================================
//
// Applies the NVFP4 E4M3 block scale's MANTISSA factor to a signed block-float
// mantissa: corrected = mant * (mant_corr / 128). This is the per-lane 8b x 16b
// multiply that closes the H21 "mant_corr has no consumer" gap — simple mode
// applies only exp_adj (to the exponent) and drops mant_corr, so E4M3 round-trip
// was metadata-only; D10 precise mode applies it for real.
//
//   mant_corr (vec_internal_scale_t) = (1 + m3/8) * 128 in {128,144,..,240}
//   for E4M3 (m3=0..7) -> factor in [1.0, 1.875]. 128 = 1.0 = identity.
//
// |mant| * mant_corr -> >> 7 (/128) with RTZ/RNE rounding -> clamp to signed
// MANT_W -> re-apply sign. overflow_o flags saturation (the renorm stage that
// instantiates this corrects it by shifting + bumping the shared exponent).
//
// Oracle: Model/bfp_golden.py mant_corr_apply_golden. Combinational leaf.
// ============================================================================

module vec_mant_corr_mul #(
    parameter int MANT_W = 16
) (
    input  logic signed [MANT_W-1:0] mant_i,        // operand mantissa (signed)
    input  logic [7:0]               mant_corr_i,   // E4M3 mantissa correction (128 = 1.0)
    input  logic                     round_rne_i,   // 0 = RTZ, 1 = RNE
    output logic signed [MANT_W-1:0] mant_o,
    output logic                     overflow_o
);
    localparam int PW = MANT_W + 8;                 // product width (16b x 8b)
    localparam logic [PW-1:0] QMAX     = PW'((1 << (MANT_W - 1)) - 1);  //  2^(W-1)-1
    localparam logic [PW-1:0] QMIN_MAG = PW'( 1 << (MANT_W - 1));        //  2^(W-1)

    logic              sign;
    logic [MANT_W-1:0] mag;
    logic [PW-1:0]     prod, q0, qfull;
    logic [6:0]        rem;
    logic              round_up;

    assign sign = mant_i[MANT_W-1];
    assign mag  = sign ? MANT_W'(-mant_i) : mant_i;     // |mant| (block-float mant << 2^(W-1))
    assign prod = mag * mant_corr_i;                    // unsigned 24b

    always_comb begin
        q0       = prod >> 7;                           // / 128
        rem      = prod[6:0];
        round_up = round_rne_i & ((rem > 7'd64) | ((rem == 7'd64) & q0[0]));
        qfull    = q0 + (round_up ? PW'(1) : PW'(0));

        if (sign) begin
            overflow_o = (qfull > QMIN_MAG);
            // q >= 2^(W-1) maps to -2^(W-1); only q > 2^(W-1) is saturation.
            mant_o = (qfull >= QMIN_MAG) ? {1'b1, {(MANT_W-1){1'b0}}}
                                         : -signed'(MANT_W'(qfull));
        end else begin
            overflow_o = (qfull > QMAX);
            mant_o = (qfull > QMAX) ? {1'b0, {(MANT_W-1){1'b1}}}
                                    : signed'(MANT_W'(qfull));
        end
    end
endmodule

// ============================================================================
// vec_scale_adapter — Dual-format block-scale decoder (C11)
// ============================================================================
//
// Pure-combinational converter from a raw 8-bit block-scale encoding (OCP-MX
// E8M0 or NVFP4 E4M3) into the unified vec_internal_scale_t consumed by every
// downstream Vector module (lanes, reduce, renorm, packer). This module was
// referenced by vector_unit (u_scale_adapter_src0/src1) but its source file
// was missing — without it the Vector Unit could not elaborate. (Decision C11.)
//
// Decode contract (VEC_README §3.6 / §5.6; vec_pkg vec_internal_scale_t):
//
//   E8M0 : 8-bit unsigned exponent, bias 127.  value = 2^(raw-127).
//          exp_adj  = raw - 127
//          mant_corr = 128 (1.0 — no fractional part)
//          raw == 0xFF → NaN scale.
//
//   E4M3 : {sign, exp[3:0], mant[2:0]}, bias 7.  value = (1 + m/8) * 2^(exp-7).
//          exp_adj  = exp - 7
//          mant_corr = {1'b1, mant[2:0], 4'b0} = (1 + m/8) * 128   (v2 lossless;
//          the 3 mantissa bits are preserved exactly so vec_result_packer can
//          re-encode E4M3 with 0% round-trip error).
//          low 7 bits == 7'h7F (exp=1111, mant=111) → NaN scale.
//          exp == 0 → zero/subnormal → flush-to-zero (special_zero).
//
// Special-value adjudication happens HERE so the raw encoding differences never
// propagate downstream:
//   - NaN scale          → special_nan + error_o (a required NaN scale is a
//                          contract violation → VERR_SCALE_DECODE upstream).
//   - E4M3 zero/subnormal → special_zero (flush-to-zero), NOT an error.
//
// scale_inline_valid_i == 0 is the LEGAL identity fallback (the capsule simply
// carries no inline scale): emit VEC_SCALE_IDENTITY (1.0) with error_o = 0, so
// it does not trip VERR_SCALE_DECODE. Likewise when valid_i == 0 (the adapter
// is not being consumed this cycle) the outputs are a quiet identity.
//
// Author: H-Tensor Vector Project
// ============================================================================

module vec_scale_adapter
  import pe_pkg::*;
  import vec_pkg::*;
(
  // ---- Inputs ----
  input  logic [7:0]          raw_scale_i,          // raw block-scale byte
  input  scale_format_e       scale_format_i,       // SCALE_E8M0 / SCALE_E4M3
  input  logic                scale_inline_valid_i, // capsule carries an inline scale
  input  logic                valid_i,              // adapter is consumed this cycle
  // [HW-REVIEW T3] absolute-scale alignment (E4M3 and, since FF2, E8M0): when
  // abs_exp_valid_i, the alignment exponent comes from the UNCLAMPED signed abs_exp_i
  // (= capsule.scale_ref), not the byte exponent. Caller sets abs_exp_valid_i =
  // inline_scale[8] && scale_format in {E4M3, E8M0}. On E4M3 mant_corr is taken from the
  // byte (lossless); on E8M0 mant_corr is always 1.0 (E8M0 has no mantissa).
  input  logic signed [15:0]  abs_exp_i,            // absolute block exponent (scale_ref)
  input  logic                abs_exp_valid_i,      // use abs_exp_i (E4M3 abs path)

  // ---- Outputs ----
  output vec_internal_scale_t scale_o,              // unified internal scale
  output logic                valid_o,              // mirrors valid_i
  output logic                error_o               // decode failure (NaN scale / bad format)
);

  always_comb begin
    // Defaults: quiet identity, no error. Covers valid_i==0 and the legal
    // scale_inline_valid_i==0 fallback without any further logic.
    scale_o = VEC_SCALE_IDENTITY;
    error_o = 1'b0;
    valid_o = valid_i;

    if (valid_i && scale_inline_valid_i) begin
      unique case (scale_format_i)

        // ---------------------------------------------------------------
        // E8M0 — pure exponent, bias 127
        // ---------------------------------------------------------------
        SCALE_E8M0: begin
          if (raw_scale_i == 8'hFF) begin
            scale_o.special_nan = 1'b1;       // NaN block scale
            error_o             = 1'b1;
          end else if (abs_exp_valid_i) begin
            // [HW-REVIEW T3-FF/FF2] absolute-scale path for E8M0 (block32 resident):
            // align by the UNCLAMPED signed abs_exp_i (= scale_ref), saturated to
            // VEC_EXP_W ([-512,511]). E8M0 has NO mantissa, so mant_corr is ALWAYS 1.0
            // — do NOT reuse the E4M3 byte mant_corr (the byte is a fixed 0x38
            // placeholder on the resident path; decoding it here would give exp -71).
            if      (abs_exp_i >  16'sd511)  scale_o.exp_adj = VEC_EXP_W'(16'sd511);
            else if (abs_exp_i < -16'sd512)  scale_o.exp_adj = VEC_EXP_W'(-16'sd512);
            else                             scale_o.exp_adj = VEC_EXP_W'(abs_exp_i);
            scale_o.mant_corr = 8'd128;       // 1.0 (E8M0 has no mantissa)
          end else begin
            scale_o.exp_adj   = VEC_EXP_W'(signed'({2'b0, raw_scale_i}) - 10'sd127);
            scale_o.mant_corr = 8'd128;       // 1.0
          end
        end

        // ---------------------------------------------------------------
        // E4M3 — exponent + significand, bias 7 (v2 lossless mant_corr)
        // ---------------------------------------------------------------
        SCALE_E4M3: begin
          if (raw_scale_i[6:0] == 7'h7F) begin
            scale_o.special_nan = 1'b1;       // NaN (exp=1111, mant=111) — honored on both paths
            error_o             = 1'b1;
          end else if (abs_exp_valid_i) begin
            // [HW-REVIEW T3] absolute-scale path: align by the UNCLAMPED signed
            // abs_exp_i (= scale_ref), saturated to the lane exponent width VEC_EXP_W
            // ([-512,511]). mant_corr still comes from the E4M3 byte (000 -> 128 = 1.0).
            // The byte exponent is decorative here (external/NVFP4 carrier only), so no
            // special_zero FTZ on the byte exp in this path.
            if      (abs_exp_i >  16'sd511)  scale_o.exp_adj = VEC_EXP_W'(16'sd511);
            else if (abs_exp_i < -16'sd512)  scale_o.exp_adj = VEC_EXP_W'(-16'sd512);
            else                             scale_o.exp_adj = VEC_EXP_W'(abs_exp_i);
            scale_o.mant_corr = {1'b1, raw_scale_i[2:0], 4'b0};
          end else if (raw_scale_i[6:3] == 4'd0) begin
            scale_o.special_zero = 1'b1;      // exp=0 → zero / subnormal → FTZ (legacy)
            scale_o.mant_corr    = 8'd128;
          end else begin
            scale_o.exp_adj   = VEC_EXP_W'(signed'({6'b0, raw_scale_i[6:3]}) - 10'sd7);  // legacy byte
            scale_o.mant_corr  = {1'b1, raw_scale_i[2:0], 4'b0};  // (1+m/8)*128
          end
        end

        // ---------------------------------------------------------------
        // Unsupported / reserved scale format → decode error
        // ---------------------------------------------------------------
        default: begin
          error_o = 1'b1;
        end

      endcase
    end
  end

  // ==========================================================================
  // Assertions (immediate — combinational module, Verilator-safe)
  // ==========================================================================
  // synopsys translate_off
  always_comb begin
    if (valid_i) begin
      assert_scale_no_x: assert (!$isunknown({raw_scale_i, scale_format_i, scale_inline_valid_i}))
        else $error("vec_scale_adapter: input contains X while valid_i asserted");
      // A clean (non-error, non-special) decode must yield a normalized mant_corr in [128,240].
      assert_mant_corr_norm: assert (error_o || scale_o.special_zero
                                     || (scale_o.mant_corr >= 8'd128))
        else $error("vec_scale_adapter: mant_corr below 1.0 on a normal decode (0x%0h)", scale_o.mant_corr);
      // [HW-REVIEW T3] warn (loud, non-fatal) if the absolute block exponent exceeds the
      // lane width (VEC_EXP_W=10 -> [-512,511]); the abs branch then saturates as a graceful
      // defensive clamp (so this path stays unit-testable). Realistic GEMM/residual exponents
      // are far inside this range, so a hit indicates a software/config error.
      assert_abs_exp_range: assert (!abs_exp_valid_i
                                    || (abs_exp_i >= -16'sd512 && abs_exp_i <= 16'sd511))
        else $warning("vec_scale_adapter: abs_exp_i=%0d out of VEC_EXP_W range [-512,511] (saturated)", abs_exp_i);
    end
  end
  // synopsys translate_on

endmodule

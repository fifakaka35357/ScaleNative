// ============================================================================
// Output Format Unit (OFU) v4.3 (Round E1 / R2.3)
// ============================================================================
//
// Pure combinational reference implementation that converts the internal
// block-float accumulator output (fp_acc_output_t) to a standard FP format.
//
// Supported output formats (selected by `out_fmt` input):
//   OUT_FMT_BF16  — BF16 E8M7  (16-bit)
//   OUT_FMT_FP16  — FP16 E5M10 (16-bit, IEEE 754)
//   OUT_FMT_FP8   — FP8 (per FP8_FMT param: E4M3FN or E5M2)
//   OUT_FMT_FP32  — FP32 E8M23 (32-bit, IEEE 754)
//
// ----------------------------------------------------------------------------
// ARCHITECTURAL MIGRATION STATUS (Round E1)
// ----------------------------------------------------------------------------
//
// As of Round E1, the OFU is in the process of being migrated OUT of the
// Tensor Unit and INTO the Vector Unit as a sidecar module. See:
//
//   Vector_Unit_OFU_Sidecar_Design_Plan.md  (Phase E1 deliverable)
//
// Rationale:
//   The paper's core framing is that the Tensor Unit's output contract is
//   pure block-float (fp_acc_output_t), and the block-float → standard FP
//   format boundary belongs to the Vector domain. Keeping the OFU as a
//   per-MAC component inside the Tensor Unit is an architectural leak of
//   that contract. The Vector-side sidecar is where this module will live.
//
// Current status (Round E1 / R2.3):
//   - This file is PRESERVED but will be REMOVED from tensor_mac_array
//     instantiation in Round 6 (R6).
//   - It remains compilable and functionally identical — testbenches can
//     still instantiate it as a golden model for verification against
//     Tensor Unit's block-float output.
//   - Phase E2/E3 will wrap this module as a 16-lane sidecar inside the
//     Vector Unit with three ingress queues (Tensor / Vector / SRAM-reload).
//
// File naming convention:
//   This file uses no prefix (neither mac_ nor tensor_) because it is
//   NOT a Tensor Unit component. It is shared infrastructure that future
//   Vector Unit modules will instantiate.
//
// ----------------------------------------------------------------------------
// Round E1 / R2.3 changes:
//   - File  rename:    upe_output_format_unit.sv → output_format_unit.sv
//                      (no mac_ prefix — future Vector sidecar, not MAC-scope)
//   - Module rename:   upe_output_format_unit → output_format_unit
//   - Package import:  upe_pkg → tensor_pkg
//   - Port types:      ofu_fmt_e → out_fmt_e, ofu_round_e → out_round_e
//   - Enum values:     OFU_FMT_{BF16,FP16,FP8,FP32} → OUT_FMT_{BF16,FP16,FP8,FP32}
//                      OFU_ROUND_{RTZ,RNE}          → OUT_ROUND_{RTZ,RNE}
//   - Comment updates: "one OFU per PE" → "per-MAC reference; future Vector sidecar"
//                      "upstream in the PE" → "upstream in the MAC cell"
//
//   * BUG FIX: Clock-reference assertions
//
//     The original upe_output_format_unit had 4 concurrent assertions at
//     the end of the module using `assert property (@(posedge clk) ...)`,
//     but this module has NO `clk` input port — it is pure combinational.
//     Under strict SV elaboration (pyslang, Verilator --lint-only, rigorous
//     VCS/Xcelium), the undeclared `clk` identifier causes an elaboration
//     error. This is a pre-existing bug from v4.2 Round 10.
//
//     Fix: Convert the 4 concurrent assertions to immediate assertions
//     inside a dedicated `always_comb` block. Immediate assertions fire
//     whenever the always_comb retriggers, which is on any input change —
//     exactly the semantics we want for X-detection on combinational inputs.
//
//     Additional rewrite: the 4th original assertion used SVA implication
//     `ofu_valid |-> !$isunknown(result)`, which is not valid in immediate
//     assertion context. Rewritten as boolean:
//         `!ofu_valid || !$isunknown(result)`
//     (equivalent truth table).
//
//     All 4 assertion semantics are preserved; only the trigger mechanism
//     changes from clocked to combinational.
//
//   - No functional datapath changes (LZC, normalize, round, pack, range
//     check, special-value handling — all byte-for-byte identical to v4.2)
//
// ----------------------------------------------------------------------------
// Pipeline:
//   1. Special value priority: NaN → Inf → zero → finite
//   2. LZC (leading zero count) on mant[47:0]
//   3. Left-normalize: mant << lzc, exp_norm = acc_exp - lzc
//   4. Biased exponent: biased_exp = exp_norm + target_bias
//   5. Extract mantissa fraction + guard/round/sticky
//   6. Round (RTZ or RNE)
//   7. Post-round carry: if mantissa overflows, >>1, exp+1
//   8. Range check: overflow → Inf (or saturate), underflow → 0 (FTZ)
//   9. Pack into target format
//
// This is a reference version: one OFU per MAC cell (Round E1 baseline
// before migration). Future Vector sidecar: 16-lane parallel OFU array
// with shared ingress arbitration.
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R2.3 — tensor_pkg migration + assertion bug fix)
//
// Prior version history:
//   v4.2 (Round 10): Defensive assertions added (but with clock bug — fixed in R2.3)
//   v4.1:            Per-format constants MUX, LZC+normalize, full round/pack
//   v4.0:            Initial reference implementation
// ============================================================================

module output_format_unit
  import tensor_pkg::*;
(
  // ---- Input: block-float accumulator result ----
  input  fp_acc_output_t     acc_in,

  // ---- Control ----
  input  out_fmt_e           out_fmt,      // Target output format
  input  out_round_e         round_mode,   // Rounding mode (RTZ or RNE)

  // ---- Output: packed floating-point result ----
  output logic [31:0]        result,       // Packed result (right-aligned)
                                           //   FP32: all 32 bits
                                           //   BF16/FP16: [15:0] valid
                                           //   FP8: [7:0] valid
  output logic               ofu_valid     // Result is meaningful (not X)
);

  // ==========================================================================
  // Per-Format Constants
  // ==========================================================================
  // Selected at runtime via out_fmt — synthesizes to MUX tree.

  logic [4:0] tgt_exp_w;      // Target exponent width
  logic [4:0] tgt_mant_w;     // Target mantissa (fraction) width
  logic signed [9:0] tgt_bias;       // Target exponent bias
  logic signed [9:0] tgt_exp_max;    // Max biased exponent for normal values
  logic        tgt_has_inf;    // Format supports Inf encoding

  always_comb begin
    unique case (out_fmt)
      OUT_FMT_BF16: begin
        tgt_exp_w   = 5'd8;
        tgt_mant_w  = 5'd7;
        tgt_bias    = 10'sd127;
        tgt_exp_max = 10'sd254;
        tgt_has_inf = 1'b1;
      end
      OUT_FMT_FP16: begin
        tgt_exp_w   = 5'd5;
        tgt_mant_w  = 5'd10;
        tgt_bias    = 10'sd15;
        tgt_exp_max = 10'sd30;
        tgt_has_inf = 1'b1;
      end
      OUT_FMT_FP8: begin
        tgt_exp_w   = 5'(FP8_EXP_W);
        tgt_mant_w  = 5'(FP8_MANT_W);
        tgt_bias    = 10'(FP8_BIAS);
        // E4M3FN: max biased exp = 15 (exp=1111 is valid for frac≠111; only frac=111 is NaN)
        // E5M2:   max biased exp = 30 (exp=11110; exp=11111 reserved for Inf/NaN)
        tgt_exp_max = (FP8_FMT == FP8_E4M3FN) ? 10'sd15 : 10'sd30;
        tgt_has_inf = FP8_HAS_INF;
      end
      default: begin  // FP32
        tgt_exp_w   = 5'd8;
        tgt_mant_w  = 5'd23;
        tgt_bias    = 10'sd127;
        tgt_exp_max = 10'sd254;
        tgt_has_inf = 1'b1;
      end
    endcase
  end

  // ==========================================================================
  // Step 1: Special Value Priority Check
  // ==========================================================================
  logic is_nan, is_inf, is_zero;

  assign is_nan  = acc_in.is_nan;
  assign is_inf  = acc_in.is_inf && !acc_in.is_nan;
  assign is_zero = (acc_in.mant == 48'd0) && !is_nan && !is_inf;

  // ==========================================================================
  // Step 2: Leading Zero Count (48-bit)
  // ==========================================================================
  // Counts leading zeros from bit[47] downward.
  // For mant=0, lzc=48 (handled by is_zero check above).

  logic [5:0] lzc;  // 0..48

  always_comb begin
    lzc = 6'd48;  // Default: all zeros
    for (int i = 47; i >= 0; i--) begin
      if (acc_in.mant[i]) begin
        lzc = 6'(47 - i);
        break;
      end
    end
  end

  // ==========================================================================
  // Step 3: Left-Normalize
  // ==========================================================================
  // After shift, norm_mant[47] = 1 (hidden bit) for non-zero values.
  //   norm_mant[46:0] = fraction bits (MSB-aligned)
  //
  // C07: under the frozen convention acc_in is value = mant * 2^acc_exp with
  // mant a 48-bit INTEGER whose leading 1 sits at bit (ACC_MANT_MSB - lzc).
  // Hence value = 1.frac * 2^(acc_exp + ACC_MANT_MSB - lzc), so the unbiased
  // exponent of the normalized 1.frac significand is:
  //   norm_exp = acc_exp + (ACC_MANT_MSB - lzc)
  // The pre-C07 code used acc_exp - lzc (missing +ACC_MANT_MSB), making every
  // escape result 2^47 too small. This MUST stay in lockstep with the source
  // rebias in mac_lru / mac_cell (see tensor_pkg C07 convention block).

  logic [47:0]       norm_mant;
  logic signed [9:0] norm_exp;

  always_comb begin
    norm_mant = acc_in.mant << lzc;
    norm_exp  = acc_in.exp + 10'(ACC_MANT_MSB) - 10'(signed'({4'b0, lzc}));
  end

  // ==========================================================================
  // Step 4: Biased Exponent
  // ==========================================================================
  logic signed [10:0] biased_exp;  // Extra bit for overflow detection

  assign biased_exp = 11'(norm_exp) + 11'(tgt_bias);

  // ==========================================================================
  // Step 5: Extract Fraction + Guard/Round/Sticky
  // ==========================================================================
  //
  // norm_mant layout (48-bit, bit 47 is hidden '1'):
  //   [47]              = hidden bit (always 1 for normalized)
  //   [46 : 47-tgt_mant_w]  = fraction bits to keep
  //   [46-tgt_mant_w]   = guard bit (G)
  //   [45-tgt_mant_w]   = round bit (R)
  //   [44-tgt_mant_w : 0] = sticky region (S = OR of all)
  //
  // Since tgt_mant_w is runtime, we use shift-based extraction.

  // Position of guard bit from bit 0: 46 - tgt_mant_w
  logic [5:0] guard_pos;
  assign guard_pos = 6'd46 - {1'b0, tgt_mant_w};

  // Fraction to keep: norm_mant[46 : guard_pos+1], width = tgt_mant_w
  // We extract into a 23-bit field (max mant width = FP32's 23 bits)
  logic [22:0] frac_raw;
  logic        guard_bit, round_bit, sticky_bits;

  always_comb begin
    // Shift norm_mant right so that the fraction aligns to [tgt_mant_w-1:0]
    // Then mask to tgt_mant_w bits
    frac_raw = 23'(norm_mant[46:24]);  // Default: FP32 (23 bits from [46:24])

    unique case (out_fmt)
      OUT_FMT_BF16: begin  // 7 fraction bits from [46:40]
        frac_raw    = {16'd0, norm_mant[46:40]};
        guard_bit   = norm_mant[39];
        round_bit   = norm_mant[38];
        sticky_bits = |norm_mant[37:0];
      end
      OUT_FMT_FP16: begin  // 10 fraction bits from [46:37]
        frac_raw    = {13'd0, norm_mant[46:37]};
        guard_bit   = norm_mant[36];
        round_bit   = norm_mant[35];
        sticky_bits = |norm_mant[34:0];
      end
      OUT_FMT_FP8: begin
        if (FP8_FMT == FP8_E4M3FN) begin  // 3 fraction bits from [46:44]
          frac_raw    = {20'd0, norm_mant[46:44]};
          guard_bit   = norm_mant[43];
          round_bit   = norm_mant[42];
          sticky_bits = |norm_mant[41:0];
        end else begin  // E5M2: 2 fraction bits from [46:45]
          frac_raw    = {21'd0, norm_mant[46:45]};
          guard_bit   = norm_mant[44];
          round_bit   = norm_mant[43];
          sticky_bits = |norm_mant[42:0];
        end
      end
      default: begin  // FP32: 23 fraction bits from [46:24]
        frac_raw    = norm_mant[46:24];
        guard_bit   = norm_mant[23];
        round_bit   = norm_mant[22];
        sticky_bits = |norm_mant[21:0];
      end
    endcase
  end

  // ==========================================================================
  // Step 6: Rounding
  // ==========================================================================
  logic        round_up;

  always_comb begin
    unique case (round_mode)
      OUT_ROUND_RTZ: begin
        round_up = 1'b0;
      end
      OUT_ROUND_RNE: begin
        // Round to nearest, ties to even
        round_up = guard_bit && ((round_bit | sticky_bits) | frac_raw[0]);
      end
      default: round_up = 1'b0;
    endcase
  end

  // ==========================================================================
  // Step 7: Post-Round Adjustment (per-format to avoid variable-width slices)
  // ==========================================================================
  logic [22:0]        frac_final;
  logic signed [10:0] exp_final;

  always_comb begin
    frac_final = '0;
    exp_final  = biased_exp;

    unique case (out_fmt)
      OUT_FMT_BF16: begin  // 7-bit fraction
        automatic logic [7:0] fr = {1'b0, frac_raw[6:0]} + {7'd0, round_up};
        if (fr[7]) begin  // carry
          frac_final[6:0] = fr[7:1];
          exp_final = biased_exp + 11'sd1;
        end else begin
          frac_final[6:0] = fr[6:0];
        end
      end
      OUT_FMT_FP16: begin  // 10-bit fraction
        automatic logic [10:0] fr = {1'b0, frac_raw[9:0]} + {10'd0, round_up};
        if (fr[10]) begin
          frac_final[9:0] = fr[10:1];
          exp_final = biased_exp + 11'sd1;
        end else begin
          frac_final[9:0] = fr[9:0];
        end
      end
      OUT_FMT_FP8: begin
        if (FP8_FMT == FP8_E4M3FN) begin  // 3-bit fraction
          automatic logic [3:0] fr = {1'b0, frac_raw[2:0]} + {3'd0, round_up};
          if (fr[3]) begin
            frac_final[2:0] = fr[3:1];
            exp_final = biased_exp + 11'sd1;
          end else begin
            frac_final[2:0] = fr[2:0];
          end
        end else begin  // E5M2: 2-bit fraction
          automatic logic [2:0] fr = {1'b0, frac_raw[1:0]} + {2'd0, round_up};
          if (fr[2]) begin
            frac_final[1:0] = fr[2:1];
            exp_final = biased_exp + 11'sd1;
          end else begin
            frac_final[1:0] = fr[1:0];
          end
        end
      end
      default: begin  // FP32: 23-bit fraction
        automatic logic [23:0] fr = {1'b0, frac_raw[22:0]} + {23'd0, round_up};
        if (fr[23]) begin
          frac_final[22:0] = fr[23:1];
          exp_final = biased_exp + 11'sd1;
        end else begin
          frac_final[22:0] = fr[22:0];
        end
      end
    endcase
  end

  // ==========================================================================
  // Step 8+9: Range Check + Pack
  // ==========================================================================
  logic        out_sign;
  logic [7:0]  out_exp;
  logic [22:0] out_frac;

  always_comb begin
    result    = 32'd0;
    ofu_valid = 1'b1;
    out_sign  = acc_in.sign;

    // ---- Priority: NaN > Inf > overflow > underflow > zero > normal ----

    if (is_nan) begin
      // Canonical NaN: all-ones exp, non-zero frac (quiet NaN)
      unique case (out_fmt)
        OUT_FMT_BF16: result = {1'b0, 8'hFF, 7'h40};          // 16'h7FC0
        OUT_FMT_FP16: result = {1'b0, 5'h1F, 10'h200};        // 16'h7E00
        OUT_FMT_FP8: begin
          if (FP8_FMT == FP8_E4M3FN)
            result = {24'd0, 1'b0, 4'hF, 3'b111};              // 8'h7F (only NaN)
          else
            result = {24'd0, 1'b0, 5'h1F, 2'b01};              // 8'h7D (qNaN)
        end
        default:      result = {1'b0, 8'hFF, 23'h400000};      // FP32 qNaN
      endcase

    end else if (is_inf) begin
      unique case (out_fmt)
        OUT_FMT_BF16: result = {out_sign, 8'hFF, 7'h00};
        OUT_FMT_FP16: result = {out_sign, 5'h1F, 10'h000};
        OUT_FMT_FP8: begin
          if (FP8_FMT == FP8_E4M3FN) begin
            // E4M3FN has no Inf → saturate to max finite
            result = {24'd0, out_sign, 4'hF, 3'b110};          // ±448.0
          end else begin
            result = {24'd0, out_sign, 5'h1F, 2'b00};          // ±Inf
          end
        end
        default:      result = {out_sign, 8'hFF, 23'h000000};  // FP32 ±Inf
      endcase

    end else if (is_zero) begin
      // Signed zero
      unique case (out_fmt)
        OUT_FMT_BF16: result = {out_sign, 15'd0};
        OUT_FMT_FP16: result = {out_sign, 15'd0};
        OUT_FMT_FP8:  result = {24'd0, out_sign, 7'd0};
        default:       result = {out_sign, 31'd0};
      endcase

    end else begin
      // ---- Finite path ----

      if (exp_final > 11'(tgt_exp_max)) begin
        // Overflow → Inf or saturate
        if (tgt_has_inf) begin
          // Encode ±Inf
          unique case (out_fmt)
            OUT_FMT_BF16: result = {out_sign, 8'hFF, 7'h00};
            OUT_FMT_FP16: result = {out_sign, 5'h1F, 10'h000};
            OUT_FMT_FP8:  result = {24'd0, out_sign, 5'h1F, 2'b00};  // E5M2 Inf
            default:       result = {out_sign, 8'hFF, 23'h000000};
          endcase
        end else begin
          // No Inf (E4M3FN): saturate to max finite
          result = {24'd0, out_sign, 4'hF, 3'b110};  // ±448.0
        end

      end else if (exp_final < 11'sd1) begin
        // Underflow → FTZ (flush to zero)
        unique case (out_fmt)
          OUT_FMT_BF16: result = {out_sign, 15'd0};
          OUT_FMT_FP16: result = {out_sign, 15'd0};
          OUT_FMT_FP8:  result = {24'd0, out_sign, 7'd0};
          default:       result = {out_sign, 31'd0};
        endcase

      end else begin
        // Normal value — pack
        out_exp  = exp_final[7:0];
        out_frac = frac_final;

        unique case (out_fmt)
          OUT_FMT_BF16: result = {out_sign, out_exp[7:0], out_frac[6:0]};
          OUT_FMT_FP16: result = {out_sign, out_exp[4:0], out_frac[9:0]};
          OUT_FMT_FP8: begin
            if (FP8_FMT == FP8_E4M3FN) begin
              // Guard: exp=0xF with frac=0x7 is NaN, must not encode normal as NaN
              if (out_exp[3:0] == 4'hF && out_frac[2:0] == 3'b111)
                result = {24'd0, out_sign, 4'hF, 3'b110};  // Saturate
              else
                result = {24'd0, out_sign, out_exp[3:0], out_frac[2:0]};
            end else begin
              result = {24'd0, out_sign, out_exp[4:0], out_frac[1:0]};
            end
          end
          default: result = {out_sign, out_exp[7:0], out_frac[22:0]};
        endcase
      end
    end
  end

  // ==========================================================================
  // Assertions (R2.3 fix: converted from clocked to immediate)
  // ==========================================================================
  //
  // R2.3 note:
  //
  //   The original upe_output_format_unit had these as concurrent assertions
  //   using `assert property (@(posedge clk) ...)`, but this module has NO
  //   clock input port — it is pure combinational. The undeclared `clk`
  //   identifier caused elaboration errors under strict SV tooling.
  //
  //   Fix: convert to immediate assertions inside a dedicated `always_comb`
  //   block. Immediate assertions fire whenever the block retriggers, which
  //   happens on any input change — exactly the semantics we want for
  //   X-detection on pure combinational inputs.
  //
  //   The 4th assertion originally used SVA implication `ofu_valid |->
  //   !$isunknown(result)`, which is not valid in immediate assertion form.
  //   Rewritten equivalently as `(!ofu_valid || !$isunknown(result))`.
  //
  //   All 4 assertion semantics preserved; only the trigger mechanism
  //   changes from clocked to combinational.
  //
  // synopsys translate_off
  always_comb begin

    // Input data integrity: accumulator output must not contain X (unknown).
    // If this fires, there is a data corruption or uninitialized register
    // upstream in the MAC cell (accumulator, alignment unit, or product assembly).
    assert_acc_mant_no_x: assert (!$isunknown(acc_in.mant))
      else $error("OFU: acc_in.mant contains X — upstream data integrity issue");

    assert_acc_exp_no_x: assert (!$isunknown(acc_in.exp))
      else $error("OFU: acc_in.exp contains X — upstream data integrity issue");

    assert_acc_flags_no_x: assert (!$isunknown({acc_in.sign, acc_in.is_nan, acc_in.is_inf}))
      else $error("OFU: acc_in control flags contain X — upstream integrity issue");

    // Output integrity: result must not contain X when ofu_valid is asserted.
    // (ofu_valid is always 1 in the current reference implementation, but
    //  future pipelined versions may gate it.)
    //
    // R2.3: rewritten from `ofu_valid |-> !$isunknown(result)` to
    //       boolean form for immediate assertion compatibility.
    assert_result_no_x_when_valid: assert (!ofu_valid || !$isunknown(result))
      else $error("OFU: result contains X while ofu_valid asserted");

  end
  // synopsys translate_on

endmodule

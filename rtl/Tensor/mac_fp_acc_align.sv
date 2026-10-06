// ============================================================================
// MAC FP Accumulator Alignment Unit v4.3 (Round E1 / R2.2)
// ============================================================================
//
// Pure combinational block that prepares two operands (incoming product and
// current accumulator state) for 48-bit addition by aligning them to a
// common exponent.
//
// Previously named upe_fp_acc_align. Renamed as part of the Round E naming
// cleanup (UPE → MAC cell distinction). No functional changes.
//
// ----------------------------------------------------------------------------
// Round E1 / R2.2 changes:
//   - File  rename:     upe_fp_acc_align.sv → mac_fp_acc_align.sv
//   - Module rename:    upe_fp_acc_align  → mac_fp_acc_align
//   - Package import:   upe_pkg → tensor_pkg
//   - Type rename:      upe_mode_e → tensor_mode_e
//   - Submodule rename: upe_tz_shifter → mac_tz_shifter (u_align_shifter)
//   - Comment updates:  "upe_fp_accumulator" → "mac_fp_accumulator"
//   - No functional logic changes
//
// ----------------------------------------------------------------------------
// Dataflow:
//   1. Input MUX — select {mant, exp, zero} from LRU or BF16 direct path
//   2. Exponent Compare — determine shift direction and amount
//   3. Toward-Zero Shift — instantiate one mac_tz_shifter on the smaller-
//      exponent operand (MUX selects which side gets shifted)
//   4. Output — aligned operand pair + shared exponent for the top-level adder
//
// Design choices:
//   - Single shifter instance: a front MUX routes either acc or prod into
//     the shifter, and a back MUX routes the result to the correct output.
//     This saves ~200 gates/MAC vs dual-shifter while adding only 2 MUX levels
//     (~1 gate delay) to the critical path.
//   - acc_is_zero flag: on the first accumulation of a new dot-product the
//     accumulator registers hold stale data. Rather than shifting stale
//     values, we unconditionally adopt the product and mark acc as zero.
//
// Ref: UPE_Core_v4_Analysis.md §3.1–3.3
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R2.2 — tensor_pkg migration + mac_tz_shifter instance)
//
// Inherited from v4.1 Round 2:
//   P5 sticky: injection of shifter sticky into shifted operand LSB
//   P6:        49-bit support via parameter (ACC_W = INTERNAL_W at top level)
//   P12:       power gate shifter inputs when acc_is_zero
// ============================================================================

module mac_fp_acc_align
  import tensor_pkg::*;
#(
  parameter int ACC_W     = ACC_WIDTH_DEFAULT,  // Accumulator mantissa width (48)
  parameter int SHIFT_MAX = 40                  // Alignment clamp threshold
) (
  // ---- Product Inputs (from LRU or BF16 path) ----
  input  lru_result_t    lru_in,
  input  fp_product_t    bf16_prod_in,
  input  tensor_mode_e   mode,

  // ---- Accumulator Current State (from top-level registers) ----
  input  logic signed [ACC_W-1:0] acc_mant_in,
  input  logic signed [9:0]       acc_exp_in,
  input  logic                    acc_is_zero,   // First accumulation flag

  // ---- Aligned Outputs (to top-level adder) ----
  // [GR-A 2026-07-28] output contract change (bit-exact identity, review-
  // gated): instead of {aligned_prod, aligned_acc} with the toward-zero
  // correction and sticky OR-ed in, the aligner hands the accumulator the
  // three addends of the SAME sum:
  //     other + shifted_raw + K  ==  other + ((shifted+corr) with LSB|=sticky)
  // with K[0] = res & ~shifted_raw[0], K[1] = res & neg & shifted_raw[0]
  // (K ∈ {0,1,2}; exhaustively proven for all three shifter arms —
  // k1cb_gra_identity_proof_20260728.py, ALL-GREEN). This removes the 49-bit
  // correction increment carry chain from the align critical path; the
  // accumulator folds K into its CSA row.
  output logic signed [ACC_W-1:0] add_other,     // Un-shifted operand
  output logic signed [ACC_W-1:0] add_shifted,   // Raw floor-shifted operand
  output logic [1:0]              add_k,         // Folded correction+sticky addend
  output logic signed [9:0]       new_exp,       // Shared exponent after alignment
  output logic                    skip           // Product is zero → skip addition
);

  // ==========================================================================
  // Stage 1 — Input Selection
  // ==========================================================================
  // Unified product representation regardless of source path.

  logic signed [ACC_W-1:0] prod_mant;
  logic signed [9:0]       prod_exp;
  logic                    prod_zero;

  always_comb begin
    // Defaults: zero product, skip accumulation
    prod_mant = '0;
    prod_exp  = 10'sd0;
    prod_zero = 1'b1;

    unique case (mode)
      // LRU path: FP4/FP8 and their MX variants
      //   lru_in.mant is 15-bit signed → sign-extend to ACC_W
      MODE_FP4, MODE_FP8, MODE_MXFP4, MODE_MXFP8: begin
        prod_mant = ACC_W'(signed'(lru_in.mant));
        prod_exp  = signed'(lru_in.exp);
        prod_zero = lru_in.zero;
      end

      // BF16 / MXINT8 direct path (uses fracturable adder tree, not LRU)
      //   bf16_prod_in.mant is 16-bit signed → sign-extend to ACC_W
      //   v4.1: MXINT8 also routes through bf16_prod (path migration)
      MODE_BF16, MODE_MXINT8: begin
        prod_mant = ACC_W'(signed'(bf16_prod_in.mant));
        prod_exp  = signed'(bf16_prod_in.exp);
        prod_zero = bf16_prod_in.zero;
      end

      // INT modes (UINT4_SIMD, UINT8) bypass FP accumulator
      default: begin
        prod_zero = 1'b1;  // Force skip
      end
    endcase
  end

  // ==========================================================================
  // Stage 2 — Exponent Comparison + Shift Routing
  // ==========================================================================
  //
  // Three cases:
  //   (a) acc_is_zero          → adopt product directly, no shift needed
  //   (b) prod_exp > acc_exp   → shift accumulator right (acc is smaller)
  //   (c) prod_exp <= acc_exp  → shift product right (prod is smaller)
  //
  // `shift_acc` selects which operand enters the mac_tz_shifter.

  // M37: compute the exponent difference in a WIDENED 12-bit signed domain.
  //   prod_exp, acc_exp ∈ [-512,511] (10-bit signed). Under extreme-but-legal MX
  //   scales their difference can exceed ±511 (e.g. MXFP8 prod_exp spans roughly
  //   [-282,+261] → |diff| up to ~543), which wraps a 10-bit subtraction and
  //   FLIPS the shift direction (the dominant operand gets flushed to sticky).
  //   12-bit holds ±2047, so the sign/direction and the clamp are correct; the
  //   shift amount is then saturated to SHIFT_MAX by the toward-zero shifter.
  logic signed [11:0]      exp_diff;      // prod_exp − acc_exp (widened, signed)
  logic [5:0]              abs_exp_diff;   // |exp_diff| for shifter (clamped 0..63)
  logic                    shift_acc;      // 1 = shift accumulator, 0 = shift product

  // Shifter interface signals (one shared instance)
  logic signed [ACC_W-1:0] shifter_in;
  logic signed [ACC_W-1:0] shifter_out;
  logic                    shifter_sticky; // Injected into aligned output LSB (v4.1)
  logic                    shifter_clamped;

  always_comb begin
    // M37: 12-bit widened subtraction (no wraparound for legal exponent spans).
    exp_diff = 12'(signed'(prod_exp)) - 12'(signed'(acc_exp_in));

    // Absolute value of exponent difference → shift amount
    // Clamp to 6-bit unsigned (max 63, but SHIFT_MAX caps at 40)
    if (exp_diff >= 12'sd0)
      abs_exp_diff = (exp_diff > 12'sd63) ? 6'd63 : 6'(exp_diff);
    else
      abs_exp_diff = (-exp_diff > 12'sd63) ? 6'd63 : 6'(-exp_diff);

    // Shift direction: shift the smaller-exponent side
    //   acc_is_zero overrides: always adopt product (no shift needed,
    //   but we route acc through shifter for cleanliness — it's zero anyway)
    shift_acc = acc_is_zero || (exp_diff > 12'sd0);
  end

  // ==========================================================================
  // Stage 3 — Shared Toward-Zero Shifter Instance
  // ==========================================================================
  // Front MUX: route either acc_mant or prod_mant into the shifter.
  // The non-shifted operand passes through unchanged.
  //
  // v4.1 fix (P12): when acc_is_zero, the shifter result is ignored
  // (Stage 4 unconditionally adopts prod_mant). Gate both shifter_in
  // and shift_amt to zero to prevent useless switching power.

  logic [5:0] eff_shift_amt;

  always_comb begin
    if (acc_is_zero) begin
      shifter_in    = '0;    // Avoid shifting stale acc value
      eff_shift_amt = 6'd0;  // No shift needed
    end else begin
      shifter_in    = shift_acc ? acc_mant_in : prod_mant;
      eff_shift_amt = abs_exp_diff;
    end
  end

  logic signed [ACC_W-1:0] shifter_raw;   // [GR-A] floor shift, no correction

  mac_tz_shifter #(
    .WIDTH     (ACC_W),
    .SHIFT_MAX (SHIFT_MAX)
  ) u_align_shifter (
    .val_in    (shifter_in),
    .shift_amt (eff_shift_amt),    // v4.1: gated when acc_is_zero
    .val_out   (shifter_out),      // [GR-A] unused here — pruned in synthesis
    .sticky    (shifter_sticky),
    .clamped   (shifter_clamped),
    .val_raw   (shifter_raw)       // [GR-A] the raw path the K-fold consumes
  );

  // ==========================================================================
  // Stage 4 — Output Assembly
  // ==========================================================================
  // Back MUX: route shifter output to the correct operand, pass the other
  // through unmodified. Select the larger exponent as the shared base.
  //
  // v4.1 fix (P5): inject shifter_sticky into the shifted operand's LSB.
  // This preserves "existence" information from bits shifted beyond precision,
  // improving accuracy when exp_diff is large (especially > SHIFT_MAX).
  // Without this, the clamped operand is hard-truncated to 0 with no trace.

  // [GR-A] K-fold: the toward-zero correction (neg & res) and the sticky
  // OR-into-LSB collapse into one 2-bit addend on the raw-shifted operand
  // (identity 2, all three shifter arms covered — clamp arm has raw='0 so
  // K degenerates to res, matching the old 0|sticky value).
  logic       k_neg;
  logic [1:0] k_val;
  assign k_neg = shifter_in[ACC_W-1];
  assign k_val = { shifter_sticky &  k_neg & shifter_raw[0],
                   shifter_sticky & ~shifter_raw[0] };

  always_comb begin
    skip = prod_zero;

    if (acc_is_zero) begin
      // First accumulation: product passes through, acc contributes 0
      // (shifter input is gated to 0 → raw = 0, sticky = 0, K = 0)
      add_other   = prod_mant;
      add_shifted = '0;
      add_k       = 2'd0;
      new_exp     = prod_exp;

    end else if (shift_acc) begin
      // Product exponent is larger → accumulator was shifted
      add_other   = prod_mant;
      add_shifted = shifter_raw;
      add_k       = k_val;
      new_exp     = prod_exp;                                 // Adopt larger exponent

    end else begin
      // Accumulator exponent is larger (or equal) → product was shifted
      add_other   = acc_mant_in;
      add_shifted = shifter_raw;
      add_k       = k_val;
      new_exp     = acc_exp_in;                               // Keep accumulator exponent
    end
  end

endmodule

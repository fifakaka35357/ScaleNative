// ============================================================================
// MAC Toward-Zero Right Shifter v4.3 (Round E1 / R2.1)
// ============================================================================
//
// Pure-combinational primitive that performs arithmetic right shift with
// toward-zero truncation semantics on signed two's complement values, plus
// sticky bit generation.
//
// Previously named upe_tz_shifter. Renamed as part of the Round E naming
// cleanup (UPE → MAC cell distinction). No functional changes.
//
// ----------------------------------------------------------------------------
// Round E1 / R2.1 changes:
//   - File  rename: upe_tz_shifter.sv → mac_tz_shifter.sv
//   - Module rename: upe_tz_shifter  → mac_tz_shifter
//   - Package import: upe_pkg → tensor_pkg
//   - Comment updates: "upe_fp_accumulator" → "mac_fp_accumulator"
//   - No functional logic changes
//
// ----------------------------------------------------------------------------
// Problem solved (ref: UPE_Core_v4_Analysis.md §3.3):
//   Standard arithmetic right shift (>>>) on negative values rounds toward
//   −∞ (floor division). For block-float accumulation this introduces a
//   systematic negative bias: e.g. -3 >>> 40 = -1, but the correct
//   toward-zero result is 0. Over K=256 accumulations the cumulative error
//   can reach -256 ulp — catastrophic for FP4 with ~2-bit effective precision.
//
// Solution:
//   shifted_tz = (val >>> n) + (is_negative & has_residue)
//   This converts floor(x/2^n) → ceil(x/2^n) for negative x, which equals
//   truncation toward zero. For positive x the correction term is 0.
//
// Clamp behavior (ref: §3.2):
//   When shift_amt > SHIFT_MAX, the entire value is lost. Rather than
//   building a full-width barrel shifter, we output zero and set sticky=1
//   if the original value was non-zero.
//
// Instantiated twice in mac_fp_accumulator:
//   Instance 1: Alignment shifter (shift_amt = 0..40, full barrel)
//   Instance 2: Overflow renorm   (shift_amt = 1, synthesizes to 1-bit MUX)
//
// Also reusable by the output format unit (future Vector-side sidecar).
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R2.1 — tensor_pkg migration)
// ============================================================================

module mac_tz_shifter
  import tensor_pkg::*;
#(
  parameter int WIDTH     = ACC_WIDTH_DEFAULT,  // Operand width (default 48)
  parameter int SHIFT_MAX = 40                  // Clamp threshold
) (
  // ---- Inputs ----
  input  logic signed [WIDTH-1:0] val_in,     // Signed value to shift
  input  logic [5:0]              shift_amt,   // Shift amount (unsigned, 0–63)

  // ---- Outputs ----
  output logic signed [WIDTH-1:0] val_out,    // Toward-zero shifted result
  output logic                    sticky,      // OR of all shifted-out bits
  output logic                    clamped,     // shift_amt exceeded SHIFT_MAX
  // [GR-A 2026-07-28] raw floor shift, NO toward-zero correction — the
  // correction folds into the consumer's adder as K (mac_fp_acc_align).
  // Per-arm contract (MUST match the identity-proof model,
  // k1cb_gra_identity_proof_20260728.py — review B2-F4):
  //   clamp arm ('0), zero-shift arm (val_in), normal arm (val_in >>> amt).
  output logic signed [WIDTH-1:0] val_raw
);

  // ==========================================================================
  // Internal Signals
  // ==========================================================================
  logic signed [WIDTH-1:0] shifted_arith;   // Raw arithmetic right shift
  logic                    is_negative;      // Sign of input
  logic                    has_residue;      // Any shifted-out bit was non-zero
  logic [WIDTH-1:0]        residue_mask;     // Mask selecting bits that shift out

  // ==========================================================================
  // Combinational Logic
  // ==========================================================================
  always_comb begin

    // Default outputs
    val_out  = '0;
    sticky   = 1'b0;
    clamped  = 1'b0;
    val_raw  = '0;   // [GR-A] clamp-arm value IS the contract ('0)

    is_negative = val_in[WIDTH-1];

    // ------------------------------------------------------------------
    // Path 1: Clamped — shift exceeds useful range
    // ------------------------------------------------------------------
    // All significant bits are lost. Output is zero, but we preserve
    // "existence" information via sticky for downstream rounding.
    if (shift_amt > SHIFT_MAX[5:0]) begin
      clamped = 1'b1;
      val_out = '0;
      sticky  = |val_in;  // Non-zero input → sticky = 1

    // ------------------------------------------------------------------
    // Path 2: Zero shift — passthrough
    // ------------------------------------------------------------------
    end else if (shift_amt == 6'd0) begin
      val_out = val_in;
      sticky  = 1'b0;
      val_raw = val_in;   // [GR-A] zero-shift arm: passthrough

    // ------------------------------------------------------------------
    // Path 3: Normal shift with toward-zero correction
    // ------------------------------------------------------------------
    end else begin

      // Step 1: Standard arithmetic right shift (rounds toward −∞)
      shifted_arith = val_in >>> shift_amt;

      // Step 2: Build residue mask — lowest `shift_amt` bits set to 1
      //   residue_mask = (1 << shift_amt) - 1
      //   This selects exactly the bits that are shifted out.
      residue_mask = (WIDTH'(1) << shift_amt) - WIDTH'(1);

      // Step 3: Detect if any shifted-out bit was non-zero
      //   has_residue serves double duty as both the toward-zero
      //   correction trigger AND the sticky bit output.
      has_residue = |(val_in & $unsigned(residue_mask));

      // Step 4: Toward-zero correction
      //   For negative values: floor(x/2^n) + 1 = ceil(x/2^n) = toward_zero
      //   For positive values: correction term = 0 (no change needed)
      //
      //   Example: val_in = -3, shift_amt = 40
      //     shifted_arith = -1  (floor(-3 / 2^40))
      //     has_residue   = 1   (-3 has non-zero low bits)
      //     correction    = 1
      //     val_out       = -1 + 1 = 0  ✓ (toward zero)
      //
      //   Example: val_in = -8, shift_amt = 3
      //     shifted_arith = -1  (floor(-8 / 8) = -1)
      //     has_residue   = 0   (-8 = ...11111000, low 3 bits = 000)
      //     correction    = 0
      //     val_out       = -1  ✓ (exact division, no correction needed)
      //
      //   Example: val_in = +7, shift_amt = 2
      //     shifted_arith = +1  (floor(7 / 4) = 1)
      //     is_negative   = 0
      //     correction    = 0
      //     val_out       = +1  ✓ (positive: floor = toward-zero)
      val_out = shifted_arith
              + WIDTH'({{(WIDTH-1){1'b0}}, (is_negative & has_residue)});
      val_raw = shifted_arith;   // [GR-A] normal arm: floor, no correction

      // Step 5: Sticky output (shared computation with has_residue)
      sticky = has_residue;
    end
  end

endmodule

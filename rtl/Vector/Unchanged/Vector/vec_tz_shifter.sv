// =============================================================================
// vec_tz_shifter.sv — Toward-Zero Right Shifter (Vector Unit Copy)
//
// Independent copy of upe_tz_shifter.sv for Vector layer isolation.
// No package dependency — fully parameterized pure combinational primitive.
//
// Purpose:
//   Performs arithmetic right shift with toward-zero truncation semantics
//   on signed two's complement values, plus sticky bit generation.
//
// Problem solved:
//   Standard arithmetic right shift (>>>) on negative values rounds toward
//   −∞ (floor division). For block-float aligned addition (VEC_RESADD) this
//   introduces a systematic negative bias: e.g. -3 >>> 40 = -1, but the
//   correct toward-zero result is 0. Over K accumulated elements the error
//   can be significant for low-precision formats.
//
// Solution:
//   shifted_tz = (val >>> n) + (is_negative & has_residue)
//   This converts floor(x/2^n) → ceil(x/2^n) for negative x, which equals
//   truncation toward zero. For positive x the correction term is 0.
//
// Clamp behavior:
//   When shift_amt > SHIFT_MAX, the entire value is lost. Output is zero
//   and sticky=1 if the original value was non-zero.
//
// Usage within Vector Unit:
//   - vec_lane_array:  alignment shifting for VEC_RESADD (two operand align)
//   - vec_renorm_quant: potential renormalization shifts
//
// Future consolidation note:
//   This module is intentionally duplicated from upe_tz_shifter.sv to avoid
//   Vector→UPE cross-layer dependency during initial development. When the
//   PE project matures, both copies can be unified into a shared arithmetic
//   library (e.g., pe_arith_pkg) without changing any module interfaces.
//
// Author:  H-Tensor Project
// Version: 1.0 (Vector-independent copy, logic identical to upe_tz_shifter v4.0)
// =============================================================================

module vec_tz_shifter #(
    parameter int WIDTH     = 48,    // Operand width (signed two's complement)
    parameter int SHIFT_MAX = 40     // Clamp threshold (shifts > this → zero + sticky)
) (
    // ---- Inputs ----
    input  logic signed [WIDTH-1:0] val_in,      // Signed value to shift
    input  logic [5:0]              shift_amt,    // Shift amount (unsigned, 0–63)

    // ---- Outputs ----
    output logic signed [WIDTH-1:0] val_out,     // Toward-zero shifted result
    output logic                    sticky,       // OR of all shifted-out bits
    output logic                    clamped       // shift_amt exceeded SHIFT_MAX
);

    // =========================================================================
    // Internal Signals
    // =========================================================================
    logic signed [WIDTH-1:0] shifted_arith;    // Raw arithmetic right shift
    logic                    is_negative;       // Sign of input
    logic                    has_residue;       // Any shifted-out bit was non-zero
    logic [WIDTH-1:0]        residue_mask;      // Mask selecting bits that shift out

    // =========================================================================
    // Combinational Logic
    // =========================================================================
    always_comb begin

        // Default outputs
        val_out  = '0;
        sticky   = 1'b0;
        clamped  = 1'b0;

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
            //     val_out       = -1  ✓ (exact division)
            //
            //   Example: val_in = +7, shift_amt = 2
            //     shifted_arith = +1  (floor(7 / 4) = 1)
            //     is_negative   = 0
            //     correction    = 0
            //     val_out       = +1  ✓ (positive: floor = toward-zero)
            val_out = shifted_arith
                    + WIDTH'({{(WIDTH-1){1'b0}}, (is_negative & has_residue)});

            // Step 5: Sticky output (shared computation with has_residue)
            sticky = has_residue;
        end
    end

endmodule

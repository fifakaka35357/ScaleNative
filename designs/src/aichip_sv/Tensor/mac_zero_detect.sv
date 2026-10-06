// ============================================================================
// MAC Zero Detection Unit v4.3 (Round E1 / R2.1)
// ============================================================================
//
// Pure combinational block that produces per-lane zero flags and accumulator
// skip signals for all 8 compute modes. These signals drive:
//   - mul_prod_gated: power gating of individual multiplier lanes
//   - skip_accumulation: bypass both LRU and accumulator when all lanes zero
//   - sparsity_map feedback to SCU for compression decisions
//
// Previously named upe_zero_detect. Renamed as part of the Round E naming
// cleanup (UPE → MAC cell distinction). No functional changes.
//
// ----------------------------------------------------------------------------
// Round E1 / R2.1 changes:
//   - File  rename: upe_zero_detect.sv → mac_zero_detect.sv
//   - Module rename: upe_zero_detect  → mac_zero_detect
//   - Package import: upe_pkg → tensor_pkg
//   - Type rename:    upe_mode_e → tensor_mode_e
//   - Comment updates: "upe_lru" → "mac_lru", "upe_core_sparse" → "mac_cell"
//   - No functional logic changes
//
// ----------------------------------------------------------------------------
// v4.2 changes (inherited):
//
//   A4 FIX — lane_valid-aware skip logic:
//     `lane_valid[3:0]` input from the tile controller (via the MAC cell).
//     skip_accumulation explicitly considers only valid lanes:
//       effective_zero = mul_zero | ~lane_valid
//       skip = &effective_zero
//     This ensures that tail-masked (invalid) lanes do not incorrectly
//     prevent a skip when all *valid* lanes are zero, and do not
//     incorrectly cause a skip when valid lanes have data.
//
//     In practice, the input mux (R4) already forces invalid-lane inputs
//     to zero, so mul_zero[i]=1 for masked lanes. The explicit lane_valid
//     check is therefore semantically redundant for current code but makes
//     the intent clear and robust against future input_mux changes.
//
// v4.0 changes (ref: UPE_Core_v4_Analysis.md §4.1):
//   v3.0 treated FP4/MXFP4 as single-lane (only mul_zero[0] active).
//   v4.0 extends to true per-lane detection for all active lanes:
//     FP4/MXFP4: 4 independent lane checks via lru_lane_zero[3:0]
//     FP8/MXFP8: 2 independent lane checks via lru_lane_zero[1:0]
//   This enables finer-grained power gating and correct SCU pack semantics.
//
// Zero detection sources by mode:
//   FP4/FP8/MXFP4/MXFP8 → lru_lane_zero (computed inside mac_lru)
//   BF16                  → exponent field == 0 on either operand
//   UINT4_SIMD            → any 4-bit nibble pair has a zero operand
//   UINT8 / MXINT8        → either 8-bit operand is zero
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R2.1 — tensor_pkg migration)
// ============================================================================

module mac_zero_detect
  import tensor_pkg::*;
(
  // ---- Control ----
  input  tensor_mode_e  mode,

  // ---- LRU Zero Flags (FP/MX modes) ----
  // Directly from mac_lru.lane_zero output.
  // Bit i = 1 means lane i product is zero (subnormal flush or zero input).
  input  logic [3:0]    lru_lane_zero,

  // ---- Raw Operands (INT/BF16 modes) ----
  // 16-bit packed weight and activation as received by mac_cell.
  // Bit-field interpretation depends on mode (handled internally).
  input  logic [15:0]   weight_in,
  input  logic [15:0]   act_in,

  // ---- Lane Valid Mask (v4.2 — from controller tail mask via MAC cell) ----
  //
  // Per-lane valid flag from the tile controller.
  //   lane_valid[i] = 1: lane i carries valid data this cycle
  //   lane_valid[i] = 0: lane i is tail-masked (invalid, input forced to zero)
  //
  // Used to compute skip_accumulation: only valid lanes participate.
  // Invalid lanes should not prevent a skip (their data is garbage/zero),
  // and should not cause a false skip when valid lanes have real data.
  input  logic [3:0]    lane_valid,

  // ---- Detection Result ----
  output zero_detect_result_t result
);

  // ==========================================================================
  // Internal Signals
  // ==========================================================================

  // Per-lane zero flags (before packaging into result struct)
  logic [3:0] mul_zero;

  // BF16 operand-level zero (either weight or activation exponent is zero)
  logic       bf16_input_zero;

  // v4.2: Effective per-lane zero considering lane validity
  //   For each lane: "effectively zero" if data is zero OR lane is invalid.
  //   skip_accumulation fires only when ALL lanes are effectively zero.
  logic [3:0] effective_lane_zero;

  // ==========================================================================
  // Combinational Detection Logic
  // ==========================================================================
  always_comb begin

    // Defaults: all lanes non-zero, no gating, no skip
    mul_zero       = 4'b0000;
    bf16_input_zero = 1'b0;

    unique case (mode)

      // -----------------------------------------------------------------
      // FP4 / MXFP4 — 4 active lanes, zero detection from LRU
      // -----------------------------------------------------------------
      // Each lane independently checks (exp_a == 0 || exp_b == 0) inside
      // mac_lru. We consume the result directly.
      MODE_FP4, MODE_MXFP4: begin
        mul_zero = lru_lane_zero;
      end

      // -----------------------------------------------------------------
      // FP8 / MXFP8 — 2 active lanes, lanes 2–3 inactive
      // -----------------------------------------------------------------
      // Only lanes 0–1 carry valid FP8 products. Lanes 2–3 are marked
      // as zero (inactive) to allow power gating.
      MODE_FP8, MODE_MXFP8: begin
        mul_zero[0] = lru_lane_zero[0];
        mul_zero[1] = lru_lane_zero[1];
        mul_zero[2] = 1'b1;  // Inactive lane
        mul_zero[3] = 1'b1;  // Inactive lane
      end

      // -----------------------------------------------------------------
      // BF16 — single multiply, zero = either exponent field is 0
      // -----------------------------------------------------------------
      // BF16 format: {sign(1), exp(8), frac(7)} = 16 bits
      // Exponent field: weight_in[14:7], act_in[14:7]
      // All 4 multiplier lanes are fused for BF16 mantissa multiply,
      // so all lanes share the same zero flag.
      MODE_BF16: begin
        bf16_input_zero = (weight_in[14:7] == 8'd0)
                       || (act_in[14:7]    == 8'd0);
        mul_zero = {4{bf16_input_zero}};
      end

      // -----------------------------------------------------------------
      // UINT4 SIMD — 4 independent 4-bit multiplier lanes
      // -----------------------------------------------------------------
      MODE_UINT4_SIMD: begin
        mul_zero[0] = (weight_in[3:0]   == 4'd0) || (act_in[3:0]   == 4'd0);
        mul_zero[1] = (weight_in[7:4]   == 4'd0) || (act_in[7:4]   == 4'd0);
        mul_zero[2] = (weight_in[11:8]  == 4'd0) || (act_in[11:8]  == 4'd0);
        mul_zero[3] = (weight_in[15:12] == 4'd0) || (act_in[15:12] == 4'd0);
      end

      // -----------------------------------------------------------------
      // UINT8 — single 8-bit multiply (lower bytes), lanes 1–3 unused
      // -----------------------------------------------------------------
      MODE_UINT8: begin
        mul_zero[0] = (weight_in[7:0] == 8'd0) || (act_in[7:0] == 8'd0);
        mul_zero[1] = 1'b1;  // Fused into lane 0
        mul_zero[2] = 1'b1;
        mul_zero[3] = 1'b1;
      end

      // -----------------------------------------------------------------
      // MXINT8 — 8-bit integer with block scale, same zero logic as UINT8
      // -----------------------------------------------------------------
      MODE_MXINT8: begin
        mul_zero[0] = (weight_in[7:0] == 8'd0) || (act_in[7:0] == 8'd0);
        mul_zero[1] = 1'b1;
        mul_zero[2] = 1'b1;
        mul_zero[3] = 1'b1;
      end

      default: begin
        mul_zero = 4'b1111;  // Unknown mode: treat as all-zero (safe)
      end

    endcase

    // =====================================================================
    // v4.2: Effective Lane Zero (tail-mask-aware)
    // =====================================================================
    //
    // For skip_accumulation, we need to know: "are all VALID lanes zero?"
    //
    //   effective_lane_zero[i] = mul_zero[i] | ~lane_valid[i]
    //
    // Interpretation:
    //   - lane_valid[i]=1, mul_zero[i]=1  →  effective=1 (valid lane, but zero data)
    //   - lane_valid[i]=1, mul_zero[i]=0  →  effective=0 (valid lane, has data → don't skip)
    //   - lane_valid[i]=0, mul_zero[i]=X  →  effective=1 (invalid lane, doesn't block skip)
    //
    // &effective_lane_zero = 1  ⟺  every valid lane is zero (safe to skip)
    //
    // Note: In current v4.2+ code, the input mux (R4) already forces
    // invalid-lane inputs to zero, so mul_zero[i] will be 1 for masked lanes
    // anyway. The explicit lane_valid term here is a semantic safety net —
    // it makes the skip decision correct even if input_mux behavior changes.

    effective_lane_zero = mul_zero | ~lane_valid;

    // =====================================================================
    // Result Struct Assembly
    // =====================================================================

    // Per-lane zero flags (direct — reflects actual data zero, not lane validity)
    result.mul_zero = mul_zero;

    // Per-lane gating signals (inverted: 1 = lane active, 0 = gated off)
    // Used by mac_cell to gate multiplier inputs for power saving.
    result.mul_gate = ~mul_zero;

    // Aggregate all-zero flag (all 4 lanes, including inactive ones)
    result.all_zero = &mul_zero;

    // Skip accumulation: all VALID lanes are zero → no useful work
    //
    // v4.2 change: uses effective_lane_zero instead of raw mul_zero.
    //
    // Examples:
    //   FP4 K=5, last cycle: lane_valid=4'b0001
    //     lane 0 has data=0 → effective[0]=1
    //     lanes 1-3 invalid → effective[1:3]=1
    //     → skip=1 (correct: only valid lane is zero)
    //
    //   FP4 K=5, last cycle: lane_valid=4'b0001
    //     lane 0 has data≠0 → effective[0]=0
    //     lanes 1-3 invalid → effective[1:3]=1
    //     → skip=0 (correct: valid lane has data)
    //
    //   FP4 normal cycle: lane_valid=4'b1111
    //     → effective = mul_zero (same as v4.1)
    result.skip_accumulation = &effective_lane_zero;

    // FP input-level zero (legacy compatibility: indicates at least one
    // FP operand has zero exponent, regardless of lane structure)
    result.fp_input_zero = bf16_input_zero
                        || (lru_lane_zero[0] & (mode == MODE_FP4
                                              || mode == MODE_FP8
                                              || mode == MODE_MXFP4
                                              || mode == MODE_MXFP8));

  end

endmodule

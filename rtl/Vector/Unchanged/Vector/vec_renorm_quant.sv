// =============================================================================
// vec_renorm_quant.sv — Renormalization & Requantization Engine (Vector Unit, v2)
//
// Pure combinational module that takes per-lane results and produces a
// renormalized block with a single updated shared exponent.
//
// [C9-b 2026-07-25] STRUCTURAL split into two sub-leaves + this wrapper
// (the C8-a requantizer front/back pattern):
//   vec_renorm_front — Stage 1 only: the balanced max/min-exp tree +
//                      any_normal/any_nan/any_inf/any_overflow flags.
//   vec_renorm_back  — Stages 2-5: escape detection, per-element re-align
//                      to max_exp, new-scale construction, packing, output
//                      assembly. Consumes the front outputs.
//   vec_renorm_quant — front+back composed combinationally, ports UNCHANGED
//                      (every existing standalone consumer bit-identical by
//                      construction).
// WHY: the deployed PH_RENORM arc lane_results_q -> u_renorm ->
// renorm_result_q measured 1750.47 ps (a1_probes tier-3, 2026-07-25) — above
// the 600 MHz budget once the C8-c/C9 walls fall. vector_unit instantiates
// front and back separately with the front outputs REGISTERED at the
// PH_RENORM boundary (new 5th rotor phase PH_RENORM2 runs the back half).
//
// v2 changes from v1:
//   - VEC_LANES: 8 → 16 (automatic via vec_pkg parameter).
//     All scan loops, alignment arrays, and packing loops scale automatically.
//   - new_scale includes mant_corr = 128 (1.0): renorm always produces a pure
//     power-of-2 shared exponent, so the fractional mantissa correction is
//     identity. This enables lossless re-encode in vec_result_packer.
//   - active_lanes: with VEC_LANES=16, both block_size=16 and block_size=32
//     produce active_lanes=16 (one full lane window per pass).
//     For block_size=32, the multi-pass controller in vector_unit feeds
//     different 16-element windows across passes. This module processes
//     one window at a time, unaware of multi-pass orchestration.
//
// Core function:
//   After lane arithmetic (e.g., RESADD) or block merge/split, elements
//   within a block may have divergent exponents. Renormalization finds
//   the new maximum exponent, shifts all mantissas to align with it,
//   and produces a packed output suitable for capsule formation.
//
// Operations:
//   RENORM:     Find max_exp across elements → shift all to max_exp
//   REQUANT:    RENORM + truncate mantissa to target bit-width (future)
//   REFRESH:    Force recompute of shared exponent (same as RENORM)
//   MERGE_POST: After block merge, reconcile two sub-block scales
//   SPLIT_POST: After block split, recompute per-sub-block scale
//
// Escape detection:
//   If the dynamic range across elements exceeds VEC_MANT_W - 2 bits
//   (meaning alignment shifts would lose >50% of mantissa precision),
//   escape_needed is asserted. The Vector Unit top-level decides the
//   fallback path (v2: forced L2 write-back as lossless spill).
//
// Precision policy:
//   Uses toward-zero truncation on re-alignment shifts, consistent
//   with vec_tz_shifter and upe_fp_accumulator conventions.
//   Future can add configurable rounding (RNE, stochastic, etc.)
//   controlled by ctrl.round_sat_policy.
//
// Author:  H-Tensor Project
// Version: 2.1 (C9-b — front/back split, wrapper contract unchanged)
// =============================================================================

// =============================================================================
// vec_renorm_front — Stage 1: balanced max/min-exp reduction + block flags
// =============================================================================
module vec_renorm_front
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  vec_lane_result_t  lane_results_i [VEC_LANES],
    input  vec_ctrl_t         ctrl_i,

    output logic signed [VEC_EXP_W-1:0] max_exp_o,
    output logic signed [VEC_EXP_W-1:0] min_exp_o,
    output logic                        any_normal_o,
    output logic                        any_nan_o,
    output logic                        any_inf_o,
    output logic                        any_overflow_o
);
    // Active lane count derived from block size (combinational)
    logic [5:0] active_lanes;

    always_comb begin
        case (ctrl_i.block_size)
            BLOCK_SIZE_16: active_lanes = 6'(VEC_LANES < 16 ? VEC_LANES : 16);
            BLOCK_SIZE_32: active_lanes = 6'(VEC_LANES < 32 ? VEC_LANES : 32);
            default:       active_lanes = 6'(VEC_LANES);
        endcase
    end

    // [C7 renorm-cone] BALANCED max/min-exp reduction. The prior 16-deep LINEAR
    // scan was ~74% of the deployed RENORM binding cone (m1v reduce_en=0: 4585 ps,
    // vec_renorm_quant ~3387 ps, and max_exp feeds every lane's shift). Rewritten
    // as a per-lane (valid,exp) balanced tree (depth 4). BIT-IDENTICAL: max/min are
    // associative+commutative; an invalid leaf never wins a combine; the
    // !any_normal→0 fixup and the (i<active_lanes)-gated any_nan/inf/overflow ORs
    // are kept verbatim. Value-preserving restructure — shift/quant/escape untouched.
    logic                        rq_v  [VEC_LANES];   // lane valid = active & finite-nonzero
    logic signed [VEC_EXP_W-1:0] rq_mx [VEC_LANES];
    logic signed [VEC_EXP_W-1:0] rq_mn [VEC_LANES];
    always_comb begin
        any_nan_o      = 1'b0;
        any_inf_o      = 1'b0;
        any_overflow_o = 1'b0;
        // leaves + the shallow OR-reduction flags (same (i<active_lanes) gate)
        for (int i = 0; i < VEC_LANES; i++) begin
            rq_v[i]  = 1'b0;
            rq_mx[i] = lane_results_i[i].exp;   // don't-care when !rq_v[i]
            rq_mn[i] = lane_results_i[i].exp;
            if (i < int'(active_lanes)) begin
                any_nan_o      = any_nan_o | lane_results_i[i].is_nan;
                any_inf_o      = any_inf_o | lane_results_i[i].is_inf;
                any_overflow_o = any_overflow_o | lane_results_i[i].overflow;
                rq_v[i]        = !lane_results_i[i].is_nan
                              && !lane_results_i[i].is_inf
                              && !lane_results_i[i].is_zero;
            end
        end

        // balanced pairwise (valid,max,min) combine, halving each level: 16→8→4→2→1
        for (int span = 1; span < VEC_LANES; span = span << 1) begin
            for (int i = 0; i + span < VEC_LANES; i = i + (span << 1)) begin
                if (rq_v[i] && rq_v[i+span]) begin
                    if (rq_mx[i+span] > rq_mx[i]) rq_mx[i] = rq_mx[i+span];
                    if (rq_mn[i+span] < rq_mn[i]) rq_mn[i] = rq_mn[i+span];
                end else if (rq_v[i+span] && !rq_v[i]) begin
                    rq_mx[i] = rq_mx[i+span];
                    rq_mn[i] = rq_mn[i+span];
                end
                // else (rq_v[i] && !rq_v[i+span]): keep node i; (neither): don't-care
                rq_v[i] = rq_v[i] | rq_v[i+span];
            end
        end

        any_normal_o = rq_v[0];
        if (any_normal_o) begin
            max_exp_o = rq_mx[0];
            min_exp_o = rq_mn[0];
        end else begin
            // No normal elements: safe defaults (matches the prior serial fixup)
            max_exp_o = '0;
            min_exp_o = '0;
        end
    end
endmodule


// =============================================================================
// vec_renorm_back — Stages 2-5: escape, re-align, new-scale, pack, assembly
// =============================================================================
module vec_renorm_back
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  vec_lane_result_t  lane_results_i [VEC_LANES],
    input  vec_ctrl_t         ctrl_i,
    input  logic              valid_i,
    input  vec_internal_scale_t orig_scale_i,

    // ── Stage-1 results (from vec_renorm_front, registered by the parent in
    //    the C9-b deployment; combinationally composed in the wrapper) ──
    input  logic signed [VEC_EXP_W-1:0] max_exp_i,
    input  logic signed [VEC_EXP_W-1:0] min_exp_i,
    input  logic                        any_normal_i,
    input  logic                        any_nan_i,
    input  logic                        any_inf_i,
    input  logic                        any_overflow_i,   // reserved (stage-2 "future" hook)

    output vec_renorm_result_t result_o
);
    // Maximum tolerable exponent spread before triggering escape (see wrapper
    // header). VEC_MANT_W = 16: threshold 14 leaves >= 2 significant bits.
    localparam int ESCAPE_THRESHOLD = VEC_MANT_W - 2;  // 14

    // Active lane count — recomputed verbatim from the HELD ctrl_i (identical
    // to the front's value by construction; ctrl is stable across the split).
    logic [5:0] active_lanes;

    always_comb begin
        case (ctrl_i.block_size)
            BLOCK_SIZE_16: active_lanes = 6'(VEC_LANES < 16 ? VEC_LANES : 16);
            BLOCK_SIZE_32: active_lanes = 6'(VEC_LANES < 32 ? VEC_LANES : 32);
            default:       active_lanes = 6'(VEC_LANES);
        endcase
    end

    // =========================================================================
    // Stage 2: Escape Detection
    // =========================================================================
    logic exp_spread_overflow;
    logic escape_needed;

    always_comb begin
        // M37-Vec: compute the spread in a widened 12-bit domain. max_exp/min_exp
        // are 10-bit signed; a legal spread can exceed 511 and wrap a 10-bit
        // subtraction to a negative value → escape (precision-loss spill) would
        // be silently MISSED exactly when it is most needed.
        exp_spread_overflow = any_normal_i &&
            (((VEC_EXP_W+2)'(signed'(max_exp_i)) - (VEC_EXP_W+2)'(signed'(min_exp_i)))
             > (VEC_EXP_W+2)'(ESCAPE_THRESHOLD));

        // CL-9 fix: NaN no longer triggers escape (status flag only, v2.1).
        escape_needed = exp_spread_overflow
                      | ctrl_i.escape_req;
    end

    // =========================================================================
    // Stage 3: Per-Element Re-Alignment to max_exp
    // =========================================================================
    logic signed [VEC_MANT_W-1:0] aligned_mant [VEC_LANES];

    // Inline toward-zero shift (VEC_MANT_W-wide, matching lane mantissa)
    function automatic logic signed [VEC_MANT_W-1:0] mant_tz_shift(
        input logic signed [VEC_MANT_W-1:0] val,
        input logic [5:0]                   amt
    );
        logic signed [VEC_MANT_W-1:0] shifted;
        logic [VEC_MANT_W-1:0]        mask;
        logic                          residue;

        if (amt == 6'd0)
            return val;
        if (amt >= 6'(VEC_MANT_W))
            return '0;

        shifted = val >>> amt;
        mask    = (VEC_MANT_W'(1) << amt) - VEC_MANT_W'(1);
        residue = |(val & $unsigned(mask));
        return shifted + VEC_MANT_W'({{(VEC_MANT_W-1){1'b0}}, (val[VEC_MANT_W-1] & residue)});
    endfunction

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            aligned_mant[i] = '0;

            if (i < int'(active_lanes)) begin
                if (lane_results_i[i].is_nan || lane_results_i[i].is_inf) begin
                    // Special values: mantissa is semantically irrelevant
                    aligned_mant[i] = '0;
                end else if (lane_results_i[i].is_zero) begin
                    aligned_mant[i] = '0;
                end else begin
                    // Normal: shift toward max_exp
                    // M37-Vec: 12-bit widened difference (max_exp-element.exp can
                    // exceed 511 → a 10-bit subtraction wraps negative → the element
                    // is NOT shifted and re-labelled at max_exp, inflating it by 2^N).
                    logic signed [VEC_EXP_W+1:0] shift_amt_signed;
                    logic [5:0] shift_amt;

                    shift_amt_signed = (VEC_EXP_W+2)'(signed'(max_exp_i))
                                     - (VEC_EXP_W+2)'(signed'(lane_results_i[i].exp));

                    // shift_amt should always be >= 0 (max_exp >= element.exp)
                    // Clamp to [0, 63] for safety
                    if (shift_amt_signed <= (VEC_EXP_W+2)'(0))
                        shift_amt = 6'd0;
                    else if (shift_amt_signed > (VEC_EXP_W+2)'(63))
                        shift_amt = 6'd63;
                    else
                        shift_amt = 6'(shift_amt_signed);

                    aligned_mant[i] = mant_tz_shift(lane_results_i[i].mant, shift_amt);
                end
            end
        end
    end

    // =========================================================================
    // Stage 4: New Scale Construction (see wrapper header for the v2.1
    // scale_changed precision note — CL-6)
    // =========================================================================
    vec_internal_scale_t new_scale;
    logic                scale_changed;

    always_comb begin
        new_scale.exp_adj      = max_exp_i;
        new_scale.mant_corr    = 8'd128;  // 1.0: renorm produces pure 2^max_exp
        new_scale.special_nan  = any_nan_i;
        new_scale.special_zero = !any_normal_i && !any_nan_i && !any_inf_i;

        if (!any_normal_i && !any_nan_i && !any_inf_i) begin
            // All-zero block: scale doesn't meaningfully change
            scale_changed = 1'b0;
        end else begin
            scale_changed = (max_exp_i != orig_scale_i.exp_adj)
                         || (new_scale.mant_corr != orig_scale_i.mant_corr);
        end
    end

    // =========================================================================
    // Stage 5: Pack aligned mantissas into flat bit-vector
    //   Element i occupies bits [i*VEC_MANT_W +: VEC_MANT_W]; inactive zero.
    //   block_size=32 multi-pass combination happens in vector_unit.
    // =========================================================================
    logic [VEC_MAX_BLOCK*VEC_MANT_W-1:0] packed_mant;

    always_comb begin
        packed_mant = '0;
        for (int i = 0; i < VEC_LANES; i++) begin
            packed_mant[i*VEC_MANT_W +: VEC_MANT_W] = aligned_mant[i];
        end
    end

    // =========================================================================
    // Output Assembly
    // =========================================================================
    always_comb begin
        result_o.packed_mant   = packed_mant;
        result_o.new_scale     = new_scale;
        result_o.scale_changed = scale_changed;
        result_o.escape_needed = escape_needed;
        result_o.valid         = valid_i && ctrl_i.renorm_en;
    end
endmodule


// =============================================================================
// vec_renorm_quant — front + back composed combinationally, ports UNCHANGED
// (the standalone contract every existing consumer/TB relies on).
// =============================================================================
module vec_renorm_quant
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── Per-Lane Results (from vec_lane_array or reduce bypass) ──
    input  vec_lane_result_t  lane_results_i [VEC_LANES],

    // ── Control ──
    input  vec_ctrl_t         ctrl_i,
    input  logic              valid_i,

    // ── Original scale reference (CL-6: for precise scale_changed detection) ──
    //   Passed from vector_unit's adapted_scale_src0. If the new max_exp
    //   equals the original exp_adj and mant_corr is unchanged, scale_changed
    //   is NOT set — preventing false epoch increments.
    input  vec_internal_scale_t orig_scale_i,

    // ── Output ──
    output vec_renorm_result_t result_o
);
    logic signed [VEC_EXP_W-1:0] w_max_exp, w_min_exp;
    logic w_any_normal, w_any_nan, w_any_inf, w_any_overflow;

    vec_renorm_front u_front (
        .lane_results_i ( lane_results_i ),
        .ctrl_i         ( ctrl_i         ),
        .max_exp_o      ( w_max_exp      ),
        .min_exp_o      ( w_min_exp      ),
        .any_normal_o   ( w_any_normal   ),
        .any_nan_o      ( w_any_nan      ),
        .any_inf_o      ( w_any_inf      ),
        .any_overflow_o ( w_any_overflow )
    );

    vec_renorm_back u_back (
        .lane_results_i ( lane_results_i ),
        .ctrl_i         ( ctrl_i         ),
        .valid_i        ( valid_i        ),
        .orig_scale_i   ( orig_scale_i   ),
        .max_exp_i      ( w_max_exp      ),
        .min_exp_i      ( w_min_exp      ),
        .any_normal_i   ( w_any_normal   ),
        .any_nan_i      ( w_any_nan      ),
        .any_inf_i      ( w_any_inf      ),
        .any_overflow_i ( w_any_overflow ),
        .result_o       ( result_o       )
    );
endmodule

// =============================================================================
// vec_lane_array.sv — VEC_LANES-Wide Parallel Element Processor (Vector Unit, v2)
//
// Pure combinational module. VEC_LANES (16) parallel lanes, each processing one
// element pair (src0, src1) under a shared lane micro-operation.
//
// v2 changes from v1:
//   - VEC_LANES: 8 → 16 (automatic via vec_pkg parameter)
//     All generate loops, port arrays, and shifter instances scale automatically.
//     No logic changes required — the module is fully parameterized.
//   - 16 vec_tz_shifter instances (was 8) for RESADD alignment
//   - LANE_ADD: src0 and src1 may now have INDEPENDENT exponents (dual scale).
//     This was already correctly handled by the exp_diff logic in v1, but the
//     caller (vector_unit.sv) previously assigned the same adapted_scale to both.
//     v2 vector_unit assigns independent scales, making this path fully functional.
//
// Key design choices:
//   - Per-lane vec_tz_shifter instance for RESADD exponent alignment.
//     In block-float mode all lanes within one operand share the same exp,
//     but per-lane shifters maintain generality for future per-element support.
//     Synthesis will share logic when inputs are provably identical.
//
//   - RESADD alignment follows upe_fp_acc_align philosophy:
//     1. Compare exponents → determine shift direction
//     2. Shift smaller-exponent operand via toward-zero shifter
//     3. Add aligned mantissas with carry headroom
//     4. Detect overflow → set flag (renorm deferred to vec_renorm_quant)
//
//   - Special value propagation: NaN > Inf > finite > zero.
//     Checked BEFORE arithmetic to skip unnecessary switching.
//
//   - Not a systolic array — purely parallel, independent lanes.
//     Does not replicate Tensor Array structure or UPE Core MAC pipeline.
//
// Author:  H-Tensor Project
// Version: 2.0 (R4 — 16-lane, dual-scale ready)
// =============================================================================

module vec_lane_array
    import pe_pkg::*;
    import vec_pkg::*;
#(
    // [C5 2026-07-24] 1 = instantiate the per-lane E4M3 correction front
    // (vec_lane_prep) INSIDE the array — the standalone/default contract, kept
    // for the module-level TBs. 0 = the parent already applied the correction
    // and feeds corrected operands in as src*_i (it must then also drive
    // e4m3_precise_i=0, which is what makes the two equivalent); the internal
    // preps collapse to a passthrough so the 32 dead mant_corr multipliers are
    // never emitted. MEASURED: leaving them in cost +3669 µm² (+13.6%) on the
    // m1v_c5 cell because yosys keeps an instantiated module whose outputs are
    // dangling — it does NOT constant-fold across the hierarchy boundary.
    parameter bit PRECISE_INTERNAL = 1'b1,

    // [LANE2 2026-07-26] 1 = the ADD/SUB arm leaf instantiates its alignment
    // front (vec_lane_align) INSIDE — the standalone/default contract, kept for
    // the module-level TBs (bit-identical to pre-LANE2). 0 = the parent runs
    // the SAME align leaf one pipeline stage earlier (PH_LANE), registers its
    // output, and feeds it in via ext_shift_out_i/ext_shift_sticky_i; the
    // internal fronts are then not instantiated (same C5 dangling-instance
    // rationale as PRECISE_INTERNAL above).
    parameter bit ALIGN_INTERNAL = 1'b1
) (
    // ── Element Inputs (VEC_LANES parallel) ──
    input  vec_elem_t        src0_i     [VEC_LANES],    // Primary operand per lane
    input  vec_elem_t        src1_i     [VEC_LANES],    // Secondary operand per lane

    // ── Control ──
    input  vec_lane_op_e     lane_op_i,                 // Micro-op (same for all lanes)
    input  logic             valid_i,                   // Operation valid

    // ── D10: E4M3 precise-mode block-scale mantissa correction (RESADD) ──
    //   Scalar (block-shared) mant_corr per operand, broadcast to all lanes.
    //   Only consumed by LANE_ADD / LANE_SUB when e4m3_precise_i is set; other
    //   lane ops ignore these. mant_corr=128 (1.0) is an exact identity.
    input  logic             e4m3_precise_i,            // gate: apply mant_corr in RESADD
    input  logic [7:0]       mant_corr_s0_i,            // src0 block-scale mantissa corr (128=1.0)
    input  logic [7:0]       mant_corr_s1_i,            // src1 block-scale mantissa corr (128=1.0)
    input  logic             precise_round_rne_i,       // 0=RTZ, 1=RNE for the corr multiply

    // ── [C9 2026-07-25] parent-registered LANE_ADD/SUB alignment controls ──
    //   When ext_shift_ctrl_valid_i=1 the ADD/SUB branch consumes these
    //   REGISTERED per-lane shift controls instead of resolving
    //   exp-compare -> abs_diff -> side in the same cycle as the whole
    //   align+add+guard-fit chain (the C-minimal cut: vector_unit computes
    //   them in PH_MC via vec_pkg::vec_lane_shift_ctrl on the SAME prepped
    //   operands that land in src*_i, so the values are identical by
    //   construction). Tie valid=0 for the standalone (TB) contract — the
    //   in-place fallback below is bit-identical to the pre-C9 inline code.
    input  logic             ext_shift_ctrl_valid_i,
    input  logic [5:0]       ext_abs_diff_i   [VEC_LANES],
    input  logic             ext_shift_src1_i [VEC_LANES],

    // ── [T1b 2026-07-26] parent-registered LANE_SUB negate pre-application ──
    //   When ext_src1_neg_valid_i=1 the ADD/SUB branch consumes this
    //   REGISTERED per-lane op-adjusted 17-bit src1 mantissa instead of
    //   resolving (lane_op==SUB ? -mant : mant) at the head of the
    //   align+add chain (the lane_op decode+broadcast wall: signoff
    //   ctrl->lane_results 2174.98 ps vs data-only -33, §T1b). Parent
    //   computes it in PH_MC from the SAME prepped operand that lands in
    //   src1_i + the held lane_op, so the value is identical by
    //   construction. Tie valid=0 for the standalone (TB) contract — the
    //   in-place fallback below is bit-identical to the pre-T1b inline code.
    input  logic                            ext_src1_neg_valid_i,
    input  logic signed [VEC_MANT_W:0]      ext_eff_src1_mant_i [VEC_LANES],

    // ── [LANE2 2026-07-26] parent-registered ADD/SUB alignment (PH_LANE seam) ──
    //   Consumed by the ADD/SUB arm leaf when ALIGN_INTERNAL=0: the parent
    //   computed shift_out/sticky through the SAME vec_lane_align leaf one
    //   phase earlier (on the SAME held operands + registered shift controls,
    //   so the values are identical by construction) and registered them.
    //   Tie '0 + default ALIGN_INTERNAL=1 for the standalone (TB) contract.
    input  logic signed [VEC_SHIFT_WIDTH-1:0] ext_shift_out_i    [VEC_LANES],
    input  logic                              ext_shift_sticky_i [VEC_LANES],

    // ── Results (VEC_LANES parallel) ──
    output vec_lane_result_t result_o   [VEC_LANES],    // Per-lane result
    output logic             valid_o                    // Results valid
);

    // =========================================================================
    // Generate per-lane processing blocks
    //
    // Each lane independently handles one element pair under the shared op.
    // [LANE2] the per-lane tz_shifter lives in vec_lane_align (inside the
    // ADD/SUB arm leaf when ALIGN_INTERNAL=1, in the parent's PH_LANE stage
    // when 0); it is only consumed by LANE_ADD / LANE_SUB.
    // =========================================================================

    // [SV-2] Scoped UNOPTFLAT waiver (historical scope kept conservative: the
    // shifter feed-through moved into vec_lane_align as pure assigns [LANE2],
    // but the waiver stays scoped to this generate rather than widening any
    // project flag; harmless if now redundant).
    /* verilator lint_off UNOPTFLAT */
    generate
        for (genvar g = 0; g < VEC_LANES; g++) begin : gen_lane

            // -----------------------------------------------------------------
            // [T1d 2026-07-26] LANE_ADD/LANE_SUB arm leaf (alignment shifter
            // now lives INSIDE it — see vec_lane_addsub at the bottom of this
            // file). Kept as a synthesis boundary (SYNTH_KEEP_MODULES) so ABC
            // cannot share logic across mutually-exclusive op arms (the
            // free-lane_op topological false paths, preflight §0) and the op
            // decode no longer gates the shifter DATA port (T1c, subsumed).
            // The leaf is a VERBATIM lift incl. the pre-case defaults, so
            // addsub_result == the old in-line arm's result_o[g] bit-for-bit.
            // -----------------------------------------------------------------
            vec_lane_result_t addsub_result;

            // -----------------------------------------------------------------
            // D10: per-operand E4M3 mant_corr multiply (RESADD precise mode)
            //
            // The factor mant_corr/128 is in [1.0, 1.875]; running the leaf in a
            // 17-bit (VEC_MANT_W+1) product domain means a 16-bit operand can
            // never clamp, so the corrected mantissa is exact-rounded. The prep
            // leaf renorms the (at most one) extra bit into a 16-bit mant + exp
            // bump. overflow_o is dead at this width (kept for the leaf's
            // standalone contract).
            //
            // [C5 2026-07-24] the multiply + renorm17 + sign refresh now live in
            // `vec_lane_prep` (bottom of this file) — lifted VERBATIM, so this
            // instance is bit-identical to the pre-C5 in-line code. The lift lets
            // the PARENT instantiate the same leaf one pipeline stage earlier and
            // feed the already-corrected operands in as src*_i with
            // e4m3_precise_i=0 (then these instances constant-fold away). See
            // vector_unit.sv [C5] MC phase.
            // -----------------------------------------------------------------
            vec_elem_t es0_pre, es1_pre;

            if (PRECISE_INTERNAL) begin : gen_prep
                vec_lane_prep u_mc_s0 (
                    .src_i          ( src0_i[g]           ),
                    .e4m3_precise_i ( e4m3_precise_i      ),
                    .mant_corr_i    ( mant_corr_s0_i      ),
                    .round_rne_i    ( precise_round_rne_i ),
                    .es_o           ( es0_pre             )
                );
                vec_lane_prep u_mc_s1 (
                    .src_i          ( src1_i[g]           ),
                    .e4m3_precise_i ( e4m3_precise_i      ),
                    .mant_corr_i    ( mant_corr_s1_i      ),
                    .round_rne_i    ( precise_round_rne_i ),
                    .es_o           ( es1_pre             )
                );
            end else begin : gen_no_prep
                // Parent-applied correction (it drives e4m3_precise_i=0), so the
                // internal front is the identity — same value, zero hardware.
                assign es0_pre = src0_i[g];
                assign es1_pre = src1_i[g];
            end

            // [T1d] dedicated ADD/SUB arm instance (per-lane); consumes the
            // SAME es*_pre the in-line arm consumed + the RAW src0_i for the
            // passthrough defaults. ext_* per-lane scalars pass straight in.
            // [LANE2] ALIGN_INTERNAL propagated; parent-registered alignment
            // enters per-lane when 0.
            vec_lane_addsub #(
                .ALIGN_INTERNAL ( ALIGN_INTERNAL )
            ) u_addsub (
                .src0_i                 ( src0_i[g]              ),
                .es0_i                  ( es0_pre                ),
                .es1_i                  ( es1_pre                ),
                .lane_op_i              ( lane_op_i              ),
                .ext_shift_ctrl_valid_i ( ext_shift_ctrl_valid_i ),
                .ext_abs_diff_i         ( ext_abs_diff_i[g]      ),
                .ext_shift_src1_i       ( ext_shift_src1_i[g]    ),
                .ext_src1_neg_valid_i   ( ext_src1_neg_valid_i   ),
                .ext_eff_src1_mant_i    ( ext_eff_src1_mant_i[g] ),
                .ext_shift_out_i        ( ext_shift_out_i[g]     ),
                .ext_shift_sticky_i     ( ext_shift_sticky_i[g]  ),
                .result_o               ( addsub_result          )
            );

            // -----------------------------------------------------------------
            // Per-lane combinational logic
            // -----------------------------------------------------------------
            always_comb begin
                // ── Default: passthrough src0, no flags ──
                result_o[g].mant      = src0_i[g].mant;
                result_o[g].exp       = src0_i[g].exp;
                result_o[g].sign      = src0_i[g].sign;
                result_o[g].is_zero   = src0_i[g].is_zero;
                result_o[g].is_nan    = src0_i[g].is_nan;
                result_o[g].is_inf    = src0_i[g].is_inf;
                result_o[g].overflow  = 1'b0;
                result_o[g].underflow = 1'b0;

                // ([T1d] the shifter idle default moved into vec_lane_addsub
                //  with the shifter itself — no op-decode gate remains here.)

                case (lane_op_i)

                    // ─────────────────────────────────────────────────────
                    // LANE_NOP / LANE_PASS: passthrough src0
                    // ─────────────────────────────────────────────────────
                    LANE_NOP, LANE_PASS: begin
                        // Defaults already set above
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_ABS: absolute value of src0
                    //   Negate mantissa if negative, clear sign bit.
                    //   Special values pass through unchanged.
                    // ─────────────────────────────────────────────────────
                    LANE_ABS: begin
                        // 17-bit negate so |−2^15| = +2^15 does not wrap to itself;
                        // only that single value overflows the 16-bit field → renorm
                        // (>>1, exp+1), lossless and sign/mant-consistent
                        // (HW-REVIEW T2; same NUM-1 pattern as LANE_SUB).
                        logic signed [VEC_MANT_W:0] abs17;
                        if (!src0_i[g].is_nan && !src0_i[g].is_inf && !src0_i[g].is_zero) begin
                            abs17 = src0_i[g].mant[VEC_MANT_W-1]
                                  ? -((VEC_MANT_W+1)'(signed'(src0_i[g].mant)))
                                  : (VEC_MANT_W+1)'(signed'(src0_i[g].mant));
                            if (abs17[VEC_MANT_W] != abs17[VEC_MANT_W-1]) begin
                                result_o[g].mant = VEC_MANT_W'(abs17 >>> 1);
                                result_o[g].exp  = src0_i[g].exp + VEC_EXP_W'(1);
                            end else begin
                                result_o[g].mant = abs17[VEC_MANT_W-1:0];
                            end
                            result_o[g].sign = 1'b0;
                        end
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_MAX: element-wise max(src0, src1)
                    //   Comparison on (exp, |mant|) tuples.
                    //   NaN > Inf > finite. Zero is smallest finite.
                    // ─────────────────────────────────────────────────────
                    LANE_MAX: begin
                        // NaN propagation: if either is NaN, result is NaN
                        if (src0_i[g].is_nan || src1_i[g].is_nan) begin
                            result_o[g].is_nan = 1'b1;
                            result_o[g].mant   = '0;
                            result_o[g].exp    = '0;
                        end
                        // Inf handling: Inf > finite
                        else if (src0_i[g].is_inf && !src1_i[g].is_inf) begin
                            result_o[g] = lane_result_from_elem(src0_i[g]);
                        end
                        else if (src1_i[g].is_inf && !src0_i[g].is_inf) begin
                            result_o[g] = lane_result_from_elem(src1_i[g]);
                        end
                        // Both Inf: pick src0 (arbitrary for same-magnitude)
                        else if (src0_i[g].is_inf && src1_i[g].is_inf) begin
                            result_o[g] = lane_result_from_elem(src0_i[g]);
                        end
                        // Both zero: pick src0
                        else if (src0_i[g].is_zero && src1_i[g].is_zero) begin
                            result_o[g] = lane_result_from_elem(src0_i[g]);
                        end
                        // One zero: pick the non-zero (if positive) or zero (if negative)
                        else if (src0_i[g].is_zero) begin
                            // max(0, x) = x if x > 0, else 0
                            if (!src1_i[g].sign)
                                result_o[g] = lane_result_from_elem(src1_i[g]);
                            else
                                result_o[g] = lane_result_from_elem(src0_i[g]);
                        end
                        else if (src1_i[g].is_zero) begin
                            if (!src0_i[g].sign)
                                result_o[g] = lane_result_from_elem(src0_i[g]);
                            else
                                result_o[g] = lane_result_from_elem(src1_i[g]);
                        end
                        // Value-aware comparison (HW-REVIEW T2). value = signed
                        // mant * 2^exp. The old exp-first compare was sign-blind
                        // (a high-exp NEGATIVE beat a low-exp POSITIVE) and also
                        // wrong same-sign for un-normalized block-float. Align the
                        // lower-exp operand to the higher exponent (arithmetic
                        // right shift; magnitude only matters for the compare),
                        // then compare as a signed value. The SELECTED result is
                        // the ORIGINAL element — no precision loss. ediff is
                        // widened to avoid a 10-bit wrap (M37-Vec discipline).
                        else begin
                            logic signed [VEC_EXP_W+1:0]  mx_ediff;
                            logic [5:0]                   mx_amt;
                            logic signed [VEC_MANT_W-1:0] mx_a0, mx_a1;
                            logic                         src0_greater;
                            mx_ediff = (VEC_EXP_W+2)'(signed'(src0_i[g].exp))
                                     - (VEC_EXP_W+2)'(signed'(src1_i[g].exp));
                            if (mx_ediff >= (VEC_EXP_W+2)'(0)) begin
                                mx_amt = (mx_ediff > (VEC_EXP_W+2)'(VEC_MANT_W))
                                       ? 6'(VEC_MANT_W) : 6'(mx_ediff);
                                mx_a0  = src0_i[g].mant;
                                mx_a1  = src1_i[g].mant >>> mx_amt;
                            end else begin
                                mx_amt = (-mx_ediff > (VEC_EXP_W+2)'(VEC_MANT_W))
                                       ? 6'(VEC_MANT_W) : 6'(-mx_ediff);
                                mx_a0  = src0_i[g].mant >>> mx_amt;
                                mx_a1  = src1_i[g].mant;
                            end
                            src0_greater = (mx_a0 >= mx_a1);
                            result_o[g] = src0_greater
                                        ? lane_result_from_elem(src0_i[g])
                                        : lane_result_from_elem(src1_i[g]);
                        end
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_ADD / LANE_SUB: block-float aligned addition —
                    // [T1d 2026-07-26] the WHOLE arm (special-value handling
                    // + Steps 1-8 + the per-lane tz_shifter) now lives in the
                    // dedicated leaf vec_lane_addsub (bottom of this file),
                    // instantiated per-lane above as u_addsub. VERBATIM lift
                    // incl. the pre-case passthrough defaults => bit-identical.
                    // Kept synthesis boundary: no cross-arm ABC sharing, no
                    // op-decode gate on the shifter data port (preflight §1.3).
                    // ─────────────────────────────────────────────────────
                    LANE_ADD, LANE_SUB: begin
                        result_o[g] = addsub_result;
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_SPLIT: pass src0, set lane index in exp field
                    //   Used for block split — each lane outputs its
                    //   element with metadata indicating position.
                    // ─────────────────────────────────────────────────────
                    LANE_SPLIT: begin
                        result_o[g] = lane_result_from_elem(src0_i[g]);
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_MERGE_LO / LANE_MERGE_HI: block merge select
                    //   LO: take from src0 (lower block elements)
                    //   HI: take from src1 (upper block elements)
                    // ─────────────────────────────────────────────────────
                    LANE_MERGE_LO: begin
                        result_o[g] = lane_result_from_elem(src0_i[g]);
                    end
                    LANE_MERGE_HI: begin
                        result_o[g] = lane_result_from_elem(src1_i[g]);
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_SIGN_INJ: inject sign from src1 into src0
                    // ─────────────────────────────────────────────────────
                    LANE_SIGN_INJ: begin
                        // 17-bit negate so -(-2^15) = +2^15 does not wrap → renorm
                        // (>>1, exp+1) keeps sign/mant consistent (HW-REVIEW T2).
                        logic signed [VEC_MANT_W:0] neg17;
                        result_o[g] = lane_result_from_elem(src0_i[g]);
                        result_o[g].sign = src1_i[g].sign;
                        // Negate mantissa to match the injected sign if different.
                        if (src0_i[g].sign != src1_i[g].sign) begin
                            neg17 = -((VEC_MANT_W+1)'(signed'(src0_i[g].mant)));
                            if (neg17[VEC_MANT_W] != neg17[VEC_MANT_W-1]) begin
                                result_o[g].mant = VEC_MANT_W'(neg17 >>> 1);
                                result_o[g].exp  = src0_i[g].exp + VEC_EXP_W'(1);
                            end else begin
                                result_o[g].mant = neg17[VEC_MANT_W-1:0];
                            end
                        end
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_CLAMP: clamp src0 mantissa to ±max representable
                    //   Uses src1.mant as the clamp threshold (absolute).
                    //   If |src0| > |src1|, output = sign(src0) × |src1|.
                    // ─────────────────────────────────────────────────────
                    LANE_CLAMP: begin
                        if (src0_i[g].is_nan || src0_i[g].is_inf) begin
                            result_o[g] = lane_result_from_elem(src0_i[g]);
                        end else begin
                            logic [VEC_MANT_W-1:0] abs0, abs_thresh;
                            abs0 = src0_i[g].mant[VEC_MANT_W-1]
                                 ? VEC_MANT_W'(-src0_i[g].mant)
                                 : VEC_MANT_W'(src0_i[g].mant);
                            abs_thresh = src1_i[g].mant[VEC_MANT_W-1]
                                       ? VEC_MANT_W'(-src1_i[g].mant)
                                       : VEC_MANT_W'(src1_i[g].mant);

                            if (abs0 > abs_thresh) begin
                                // Clamped: output = sign(src0) × threshold
                                result_o[g].mant = src0_i[g].sign
                                                 ? (-VEC_MANT_W'(abs_thresh))
                                                 : VEC_MANT_W'(abs_thresh);
                                result_o[g].exp  = src0_i[g].exp;
                                result_o[g].sign = src0_i[g].sign;
                                result_o[g].overflow = 1'b1;
                            end else begin
                                result_o[g] = lane_result_from_elem(src0_i[g]);
                            end
                        end
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_REDUCE_P: prepare element for reduction
                    //   Passthrough with explicit is_zero / flag cleanup.
                    //   The reduce cluster consumes lane results directly.
                    // ─────────────────────────────────────────────────────
                    LANE_REDUCE_P: begin
                        result_o[g] = lane_result_from_elem(src0_i[g]);
                    end

                    // ─────────────────────────────────────────────────────
                    // LANE_MULADD: reserved for future bias/scale ops
                    // ─────────────────────────────────────────────────────
                    LANE_MULADD: begin
                        // TODO(v2): implement small mul-add for bias/scale
                        result_o[g] = lane_result_from_elem(src0_i[g]);
                    end

                    default: begin
                        result_o[g] = lane_result_from_elem(src0_i[g]);
                    end

                endcase
            end // always_comb

        end // gen_lane
    endgenerate
    /* verilator lint_on UNOPTFLAT */

    // =========================================================================
    // Output valid — pure combinational (no pipeline latency in v2)
    // =========================================================================
    assign valid_o = valid_i;

    // =========================================================================
    // Helper: convert vec_elem_t to vec_lane_result_t (zero flags, no error)
    // =========================================================================
    function automatic vec_lane_result_t lane_result_from_elem(input vec_elem_t e);
        vec_lane_result_t r;
        r.mant      = e.mant;
        r.exp       = e.exp;
        r.sign      = e.sign;
        r.is_zero   = e.is_zero;
        r.is_nan    = e.is_nan;
        r.is_inf    = e.is_inf;
        r.overflow  = 1'b0;
        r.underflow = 1'b0;
        return r;
    endfunction

endmodule


// =============================================================================
// vec_lane_prep — [C5 2026-07-24] per-operand E4M3 precise-mode correction FRONT
//
// = the D10 mant_corr multiply + renorm17 + sign refresh, lifted VERBATIM out of
// vec_lane_array's LANE_ADD/LANE_SUB branch. Pure combinational, zero behaviour
// change: `es_o` is bit-for-bit the old `es0`/`es1`, including the
// e4m3_precise_i=0 passthrough (es_o == src_i).
//
// WHY it is its own module: the parent (vector_unit) needs to run this SAME leaf
// one pipeline stage earlier than the lane add chain — the mant_corr multiply
// (~517 ps) + the 16-way operand select in front of it (~509 ps) sat in series
// with the whole align+add+guard-fit chain (~1764 ps) in ONE clock, which was the
// deployed binding path (2805 ps, `lane_results_q`). vector_unit instantiates this
// leaf, registers its output, and feeds the corrected operands to vec_lane_array
// as src*_i with e4m3_precise_i=0 — so the instances inside vec_lane_array
// constant-fold away there while the module keeps its standalone contract (and
// its standalone TBs) intact.
//
// Single source of truth: BOTH users instantiate this module, so the corrected
// operand can never diverge between the in-array path and the parent's path.
// =============================================================================
module vec_lane_prep
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  vec_elem_t  src_i,
    input  logic       e4m3_precise_i,   // gate: apply mant_corr (RESADD precise)
    input  logic [7:0] mant_corr_i,      // block-scale mantissa corr (128 = 1.0)
    input  logic       round_rne_i,      // 0=RTZ, 1=RNE for the corr multiply
    output vec_elem_t  es_o              // effective (corrected) operand
);
    localparam int MC_W = VEC_MANT_W + 1;              // 17-bit corrected domain

    logic signed [MC_W-1:0] mc_in, mc_out;
    logic                   mc_ovf;                    // tied dead at 17-bit

    assign mc_in = MC_W'(signed'(src_i.mant));

    vec_mant_corr_mul #(.MANT_W(MC_W)) u_mc (
        .mant_i      ( mc_in       ),
        .mant_corr_i ( mant_corr_i ),
        .round_rne_i ( round_rne_i ),
        .mant_o      ( mc_out      ),
        .overflow_o  ( mc_ovf      )
    );

    always_comb begin
        es_o = src_i;
        if (e4m3_precise_i) begin
            // renorm17(mc_out, exp)
            if (mc_out[MC_W-1] != mc_out[MC_W-2]) begin
                es_o.mant = VEC_MANT_W'((mc_out >>> 1)
                          + MC_W'((mc_out[MC_W-1] & mc_out[0]) ? 1 : 0));
                es_o.exp  = src_i.exp + VEC_EXP_W'(1);
            end else begin
                es_o.mant = mc_out[VEC_MANT_W-1:0];
            end
            // sign tracks the corrected mantissa for normal operands only;
            // preserve the original sign for Inf/NaN (their mantissa is 0 /
            // meaningless) so the Inf direction used by the special branches
            // survives. (NUM-2/SV-1)
            if (!es_o.is_inf && !es_o.is_nan && !es_o.is_zero)
                es_o.sign = es_o.mant[VEC_MANT_W-1];
        end
    end
endmodule


// =============================================================================
// vec_lane_addsub — [T1d 2026-07-26] LANE_ADD/LANE_SUB arm, lifted VERBATIM
//
// = the whole LANE_ADD/LANE_SUB case arm of vec_lane_array (special-value
// handling + normal aligned addition, Steps 1-8), moved into a dedicated
// combinational leaf. Pure lift, zero behaviour change: result_o is
// bit-for-bit the arm's old result_o[g], INCLUDING the pre-case passthrough
// defaults (copied verbatim below — the arm's special branches deliberately
// let some fields fall through to them, so the leaf replicates them from the
// same RAW src0_i).
//
// [LANE2 2026-07-26] the alignment FRONT (Steps 1+3 + the per-lane
// tz_shifter) moved on into its own leaf `vec_lane_align` (bottom of this
// file). In the standalone (TB) contract (ALIGN_INTERNAL=1, default) it is
// instantiated right here, so this module's contract is unchanged; in the
// deployed config (ALIGN_INTERNAL=0) the parent runs the SAME leaf one
// pipeline phase earlier (PH_LANE) and this arm consumes the REGISTERED
// seam (ext_shift_out_i/ext_shift_sticky_i) — the align|arith phase split.
//
// WHY it is its own module (T1c_Preflight_LaneUngate_MC2Split §1.3): under
// the deployed free-lane_op STA criterion, ABC's cross-arm logic sharing in
// the flattened array wove topological paths through mutually-exclusive op
// arms (signoff -75.78 on src1_lane_q -> lane_results_q while EVERY reachable
// pinned op is MET, worst ADD +72.38 — arcprobe4 10/10). A kept synthesis
// boundary (SYNTH_HIERARCHICAL keep + SYNTH_KEEP_MODULES) makes such weaves
// impossible by construction. The lift also retires the op-decode gate that
// rode the shifter DATA port (the -91.43 ctrl_q[41] -> NAND2 682ps wall):
// inside a dedicated arm there is no case, so shift_in/shift_amt are driven
// by data with no lane_op term (the T1c ungate, subsumed). Power note: the
// shifter still idles to '0 on special-value operands, but no longer on
// non-ADD/SUB ops — disclosed, RESADD-dominant deployment.
// =============================================================================
module vec_lane_addsub
    import pe_pkg::*;
    import vec_pkg::*;
#(
    // [LANE2 2026-07-26] 1 = standalone (TB) contract: the alignment front
    // (vec_lane_align — Steps 1+3 + the tz_shifter, bottom of this file) is
    // instantiated INSIDE, bit-identical to the pre-LANE2 leaf. 0 = the parent
    // ran the SAME front one pipeline phase earlier (PH_LANE) and feeds the
    // REGISTERED shift_out/sticky in via ext_shift_out_i/ext_shift_sticky_i;
    // the internal front is then not instantiated (C5 dangling-instance
    // lesson: yosys does NOT constant-fold across a hierarchy boundary).
    parameter bit ALIGN_INTERNAL = 1'b1
)(
    input  vec_elem_t                  src0_i,   // RAW operand 0 (defaults source)
    input  vec_elem_t                  es0_i,    // corrected operand 0 (= es0_pre)
    input  vec_elem_t                  es1_i,    // corrected operand 1 (= es1_pre)
    input  vec_lane_op_e               lane_op_i,             // ADD vs SUB semantics
    input  logic                       ext_shift_ctrl_valid_i,
    input  logic [5:0]                 ext_abs_diff_i,
    input  logic                       ext_shift_src1_i,
    input  logic                       ext_src1_neg_valid_i,
    input  logic signed [VEC_MANT_W:0] ext_eff_src1_mant_i,
    // [LANE2] parent-registered alignment (consumed when ALIGN_INTERNAL=0)
    input  logic signed [VEC_SHIFT_WIDTH-1:0] ext_shift_out_i,
    input  logic                       ext_shift_sticky_i,
    output vec_lane_result_t           result_o
);

    // -------------------------------------------------------------------------
    // [LANE2] Step-2 ctrl resolve + the T1b negate, HOISTED from the arm body
    // to module scope so they can feed the alignment leaf as well as the arm.
    // Value-EQUIVALENT replacement (not same-text, preflight §7-2b VERBATIM
    // exemption): the old arm assigned `es0 = es0_i; es1 = es1_i;` once and
    // never re-wrote them, so es*_i substitute exactly in both expressions.
    // (The old UNOPTFLAT waiver here is RETIRED: the arm's always_comb no
    // longer drives any shifter input — the feed-through is gone. SV-2.)
    // -------------------------------------------------------------------------
    logic signed [VEC_MANT_W:0] eff_src1_mant;
    assign eff_src1_mant = ext_src1_neg_valid_i
                         ? ext_eff_src1_mant_i
                         : ((lane_op_i == LANE_SUB)
                             ? -((VEC_MANT_W+1)'(signed'(es1_i.mant)))
                             : (VEC_MANT_W+1)'(signed'(es1_i.mant)));

    // Step 2: shift controls (exponent compare). [C9] parent-registered when
    // ext_shift_ctrl_valid_i=1; otherwise computed in place through the SAME
    // shared leaf vec_pkg::vec_lane_shift_ctrl (widened +2 domain, clamp 63,
    // side = diff>0) — bit-identical to the pre-LANE2 in-arm resolve.
    logic       shift_src1_side_w;
    logic [5:0] abs_diff_w;
    assign {shift_src1_side_w, abs_diff_w}
        = ext_shift_ctrl_valid_i
            ? {ext_shift_src1_i, ext_abs_diff_i}
            : vec_lane_shift_ctrl(es0_i, es1_i);

    // [LANE2] alignment source: internal front (standalone) vs parent seam
    // registers (deployed). Single source of truth — the internal instance is
    // the SAME vec_lane_align leaf the parent runs in PH_LANE.
    logic signed [VEC_SHIFT_WIDTH-1:0] shift_out_eff;
    logic                              shift_sticky_eff;

    generate
        if (ALIGN_INTERNAL) begin : gen_align
            vec_lane_align u_align (
                .es0_mant_i      ( es0_i.mant        ),
                .eff_src1_mant_i ( eff_src1_mant     ),
                .shift_src1_i    ( shift_src1_side_w ),
                .abs_diff_i      ( abs_diff_w        ),
                .shift_out_o     ( shift_out_eff     ),
                .sticky_o        ( shift_sticky_eff  )
            );
        end else begin : gen_ext_align
            assign shift_out_eff    = ext_shift_out_i;
            assign shift_sticky_eff = ext_shift_sticky_i;
        end
    endgenerate

    always_comb begin : addsub_arm
        // [N16] declarations precede statements (verbatim from the case arm)
        // ([LANE2] eff_src1_mant is now a module-scope assign above — it feeds
        //  the alignment leaf as well as this body.)
        vec_elem_t es0, es1;

        // ── Defaults: VERBATIM copy of the array's pre-case passthrough ──
        // (the special branches below rely on fall-through of sign/is_zero/
        //  is_nan/is_inf from the RAW src0_i, exactly as in the array)
        result_o.mant      = src0_i.mant;
        result_o.exp       = src0_i.exp;
        result_o.sign      = src0_i.sign;
        result_o.is_zero   = src0_i.is_zero;
        result_o.is_nan    = src0_i.is_nan;
        result_o.is_inf    = src0_i.is_inf;
        result_o.overflow  = 1'b0;
        result_o.underflow = 1'b0;

        // ([LANE2] the shifter idle default left with the shifter into
        //  vec_lane_align — the front now always computes; shift_out/sticky
        //  are only READ in the normal branch below, so results are bit-
        //  identical and the delta is special-operand switching power,
        //  disclosed in the preflight.)

        // ── LANE_ADD / LANE_SUB arm body: VERBATIM from vec_lane_array ──
        es0 = es0_i;
        es1 = es1_i;

        // --- Special value handling ---
        if (es0.is_nan || es1.is_nan) begin
            // NaN + anything = NaN
            result_o.is_nan = 1'b1;
            result_o.mant   = '0;
            result_o.exp    = '0;
        end
        else if (es0.is_inf && es1.is_inf) begin
            // Inf + Inf: same sign → Inf, opposite → NaN
            logic same_sign;
            if (lane_op_i == LANE_SUB)
                same_sign = (es0.sign != es1.sign);
            else
                same_sign = (es0.sign == es1.sign);
            if (same_sign) begin
                result_o.is_inf = 1'b1;
                result_o.sign   = es0.sign;
            end else begin
                result_o.is_nan = 1'b1;
            end
            result_o.mant = '0;
            result_o.exp  = '0;
        end
        else if (es0.is_inf) begin
            result_o = addsub_result_from_elem(es0);
        end
        else if (es1.is_inf) begin
            result_o.is_inf = 1'b1;
            result_o.sign   = (lane_op_i == LANE_SUB)
                               ? (~es1.sign) : es1.sign;
            result_o.mant   = '0;
            result_o.exp    = '0;
        end
        else if (es0.is_zero && es1.is_zero) begin
            result_o = addsub_result_from_elem(es0);
            result_o.is_zero = 1'b1;
        end
        else if (es0.is_zero) begin
            // 0 + x = x (or 0 - x = -x). eff_src1_mant is 17-bit;
            // only +2^(W-1) (from negating -2^(W-1)) exceeds the
            // 16-bit result field, so renorm it (>>1, exp+1).
            if (eff_src1_mant[VEC_MANT_W] != eff_src1_mant[VEC_MANT_W-1]) begin
                result_o.mant = VEC_MANT_W'(eff_src1_mant >>> 1);
                result_o.exp  = es1.exp + VEC_EXP_W'(1);
            end else begin
                result_o.mant = eff_src1_mant[VEC_MANT_W-1:0];
                result_o.exp  = es1.exp;
            end
            result_o.sign    = result_o.mant[VEC_MANT_W-1];
            result_o.is_zero = 1'b0;
        end
        else if (es1.is_zero) begin
            // x + 0 = x
            result_o = addsub_result_from_elem(es0);
        end
        else begin
            // --- Normal aligned addition ---
            // [N16] All block-local declarations are hoisted to the
            // top of this begin..end (strict-SV: declarations must
            // precede statements). Logic/ordering unchanged.
            logic signed [VEC_SHIFT_WIDTH-1:0] ext0, ext1_eff;
            // [HW-REVIEW T3 widening + clamp63 + side compare live in
            //  vec_pkg::vec_lane_shift_ctrl — resolved at module scope
            //  as shift_src1_side_w/abs_diff_w ([LANE2] hoist).]
            logic signed [VEC_SHIFT_WIDTH-1:0] aligned_a, aligned_b;
            logic signed [VEC_SHIFT_WIDTH:0]   sum_wide;
            logic signed [VEC_EXP_W-1:0]       res_exp;
            logic                              ovf;
            logic signed [VEC_SHIFT_WIDTH-1:0] sum_norm;
            logic signed [VEC_EXP_W-1:0]       exp_norm;
            logic [3:0]                        guard_xor;
            logic [2:0]                        extra_shift;
            logic signed [VEC_SHIFT_WIDTH-1:0] final_val;
            logic signed [VEC_EXP_W-1:0]       final_exp;

            // Step 1: Sign-extend to shift width
            ext0     = VEC_SHIFT_WIDTH'(signed'(es0.mant));
            ext1_eff = VEC_SHIFT_WIDTH'(signed'(eff_src1_mant));

            // (Steps 2+3 [LANE2]: the ctrl resolve is the module-scope
            //  shift_src1_side_w/abs_diff_w assign; the route + tz_shifter
            //  live in vec_lane_align — internal instance when
            //  ALIGN_INTERNAL=1, parent PH_LANE seam registers when 0.)

            // Step 4: Assemble aligned operands
            if (shift_src1_side_w) begin
                aligned_a = ext0;
                aligned_b = shift_out_eff;
                // Inject sticky into LSB of shifted operand
                aligned_b[0] = aligned_b[0] | shift_sticky_eff;
            end else begin
                aligned_a = shift_out_eff;
                aligned_a[0] = aligned_a[0] | shift_sticky_eff;
                aligned_b = ext1_eff;
            end

            // Step 5: Addition with 1-bit carry headroom
            sum_wide = (VEC_SHIFT_WIDTH+1)'(aligned_a)
                     + (VEC_SHIFT_WIDTH+1)'(aligned_b);

            // Step 6: Result exponent (adopt larger)
            res_exp = shift_src1_side_w ? es0.exp : es1.exp;

            // Step 7: Overflow detection and single-step renorm
            //   If magnitude needs more than VEC_SHIFT_WIDTH-1 bits,
            //   right-shift by 1 and increment exponent.
            ovf = (sum_wide[VEC_SHIFT_WIDTH] != sum_wide[VEC_SHIFT_WIDTH-1]);

            if (ovf) begin
                // Arithmetic right shift by 1 (toward-zero for
                // consistency, but single-bit shift on sum is exact
                // when the overflow is only 1 bit)
                sum_norm = VEC_SHIFT_WIDTH'(sum_wide[VEC_SHIFT_WIDTH:1]);
                exp_norm = res_exp + VEC_EXP_W'(1);
            end else begin
                sum_norm = sum_wide[VEC_SHIFT_WIDTH-1:0];
                exp_norm = res_exp;
            end

            // Step 8: Normalize to VEC_MANT_W (CL-1 fix)
            //
            // After step 7, sum_norm is VEC_SHIFT_WIDTH (20) bits.
            // Truncating directly to VEC_MANT_W (16) bits can
            // corrupt the sign if guard bits [18:15] contain
            // non-sign-extension data.
            //
            // Fix: detect non-sign-extension guard bits, apply
            // additional right-shift with toward-zero correction
            // and exponent compensation.

            // XOR guard bits with sign to find non-extension bits
            guard_xor = sum_norm[VEC_SHIFT_WIDTH-2:VEC_MANT_W-1]
                      ^ {4{sum_norm[VEC_SHIFT_WIDTH-1]}};

            // Priority encoder: highest set bit → shift amount
            if (guard_xor[3])      extra_shift = 3'd4;
            else if (guard_xor[2]) extra_shift = 3'd3;
            else if (guard_xor[1]) extra_shift = 3'd2;
            else if (guard_xor[0]) extra_shift = 3'd1;
            else                   extra_shift = 3'd0;

            if (extra_shift == 3'd0) begin
                // Guard bits are pure sign extension — safe truncation
                final_val = sum_norm;
                final_exp = exp_norm;
            end else begin
                // Additional right-shift needed to fit in VEC_MANT_W
                final_val = sum_norm >>> extra_shift;

                // Toward-zero correction for negative values
                //   (same formula as vec_tz_shifter)
                if (sum_norm[VEC_SHIFT_WIDTH-1]) begin
                    logic [VEC_SHIFT_WIDTH-1:0] tz_mask;
                    tz_mask = (VEC_SHIFT_WIDTH'(1) << extra_shift)
                            - VEC_SHIFT_WIDTH'(1);
                    if (|(sum_norm & $unsigned(tz_mask)))
                        final_val = final_val + VEC_SHIFT_WIDTH'(1);
                end

                final_exp = exp_norm + VEC_EXP_W'({7'd0, extra_shift});
            end

            result_o.mant     = final_val[VEC_MANT_W-1:0];
            result_o.exp      = final_exp;
            result_o.sign     = final_val[VEC_SHIFT_WIDTH-1];
            result_o.is_zero  = (final_val[VEC_MANT_W-1:0] == '0);
            result_o.is_nan   = 1'b0;
            result_o.is_inf   = 1'b0;
            result_o.overflow = ovf || (extra_shift != 3'd0);
            result_o.underflow= 1'b0;
        end
    end // always_comb

    // Helper: VERBATIM copy of vec_lane_array.lane_result_from_elem — the
    // leaf must be self-contained (kept synthesis boundary); keep in sync.
    function automatic vec_lane_result_t addsub_result_from_elem(input vec_elem_t e);
        vec_lane_result_t r;
        r.mant      = e.mant;
        r.exp       = e.exp;
        r.sign      = e.sign;
        r.is_zero   = e.is_zero;
        r.is_nan    = e.is_nan;
        r.is_inf    = e.is_inf;
        r.overflow  = 1'b0;
        r.underflow = 1'b0;
        return r;
    endfunction

endmodule


// =============================================================================
// vec_lane_align — [LANE2 2026-07-26] LANE_ADD/SUB alignment FRONT, lifted
// VERBATIM out of vec_lane_addsub (Steps 1+3 + the per-lane vec_tz_shifter).
//
// Pure combinational, zero value change: shift_out_o/sticky_o are bit-for-bit
// the old in-arm shift_out/shift_sticky for every input on which they are
// consumed (the arm's special-value branches never read the shifter — the old
// idle default only affected unread values; the delta is special-operand
// switching power, disclosed in LANE2_Preflight §1.1).
//
// WHY it is its own module (LANE2_Preflight_AlignArithSplit §1): the single
// remaining signoff wall was the ONE-cycle align+add+guard-fit chain
// (~1489 ps) with the opt_merge-folded lane-shared-flag broadcast head
// (~224 ps) riding it (m1v_t1c 1766.20 ps, -96.20). vector_unit runs this
// leaf in PH_LANE on the REGISTERED operands + shift controls, registers
// shift_out/sticky (the 21b/lane seam), and the arm's arithmetic BACK half
// (Steps 4-8 + special branches) runs in the new PH_LANE2 from the seam +
// the same held registers — each half gets a full clock. C5 vec_lane_prep
// same single-source-of-truth pattern: BOTH users instantiate this module.
// =============================================================================
module vec_lane_align
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic signed [VEC_MANT_W-1:0] es0_mant_i,      // = es0.mant (corrected op0)
    input  logic signed [VEC_MANT_W:0]   eff_src1_mant_i, // 17b op-adjusted src1 ([T1b])
    input  logic                         shift_src1_i,    // side ([C9] registered ctrl)
    input  logic [5:0]                   abs_diff_i,      // amount ([C9] registered ctrl)
    output logic signed [VEC_SHIFT_WIDTH-1:0] shift_out_o,
    output logic                         sticky_o
);
    // Step 1: Sign-extend to shift width (VERBATIM from the arm)
    logic signed [VEC_SHIFT_WIDTH-1:0] ext0, ext1_eff;
    assign ext0     = VEC_SHIFT_WIDTH'(signed'(es0_mant_i));
    assign ext1_eff = VEC_SHIFT_WIDTH'(signed'(eff_src1_mant_i));

    // Step 3: Route smaller-exponent operand to shifter (VERBATIM)
    logic signed [VEC_SHIFT_WIDTH-1:0] shift_in;
    assign shift_in = shift_src1_i ? ext1_eff : ext0;

    // Pure feed-through (assign -> instance): no UNOPTFLAT waiver needed here
    // (the old SV-2 waiver covered the same-always_comb drive/read pattern,
    // which this lift dissolves).
    vec_tz_shifter #(
        .WIDTH     (VEC_SHIFT_WIDTH),
        .SHIFT_MAX (VEC_SHIFT_MAX)
    ) u_align_shift (
        .val_in    (shift_in),
        .shift_amt (abs_diff_i),
        .val_out   (shift_out_o),
        .sticky    (sticky_o),
        .clamped   ()   // dead pre-LANE2 too: old shift_clamped had zero consumers
    );
endmodule

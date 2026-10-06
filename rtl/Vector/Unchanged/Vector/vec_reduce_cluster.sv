// =============================================================================
// vec_reduce_cluster.sv — Cross-Lane Reduction Tree (Vector Unit, v3)
//
// Pure combinational module that reduces VEC_LANES (16) lane results into a
// single scalar result.
//
// v3 (S-STAT v1.2, prereg soc600_prereg_20260902.md §70 + §74.1; 待-2 / #285
// ⑬⑭): the REDUCE_STAT (sum-of-squares) datapath is replaced. MAX / SUM are
// byte-for-byte unchanged.
//   - Old STAT: per-pair aligned 40-bit tree with 2*exp clamped to 10 bits,
//     zero lanes injected as (0, exp 0), then a FIXED >>>19 + exp+19 (10-bit
//     wrap) truncation — zero was not an additive identity, 2e was clamped,
//     the exponent wrapped, no rounding / overflow / underflow was defined.
//   - New STAT (scheme C, MSB-anchored 40-bit window): lane key
//     g_i = e_i + floor(log2|m_i|); G = max g over contributing lanes;
//     each square is truncated to the grid u = 2^(2G - STAT_WIN_LSB) by an
//     even-step funnel and summed exactly in 40 bits (unsigned); LZC6
//     normalizes to bit39 -> raw port (rm, re), rm*2^re = the window sum
//     exactly; result_o = vec_stat_shape(...) (RNE to 20 bits, O-IB Inf/NaN
//     codes, flush-to-zero) — the same function vector_unit uses cross-pass.
//     Exact whenever every contributing lane has e_i >= G - 17 (in particular
//     for the product-path invariant "one block exponent"); otherwise the
//     relative error is < 15*2^-34 and the rounding is faithful. This is a
//     defined 40-bit window, NOT Kulisch-exact.
//
// v2 changes from v1 (MAX / SUM, still current):
//   - VEC_LANES: 8 → 16. Tree depth: 3 levels → 4 levels (16→8→4→2→1).
//   - REDUCE_W: 20 → 21 (from vec_pkg, 5-bit headroom for 16-input sum).
//   - rnode_t and tz_shift use REDUCE_W from vec_pkg (no local override).
//
// Supported modes:
//   REDUCE_NONE: bypass (result = lane 0, for single-element passthrough)
//   REDUCE_MAX:  maximum element across all lanes (comparator tree)
//   REDUCE_SUM:  aligned sum of all lanes (block-float adder tree, 21-bit)
//   REDUCE_STAT: sum of squares for RMSNorm partial (S-STAT v1.2, see above)
//
// MAX / SUM tree structure (16 inputs → 4 levels):
//   Level 0: 16 → 8  (pairs: 0-1, 2-3, ..., 14-15)
//   Level 1:  8 → 4  (pairs: 01-23, 45-67, 89-AB, CD-EF)
//   Level 2:  4 → 2  (pairs: 0123-4567, 89AB-CDEF)
//   Level 3:  2 → 1  (final)
//
// Author:  H-Tensor Project
// Version: 3.0 (S-STAT v1.2 — scheme C STAT window; MAX/SUM = v2.0)
// =============================================================================

module vec_reduce_cluster
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── Inputs (from vec_lane_array) ──
    input  vec_lane_result_t  lane_results_i [VEC_LANES],
    input  vec_reduce_mode_e  mode_i,
    input  logic              valid_i,

    // ── Output ──
    output vec_reduce_result_t result_o,

    // ── CL-5 / S-STAT v1.2 (S9): raw STAT window sum of this pass ──
    //   Exposed for block32 cross-pass accumulation in vector_unit (latched on
    //   pass 0 into partial_stat_*_q). rm*2^re = S_k exactly; S_k != 0 ⇒
    //   rm in [2^39, 2^40) (unsigned, bit39 normalized), S_k == 0 ⇒ (0, 0).
    //   re is 12-bit signed, in [-1063, 1018]. Not gated by valid_i / mode_i
    //   (Q-C4: gating is registered separately, not in this change).
    output logic [REDUCE_STAT_W-1:0]        stat_raw_mant_o,
    output logic signed [STAT_EXP_W-1:0]    stat_raw_exp_o
);

    // =========================================================================
    // Internal reduce node type — for MAX / SUM trees
    //
    //   REDUCE_W = VEC_MANT_W + 5 = 21 bits (from vec_pkg).
    //   Provides 5-bit headroom for 16-input aligned summation:
    //     worst case = 16 × max_mant = 16 × 2^15 = 2^19, fits in 20 bits signed.
    //     21 bits gives 1 extra guard bit beyond theoretical maximum.
    // =========================================================================
    typedef struct packed {
        logic signed [REDUCE_W-1:0]   mant;     // 21-bit mantissa
        logic signed [VEC_EXP_W-1:0]  exp;      // 10-bit exponent
        logic                         is_nan;
        logic                         is_inf;
    } rnode_t;

    // =========================================================================
    // Toward-zero shift function — REDUCE_W (21-bit) version
    //
    // Identical semantics to vec_tz_shifter:
    //   shifted_tz = (val >>> n) + (is_negative & has_residue)
    // Clamped at REDUCE_W (shift > REDUCE_W → zero).
    // =========================================================================
    function automatic logic signed [REDUCE_W-1:0] tz_shift(
        input logic signed [REDUCE_W-1:0] val,
        input logic [5:0]                 amt
    );
        logic signed [REDUCE_W-1:0] shifted;
        logic [REDUCE_W-1:0]        mask;
        logic                       residue;

        if (amt == 6'd0)
            return val;
        if (amt >= 6'(REDUCE_W))
            return '0;

        shifted = val >>> amt;
        mask    = (REDUCE_W'(1) << amt) - REDUCE_W'(1);
        residue = |(val & $unsigned(mask));
        return shifted + REDUCE_W'({{(REDUCE_W-1){1'b0}}, (val[REDUCE_W-1] & residue)});
    endfunction

    // =========================================================================
    // Pair-reduce: REDUCE_MAX (rnode_t)
    //   Returns the element with larger magnitude.
    //   NaN > Inf > finite. For equal magnitude: returns 'a'.
    // =========================================================================
    function automatic rnode_t pair_max(input rnode_t a, input rnode_t b);
        logic signed [VEC_EXP_W+1:0] ediff;
        logic [5:0]                  amt;
        logic signed [REDUCE_W-1:0]  aa, bb;
        // NaN propagation
        if (a.is_nan)       return a;
        if (b.is_nan)       return b;
        // Inf handling
        if (a.is_inf && !b.is_inf) return a;
        if (b.is_inf && !a.is_inf) return b;
        if (a.is_inf && b.is_inf)  return a;  // both Inf → pick a
        // Value-aware compare (HW-REVIEW T2): value = signed mant * 2^exp. Align
        // the lower-exp operand to the higher exponent (arithmetic right shift)
        // then signed-compare. The previous exp-first compare was SIGN-BLIND
        // (a high-exp negative beat a low-exp positive) and wrong same-sign for
        // un-normalized nodes. ediff widened (M37-Vec) to avoid a 10-bit wrap.
        ediff = (VEC_EXP_W+2)'(signed'(a.exp)) - (VEC_EXP_W+2)'(signed'(b.exp));
        if (ediff >= (VEC_EXP_W+2)'(0)) begin
            amt = (ediff > (VEC_EXP_W+2)'(REDUCE_W)) ? 6'(REDUCE_W) : 6'(ediff);
            aa  = a.mant;
            bb  = b.mant >>> amt;
        end else begin
            amt = (-ediff > (VEC_EXP_W+2)'(REDUCE_W)) ? 6'(REDUCE_W) : 6'(-ediff);
            aa  = a.mant >>> amt;
            bb  = b.mant;
        end
        return (aa >= bb) ? a : b;
    endfunction

    // =========================================================================
    // Pair-reduce: REDUCE_SUM (rnode_t, 21-bit aligned addition)
    //   Aligns the smaller-exponent operand via toward-zero shift, then adds.
    //   Result exponent = max(a.exp, b.exp).
    // =========================================================================
    function automatic rnode_t pair_sum(input rnode_t a, input rnode_t b);
        rnode_t r;
        logic signed [VEC_EXP_W+1:0] ediff;   // M37-Vec: 12-bit, no wrap
        logic [5:0]                   abs_ediff;
        logic signed [REDUCE_W-1:0]   a_aligned, b_aligned;

        r.is_nan = a.is_nan | b.is_nan;
        r.is_inf = a.is_inf | b.is_inf;

        ediff = (VEC_EXP_W+2)'(signed'(a.exp)) - (VEC_EXP_W+2)'(signed'(b.exp));  // M37-Vec

        if (ediff >= VEC_EXP_W'(0)) begin
            abs_ediff = (ediff > VEC_EXP_W'(63)) ? 6'd63 : 6'(ediff);
            a_aligned = a.mant;
            b_aligned = tz_shift(b.mant, abs_ediff);
            r.exp     = a.exp;
        end else begin
            abs_ediff = (-ediff > VEC_EXP_W'(63)) ? 6'd63 : 6'(-ediff);
            a_aligned = tz_shift(a.mant, abs_ediff);
            b_aligned = b.mant;
            r.exp     = b.exp;
        end

        r.mant = a_aligned + b_aligned;
        return r;
    endfunction

    // =========================================================================
    // Input Conversion: lane_result_t → rnode_t (for MAX / SUM)
    //   Sign-extend VEC_MANT_W (16) to REDUCE_W (21) mantissa.
    // =========================================================================
    rnode_t inputs [VEC_LANES];

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            inputs[i].mant   = REDUCE_W'(signed'(lane_results_i[i].mant));
            inputs[i].exp    = lane_results_i[i].exp;
            inputs[i].is_nan = lane_results_i[i].is_nan;
            inputs[i].is_inf = lane_results_i[i].is_inf;
        end
    end

    // =========================================================================
    // Source selection for MAX/SUM tree (rnode_t, 21-bit)
    //   REDUCE_STAT uses its own tree below; MAX/SUM share the rnode tree.
    // =========================================================================
    rnode_t tree_in [VEC_LANES];

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            tree_in[i] = inputs[i];  // MAX and SUM always use normal inputs
        end
    end

    // =========================================================================
    // 4-Level Binary Reduction Tree — MAX / SUM (rnode_t, 21-bit)
    //
    //   Level 0: 16 → 8  (8 pairs)
    //   Level 1:  8 → 4  (4 pairs)
    //   Level 2:  4 → 2  (2 pairs)
    //   Level 3:  2 → 1  (final)
    //
    // For REDUCE_MAX: pair_max at every level.
    // For REDUCE_SUM: pair_sum (aligned addition) at every level.
    // REDUCE_STAT uses a separate 40-bit tree below.
    // =========================================================================

    // ── Level 0: 16 → 8 ──
    rnode_t l0 [8];

    always_comb begin
        for (int p = 0; p < 8; p++) begin
            if (mode_i == REDUCE_MAX)
                l0[p] = pair_max(tree_in[2*p], tree_in[2*p+1]);
            else
                l0[p] = pair_sum(tree_in[2*p], tree_in[2*p+1]);
        end
    end

    // ── Level 1: 8 → 4 ──
    rnode_t l1 [4];

    always_comb begin
        for (int p = 0; p < 4; p++) begin
            if (mode_i == REDUCE_MAX)
                l1[p] = pair_max(l0[2*p], l0[2*p+1]);
            else
                l1[p] = pair_sum(l0[2*p], l0[2*p+1]);
        end
    end

    // ── Level 2: 4 → 2 ──
    rnode_t l2 [2];

    always_comb begin
        for (int p = 0; p < 2; p++) begin
            if (mode_i == REDUCE_MAX)
                l2[p] = pair_max(l1[2*p], l1[2*p+1]);
            else
                l2[p] = pair_sum(l1[2*p], l1[2*p+1]);
        end
    end

    // ── Level 3: 2 → 1 (final) ──
    rnode_t final_node;

    always_comb begin
        if (mode_i == REDUCE_MAX)
            final_node = pair_max(l2[0], l2[1]);
        else
            final_node = pair_sum(l2[0], l2[1]);
    end

    // =========================================================================
    // REDUCE_STAT (sum of squares) — S-STAT v1.2, scheme C (prereg §74.1.2)
    //
    //   lane i:  am_i = |m_i| (16b; -32768 -> 16'h8000), q_i = am_i^2 <= 2^30
    //            key g_i = e_i + floor(log2 am_i) = e_i + 15 - lzc16(am_i) (11b)
    //            contributes iff !(is_zero || m == 0 || is_nan || is_inf) (S1)
    //   16->1 balanced max tree over the keys of contributing lanes -> G, any_nz
    //   funnel:  a_i = ({q_i, STAT_WIN_LSB'b0} >> 2*min(G - e_i, 33))[35:0]
    //            = floor(q_i*2^(2e_i) / u), u = 2^(2G - STAT_WIN_LSB), a_i < 2^36
    //   balanced adder tree (37/38/39/40 bit) -> acc, unsigned, in
    //            [2^34, 2^40) when any_nz (the max-key lane alone gives >= 2^34)
    //   LZC6 on acc[39:34] -> lz6 in [0, 5]; rm = acc << lz6 (bit39 = 1);
    //   re = 2G - STAT_WIN_LSB - lz6 (12b signed)
    //   result_o(STAT) = vec_stat_shape({1'b0, rm}, re, 0, |is_nan, |is_inf)
    // NaN / Inf lanes never enter the key or the sum (S1); their flags are ORed
    // over all 16 lanes (S8).
    // =========================================================================
    logic                          st_c [VEC_LANES];   // contributing lane (S1)
    logic [31:0]                   st_q [VEC_LANES];   // |m|^2 <= 2^30
    logic signed [STAT_KEY_W-1:0]  st_g [VEC_LANES];   // key g in [-512, 526]

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            logic [VEC_MANT_W-1:0] am;
            am      = lane_results_i[i].mant[VEC_MANT_W-1]
                    ? VEC_MANT_W'(-lane_results_i[i].mant)
                    : VEC_MANT_W'(lane_results_i[i].mant);         // -32768 -> 16'h8000
            st_q[i] = 32'(am) * 32'(am);
            st_g[i] = STAT_KEY_W'(signed'(lane_results_i[i].exp))
                    + STAT_KEY_W'(signed'({1'b0, 4'(4'd15 - vec_lzc16(am))}));
            st_c[i] = !(lane_results_i[i].is_zero || (lane_results_i[i].mant == '0)
                        || lane_results_i[i].is_nan || lane_results_i[i].is_inf);
        end
    end

    // ── 16 → 1 balanced max tree over {v, g}: kmax(a, b) = (!b.v || (a.v && a.g >= b.g)) ? a : b ──
    typedef struct packed {
        logic                         v;     // some contributing lane below this node
        logic signed [STAT_KEY_W-1:0] g;     // max key among them
    } stat_key_t;

    function automatic stat_key_t stat_kmax(input stat_key_t a, input stat_key_t b);
        return (!b.v || (a.v && ($signed(a.g) >= $signed(b.g)))) ? a : b;   // signed key compare
    endfunction

    stat_key_t st_k0 [VEC_LANES];
    stat_key_t st_k1 [8];
    stat_key_t st_k2 [4];
    stat_key_t st_k3 [2];
    stat_key_t st_kt;

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            st_k0[i].v = st_c[i];
            st_k0[i].g = st_g[i];
        end
        for (int p = 0; p < 8; p++) st_k1[p] = stat_kmax(st_k0[2*p], st_k0[2*p+1]);
        for (int p = 0; p < 4; p++) st_k2[p] = stat_kmax(st_k1[2*p], st_k1[2*p+1]);
        for (int p = 0; p < 2; p++) st_k3[p] = stat_kmax(st_k2[2*p], st_k2[2*p+1]);
        st_kt = stat_kmax(st_k3[0], st_k3[1]);
    end

    logic                          st_any_nz;          // >= 1 contributing lane
    logic signed [STAT_KEY_W-1:0]  st_G;               // max key (valid iff st_any_nz)
    assign st_any_nz = st_kt.v;
    assign st_G      = st_kt.g;

    // ── even-step funnel: align every square to the window grid u = 2^(2G - STAT_WIN_LSB) ──
    //   d = G - e_i in [0, 1038] for a contributing lane; dc = min(d, 33)
    //   (d >= 33 ⇒ q_i*2^STAT_WIN_LSB / 4^d < 1 ⇒ the term is 0 either way).
    logic [35:0]                   st_a [VEC_LANES];

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            logic signed [STAT_EXP_W-1:0]  d;
            logic [5:0]                    dc;
            logic [30+STAT_WIN_LSB:0]      wide;   // 65 bit: {q[30:0], 34'b0}
            d       = STAT_EXP_W'(st_G) - STAT_EXP_W'(signed'(lane_results_i[i].exp));
            dc      = (d > 12'sd33) ? 6'd33 : 6'(d);
            wide    = {st_q[i][30:0], {STAT_WIN_LSB{1'b0}}} >> {dc, 1'b0};
            st_a[i] = st_c[i] ? wide[35:0] : 36'd0;
        end
    end

    // ── balanced adder tree, widths grow 37 / 38 / 39 / 40 (no inter-level alignment) ──
    logic [36:0]                   st_s0 [8];
    logic [37:0]                   st_s1 [4];
    logic [38:0]                   st_s2 [2];
    logic [REDUCE_STAT_W-1:0]      st_acc;

    always_comb begin
        for (int p = 0; p < 8; p++) st_s0[p] = 37'(st_a[2*p])  + 37'(st_a[2*p+1]);
        for (int p = 0; p < 4; p++) st_s1[p] = 38'(st_s0[2*p]) + 38'(st_s0[2*p+1]);
        for (int p = 0; p < 2; p++) st_s2[p] = 39'(st_s1[2*p]) + 39'(st_s1[2*p+1]);
        st_acc = REDUCE_STAT_W'(st_s2[0]) + REDUCE_STAT_W'(st_s2[1]);
    end

    // ── LZC6 normalization to bit39 + raw exponent ──
    logic [2:0]                    st_lz6;
    logic [REDUCE_STAT_W-1:0]      st_rm;
    logic signed [STAT_EXP_W-1:0]  st_re;

    always_comb begin
        logic signed [12:0] re13;
        casez (st_acc[REDUCE_STAT_W-1:STAT_WIN_LSB])
            6'b1?????: st_lz6 = 3'd0;
            6'b01????: st_lz6 = 3'd1;
            6'b001???: st_lz6 = 3'd2;
            6'b0001??: st_lz6 = 3'd3;
            6'b00001?: st_lz6 = 3'd4;
            default:   st_lz6 = 3'd5;
        endcase
        st_rm = st_acc << st_lz6;
        re13  = (13'(st_G) <<< 1) - 13'(STAT_WIN_LSB) - 13'(signed'({1'b0, st_lz6}));
        st_re = re13[STAT_EXP_W-1:0];
    end

    // CL-5 / S9: raw window sum of this pass (exact; (0, 0) when no lane contributes)
    assign stat_raw_mant_o = st_any_nz ? st_rm : '0;
    assign stat_raw_exp_o  = st_any_nz ? st_re : '0;

    // S8 flags: OR over all 16 lanes (NaN / Inf lanes are excluded from key and sum above)
    logic st_any_nan, st_any_inf;
    always_comb begin
        st_any_nan = 1'b0;
        st_any_inf = 1'b0;
        for (int i = 0; i < VEC_LANES; i++) begin
            st_any_nan = st_any_nan | lane_results_i[i].is_nan;
            st_any_inf = st_any_inf | lane_results_i[i].is_inf;
        end
    end

    // S5-S8: the single shaping function (vec_pkg), same as the cross-pass combine
    vec_reduce_result_t st_shaped;
    assign st_shaped = vec_stat_shape({1'b0, stat_raw_mant_o}, stat_raw_exp_o,
                                      1'b0, st_any_nan, st_any_inf);

    // =========================================================================
    // Output Assembly
    // =========================================================================
    always_comb begin
        result_o.mant   = '0;
        result_o.exp    = '0;
        result_o.is_nan = 1'b0;
        result_o.is_inf = 1'b0;
        result_o.valid  = 1'b0;

        if (valid_i) begin
            case (mode_i)
                REDUCE_NONE: begin
                    // Bypass: output lane 0 (sign-extended to REDUCE_W)
                    result_o.mant   = REDUCE_W'(signed'(lane_results_i[0].mant));
                    result_o.exp    = lane_results_i[0].exp;
                    result_o.is_nan = lane_results_i[0].is_nan;
                    result_o.is_inf = lane_results_i[0].is_inf;
                    result_o.valid  = 1'b1;
                end

                REDUCE_MAX, REDUCE_SUM: begin
                    result_o.mant   = final_node.mant;
                    result_o.exp    = final_node.exp;
                    result_o.is_nan = final_node.is_nan;
                    result_o.is_inf = final_node.is_inf;
                    result_o.valid  = 1'b1;
                end

                REDUCE_STAT: begin
                    // S-STAT v1.2: shaped window sum (vec_stat_shape, see above)
                    result_o        = st_shaped;
                    result_o.valid  = 1'b1;
                end

                default: begin
                    result_o.valid = 1'b0;
                end
            endcase
        end
    end

    // =========================================================================
    // Simulation-only S-STAT invariants (prereg §74.1.2 A2' / A3 / A4).
    // Pure functions of the lane inputs, true for ANY input (not only in
    // REDUCE_STAT mode) — a firing here is an RTL defect, never a data case.
    // =========================================================================
`ifndef SYNTHESIS
    always_comb begin
        // A2': raw mant is 0 or bit39-normalized; raw mant 0 ⇒ raw exp 0
        assert ((stat_raw_mant_o == '0) || stat_raw_mant_o[REDUCE_STAT_W-1])
            else $error("[S-STAT A2'] raw mant %h neither 0 nor bit39-normalized", stat_raw_mant_o);
        assert ((stat_raw_mant_o != '0) || (stat_raw_exp_o == '0))
            else $error("[S-STAT A2'] raw mant 0 with raw exp %0d", stat_raw_exp_o);
        // A4: the max-key lane alone puts >= 2^34 into acc (anchor invariant,
        //     and the LZC6 precondition)
        assert (!st_any_nz || (st_acc[REDUCE_STAT_W-1:STAT_WIN_LSB] != '0))
            else $error("[S-STAT A4] any_nz but acc[39:34] == 0 (acc %h)", st_acc);
        // A3: finite results are (0,0) or M in [2^19, 2^20); special values carry
        //     exactly the O-IB codes
        if (!st_shaped.is_nan && !st_shaped.is_inf) begin
            assert (st_shaped.mant[REDUCE_W-1] == 1'b0)
                else $error("[S-STAT A3] finite result with mant[20] set: %h", st_shaped.mant);
            assert ((st_shaped.mant != '0) || (st_shaped.exp == '0))
                else $error("[S-STAT A3] zero result with exp %0d", st_shaped.exp);
            assert ((st_shaped.mant == '0) || st_shaped.mant[REDUCE_W-2])
                else $error("[S-STAT A3] finite non-zero result not normalized: %h", st_shaped.mant);
        end else if (st_shaped.is_nan) begin
            assert ((st_shaped.mant == 21'h1FFFFF) && (st_shaped.exp == 10'sd0))
                else $error("[S-STAT A3] NaN result without the O-IB NaN code");
        end else begin
            assert ((st_shaped.mant == 21'h100000) && (st_shaped.exp == 10'sd511))
                else $error("[S-STAT A3] Inf result without the O-IB Inf code");
        end
    end
`endif

endmodule

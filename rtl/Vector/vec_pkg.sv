// =============================================================================
// vec_pkg.sv — H-Tensor Vector Unit Shared Package
//
// Defines all Vector-internal types, enums, parameters, structs, and helpers.
// This file must be compiled after pe_pkg.sv and before any vec_*.sv module.
//
// v6.0 Round 1 changes (infrastructure only — no downstream behavior change):
//   - VEC_WATCHDOG_THRESHOLD (new): explicit 10-bit comparison value for
//     VST_ACTIVE watchdog, replacing the unsafe VEC_MAX_OP_CYCLES[9:0]
//     part-select usage pattern in vector_unit.sv (pre-v6 bug).
//     VEC_MAX_OP_CYCLES is retained as the semantic concept ("nominal max
//     cycles per op"); VEC_WATCHDOG_THRESHOLD is the concrete RTL compare
//     target. Both exist intentionally; see Section 1 for rationale.
//   - vec_error_e: +2 codes, organized by the error taxonomy below
//       VERR_ROLE_MISORDER (4'd10): from vector_unit FSM (CL-4 HOL guard)
//       VERR_SCALE_DECODE  (4'd11): from vec_scale_adapter (decode-time fail)
//
// Error taxonomy (consistent across Vector Unit):
//   *_FORMAT   : field / enum / contract MISMATCH against descriptor
//                (value is syntactically valid, but not what consumer expects)
//   *_DECODE   : field value EXISTS but cannot be interpreted
//                (e.g., subnormal raw_scale, scale_inline_valid=0 when needed)
//   *_MISORDER : TIMING / role / arrival-order violation
//                (e.g., SRC1 arrives before SRC0 → HOL stall timeout)
//
// Historical changes (retained for traceability):
//   v2 from v1:
//     - VEC_LANES:   8 → 16 (aligns with 256-bit payload / 16-element capsule)
//     - VEC_OQ_DEPTH: 4 → 6 (margin for block_size=32 dual-operand 4-capsule)
//     - REDUCE_W:    20 → 21 (headroom for 16-input summation)
//     - REDUCE_STAT_W: new 40-bit (no per-element truncation for sum-of-squares)
//     - vec_internal_scale_t: added mant_corr[7:0] (E4M3 full-precision decode)
//     - vec_ctrl_t:  added num_passes[1:0] (multi-pass block controller)
//     - New helpers:  passes_for_block(), is_dual_pass()
//   v4 internal closures (CL-1..CL-10): no vec_pkg signature changes;
//     LAYOUT_* constants already present in Section 10b.
//
// Design principles:
//   - Imports pe_pkg for shared contract types (bs_capsule_t, scale_format_e,
//     block_size_sel_e, elem_fmt_e, operand_role_e, etc.)
//   - Does NOT import upe_pkg — Vector layer is independent of UPE internals
//   - All cross-module interfaces within Vector Unit are frozen in this file
//   - Parameterized for lane count, block sizes, and future extensibility
//
// Layering:
//   pe_pkg (contract types)  ← vec_pkg (Vector internals)
//   upe_pkg (UPE internals)  — no dependency from vec_pkg
//
// Contents:
//   1. Global Parameters
//   2. Primitive & Operation Enums
//   3. Internal Scale Representation
//   4. Lane-Level Types
//   5. Reduction Types
//   6. Renorm / Requant Types
//   7. Pipeline Control Bus (vec_ctrl_t)
//   8. Error Types
//   9. Performance Counter Types
//  10. Shifter Parameters
//  11. Helper Functions
//
// Author:  H-Tensor Project
// Version: 6.0 (Round 1 — error taxonomy + watchdog threshold infrastructure)
// =============================================================================

package vec_pkg;

    import pe_pkg::*;

    // =========================================================================
    // 1. Global Parameters
    // =========================================================================

    // Lane array configuration
    //   VEC_LANES: number of parallel lanes in vec_lane_array
    //   v2: 16 lanes — aligns with BS_CAP_PAYLOAD_W/VEC_MANT_W = 256/16 = 16
    //   elements per capsule, enabling single-pass processing for block_size=16
    //   and 2-pass for block_size=32.
    parameter int VEC_LANES         = 16;
    parameter int VEC_LANE_IDX_W    = $clog2(VEC_LANES);   // 4 for 16 lanes

    // Block size support
    //   V1 contract: 16 and 32 are the two formally supported sizes.
    //   VEC_MAX_BLOCK determines internal buffer widths and reduce tree depth.
    parameter int VEC_MAX_BLOCK     = 32;
    parameter int VEC_BASELINE_BLOCK = 32;
    parameter int VEC_ALT_BLOCK     = 16;

    // Internal mantissa width for lane arithmetic
    //   Matches UPE accumulator philosophy: wide enough for BF16 (8-bit mant)
    //   alignment + guard bits, but not full FP32 adder.
    //   16-bit signed covers all element formats with alignment headroom.
    parameter int VEC_MANT_W        = 16;

    // Internal exponent width (matches block-float accumulator convention)
    parameter int VEC_EXP_W         = 10;

    // Operand queue depth
    //   v2: depth=6 provides 2-slot margin over worst-case block_size=32
    //   dual-operand (4 capsules: 2×src0 + 2×src1), absorbing ingress jitter.
    parameter int VEC_OQ_DEPTH      = 6;

    // Maximum cycles for a single Vector op (semantic concept)
    //   Nominal upper bound on how many cycles any single Vector op should
    //   take, including multi-pass iteration, escape handling, and L2_WB.
    //   Used in documentation and high-level arch reasoning.
    //   NOT directly used in RTL comparators (see VEC_WATCHDOG_THRESHOLD below).
    parameter int VEC_MAX_OP_CYCLES = 1024;

    // Watchdog comparison threshold for VST_ACTIVE (RTL compare target)
    //   This is the concrete value fed into the watchdog_timeout comparator.
    //   It MUST be a literal that fits in the watchdog counter's bit-width
    //   (currently 10 bits in vector_unit.sv → max representable = 1023).
    //
    //   Why this exists separately from VEC_MAX_OP_CYCLES:
    //     Pre-v6 code wrote `watchdog_timeout = (cnt >= VEC_MAX_OP_CYCLES[9:0])`.
    //     Because VEC_MAX_OP_CYCLES = 1024 = 11'b10000000000, its low 10 bits
    //     are all zero — the comparison degraded to `(cnt >= 0)`, which is
    //     always true, firing watchdog on the first ACTIVE cycle of every op.
    //     Introducing a dedicated 10-bit-safe threshold eliminates this class
    //     of bugs by making the compare target explicit and literal-friendly.
    //
    //   Invariant: VEC_WATCHDOG_THRESHOLD <= 2^WATCHDOG_CNT_W - 1
    //     Currently: 1023 <= 2^10 - 1 = 1023 ✓ (at the maximum)
    //     If the counter width changes in the future, this literal must be
    //     re-checked and potentially widened in both places simultaneously.
    localparam int VEC_WATCHDOG_THRESHOLD = 1023;

    // =========================================================================
    // 2. Primitive & Operation Enums
    //
    // vec_primitive_e: enumerates all defined Vector primitives.
    //   MVP (v1): VEC_RENORM through VEC_MOE_DISPATCH_PACK (10 primitives)
    //   Future:   VEC_BIASADD through VEC_SPECIAL_ESCAPE (reserved encoding)
    //
    // vec_op_class_e: coarse-grained datapath selection.
    //   Used by vec_desc_decode to configure pipeline stage enables.
    // =========================================================================

    typedef enum logic [5:0] {
        // --- NOP (identity / placeholder) ---
        VEC_NOP                 = 6'd0,

        // --- P1: Scale-preserving transform (MVP) ---
        VEC_PACK                = 6'd1,
        VEC_UNPACK              = 6'd2,
        VEC_SPLIT               = 6'd3,
        VEC_MERGE               = 6'd4,

        // --- P2: Scale-aware arithmetic (MVP) ---
        VEC_RESADD              = 6'd5,

        // --- P3: Scale-changing transform (MVP) ---
        VEC_RENORM              = 6'd6,

        // --- P4: Reduction / partial-stat ops (MVP) ---
        VEC_REDUCE_MAX          = 6'd7,
        VEC_REDUCE_SUM          = 6'd8,
        VEC_RMSNORM_PARTIAL     = 6'd9,

        // --- P5: Routing / dispatch transform (MVP) ---
        VEC_MOE_DISPATCH_PACK   = 6'd10,

        // --- Future P2: Scale-aware arithmetic ---
        VEC_BIASADD             = 6'd11,
        VEC_CLAMP               = 6'd12,
        VEC_ABS                 = 6'd13,
        VEC_MAX_ELEM            = 6'd14,
        VEC_ACT_APPROX          = 6'd15,

        // --- Future P3: Scale-changing transform ---
        VEC_REQUANT             = 6'd16,
        VEC_SCALE_REFRESH       = 6'd17,
        VEC_BLOCK_SPLIT_REPACK  = 6'd18,
        VEC_BLOCK_MERGE_REPACK  = 6'd19,

        // --- Future P1: Layout transform ---
        VEC_LAYOUT_RETAG        = 6'd20,
        VEC_GATHER_INBLOCK      = 6'd21,
        VEC_SCATTER_INBLOCK     = 6'd22,

        // --- Future P4: Reduction ---
        VEC_LAYERNORM_PARTIAL   = 6'd23,

        // --- Future P5: Routing ---
        VEC_ROUTE_PREP          = 6'd24,
        VEC_EXPERT_LOCAL_REORDER = 6'd25,

        // --- P6: Escape-marked ops (future) ---
        VEC_SOFTMAX_PREP        = 6'd26,
        VEC_FP_ASSIST_REDUCE    = 6'd27,
        VEC_SPECIAL_ESCAPE      = 6'd28
        // 29-63: reserved for future extension
    } vec_primitive_e;

    // Operation class — coarse-grained pipeline configuration
    typedef enum logic [2:0] {
        VCLASS_TRANSFORM  = 3'd0,   // pack/unpack/split/merge/layout
        VCLASS_ARITHMETIC = 3'd1,   // resadd/biasadd/clamp/abs/act
        VCLASS_REDUCE     = 3'd2,   // reduce_max/sum/partial_stat
        VCLASS_RENORM     = 3'd3,   // renorm/requant/scale_refresh
        VCLASS_ROUTE      = 3'd4,   // moe_dispatch/route_prep/reorder
        VCLASS_ESCAPE     = 3'd5,   // softmax_prep/fp_assist/escape
        VCLASS_NOP        = 3'd6    // no-op / placeholder
        // 7: reserved
    } vec_op_class_e;

    // =========================================================================
    // 3. Internal Scale Representation
    //
    // vec_internal_scale_t: the unified internal form for block-scale metadata.
    //   vec_scale_adapter converts E8M0 / E4M3 raw encoding into this form.
    //   All downstream modules (lanes, reduce, renorm, packer) only see this.
    //
    //   exp_adj: signed exponent adjustment (shared factor as 2^exp_adj)
    //     - E8M0:  exp_adj = unsigned_exp - 127  (bias removal)
    //     - E4M3:  exp_adj = (decoded_exponent - 7)  (v2: pure exponent, no approx)
    //   mant_corr: 8-bit mantissa correction factor (v2 full-precision decode)
    //     - Encodes the fractional part: actual_scale = 2^exp_adj × (mant_corr/128)
    //     - E8M0:  mant_corr = 128 (1.0, no fractional part)
    //     - E4M3:  mant_corr = {1'b1, mant[2:0], 4'b0} = (1 + mant/8) × 128
    //     - Simple mode (v2 / v4 / v6.0 current): lanes use only exp_adj for
    //       alignment; mant_corr is passed through to result_packer for
    //       lossless E4M3 re-encode (0% round-trip error).
    //     - Precise mode (Future Plan Phase 5): lanes apply mant_corr as a
    //       multiplicative correction for tighter block-float alignment.
    //       Not implemented in v6.0; reserved for later revision.
    //   special_nan:  shared factor is NaN (E8M0: 0xFF; E4M3: all-ones)
    //   special_zero: shared factor is zero/denorm (treated as flush-to-zero)
    // =========================================================================

    typedef struct packed {
        logic signed [VEC_EXP_W-1:0]  exp_adj;        // signed exponent adjustment
        logic [7:0]                   mant_corr;       // mantissa correction (128 = 1.0)
        logic                         special_nan;     // NaN flag
        logic                         special_zero;    // zero/denorm flag
    } vec_internal_scale_t;

    // Default (identity) scale: exp_adj=0, mant_corr=128 (1.0), no special flags
    localparam vec_internal_scale_t VEC_SCALE_IDENTITY = '{
        exp_adj:      '0,
        mant_corr:    8'd128,
        special_nan:  1'b0,
        special_zero: 1'b0
    };

    // =========================================================================
    // 4. Lane-Level Types
    //
    // vec_lane_op_e:  micro-operation for each lane.
    // vec_elem_t:     internal element representation within a lane.
    // vec_lane_result_t: output from each lane (element + flags).
    // =========================================================================

    // Lane micro-operations
    typedef enum logic [3:0] {
        LANE_NOP       = 4'd0,    // no operation (output = input passthrough)
        LANE_PASS      = 4'd1,    // explicit passthrough (pack/unpack reshape)
        LANE_ABS       = 4'd2,    // absolute value
        LANE_CLAMP     = 4'd3,    // clamp to range
        LANE_MAX       = 4'd4,    // max(src0, src1) — element-wise compare
        LANE_ADD       = 4'd5,    // aligned add (for VEC_RESADD)
        LANE_SUB       = 4'd6,    // aligned sub
        LANE_MULADD    = 4'd7,    // small mul-add (future, for bias/scale)
        LANE_SIGN_INJ  = 4'd8,    // sign injection / flip
        LANE_MERGE_LO  = 4'd9,    // block merge: select lower half
        LANE_MERGE_HI  = 4'd10,   // block merge: select upper half
        LANE_SPLIT     = 4'd11,   // block split: route to sub-block
        LANE_REDUCE_P  = 4'd12    // partial reduction output prep
        // 13-15: reserved
    } vec_lane_op_e;

    // Internal element representation (block-float aligned)
    //   Used within vec_lane_array and vec_reduce_cluster.
    //   Mantissa is signed (two's complement after sign separation).
    //   Exponent is the block-shared exponent (from vec_internal_scale_t)
    //   adjusted by per-element offset where applicable.
    typedef struct packed {
        logic signed [VEC_MANT_W-1:0]  mant;      // signed mantissa
        logic signed [VEC_EXP_W-1:0]   exp;       // exponent (block-float)
        logic                          sign;      // original sign (pre-2C)
        logic                          is_zero;   // element is zero
        logic                          is_nan;    // NaN flag
        logic                          is_inf;    // Inf flag
    } vec_elem_t;

    // [C9 2026-07-25] LANE_ADD/SUB alignment-control leaf — the SINGLE source
    // of truth shared by vec_lane_array (in-place fallback when the parent
    // does not supply registered controls), vector_unit (PH_MC registration)
    // and the C9 shadow tripwire. Verbatim the pre-C9 inline math from the
    // LANE_ADD branch: widened (VEC_EXP_W+2) domain (HW-REVIEW T3 / M37-Vec
    // discipline), clamp 63, shift side = (exp_diff > 0).
    // Returns {shift_src1_side, abs_diff[5:0]}.
    function automatic logic [6:0] vec_lane_shift_ctrl(input vec_elem_t a,
                                                       input vec_elem_t b);
        logic signed [VEC_EXP_W+1:0] exp_diff;
        logic [5:0]                  ad;
        exp_diff = (VEC_EXP_W+2)'(signed'(a.exp)) - (VEC_EXP_W+2)'(signed'(b.exp));
        if (exp_diff >= (VEC_EXP_W+2)'(0))
            ad = (exp_diff > (VEC_EXP_W+2)'(63)) ? 6'd63 : 6'(exp_diff);
        else
            ad = (-exp_diff > (VEC_EXP_W+2)'(63)) ? 6'd63 : 6'(-exp_diff);
        return {(exp_diff > (VEC_EXP_W+2)'(0)), ad};
    endfunction

    // Lane result (element + status flags)
    typedef struct packed {
        logic signed [VEC_MANT_W-1:0]  mant;      // result mantissa
        logic signed [VEC_EXP_W-1:0]   exp;       // result exponent
        logic                          sign;      // result sign
        logic                          is_zero;   // result is zero
        logic                          is_nan;    // NaN propagated / generated
        logic                          is_inf;    // Inf propagated / generated
        logic                          overflow;  // lane detected overflow
        logic                          underflow; // lane detected underflow
    } vec_lane_result_t;

    // Default zero element
    localparam vec_elem_t VEC_ELEM_ZERO = '{
        mant:    '0,
        exp:     '0,
        sign:    1'b0,
        is_zero: 1'b1,
        is_nan:  1'b0,
        is_inf:  1'b0
    };

    // =========================================================================
    // 5. Reduction Types
    //
    // vec_reduce_mode_e: operation mode for vec_reduce_cluster.
    // vec_reduce_result_t: output from the reduce cluster.
    //
    // Width parameters:
    //   REDUCE_W:      mantissa width for MAX/SUM reduction tree nodes.
    //                  VEC_MANT_W + 5 = 21 provides 5-bit headroom for
    //                  16-input aligned summation (4 bits for sum + 1 guard).
    //   REDUCE_STAT_W: REDUCE_STAT (sum-of-squares) per-pass window accumulator
    //                  and raw-port mantissa width. [S-STAT v1.2 / §74.1] 40-bit
    //                  UNSIGNED, MSB-anchored window (scheme C): the pass sum is
    //                  exact on the grid u = 2^(2G - STAT_WIN_LSB) (G = max lane
    //                  key e + floor(log2|m|)); the raw port (rm, re) is
    //                  normalized to bit39 and rm*2^re equals the window sum
    //                  exactly. The 21-bit result is produced by vec_stat_shape
    //                  (round-to-nearest-even, O-IB Inf/NaN codes, flush-to-zero),
    //                  never by a fixed right shift.
    // =========================================================================

    // Reduction accumulator widths
    localparam int REDUCE_W      = VEC_MANT_W + 5;   // 21 for MAX/SUM
    localparam int REDUCE_STAT_W = 40;                // 40 for STAT (window accumulator)

    // [S-STAT v1.2 / prereg §70 + §74.1] REDUCE_STAT (sum-of-squares) constants
    localparam int STAT_EXP_W   = VEC_EXP_W + 2;      // 12: raw exponent re
    localparam int STAT_KEY_W   = VEC_EXP_W + 1;      // 11: lane key g in [-512, 526]
    localparam int STAT_WIN_LSB = 34;                 // u = 2^(2G - 34)
    localparam int STAT_Z_W     = REDUCE_STAT_W + 1;  // 41: cross-pass sum

    typedef enum logic [1:0] {
        REDUCE_NONE = 2'd0,    // no reduction (bypass)
        REDUCE_MAX  = 2'd1,    // max across block (for find-max / softmax prep)
        REDUCE_SUM  = 2'd2,    // sum across block (for norm / mean)
        REDUCE_STAT = 2'd3     // partial statistics: sum-of-squares (for RMSNorm)
    } vec_reduce_mode_e;

    // Reduce cluster output
    //   The reduce result is a single scalar (or partial result) per block.
    //   For REDUCE_MAX:  result = max element (mant+exp)
    //   For REDUCE_SUM:  result = sum of aligned elements (REDUCE_W accumulator)
    //   For REDUCE_STAT: result = sum-of-squares, S-STAT v1.2 (vec_stat_shape):
    //                    finite = M*2^E with M in [2^19, 2^20) or (0, 0);
    //                    Inf = (-2^20, 511) (field 0x100000), NaN = (-1, 0)
    //                    (field 0x1FFFFF) — the mant[20]=1 code points are
    //                    reserved for the two special values (O-IB).
    typedef struct packed {
        logic signed [REDUCE_W-1:0]    mant;      // REDUCE_W bits (21)
        logic signed [VEC_EXP_W-1:0]   exp;       // shared exponent of result
        logic                          is_nan;    // any lane had NaN
        logic                          is_inf;    // any lane had Inf
        logic                          valid;     // result is valid
    } vec_reduce_result_t;

    // [S-STAT v1.2] leading-zero count of a 16-bit magnitude (a == 0: don't care, 15).
    function automatic logic [3:0] vec_lzc16(input logic [15:0] a);
        logic [3:0] r;
        r = 4'd15;
        for (int b = 0; b < 16; b++)
            if (a[b]) r = 4'(15 - b);                     // highest set bit is written last
        return r;
    endfunction

    // [S-STAT v1.2] the ONE implementation of S5-S8 (shared by vec_reduce_cluster
    // per pass and vector_unit cross-pass; prereg §74.1.2):
    //   value = z * 2^y (+ sticky_in below z[0]); round to nearest even to a
    //   20-bit significand, then range: E > 511 -> Inf (O-IB), E < -512 -> 0.
    //   Precondition: z == 0 or z[40] | z[39].
    //   Payload priority: any_nan -> NaN code; else is_inf -> Inf code;
    //   else flush-to-zero -> (0, 0); else (M, E).
    function automatic vec_reduce_result_t vec_stat_shape(
        input logic [STAT_Z_W-1:0]          z,
        input logic signed [STAT_EXP_W-1:0] y,           // weight of z[0]
        input logic                         sticky_in,
        input logic                         any_nan,
        input logic                         any_inf
    );
        vec_reduce_result_t r;
        logic               h, g, s, rnd, ovf, ftz;
        logic [19:0]        kept;
        logic [20:0]        m;
        logic signed [12:0] e;
        h    = z[40];
        kept = h ? z[40:21] : z[39:20];
        g    = h ? z[20]    : z[19];
        s    = (h ? |z[19:0] : |z[18:0]) | sticky_in;
        rnd  = g & (s | kept[0]);                         // round half to even
        m    = {1'b0, kept} + {20'd0, rnd};
        e    = 13'(y) + (h ? 13'sd21 : 13'sd20);          // y signed => sign-extended
        if (m[20]) begin
            m = 21'h080000;                               // carry out: two statements (§70.3)
            e = e + 13'sd1;
        end
        ovf  = (z != '0) && (e > 13'sd511);
        ftz  = (z == '0) || (e < -13'sd512);
        r.is_nan = any_nan;
        r.is_inf = any_inf | ovf;
        r.valid  = 1'b1;
        if (any_nan)       begin r.mant = 21'h1FFFFF; r.exp = 10'sd0;   end   // O-IB NaN = (-1, 0)
        else if (r.is_inf) begin r.mant = 21'h100000; r.exp = 10'sd511; end   // O-IB Inf = (-2^20, 511)
        else if (ftz)      begin r.mant = '0;         r.exp = '0;       end
        else               begin r.mant = m;          r.exp = e[9:0];   end
        return r;
    endfunction

    // =========================================================================
    // 6. Renorm / Requant Types
    //
    // vec_renorm_result_t: output from vec_renorm_quant.
    //   Contains renormalized elements ready for capsule packing.
    //   Also carries the updated scale metadata (new exp_adj after renorm).
    // =========================================================================

    typedef struct packed {
        logic [VEC_MAX_BLOCK*VEC_MANT_W-1:0] packed_mant;   // renormed mantissas
        vec_internal_scale_t                  new_scale;     // updated scale
        logic                                 scale_changed; // scale was refreshed
        logic                                 escape_needed; // exp spread > threshold
                                                             // OR ctrl.escape_req;
                                                             // NaN is status-only
                                                             // (CL-9, not an escape trigger)
        logic                                 valid;
    } vec_renorm_result_t;

    // =========================================================================
    // 7. Pipeline Control Bus (vec_ctrl_t)
    //
    // Master control signal bundle generated by vec_desc_decode and consumed
    // by all downstream sub-modules. Carries decoded primitive, pipeline stage
    // enables, format context, and identity fields.
    //
    // This struct is the single source of truth for "what the current op needs."
    // Each sub-module selects the fields it cares about.
    //
    // Frozen at R1. Sub-modules must not require additional control signals
    // outside this struct (except valid/ready handshake signals).
    // =========================================================================

    typedef struct packed {
        // --- Primitive identity ---
        // NOTE: field renamed primitive→prim_id — `primitive` is a reserved
        // SystemVerilog keyword (UDP), which strict tools (Verilator) reject as
        // an identifier. This blocked the whole package from elaborating.
        vec_primitive_e    prim_id;        // [5:0] specific primitive
        vec_op_class_e     op_class;       // [2:0] coarse datapath class

        // --- Operand requirements ---
        logic              need_src0;      // src0 operand required
        logic              need_src1;      // src1 operand required (e.g., RESADD)

        // --- Pipeline stage enables ---
        logic              scale_adapt_en; // activate vec_scale_adapter
        logic              lane_en;        // activate vec_lane_array
        logic              reduce_en;      // activate vec_reduce_cluster
        logic              renorm_en;      // activate vec_renorm_quant
        logic              escape_req;     // request escape path

        // --- Lane control ---
        vec_lane_op_e      lane_op;        // [3:0] per-lane micro-op

        // --- Reduce control ---
        vec_reduce_mode_e  reduce_mode;    // [1:0] reduce operation type

        // --- Multi-pass control ---
        //   num_passes: how many VEC_LANES-wide passes are needed for one block.
        //     block_size=16, VEC_LANES=16 → 1 pass
        //     block_size=32, VEC_LANES=16 → 2 passes
        //   Computed by vec_desc_decode from block_size and VEC_LANES.
        //   vector_unit FSM uses this to control pass iteration.
        logic [1:0]        num_passes;     // 1 or 2 (v2 range)

        // --- Format context (from descriptor, propagated through pipeline) ---
        block_size_sel_e   block_size;     // [1:0] 16 or 32
        scale_format_e     scale_format;   // [2:0] E8M0 / E4M3
        elem_fmt_e         elem_fmt;       // [3:0] element format
        logic [3:0]        layout_tag;     // layout identifier
        logic [7:0]        scale_epoch;    // metadata consistency token
        logic [3:0]        round_sat_policy; // rounding / saturation mode
        logic [1:0]        escape_hint;    // escape policy from descriptor

        // --- Egress policy ---
        destination_hint_e dest_hint;      // [1:0] preferred destination
        logic              fwd_eligible;   // fast-path forwarding allowed
        logic              multi_consumer; // multiple consumers expected

        // --- Identity (preserved through entire pipeline) ---
        logic [CTX_ID_W-1:0] ctx_id;      // context ID (from PE scheduler)
        logic [TAG_W-1:0]    tag;          // tag (for credit/completion return)
    } vec_ctrl_t;

    // =========================================================================
    // 8. Error Types
    //
    // vec_error_e: internal error codes generated by Vector sub-modules.
    //   These are reported to PE via done_err signals and mapped to
    //   fp_miss_reason_e at the vector_unit boundary.
    //
    // Error taxonomy (see file header for the three-axis principle):
    //   *_FORMAT   : field / enum / contract MISMATCH  (value legal, not expected)
    //   *_DECODE   : field value exists but cannot be interpreted
    //   *_MISORDER : timing / role / arrival-order violation
    //
    // Source module annotations (which RTL module can set each code):
    //   vec_desc_decode  : VERR_BAD_PRIMITIVE, VERR_BAD_BLOCK_SIZE,
    //                      VERR_BAD_SCALE_FORMAT, VERR_LAYOUT_UNSUPPORTED
    //   vec_ingress_arb  : VERR_BAD_BLOCK_SIZE, VERR_BAD_SCALE_FORMAT,
    //                      VERR_EPOCH_MISMATCH (also mapped to miss_reason)
    //   vec_lane_array   : VERR_OVERFLOW (set via status propagation only)
    //   vec_renorm_quant : VERR_ESCAPE_FORCED (via escape_needed path)
    //   vec_operand_queue: VERR_QUEUE_FULL
    //   vec_scale_adapter: VERR_SCALE_DECODE   (v6.0: invalid raw_scale /
    //                                           missing inline_scale)
    //   vector_unit FSM  : VERR_ROLE_MISORDER  (v6.0: CL-4 HOL stall timeout;
    //                                           replaces pre-v6 VERR_INTERNAL
    //                                           overload for role stalls)
    //                      VERR_INTERNAL       (genuinely unexpected state)
    // =========================================================================

    typedef enum logic [3:0] {
        VERR_NONE              = 4'd0,
        VERR_BAD_PRIMITIVE     = 4'd1,   // FORMAT: unsupported / unimplemented primitive
        VERR_BAD_BLOCK_SIZE    = 4'd2,   // FORMAT: block_size not in {16, 32}
        VERR_BAD_SCALE_FORMAT  = 4'd3,   // FORMAT: scale_format not in {E8M0, E4M3}
        VERR_EPOCH_MISMATCH    = 4'd4,   // FORMAT: scale_epoch inconsistency
        VERR_LAYOUT_UNSUPPORTED = 4'd5,  // FORMAT: layout_tag not consumable
        VERR_OVERFLOW          = 4'd6,   // arithmetic overflow in lane/reduce
        VERR_ESCAPE_FORCED     = 4'd7,   // escape required but not available
        VERR_QUEUE_FULL        = 4'd8,   // operand queue overflow
        VERR_INTERNAL          = 4'd9,   // unexpected internal state
        VERR_ROLE_MISORDER     = 4'd10,  // MISORDER: v6.0 — CL-4 HOL stall timeout
                                         //   (queue head has wrong operand_role
                                         //    for current WAIT state beyond
                                         //    ROLE_STALL_LIMIT cycles)
        VERR_SCALE_DECODE      = 4'd11,  // DECODE:   v6.0 — scale_adapter reports
                                         //   error_o=1 while scale_adapt_en is
                                         //   active and scale is required
        VERR_OPERAND_TIMEOUT   = 4'd12,  // TIMEOUT: HW-REVIEW T4 — an operand never
                                         //   arrived in VST_WAIT_OP0/OP1 (incl. a
                                         //   hung resident-SRC1 read), a hung sidecar
                                         //   read (T3-FF/FF3b-c BLK_SETUP), or an
                                         //   L2_WB write-stall; watchdog → VST_ERROR
                                         //   + done (credit)
        VERR_DEGRADED          = 4'd13   // DEGRADED: HW-REVIEW T3-FF/FF3b-c — a
                                         //   streaming op completed (done_o) but a
                                         //   watchdog spill degraded a block; err_valid_o
                                         //   fires at the final VST_DONE so completion
                                         //   is NOT silent (defensive: the spill path is
                                         //   structurally hard to reach — ACTIVE advances
                                         //   every cycle — but the code keeps it loud)
        // 14-15: reserved
    } vec_error_e;

    // =========================================================================
    // 9. Performance Counter Types
    //
    // VEC_PERF_CNT_NUM counters, each PERF_CNT_W bits (32-bit, from pe_pkg).
    // These are instantiated inside vector_unit.sv and routed to cp_csr for
    // MMIO read at 0x140-0x184 (high-half MMIO region).
    //
    // Counter index enumeration for array addressing:
    // =========================================================================

    // Total number of Vector performance counters
    localparam int VEC_NUM_PERF_CNTS = 17;

    typedef enum logic [4:0] {
        VCNT_ISSUE          = 5'd0,    // total ops issued to Vector Unit
        VCNT_BUSY_CYCLES    = 5'd1,    // cycles Vector Unit is active
        VCNT_FASTPATH_IN    = 5'd2,    // capsules received via fast path
        VCNT_FASTPATH_OUT   = 5'd3,    // capsules sent via fast path
        VCNT_FASTPATH_MISS  = 5'd4,    // fast path ingress rejected
        VCNT_KEEP_LOCAL     = 5'd5,    // results kept in local SRAM
        VCNT_WRITEBACK      = 5'd6,    // results written back (cross-PE)
        VCNT_ESCAPE         = 5'd7,    // ops forwarded to escape path
        VCNT_RENORM         = 5'd8,    // renorm operations executed
        VCNT_REQUANT        = 5'd9,    // requant operations executed
        VCNT_REDUCE_MAX     = 5'd10,   // reduce_max operations
        VCNT_REDUCE_SUM     = 5'd11,   // reduce_sum operations
        VCNT_BLOCK16        = 5'd12,   // ops with block_size=16
        VCNT_BLOCK32        = 5'd13,   // ops with block_size=32
        VCNT_SCALE_E8M0     = 5'd14,   // ops with scale_format=E8M0
        VCNT_SCALE_E4M3     = 5'd15,   // ops with scale_format=E4M3
        VCNT_SCALE_STALL    = 5'd16    // cycles stalled on scale adapter
    } vec_perf_idx_e;

    // =========================================================================
    // 10. Shifter Parameters
    //
    // Used by vec_tz_shifter (independent copy of upe_tz_shifter for Vector
    // layer isolation). These match UPE conventions but are independently
    // defined to avoid cross-layer coupling.
    //
    // VEC_SHIFT_WIDTH:  operand width for LANE alignment shifter
    //                   (VEC_MANT_W + 4 = 20 bits: 16 mant + 4 guard)
    //                   This is for per-element alignment in vec_lane_array.
    //                   NOT the same as REDUCE_W (which is the reduce tree width).
    // VEC_SHIFT_MAX:    clamp threshold (shifts beyond this flush to zero)
    // =========================================================================

    parameter int VEC_SHIFT_WIDTH = VEC_MANT_W + 4;   // 20 bits (16 mant + 4 guard)
    parameter int VEC_SHIFT_MAX   = VEC_SHIFT_WIDTH;   // clamp at full width

    // =========================================================================
    // 10b. Layout Tag Constants (CL-7)
    //
    // Well-known layout_tag values for capsule contract semantics.
    // These are checked by downstream consumers to interpret payload format.
    // =========================================================================
    localparam logic [3:0] LAYOUT_BLOCK_FRAGMENT = 4'd0;  // normal block fragment
    localparam logic [3:0] LAYOUT_SCALAR_REDUCE  = 4'd1;  // scalar reduction result
    localparam logic [3:0] LAYOUT_RESERVED       = 4'hF;  // invalid / sentinel

    // =========================================================================
    // 10c. Reduce Result Capsule Contract (CL-7)
    //
    // When Vector Unit outputs a reduce result (REDUCE_MAX, REDUCE_SUM,
    // RMSNORM_PARTIAL), the capsule carries a SCALAR value, not a block fragment.
    // The payload format differs from normal capsules:
    //
    //   payload[REDUCE_W-1:0]                  = reduce mant (21 bits)
    //   payload[REDUCE_W+VEC_EXP_W-1:REDUCE_W] = reduce exp  (10 bits)
    //   payload[BS_CAP_PAYLOAD_W-1:REDUCE_W+VEC_EXP_W] = zero-padded
    //
    // Consumer rules:
    //   - layout_tag == LAYOUT_SCALAR_REDUCE → interpret as scalar
    //   - block_size retains original value (context for "reduced N elements")
    //   - fwd_eligible should be 0: reduce results typically need software
    //     interpretation and should NOT be direct-forwarded to Tensor Unit
    //     (Tensor expects block fragments, not scalars)
    //   - Downstream can check layout_tag before attempting to use payload
    //     as element array (which would be semantically wrong for a scalar)
    // =========================================================================

    // =========================================================================
    // 11. Helper Functions
    // =========================================================================

    // Check if a primitive is in the MVP set (v1 implemented)
    function automatic logic is_mvp_primitive(input vec_primitive_e p);
        case (p)
            VEC_RENORM,
            VEC_PACK,
            VEC_UNPACK,
            VEC_SPLIT,
            VEC_MERGE,
            VEC_RESADD,
            VEC_REDUCE_MAX,
            VEC_REDUCE_SUM,
            VEC_RMSNORM_PARTIAL,
            VEC_MOE_DISPATCH_PACK:
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    // Derive operation class from primitive
    function automatic vec_op_class_e class_from_primitive(input vec_primitive_e p);
        case (p)
            VEC_NOP:
                return VCLASS_NOP;
            VEC_PACK, VEC_UNPACK, VEC_SPLIT, VEC_MERGE,
            VEC_LAYOUT_RETAG, VEC_GATHER_INBLOCK, VEC_SCATTER_INBLOCK:
                return VCLASS_TRANSFORM;
            VEC_RESADD, VEC_BIASADD, VEC_CLAMP, VEC_ABS,
            VEC_MAX_ELEM, VEC_ACT_APPROX:
                return VCLASS_ARITHMETIC;
            VEC_REDUCE_MAX, VEC_REDUCE_SUM,
            VEC_RMSNORM_PARTIAL, VEC_LAYERNORM_PARTIAL:
                return VCLASS_REDUCE;
            VEC_RENORM, VEC_REQUANT, VEC_SCALE_REFRESH,
            VEC_BLOCK_SPLIT_REPACK, VEC_BLOCK_MERGE_REPACK:
                return VCLASS_RENORM;
            VEC_MOE_DISPATCH_PACK, VEC_ROUTE_PREP,
            VEC_EXPERT_LOCAL_REORDER:
                return VCLASS_ROUTE;
            VEC_SOFTMAX_PREP, VEC_FP_ASSIST_REDUCE,
            VEC_SPECIAL_ESCAPE:
                return VCLASS_ESCAPE;
            default:
                return VCLASS_NOP;
        endcase
    endfunction

    // Derive lane operation from primitive
    function automatic vec_lane_op_e lane_op_from_primitive(input vec_primitive_e p);
        case (p)
            VEC_NOP, VEC_PACK, VEC_UNPACK:
                return LANE_PASS;
            VEC_RESADD:
                return LANE_ADD;
            VEC_ABS:
                return LANE_ABS;
            VEC_CLAMP:
                return LANE_CLAMP;
            VEC_MAX_ELEM:
                return LANE_MAX;            // element-wise max(src0, src1)
            VEC_REDUCE_MAX:
                // Single-operand block reduction: pass elements through so the
                // reduce tree's value-correct pair_max does the max at the shared
                // block exponent. Routing through LANE_MAX (with src1==ZERO from
                // need_src1==0) would ReLU-clamp negatives to exp=0 phantom zeros
                // that then outrank real negative-exponent elements in the
                // exp-first tree => silent wrong max (HW review 2026-06-20, TIER-2).
                return LANE_REDUCE_P;
            VEC_SPLIT:
                return LANE_SPLIT;
            VEC_MERGE:
                return LANE_MERGE_LO;  // default; HI selected by address
            VEC_REDUCE_SUM, VEC_RMSNORM_PARTIAL:
                return LANE_REDUCE_P;
            default:
                return LANE_NOP;
        endcase
    endfunction

    // Derive reduce mode from primitive
    function automatic vec_reduce_mode_e reduce_mode_from_primitive(input vec_primitive_e p);
        case (p)
            VEC_REDUCE_MAX:
                return REDUCE_MAX;
            VEC_REDUCE_SUM:
                return REDUCE_SUM;
            VEC_RMSNORM_PARTIAL:
                return REDUCE_STAT;
            default:
                return REDUCE_NONE;
        endcase
    endfunction

    // Check if block_size_sel is supported in v1
    function automatic logic is_valid_block_size(input block_size_sel_e bs);
        return (bs == BLOCK_SIZE_16) || (bs == BLOCK_SIZE_32);
    endfunction

    // Check if scale_format is supported in v1
    function automatic logic is_valid_scale_format(input scale_format_e sf);
        return (sf == SCALE_E8M0) || (sf == SCALE_E4M3);
    endfunction

    // Get numeric block size from enum
    function automatic int block_size_value(input block_size_sel_e bs);
        case (bs)
            BLOCK_SIZE_16: return 16;
            BLOCK_SIZE_32: return 32;
            default:       return 32;  // fallback to baseline
        endcase
    endfunction

    // Compute number of VEC_LANES-wide passes needed for a block
    //   block_size=16, VEC_LANES=16 → 1
    //   block_size=32, VEC_LANES=16 → 2
    function automatic logic [1:0] passes_for_block(input block_size_sel_e bs);
        case (bs)
            BLOCK_SIZE_16: return (VEC_LANES >= 16) ? 2'd1 : 2'd2;
            BLOCK_SIZE_32: return (VEC_LANES >= 32) ? 2'd1 : 2'd2;
            default:       return 2'd1;
        endcase
    endfunction

    // Convenience: check if block_size requires multi-pass
    function automatic logic is_dual_pass(input block_size_sel_e bs);
        return passes_for_block(bs) > 2'd1;
    endfunction

    // Saturating increment (matches pe_pkg convention for perf counters)
    function automatic logic [PERF_CNT_W-1:0] vec_sat_inc(
        input logic [PERF_CNT_W-1:0] val
    );
        return (&val) ? val : val + 1'b1;
    endfunction

endpackage

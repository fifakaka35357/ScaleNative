// ============================================================================
// requantizer.sv — D9 per-cell block-float -> compact-mantissa narrowing
// ============================================================================
//
// Narrows ONE block-float cell (|mant|, exp, sign) to a signed target_mant_w
// integer aligned to the block's shared exponent. Combinational leaf; the
// tensor_result_packer (D2) drives VEC_LANES of these per row, maxes their
// eff_o to get shared_exp, and feeds it back to shared_exp_i (a pure
// combinational fan-in/fan-out, no loop since eff_o does not depend on
// shared_exp_i).
//
// [C8-a 2026-07-25] STRUCTURAL split into two sub-leaves + this wrapper:
//   requantizer_front — everything INDEPENDENT of shared_exp_i:
//                       lzc, normalized mantissa (norm_o), eff_o, zero/special.
//   requantizer_back  — everything DEPENDENT on shared_exp_i:
//                       INT align/round/clamp, FP re-encode, output mux.
//   requantizer       — front+back composed combinationally, ports UNCHANGED
//                       (Tensor consumers bit-identical by construction).
// Motive: vector_unit's ⑦ compact path registers the front outputs in
// VST_CMX_PREP1 (inputs are HELD result_cap_q values), halving the
// PREP-cycle encode cone (M2M3_AnchorPlan §C8-a). Pure retiming enabler —
// no arithmetic change in either half.
//
// FROZEN convention (oracle: Model/bfp_golden.py requantize_cell_int_golden,
// see Review/Step4_FastPath_Plan.md §3):
//   value = (-1)^sign * mant * 2^exp ;  eff = exp + (47 - lzc48(mant)).
//   W = target_mant_w in {16,8,4} ;  E_block = shared_exp - (W-2).
//   shift = E_block - exp  (right shift; left if negative).
//   q = round_{RTZ|RNE}(mant >> shift), clamped to signed W-bit, sign applied.
//   underflow when a NONZERO cell yields q == 0 (catastrophic precision loss).
//
// Supports all 6 combos {16,8,4} x {INT, FP}:
//   - INT (kind_fp_i=0): signed Wb mantissa (the W=16 Vector fast-path lane +
//     W=8/4 compact-MX storage).
//   - FP  (kind_fp_i=1): OFU-lite re-encode to FP4 E2M1 (W=4) / FP8 E4M3FN (W=8)
//     of value/2^shared_exp, normalize + round (RNE/RTZ) with subnormals,
//     matching the brute-force-grid golden. (W=16 FP = Class-C escape / full OFU,
//     out of scope here.)
// `fp_todo_o` is retained tied-0 for interface stability (FP is implemented).
// ============================================================================

// ----------------------------------------------------------------------------
// requantizer_front — shared_exp-INDEPENDENT half (lzc / norm / eff / flags)
// ----------------------------------------------------------------------------
module requantizer_front #(
    parameter int CELL_MANT_W = 48,
    parameter int EXP_W       = 12
) (
    input  logic [CELL_MANT_W-1:0]   cell_mant_i,
    input  logic signed [EXP_W-1:0]  cell_exp_i,
    input  logic                     cell_is_nan_i,
    input  logic                     cell_is_inf_i,

    output logic [CELL_MANT_W-1:0]   norm_o,        // 1.frac, leading 1 at bit 47
    output logic signed [EXP_W-1:0]  eff_o,         // cell effective exponent
    output logic                     is_zero_o,
    output logic                     is_special_o
);
    // --- leading-zero count of a 48-bit magnitude (0..48) ---
    function automatic logic [6:0] lzc48(input logic [CELL_MANT_W-1:0] m);
        logic [6:0] n;
        n = 7'(CELL_MANT_W);                  // 48 when m == 0
        for (int i = 0; i < CELL_MANT_W; i++)
            if (m[i]) n = 7'(CELL_MANT_W - 1) - 7'(i);  // highest set bit wins
        return n;
    endfunction

    logic [6:0] lzc;
    assign lzc          = lzc48(cell_mant_i);
    assign eff_o        = cell_exp_i + EXP_W'(signed'({1'b0, (7'd47 - lzc)}));
    assign norm_o       = cell_mant_i << lzc;   // 0 when mant==0 (zero handled downstream)
    assign is_special_o = cell_is_nan_i | cell_is_inf_i;
    assign is_zero_o    = (cell_mant_i == '0) & ~is_special_o;
endmodule

// ----------------------------------------------------------------------------
// requantizer_back_align — back ALIGN half (shared_exp-DEPENDENT alignment)
//
// [T1 2026-07-26] STRUCTURAL split of requantizer_back at the align|round/encode
// boundary (same pattern as the C8-a front/back cut, one level deeper):
//   requantizer_back_align  — everything up to the PRE-ROUND alignment product:
//                             INT shift/trunc/round-bit/sticky; FP rel_exp/
//                             e_unb/branch + variable-shift alignment down to
//                             the pre-round {mfield, rbit, sticky}.
//   requantizer_back_encode — round increment / carry / clamp / FP field
//                             assembly / output mux.
//   requantizer_back        — wrapper, align∘encode composed combinationally,
//                             ports and behavior UNCHANGED (Tensor consumers
//                             bit-identical by construction).
// Motive: vector_unit's ⑦ VST_CMX_PREP encode cone (back whole) measured
// 2175.75 ps @1670 signoff RC (m1v_c9s deployed wall, slack −223.36); the cut
// lets the consumer register the align products in a leading stage.
// fp_eunb_o is a 4-bit slice of the unbounded e_unb: the encode side's
// carry-increment-then-mask is mod-2^EBITS with EBITS <= 4, and 2^EBITS
// divides 16, so incrementing the mod-16 slice is exact for ALL inputs.
// ----------------------------------------------------------------------------
module requantizer_back_align #(
    parameter int CELL_MANT_W = 48,
    parameter int EXP_W       = 12
) (
    // raw cell (INT path only)
    input  logic [CELL_MANT_W-1:0]   cell_mant_i,
    input  logic signed [EXP_W-1:0]  cell_exp_i,
    // front outputs (FP path)
    input  logic [CELL_MANT_W-1:0]   norm_i,
    input  logic signed [EXP_W-1:0]  eff_i,
    // block context + per-op config
    input  logic signed [EXP_W-1:0]  shared_exp_i,
    input  logic [1:0]               target_w_sel_i,

    // INT pre-round alignment product
    output logic [63:0]              int_trunc_o,
    output logic                     int_rbit_o,
    output logic                     int_sticky_o,
    // FP pre-round alignment product
    output logic [4:0]               fp_mfield_o,   // {carry headroom, 1, m[MW-1:0]}
    output logic                     fp_rbit_o,
    output logic                     fp_stick_o,
    output logic [3:0]               fp_eunb_o,     // normal branch only (mod-16 slice)
    output logic                     fp_normal_o
);
    localparam int MAXSH = CELL_MANT_W + 4;   // beyond this every bit is dropped

    // --- target width W from the selector ---
    logic [4:0] w_bits;
    always_comb begin
        unique case (target_w_sel_i)
            2'd0:    w_bits = 5'd4;
            2'd1:    w_bits = 5'd8;
            default: w_bits = 5'd16;
        endcase
    end

    // --- INT path: per-cell shift from the shared block exponent ---
    logic signed [EXP_W-1:0] e_block, shift;
    assign e_block = shared_exp_i - EXP_W'(signed'({1'b0, (w_bits - 5'd2)}));
    assign shift   = e_block - cell_exp_i;

    // --- INT align (round/clamp live in the encode half) ---
    logic [63:0] mant64, lowmask;
    logic [EXP_W-1:0] rsh, lsh;
    assign mant64 = {{(64-CELL_MANT_W){1'b0}}, cell_mant_i};

    always_comb begin
        int_trunc_o = 64'd0; int_rbit_o = 1'b0; int_sticky_o = 1'b0;
        rsh = '0; lsh = '0; lowmask = 64'd0;
        if (shift <= 0) begin                      // left shift (or zero)
            lsh         = (-shift > EXP_W'(MAXSH)) ? EXP_W'(MAXSH) : EXP_W'(-shift);
            int_trunc_o = mant64 << lsh;           // clamped in the encode half
        end else if (shift > EXP_W'(MAXSH)) begin  // fully dropped
            int_trunc_o = 64'd0; int_rbit_o = 1'b0; int_sticky_o = |cell_mant_i;
        end else begin                             // right shift in [1..MAXSH]
            rsh          = EXP_W'(shift);
            int_trunc_o  = mant64 >> rsh;
            int_rbit_o   = mant64[rsh - 1];
            lowmask      = (rsh >= 2) ? ((64'd1 << (rsh - 1)) - 64'd1) : 64'd0;
            int_sticky_o = |(mant64 & lowmask);
        end
    end

    // ------------------------------------------------------------------
    // FP align (MXFP) — value/2^shared = 1.frac * 2^rel_exp, rel_exp =
    // eff - shared_exp (<= 0). Normal/subnormal branch + alignment shift
    // down to the pre-round {mfield, rbit, sticky}; round/assembly live
    // in the encode half. Matches the pre-split fp_encode_mag line-for-line
    // up to the round increment.
    // ------------------------------------------------------------------
    logic signed [EXP_W-1:0] rel_exp;
    assign rel_exp = eff_i - shared_exp_i;

    // pack: {normal, e_unb[3:0], mfield[4:0], rbit, stick}
    function automatic logic [11:0] fp_align_mag(
        input logic [CELL_MANT_W-1:0] nrm,      // leading 1 at bit 47
        input logic signed [EXP_W-1:0] rexp,
        input int MW, input int BIAS
    );
        logic signed [EXP_W-1:0] e_unb;
        logic [CELL_MANT_W-1:0] man;
        logic [63:0] low_mask;
        logic [4:0]  mfield;                    // {1, m[MW-1:0]} + round carry headroom
        logic        rbit, stick, nrml;
        int          sh;
        e_unb = rexp + EXP_W'(BIAS);
        if (e_unb >= 1) begin
            // ---- normal: top MW fraction bits = nrm[46 : 47-MW] ----
            nrml     = 1'b1;
            man      = nrm >> (47 - MW);
            rbit     = nrm[46 - MW];
            low_mask = (64'd1 << (46 - MW)) - 64'd1;
            stick    = |(nrm & low_mask[CELL_MANT_W-1:0]);
        end else begin
            // ---- subnormal: M = round(1.frac * 2^(e_unb-1+MW)) = nrm >> sh ----
            nrml = 1'b0;
            sh = 48 - MW - int'(e_unb);          // >= 48-MW
            if (sh >= CELL_MANT_W) begin
                man   = '0;
                rbit  = (sh == CELL_MANT_W) ? nrm[CELL_MANT_W-1] : 1'b0;
                low_mask = (sh == CELL_MANT_W)
                         ? ((64'd1 << (CELL_MANT_W - 1)) - 64'd1) : {64{1'b1}};
                stick = |(nrm & low_mask[CELL_MANT_W-1:0]);
            end else begin
                man      = nrm >> sh;
                rbit     = (sh >= 1) ? nrm[(sh > 0) ? (sh - 1) : 0] : 1'b0;
                low_mask = (sh >= 2) ? ((64'd1 << (sh - 1)) - 64'd1) : 64'd0;
                stick    = |(nrm & low_mask[CELL_MANT_W-1:0]);
            end
        end
        mfield = man[4:0] & 5'((1 << (MW + 1)) - 1);   // {1, m[MW-1:0]}, hidden 1 at bit MW
        return {nrml, e_unb[3:0], mfield, rbit, stick};
    endfunction

    logic [11:0] fp_al;
    always_comb begin
        if (target_w_sel_i == 2'd0)             // W=4 -> FP4 E2M1
            fp_al = fp_align_mag(norm_i, rel_exp, 1, 1);
        else                                     // W=8 -> FP8 E4M3FN
            fp_al = fp_align_mag(norm_i, rel_exp, 3, 7);
    end
    assign {fp_normal_o, fp_eunb_o, fp_mfield_o, fp_rbit_o, fp_stick_o} = fp_al;
endmodule

// ----------------------------------------------------------------------------
// requantizer_back_encode — back ROUND/ENCODE half (see the [T1] split header)
// ----------------------------------------------------------------------------
module requantizer_back_encode #(
    parameter int CELL_MANT_W = 48,
    parameter int EXP_W       = 12,
    parameter int OUT_W       = 16
) (
    // INT pre-round alignment product (possibly REGISTERED by the consumer)
    input  logic [63:0]              int_trunc_i,
    input  logic                     int_rbit_i,
    input  logic                     int_sticky_i,
    // FP pre-round alignment product (possibly REGISTERED by the consumer)
    input  logic [4:0]               fp_mfield_i,
    input  logic                     fp_rbit_i,
    input  logic                     fp_stick_i,
    input  logic [3:0]               fp_eunb_i,
    input  logic                     fp_normal_i,
    // held cell flags + per-op config
    input  logic                     cell_sign_i,
    input  logic                     is_zero_i,
    input  logic                     is_special_i,
    input  logic [1:0]               target_w_sel_i,
    input  logic                     kind_fp_i,
    input  logic                     round_rne_i,

    output logic signed [OUT_W-1:0]  elem_o,
    output logic                     underflow_o,
    output logic                     zero_o,
    output logic                     special_o,
    output logic                     fp_todo_o
);
    // --- target width W from the selector ---
    logic [4:0] w_bits;
    always_comb begin
        unique case (target_w_sel_i)
            2'd0:    w_bits = 5'd4;
            2'd1:    w_bits = 5'd8;
            default: w_bits = 5'd16;
        endcase
    end

    // --- INT round ---
    logic [63:0] qmag_raw;
    logic        round_up;
    always_comb begin
        round_up = round_rne_i & int_rbit_i & (int_sticky_i | int_trunc_i[0]);
        qmag_raw = int_trunc_i + (round_up ? 64'd1 : 64'd0);
    end

    // --- clamp to W-bit signed and apply sign ---
    logic [63:0] qmax_mag, qmin_mag, qmag_clamped;
    assign qmax_mag = (64'd1 << (w_bits - 5'd1)) - 64'd1;   //  2^(W-1)-1
    assign qmin_mag = (64'd1 << (w_bits - 5'd1));           //  2^(W-1)
    always_comb begin
        if (cell_sign_i)
            qmag_clamped = (qmag_raw > qmin_mag) ? qmin_mag : qmag_raw;
        else
            qmag_clamped = (qmag_raw > qmax_mag) ? qmax_mag : qmag_raw;
    end

    // --- FP round + field assembly (pre-split fp_encode_mag, post-align part).
    // eunb is the mod-16 slice; the increment-then-mask below is mod-2^EBITS
    // (EBITS <= 4, 2^EBITS | 16) so the slice arithmetic is exact.
    function automatic logic [7:0] fp_round_mag(
        input logic [4:0] mfield_i,
        input logic rbit, input logic stick,
        input logic [3:0] eunb, input logic nrml,
        input int MW, input int EBITS, input logic rne,
        output logic underflow
    );
        logic [4:0] mfield;
        logic [4:0] eunb5;                      // slice + carry headroom
        logic       rup;
        logic [7:0] mmask;
        underflow = 1'b0;
        mmask  = 8'((1 << MW) - 1);
        rup    = rne & rbit & (stick | mfield_i[0]);
        mfield = mfield_i + (rup ? 5'd1 : 5'd0);
        if (nrml) begin
            eunb5 = {1'b0, eunb};
            if (mfield[MW + 1]) eunb5 = eunb5 + 5'd1;        // round CARRY -> exp++
            return 8'((eunb5 & 5'((1 << EBITS) - 1)) << MW) | (8'(mfield) & mmask);
        end else begin
            if (mfield[MW])                                  // -> smallest normal E=1,m=0
                return 8'(1 << MW);
            if ((8'(mfield) & mmask) == 8'd0) underflow = 1'b1;
            return 8'(mfield) & mmask;                       // E=0, mantissa
        end
    endfunction

    logic [7:0] fp_mag;
    logic       fp_uf;
    always_comb begin
        fp_mag = 8'd0; fp_uf = 1'b0;
        if (kind_fp_i && !is_special_i && !is_zero_i) begin
            if (target_w_sel_i == 2'd0)         // W=4 -> FP4 E2M1
                fp_mag = fp_round_mag(fp_mfield_i, fp_rbit_i, fp_stick_i,
                                      fp_eunb_i, fp_normal_i, 1, 2, round_rne_i, fp_uf);
            else                                 // W=8 -> FP8 E4M3FN
                fp_mag = fp_round_mag(fp_mfield_i, fp_rbit_i, fp_stick_i,
                                      fp_eunb_i, fp_normal_i, 3, 4, round_rne_i, fp_uf);
        end
    end

    // sign-bit position within the FP element (FP4: bit 3, FP8: bit 7)
    logic [3:0] fp_sign_pos;
    assign fp_sign_pos = (target_w_sel_i == 2'd0) ? 4'd3 : 4'd7;

    always_comb begin
        if (is_special_i || is_zero_i) begin
            elem_o = '0;
        end else if (kind_fp_i) begin           // FP element, right-aligned + sign
            elem_o = OUT_W'(fp_mag | (logic'(cell_sign_i) << fp_sign_pos));
        end else if (cell_sign_i) begin         // INT, signed
            elem_o = -OUT_W'(signed'(qmag_clamped[OUT_W-1:0]));
        end else begin
            elem_o = OUT_W'(signed'({1'b0, qmag_clamped[OUT_W-2:0]}));
        end
    end

    assign zero_o      = is_zero_i;
    assign special_o   = is_special_i;
    assign fp_todo_o   = 1'b0;                   // FP now implemented
    assign underflow_o = ~is_special_i & ~is_zero_i &
                         (kind_fp_i ? fp_uf : (qmag_clamped == 64'd0));
endmodule

// ----------------------------------------------------------------------------
// requantizer_back — shared_exp-DEPENDENT half. [T1] now a WRAPPER: align ∘
// encode composed combinationally; ports and behavior UNCHANGED.
// ----------------------------------------------------------------------------
module requantizer_back #(
    parameter int CELL_MANT_W = 48,
    parameter int EXP_W       = 12,
    parameter int OUT_W       = 16
) (
    // raw cell (INT path only; FP path consumes norm_i/eff_i)
    input  logic [CELL_MANT_W-1:0]   cell_mant_i,
    input  logic signed [EXP_W-1:0]  cell_exp_i,
    input  logic                     cell_sign_i,
    // front outputs (possibly REGISTERED by the consumer — the C8-a cut)
    input  logic [CELL_MANT_W-1:0]   norm_i,
    input  logic signed [EXP_W-1:0]  eff_i,
    input  logic                     is_zero_i,
    input  logic                     is_special_i,
    // block context + per-op config
    input  logic signed [EXP_W-1:0]  shared_exp_i,
    input  logic [1:0]               target_w_sel_i,
    input  logic                     kind_fp_i,
    input  logic                     round_rne_i,

    output logic signed [OUT_W-1:0]  elem_o,
    output logic                     underflow_o,
    output logic                     zero_o,
    output logic                     special_o,
    output logic                     fp_todo_o
);
    logic [63:0] int_trunc_w;
    logic        int_rbit_w, int_sticky_w;
    logic [4:0]  fp_mfield_w;
    logic        fp_rbit_w, fp_stick_w, fp_normal_w;
    logic [3:0]  fp_eunb_w;

    requantizer_back_align #(
        .CELL_MANT_W ( CELL_MANT_W ),
        .EXP_W       ( EXP_W       )
    ) u_align (
        .cell_mant_i    ( cell_mant_i    ),
        .cell_exp_i     ( cell_exp_i     ),
        .norm_i         ( norm_i         ),
        .eff_i          ( eff_i          ),
        .shared_exp_i   ( shared_exp_i   ),
        .target_w_sel_i ( target_w_sel_i ),
        .int_trunc_o    ( int_trunc_w    ),
        .int_rbit_o     ( int_rbit_w     ),
        .int_sticky_o   ( int_sticky_w   ),
        .fp_mfield_o    ( fp_mfield_w    ),
        .fp_rbit_o      ( fp_rbit_w      ),
        .fp_stick_o     ( fp_stick_w     ),
        .fp_eunb_o      ( fp_eunb_w      ),
        .fp_normal_o    ( fp_normal_w    )
    );

    requantizer_back_encode #(
        .CELL_MANT_W ( CELL_MANT_W ),
        .EXP_W       ( EXP_W       ),
        .OUT_W       ( OUT_W       )
    ) u_encode (
        .int_trunc_i    ( int_trunc_w    ),
        .int_rbit_i     ( int_rbit_w     ),
        .int_sticky_i   ( int_sticky_w   ),
        .fp_mfield_i    ( fp_mfield_w    ),
        .fp_rbit_i      ( fp_rbit_w      ),
        .fp_stick_i     ( fp_stick_w     ),
        .fp_eunb_i      ( fp_eunb_w      ),
        .fp_normal_i    ( fp_normal_w    ),
        .cell_sign_i    ( cell_sign_i    ),
        .is_zero_i      ( is_zero_i      ),
        .is_special_i   ( is_special_i   ),
        .target_w_sel_i ( target_w_sel_i ),
        .kind_fp_i      ( kind_fp_i      ),
        .round_rne_i    ( round_rne_i    ),
        .elem_o         ( elem_o         ),
        .underflow_o    ( underflow_o    ),
        .zero_o         ( zero_o         ),
        .special_o      ( special_o      ),
        .fp_todo_o      ( fp_todo_o      )
    );
endmodule

// ----------------------------------------------------------------------------
// requantizer — original single-cycle leaf: front + back composed. Ports and
// behavior UNCHANGED (Tensor consumers are bit-identical by construction).
// ----------------------------------------------------------------------------
module requantizer #(
    parameter int CELL_MANT_W = 48,    // |mantissa| width (fp_acc_output_t)
    parameter int EXP_W       = 12,    // widened intermediate exponent (M37 style)
    parameter int OUT_W       = 16     // max output element width (= VEC_MANT_W)
) (
    // --- per-cell block-float input (unpacked fp_acc_output_t) ---
    input  logic [CELL_MANT_W-1:0]   cell_mant_i,    // |mantissa| unsigned
    input  logic signed [EXP_W-1:0]  cell_exp_i,     // cell exponent (sign-ext from 10b)
    input  logic                     cell_sign_i,
    input  logic                     cell_is_nan_i,
    input  logic                     cell_is_inf_i,
    // --- block context (from the packer's max over eff_o) ---
    input  logic signed [EXP_W-1:0]  shared_exp_i,   // block max eff exponent
    // --- per-op config (from elem_fmt / descriptor) ---
    input  logic [1:0]               target_w_sel_i, // 0:W=4  1:W=8  2:W=16
    input  logic                     kind_fp_i,      // 0:INT  1:FP (TODO)
    input  logic                     round_rne_i,    // 0:RTZ  1:RNE
    // --- outputs ---
    output logic signed [EXP_W-1:0]  eff_o,          // this cell's eff (for the max scan)
    output logic signed [OUT_W-1:0]  elem_o,         // narrowed signed mantissa
    output logic                     underflow_o,    // nonzero cell -> zero output
    output logic                     zero_o,         // input cell was zero
    output logic                     special_o,      // cell is NaN/Inf (passthrough)
    output logic                     fp_todo_o       // FP kind requested (not yet impl)
);
    logic [CELL_MANT_W-1:0] norm_w;
    logic                   is_zero_w, is_special_w;

    requantizer_front #(
        .CELL_MANT_W ( CELL_MANT_W ),
        .EXP_W       ( EXP_W       )
    ) u_front (
        .cell_mant_i   ( cell_mant_i   ),
        .cell_exp_i    ( cell_exp_i    ),
        .cell_is_nan_i ( cell_is_nan_i ),
        .cell_is_inf_i ( cell_is_inf_i ),
        .norm_o        ( norm_w        ),
        .eff_o         ( eff_o         ),
        .is_zero_o     ( is_zero_w     ),
        .is_special_o  ( is_special_w  )
    );

    requantizer_back #(
        .CELL_MANT_W ( CELL_MANT_W ),
        .EXP_W       ( EXP_W       ),
        .OUT_W       ( OUT_W       )
    ) u_back (
        .cell_mant_i    ( cell_mant_i    ),
        .cell_exp_i     ( cell_exp_i     ),
        .cell_sign_i    ( cell_sign_i    ),
        .norm_i         ( norm_w         ),
        .eff_i          ( eff_o          ),
        .is_zero_i      ( is_zero_w      ),
        .is_special_i   ( is_special_w   ),
        .shared_exp_i   ( shared_exp_i   ),
        .target_w_sel_i ( target_w_sel_i ),
        .kind_fp_i      ( kind_fp_i      ),
        .round_rne_i    ( round_rne_i    ),
        .elem_o         ( elem_o         ),
        .underflow_o    ( underflow_o    ),
        .zero_o         ( zero_o         ),
        .special_o      ( special_o      ),
        .fp_todo_o      ( fp_todo_o      )
    );
endmodule

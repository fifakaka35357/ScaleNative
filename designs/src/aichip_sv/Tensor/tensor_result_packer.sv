// ============================================================================
// tensor_result_packer.sv — D2 capsule formation (48b -> 16b, row -> capsule)
// ============================================================================
//
// Consumes ONE egress row of LANES (=16) block-float cells (fp_acc_output_t,
// raw from tensor_egress_fragmentizer) and forms ONE block16 fast-path capsule
// (bs_capsule_t). The row = C[i][0..15] = 16 output channels of one token =
// a natural block16 MX block (Design_Notes N5).
//
// Combinational, two structural passes in one cycle (no real loop — eff is
// computed here from inputs only; it feeds shared_exp which feeds the
// requantizer narrowing):
//   1. eff[i] = exp + (47 - lzc48(mant)) per nonzero cell; shared_exp = max,
//      min_exp = min over nonzero cells.
//   2. 16x requantizer (D9 leaf) narrow each cell to a signed VEC_MANT_W=16
//      mantissa aligned to shared_exp; pack into payload[255:0].
// ESCAPE (D2 valve): spread = shared-min > spread_limit (14 for W=16) OR any
//   lane underflows OR block NaN/Inf -> escape_o=1 (caller routes Class C and
//   does NOT forward this capsule). The capsule_o fields are still driven (for
//   the non-escape path) so the egress MUX can mux on escape_o.
//
// block32 (D8, Q8 two independent per-window exps) is handled by sequencing TWO
// invocations (one per 16-window) in the egress controller — out of this leaf.
//
// Oracle: Model/bfp_golden.py capsule_form_golden. See Step4_FastPath_Plan.md §4.
// ============================================================================

module tensor_result_packer
    import pe_pkg::*;
#(
    parameter int LANES = 16,
    parameter int EXP_W = 12
) (
    // --- one egress row of 16 block-float cells (packed fp_acc_output_t) ---
    input  tensor_pkg::fp_acc_output_t  cells_i [LANES],
    // --- descriptor-derived metadata (from tile_desc_scan_q) ---
    input  logic [1:0]              target_w_sel_i,   // 2 = W16 (Vector fast-path lane)
    input  logic                    kind_fp_i,        // 0 = INT lane (fast path)
    input  logic                    round_rne_i,      // 0 = RTZ (tz_shifter)
    input  block_size_sel_e         block_size_i,
    input  scale_format_e           scale_format_i,
    input  logic [7:0]              scale_epoch_i,
    input  logic [CTX_ID_W-1:0]     ctx_id_i,
    input  logic [TAG_W-1:0]        tag_i,
    input  elem_fmt_e               elem_fmt_i,
    input  operand_role_e           operand_role_i,
    input  logic [3:0]              spread_limit_i,   // 14 for W=16
    // --- outputs ---
    output bs_capsule_t             capsule_o,
    output logic                    escape_o,         // route Class C instead of forwarding
    output logic                    all_zero_o,
    output logic                    block_nan_o,
    output logic                    block_inf_o
);

    localparam int MANT_W = 48;

    function automatic logic [6:0] lzc48(input logic [MANT_W-1:0] m);
        logic [6:0] n;
        n = 7'(MANT_W);
        for (int i = 0; i < MANT_W; i++)
            if (m[i]) n = 7'(MANT_W - 1) - 7'(i);
        return n;
    endfunction

    // --- unpack cells + per-lane eff / status ---
    logic [MANT_W-1:0]       mant [LANES];
    logic signed [EXP_W-1:0] cexp [LANES];
    logic                    csign [LANES];
    logic signed [EXP_W-1:0] eff  [LANES];
    logic [LANES-1:0]        lane_nz, lane_nan, lane_inf;

    for (genvar i = 0; i < LANES; i++) begin : g_unpack
        assign mant[i]     = cells_i[i].mant;
        assign cexp[i]     = EXP_W'(signed'(cells_i[i].exp));
        assign csign[i]    = cells_i[i].sign;
        assign lane_nan[i] = cells_i[i].is_nan;
        assign lane_inf[i] = cells_i[i].is_inf & ~cells_i[i].is_nan;
        assign lane_nz[i]  = (cells_i[i].mant != '0) & ~cells_i[i].is_nan & ~cells_i[i].is_inf;
        assign eff[i]      = cexp[i] + EXP_W'(signed'({1'b0, (7'd47 - lzc48(mant[i]))}));
    end

    // --- shared_exp = max eff, min_exp = min eff over nonzero cells ---
    //
    // [S4 KNIFE-1, 2026-09-06] The 16-iteration SERIAL masked max/min scan was
    // rewritten as a balanced pairwise (valid,max,min) tree (16->8->4->2->1,
    // depth 4). MEASURED, not assumed: on the pe_top binding path this scan is
    // 3114.48 ps = 48.7% of u_result_packer's 6394.88 ps and 32.9% of the whole
    // 9479.77 ps data segment, with cross-lane logic depth climbing 11 -> 117
    // across 15 accumulate steps -- i.e. ABC had NOT re-balanced it.
    // Evidence: soc600_prereg_20260902.md §40.1; executor
    // aichip_run_logs/s4_packer_segdecomp_20260906.py (1 positive + 1 negative
    // + 1 ordering gate, all green).
    //
    // BIT-IDENTICAL: max/min are associative + commutative, an invalid leaf never
    // wins a combine, and the !any_nz -> '0 fixup below is kept verbatim. This is
    // a value-preserving COMBINATIONAL restructure: no clk, no port, no DFF, so
    // it does NOT touch the deferred "packer pipelining" decision.
    // Same-repo reference implementation (same masked (valid,max,min) semantics):
    //   Vector/Unchanged/Vector/vec_renorm_quant.sv:121-133.
    logic                    rq_v  [LANES];
    logic signed [EXP_W-1:0] rq_mx [LANES];   // don't-care when !rq_v[i]
    logic signed [EXP_W-1:0] rq_mn [LANES];
    logic signed [EXP_W-1:0] shared_exp, min_exp;
    logic                    any_nz;
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            rq_v[i]  = lane_nz[i];
            rq_mx[i] = eff[i];
            rq_mn[i] = eff[i];
        end
        // balanced pairwise combine, halving each level: 16 -> 8 -> 4 -> 2 -> 1
        for (int span = 1; span < LANES; span = span << 1) begin
            for (int i = 0; i + span < LANES; i = i + (span << 1)) begin
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
        any_nz = rq_v[0];
        if (any_nz) begin
            shared_exp = rq_mx[0];
            min_exp    = rq_mn[0];
        end else begin
            // No nonzero cells: same defaults the serial scan produced.
            shared_exp = '0;
            min_exp    = '0;
        end
    end

    // --- 16x requantizer leaf (narrow given shared_exp) ---
    logic signed [15:0] elem  [LANES];
    logic [LANES-1:0]   lane_uf;
    for (genvar i = 0; i < LANES; i++) begin : g_rq
        logic uf_i, zero_i, special_i, fp_todo_i;
        logic signed [EXP_W-1:0] eff_unused;
        requantizer #(.CELL_MANT_W(MANT_W), .EXP_W(EXP_W), .OUT_W(16)) u_rq (
            .cell_mant_i   (mant[i]),
            .cell_exp_i    (cexp[i]),
            .cell_sign_i   (csign[i]),
            .cell_is_nan_i (lane_nan[i]),
            .cell_is_inf_i (lane_inf[i]),
            .shared_exp_i  (shared_exp),
            .target_w_sel_i(target_w_sel_i),
            .kind_fp_i     (kind_fp_i),
            .round_rne_i   (round_rne_i),
            .eff_o         (eff_unused),
            .elem_o        (elem[i]),
            .underflow_o   (uf_i),
            .zero_o        (zero_i),
            .special_o     (special_i),
            .fp_todo_o     (fp_todo_i)
        );
        assign lane_uf[i] = uf_i;
    end

    // --- block-scale byte (E8M0 / E4M3) for inline_scale ---
    // INT: ref_exp = shared_exp - (W-2) ; FP: ref_exp = shared_exp.
    logic [4:0]              w_bits;
    logic signed [EXP_W-1:0] ref_exp, e4m3_e;
    logic [7:0]              scale_byte;
    always_comb begin
        unique case (target_w_sel_i)
            2'd0:    w_bits = 5'd4;
            2'd1:    w_bits = 5'd8;
            default: w_bits = 5'd16;
        endcase
        ref_exp = kind_fp_i ? shared_exp
                            : (shared_exp - EXP_W'(signed'({1'b0, (w_bits - 5'd2)})));
        if (scale_format_i == SCALE_E4M3) begin
            // E4M3 block scale (mant 0): biased exp = ref_exp+7, CLAMPED to the
            // E4M3 normal range [1,15] (matches Model/bfp_golden.py _e4m3_scale_encode).
            // A bare mask would wrap for ref_exp out of range (review-gate finding).
            e4m3_e = ref_exp + 12'sd7;
            if (e4m3_e < 12'sd1)        e4m3_e = 12'sd1;
            else if (e4m3_e > 12'sd15)  e4m3_e = 12'sd15;
            scale_byte = 8'(e4m3_e << 3);
        end else begin
            scale_byte = 8'(ref_exp + 12'sd127);                  // E8M0
        end
    end

    // --- assemble bs_capsule_t ---
    logic [BS_CAP_PAYLOAD_W-1:0] payload;
    always_comb begin
        payload = '0;
        for (int i = 0; i < LANES; i++)
            payload[i*16 +: 16] = elem[i];
    end

    assign block_nan_o = |lane_nan;
    assign block_inf_o = |lane_inf & ~|lane_nan;
    assign all_zero_o  = ~any_nz & ~|lane_nan & ~|lane_inf;
    assign escape_o    = (any_nz & ($signed(shared_exp - min_exp) > $signed(EXP_W'({8'b0, spread_limit_i}))))
                       | (|lane_uf) | block_nan_o | block_inf_o;

    always_comb begin
        capsule_o = '0;
        capsule_o.payload            = payload;
        capsule_o.elem_fmt           = elem_fmt_i;
        capsule_o.block_size         = block_size_i;
        capsule_o.scale_format       = scale_format_i;
        capsule_o.layout_tag         = 4'd0;                  // LAYOUT_BLOCK_FRAGMENT
        // [HW-REVIEW T3] E4M3 block16 carries the ABSOLUTE block exponent in scale_ref
        // + inline_scale[8] (BS_ABS_EXP_BIT); the E4M3 byte stays the clamped external /
        // NVFP4 carrier (mant_corr). Without this, ref_exp outside the 4-bit E4M3 window
        // [-6,8] clamps and the RESADD silently misaligns by powers of two. E8M0 keeps
        // its wide 8-bit byte (no clamp) = legacy carrier, bit8=0.
        if (scale_format_i == SCALE_E4M3 && any_nz) begin
            capsule_o.scale_ref    = 16'(signed'(ref_exp));   // unclamped abs block exp
            capsule_o.inline_scale = {23'd0, 1'b1, scale_byte};
        end else begin
            // E8M0 (wide byte), OR an all-zero E4M3 block: no absolute exponent is
            // meaningful (all_zero_o=1, payload=0), so bit8=0 / scale_ref=0 (matches the
            // golden true_ref_exp=None for an empty block).
            capsule_o.scale_ref    = 16'd0;
            capsule_o.inline_scale = 32'(scale_byte);
        end
        capsule_o.scale_inline_valid = 1'b1;
        capsule_o.scale_epoch        = scale_epoch_i;
        capsule_o.round_sat_policy   = {3'd0, round_rne_i};
        capsule_o.escape_hint        = 2'd0;
        capsule_o.dest_hint          = DEST_VECTOR;
        capsule_o.fwd_eligible       = 1'b1;
        capsule_o.multi_consumer     = 1'b0;
        capsule_o.operand_role       = operand_role_i;
        capsule_o.ctx_id             = ctx_id_i;
        capsule_o.tag                = tag_i;
        capsule_o.producer           = DOMAIN_TENSOR;
        capsule_o.status_flags       = {6'd0, block_inf_o, block_nan_o};
    end

endmodule

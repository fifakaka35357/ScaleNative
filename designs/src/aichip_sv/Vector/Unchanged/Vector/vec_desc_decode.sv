// =============================================================================
// vec_desc_decode.sv — Execution Descriptor Decoder (Vector Unit, v2)
//
// Pure combinational module that decodes vec_exec_desc_t into the vec_ctrl_t
// pipeline control bus consumed by all downstream sub-modules.
//
// v2 changes from v1:
//   - Outputs num_passes (1 or 2) derived from block_size and VEC_LANES
//   - VEC_LANES=16: block_size=16 → 1 pass, block_size=32 → 2 passes
//   - Stage enables are per-pass (total switch); vector_unit FSM iterates
//
// Responsibilities:
//   1. Field validation: block_size, scale_format, primitive support
//   2. Primitive → pipeline stage enable mapping
//   3. Primitive → lane_op / reduce_mode derivation (via vec_pkg helpers)
//   4. Operand requirement determination (need_src0, need_src1)
//   5. Multi-pass computation: num_passes from block_size + VEC_LANES
//   6. Error detection and reporting
//
// Validation order (first error wins):
//   1. Bad block_size   → VERR_BAD_BLOCK_SIZE
//   2. Bad scale_format → VERR_BAD_SCALE_FORMAT
//   3. Bad primitive    → VERR_BAD_PRIMITIVE
//   (Layout and epoch checks are deferred to ingress_arb for per-capsule
//    validation rather than per-descriptor, since the same descriptor may
//    receive capsules from different sources.)
//
// MVP primitives:
//   VEC_RENORM, VEC_PACK, VEC_UNPACK, VEC_SPLIT, VEC_MERGE,
//   VEC_RESADD, VEC_REDUCE_MAX, VEC_REDUCE_SUM,
//   VEC_RMSNORM_PARTIAL, VEC_MOE_DISPATCH_PACK
//
// Author:  H-Tensor Project
// Version: 2.0 (R3 — multi-pass num_passes output)
// =============================================================================

module vec_desc_decode
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── Input ──
    input  vec_exec_desc_t  desc_i,
    input  logic            valid_i,

    // ── Output ──
    output vec_ctrl_t       ctrl_o,
    output logic            valid_o,
    output vec_error_e      error_o
);

    // =========================================================================
    // Primitive extraction
    // =========================================================================
    vec_primitive_e prim;
    assign prim = vec_primitive_e'(desc_i.primitive_id);

    // =========================================================================
    // Field Validation
    // =========================================================================
    logic bad_block_size;
    logic bad_scale_format;
    logic bad_primitive;

    assign bad_block_size   = !is_valid_block_size(desc_i.block_size);
    assign bad_scale_format = !is_valid_scale_format(desc_i.scale_format);
    assign bad_primitive    = !is_mvp_primitive(prim);

    logic any_error;
    assign any_error = bad_block_size | bad_scale_format | bad_primitive;

    // =========================================================================
    // Error Priority Encoder
    // =========================================================================
    always_comb begin
        if (bad_block_size)
            error_o = VERR_BAD_BLOCK_SIZE;
        else if (bad_scale_format)
            error_o = VERR_BAD_SCALE_FORMAT;
        else if (bad_primitive)
            error_o = VERR_BAD_PRIMITIVE;
        else
            error_o = VERR_NONE;
    end

    // =========================================================================
    // Pipeline Stage Enable Logic
    //
    // Each primitive activates a specific subset of pipeline stages.
    // This is the single authoritative mapping — all downstream modules
    // check ctrl.xxx_en to decide whether to operate.
    //
    // Stage map (rows = primitives, cols = stages):
    //
    //   Primitive           | scale | lane | reduce | renorm | escape
    //   --------------------|-------|------|--------|--------|-------
    //   VEC_PACK            |   ✓   |  ✓   |        |        |
    //   VEC_UNPACK          |   ✓   |  ✓   |        |        |
    //   VEC_SPLIT           |   ✓   |  ✓   |        |   ✓    |
    //   VEC_MERGE           |   ✓   |  ✓   |        |   ✓    |
    //   VEC_RESADD          |   ✓   |  ✓   |        |   ✓    |
    //   VEC_RENORM          |   ✓   |  ✓   |        |   ✓    |
    //   VEC_REDUCE_MAX      |   ✓   |  ✓   |   ✓    |        |
    //   VEC_REDUCE_SUM      |   ✓   |  ✓   |   ✓    |        |
    //   VEC_RMSNORM_PARTIAL |   ✓   |  ✓   |   ✓    |        |
    //   VEC_MOE_DISPATCH_PACK|  ✓   |  ✓   |        |        |
    // =========================================================================
    logic scale_en, lane_en, reduce_en, renorm_en, escape_req;
    logic need_src0, need_src1;

    always_comb begin
        // Defaults: nothing enabled
        scale_en   = 1'b0;
        lane_en    = 1'b0;
        reduce_en  = 1'b0;
        renorm_en  = 1'b0;
        escape_req = 1'b0;
        need_src0  = 1'b0;
        need_src1  = 1'b0;

        if (valid_i && !any_error) begin
            case (prim)
                VEC_PACK: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    need_src0 = 1'b1;
                end

                VEC_UNPACK: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    need_src0 = 1'b1;
                end

                VEC_SPLIT: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    renorm_en = 1'b1;   // sub-blocks may need new scale
                    need_src0 = 1'b1;
                end

                VEC_MERGE: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    renorm_en = 1'b1;   // merged block needs unified scale
                    need_src0 = 1'b1;
                    need_src1 = 1'b1;   // two sub-blocks to merge
                end

                VEC_RESADD: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    renorm_en = 1'b1;   // sum may shift dynamic range
                    need_src0 = 1'b1;
                    need_src1 = 1'b1;   // two operands for add
                end

                VEC_RENORM: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;   // passthrough to get lane_result format
                    renorm_en = 1'b1;   // core operation
                    need_src0 = 1'b1;
                end

                VEC_REDUCE_MAX: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    reduce_en = 1'b1;
                    need_src0 = 1'b1;
                end

                VEC_REDUCE_SUM: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    reduce_en = 1'b1;
                    need_src0 = 1'b1;
                end

                VEC_RMSNORM_PARTIAL: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    reduce_en = 1'b1;   // sum-of-squares reduction
                    need_src0 = 1'b1;
                end

                VEC_MOE_DISPATCH_PACK: begin
                    scale_en  = 1'b1;
                    lane_en   = 1'b1;
                    need_src0 = 1'b1;
                end

                default: begin
                    // Unknown MVP primitive — should not reach here due to
                    // bad_primitive check, but defensively disable all stages
                end
            endcase
        end

        // Escape override: if descriptor explicitly requests escape,
        // assert escape_req regardless of primitive.
        if (valid_i && desc_i.escape_hint == 2'b11)
            escape_req = 1'b1;
    end

    // =========================================================================
    // Output Assembly: vec_ctrl_t
    // =========================================================================
    always_comb begin
        // --- Primitive identity ---
        ctrl_o.prim_id        = prim;   // field renamed (primitive = reserved SV keyword)
        ctrl_o.op_class       = class_from_primitive(prim);

        // --- Operand requirements ---
        ctrl_o.need_src0      = need_src0;
        ctrl_o.need_src1      = need_src1;

        // --- Pipeline stage enables ---
        ctrl_o.scale_adapt_en = scale_en;
        ctrl_o.lane_en        = lane_en;
        ctrl_o.reduce_en      = reduce_en;
        ctrl_o.renorm_en      = renorm_en;
        ctrl_o.escape_req     = escape_req;

        // --- Lane control ---
        ctrl_o.lane_op        = lane_op_from_primitive(prim);

        // --- Reduce control ---
        ctrl_o.reduce_mode    = reduce_mode_from_primitive(prim);

        // --- Multi-pass control ---
        //   Derived from block_size and VEC_LANES parameter:
        //     block_size=16, VEC_LANES=16 → 1 pass  (16 elements in one window)
        //     block_size=32, VEC_LANES=16 → 2 passes (32 elements in two windows)
        //   vector_unit FSM uses this to iterate over element windows.
        //   Stage enables (lane_en, reduce_en, renorm_en) are total switches:
        //     they indicate WHICH stages are active per pass, not per element.
        ctrl_o.num_passes     = passes_for_block(desc_i.block_size);

        // --- Format context (propagated from descriptor) ---
        ctrl_o.block_size     = desc_i.block_size;
        ctrl_o.scale_format   = desc_i.scale_format;
        ctrl_o.elem_fmt       = desc_i.elem_fmt;
        ctrl_o.layout_tag     = desc_i.layout_tag;
        ctrl_o.scale_epoch    = desc_i.scale_epoch;
        ctrl_o.round_sat_policy = desc_i.round_sat_policy;
        ctrl_o.escape_hint    = desc_i.escape_hint;

        // --- Egress policy ---
        ctrl_o.dest_hint      = desc_i.dest_hint;
        ctrl_o.fwd_eligible   = desc_i.fwd_eligible;
        ctrl_o.multi_consumer = desc_i.multi_consumer;

        // --- Identity ---
        ctrl_o.ctx_id         = desc_i.ctx_id;
        ctrl_o.tag            = desc_i.tag;
    end

    // =========================================================================
    // Output valid: pass through if no error, suppress if error detected
    // =========================================================================
    assign valid_o = valid_i && !any_error;

endmodule

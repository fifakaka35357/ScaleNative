// =============================================================================
// vec_result_packer.sv — Result Capsule Assembler (Vector Unit, v2)
//
// Pure combinational module that takes the final pipeline stage output and
// packs it into a bs_capsule_t for downstream consumption (fast path egress,
// keep-local, writeback, or escape spill).
//
// v2 changes from v1:
//   - Scale passthrough (B3 fix): non-renorm paths (lane, reduce) now
//     propagate src0's inline_scale unchanged, instead of outputting zero.
//     This preserves the "scale is a first-class citizen" contract.
//   - E4M3 precise re-encode: uses mant_corr from vec_internal_scale_t to
//     recover the exact original raw mantissa bits (lossless round-trip).
//   - 16-lane packing: VEC_LANES=16 fills the full 256-bit payload in one pass.
//   - Reduce result width: REDUCE_W=21 (was 20), matching vec_reduce_cluster v2.
//   - operand_role field: set to OP_SRC0 in output capsule (result is always
//     a primary operand from the consumer's perspective).
//   - New ports: src0_inline_scale_i, src0_scale_inline_valid_i for passthrough.
//
// Source selection priority (last active stage wins):
//   1. Renorm result  (if ctrl.renorm_en)   → packed_mant + re-encoded new_scale
//   2. Reduce result  (if ctrl.reduce_en)   → single scalar + src0 scale passthrough
//   3. Lane results   (if ctrl.lane_en)     → per-lane mants + src0 scale passthrough
//   4. Bypass         (if none enabled)      → invalid output
//
// Scale handling per path:
//   Renorm:  re-encode new_scale → inline_scale, scale_inline_valid = 1
//   Reduce:  passthrough src0 inline_scale, scale_inline_valid = src0's
//   Lane:    passthrough src0 inline_scale, scale_inline_valid = src0's
//   None:    scale_inline_valid = 0
//
// Author:  H-Tensor Project
// Version: 2.0 (R7 — scale passthrough + precise E4M3 encode + 16-lane)
// =============================================================================

module vec_result_packer
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── Per-Lane Results (from vec_lane_array, valid if ctrl.lane_en) ──
    input  vec_lane_result_t   lane_results_i [VEC_LANES],
    input  logic               lane_valid_i,

    // ── Reduce Result (from vec_reduce_cluster, valid if ctrl.reduce_en) ──
    input  vec_reduce_result_t reduce_result_i,

    // ── Renorm Result (from vec_renorm_quant, valid if ctrl.renorm_en) ──
    input  vec_renorm_result_t renorm_result_i,

    // ── Pipeline Control ──
    input  vec_ctrl_t          ctrl_i,

    // ── Source capsule scale reference (for non-renorm passthrough) ──
    input  logic [15:0]        src_scale_ref_i,

    // ── Source capsule inline scale (for non-renorm passthrough, B3 fix) ──
    //   These come from src0_cap_q in vector_unit, preserving the original
    //   inline scale through scale-preserving operations (PACK, UNPACK, etc.)
    input  logic [31:0]        src0_inline_scale_i,
    input  logic               src0_scale_inline_valid_i,

    // ── Output ──
    output bs_capsule_t        capsule_o,
    output logic               valid_o,
    output logic               escape_needed_o   // from renorm or special detection
);

    // =========================================================================
    // Internal payload construction widths
    // =========================================================================
    // All internal elements are VEC_MANT_W = 16 bits, packed sequentially.
    // payload capacity: BS_CAP_PAYLOAD_W / VEC_MANT_W = 256 / 16 = 16 elements
    // per capsule. With VEC_LANES=16, one pass fills the entire 256-bit payload.
    localparam int ELEM_PACK_W = VEC_MANT_W;  // 16 bits per packed element

    // =========================================================================
    // Stage 1: Payload Assembly — select from pipeline sources
    // =========================================================================
    logic [BS_CAP_PAYLOAD_W-1:0] payload;
    logic                        result_valid;

    always_comb begin
        payload      = '0;
        result_valid = 1'b0;

        // Priority: renorm > reduce > lane > none
        if (ctrl_i.renorm_en && renorm_result_i.valid) begin
            // ── Renorm path: pre-packed mantissas from renorm engine ──
            // Copy up to BS_CAP_PAYLOAD_W bits from packed_mant.
            // renorm_result_i.packed_mant is VEC_MAX_BLOCK*VEC_MANT_W = 512 bits.
            // Take the low BS_CAP_PAYLOAD_W (256) bits for this capsule.
            // For block_size=32 multi-pass, vector_unit combines two passes
            // by selecting the appropriate 256-bit window.
            payload      = renorm_result_i.packed_mant[BS_CAP_PAYLOAD_W-1:0];
            result_valid = 1'b1;

        end else if (ctrl_i.reduce_en && reduce_result_i.valid) begin
            // ── Reduce path: single scalar result ──
            // Pack into low bits: {exp, mant}
            // mant is REDUCE_W (21) bits; exp is VEC_EXP_W (10) bits.
            // Consumer interprets based on elem_fmt + reduce context.
            payload[REDUCE_W-1:0]                             = reduce_result_i.mant;
            payload[REDUCE_W+VEC_EXP_W-1:REDUCE_W]           = reduce_result_i.exp;
            result_valid = 1'b1;

        end else if (ctrl_i.lane_en && lane_valid_i) begin
            // ── Lane path: per-element results ──
            // Pack VEC_LANES (16) mantissas sequentially into payload.
            // 16 × 16-bit = 256 bits → fills entire payload.
            for (int i = 0; i < VEC_LANES; i++) begin
                if (i * ELEM_PACK_W + ELEM_PACK_W <= BS_CAP_PAYLOAD_W) begin
                    payload[i*ELEM_PACK_W +: ELEM_PACK_W] = lane_results_i[i].mant;
                end
            end
            result_valid = 1'b1;

        end else begin
            // No active pipeline stage — invalid output
            result_valid = 1'b0;
        end
    end

    // =========================================================================
    // Stage 2: Scale Output — Re-Encode or Passthrough
    //
    // Two sub-paths:
    //
    //   A) Renorm path: new_scale from vec_renorm_quant is re-encoded back
    //      to raw 8-bit format. Uses mant_corr for lossless E4M3 encoding.
    //
    //   B) Non-renorm path (lane / reduce / bypass): the original src0
    //      inline_scale is passed through unchanged. This is the B3 fix —
    //      scale-preserving operations no longer drop scale metadata.
    //
    // E8M0 encode: raw = clamp(exp_adj + 127, 1, 254)
    //   0xFF reserved for NaN, 0x00 for zero.
    //   mant_corr is always 128 for E8M0 (no fractional part).
    //
    // E4M3 encode (v2 precise):
    //   raw_exp  = clamp(exp_adj + 7, 1, 14)
    //   raw_mant = (mant_corr >> 4) & 3'b111   (lossless inverse of adapter)
    //   raw = {1'b0, raw_exp[3:0], raw_mant[2:0]}
    //   NaN → 0x7F, zero → 0x00.
    //
    //   Verification: for all 8 mantissa values:
    //     encode(decode(raw)) == raw   ← lossless round-trip
    // =========================================================================
    logic [31:0] out_inline_scale;
    logic        out_scale_valid;
    // [HW-REVIEW T3] result absolute block exponent (bs_capsule_t.scale_ref). Renorm
    // path emits the RESULT's exp; passthrough carries src0's; else 0. Symmetric with
    // tensor_result_packer so chained RESADDs keep the unclamped scale one hop later.
    logic [15:0] out_scale_ref;

    always_comb begin
        out_inline_scale = '0;
        out_scale_valid  = 1'b0;
        out_scale_ref    = 16'd0;

        if (ctrl_i.renorm_en && renorm_result_i.valid) begin
            // ── Path A: Renorm re-encode ──
            logic [7:0] encoded_scale;
            encoded_scale = 8'h00;

            if (renorm_result_i.new_scale.special_nan) begin
                case (ctrl_i.scale_format)
                    SCALE_E8M0: encoded_scale = 8'hFF;
                    SCALE_E4M3: encoded_scale = 8'h7F;  // {0, 1111, 111}
                    default:    encoded_scale = 8'hFF;
                endcase
            end else if (renorm_result_i.new_scale.special_zero) begin
                encoded_scale = 8'h00;
            end else begin
                case (ctrl_i.scale_format)
                    SCALE_E8M0: begin
                        // raw = exp_adj + 127, clamped to [1, 254]
                        logic signed [VEC_EXP_W-1:0] biased;
                        biased = renorm_result_i.new_scale.exp_adj + VEC_EXP_W'(127);
                        if (biased <= VEC_EXP_W'(0))
                            encoded_scale = 8'h01;  // minimum normal
                        else if (biased >= VEC_EXP_W'(254))
                            encoded_scale = 8'hFE;  // maximum normal (0xFF = NaN)
                        else
                            encoded_scale = 8'(biased);
                    end
                    SCALE_E4M3: begin
                        // v2 precise encode using mant_corr
                        // raw_exp = exp_adj + 7, clamped to [1, 14]
                        // raw_mant = (mant_corr >> 4) & 3'b111
                        logic signed [VEC_EXP_W-1:0] biased_e4;
                        logic [2:0] raw_mant;
                        biased_e4 = renorm_result_i.new_scale.exp_adj + VEC_EXP_W'(7);
                        raw_mant  = (renorm_result_i.new_scale.mant_corr >> 4) & 3'b111;

                        if (biased_e4 <= VEC_EXP_W'(0))
                            encoded_scale = {1'b0, 4'd1, 3'b000};  // min normal
                        else if (biased_e4 >= VEC_EXP_W'(15))
                            encoded_scale = {1'b0, 4'd14, 3'b110}; // max non-NaN
                        else
                            encoded_scale = {1'b0, biased_e4[3:0], raw_mant};
                    end
                    default: begin
                        encoded_scale = 8'h00;
                    end
                endcase
            end

            // [HW-REVIEW T3] carry the RESULT's UNCLAMPED absolute exponent for E4M3:
            // scale_ref = new_scale.exp_adj + inline_scale[8]. The clamped E4M3 byte
            // (encoded_scale) stays the external/NVFP4 carrier. Without this, a chained
            // RESADD re-clamps the result one hop later (symmetric with tensor_result_packer).
            if (ctrl_i.scale_format == SCALE_E4M3) begin
                out_inline_scale = {23'h0, 1'b1, encoded_scale};
                out_scale_ref    = 16'(signed'(renorm_result_i.new_scale.exp_adj));
            end else begin
                out_inline_scale = {24'h0, encoded_scale};       // E8M0 byte is wide (legacy)
                out_scale_ref    = 16'd0;
            end
            out_scale_valid  = 1'b1;

        end else if (result_valid) begin
            // ── Path B: Non-renorm passthrough (B3 fix) ──
            // Preserve src0's original inline_scale unchanged (incl. inline_scale[8]
            // and scale_ref — [HW-REVIEW T3]).
            // This ensures scale-preserving operations (PACK, UNPACK,
            // REDUCE_MAX, REDUCE_SUM, MOE_DISPATCH_PACK, etc.) maintain
            // the "scale is a first-class citizen" contract.
            out_inline_scale = src0_inline_scale_i;
            out_scale_valid  = src0_scale_inline_valid_i;
            out_scale_ref    = src_scale_ref_i;

        end else begin
            // No valid result — no scale
            out_inline_scale = '0;
            out_scale_valid  = 1'b0;
            out_scale_ref    = 16'd0;
        end
    end

    // =========================================================================
    // Stage 3: Status Flags Assembly
    //
    // Aggregate special condition flags from all pipeline sources.
    //
    // status_flags[7:0] encoding:
    //   [0] any_nan       — NaN detected in any element
    //   [1] any_inf       — Inf detected in any element
    //   [2] any_overflow  — overflow in any lane
    //   [3] any_underflow — underflow in any lane
    //   [4] scale_changed — renorm updated the shared exponent
    //   [5] escape_needed — escape detected (v2: result will be spilled to L2)
    //   [7:6] reserved
    // =========================================================================
    logic [7:0] status_flags;

    always_comb begin
        status_flags = 8'h00;

        // Aggregate from lane results
        if (ctrl_i.lane_en) begin
            for (int i = 0; i < VEC_LANES; i++) begin
                status_flags[0] = status_flags[0] | lane_results_i[i].is_nan;
                status_flags[1] = status_flags[1] | lane_results_i[i].is_inf;
                status_flags[2] = status_flags[2] | lane_results_i[i].overflow;
                status_flags[3] = status_flags[3] | lane_results_i[i].underflow;
            end
        end

        // Aggregate from reduce result
        if (ctrl_i.reduce_en && reduce_result_i.valid) begin
            status_flags[0] = status_flags[0] | reduce_result_i.is_nan;
            status_flags[1] = status_flags[1] | reduce_result_i.is_inf;
        end

        // Aggregate from renorm result
        if (ctrl_i.renorm_en && renorm_result_i.valid) begin
            status_flags[0] = status_flags[0] | renorm_result_i.new_scale.special_nan;
            status_flags[4] = renorm_result_i.scale_changed;
            status_flags[5] = renorm_result_i.escape_needed;
        end
    end

    // =========================================================================
    // Stage 4: Scale Epoch Update
    //
    // If renorm changed the scale, increment scale_epoch by 1 to signal
    // downstream consumers that scale metadata has been refreshed.
    // Non-renorm paths preserve the original epoch unchanged.
    // =========================================================================
    logic [7:0] out_epoch;

    always_comb begin
        out_epoch = ctrl_i.scale_epoch;
        if (ctrl_i.renorm_en && renorm_result_i.valid && renorm_result_i.scale_changed)
            out_epoch = ctrl_i.scale_epoch + 8'd1;
    end

    // =========================================================================
    // Stage 5: Capsule Assembly
    //
    // Fill all fields of bs_capsule_t from pipeline results + ctrl metadata.
    // Contract invariant: no field may be left undefined or zero by accident.
    // Every field is explicitly assigned.
    //
    // CL-7: Reduce-result capsules use LAYOUT_SCALAR_REDUCE layout_tag
    // and fwd_eligible=0 to prevent misinterpretation by downstream consumers.
    // =========================================================================
    always_comb begin
        // ── Payload ──
        capsule_o.payload          = payload;

        // ── Format context (from ctrl, propagated unchanged) ──
        capsule_o.elem_fmt         = ctrl_i.elem_fmt;
        capsule_o.block_size       = ctrl_i.block_size;
        capsule_o.scale_format     = ctrl_i.scale_format;

        // CL-7: Set layout_tag based on result source.
        //   Reduce path: LAYOUT_SCALAR_REDUCE (scalar, not block fragment)
        //   All other paths: preserve original layout_tag from ctrl
        if (ctrl_i.reduce_en && reduce_result_i.valid) begin
            capsule_o.layout_tag   = LAYOUT_SCALAR_REDUCE;
        end else begin
            capsule_o.layout_tag   = ctrl_i.layout_tag;
        end

        // ── Scale metadata ──
        // [HW-REVIEW T3] per-path scale_ref: renorm -> result exp; passthrough -> src0's.
        // (Was unconditionally src_scale_ref_i, which aliased the result's exp with src0's.)
        capsule_o.scale_ref          = out_scale_ref;
        capsule_o.inline_scale       = out_inline_scale;
        capsule_o.scale_inline_valid = out_scale_valid;
        capsule_o.scale_epoch        = out_epoch;

        // ── Policy ──
        capsule_o.round_sat_policy = ctrl_i.round_sat_policy;
        capsule_o.escape_hint      = ctrl_i.escape_hint;

        // CL-7: Reduce results should NOT be direct-forwarded to Tensor Unit.
        //   Tensor expects block fragments (16/32 element arrays), not scalars.
        //   Force dest_hint=DEST_SRAM and fwd_eligible=0 for reduce results.
        if (ctrl_i.reduce_en && reduce_result_i.valid) begin
            capsule_o.dest_hint    = DEST_SRAM;
            capsule_o.fwd_eligible = 1'b0;
        end else begin
            capsule_o.dest_hint    = ctrl_i.dest_hint;
            capsule_o.fwd_eligible = ctrl_i.fwd_eligible;
        end
        capsule_o.multi_consumer   = ctrl_i.multi_consumer;

        // ── Operand role ──
        capsule_o.operand_role     = OP_SRC0;

        // ── Identity ──
        capsule_o.ctx_id           = ctrl_i.ctx_id;
        capsule_o.tag              = ctrl_i.tag;

        // ── Provenance ──
        capsule_o.producer         = DOMAIN_VECTOR;

        // ── Status ──
        capsule_o.status_flags     = status_flags;
    end

    // =========================================================================
    // Output valid & escape
    // =========================================================================
    assign valid_o         = result_valid;
    assign escape_needed_o = status_flags[5];

endmodule

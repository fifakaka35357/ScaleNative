// =============================================================================
// vec_cmd_to_desc.sv — Legacy Command Adapter (vec_cmd_t → vec_exec_desc_t)
//
// Thin combinational adapter bridging the existing cp_scheduler output
// (vec_cmd_t with opcode/row/len/ctx/tag) to the Vector Unit's native input
// (vec_exec_desc_t with primitive_id, block_size, scale_format, etc.).
//
// v2 changes from v1:
//   - elem_fmt default changed from ELEM_BF16 to ELEM_BFP_INTERNAL
//     Reason: Vector Unit internal datapath uses 16-bit signed mantissa
//     representation, NOT standard BF16 bit-pattern. Using ELEM_BF16 would
//     mislead downstream consumers into interpreting the payload incorrectly.
//     ELEM_BFP_INTERNAL accurately describes the actual data encoding.
//
// Purpose:
//   The cp_scheduler and cp_completion systems remain unmodified. This adapter
//   sits between cp_scheduler's vec_cmd output and vector_unit's desc input,
//   translating the legacy format into the Full BFP Dataflow contract format.
//
// Mapping strategy:
//   - Opcodes → MVP primitives (OP_VEC_LOAD→VEC_PACK, etc.)
//   - BFP contract fields filled with safe defaults:
//       block_size   = BLOCK_SIZE_32    (baseline)
//       scale_format = SCALE_E8M0      (MX-standard)
//       elem_fmt     = ELEM_BFP_INTERNAL (internal block-float mantissa)
//       fwd_eligible = 0               (legacy path, no fast path)
//   - ctx_id and tag pass through unchanged (credit/completion compat)
//   - src0_ref/dst_ref derived from physical row addresses
//
// Future removal:
//   When PE is upgraded with contract_decode_expand.sv, this adapter
//   is removed and cp_scheduler drives vec_exec_desc_t directly.
//
// Author:  H-Tensor Project
// Version: 2.0 (R3 — elem_fmt correction)
// =============================================================================

module vec_cmd_to_desc
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── Legacy command input (from cp_scheduler) ──
    input  logic        cmd_valid_i,
    output logic        cmd_ready_o,
    input  vec_cmd_t    cmd_i,

    // ── BFP descriptor output (to vector_unit) ──
    output logic            desc_valid_o,
    input  logic            desc_ready_i,
    output vec_exec_desc_t  desc_o
);

    // =========================================================================
    // Handshake pass-through
    // =========================================================================
    assign desc_valid_o = cmd_valid_i;
    assign cmd_ready_o  = desc_ready_i;

    // =========================================================================
    // Opcode → Primitive Mapping
    //
    // Legacy Vec opcodes map to the closest MVP primitive:
    //   OP_VEC_LOAD  → VEC_PACK    (load from L2 = pack into block-scaled)
    //   OP_VEC_STORE → VEC_UNPACK  (store to L2 = unpack from block-scaled)
    //   OP_VEC_ACT   → VEC_RENORM  (activation = renorm/transform)
    // =========================================================================
    vec_primitive_e mapped_prim;
    vec_op_class_e  mapped_class;

    always_comb begin
        case (cmd_i.opcode)
            OP_VEC_LOAD:  begin
                mapped_prim  = VEC_PACK;
                mapped_class = VCLASS_TRANSFORM;
            end
            OP_VEC_STORE: begin
                mapped_prim  = VEC_UNPACK;
                mapped_class = VCLASS_TRANSFORM;
            end
            OP_VEC_ACT:   begin
                mapped_prim  = VEC_RENORM;
                mapped_class = VCLASS_RENORM;
            end
            OP_VEC_RESADD: begin                       // [STEP4-E2E]
                mapped_prim  = VEC_RESADD;             // two fast-path operands
                mapped_class = VCLASS_ARITHMETIC;
            end
            default: begin
                mapped_prim  = VEC_NOP;
                mapped_class = VCLASS_NOP;
            end
        endcase
    end

    // [STEP4-E2E] RESADD takes its operands from the fast path (operand_role
    // SRC0/SRC1) and must carry the real block-scale contract so vec_ingress_arb
    // accepts the producer's capsules (exact-match on block_size/scale_format/
    // scale_epoch/fwd_eligible). Legacy LOAD/STORE/ACT keep the safe defaults.
    logic is_resadd;
    assign is_resadd = (cmd_i.opcode == OP_VEC_RESADD);

    // [C-MX STORE ⑦] compact-MX L2-store gate: an OP_VEC_STORE whose contract
    // carries a block-scaled elem_fmt (MXFP8/MXFP4/MXINT8 per fmt_is_block_scaled;
    // MXINT8 is further excluded on the vector_unit side) passes the contract's
    // elem_fmt/block_size (+ derived scale_format) and the sidecar_base through
    // to the descriptor, mirroring the is_resadd gating precedent. The default
    // contract ('0 -> ELEM_BF16, not block-scaled) keeps every legacy STORE
    // bit-identical on the old path.
    logic is_store, compact_store;
    assign is_store      = (cmd_i.opcode == OP_VEC_STORE);
    assign compact_store = is_store && pe_pkg::fmt_is_block_scaled(cmd_i.contract.elem_fmt);

    // scale_format from the dual-ecosystem default (D12): block16 = NVFP4 (E4M3
    // block scale), block32 = OCP MX (E8M0). A future explicit contract
    // scale_format field would override this derivation.
    // [C-MX STORE ⑦] the compact store reuses the same derivation.
    scale_format_e resadd_scale_format;
    assign resadd_scale_format = (cmd_i.contract.block_size_log2 == BS_16)
                               ? SCALE_E4M3 : SCALE_E8M0;

    // =========================================================================
    // Descriptor Assembly
    // =========================================================================
    always_comb begin
        // ── Identity (preserved for credit/completion) ──
        desc_o.ctx_id           = cmd_i.ctx_id;
        desc_o.tag              = cmd_i.tag;

        // ── Primitive ──
        desc_o.op_class         = mapped_class;
        desc_o.primitive_id     = mapped_prim;

        // ── Format defaults (legacy path) ──
        //   elem_fmt = ELEM_BFP_INTERNAL: Vector Unit internally represents all
        //   elements as VEC_MANT_W-bit (16-bit) signed mantissa with a shared
        //   block exponent. This is NOT standard BF16 — it's an internal
        //   block-float format. Using ELEM_BFP_INTERNAL prevents downstream
        //   consumers from misinterpreting the payload as IEEE BF16 bit-patterns.
        //   For RESADD the format fields come from the architectural contract
        //   (so they match the producer's fast-path capsules); legacy ops keep
        //   the v2 safe defaults.
        //   [C-MX STORE ⑦] a compact-MX STORE carries the contract's block-scaled
        //   elem_fmt so vector_unit engages the requantizing compact write-back
        //   (lane datapath is unchanged — the format tags the OUTPUT encoding).
        desc_o.elem_fmt         = compact_store ? cmd_i.contract.elem_fmt
                                                : ELEM_BFP_INTERNAL;   // lane datapath = 16b mantissa
        desc_o.block_size       = (is_resadd || compact_store)
                                ? bs_sel_from_log2(cmd_i.contract.block_size_log2)
                                : BLOCK_SIZE_32;
        desc_o.scale_format     = (is_resadd || compact_store) ? resadd_scale_format
                                                               : SCALE_E8M0;
        desc_o.layout_tag       = 4'd0;

        // ── Address mapping ──
        desc_o.src0_ref         = {7'b0, cmd_i.src_row};
        // [STEP4-E2E §11.4] RESADD resident SRC1: the residual L2 row = cmd.src_row
        // (otherwise unused for RESADD, whose SRC0 arrives on the fast path).
        desc_o.src1_ref         = is_resadd ? {7'b0, cmd_i.src_row} : '0;
        desc_o.dst_ref          = {7'b0, cmd_i.dst_row};
        desc_o.scale_ref        = '0;

        // ── Metadata defaults ──
        desc_o.scale_epoch      = is_resadd ? cmd_i.contract.scale_epoch : 8'd0;
        desc_o.round_sat_policy = 4'd0;
        desc_o.escape_hint      = 2'b00;
        desc_o.dest_hint        = DEST_SRAM;            // RESADD result -> L2 write-back
        desc_o.fwd_eligible     = is_resadd ? cmd_i.contract.fwd_eligible : 1'b0;
        desc_o.multi_consumer   = 1'b0;
        // [STEP4-E2E §11.4] resident SRC1 select (RESADD only); default fast-path.
        desc_o.src1_resident    = is_resadd ? cmd_i.contract.src1_resident : 1'b0;
        // [HW-REVIEW T3] resident SRC1 per-residual absolute block exponent
        // (software-provided via the contract, so cp_scheduler's contract-copy
        // propagates it; aligns the resident residual instead of the old fixed exp0).
        // Only meaningful for a resident RESADD.
        desc_o.src1_scale_ref   = is_resadd ? cmd_i.contract.src1_scale_ref : 16'sd0;
        // [HW-REVIEW T3-FF/FF3b-c] multi-block streaming RESADD. block_count counts
        // residual BLOCKS (= len_rows; block16->1 frag/block, block32->2 windows/block,
        // handled by the inner 1-bit machinery). Gated to a resident RESADD so legacy
        // LOAD/STORE/ACT and non-resident fast-path RESADD stay bit-identical
        // (block_count=1 => the outer streaming loop runs exactly once = today's path).
        // sidecar_base is the PHYSICAL scale row, already xlat'd by cp_scheduler (this
        // frozen adapter holds no region table), zero-extended to the 16b desc field.
        desc_o.block_count      = (is_resadd && cmd_i.contract.src1_resident)
                                ? cmd_i.len_rows : 16'd1;
        // [C-MX STORE ⑦] the compact store also needs the physical scale-sidecar
        // base row (RMW target of the per-window scale write-back). block_count
        // stays 1 for STORE (non-streaming), so blk_idx never advances.
        desc_o.sidecar_base     = ((is_resadd && cmd_i.contract.src1_resident) || compact_store)
                                ? {{(16-L2_BANK_AW){1'b0}}, cmd_i.sidecar_base} : 16'd0;
    end

endmodule

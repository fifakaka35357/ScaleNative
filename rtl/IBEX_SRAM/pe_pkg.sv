// =============================================================================
// pe_pkg.sv — H-Tensor PE v5 Shared Package
//
// Phase 1 (v5) changes:
//   [PHASE1-01] Add OP_WAIT to desc_opcode_e (was referenced but undefined)
//   [PHASE1-02] OP_RING_* explicitly marked RESERVED (poison-on-fetch in Phase 4)
//   [PHASE1-03] Add ERR_OPCODE_RESERVED to err_class_e
//   [PHASE1-04] TXN_ID_W comment de-versioned
//   [PHASE1-05] Add width constants: FULL_STRIPE_W, HALF_STRIPE_W, FRAG_W, FRAG_ELEMS
//   [PHASE1-06] New §6b: Contract Type System (elem_fmt_e, block_size_log2_e,
//               dest_hint_e, tile_contract_t)
//   [PHASE1-07] RENAME vec_cmd_t <-> tens_cmd_t (semantic reversal):
//               - tens_cmd_t now carries FULL_STRIPE (512b) GEMM workhorse semantics
//               - vec_cmd_t now carries HALF_STRIPE (256b) transform engine semantics
//               - M/N/K parameters migrate into tens_cmd_t (they describe GEMM tile)
//               - Both cmd_t types embed tile_contract_t
//   [PHASE1-08] dma_cmd_t embeds tile_contract_t (DMA must know the contract)
//   [PHASE1-09] New §7b: Fast Path Sideband Types (frag_sideband_t with
//               fragment_idx, last_frag_in_block, last_frag_in_row, scale)
//   [PHASE1-10] trace_evt_e extended with 6 new event codes for fast-path /
//               contract observability (codes 10-15 filled)
//
// Historical changelog (preserved):
//   (Round 5A fix: P1.1 DESC_MAX_EXT)
//   (Round R1: add CTX_ERROR, CTX_ID_W)
//   (Round R2A: add ring helper functions — clamp_ring_cfg, ring_mask_from_log2)
//   (Round D3/R7.1a: TAG_W, multi-credit defaults, tag field in cmd structs)
//   (D6/R7.2: OP_WAIT, CTX_WAIT_EVENT, event mask constants, ctx_state 4-bit)
//   (D8/R7.3: trace_entry_t, trace_evt_e, trace ring parameters)
//   (Round R3A: add min_ext_for_opcode, is_known_opcode, err_class_e, poison helpers)
//   (Round R3A+: R3.4 descriptor format reserves, R3.5 TXN_ID_W)
//   (Round R4A: scoreboard credit params, watchdog params, dep_mask defs)
//   (Round R4A+: CREDIT_W widened +1 bit for net-delta arithmetic safety)
//   (Round R4.3: IRQ system parameters — bit positions, total width)
//   (Round R5.1: perf counter parameters, MMIO address plan)
//
// Shared parameters, types, and structs used across all PE v5 modules.
// This file must be compiled before any other PE v5 RTL.
//
// Contents:
//   1.  Global Parameters
//   2.  Memory Map Constants
//   3.  Descriptor Opcode Enum
//   4.  Descriptor Flags & Types
//   5.  Region Table Entry
//   6.  CP Context / Slot State Enums
//   6b. Contract Type System                            [PHASE1 NEW]
//   7.  Execution Unit Command Types
//   7b. Fast Path Sideband Types                        [PHASE1 NEW]
//   8.  Arbiter Types
// =============================================================================

package pe_pkg;

    // =========================================================================
    // 1. Global Parameters
    // =========================================================================

    // L1 Instruction Memory — 1 × 2KB macro
    parameter int L1I_SIZE_BYTES   = 2048;
    parameter int L1I_BANK_AW      = 9;          // 2^9 = 512 words

    // L1 Data Memory — 2 × 2KB macro, word-interleaved, 64b CP read
    parameter int L1D_NUM_BANKS    = 2;
    parameter int L1D_BANK_AW      = 9;          // 512 words per bank
    parameter int L1D_SIZE_BYTES   = 4096;       // 4KB total

    // L2 Scratchpad — 16 × 2KB macro, word-interleaved, row-based regions
    parameter int L2_NUM_BANKS     = 16;
    parameter int L2_BANK_AW       = 9;          // 512 words/bank (2KB); 10 for 4KB future
    parameter int L2_ROW_BYTES     = L2_NUM_BANKS * 4;           // 64B per row
    parameter int L2_TOTAL_ROWS    = 1 << L2_BANK_AW;           // 512 rows
    parameter int L2_BANK_SEL_W    = $clog2(L2_NUM_BANKS);      // 4 bits

    // [PHASE1-05] PE-facing data-path width constants
    //
    // These width constants form the architecture-visible contract between the
    // PE-top, the L2 arbiters, and the execution-domain wrappers. They are NOT
    // implementation parameters of the cores themselves — the Tensor / Vector
    // cores are free to organize internal arithmetic differently (e.g. Tensor
    // may still use BF16-baseline + local reduction for FP8/FP4), as long as
    // their PE-facing ports match these widths.
    //
    //   FULL_STRIPE_W = 512  — 16 banks × 32b. Consumed by Tensor Unit (GEMM
    //                          workhorse). Matches L2 full-row SRAM geometry.
    //   HALF_STRIPE_W = 256  —  8 banks × 32b. Consumed by Vector Unit
    //                          (scale-aware transform engine). Matches one
    //                          bank-half of the L2.
    //   FRAG_W        = 256  — Tensor <-> Vector fast-path payload width.
    //                          Intentionally equal to HALF_STRIPE_W so Vector
    //                          ingress consumes fragments at native width.
    //   FRAG_ELEMS    = 16   — Number of elements carried per fragment.
    //                          Element container = FRAG_W / FRAG_ELEMS = 16 bits
    //                          (BF16/FP16 native; FP8/FP4 use packed subword).
    //
    // Block-size / fragment relationship (sideband-driven, not in these widths):
    //   BS=16 (MX-16):  1 fragment == 1 complete block
    //   BS=32 (MX-32):  2 consecutive fragments == 1 complete block
    //   See frag_sideband_t.{fragment_idx, last_frag_in_block} in §7b.
    parameter int FULL_STRIPE_W    = L2_NUM_BANKS * 32;            // 512
    parameter int HALF_STRIPE_W    = (L2_NUM_BANKS/2) * 32;        // 256
    parameter int FRAG_W           = HALF_STRIPE_W;                 // 256
    parameter int FRAG_ELEMS       = 16;
    parameter int FRAG_ELEM_W      = FRAG_W / FRAG_ELEMS;          // 16-bit container

    // Command Processor
    parameter int NUM_CTX          = 4;
    parameter int NUM_REGIONS      = 4;
    parameter int RING_PTR_W       = 4;           // max 16 entries per ring
    parameter int RING_SIZE_MAX    = 1 << RING_PTR_W;

    // R2.3: ring_size_log2 legal domain
    //   Minimum 2 entries (log2=1): ring needs ≥2 slots for head/tail distinction
    //   Maximum: (1 << RING_PTR_W) entries (log2=RING_PTR_W)
    localparam logic [3:0] RING_CFG_MIN = 4'd1;
    localparam logic [3:0] RING_CFG_MAX = 4'(RING_PTR_W);

    // R2.3: Clamp raw ring_size_log2 to legal domain [RING_CFG_MIN..RING_CFG_MAX]
    function automatic logic [3:0] clamp_ring_cfg(input logic [3:0] cfg);
        if (cfg < RING_CFG_MIN)      return RING_CFG_MIN;
        else if (cfg > RING_CFG_MAX) return RING_CFG_MAX;
        else                         return cfg;
    endfunction

    // R2.3: Compute ring_mask from (possibly raw) ring_size_log2
    //   Internally clamps cfg first, then computes (1 << clamped) - 1.
    //   Single source of truth — all ring_mask consumers call this.
    function automatic logic [RING_PTR_W-1:0] ring_mask_from_log2(input logic [3:0] cfg);
        logic [3:0] c;
        c = clamp_ring_cfg(cfg);
        return (RING_PTR_W'(1) << c) - RING_PTR_W'(1);
    endfunction

    // Descriptor geometry
    parameter int DESC_BASE_WORDS  = 4;           // 16B base
    parameter int DESC_MAX_EXT     = 4;           // v4: max 4 extension words
                                                   //   total = base(4) + ext(0..4) = 4..8 words
                                                   //   fits exactly in DESC_SLOT_WORDS.
                                                   //   Values 5–15 reserved for future variable-
                                                   //   length descriptor mechanism; hw will flag
                                                   //   ext_len > 4 as an error (see cp_desc_fetch).
    parameter int DESC_SLOT_WORDS  = 8;           // per-ctx slot storage = DESC_BASE_WORDS
                                                   //   + DESC_MAX_EXT = 32B per slot

    // R3.2a: Poison flag — set by fetch engine in buf[0][31] when descriptor
    //   fails early validation. The scheduler checks this bit before issue.
    //   Uses bit 31 of word[0] (desc_header_t.reserved_hi[7]) which is
    //   zero-initialized and never written by software.
    //   This flag exists ONLY in the internal buffer / slot — never in L1D.
    localparam int DESC_POISON_BIT = 31;

    // R3.2a: Error class encoding (for CP_CTX_ERR register)
    //
    // [PHASE1-03] ERR_OPCODE_RESERVED added for RESERVED-but-not-supported
    // opcodes (currently: OP_RING_RESERVE / OP_RING_CONSUME / OP_RING_WAIT_GE).
    // Poison-on-fetch by cp_desc_fetch, carried through the existing error path.
    typedef enum logic [3:0] {
        ERR_NONE             = 4'd0,
        ERR_EXT_OVERFLOW     = 4'd1,   // ext_len > DESC_MAX_EXT
        ERR_EXT_UNDERFLOW    = 4'd2,   // ext_len < min_ext_for_opcode
        ERR_UNKNOWN_OPCODE   = 4'd3,   // opcode not in desc_opcode_e
        ERR_REGION_OOB       = 4'd4,   // row_off >= num_rows (R3.3)
        ERR_WATCHDOG         = 4'd5,   // watchdog timeout (R4)
        ERR_ALIGNMENT        = 4'd6,   // reserved for future
        ERR_INVALID_PARAM    = 4'd7,   // len_rows == 0 on compute/DMA op
        ERR_OPCODE_RESERVED  = 4'd8    // [PHASE1-03] opcode is architecturally
                                        //   reserved (e.g. OP_RING_*) and not
                                        //   yet supported in this PE integration
        // 9-15: reserved
    } err_class_e;

    // R3.2a: Poison encoding in word[0] (internal buffer / slot only)
    //
    //   [31]    = poison flag  (DESC_POISON_BIT)
    //   [30:27] = err_class[3:0]
    //   [26:0]  = original header bits (preserved)
    //
    //   Helper to mark a word[0] as poisoned with a given err_class:
    function automatic logic [31:0] make_poisoned(
        input logic [31:0] word0,
        input err_class_e  eclass
    );
        logic [31:0] w;
        w = word0;
        w[DESC_POISON_BIT]   = 1'b1;
        w[30:27]             = eclass;
        return w;
    endfunction

    // Helper to check if a slot word[0] is poisoned:
    function automatic logic is_poisoned(input logic [31:0] word0);
        return word0[DESC_POISON_BIT];
    endfunction

    // Helper to extract err_class from a poisoned word[0]:
    //
    // NOTE (Phase 1): This is the SINGLE SOURCE OF TRUTH for poison err-class
    // decoding. Any module-local shadow copies of this function (historically
    // present in cp_scheduler.sv with a WRONG [30:28] slice) must be removed
    // in Phase 4. The canonical slice is [30:27] (4 bits, matches make_poisoned).
    function automatic err_class_e get_poison_err_class(input logic [31:0] word0);
        return err_class_e'(word0[30:27]);
    endfunction

    // DMA
    parameter int DMA_FIFO_DEPTH   = 8;           // ingress/egress FIFO depth (words)
                                                   //   (Note: README previously stated depth=4;
                                                   //    RTL default is and has always been 8.
                                                   //    README to be aligned in Phase 7.)

    // =========================================================================
    // 2. Memory Map Constants (IBEX OBI address space)
    //
    //  0x0000_0000 – 0x0000_07FF : L1I  (2KB)
    //  0x0001_0000 – 0x0001_0FFF : L1D  (4KB)
    //  0x0002_0000 – 0x0002_01FF : MMIO (512B)  CP CSR / Region Table
    //  Others                    : Unmapped → bus error
    //
    // L2 is NOT in IBEX address space — accessed only via CP/Vec/Tens/DMA.
    // Full MMIO register map: see cp_csr.sv header.
    // =========================================================================

    // L1I: 0x0000_0000 – 0x0000_07FF
    //   addr[31:11] == 21'b0
    parameter logic [31:0] L1I_BASE = 32'h0000_0000;

    // L1D: 0x0001_0000 – 0x0001_0FFF
    //   addr[31:16] == 16'h0001, addr[15:12] == 4'h0
    parameter logic [31:0] L1D_BASE = 32'h0001_0000;

    // MMIO: 0x0002_0000 – 0x0002_01FF
    //   addr[31:16] == 16'h0002, addr[15:9] == 7'h00
    parameter logic [31:0] MMIO_BASE = 32'h0002_0000;

    // =========================================================================
    // 3. Descriptor Opcode Enum
    //
    // [PHASE1-01] OP_WAIT = 8'h31 added. Previously referenced by cp_scheduler
    //             and pe_assertions but never declared — this was a compile
    //             error latent in the v4 tree.
    //
    // [PHASE1-02] OP_RING_* opcodes are RESERVED. They are:
    //   - present in the opcode space (forward-compat)
    //   - accepted by is_known_opcode() (keeps decode semantics stable)
    //   - poisoned-on-fetch by cp_desc_fetch with ERR_OPCODE_RESERVED
    //     (implemented in Phase 4)
    //   They are intended for future PE Mesh / ring-buffer communication and
    //   MUST NOT be used by software in the current PE integration.
    // =========================================================================

    typedef enum logic [7:0] {
        OP_NOP           = 8'h00,
        // Vector
        OP_VEC_LOAD      = 8'h01,
        OP_VEC_STORE     = 8'h02,
        OP_VEC_ACT       = 8'h03,
        OP_VEC_RESADD    = 8'h04,   // [STEP4-E2E] residual add of two fast-path
                                    // capsules (operand_role SRC0/SRC1) -> L2
                                    // write-back. Maps to vec primitive VEC_RESADD.
        OP_VEC_RESADD_RESIDENT = 8'h05, // [HW-REVIEW T3-FF/FF1] resident-SRC1 RESADD:
                                    // SRC1 (residual) is read from L2 by the Vector.
                                    // A DISTINCT opcode so min_ext_for_opcode=4 forces
                                    // the contract words 6/7 (src1_resident + the SIGNED
                                    // src1_scale_ref) to be fetched and LOUD-REJECTS an
                                    // under-length descriptor (ERR_EXT_UNDERFLOW) — closing
                                    // the silent-degrade where residency+scale (both in
                                    // fetch pair3) zero out and run as a fast-path RESADD.
                                    // cp_scheduler normalizes it to OP_VEC_RESADD (and
                                    // forces src1_resident=1) for the frozen Vector adapter.
        // Tensor
        OP_TENS_GEMM     = 8'h10,
        OP_TENS_CONV     = 8'h11,
        // DMA
        OP_DMA_FILL      = 8'h20,
        OP_DMA_EVICT     = 8'h21,
        OP_DMA_MEMSET    = 8'h22,   // R7.4: constant fill (no NoC)
        // Control
        OP_BARRIER       = 8'h30,
        OP_WAIT          = 8'h31,   // [PHASE1-01] event-mask wait (see §6.4)
        // RESERVED: Ring buffer ops (PE Mesh future; poisoned by cp_desc_fetch)
        OP_RING_RESERVE  = 8'h40,   // [PHASE1-02] RESERVED — not supported
        OP_RING_CONSUME  = 8'h41,   // [PHASE1-02] RESERVED — not supported
        OP_RING_WAIT_GE  = 8'h42    // [PHASE1-02] RESERVED — not supported
    } desc_opcode_e;

    // [PHASE1-02] Helper: is this opcode currently supported by hardware?
    //   Used by cp_desc_fetch to poison RESERVED opcodes with ERR_OPCODE_RESERVED.
    //   Distinct from is_known_opcode() (which only checks enum membership).
    // [PHASE7-01] Helper signatures changed from `input logic [7:0] op` to
    // `input desc_opcode_e op` to eliminate 31 pyslang -Wcase-type warnings
    // caused by comparing `logic[7:0]` against enum-typed case labels. The
    // sole external caller (cp_desc_fetch) passes a `logic[7:0]` bit slice;
    // SystemVerilog permits implicit same-width integral-to-enum conversion
    // at the call site, so no caller changes are required.
    function automatic logic is_supported_opcode(input desc_opcode_e op);
        case (op)
            // [STEP4-E2E] OP_VEC_RESADD is now GRADUATED to supported (D5-2): the
            // cp_scheduler dispatch/credit/completion path is wired (vec_cmd_o
            // emit + res_avail + issue_ok + credit_dec + CTX_WAIT_VEC transition
            // + region_oob check_dst arm — all for OP_VEC_RESADD). So a
            // software-fetched RESADD descriptor is no longer poisoned at fetch;
            // it issues like LOAD/STORE/ACT (operands arrive on the fast path).
            // It was interim-reserved earlier (when no dispatch path existed) to
            // avoid a silent watchdog hang — that interim is now removed.
            OP_RING_RESERVE,
            OP_RING_CONSUME,
            OP_RING_WAIT_GE: return 1'b0;   // RESERVED, not implemented
            // [T3-FF/FF1] OP_VEC_RESADD_RESIDENT is supported (falls to default): it
            // dispatches like OP_VEC_RESADD (cp_scheduler normalizes it). It differs
            // only at fetch (min_ext_for_opcode=4 -> loud ERR_EXT_UNDERFLOW if short).
            default:         return 1'b1;   // all other known opcodes are supported
        endcase
    endfunction

    // =========================================================================
    // R3.2a: Opcode Validation Helpers (single source of truth)
    // =========================================================================

    // Minimum ext_len required for each opcode (based on real field needs).
    // ext_len >= min_ext is allowed (forward-compatible); ext_len < min_ext
    // is ILLEGAL (parameter words missing → silent corruption).
    function automatic logic [3:0] min_ext_for_opcode(input desc_opcode_e op);
        case (op)
            OP_NOP:                      return 4'd0;  // no params
            OP_BARRIER:                  return 4'd0;  // legacy fence; dep_mask ver uses ext>=1
            OP_WAIT:                     return 4'd1;  // D6: word[4] = event_mask
            OP_VEC_LOAD, OP_VEC_STORE:   return 4'd0;  // base 4 words sufficient
            OP_VEC_RESADD:               return 4'd0;  // operands via fast path; contract in w6/w7
            OP_VEC_RESADD_RESIDENT:      return 4'd4;  // [T3-FF/FF1] resident SRC1 needs
                                                        // words 6/7 (src1_resident + signed
                                                        // src1_scale_ref) -> full 8-word slot.
                                                        // ext_len<4 -> ERR_EXT_UNDERFLOW (loud).
            OP_VEC_ACT:                  return 4'd1;  // word[4] = act_type/scale/bias
            OP_DMA_FILL, OP_DMA_EVICT:   return 4'd1;  // word[4] = outer_count (2D)
            OP_DMA_MEMSET:               return 4'd2;  // word[4] = outer_count, word[5] = memset_val
            OP_TENS_GEMM, OP_TENS_CONV:  return 4'd2;  // word[4:5] = M/N/K or tile params
            OP_RING_RESERVE,
            OP_RING_CONSUME,
            OP_RING_WAIT_GE:             return 4'd0;  // RESERVED — value immaterial
                                                        // (poisoned at fetch anyway)
            default:                     return 4'd0;  // unknown → bad_opcode path
        endcase
    endfunction

    // R3.2a: Opcode validity check (v5 + forward-compat ring ops).
    //   Returns 1 for all defined opcodes, 0 for unknown.
    //   NOTE: OP_RING_* returns 1 here (they ARE known opcodes in the ISA),
    //   but is_supported_opcode() returns 0 for them (hardware doesn't run them).
    //   This split preserves forward-compat semantics.
    function automatic logic is_known_opcode(input desc_opcode_e op);
        case (op)
            OP_NOP, OP_BARRIER, OP_WAIT,
            OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT,
            OP_TENS_GEMM, OP_TENS_CONV,
            OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET,
            OP_RING_RESERVE, OP_RING_CONSUME, OP_RING_WAIT_GE:
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    // =========================================================================
    // 4. Descriptor Flags & Types
    // =========================================================================

    typedef struct packed {
        logic [4:0] reserved;       // [7:3]
        logic       last_in_batch;  // [2]
        logic       chain_next;     // [1]
        logic       irq_on_done;    // [0]
    } desc_flags_t;

    // Parsed descriptor header (= word 0)
    //
    // Bit layout of word 0:
    //   [7:0]   opcode
    //   [11:8]  ext_len
    //   [13:12] ctx_id
    //   [15:14] reserved
    //   [23:16] flags
    //   [31:24] reserved
    typedef struct packed {
        logic [7:0]    reserved_hi;  // [31:24]
        desc_flags_t   flags;        // [23:16]
        logic [1:0]    reserved_mid; // [15:14]
        logic [1:0]    ctx_id;       // [13:12]
        logic [3:0]    ext_len;      // [11:8]
        desc_opcode_e  opcode;       // [7:0]
    } desc_header_t;

    // L2 local address encoding (used in descriptor word 1 / word 2)
    //   [27:24] rid — Region Table index
    //   [15:0]  row_off — row offset within region
    typedef struct packed {
        logic [3:0]  reserved_hi;    // [31:28]
        logic [3:0]  rid;            // [27:24]
        logic [7:0]  reserved_mid;   // [23:16]
        logic [15:0] row_off;        // [15:0]
    } l2_addr_t;

    // Per-ctx descriptor slot (raw word storage)
    typedef logic [31:0] desc_slot_t [DESC_SLOT_WORDS];

    // =========================================================================
    // Descriptor field extraction helpers
    // =========================================================================

    function automatic desc_header_t get_header(input logic [31:0] word0);
        return desc_header_t'(word0);
    endfunction

    function automatic l2_addr_t get_l2_addr(input logic [31:0] word);
        return l2_addr_t'(word);
    endfunction

    function automatic logic [15:0] get_len_rows(input logic [31:0] word3);
        return word3[15:0];
    endfunction

    function automatic logic [15:0] get_stride_rows(input logic [31:0] word3);
        return word3[31:16];
    endfunction

    // =========================================================================
    // R3.4: Descriptor Extension Word Format Reserves
    //
    // v5 decodes ext words for opcodes with min_ext > 0.
    // These definitions document the planned field layout to prevent
    // future allocation conflicts.
    //
    // word[4] (ext index 0):
    //   - VEC_ACT:     [7:0]  activation_type, [15:8] scale, [23:16] bias
    //   - DMA_FILL/EVICT: [15:0] outer_count (2D), [31:16] reserved
    //     outer_count: 0 or 1 → 1D (backward compat). >1 → 2D strided.
    //   - DMA_MEMSET:  [15:0] outer_count (2D), [31:16] reserved
    //   - BARRIER:     [2:0]  dep_mask (when ext_len >= 1, see R4.2)
    //   - TENS_GEMM/CONV: [15:0] param_M, [31:16] param_N
    //   - OP_WAIT:     [EVT_W-1:0] event_mask, rest reserved
    //
    // word[5] (ext index 1):
    //   - TENS_GEMM/CONV: [15:0] param_K,
    //                     [17:16] n_cfg   ([3a-3] per-tile N:M 配置，M=4)
    //                     [19:18] M       (RESERVED-must-be-zero，M=8 的后手)
    //                     [31:20] RESERVED-must-be-zero
    //   - DMA_MEMSET:  [31:0] memset_val (constant pattern for all words)
    //
    // 🔴 [3a-3 2026-08-04] n_cfg 的编码是 tensor_pkg::ncfg_e（00=dense/N=4、01=1:4、
    //    10=2:4、11=保留），**唯一权威在 Tensor/tensor_pkg.sv**（本包不 import
    //    tensor_pkg，故这里只能是裸位注释 —— 别在本文件复制一份编码表，会分叉）。
    //    min_ext_for_opcode(OP_TENS_GEMM/CONV) 已 return 4'd2 ⇒ word[4:5] 必到达。
    // 🔴 **本片新开的敞口，登记指向 3a-7**：cp_desc_fetch 的 ST_FETCH_PAIR_N 今天
    //    **只有 wi==6 分支、没有 wi==4**（实测），即 word[5] 的高半字**零校验**。
    //    3a-3 之后，脏数据会被当 n_cfg 静默执行。3a-3 **不实现该守卫（正确分工）**，
    //    但 3a-7 补时门必须开在 OP_TENS_GEMM/CONV 上 —— word[5] 对 DMA_MEMSET 是
    //    memset_val，不门会误毒（规格 §1.3 原文）。
    //
    // word[6..7] (ext index 2..3):
    //   [PHASE1-06] RESERVED for tile_contract_t transport from software
    //   (see §6b for field definition). The scheduler slices tile_contract_t
    //   from slot_current_i[sel_ctx][6:7] in cp_scheduler (implemented in
    //   Phase 4). v5/v6 software should pack tile_contract_t into these two
    //   words when issuing block-scaled ops; legacy software leaving them 0
    //   produces a "no special contract" default.
    //
    // Compatibility rule:
    //   ext_len > min_ext_for_opcode is LEGAL (forward-compat padding).
    //   Extra ext words beyond min_ext MUST be 0 in v4/v5 for legacy ops.
    // =========================================================================

    // =========================================================================
    // R3.5 [PHASE1-04]: L2/NoC Transaction ID Reservation
    //
    // Reserved for future tagged L2/NoC request-response correlation,
    // enabling out-of-order completion. Currently tied to 0 throughout the
    // PE integration; l2_bank exposes pa_txn_id_i / pb_txn_id_i as stub
    // ports that propagate this value.
    //
    // Not currently scheduled for activation in any specific phase; will be
    // enabled when out-of-order L2 responses become useful (likely alongside
    // deeper L2 / multi-PE work).
    // =========================================================================
    parameter int TXN_ID_W = 4;  // 4-bit txn ID (up to 16 in-flight per port)

    // =========================================================================
    // R4.1/R4.2 + D3/R7.1: Scoreboard Credit & Tag Parameters
    //
    // D3: Multi-credit upgrade. TAG_W defines max inflight per unit (2^TAG_W).
    // Default credits: Vec=4 (streaming, hides L2 stalls), Tens=2 (compute-
    // bound, less benefit from deep pipeline), DMA=2 (serial AGU).
    //
    // [PHASE1 NOTE] The numeric defaults below are kept unchanged in Phase 1
    // (no semantic swap yet). The rename from vec<->tens has semantic and
    // wiring consequences; Phase 3/4/5 will re-evaluate whether the new
    // Tensor (now the GEMM workhorse) wants more credits than the new Vector.
    // For Phase 1, keep values stable to isolate Phase 1 risk to "types only".
    //
    // Architecture max = 2^TAG_W = 8 per unit. Default != max.
    //
    // "Unit idle" = (credit == DEFAULT).  "Has capacity" = (credit > 0).
    //
    // Tag lifecycle:
    //   Issue: alloc tag from freelist → write tag→ctx map → attach to cmd
    //   Done:  exec unit returns tag → lookup ctx → free tag → credit++
    // =========================================================================
    parameter int TAG_W = 3;                              // max 8 inflight/unit
    localparam int TAG_MAX = 1 << TAG_W;                  // 8

    parameter int SCOREBOARD_CREDITS_VEC  = 4;            // Vec default
    parameter int SCOREBOARD_CREDITS_TENS = 2;            // Tens default
    parameter int SCOREBOARD_CREDITS_DMA  = 2;            // DMA default

    // Max across all units — used for counter width
    localparam int SCOREBOARD_CREDITS_MAX = (SCOREBOARD_CREDITS_VEC > SCOREBOARD_CREDITS_TENS)
                                          ? ((SCOREBOARD_CREDITS_VEC > SCOREBOARD_CREDITS_DMA)
                                             ? SCOREBOARD_CREDITS_VEC : SCOREBOARD_CREDITS_DMA)
                                          : ((SCOREBOARD_CREDITS_TENS > SCOREBOARD_CREDITS_DMA)
                                             ? SCOREBOARD_CREDITS_TENS : SCOREBOARD_CREDITS_DMA);
    localparam int SCOREBOARD_CREDIT_W = $clog2(SCOREBOARD_CREDITS_MAX + 2);  // 3 bits for max=4
    // +2 (not +1): provides 1 bit of headroom for net-delta arithmetic.
    // Catches spurious done-without-issue as credit > MAX (assertion-detectable)
    // rather than silent wrap-around.

    // =========================================================================
    // R4.1: Watchdog Parameters
    // =========================================================================
    parameter int WD_CNT_W = 16;  // 16-bit saturating progress counter

    // =========================================================================
    // R4.2: BARRIER Dependency Mask Bit Positions (word[4][2:0])
    //
    // ext_len == 0: legacy global fence (all units idle)
    // ext_len >= 1: selective dep_mask from word[4]
    //   [0] = wait vec idle
    //   [1] = wait tens idle
    //   [2] = wait dma idle
    //   dep_mask = 0: no dependency, barrier passes immediately
    // =========================================================================
    localparam int DEP_MASK_VEC  = 0;
    localparam int DEP_MASK_TENS = 1;
    localparam int DEP_MASK_DMA  = 2;

    // =========================================================================
    // D6/R7.2: Event Mask Bit Positions (OP_WAIT word[4][EVT_W-1:0])
    //
    // Per-ctx event_pending accumulates sticky event bits. OP_WAIT issues
    // with an 8-bit mask; ctx enters CTX_WAIT_EVENT. When
    //   (event_pending & wait_mask) != 0
    // ctx wakes to CTX_RUNNABLE and matched bits are cleared.
    //
    // Event sources:
    //   [0] EVT_DONE_VEC  — this ctx's vec op completed
    //   [1] EVT_DONE_TENS — this ctx's tens op completed
    //   [2] EVT_DONE_DMA  — this ctx's dma op completed
    //   [3] EVT_DOORBELL  — this ctx received a doorbell write
    //   [4] EVT_IRQ       — any IRQ pending for this ctx
    //   [7:5] reserved (reads as 0)
    // =========================================================================
    localparam int EVT_W         = 8;
    localparam int EVT_DONE_VEC  = 0;
    localparam int EVT_DONE_TENS = 1;
    localparam int EVT_DONE_DMA  = 2;
    localparam int EVT_DOORBELL  = 3;
    localparam int EVT_IRQ       = 4;

    // =========================================================================
    // D8/R7.3: Event Trace Ring Buffer Parameters
    //
    // Records recent system events with timestamps for post-mortem debug.
    // IBEX reads via MMIO index+data pattern (TRACE_INDEX, TRACE_DATA).
    //
    // trace_entry_t layout (32-bit, packed):
    //   [31:16]  timestamp   — 16-bit free-running counter (wraps at 65536)
    //   [15:12]  event_type  — trace_evt_e encoding
    //   [11:10]  ctx_id      — context that generated event
    //   [9:0]    payload     — event-specific data
    //
    // Payload encoding per event_type (existing):
    //   ISSUE:        {2'b0, opcode[7:0]}
    //   DONE_VEC/TENS/DMA: {2'b0, tag[TAG_W-1:0], 5'd0}
    //   STATE_CHANGE: {old_state[3:0], new_state[3:0], 2'd0}
    //   EVENT_WAKE:   {2'b0, matched_mask[EVT_W-1:0]}
    //   ERROR:        {2'b0, err_class[3:0], 4'd0}
    //   DOORBELL:     10'd0
    //   CREDIT_STALL: {2'b0, unit[1:0], credit[CREDIT_W-1:0], 3'd0}
    //
    // [PHASE1-10] Payload encoding for new event types:
    //   FWD_HIT:      {2'b0, dest_hint[1:0], fragment_idx[1:0], 4'd0}
    //   FWD_MISS:     {2'b0, dest_hint[1:0], 6'd0} (indicates SRAM fallback)
    //   ESCAPE:       {2'b0, escape_reason[3:0], 4'd0}
    //   REQUANT:      {2'b0, dir[1:0], 6'd0} (dir: T→V=0, V→T=1)
    //   FETCH_STALL:  {2'b0, ctx_slot_state[1:0], 6'd0}
    //   CONTRACT_VIOLATION: {2'b0, violation_code[3:0], 4'd0}
    //
    // COLLECTOR STATUS (as of Phase 1):
    //   - All new event types have ENUM CODES reserved here.
    //   - Only CONTRACT_VIOLATION has no collector logic in Phase 1/4
    //     (there is no fast-path runtime check yet). FWD_HIT/MISS/ESCAPE/
    //     REQUANT collector logic will be added when the fast-path physical
    //     modules are implemented (post-Phase 6, "L3" in the roadmap).
    //   - FETCH_STALL can be collected in Phase 4 as a low-cost addition
    //     (cp_desc_fetch already knows when a ctx is waiting on fetch).
    // =========================================================================
    parameter int TRACE_DEPTH_LOG2 = 6;                       // 2^6 = 64 entries
    localparam int TRACE_DEPTH     = 1 << TRACE_DEPTH_LOG2;   // 64
    localparam int TRACE_AW        = TRACE_DEPTH_LOG2;        // 6-bit address
    localparam int TRACE_ENTRY_W   = 32;

    typedef enum logic [3:0] {
        TRACE_ISSUE              = 4'd0,   // descriptor issued to exec unit
        TRACE_DONE_VEC           = 4'd1,   // vec completion
        TRACE_DONE_TENS          = 4'd2,   // tens completion
        TRACE_DONE_DMA           = 4'd3,   // dma completion
        TRACE_STATE_CHG          = 4'd4,   // ctx state transition
        TRACE_EVENT_WAKE         = 4'd5,   // event-based wake-up from CTX_WAIT_EVENT
        TRACE_ERROR              = 4'd6,   // error descriptor or watchdog
        TRACE_DOORBELL           = 4'd7,   // doorbell pulse
        TRACE_CREDIT_STALL       = 4'd8,   // issue blocked on credit=0
        TRACE_SOFT_RESET         = 4'd9,   // soft reset event
        // [PHASE1-10] Fast-path / contract observability event codes:
        TRACE_FWD_HIT            = 4'd10,  // Tensor<->Vector fast path delivered
        TRACE_FWD_MISS           = 4'd11,  // fwd_eligible=1 but fallback to SRAM taken
        TRACE_ESCAPE             = 4'd12,  // block-scaled semantics escaped to high-prec
        TRACE_REQUANT            = 4'd13,  // re-quantization event at domain boundary
        TRACE_FETCH_STALL        = 4'd14,  // ctx runnable-ish but slot EMPTY waiting fetch
        TRACE_CONTRACT_VIOLATION = 4'd15   // runtime contract check failed (future use)
    } trace_evt_e;

    typedef struct packed {
        logic [15:0]  timestamp;     // [31:16] free-running counter
        trace_evt_e   event_type;    // [15:12] 4-bit event code
        logic [1:0]   ctx_id;        // [11:10] context
        logic [9:0]   payload;       // [9:0]   event-specific data
    } trace_entry_t;

    // =========================================================================
    // R4.3: IRQ System Parameters
    //
    // CP_IRQ pending register layout (12-bit):
    //   [3:0]   IRQ_ON_DONE     — from completion (desc_flags.irq_on_done)
    //   [7:4]   IRQ_ON_ERROR    — from error_valid (poisoned/OOB/bad_param)
    //   [11:8]  IRQ_ON_WATCHDOG — from wd_timeout
    //
    // Each group has 1 bit per ctx (ctx0=LSB within group).
    // CP_IRQ_MASK has the same layout; bit=1 → IRQ enabled.
    // irq_o = |(pending & mask)
    // =========================================================================
    localparam int IRQ_DONE_BASE = 0;   // [3:0]
    localparam int IRQ_ERR_BASE  = 4;   // [7:4]
    localparam int IRQ_WD_BASE   = 8;   // [11:8]
    localparam int IRQ_TOTAL_W   = 3 * NUM_CTX;  // 12 for NUM_CTX=4

    // =========================================================================
    // R5.1: Performance Counter Parameters
    //
    // All perf counters are 32-bit saturating (never wrap).
    // Clear on hard_reset and soft_reset. Freeze on overflow (stuck at MAX).
    //
    // CP-side counters (in cp_scheduler):
    //   ctx_blocked_cycles[i]   — cycles in CTX_BLOCKED
    //   ctx_barrier_stalls[i]   — cycles in CTX_BLOCKED on OP_BARRIER
    //   ctx_starved_cycles[i]   — cycles can_issue but lost RR arbitration
    //   total_issue_cnt         — total successful issues
    //   total_done_cnt          — total exec completions (any unit)
    //
    // L2-side counters (in l2_rw_arbiter, R5.2):
    //   bank_conflict_stalls    — total req-without-grant cycles (any master)
    //   vec_stall_cycles        — vec_req && !vec_gnt
    //   tens_stall_cycles       — tens_req && !tens_gnt
    //   dma_stall_cycles        — dma_fill_req && !dma_fill_gnt
    //
    // MMIO layout (within cp_csr 512B window):
    //   0xBC    PERF_CTRL           RW   [0] perf_cnt_en (default 1)
    //   0xC0    CTX0_BLOCKED_CYC    RO   ctx_blocked_cycles[0]
    //   0xC4-CC CTX1-3_BLOCKED_CYC  RO
    //   0xD0-DC CTX0-3_BARRIER_CYC  RO
    //   0xE0-EC CTX0-3_STARVED_CYC  RO
    //   0xF0    TOTAL_ISSUE_CNT     RO
    //   0xF4    TOTAL_DONE_CNT      RO
    //   0xF8    L2_CONFLICT_CNT     RO
    //   0xFC    L2_STALL_PACKED     RO   {dma[9:0],tens[9:0],vec[9:0],2'b0}
    // =========================================================================
    parameter int PERF_CNT_W = 32;

    // =========================================================================
    // 5. Region Table Entry
    //
    //   MMIO-writable; 4 entries.
    //   physical_row = region_table[rid].base_row + row_off
    // =========================================================================

    typedef struct packed {
        logic [15:0] num_rows;       // region size (rows)
        logic [15:0] base_row;       // starting row in SRAM
    } region_entry_t;

    // =========================================================================
    // 6. CP Context / Slot State Enums
    // =========================================================================

    // Context ID width (derived from NUM_CTX)
    localparam int CTX_ID_W = $clog2(NUM_CTX);   // = 2 for NUM_CTX=4

    typedef enum logic [3:0] {
        CTX_IDLE      = 4'd0,
        CTX_RUNNABLE  = 4'd1,
        CTX_WAIT_VEC  = 4'd2,
        CTX_WAIT_TENS = 4'd3,
        CTX_WAIT_DMA  = 4'd4,
        CTX_BLOCKED   = 4'd5,       // BARRIER / resource busy (auto-recoverable)
        CTX_DONE      = 4'd6,       // Ring empty + slots empty
        CTX_ERROR     = 4'd7,       // Illegal desc / watchdog — needs SW CLEAR_ERROR
        CTX_WAIT_EVENT = 4'd8       // D6: waiting for event mask match (OP_WAIT)
    } ctx_state_e;

    // Slot state for desc_current and desc_next
    typedef enum logic [1:0] {
        SLOT_EMPTY   = 2'd0,        // No descriptor in slot
        SLOT_VALID   = 2'd1,        // Fetched, not yet evaluated by scheduler
        SLOT_READY   = 2'd2,        // Resource available, can be issued
        SLOT_BLOCKED = 2'd3         // BARRIER/resource busy (re-evaluated each cycle)
    } slot_state_e;

    // =========================================================================
    // [PHASE1-06] 6b. Contract Type System
    //
    // This section defines the PE-level contract language that elevates
    // `data + scale + layout + policy` from compute-local detail to a
    // first-class architectural contract jointly understood by CP, exec
    // units, local SRAM, and (eventually) interconnect.
    //
    // Layering:
    //   - tile_contract_t (tile-level):  "what is this batch of data?"
    //       Carried on every cmd_t (vec/tens/dma). Scheduler slices it from
    //       descriptor ext words [6:7] (packing layout documented below).
    //       Constant over the entire tile / command.
    //   - frag_sideband_t (fragment-level, see §7b): "where is this fragment
    //       within the tile, and what is its current scale?"
    //       Travels with each fragment on the Tensor<->Vector fast path.
    //       Varies per fragment within a single tile.
    //
    // Design discipline:
    //   tile_contract_t describes ARCHITECTURAL intent (software-visible,
    //   part of the ISA/descriptor). Downstream microarchitectural
    //   translations (e.g. physical scale row = xlat_row(scale_rid,
    //   scale_row_off)) are internal to the scheduler / ingress adapter
    //   and MUST NOT leak back into tile_contract_t. This keeps the
    //   contract stable under microarchitectural refactoring.
    //
    // RESERVED-for-future entries in every enum permit ISA extension
    // without breaking packed widths.
    // =========================================================================

    // -------------------------------------------------------------------------
    // Element format enum (4 bits) — CANONICAL, unified at Step 2.
    //
    // [STEP2-MERGE] Reconciliation of the two pre-merge elem_fmt_e definitions:
    //   - v5 (this package) originally used a FMT_* taxonomy. It was pe_pkg-
    //     PRIVATE: no code outside this package referenced any FMT_* literal —
    //     only the package's own tile_contract helpers did.
    //   - v4 R-VEC §9 (now merged below) used an ELEM_* taxonomy described as
    //     "PE-level element format identifier, superset of UPE's internal mode",
    //     referenced by 50+ sites across the Vector tree (and it already carries
    //     ELEM_INT4 / ELEM_BFP_INTERNAL that Decisions Log §4 asked us to keep).
    // So the ELEM_* taxonomy is the canonical survivor, with its v4 encodings
    // preserved BIT-FOR-BIT (Vector value-dependent code is therefore unaffected).
    // The only additions are ELEM_FP16 (the one format the FMT_* set had that v4
    // lacked) in a former-reserved slot, and ELEM_NONE (the legacy "no-contract"
    // sentinel, was FMT_NONE) at 4'd15. tile_contract_t and its helpers below are
    // updated to ELEM_* names. See Decisions Log §4 + Design_Notes N12.
    //
    // The execution domain (Tensor or Vector) honors the format; an unimplemented
    // format must raise ERR_INVALID_PARAM (via poison-on-issue in Phase 4).
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ELEM_BF16         = 4'd0,   // Brain Float 16 (E8M7)
        ELEM_FP8_E4M3     = 4'd1,   // FP8 E4M3FN
        ELEM_FP8_E5M2     = 4'd2,   // FP8 E5M2
        ELEM_FP4_E2M1     = 4'd3,   // FP4 E2M1
        ELEM_INT8         = 4'd4,   // (unsigned) INT8
        ELEM_INT4         = 4'd5,   // (unsigned) INT4
        ELEM_MXFP8        = 4'd6,   // MX FP8 (block-scaled, OCP MX v1.0)
        ELEM_MXFP4        = 4'd7,   // MX FP4 (block-scaled, OCP MX v1.0)
        ELEM_MXINT8       = 4'd8,   // MX INT8 (2's comp, implicit 2^-6 scale)
        ELEM_BFP_INTERNAL = 4'd9,   // internal block-float representation
        ELEM_FP16         = 4'd10,  // [STEP2] FP16 E5M10 (was FMT_FP16; v4 RSVD10)
        ELEM_RSVD11       = 4'd11,
        ELEM_RSVD12       = 4'd12,
        ELEM_RSVD13       = 4'd13,
        ELEM_RSVD14       = 4'd14,
        ELEM_NONE         = 4'd15   // no contract / legacy path (was FMT_NONE)
    } elem_fmt_e;

    // Helper: does this format use block-scaled semantics (carry per-block scale)?
    function automatic logic fmt_is_block_scaled(input elem_fmt_e f);
        case (f)
            ELEM_MXFP8, ELEM_MXFP4, ELEM_MXINT8: return 1'b1;
            default:                             return 1'b0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // [C-1 2026-07-31] Which elem_fmt values can the TENSOR domain actually
    // EXECUTE **and EGRESS** in this tapeout?
    //
    // 🔴 WHY THIS EXISTS (cross-module fail-open, fail-open type 15):
    //   tensor_cmd_mmio_seq.sv is a TOTAL function by design — every elem_fmt
    //   maps to some tensor_mode_e, unimplemented ones falling back to BF16.
    //   Its comment delegated rejection to the CP ("Rejecting them is the CP's
    //   job (poison-on-issue -> ERR_INVALID_PARAM)") — but no such check
    //   existed: MISS_UNSUPPORTED_FMT had ZERO consumers repo-wide. Both sides
    //   assumed the other was the gate, so an illegal elem_fmt produced a
    //   SILENTLY WRONG capsule with no error. This function is that missing gate.
    //
    //   Sweep + registration: Review/UNWIRED_CAPABILITY_SWEEP_2026-07-31.md (C-1).
    //
    // REJECTED, and why each is NOT merely "unimplemented" but silently wrong:
    //   ELEM_INT8 / ELEM_INT4   -> map to MODE_UINT8 / MODE_UINT4_SIMD, which the
    //       array DOES compute, but the INT psum chain has NO reader in
    //       tensor_unit_top and egress only moves the FP accumulator ⇒ firmware
    //       receives a capsule that is not an error and not the answer.
    //   ELEM_FP8_E5M2           -> tensor_pkg.sv:114-117: "architecturally
    //       reserved but NOT supported in current RTL. All FP8 data paths assume
    //       E4M3FN bit-field layout." The $fatal guard in mac_lru.sv sits inside
    //       `synopsys translate_off` ⇒ SIMULATION ONLY, no protection in silicon.
    //       Requesting E5M2 would compute E4M3FN on E5M2 bits = wrong numbers.
    //   ELEM_BFP_INTERNAL       -> the capsule/transport representation produced
    //       by the packer, not an ingress operand format; falls back to BF16.
    //   ELEM_FP16 / ELEM_RSVD*  -> no tensor mode; fall back to BF16 silently.
    //
    // ACCEPTED:
    //   ELEM_NONE -> MUST stay accepted: make_default_contract() sets it and every
    //       existing bench issues that default; it maps to MODE_BF16 bit-for-bit
    //       (tensor_cmd_mmio_seq.sv:82-85). Rejecting it would break every bench.
    //
    // SCOPE: Tensor-dispatched opcodes ONLY (OP_TENS_*). elem_fmt has exactly two
    //   functional consumers repo-wide — tensor_cmd_mmio_seq.sv:111 (this domain)
    //   and vec_result_packer.sv:313 (carries it into the capsule without
    //   switching on it) — so a global reject would wrongly poison Vector ops
    //   that legitimately carry ELEM_BFP_INTERNAL.
    // -------------------------------------------------------------------------
    function automatic logic fmt_tensor_executable(input elem_fmt_e f);
        case (f)
            ELEM_BF16,          // -> MODE_BF16
            ELEM_FP8_E4M3,      // -> MODE_FP8   (FP8_FMT == FP8_E4M3FN)
            ELEM_FP4_E2M1,      // -> MODE_FP4
            ELEM_MXFP8,         // -> MODE_MXFP8
            ELEM_MXFP4,         // -> MODE_MXFP4
            ELEM_MXINT8,        // -> MODE_MXINT8
            ELEM_NONE:          // -> MODE_BF16 (legacy default, must stay legal)
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    // ------------------------------------------------------------------
    // [3a-7/P2 2026-08-05] (elem_fmt x N) cross-table — sparse-capable formats
    //
    // 判据（唯一定义处 = 规格 Tensor_Unit_Sparse_Doubling_Spec.md §1.3.1/§1.3.2）：
    //     N in {1,2} 合法  <=>  tensor_pkg::dense_pack_advance(mode) == 1
    //
    // 机理是结构性的，不是配置选择：tensor_tile_controller 的 sparse_k_advance()
    //   · N=4 臂  return pack_advance
    //   · N=2 臂  return 8'd2      <- 不乘 pack_advance
    //   · N=1 臂  return {4,0}     <- 不乘 pack_advance
    // 故 pack_advance != 1 的格式在非 dense 档下 K 游标少推 2x/4x，静默错果。
    //
    // 🔴 分叉风险登记（本函数是【派生知识的第二份拷贝】）：
    //   本包**刻意不 import tensor_pkg**（见 word[5] 注释块的同款说明），且
    //   elaborate 靶 T30 的源清单里没有 tensor_pkg.sv ⇒ 这里只能内联结果集。
    //   dense_pack_advance 实测：FP4/MXFP4/UINT4_SIMD -> 4；FP8/MXFP8 -> 2；default -> 1。
    //   映射 elem_fmt -> mode 用的是紧邻上方 fmt_tensor_executable 的同一份注释列。
    //   ⇒ 结果集 = {ELEM_BF16, ELEM_MXINT8, ELEM_NONE}（ELEM_NONE -> MODE_BF16）。
    //   **改 dense_pack_advance 或改 fmt->mode 映射，必须同批改本函数。**
    //   一致性由 P2 红臂脚本的静态自检守（从 tensor_pkg 反算该集合并逐字比对本函数）。
    //
    // 本函数【只回答 sparse 合法性】，不回答「该格式能否执行」——
    // 后者仍归 fmt_tensor_executable，两者在 cp_desc_fetch 里是**合取**关系，
    // 🔴 禁把本函数的结果并进 fmt_tensor_executable 的白名单（那会改掉 C-1 的红样本）。
    function automatic logic fmt_allows_sparse(input elem_fmt_e f);
        case (f)
            ELEM_BF16,          // -> MODE_BF16    : pack_advance = 1
            ELEM_MXINT8,        // -> MODE_MXINT8  : pack_advance = 1
            ELEM_NONE:          // -> MODE_BF16    : pack_advance = 1 (legacy default)
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Block size log2 enum (2 bits)
    //
    // Enumerates the ARCHITECTURE-supported block grouping sizes.
    // Matches Master Plan §1.1 strategy: baseline 32, sensitivity point 16.
    // Non-block-scaled formats (ELEM_BF16 etc.) ignore this field.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        BS_16           = 2'd0,    // block of 16 elements per scale
        BS_32           = 2'd1,    // block of 32 elements per scale (baseline)
        BS_RESERVED_2   = 2'd2,
        BS_RESERVED_3   = 2'd3
    } block_size_log2_e;

    // Helper: number of fragments per block at FRAG_ELEMS=16
    //   BS_16 -> 1 fragment/block;  BS_32 -> 2 fragments/block.
    function automatic logic [1:0] frags_per_block(input block_size_log2_e bs);
        case (bs)
            BS_16:   return 2'd1;
            BS_32:   return 2'd2;
            default: return 2'd1;   // treat reserved as BS_16 (safest default)
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // Destination hint enum (2 bits) — tile-result routing class (PE contract).
    //
    // Advises the producing execution domain where the TILE RESULT should go:
    //   DEST_WB         — classical writeback to local L2 scratchpad
    //   DEST_FWD_TENS   — forward to Tensor domain via Tensor<->Vector fast path
    //   DEST_FWD_VEC    — forward to Vector domain via fast path
    //   DEST_ESCAPE     — controlled escape to high-prec path (block-scaled
    //                     semantics cannot be preserved safely)
    //
    // [STEP2-MERGE] The 4'd0 literal was renamed DEST_SRAM -> DEST_WB to avoid a
    // name clash with the §9 capsule-level destination_hint_e.DEST_SRAM (=2'd2),
    // which the merge brought into this same package. The two enums are kept
    // DISTINCT on purpose: dest_hint_e is the PE tile-contract result-routing
    // class; destination_hint_e (§9) is the wire-capsule preferred next
    // destination. Only DEST_WB is referenced outside the typedef (in
    // default_tile_contract); no external code depends on the old literal.
    //
    // The fast-path router (future, post-Phase 6) consumes this field.
    // For Phase 1-6, DEST_WB is the universal default and other values
    // are accepted but not yet acted upon.
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        DEST_WB         = 2'd0,
        DEST_FWD_TENS   = 2'd1,
        DEST_FWD_VEC    = 2'd2,
        DEST_ESCAPE     = 2'd3
    } dest_hint_e;

    // -------------------------------------------------------------------------
    // tile_contract_t — the tile-level architectural contract
    //
    // Packing width: 64 bits (exactly 2 × 32-bit descriptor ext words).
    // Layout (software-visible, stable across v5/v6):
    //
    //   word[6] (32b):
    //     [3:0]    elem_fmt          — elem_fmt_e
    //     [5:4]    block_size_log2   — block_size_log2_e
    //     [7:6]    dest_hint         — dest_hint_e
    //     [8]      fwd_eligible      — 1=may take fast path; 0=must go via SRAM
    //     [9]      half_sel          — [D1/D7] descriptor-driven L2 half-stripe
    //                                   placement for the Vector 256b narrow master:
    //                                   0=banks 0-7 (lo half), 1=banks 8-15 (hi half).
    //                                   Tensor (512b full stripe) ignores it. CPU
    //                                   assigns complementary halves STATICALLY —
    //                                   deterministic placement; bandwidth comes from
    //                                   arbiter timing (Tens-Yield), not dynamic
    //                                   placement (see D7 / Design_Notes N6). The
    //                                   physical vec_*_half_sel_o ports already exist
    //                                   in vector_unit_top (tied to 0 in Phase 2b);
    //                                   wiring this field to them is Step-4 integration.
    //     [15:10]  pertensor_scale_id— [D13] 6-bit id into the IBEX-software per-tensor
    //                                   FP32 scale table (NVFP4 outermost scale). The
    //                                   scale VALUE lives in control-plane software;
    //                                   hardware carries only this reference and applies
    //                                   it ONLY on a Class-C escape — there is NO FP32
    //                                   multiply in the datapath (see D13 / Design_Notes
    //                                   N7). 0 = no per-tensor scale (identity). 6 bits /
    //                                   64 ids cover one layer's tensors x 4 ctx x
    //                                   cross-layer pipelining without remap.
    //     [19:16]  scale_rid         — Region Table index for scale bank
    //     [27:20]  scale_epoch       — [STEP2 §4] 8-bit rotating epoch for contract-
    //                                   preserving pipelines; mismatch triggers escape/
    //                                   requant. Widened 4b->8b to match the §9
    //                                   bs_capsule_t.scale_epoch (8b) and vec_ctrl_t,
    //                                   so the epoch compares consistently across the
    //                                   PE-contract / capsule / Vector-internal layers.
    //     [28]     src1_resident     — [STEP4-E2E §11.4] RESADD SRC1 source:
    //                                   0=fast-path capsule, 1=resident L2 (read at
    //                                   src_row). Ignored for non-RESADD opcodes.
    //     [31:29]  reserved (must be zero in v5)
    //
    //   word[7] (32b):
    //     [15:0]   scale_row_off     — row offset within scale region
    //     [31:16]  src1_scale_ref    — [HW-REVIEW T3] SIGNED (two's-complement) absolute
    //                                   block exponent of the resident SRC1 residual, used
    //                                   to align it against SRC0 in a resident RESADD. Only
    //                                   meaningful for OP_VEC_RESADD_RESIDENT (which forces
    //                                   this word to be fetched, min_ext=4); software MUST
    //                                   set it for a resident RESADD (0 = exp0). Decoded by
    //                                   extract_tile_contract (pe_pkg) -> tile_contract_t.
    //                                   (Was "reserved must-be-zero in v5"; the T3 merge
    //                                   repurposed it but left this doc stale — fixed FF1.)
    //
    // The struct below is the HARDWARE-facing packed representation, used
    // on internal command buses. Software writes via the word[6:7] layout
    // above; the scheduler (Phase 4) slices tile_contract_t from ext words.
    //
    // IMPORTANT: scale_rid + scale_row_off is the ARCHITECTURE-VISIBLE
    // addressing scheme (consistent with l2_addr_t in §4). Microarchitectural
    // modules may internally derive a physical scale_row via xlat_row() but
    // that derived form is not part of the contract.
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic signed [15:0] src1_scale_ref;    // word[7][31:16]  [HW-REVIEW T3] resident SRC1
                                               //   absolute block exponent (software-provided);
                                               //   propagates via CP contract-copy to the residual
        logic [15:0]      scale_row_off;       // word[7][15:0]
        logic [7:0]       scale_epoch;         // word[6][27:20]  [STEP2 §4] 4b->8b
        logic [3:0]       scale_rid;           // word[6][19:16]
        logic [5:0]       pertensor_scale_id;  // word[6][15:10]  [D13] NVFP4 per-tensor
                                               //   FP32 scale id (software table ref)
        logic             half_sel;            // word[6][9]      [D1/D7] L2 half-stripe
                                               //   placement: 0=lo (banks 0-7), 1=hi (8-15)
        logic             src1_resident;       // word[6][28]     [STEP4-E2E §11.4] RESADD SRC1
                                               //   source: 0=fast-path capsule, 1=resident L2
                                               //   (Vector reads the residual at src_row)
        logic             fwd_eligible;        // word[6][8]
        dest_hint_e       dest_hint;           // word[6][7:6]
        block_size_log2_e block_size_log2;     // word[6][5:4]
        elem_fmt_e        elem_fmt;            // word[6][3:0]
    } tile_contract_t;

    // Canonical "no-contract" / legacy default.
    //   Any cmd not carrying a meaningful contract (e.g. legacy OP_VEC_STORE
    //   with ext_len==0) uses this value.
    function automatic tile_contract_t default_tile_contract();
        tile_contract_t c;
        c.elem_fmt           = ELEM_NONE;
        c.block_size_log2    = BS_32;       // harmless default (unused when ELEM_NONE)
        c.dest_hint          = DEST_WB;
        c.fwd_eligible       = 1'b0;
        c.src1_resident      = 1'b0;        // [STEP4-E2E §11.4] default = fast-path SRC1
        c.half_sel           = 1'b0;        // [D1/D7] default lo half-stripe
        c.scale_epoch        = 8'd0;        // [STEP2 §4] widened 4b->8b
        c.scale_rid          = 4'd0;
        c.pertensor_scale_id = 6'd0;        // [D13] 0 = no per-tensor scale (identity)
        c.scale_row_off      = 16'd0;
        c.src1_scale_ref     = 16'sd0;      // [HW-REVIEW T3] default exp0 residual
        return c;
    endfunction

    // Extract tile_contract_t from descriptor ext words [6:7].
    //   w6 = slot_current[sel_ctx][6]
    //   w7 = slot_current[sel_ctx][7]
    //   (When min_ext_for_opcode < 2, software should leave w6/w7 = 0 and
    //    this returns default_tile_contract() in effect.)
    function automatic tile_contract_t extract_tile_contract(
        input logic [31:0] w6,
        input logic [31:0] w7
    );
        tile_contract_t c;
        c.elem_fmt           = elem_fmt_e'(w6[3:0]);
        c.block_size_log2    = block_size_log2_e'(w6[5:4]);
        c.dest_hint          = dest_hint_e'(w6[7:6]);
        c.fwd_eligible       = w6[8];
        c.half_sel           = w6[9];          // [D1/D7]
        c.src1_resident      = w6[28];         // [STEP4-E2E §11.4] RESADD resident SRC1
        c.pertensor_scale_id = w6[15:10];      // [D13]
        c.scale_rid          = w6[19:16];
        c.scale_epoch        = w6[27:20];      // [STEP2 §4] 8-bit
        c.scale_row_off      = w7[15:0];
        c.src1_scale_ref     = signed'(w7[31:16]); // [HW-REVIEW T3] resident SRC1 abs block exp
        return c;
    endfunction

    // =========================================================================
    // 7. Execution Unit Command Types
    //
    //   Issued by cp_scheduler after RID → physical_row translation.
    //   These carry physical addresses, not RID+offset.
    //
    // [PHASE1-07] RENAME: vec_cmd_t <-> tens_cmd_t semantic reversal.
    //   Post-Phase 1 semantics:
    //     tens_cmd_t — commands for the Tensor execution domain
    //                  (GEMM workhorse, 512b / full-stripe / 16-bank).
    //                  Carries M/N/K GEMM tile parameters.
    //     vec_cmd_t  — commands for the Vector execution domain
    //                  (scale-aware transform engine, 256b / half-stripe /
    //                  8-bank). M/N/K not meaningful here.
    //
    //   Both carry tile_contract_t. dma_cmd_t also carries it.
    //   Legacy cmd issuance (no contract in descriptor) fills
    //   default_tile_contract().
    //
    // [PHASE1 NOTE] The port widths (FULL_STRIPE_W for tens, HALF_STRIPE_W
    // for vec) are NOT inside these cmd_t structs — they belong on the
    // data-path ports of the exec units themselves (Phase 3/5/6 wiring).
    // The cmd_t structs carry only control-plane fields.
    // =========================================================================

    // -------------------------------------------------------------------------
    // tens_cmd_t — Tensor domain command (GEMM workhorse)
    //
    // Post-[PHASE1-07], this carries the semantics previously attached to
    // the WIDE (512b) execution slot, and hosts M/N/K fields for GEMM.
    // -------------------------------------------------------------------------
    typedef struct packed {
        desc_opcode_e              opcode;
        logic [L2_BANK_AW-1:0]     src_row;      // Physical row (post-xlat)
        logic [L2_BANK_AW-1:0]     dst_row;
        logic [15:0]               len_rows;
        logic [15:0]               stride_rows;
        logic [1:0]                ctx_id;
        desc_flags_t               flags;
        logic [15:0]               param_M;      // GEMM tile dims (from ext words)
        logic [15:0]               param_N;
        logic [15:0]               param_K;
        // [3a-3] per-tile N:M 配置，来自 word[5][17:16]。
        // 🔴 裸 logic [1:0]，不是 tensor_pkg::ncfg_e —— pe_pkg 不 import tensor_pkg
        //    （elaborate_smoke 的 T1/T2 靶把 pe_pkg/cp_scheduler 单独 elaborate，
        //     引 tensor_pkg 会让那两个靶要多带一个文件）。语义在 Tensor 域收敛：
        //    tensor_cmd_mmio_seq 把它写进 MMIO 0x08[3:2]，decoder 侧才转成 ncfg_e。
        // 🔴 三个 tb 载体（tb_tensor_cmd_mmio_seq / tb_tensor_gemm_chain / tb_soc_e2e）
        //    都以 `cmd = '0;` 起手再逐字段赋值 ⇒ 新字段自动 dense，不会假红；
        //    但**也正因为如此，漏接是纯静默的**（见本字段在 mmio_seq 的消费点注释）。
        logic [1:0]                n_cfg;
        logic [TAG_W-1:0]          tag;          // scoreboard tag
        tile_contract_t            contract;     // [PHASE1-07] architectural contract
    } tens_cmd_t;

    // -------------------------------------------------------------------------
    // vec_cmd_t — Vector domain command (scale-aware transform engine)
    //
    // Post-[PHASE1-07], this carries the semantics previously attached to
    // the NARROW (256b) execution slot. M/N/K intentionally absent; Vector
    // operations are fragment/row-parallel, not matmul-dimensioned.
    // -------------------------------------------------------------------------
    typedef struct packed {
        desc_opcode_e              opcode;
        logic [L2_BANK_AW-1:0]     src_row;
        logic [L2_BANK_AW-1:0]     dst_row;
        logic [15:0]               len_rows;
        logic [15:0]               stride_rows;
        logic [1:0]                ctx_id;
        desc_flags_t               flags;
        logic [TAG_W-1:0]          tag;
        tile_contract_t            contract;     // [PHASE1-07] architectural contract
                                                 //   ([HW-REVIEW T3] carries src1_scale_ref for resident RESADD)
        logic [L2_BANK_AW-1:0]     sidecar_base; // [T3-FF/FF3b-c] physical scale-sidecar row =
                                                 //   xlat_row(contract.scale_rid, scale_row_off); 0 unless resident RESADD
    } vec_cmd_t;

    // -------------------------------------------------------------------------
    // dma_cmd_t — DMA engine command
    //
    // [PHASE1-08] DMA carries tile_contract_t so that data movement is
    // contract-aware (e.g. DMA knows whether what it moves is block-scaled
    // and whether a paired scale bank transfer is implied).
    //
    // For legacy FILL/EVICT of raw bytes, contract == default_tile_contract()
    // and the DMA engine treats the payload as opaque words.
    // -------------------------------------------------------------------------
    typedef struct packed {
        desc_opcode_e              opcode;
        logic [31:0]               noc_addr;      // Flat NoC byte address
        logic [3:0]                l2_rid;        // Region index (for future AGU use)
        logic [L2_BANK_AW-1:0]     l2_row;        // Physical row (post-xlat)
        logic [15:0]               len_rows;      // Inner loop: rows per iteration
        logic [15:0]               stride_rows;   // 2D: row stride between outer iterations
        logic [15:0]               outer_count;   // 0 or 1 = 1D; >1 = 2D strided
        logic [31:0]               memset_val;    // constant value for OP_DMA_MEMSET
        logic [1:0]                ctx_id;
        desc_flags_t               flags;
        logic [TAG_W-1:0]          tag;
        tile_contract_t            contract;      // [PHASE1-08] architectural contract
    } dma_cmd_t;

    // =========================================================================
    // [PHASE1-09] 7b. Fast Path Sideband Types
    //
    // Sideband carried alongside every fragment on the Tensor<->Vector
    // fast path. Distinct from tile_contract_t: whereas tile_contract_t
    // describes the WHOLE tile and is constant over a command, this
    // sideband describes the SINGLE FRAGMENT currently crossing the
    // domain boundary.
    //
    // Scoping discipline (Q20 resolution):
    //   This sideband carries ONLY fast-path-LOCAL semantics:
    //     - last_frag_in_block  — serves 16/32 block-size semantics
    //     - last_frag_in_row    — serves tensor_egress_fragmentizer row-scan
    //   Higher-layer transfer-unit semantics (capsule boundaries, inter-PE
    //   packet boundaries, NoC beats) are intentionally NOT encoded here.
    //   They belong to a future routing-layer sideband — not to this
    //   PE-local Tensor<->Vector fast-path contract.
    //
    // Scale redundancy policy (Q11 resolution):
    //   Scale is carried in EVERY fragment sideband, not just the first
    //   fragment of a block. This makes each fragment a self-describing
    //   packet: the receiver needs no cross-fragment state for correct
    //   block-scaled interpretation. The ~3% overhead (8b scale vs 256b
    //   payload) is worth the simplification of the receive path.
    //
    // Packed width: 16 bits total (enables compact sideband routing;
    // 2 bits headroom within typical 2-byte sideband lanes).
    // =========================================================================
    typedef struct packed {
        logic             last_frag_in_row;    // [15]    end of an egress row-scan
        logic             last_frag_in_block;  // [14]    end of block_size_log2 grouping
        logic [1:0]       fragment_idx;        // [13:12] 0..3 (BS_16: only 0;
                                                //                BS_32: 0 or 1)
        logic [3:0]       scale_epoch;         // [11:8]  copied from tile_contract;
                                                //          redundancy guard for reorder
        logic [7:0]       scale;               // [7:0]   E8M0 shared exponent
                                                //          (OCP MX block scale)
    } frag_sideband_t;

    // Canonical "no-sideband" for fragments that don't carry block-scaled data
    // (e.g. legacy raw-byte FP16 streams).
    function automatic frag_sideband_t default_frag_sideband();
        frag_sideband_t s;
        s.last_frag_in_row   = 1'b0;
        s.last_frag_in_block = 1'b0;
        s.fragment_idx       = 2'd0;
        s.scale_epoch        = 4'd0;
        s.scale              = 8'd0;
        return s;
    endfunction

    // =========================================================================
    // 8. Arbiter Master ID (per-bank arbitration)
    //
    // [PHASE1-ADDENDUM / PHASE3-B2] Semantic binding swap.
    //
    // Phase 1 originally left the enum body unchanged (v4 semantics:
    // ARB_VEC = wide 512b master, ARB_TENS = narrow 256b master) with a
    // note that Phase 3 would rewire it. Phase 3 Batch 2 now atomically
    // performs that rewire together with the arbiter rename, so that
    // name and semantics align throughout the tree.
    //
    // Post-Phase-3-B2 semantic binding:
    //   ARB_TENS = 3'd1  — Tensor domain master (FULL_STRIPE_W = 512b,
    //                      16 banks, GEMM workhorse, highest non-DMA
    //                      priority in the RW arbiter)
    //   ARB_VEC  = 3'd2  — Vector domain master (HALF_STRIPE_W = 256b,
    //                      8 banks via half_sel, mid priority)
    //   ARB_DMA_FILL / ARB_DMA_EVICT  — DMA masters, lowest priority
    //
    // The numeric codes 3'd1 and 3'd2 are retained from the v4 enum body,
    // but the NAME→CODE mapping has swapped: ARB_TENS now = 3'd1
    // (was ARB_VEC = 3'd1 in v4), and ARB_VEC now = 3'd2 (was ARB_TENS).
    // Any downstream code that compared a logged arb_master_e numeric
    // value to a literal would need review — none exists in the current
    // tree, verified at Phase 3 Batch 2 commit time.
    //
    // Design discipline note: enum VALUES do NOT encode priority.
    // "Lower value = higher priority" is NOT a property this enum
    // guarantees — the arbiter priority table is hardcoded in the
    // arbiter logic. The values here are identifiers, not priorities.
    //
    // This is the only Phase 1 file addendum in the entire Phase 3
    // effort, scoped strictly to arb_master_e. See discussion around
    // D18-b in the Phase 3 planning notes.
    // =========================================================================

    typedef enum logic [2:0] {
        ARB_NONE       = 3'd0,
        ARB_TENS       = 3'd1,   // [PHASE3-B2] was ARB_VEC = 3'd1 in v4
        ARB_VEC        = 3'd2,   // [PHASE3-B2] was ARB_TENS = 3'd2 in v4
        ARB_DMA_FILL   = 3'd3,
        ARB_DMA_EVICT  = 3'd4
    } arb_master_e;

    // =========================================================================
    // 9. BFP Dataflow Contract Types (R-VEC)  —  [STEP2-MERGE]
    //
    // Merged verbatim from the v4 R-VEC §9 contract (was
    // Vector/Unchanged/PE/pe_pkg.sv:614-796), which until Step 2 was the ONLY
    // pe_pkg the Vector tree compiled against. These types define the
    // "first-class architectural contract" for block-scaled operand flow across
    // Tensor / Vector / SRAM / interconnect, and are consumed EXCLUSIVELY by the
    // Vector tree (bs_capsule_t, vec_exec_desc_t, scale_format_e, ...).
    //
    // Merge notes (see Decisions Log §4, Design_Notes N12):
    //   - elem_fmt_e is NOT re-declared here — the canonical ELEM_* enum lives in
    //     §6b above (the v4 ELEM_* taxonomy, preserved bit-for-bit, is the SSOT).
    //     bs_capsule_t / vec_exec_desc_t below reference that canonical type.
    //   - destination_hint_e keeps its v4 literals (DEST_TENSOR/VECTOR/SRAM/NOC).
    //     It is DISTINCT from the §6b tile-contract dest_hint_e (whose 4'd0 was
    //     renamed DEST_SRAM->DEST_WB to clear the literal clash). These two enums
    //     model two different layers and are intentionally kept separate.
    //   - block_size_sel_e (capsule) parallels §6b block_size_log2_e (contract):
    //     same encoding (16=0, 32=1), different type names per layer; the
    //     three-layer mapping table records the 1:1 correspondence.
    //
    // Key invariant: scale_format + block_size + scale_epoch are the three fields
    // that MUST be checked on fast-path ingress. A mismatch in any MUST produce a
    // miss (never silent data corruption).
    // =========================================================================

    // ── Scale Format ──
    //   Identifies the shared-factor encoding carried by block-scaled operands.
    //   v1 formally supports E8M0 (MX-style) and E4M3 (NV-like).
    typedef enum logic [2:0] {
        SCALE_E8M0          = 3'd0,   // MX-style: pure 2^e shared factor (OCP MX v1.0)
        SCALE_E4M3          = 3'd1,   // NV-like: E4M3 shared factor
        SCALE_INLINE_BFP    = 3'd2,   // reserved: inline BFP representation
        SCALE_PTR           = 3'd3,   // reserved: pointer-based scale
        SCALE_INDEXED       = 3'd4,   // reserved: indexed scale
        SCALE_NONE          = 3'd7    // no scale metadata (pure element format)
    } scale_format_e;

    // ── Block Size Selection ──
    //   v1: only BLOCK_SIZE_16 and BLOCK_SIZE_32 are supported.
    //   Decoder must reject other values (ERR_BAD_BLOCK_SIZE).
    typedef enum logic [1:0] {
        BLOCK_SIZE_16   = 2'd0,   // 16 elements per block
        BLOCK_SIZE_32   = 2'd1,   // 32 elements per block (baseline)
        BLOCK_SIZE_RSVD2 = 2'd2,  // reserved
        BLOCK_SIZE_RSVD3 = 2'd3   // reserved
    } block_size_sel_e;

    // [STEP2] Bridge between the two parallel block-size enums:
    //   block_size_log2_e (tile_contract_t, PE layer, §6b)  <->
    //   block_size_sel_e  (bs_capsule_t,  wire layer, §9).
    // They share the same encoding (16 -> 2'd0, 32 -> 2'd1); these make the
    // contract<->capsule correspondence explicit and compile-checked so Step-4
    // capsule formation can't silently diverge. See
    // Review/Three_Layer_Contract_Map.md §1/§4.
    function automatic block_size_sel_e bs_sel_from_log2(input block_size_log2_e b);
        case (b)
            BS_16:   return BLOCK_SIZE_16;
            BS_32:   return BLOCK_SIZE_32;
            default: return BLOCK_SIZE_16;   // reserved -> safest (1 frag/block)
        endcase
    endfunction
    function automatic block_size_log2_e bs_log2_from_sel(input block_size_sel_e b);
        case (b)
            BLOCK_SIZE_16: return BS_16;
            BLOCK_SIZE_32: return BS_32;
            default:       return BS_16;
        endcase
    endfunction

    // ── Producer Domain ──
    //   Identifies which execution domain produced a capsule (provenance).
    typedef enum logic [1:0] {
        DOMAIN_TENSOR   = 2'd0,   // produced by Tensor Unit
        DOMAIN_VECTOR   = 2'd1,   // produced by Vector Unit
        DOMAIN_SRAM     = 2'd2,   // loaded from local SRAM (resident fetch)
        DOMAIN_EXTERNAL = 2'd3    // loaded from NoC / external (future)
    } producer_domain_e;

    // ── Destination Hint (capsule-level) ──
    //   Preferred next destination for a result capsule. Distinct from the §6b
    //   tile-contract dest_hint_e (result-routing class). PE residency manager
    //   uses this for path-select decisions.
    typedef enum logic [1:0] {
        DEST_TENSOR = 2'd0,   // prefer Tensor Unit
        DEST_VECTOR = 2'd1,   // prefer Vector Unit
        DEST_SRAM   = 2'd2,   // prefer local SRAM (keep-local)
        DEST_NOC    = 2'd3    // prefer NoC / writeback
    } destination_hint_e;

    // ── Operand Role ──
    //   Which operand position this capsule fulfills in a multi-operand
    //   primitive (e.g. VEC_RESADD src0 vs src1). Produced by the PE scheduler /
    //   contract layer; consumed by the Vector Unit FSM for operand latch dispatch.
    typedef enum logic {
        OP_SRC0 = 1'b0,    // primary operand (always present)
        OP_SRC1 = 1'b1     // secondary operand (for dual-operand primitives)
    } operand_role_e;

    // ── Fast Path Miss Reason ──
    //   When a capsule cannot be accepted by the target ingress, the miss reason
    //   is reported back for PE-level fallback decisions. Shared across Tensor
    //   and Vector fast-path endpoints.
    typedef enum logic [3:0] {
        MISS_NONE            = 4'd0,   // no miss (accepted)
        MISS_BLOCK_SIZE      = 4'd1,   // unsupported block_size
        MISS_SCALE_FORMAT    = 4'd2,   // unsupported scale_format
        MISS_EPOCH           = 4'd3,   // scale_epoch mismatch
        MISS_LAYOUT          = 4'd4,   // layout_tag not consumable
        MISS_BUSY            = 4'd5,   // target unit busy / queue full
        MISS_NOFWD           = 4'd6,   // fwd_eligible == 0
        MISS_MULTI_CONSUMER  = 4'd7,   // multi_consumer conflict
        MISS_POLICY_ESCAPE   = 4'd8,   // escape policy requires fallback
        MISS_BAD_PRIMITIVE   = 4'd9,   // primitive not supported by target
        MISS_UNSUPPORTED_FMT = 4'd10   // elem_fmt not consumable
        // 11-15: reserved
    } fp_miss_reason_e;

    // ── Capsule Payload Width ──
    //   256 bits = 32 bytes = one L2 row half (16 banks × 32b / 2).
    //   Sufficient for 32 × FP8 elements or 16 × BF16 elements per capsule.
    parameter int BS_CAP_PAYLOAD_W = 256;

    // ── Block-Scaled Capsule ──
    //   The fundamental data object flowing through the Tensor↔Vector fast path
    //   and PE fabric: payload data together with full block-scaled contract
    //   metadata. NOT a raw bypass — a contract-preserving capsule channel.
    typedef struct packed {
        logic [BS_CAP_PAYLOAD_W-1:0] payload;          // element data
        elem_fmt_e                   elem_fmt;          // per-element encoding (§6b canonical)
        block_size_sel_e             block_size;        // block grouping size
        scale_format_e               scale_format;      // shared factor format
        logic [3:0]                  layout_tag;        // data layout identifier
        // [HW-REVIEW T3] scale_ref carries the signed ABSOLUTE block reference exponent
        // when inline_scale[BS_ABS_EXP_BIT]=1 (the converter-free RESADD alignment scale,
        // unclamped). Legacy (bit=0): scale_ref is the sidecar idx / ptr (=0 today).
        logic [15:0]                 scale_ref;         // abs block exp (bit8=1) | sidecar idx
        // [HW-REVIEW T3] inline_scale layout:
        //   [7:0]  = E4M3/E8M0 shared-scale byte (mant_corr + external NVFP4 scale; clamped)
        //   [8]    = BS_ABS_EXP_BIT (ABS_EXP_PRESENT): 1 => align by scale_ref, not the byte exp
        //   [31:9] = reserved (0)
        logic [31:0]                 inline_scale;      // {reserved, abs_present[8], scale_byte[7:0]}
        logic                        scale_inline_valid;// inline_scale is populated
        logic [7:0]                  scale_epoch;       // metadata consistency token
        logic [3:0]                  round_sat_policy;  // rounding / saturation mode
        logic [1:0]                  escape_hint;       // escape policy bits
        destination_hint_e           dest_hint;         // preferred destination
        logic                        fwd_eligible;      // fast-path forward allowed
        logic                        multi_consumer;    // >1 consumer expected
        operand_role_e               operand_role;      // which operand position (src0/src1)
        logic [CTX_ID_W-1:0]         ctx_id;            // PE context ID
        logic [TAG_W-1:0]            tag;               // PE scoreboard tag
        producer_domain_e            producer;          // which domain produced this
        logic [7:0]                  status_flags;      // aux: outlier/special/debug
    } bs_capsule_t;

    // [HW-REVIEW T3] inline_scale bit that selects absolute-scale alignment: when set,
    // vec_scale_adapter aligns by the signed scale_ref exponent (full range), not the
    // clamped E4M3 4-bit byte exponent. 0 = legacy byte decode (back-compatible).
    localparam int BS_ABS_EXP_BIT = 8;

    // ── Vector Execution Descriptor ──
    //   Issued by PE (via contract_decode_expand or vec_cmd_to_desc adapter) to
    //   the Vector Unit; everything the Vector Unit needs to execute one primitive.
    //   ctx_id/tag use PE-native widths for direct credit/completion compatibility.
    typedef struct packed {
        logic [CTX_ID_W-1:0]   ctx_id;             // PE context ID
        logic [TAG_W-1:0]      tag;                 // PE scoreboard tag
        logic [2:0]            op_class;            // coarse datapath selector
        logic [5:0]            primitive_id;        // specific primitive
        elem_fmt_e             elem_fmt;            // element format (§6b canonical)
        block_size_sel_e       block_size;          // block grouping size
        scale_format_e         scale_format;        // shared factor format
        logic [3:0]            layout_tag;          // data layout identifier
        logic [15:0]           src0_ref;            // source 0 reference (L2 row or sidecar)
        logic [15:0]           src1_ref;            // source 1 reference (for dual-operand ops)
        logic [15:0]           dst_ref;             // destination reference
        logic [15:0]           scale_ref;           // scale location reference
        logic [7:0]            scale_epoch;         // metadata consistency token
        logic [3:0]            round_sat_policy;    // rounding / saturation mode
        logic [1:0]            escape_hint;         // escape policy bits
        destination_hint_e     dest_hint;           // preferred destination
        logic                  fwd_eligible;        // fast-path forward allowed
        logic                  multi_consumer;      // >1 consumer expected
        logic                  src1_resident;       // [STEP4-E2E §11.4] SRC1 from resident L2
        logic signed [15:0]    src1_scale_ref;      // [HW-REVIEW T3] resident SRC1 absolute block exp
        // [HW-REVIEW T3-FF/FF3b-c] multi-block streaming RESADD:
        logic [15:0]           block_count;         // N residual blocks (= len_rows; >=1, 1 = single-block today)
        logic [15:0]           sidecar_base;        // physical L2 row of exp[0] (cp_scheduler xlat'd; sliced to L2_BANK_AW)
    } vec_exec_desc_t;

    // ── [HW-REVIEW T3-FF/FF3a] Scale-sidecar wire format (multi-block streaming RESADD) ──
    //   A resident residual spanning N blocks (N = len_rows, the streaming length) carries
    //   ONE absolute block exponent per block. The N exponents live in an L2 "scale-sidecar"
    //   region whose base = the contract's scale_rid (region) + scale_row_off (row) — the
    //   architecture-visible scale-addressing fields, unused until now. Packing is DENSE:
    //   16 signed-16b exponents per 256b (HALF_STRIPE_W) row, so exp[k] lives at
    //     row  = sidecar_base + (k >> 4)        (k / 16)
    //     bits = [16*(k & 4'hF) +: 16]          (lane k mod 16, signed two's-complement)
    //   The streaming reader (FF3b/c) reads a sidecar row alongside the residual payload
    //   reads and drives exp[k] as the resident block's abs scale_ref (-> the E8M0/E4M3 abs
    //   path). SRC0 streams as N ordered fast-path capsules (decision (B), 2026-06-21); the
    //   residual stays resident. block_count = len_rows; block16 -> 1 frag/block, block32 ->
    //   2 windows/block (the existing per-block multi-pass machinery is reused per block).
    //   This primitive extracts exp[k] from a FETCHED 256b sidecar row given the in-row lane
    //   (k mod 16); the row-select (k >> 4) is the reader's address arithmetic.
    function automatic logic signed [15:0] sidecar_scale_k(
        input logic [HALF_STRIPE_W-1:0] sidecar_row,   // a fetched 256b sidecar row
        input logic [3:0]               lane           // k mod 16 (in-row block index)
    );
        return signed'(sidecar_row[16*lane +: 16]);
    endfunction

    // ── Vector Performance Counter MMIO Parameters ──
    //   17 counters mapped to high-half MMIO 0x140-0x184.
    //   Routing: vector_unit → pe_top → command_processor → cp_csr → IBEX.
    localparam int VEC_PERF_CNT_NUM     = 17;
    localparam int VEC_PERF_MMIO_BASE   = 9'h140;  // first Vector counter MMIO addr
    localparam int VEC_PERF_MMIO_LAST   = 9'h184;  // last Vector counter MMIO addr

endpackage

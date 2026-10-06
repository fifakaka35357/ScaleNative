// =============================================================================
// cp_desc_fetch.sv — Descriptor Fetch Engine (PE v5, Phase 4)
//   (R2A: ring_mask DRY, R3B: early validation)
//
// Phase 4 changes:
//   [PHASE4-01] Add OP_RING_* poison-at-fetch. RESERVED opcodes
//               (OP_RING_RESERVE/CONSUME/WAIT_GE) that pass is_known_opcode()
//               but fail is_supported_opcode() are poisoned with
//               ERR_OPCODE_RESERVED. This replaces the previous silent-accept
//               behavior where these reserved opcodes would have triggered
//               CP deadlocks downstream.
//   [PHASE4-02] Document the existing P1.2 fix (buf clear on IDLE→FETCH)
//               as the guarantee that slot[6:7] = 0 when ext_len < 2.
//               This is the foundation for cp_scheduler's unconditional
//               tile_contract_t extraction from ext words [6:7].
//
// Scans all contexts for empty slots with non-empty rings,
// then fetches descriptors from L1D via Port 1 (64b parallel read).
//
// Fetch flow:
//   1. IDLE: RR scan → find ctx with desc_next==EMPTY && ring non-empty
//   2. FETCH_PAIR_0: read word[0:1] (64b) from L1D
//      → parse word[0].ext_len → validate (≤4 for v4) → compute total_pairs
//      → R3.2a: early validation (bad_opcode, ext_overflow, ext_underflow)
//      → [PHASE4-01] reserved-opcode check: is_supported_opcode(op) == 0
//                    → ERR_OPCODE_RESERVED
//              if fail → poison buf[0], force base-only fetch
//   3. FETCH_PAIR_1: read word[2:3] (64b)
//      → R3.2a: bad_param check (len_rows==0 on compute/DMA)
//      → if total_pairs==2: done → STORE
//      → else: FETCH_PAIR_N (extension words)
//   4. FETCH_PAIR_N: read remaining pairs until all words fetched
//   5. STORE: assert fill_valid → command_processor routes to slot
//      → increment ring_head (with power-of-2 wrap) → back to IDLE
//
// R3.2a Error Classes Detected Here (post-Phase 4):
//   ERR_UNKNOWN_OPCODE   (3): opcode not in desc_opcode_e — priority 1
//   ERR_OPCODE_RESERVED  (8): [PHASE4-01] opcode is known but reserved
//                             (OP_RING_*) — priority 2 (between unknown and
//                             ext-related errors)
//   ERR_EXT_OVERFLOW     (1): ext_len > V4_MAX_EXT — priority 3
//   ERR_EXT_UNDERFLOW    (2): ext_len < min_ext_for_opcode — priority 4
//   ERR_INVALID_PARAM    (7): len_rows==0 on non-NOP/BARRIER/RING —
//                             checked in pair_1
//
// Error Classes Detected Elsewhere:
//   ERR_REGION_OOB     (4): cp_scheduler (R3C) — post-xlat row out of bounds
//   ERR_WATCHDOG       (5): cp_scheduler (R4) — ctx progress timeout
//   ERR_ALIGNMENT      (6): deferred to v5 — ring_base enforced at CSR write,
//                           noc_addr depends on NoC beat width (not yet parameterized)
//
// Consume-and-quarantine strategy:
//   Poisoned descriptors are stored to the slot like normal descriptors.
//   ring_head advances (freeing the ring entry). The scheduler (R3C) detects
//   the poison bit and routes to CTX_ERROR instead of issuing to an engine.
//   Other contexts continue unaffected — per-ctx isolation preserved.
//
// [PHASE4-02] Slot buffer zero-fill invariant:
//   On IDLE→FETCH_PAIR_0 transition, the ENTIRE buf_d[0..DESC_SLOT_WORDS-1]
//   is cleared to zero (P1.2 fix). Subsequently, ST_FETCH_PAIR_N only writes
//   buf_d[wi] and buf_d[wi+1] for pair_idx = 2, 3 (i.e., words 4,5,6,7) if
//   total_pairs_q calls for those pairs. When ext_len < 2, total_pairs = 2,
//   so word[4..7] are never written and remain at their cleared-zero value.
//
//   GUARANTEE: for any descriptor whose stored slot is not poisoned,
//              slot[6:7] == 0 iff ext_len < 2.
//   CONSEQUENCE: cp_scheduler may call
//                  extract_tile_contract(slot[6], slot[7])
//                unconditionally. When ext_len < 2, this returns a
//                tile_contract_t with ELEM_BF16 / BS_16 / DEST_WB defaults
//                (which extract_tile_contract produces from all-zero input;
//                 elem_fmt/block_size/dest_hint all decode 0). This is NOT
//                equivalent to default_tile_contract() whose elem_fmt is
//                ELEM_NONE — however, for opcodes that don't
//                require a contract (min_ext < 2), the contract field is
//                semantically unused downstream.
//
// L1D address calculation:
//   byte_addr = ring_base[ctx] + (ring_head[ctx] * SLOT_STRIDE) + (pair_idx * 8)
//   word_addr = byte_addr[11:3]  (9-bit, same for both banks)
//
//   SLOT_STRIDE = DESC_SLOT_WORDS * 4 = 32 bytes per ring entry
//
// v4 Round 2 fixes:
//   P4:  First-beat address used stale tgt_ctx_q → added eff_ctx MUX
//   P1.2: Buffer not cleared on new fetch → explicit clear on IDLE→FETCH
//   P1.3: ext_len > 4 silently clamped → now validated, excess flagged
//   P10: ring_size_log2 CSR was unused → head wraps at actual ring size
//   P13: soft_reset not propagated → added soft_reset_i port
//
// Throughput:
//   Base descriptor (4 words = 2 pairs): 2 read + 1 store = 3 cycles
//   4 contexts worst-case round-trip: 4 × 3 = 12 cycles
//   Tensor GEMM ~256 cycles → ample margin
// =============================================================================

module cp_desc_fetch
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Control ──
    input  logic        enable_i,           // from cp_csr CP_CTRL.enable
    input  logic        soft_reset_i,       // P13: from command_processor

    // ── L1D Port 1 (64b parallel read) ──
    output logic [L1D_BANK_AW-1:0] l1d_addr_o,     // word address
    output logic                    l1d_req_o,
    input  logic [63:0]             l1d_rdata_i,     // {bank1, bank0}
    input  logic                    l1d_rvalid_i,

    // ── Ring Configuration (from cp_csr) ──
    input  logic [11:0]              ring_base_i     [NUM_CTX],
    input  logic [RING_PTR_W-1:0]    ring_tail_i     [NUM_CTX],
    input  logic [3:0]               ring_size_log2_i [NUM_CTX],  // P10: log2(entries)

    // ── Ring Head Pointers (maintained here, read by cp_csr) ──
    output logic [RING_PTR_W-1:0]    ring_head_o     [NUM_CTX],

    // ── Per-Ctx Slot Status (from command_processor slot registers) ──
    input  slot_state_e              next_state_i    [NUM_CTX],

    // ── Fill Output (to command_processor slot registers) ──
    output logic [NUM_CTX-1:0]       fill_valid_o,
    output logic [1:0]               fill_ctx_o,
    output logic [31:0]              fill_data_o     [DESC_SLOT_WORDS]
);

    // =========================================================================
    // Constants
    // =========================================================================
    // Ring slot stride in bytes (each slot holds up to DESC_SLOT_WORDS words)
    localparam int SLOT_STRIDE_BYTES = DESC_SLOT_WORDS * 4;  // 32 bytes
    // Max pairs per descriptor
    localparam int MAX_PAIRS = (DESC_SLOT_WORDS + 1) / 2;    // 4
    // v4: max valid extension words (slot = 8 words, base = 4 words)
    localparam int V4_MAX_EXT = DESC_SLOT_WORDS - DESC_BASE_WORDS;  // 4

    // =========================================================================
    // FSM States
    // =========================================================================
    typedef enum logic [2:0] {
        ST_IDLE         = 3'd0,
        ST_FETCH_PAIR_0 = 3'd1,   // reading word[0:1], waiting rvalid
        ST_FETCH_PAIR_1 = 3'd2,   // reading word[2:3], waiting rvalid
        ST_FETCH_PAIR_N = 3'd3,   // reading extension pairs
        ST_STORE        = 3'd4    // writing to slot, incrementing head
    } fetch_state_e;

    fetch_state_e state_q, state_d;

    // =========================================================================
    // Working Registers
    // =========================================================================
    logic [1:0]               tgt_ctx_q, tgt_ctx_d;       // target context
    // [STEP4-E2E] Scoped UNOPTFLAT waiver: pair_idx_d is the FSM next-state pair
    // counter (registered into pair_idx_q below). The fetch-address always_comb
    // reads pair_idx_d (fetch_byte_addr = ... + pair_idx_d*8) BEFORE the FSM
    // always_comb assigns it; Verilator flags this cross-block read-before-write
    // as circular, but it is a FALSE loop — pair_idx_d depends only on pair_idx_q
    // (registered) + state, never transitively on the address it feeds, so it
    // settles in one pass. Scoped here (matches the vec_lane_array / tensor_mac_array
    // SV waivers) so command_processor can be exercised in cocotb sim + the
    // elaborate gate without a project-wide UNOPTFLAT suppression.
    /* verilator lint_off UNOPTFLAT */
    logic [2:0]               pair_idx_q, pair_idx_d;      // current pair index
    /* verilator lint_on UNOPTFLAT */
    logic [2:0]               total_pairs_q, total_pairs_d; // total pairs to fetch
    logic [31:0]              buf_q [DESC_SLOT_WORDS];      // word accumulator
    logic [31:0]              buf_d [DESC_SLOT_WORDS];
    logic                     ext_err_q, ext_err_d;         // P1.3: ext_len overflow

    // Ring head pointers (per-ctx)
    logic [RING_PTR_W-1:0]    head_q [NUM_CTX];

    // =========================================================================
    // P10 / R2.3: Per-ctx ring head wrap masks
    //
    // R2.3: Uses pe_pkg::ring_mask_from_log2 (DRY — single source of truth).
    //   The helper internally clamps ring_size_log2 to [RING_CFG_MIN..RING_CFG_MAX],
    //   protecting against edge cases (cfg=0 or cfg > RING_PTR_W).
    //   Note: cp_csr already clamps on write (R2.3), so ring_size_log2_i should
    //   always be in-range here. The helper's internal clamp is a safety net.
    // =========================================================================
    logic [RING_PTR_W-1:0] ring_mask [NUM_CTX];

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++)
            ring_mask[i] = ring_mask_from_log2(ring_size_log2_i[i]);
    end

    // =========================================================================
    // Context Selection: RR scan for eligible ctx
    //
    // Eligible: desc_next == EMPTY && ring not empty (tail != head)
    // The command_processor's comb logic decides whether to route the fill
    // to current (if empty) or next — fetch engine just needs to know that
    // at least one slot can accept data.
    // =========================================================================
    logic [1:0] rr_ptr_q;              // round-robin pointer
    logic [NUM_CTX-1:0] ctx_eligible;
    logic       any_eligible;
    logic [1:0] selected_ctx;
    logic       found;

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            ctx_eligible[i] = (next_state_i[i] == SLOT_EMPTY) &&
                              (ring_tail_i[i] != head_q[i]);
        end
        any_eligible = |ctx_eligible;
    end

    // RR selection: start from rr_ptr_q, wrap around
    always_comb begin
        found = 1'b0;
        selected_ctx = rr_ptr_q;
        for (int k = 0; k < NUM_CTX; k++) begin
            automatic logic [1:0] idx = rr_ptr_q + k[1:0];
            if (!found && ctx_eligible[idx]) begin
                selected_ctx = idx;
                found = 1'b1;
            end
        end
    end

    // =========================================================================
    // P4 fix: Effective context for address calculation
    //
    // Problem: In ST_IDLE, tgt_ctx_q holds the PREVIOUS fetch's context.
    //          The first L1D read issued in ST_IDLE must use the NEWLY
    //          selected ctx, but tgt_ctx_q hasn't updated yet (still _d).
    //
    // Fix: MUX selects selected_ctx when in IDLE (about to start new fetch),
    //      otherwise uses the registered tgt_ctx_q.
    //      Cost: 2-bit MUX on ctx index, negligible.
    // =========================================================================
    logic [1:0] eff_ctx;
    assign eff_ctx = (state_q == ST_IDLE) ? selected_ctx : tgt_ctx_q;

    // =========================================================================
    // L1D Address Calculation
    //
    // byte_addr = ring_base[ctx] + (head * SLOT_STRIDE_BYTES) + (pair_idx * 8)
    // word_addr = byte_addr[11:3]
    //
    // Uses eff_ctx (P4 fix) for correct first-beat address.
    // =========================================================================
    logic [11:0] fetch_byte_addr;
    logic [L1D_BANK_AW-1:0] fetch_word_addr;

    always_comb begin
        fetch_byte_addr = ring_base_i[eff_ctx]
                        + ({8'b0, head_q[eff_ctx]} * SLOT_STRIDE_BYTES[11:0])
                        + ({9'b0, pair_idx_d} * 12'd8);
        fetch_word_addr = fetch_byte_addr[L1D_BANK_AW+2:3]; // [11:3]
    end

    // =========================================================================
    // FSM: Next State + Datapath
    // =========================================================================
    always_comb begin
        state_d       = state_q;
        tgt_ctx_d     = tgt_ctx_q;
        pair_idx_d    = pair_idx_q;
        total_pairs_d = total_pairs_q;
        ext_err_d     = ext_err_q;

        // Default hold for buffer
        for (int w = 0; w < DESC_SLOT_WORDS; w++)
            buf_d[w] = buf_q[w];

        l1d_req_o  = 1'b0;
        l1d_addr_o = '0;

        fill_valid_o = '0;
        fill_ctx_o   = tgt_ctx_q;
        for (int w = 0; w < DESC_SLOT_WORDS; w++)
            fill_data_o[w] = buf_q[w];

        case (state_q)
            // -----------------------------------------------------------------
            ST_IDLE: begin
                if (enable_i && any_eligible) begin
                    tgt_ctx_d  = selected_ctx;
                    pair_idx_d = 3'd0;
                    ext_err_d  = 1'b0;

                    // P1.2 fix: Clear buffer on new fetch start.
                    // Prevents stale data from previous descriptor leaking
                    // into extension word positions of short descriptors.
                    for (int w = 0; w < DESC_SLOT_WORDS; w++)
                        buf_d[w] = 32'h0;

                    state_d = ST_FETCH_PAIR_0;

                    // Issue first read immediately (uses eff_ctx = selected_ctx)
                    l1d_req_o  = 1'b1;
                    l1d_addr_o = fetch_word_addr;
                end
            end

            // -----------------------------------------------------------------
            ST_FETCH_PAIR_0: begin
                // Waiting for rvalid from pair 0 (word[0:1])
                if (l1d_rvalid_i) begin
                    // [PHASE4-hygiene] All declarations at top of block
                    // (was a pre-existing v4 declaration-after-statement
                    //  error caught by pyslang, fixed as part of Phase 4
                    //  since this block was being touched anyway).
                    //
                    // Parse ext_len and opcode from word[0]
                    // [PHASE7-01] Explicit cast from logic[7:0] to desc_opcode_e
                    // matches the helpers' enum-typed input (needed for strict
                    // pyslang; the runtime value is still the same 8-bit slice).
                    // Unknown bit patterns land in the enum's "default" case
                    // branch in all three helpers — safe.
                    automatic logic [3:0]   ext_len  = l1d_rdata_i[11:8];
                    automatic desc_opcode_e opcode   = desc_opcode_e'(l1d_rdata_i[7:0]);
                    automatic logic [3:0]   total_words;

                    // ── R3.2a: Early validation (consume-and-quarantine) ──
                    //
                    // Checks on pair_0 data (opcode + ext_len available),
                    // priority order (first-match wins):
                    //   1. bad_opcode:       not in known opcode set
                    //   2. [PHASE4-01] reserved: opcode known but reserved
                    //                   (OP_RING_*) — not yet supported by HW
                    //   3. ext_overflow:     ext_len > V4_MAX_EXT
                    //   4. ext_underflow:    ext_len < min_ext_for_opcode
                    //
                    // If any fail: poison buf[0] with err_class, force
                    // total_pairs=2 (fetch base words only, skip extensions).
                    // Head still advances → consume-and-quarantine.
                    //
                    // Deferred checks:
                    //   bad_param (len_rows==0): needs word[3] → checked in pair_1
                    //   alignment: v5 (ring_base enforced at CSR write; noc_addr
                    //              checked at issue time once NoC beat width parameterized)
                    //   region_oob: detected in cp_scheduler after address translation
                    automatic logic ext_overflow  = (ext_len > V4_MAX_EXT[3:0]);
                    automatic logic ext_underflow = (ext_len < min_ext_for_opcode(opcode));
                    automatic logic bad_opcode    = !is_known_opcode(opcode);
                    automatic logic reserved_op   = is_known_opcode(opcode) &&
                                                    !is_supported_opcode(opcode);

                    // Now that declarations are complete, write the pair-0 data
                    buf_d[0] = l1d_rdata_i[31:0];   // word[0] = bank0
                    buf_d[1] = l1d_rdata_i[63:32];   // word[1] = bank1

                    if (bad_opcode) begin
                        // Unknown opcode — highest priority error class
                        buf_d[0] = make_poisoned(l1d_rdata_i[31:0], ERR_UNKNOWN_OPCODE);
                        total_words = DESC_BASE_WORDS[3:0];  // fetch base only
                        ext_err_d = 1'b1;
                    end else if (reserved_op) begin
                        // [PHASE4-01] Reserved opcode (OP_RING_*) — known to the
                        // ISA but not implemented in this PE integration.
                        // Poison now so the scheduler never attempts to dispatch,
                        // avoiding watchdog-death-by-deadlock.
                        buf_d[0] = make_poisoned(l1d_rdata_i[31:0], ERR_OPCODE_RESERVED);
                        total_words = DESC_BASE_WORDS[3:0];
                        ext_err_d = 1'b1;
                    end else if (ext_overflow) begin
                        buf_d[0] = make_poisoned(l1d_rdata_i[31:0], ERR_EXT_OVERFLOW);
                        total_words = DESC_BASE_WORDS[3:0];
                        ext_err_d = 1'b1;
                    end else if (ext_underflow) begin
                        buf_d[0] = make_poisoned(l1d_rdata_i[31:0], ERR_EXT_UNDERFLOW);
                        total_words = DESC_BASE_WORDS[3:0];
                        ext_err_d = 1'b1;
                    end else begin
                        total_words = 4'd4 + ext_len;
                    end

                    total_pairs_d = (total_words + 4'd1) >> 1; // ceil(total_words/2)

                    // Issue read for pair 1 (word[2:3])
                    pair_idx_d = 3'd1;
                    l1d_req_o  = 1'b1;
                    l1d_addr_o = fetch_word_addr;

                    state_d = ST_FETCH_PAIR_1;
                end
            end

            // -----------------------------------------------------------------
            ST_FETCH_PAIR_1: begin
                if (l1d_rvalid_i) begin
                    buf_d[2] = l1d_rdata_i[31:0];
                    buf_d[3] = l1d_rdata_i[63:32];

                    // ── R3.2a: bad_param check (needs word[3] = len_rows) ──
                    //
                    // len_rows == 0 on compute/DMA ops → undefined behavior
                    // (zero-length operation, AGU may wrap or stall).
                    // Only flag if not already poisoned from pair_0 checks.
                    // Excluded opcodes: NOP, BARRIER, and ring ops (don't use len_rows).
                    if (!ext_err_q) begin
                        // [PHASE7-01] opcode as desc_opcode_e for clean
                        // enum-to-enum comparison below (eliminates
                        // -Wcase-type style mismatches in this comparison).
                        automatic desc_opcode_e opcode   = desc_opcode_e'(buf_q[0][7:0]);
                        automatic logic [15:0]  len_rows = l1d_rdata_i[47:32]; // word[3][15:0]
                        automatic logic needs_len = !(opcode == OP_NOP       ||
                                                      opcode == OP_BARRIER    ||
                                                      opcode == OP_RING_RESERVE ||
                                                      opcode == OP_RING_CONSUME ||
                                                      opcode == OP_RING_WAIT_GE);
                        if (len_rows == '0 && needs_len) begin
                            buf_d[0] = make_poisoned(buf_q[0], ERR_INVALID_PARAM);
                        end
                    end

                    if (total_pairs_q <= 3'd2) begin
                        // Base descriptor complete (4 words) — or poisoned (forced to 2 pairs)
                        state_d = ST_STORE;
                    end else begin
                        // Need extension words
                        pair_idx_d = 3'd2;
                        l1d_req_o  = 1'b1;
                        l1d_addr_o = fetch_word_addr;
                        state_d    = ST_FETCH_PAIR_N;
                    end
                end
            end

            // -----------------------------------------------------------------
            ST_FETCH_PAIR_N: begin
                if (l1d_rvalid_i) begin
                    // Store extension pair into buffer
                    automatic int wi = {pair_idx_q, 1'b0}; // pair_idx * 2
                    if (wi < DESC_SLOT_WORDS)
                        buf_d[wi]   = l1d_rdata_i[31:0];
                    if (wi + 1 < DESC_SLOT_WORDS)
                        buf_d[wi+1] = l1d_rdata_i[63:32];

                    // ---------------------------------------------------------
                    // [C-1 2026-07-31] elem_fmt whitelist for TENSOR ops.
                    //
                    // This is the poison-on-issue gate that tensor_cmd_mmio_seq.sv:87-88
                    // has been delegating to since 2026-07-12 but which never existed
                    // (MISS_UNSUPPORTED_FMT had zero consumers repo-wide) — a
                    // cross-module fail-open: the leaf stays total and assumes the CP
                    // rejects, the CP never checked. An illegal elem_fmt therefore
                    // produced a SILENTLY WRONG capsule. See PROJECT_RULES §5.0d type 15
                    // and Review/UNWIRED_CAPABILITY_SWEEP_2026-07-31.md (C-1).
                    //
                    // Word 6 carries tile_contract_t.elem_fmt in [3:0]
                    // (pe_pkg extract_tile_contract: c.elem_fmt = w6[3:0]), and word 6
                    // is exactly this pair when pair_idx_q == 3 (wi == 6). We test the
                    // ARRIVING data (l1d_rdata_i), not buf_q[6], which is not yet
                    // registered at this point.
                    //
                    // Descriptors with ext_len < 4 never reach pair 3; words 6:7 are
                    // zero-cleared (P1.2) so elem_fmt decodes to 4'd0 = ELEM_BF16,
                    // which is whitelisted ⇒ every existing bench is bit-for-bit
                    // unaffected (no false poison).
                    //
                    // !ext_err_q mirrors the len_rows check below/above: do not stack a
                    // second poison onto a descriptor already failing ext_len validation.
                    // ---------------------------------------------------------
                    // [3a-7/P2 2026-08-05] word[5] guard for TENSOR ops —
                    // **单臂两检**（规格 §5.3.1 四要件表；Spec_Absorption_Diff #27+#28）
                    //
                    // 检 1: n_cfg == 2'b11 (NCFG_RESERVED) —— 不在批准集 {4,2,1} 内。
                    //       不拒 ⇒ tensor_pkg::ncfg_survivors() 返 N=3，压实行数与相位全错，
                    //       **硅上静默**（规格 §5.2 的残留静默点一段已登记该后果）。
                    // 检 2: word[5][31:18] reserved-must-be-zero（规格 §5.1 明文要求；
                    //       理由 = 独立偏移字段是绕过 region/OOB 检查的裸地址通路）。
                    //
                    // 🔴 两检**合并成一条臂**（#28 逐字要求）：同 opcode 门、同不叠毒谓词、
                    //    同 err_class ⇒ 两半臂的覆盖顺序不会成为可观测差异。
                    //
                    // 🔴 观测量必须取【到达数据】的**高**半字：
                    //    wi = {pair_idx_q, 1'b0} ⇒ wi==4 <=> pair_idx_q==2；
                    //    buf_d[wi] = rdata[31:0] = word[4]、buf_d[wi+1] = rdata[63:32] = word[5]
                    //    ⇒ word[5][17:16] = rdata[49:48]、word[5][31:18] = rdata[63:50]。
                    //    照抄下方 wi==6 的 `[3:0]` 形状会读成 word[4] 的 param_N 低两位；
                    //    取 buf_q[5] 则因 P1.2 零清恒读 2'b00 ⇒ **永久 fail-open**。
                    //
                    // 🔴 不叠毒谓词用 `!is_poisoned(buf_q[0])`，**不是** `!ext_err_q`：
                    //    ext_err_q 在本状态内**可证恒真**（置 ext_err_d 的四处都同时把
                    //    total_words 压回 DESC_BASE_WORDS ⇒ total_pairs=2 ⇒ 本状态不可达），
                    //    而真正的叠毒源 —— ST_FETCH_PAIR_1 的 len_rows==0 毒 ——
                    //    只写 buf_d[0] **不置 ext_err_d** ⇒ `!ext_err_q` 一点没盖住它。
                    //
                    // OP 门必须在（word[5] 对 DMA_MEMSET 是 memset_val，不门会误毒）：
                    //    在飞 3 条 MEMSET 的 word[5][31:18] **实算全非零**
                    //    （0xA5A51234/0xDEAD0001/0x600D600D）⇒ 漏门当场毒掉它们、闸2 立红。
                    if (wi == 4 && !is_poisoned(buf_q[0])) begin
                        automatic desc_opcode_e ext_opcode =
                            desc_opcode_e'(buf_q[0][7:0]);
                        automatic logic [1:0]   ext_ncfg =
                            l1d_rdata_i[49:48];              // word[5][17:16]
                        automatic logic [13:0]  ext_rsvd =
                            l1d_rdata_i[63:50];              // word[5][31:18]
                        if ((ext_opcode == OP_TENS_GEMM || ext_opcode == OP_TENS_CONV)
                            && ((ext_ncfg == 2'b11) || (ext_rsvd != 14'd0))) begin
                            buf_d[0] = make_poisoned(buf_q[0], ERR_INVALID_PARAM);
                        end
                    end

                    // 🔴 [3a-7/P2] 不叠毒谓词同上由 `!ext_err_q` 改 `!is_poisoned(buf_q[0])`
                    //    —— 这一改同时让 wi==6 臂**不再覆写 wi==4 臂刚写下的毒**。
                    if (wi == 6 && !is_poisoned(buf_q[0])) begin
                        automatic desc_opcode_e ext_opcode =
                            desc_opcode_e'(buf_q[0][7:0]);
                        automatic elem_fmt_e    ext_fmt    =
                            elem_fmt_e'(l1d_rdata_i[3:0]);
                        // [3a-7/P2] (elem_fmt x N) 交叉表：n_cfg 在 word[5]，本拍已寄存
                        // （word[5] 在 pair_idx_q==2 落盘，本分支是 pair_idx_q==3）。
                        // 🔴 写成【合取加项】叠在现役白名单之上，**不动 fmt_tensor_executable**
                        //    —— 白名单的红样本（ELEM_INT8 必毒）是 C-1 的现役资产。
                        automatic logic [1:0]   reg_ncfg = buf_q[5][17:16];
                        automatic logic         sparse_req = (reg_ncfg != 2'b00);
                        if ((ext_opcode == OP_TENS_GEMM || ext_opcode == OP_TENS_CONV)
                            && (!fmt_tensor_executable(ext_fmt)
                                || (sparse_req && !fmt_allows_sparse(ext_fmt)))) begin
                            buf_d[0] = make_poisoned(buf_q[0], ERR_INVALID_PARAM);
                        end
                    end

                    if (pair_idx_q + 3'd1 >= total_pairs_q) begin
                        // All pairs fetched
                        state_d = ST_STORE;
                    end else begin
                        pair_idx_d = pair_idx_q + 3'd1;
                        l1d_req_o  = 1'b1;
                        l1d_addr_o = fetch_word_addr;
                    end
                end
            end

            // -----------------------------------------------------------------
            ST_STORE: begin
                // Assert fill for target ctx
                fill_valid_o[tgt_ctx_q] = 1'b1;
                fill_ctx_o = tgt_ctx_q;
                for (int w = 0; w < DESC_SLOT_WORDS; w++)
                    fill_data_o[w] = buf_q[w];

                // ring_head increment happens in sequential block below

                state_d = ST_IDLE;
            end

            default: state_d = ST_IDLE;
        endcase
    end

    // =========================================================================
    // Sequential: State + Working Registers + Ring Head
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin   // P13: soft_reset clears all state
            state_q       <= ST_IDLE;
            tgt_ctx_q     <= '0;
            pair_idx_q    <= '0;
            total_pairs_q <= '0;
            ext_err_q     <= 1'b0;
            rr_ptr_q      <= '0;
            for (int w = 0; w < DESC_SLOT_WORDS; w++)
                buf_q[w] <= '0;
            for (int i = 0; i < NUM_CTX; i++)
                head_q[i] <= '0;
        end else if (soft_reset_i) begin   // [STEP5 slang] sync soft_reset_i split from async reset
            state_q       <= ST_IDLE;
            tgt_ctx_q     <= '0;
            pair_idx_q    <= '0;
            total_pairs_q <= '0;
            ext_err_q     <= 1'b0;
            rr_ptr_q      <= '0;
            for (int w = 0; w < DESC_SLOT_WORDS; w++)
                buf_q[w] <= '0;
            for (int i = 0; i < NUM_CTX; i++)
                head_q[i] <= '0;
        end else begin
            state_q       <= state_d;
            tgt_ctx_q     <= tgt_ctx_d;
            pair_idx_q    <= pair_idx_d;
            total_pairs_q <= total_pairs_d;
            ext_err_q     <= ext_err_d;

            for (int w = 0; w < DESC_SLOT_WORDS; w++)
                buf_q[w] <= buf_d[w];

            // Advance RR pointer after completing a fetch
            if (state_q == ST_STORE) begin
                rr_ptr_q <= tgt_ctx_q + 2'd1;

                // P10 fix: Increment ring head with power-of-2 wrap.
                // Uses ring_mask derived from ring_size_log2 to wrap correctly
                // for configured ring sizes smaller than the max (16).
                head_q[tgt_ctx_q] <= (head_q[tgt_ctx_q] + {{(RING_PTR_W-1){1'b0}}, 1'b1})
                                   & ring_mask[tgt_ctx_q];
            end
        end
    end

    // =========================================================================
    // Output: Ring Head Pointers
    // =========================================================================
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_head_out
            assign ring_head_o[i] = head_q[i];
        end
    endgenerate

    // =========================================================================
    // R3.2a: Synthesis-safe validation warning
    //
    // In simulation: fires when any descriptor fails early validation.
    // Displays err_class, opcode, ext_len, and ring head for debug.
    // In synthesis: poison flag in slot data is the sole mechanism —
    //   cp_scheduler reads is_poisoned() and routes to CTX_ERROR (R3C).
    // =========================================================================
`ifndef SYNTHESIS
    always_ff @(posedge clk_i) begin
        if (rst_ni && state_q == ST_STORE) begin
            if (is_poisoned(buf_q[0])) begin
                automatic err_class_e ec = get_poison_err_class(buf_q[0]);
                $warning("[cp_desc_fetch R3.2a] CTX%0d: descriptor POISONED @ head=%0d, err_class=%s(%0d), opcode=0x%02h, ext_len=%0d",
                         tgt_ctx_q, head_q[tgt_ctx_q],
                         ec.name(), ec, buf_q[0][7:0], buf_q[0][11:8]);
            end
        end
    end
`endif

endmodule

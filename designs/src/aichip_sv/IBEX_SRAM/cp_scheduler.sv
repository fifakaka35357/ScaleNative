// =============================================================================
// cp_scheduler.sv — Scheduler + Scoreboard + Issue (PE v5, Phase 4)
//   (R1+R2B+R3C+R4A+R5.1 + D3/R7.1: multi-credit tags + D6/R7.2: event WAIT)
//
// Phase 4 changes:
//   [PHASE4-03] Delete local shadow get_poison_err_class function —
//               the canonical version in pe_pkg (bits [30:27], 4-bit) is
//               used instead. The local shadow was decoding bits [30:28]
//               (3-bit) with wrong enum values, a latent bug that Phase 1's
//               header corrections now surface.
//   [PHASE4-04] Add tile_contract_t population to vec_cmd_o / tens_cmd_o /
//               dma_cmd_o. Contract is extracted unconditionally from
//               slot_current[sel_ctx][6:7] using pe_pkg's
//               extract_tile_contract() helper. When ext_len < 2, the
//               cp_desc_fetch P1.2 fix guarantees slot[6:7] == 0, so
//               extract returns a zero-tiled contract (harmless for
//               opcodes that don't consume the contract field).
//   [PHASE4-05] Expose event_wake as a formal output port (event_wake_o)
//               instead of letting command_processor reach it via
//               hierarchical reference. Pure discipline fix.
//
// D6/R7.2 changes (Event-based WAIT):
//   - OP_WAIT instruction: ctx waits for event mask match
//   - Per-ctx event_pending_q[EVT_W-1:0] — sticky event accumulator
//   - Per-ctx wait_mask_q[EVT_W-1:0] — stored from OP_WAIT word[4]
//   - Event sources: DONE_VEC, DONE_TENS, DONE_DMA, DOORBELL, IRQ
//   - Wake-up: (event_pending & wait_mask) != 0 → CTX_RUNNABLE
//   - Matched event bits auto-cleared on wake
//   - Same-cycle event delivery: event_set | event_pending checked together
//
// D3/R7.1: Multi-credit scoreboard with tags (TAG_W=3, max 8 inflight/unit)
// D4/R7.1c: Forward tag return from exec units (O(1) tag dealloc)
// R5.1: CP-side perf counters (blocked/barrier/starved/issue/done)
// R4A:  Credit net-delta, watchdog, dep_mask BARRIER
// R3:   Error handling (poison, OOB, CLEAR_ERROR)
// R1:   Ready-based scheduling, CTX_BLOCKED/DONE/ERROR, auto-promote
//
// State machine priority (low→high, last-write-wins):
//   9. doorbell       → IDLE→RUNNABLE
//   8. auto_promote   → IDLE→RUNNABLE (safety net)
//   7. blocked_update → RUNNABLE↔BLOCKED
//   6. done_detect    → ring_empty+slot_empty → DONE
//   5. comp_done      → WAIT_*→RUNNABLE
//   4.5 event_wake    → CTX_WAIT_EVENT→RUNNABLE (D6 new)
//   4. issue_ok       → →WAIT_* or →RUNNABLE(NOP/BARRIER/WAIT)
//   3. error          → →CTX_ERROR (poisoned desc / watchdog)
//   2. clear_error    → CTX_ERROR→CTX_IDLE
//   1. reset          → →CTX_IDLE (highest priority)
// =============================================================================

module cp_scheduler
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Control ──
    input  logic        enable_i,
    input  logic        soft_reset_i,

    // ── Per-Ctx Slot Data (from command_processor registers) ──
    input  logic [31:0]   slot_current_i   [NUM_CTX][DESC_SLOT_WORDS],
    input  slot_state_e   current_state_i  [NUM_CTX],

    // ── R1.2: Ring pointers + slot_next state (for CTX_DONE detection) ──
    input  logic [RING_PTR_W-1:0] ring_head_i      [NUM_CTX],
    input  logic [RING_PTR_W-1:0] ring_tail_i      [NUM_CTX],
    input  slot_state_e           slot_next_state_i [NUM_CTX],

    // ── NOP/BARRIER/WAIT Immediate Done (to completion router) ──
    output logic [NUM_CTX-1:0] nop_done_o,

    // ── R1.1b: Derived slot observability (to cp_csr via command_processor) ──
    output slot_state_e slot_state_vis_o [NUM_CTX],

    // ── Execution Unit Commands (valid/ready) ──
    output logic        vec_cmd_valid_o,
    output vec_cmd_t    vec_cmd_o,
    input  logic        vec_cmd_ready_i,

    output logic        tens_cmd_valid_o,
    output tens_cmd_t   tens_cmd_o,
    input  logic        tens_cmd_ready_i,

    output logic        dma_cmd_valid_o,
    output dma_cmd_t    dma_cmd_o,
    input  logic        dma_cmd_ready_i,

    // ── Region Table (from cp_csr) ──
    input  region_entry_t region_table_i [NUM_REGIONS],

    // ── Scoreboard Busy Flags (exposed to cp_csr for observability) ──
    output logic        vec_busy_o,
    output logic        tens_busy_o,
    output logic        dma_busy_o,

    // ── Done Signals (from cp_completion — per-ctx one-hot) ──
    input  logic [NUM_CTX-1:0] done_vec_i,
    input  logic [NUM_CTX-1:0] done_tens_i,
    input  logic [NUM_CTX-1:0] done_dma_i,

    // ── D4: Done Tag Return (from cp_completion — per-unit tag) ──
    input  logic [TAG_W-1:0] done_vec_tag_i,
    input  logic [TAG_W-1:0] done_tens_tag_i,
    input  logic [TAG_W-1:0] done_dma_tag_i,

    // ── Context States (to cp_csr) ──
    output ctx_state_e  ctx_state_o [NUM_CTX],

    // ── Doorbell (from cp_csr — wakes IDLE→RUNNABLE + D6 event) ──
    input  logic [NUM_CTX-1:0] doorbell_pulse_i,

    // ── R3.2c: CLEAR_ERROR (from cp_csr — per-ctx W1C) ──
    input  logic [NUM_CTX-1:0] clear_error_i,

    // ── R2.7: Issue Snapshot (to cp_csr) ──
    output logic                issue_snap_valid_o,
    output logic [CTX_ID_W-1:0] issue_snap_ctx_o,
    output logic [7:0]          issue_snap_opcode_o,
    output logic [3:0]          issue_snap_ext_len_o,

    // ── R3+R4: Error Pulse (to cp_csr) ──
    output logic                error_valid_o,
    output logic [CTX_ID_W-1:0] error_ctx_o,
    output err_class_e          error_class_o,

    // ── R4.1: Watchdog ──
    input  logic [WD_CNT_W-1:0] wd_threshold_i,
    output logic [NUM_CTX-1:0]  wd_timeout_o,

    // ── D3: Tag + Credit Observability (to cp_csr via command_processor) ──
    output logic [TAG_MAX-1:0]            vec_tag_valid_o,
    output logic [TAG_MAX-1:0]            tens_tag_valid_o,
    output logic [TAG_MAX-1:0]            dma_tag_valid_o,
    output logic [SCOREBOARD_CREDIT_W-1:0] vec_credit_o,
    output logic [SCOREBOARD_CREDIT_W-1:0] tens_credit_o,
    output logic [SCOREBOARD_CREDIT_W-1:0] dma_credit_o,

    // ── R5.1: Performance Counter Control ──
    input  logic perf_cnt_en_i,

    // ── R5.1: Performance Counter Outputs (to cp_csr) ──
    output logic [PERF_CNT_W-1:0] perf_ctx_blocked_o [NUM_CTX],
    output logic [PERF_CNT_W-1:0] perf_ctx_barrier_o [NUM_CTX],
    output logic [PERF_CNT_W-1:0] perf_ctx_starved_o [NUM_CTX],
    output logic [PERF_CNT_W-1:0] perf_total_issue_o,
    output logic [PERF_CNT_W-1:0] perf_total_done_o,

    // ── D6: Event System (IRQ pending from cp_csr, event status to cp_csr) ──
    input  logic [NUM_CTX-1:0]   irq_pending_i,          // per-ctx masked IRQ
    input  logic [NUM_CTX-1:0]   event_clear_i,          // D7: per-ctx clear pulse
    output logic [EVT_W-1:0]     event_pending_o [NUM_CTX], // sticky event bits

    // ── [PHASE4-05] Event Wake — formal port replacing hierarchical ref ──
    output logic [NUM_CTX-1:0]   event_wake_o            // high when ctx's
                                                          //   wait_mask matches
                                                          //   pending events;
                                                          //   used by trace ring
);

    // =========================================================================
    // Context State Registers
    // =========================================================================
    ctx_state_e ctx_state_q [NUM_CTX];

    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_ctx_out
            assign ctx_state_o[i] = ctx_state_q[i];
        end
    endgenerate

    // =========================================================================
    // [PHASE4-hygiene] Forward declarations
    //
    // v4 used sel_ctx (and a few related combinational signals) in
    // address-translation / OOB-check / poison-detection blocks that
    // appear textually BEFORE sel_ctx's RR-arbiter assignment. pyslang
    // rejects this as "identifier used before declaration" (6 sites in
    // v4). Verilator accepts it, but relying on tool-specific tolerance
    // is brittle.
    //
    // Fix: forward-declare sel_ctx and sel_valid here at module top. The
    // actual combinational assignment remains in the RR-arbiter block
    // further down; this is purely a declaration hoist, no logical change.
    // =========================================================================
    logic [CTX_ID_W-1:0] sel_ctx;
    logic                sel_valid;

    // =========================================================================
    // D3: Multi-Credit Scoreboard + Tag Infrastructure
    //
    // Per-unit: credit counter + tag bitmap + tag→ctx mapping.
    // Vec=4, Tens=2, DMA=2 credits (TAG_W=3, max 8 inflight).
    //
    // busy_o: any credit consumed (backward compat with legacy CSR).
    // avail:  credit > 0 → can accept new op (feeds can_issue).
    // idle:   credit == MAX → no inflight ops (feeds BARRIER check).
    // =========================================================================
    logic [SCOREBOARD_CREDIT_W-1:0] vec_credit_q, tens_credit_q, dma_credit_q;

    assign vec_busy_o  = (vec_credit_q  != SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_VEC));
    assign tens_busy_o = (tens_credit_q != SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_TENS));
    assign dma_busy_o  = (dma_credit_q  != SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_DMA));

    logic vec_idle, tens_idle, dma_idle;
    assign vec_idle  = (vec_credit_q  == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_VEC));
    assign tens_idle = (tens_credit_q == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_TENS));
    assign dma_idle  = (dma_credit_q  == SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_DMA));

    logic vec_avail, tens_avail, dma_avail;
    assign vec_avail  = (vec_credit_q  > '0);
    assign tens_avail = (tens_credit_q > '0);
    assign dma_avail  = (dma_credit_q  > '0);

    // Per-unit tag state: bitmap + tag→ctx mapping
    logic [TAG_MAX-1:0]   vec_tag_valid_q,  tens_tag_valid_q,  dma_tag_valid_q;
    logic [CTX_ID_W-1:0]  vec_tag_ctx_q  [TAG_MAX];
    logic [CTX_ID_W-1:0]  tens_tag_ctx_q [TAG_MAX];
    logic [CTX_ID_W-1:0]  dma_tag_ctx_q  [TAG_MAX];

    // Tag observability outputs
    assign vec_tag_valid_o  = vec_tag_valid_q;
    assign tens_tag_valid_o = tens_tag_valid_q;
    assign dma_tag_valid_o  = dma_tag_valid_q;
    assign vec_credit_o     = vec_credit_q;
    assign tens_credit_o    = tens_credit_q;
    assign dma_credit_o     = dma_credit_q;

    // =========================================================================
    // D3: Tag Allocation (find-first-zero in bitmap)
    //
    // Combinational priority encoder per unit. Scans tag_valid bitmap for
    // first free (0) bit. alloc_ok = found a free tag.
    // Only valid when issue_attempt targets that unit.
    // =========================================================================
    logic [TAG_W-1:0] vec_alloc_tag,  tens_alloc_tag,  dma_alloc_tag;
    logic             vec_alloc_ok,   tens_alloc_ok,   dma_alloc_ok;

    always_comb begin
        vec_alloc_tag = '0; vec_alloc_ok = 1'b0;
        for (int t = 0; t < TAG_MAX; t++) begin
            if (!vec_tag_valid_q[t] && !vec_alloc_ok) begin
                vec_alloc_tag = TAG_W'(t);
                vec_alloc_ok  = 1'b1;
            end
        end
    end

    always_comb begin
        tens_alloc_tag = '0; tens_alloc_ok = 1'b0;
        for (int t = 0; t < TAG_MAX; t++) begin
            if (!tens_tag_valid_q[t] && !tens_alloc_ok) begin
                tens_alloc_tag = TAG_W'(t);
                tens_alloc_ok  = 1'b1;
            end
        end
    end

    always_comb begin
        dma_alloc_tag = '0; dma_alloc_ok = 1'b0;
        for (int t = 0; t < TAG_MAX; t++) begin
            if (!dma_tag_valid_q[t] && !dma_alloc_ok) begin
                dma_alloc_tag = TAG_W'(t);
                dma_alloc_ok  = 1'b1;
            end
        end
    end

    // =========================================================================
    // D4: Forward Tag Deallocation Signals (combinational)
    //
    // When exec unit fires done, the tag is returned directly. We index
    // into tag_valid bitmap with O(1) direct lookup (no reverse scan).
    // =========================================================================
    logic vec_tag_do_free, tens_tag_do_free, dma_tag_do_free;
    assign vec_tag_do_free  = |done_vec_i;
    assign tens_tag_do_free = |done_tens_i;
    assign dma_tag_do_free  = |done_dma_i;

    // =========================================================================
    // Descriptor Decode (combinational, for all 4 ctxs)
    // =========================================================================
    desc_header_t hdr        [NUM_CTX];
    l2_addr_t     src_addr   [NUM_CTX];
    l2_addr_t     dst_addr   [NUM_CTX];
    logic [15:0]  len_rows   [NUM_CTX];
    logic [15:0]  stride_rows[NUM_CTX];

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            hdr[i]         = get_header(slot_current_i[i][0]);
            src_addr[i]    = get_l2_addr(slot_current_i[i][1]);
            dst_addr[i]    = get_l2_addr(slot_current_i[i][2]);
            len_rows[i]    = get_len_rows(slot_current_i[i][3]);
            stride_rows[i] = get_stride_rows(slot_current_i[i][3]);
        end
    end

    // =========================================================================
    // RID → Physical Row Translation
    // =========================================================================
    function automatic logic [L2_BANK_AW-1:0] xlat_row(
        input l2_addr_t addr,
        input region_entry_t rtab [NUM_REGIONS]
    );
        return rtab[addr.rid].base_row[L2_BANK_AW-1:0] + addr.row_off[L2_BANK_AW-1:0];
    endfunction

    // =========================================================================
    // R3.3: Region Bounds Check (post-xlat, per-selected-ctx)
    //
    // Detects when a descriptor's L2 row_off exceeds the region's num_rows.
    // Only checked for the SELECTED ctx (the one about to be issued).
    // OOB → error descriptor → immediate completion → CTX_ERROR.
    // =========================================================================
    logic src_oob, dst_oob, region_oob;

    always_comb begin
        logic check_src, check_dst;
        check_src = 1'b0;
        check_dst = 1'b0;

        case (hdr[sel_ctx].opcode)
            OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT,
            OP_TENS_GEMM, OP_TENS_CONV: begin
                check_src = 1'b1;
                check_dst = 1'b1;
            end
            OP_DMA_FILL, OP_DMA_MEMSET: begin
                check_dst = 1'b1;
            end
            OP_VEC_RESADD,
            OP_VEC_RESADD_RESIDENT: begin        // [STEP4-E2E] D5-2 + §11.4; [T3-FF/FF1] resident variant
                check_dst = 1'b1;                // result write-back row
                // SRC0 is fast-path (t2v) so src is normally unchecked; BUT a resident
                // SRC1 reads src_row from L2 -> bounds-check it too, so an OOB residual
                // row is poisoned to ERR_REGION_OOB like every other L2-source vec op
                // (not a silent wrong-row read). Residency = word6[28] for OP_VEC_RESADD,
                // or IMPLIED by the OP_VEC_RESADD_RESIDENT opcode ([T3-FF/FF1]).
                check_src = slot_current_i[sel_ctx][6][28] ||
                            (hdr[sel_ctx].opcode == OP_VEC_RESADD_RESIDENT);
            end
            OP_DMA_EVICT: begin
                check_src = 1'b1;
            end
            default: ;
        endcase

        src_oob = check_src &&
                  (src_addr[sel_ctx].row_off >=
                   region_table_i[src_addr[sel_ctx].rid].num_rows);
        dst_oob = check_dst &&
                  (dst_addr[sel_ctx].row_off >=
                   region_table_i[dst_addr[sel_ctx].rid].num_rows);
        region_oob = src_oob | dst_oob;
    end

    // =========================================================================
    // R3.2b: Poisoned Descriptor Detection
    //
    // word[0] bit[31] = poison flag. If set, descriptor is treated as error.
    // =========================================================================
    logic is_poisoned_sel;
    assign is_poisoned_sel = slot_current_i[sel_ctx][0][31];

    logic is_error_sel;
    assign is_error_sel = is_poisoned_sel || region_oob;

    // [PHASE4-03] Local shadow get_poison_err_class REMOVED.
    //
    // The v4 version of this file declared a module-local function that
    // decoded word0[30:28] (3-bit) into {ERR_UNKNOWN_OPCODE, ERR_BAD_PARAM}
    // — two bugs in one:
    //   (1) wrong bit slice  — pe_pkg canonical is [30:27] (4-bit)
    //   (2) referenced non-existent enum ERR_BAD_PARAM (pe_pkg has
    //       ERR_INVALID_PARAM, not ERR_BAD_PARAM)
    // Both are eliminated by deleting the shadow and resolving the call
    // at line ~579 to pe_pkg::get_poison_err_class (canonical).

    // =========================================================================
    // R1.1: Per-Ctx can_issue Pre-computation (Ready-Based Scheduling)
    //
    // D3: uses vec/tens/dma_avail (credit > 0) instead of !busy.
    // D6: OP_WAIT is always ready (no exec unit needed).
    // =========================================================================
    logic [NUM_CTX-1:0] can_issue;
    logic [NUM_CTX-1:0] res_avail;
    logic [NUM_CTX-1:0] res_ready;   // HW-REVIEW T4: target exec unit ready THIS cycle

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            res_avail[i] = 1'b0;
            res_ready[i] = 1'b1;

            case (hdr[i].opcode)
                OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT:  // [STEP4-E2E] D5-2
                    res_avail[i] = vec_avail;
                OP_TENS_GEMM, OP_TENS_CONV:
                    res_avail[i] = tens_avail;
                OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET:
                    res_avail[i] = dma_avail;
                OP_BARRIER: begin
                    // R4.2: dep_mask BARRIER (ext_len≥1 → selective fence)
                    if (hdr[i].ext_len >= 4'd1) begin
                        logic [2:0] dep;
                        dep = slot_current_i[i][4][2:0];
                        res_avail[i] = (~dep[DEP_MASK_VEC]  | vec_idle) &
                                       (~dep[DEP_MASK_TENS] | tens_idle) &
                                       (~dep[DEP_MASK_DMA]  | dma_idle);
                    end else begin
                        res_avail[i] = vec_idle & tens_idle & dma_idle;
                    end
                end
                OP_NOP:
                    res_avail[i] = 1'b1;
                OP_WAIT:                             // D6: no exec unit needed
                    res_avail[i] = 1'b1;
                OP_RING_RESERVE, OP_RING_CONSUME, OP_RING_WAIT_GE:
                    res_avail[i] = 1'b1;
                default:
                    res_avail[i] = 1'b1;
            endcase

            // HW-REVIEW T4: per-ctx target-unit readiness. A ctx whose exec unit
            // is back-pressured (cmd_ready=0) cannot make forward progress this
            // cycle; the RR selector must skip it, else it freezes rr_ptr and
            // head-of-line-blocks a ready ctx on an otherwise-idle unit (units are
            // single-op-in-flight but credits are over-provisioned, so credit>0
            // with cmd_ready=0 is the normal busy condition). Non-exec ops and
            // poisoned (immediate-done) descriptors are always "ready".
            case (hdr[i].opcode)
                OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT:
                    res_ready[i] = vec_cmd_ready_i;
                OP_TENS_GEMM, OP_TENS_CONV:
                    res_ready[i] = tens_cmd_ready_i;
                OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET:
                    res_ready[i] = dma_cmd_ready_i;
                default:
                    res_ready[i] = 1'b1;
            endcase
            if (slot_current_i[i][0][31])   // poisoned → immediate done (no unit)
                res_ready[i] = 1'b1;

            can_issue[i] = (ctx_state_q[i] inside {CTX_RUNNABLE, CTX_BLOCKED}) &&
                           (current_state_i[i] == SLOT_VALID) &&
                           res_avail[i];
        end
    end

    // =========================================================================
    // R1.1b: Derived Slot State for Observability
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            if (current_state_i[i] == SLOT_EMPTY) begin
                slot_state_vis_o[i] = SLOT_EMPTY;
            end else if (can_issue[i]) begin
                slot_state_vis_o[i] = SLOT_READY;
            end else if (ctx_state_q[i] inside {CTX_RUNNABLE, CTX_BLOCKED}) begin
                slot_state_vis_o[i] = SLOT_BLOCKED;
            end else begin
                slot_state_vis_o[i] = SLOT_VALID;
            end
        end
    end

    // =========================================================================
    // RR Selection — from can_issue only
    //
    // Note: sel_ctx and sel_valid are forward-declared at module top
    // (see [PHASE4-hygiene] block) to satisfy strict declaration-before-use
    // ordering. This block assigns them combinationally.
    // =========================================================================
    logic [CTX_ID_W-1:0] rr_ptr_q;

    always_comb begin
        sel_valid = 1'b0;
        sel_ctx   = rr_ptr_q;
        for (int k = 0; k < NUM_CTX; k++) begin
            automatic logic [CTX_ID_W-1:0] idx = rr_ptr_q + CTX_ID_W'(k);
            // HW-REVIEW T4: also require res_ready (target unit can accept this
            // cycle) so a ctx stalled on a busy unit does not block a ready ctx
            // on an idle unit and freeze rr_ptr. (res_ready feeds only selection,
            // not can_issue/slot_state_vis, so observability is unchanged.)
            if (!sel_valid && can_issue[idx] && res_ready[idx]) begin
                sel_ctx   = idx;
                sel_valid = 1'b1;
            end
        end
    end

    // [PHASE4-04] sel_contract — declared here (after sel_ctx is declared)
    // and assigned combinationally from slot[6:7]. Used downstream by the
    // three cmd assembly blocks (vec/tens/dma).
    // When ext_len < 2 for the selected descriptor, the cp_desc_fetch
    // P1.2 fix guarantees slot[6:7] == 0 and extract_tile_contract returns
    // a zero-filled contract (safe — unused by opcodes that don't require
    // a contract).
    tile_contract_t sel_contract;
    assign sel_contract = extract_tile_contract(
                              slot_current_i[sel_ctx][6],
                              slot_current_i[sel_ctx][7]
                          );

    // =========================================================================
    // Issue Logic (combinational)
    // =========================================================================
    logic              issue_ok;
    logic              issue_attempt;
    logic              is_nop;
    logic              is_barrier;
    logic              is_wait;         // D6: OP_WAIT

    desc_opcode_e      sel_opcode;

    always_comb begin
        sel_opcode    = hdr[sel_ctx].opcode;
        is_nop        = (sel_opcode == OP_NOP);
        is_barrier    = (sel_opcode == OP_BARRIER);
        is_wait       = (sel_opcode == OP_WAIT);    // D6
        issue_attempt = sel_valid && enable_i;
    end

    // =========================================================================
    // Command Assembly (combinational)
    //
    // D3: attach allocated tag to command outputs.
    //
    // [PHASE4-04] Contract extraction: for all three cmd types, we
    // extract tile_contract_t from slot_current[sel_ctx][6:7]. The
    // cp_desc_fetch P1.2 fix guarantees that slot[6:7] == 0 whenever
    // ext_len < 2 (i.e., for opcodes that do not carry a contract), so
    // the extraction is safe to do unconditionally. sel_contract is
    // declared and assigned earlier (right after sel_ctx is computed).
    // =========================================================================
    logic [L2_BANK_AW-1:0] phys_src, phys_dst;
    // [T3-FF/FF3b-c] physical scale-sidecar base for a multi-block streaming RESADD.
    //   The contract exposes the scale region as RID+offset (scale_rid/scale_row_off,
    //   word6[19:16]/word7[15:0]); cp_scheduler is the only module holding the region
    //   table, so it translates the scale address the SAME way as src/dst. The frozen
    //   vec_cmd_to_desc adapter then just forwards the physical row.
    logic [L2_BANK_AW-1:0] phys_sidecar;
    l2_addr_t              sc_addr;

    always_comb begin
        phys_src = xlat_row(src_addr[sel_ctx], region_table_i);
        phys_dst = xlat_row(dst_addr[sel_ctx], region_table_i);
        sc_addr  = '{ reserved_hi:  4'b0,
                     rid:          sel_contract.scale_rid,
                     reserved_mid: 8'b0,
                     row_off:      sel_contract.scale_row_off };
        phys_sidecar = xlat_row(sc_addr, region_table_i);
    end

    // Vec command
    always_comb begin
        vec_cmd_valid_o = 1'b0;
        vec_cmd_o       = '0;

        if (issue_attempt && !is_error_sel &&
            (sel_opcode inside {OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT})) begin  // [STEP4-E2E] D5-2
            vec_cmd_valid_o       = 1'b1;
            // [T3-FF/FF1] NORMALIZE the resident-RESADD variant to OP_VEC_RESADD so the
            // frozen downstream adapter (vec_cmd_to_desc) maps it to VEC_RESADD as usual;
            // the residency/scale ride the contract. The variant opcode exists only in
            // the descriptor ISA / fetch layer (min_ext-enforced loud reject).
            vec_cmd_o.opcode      = (sel_opcode == OP_VEC_RESADD_RESIDENT)
                                    ? OP_VEC_RESADD : sel_opcode;
            vec_cmd_o.src_row     = phys_src;
            vec_cmd_o.dst_row     = phys_dst;
            vec_cmd_o.len_rows    = len_rows[sel_ctx];
            vec_cmd_o.stride_rows = stride_rows[sel_ctx];
            vec_cmd_o.ctx_id      = sel_ctx;
            vec_cmd_o.flags       = hdr[sel_ctx].flags;
            vec_cmd_o.tag         = vec_alloc_tag;       // D3: attach tag
            vec_cmd_o.contract    = sel_contract;        // [PHASE4-04]
            // [T3-FF/FF1] residency is IMPLIED by the opcode for OP_VEC_RESADD_RESIDENT
            // (the source of truth, so cp_desc_fetch can loud-reject under-length); plain
            // OP_VEC_RESADD keeps honoring word6[28] (sel_contract.src1_resident).
            if (sel_opcode == OP_VEC_RESADD_RESIDENT)
                vec_cmd_o.contract.src1_resident = 1'b1;
            // [T3-FF/FF3b-c] physical scale-sidecar base, only for a resident RESADD
            // (the RESIDENT variant forces residency; plain OP_VEC_RESADD honors word6[28]).
            // The frozen adapter additionally gates on residency, so this is belt-and-braces.
            if ((sel_opcode == OP_VEC_RESADD_RESIDENT) ||
                (sel_opcode == OP_VEC_RESADD && sel_contract.src1_resident))
                vec_cmd_o.sidecar_base = phys_sidecar;
        end
    end

    // Tens command
    always_comb begin
        tens_cmd_valid_o = 1'b0;
        tens_cmd_o       = '0;

        if (issue_attempt && !is_error_sel &&
            (sel_opcode inside {OP_TENS_GEMM, OP_TENS_CONV})) begin
            tens_cmd_valid_o       = 1'b1;
            tens_cmd_o.opcode      = sel_opcode;
            tens_cmd_o.src_row     = phys_src;
            tens_cmd_o.dst_row     = phys_dst;
            tens_cmd_o.len_rows    = len_rows[sel_ctx];
            tens_cmd_o.stride_rows = stride_rows[sel_ctx];
            tens_cmd_o.ctx_id      = sel_ctx;
            tens_cmd_o.flags       = hdr[sel_ctx].flags;
            tens_cmd_o.tag         = tens_alloc_tag;     // D3: attach tag
            tens_cmd_o.param_M     = slot_current_i[sel_ctx][4][15:0];
            tens_cmd_o.param_N     = slot_current_i[sel_ctx][4][31:16];
            tens_cmd_o.param_K     = slot_current_i[sel_ctx][5][15:0];
            // [3a-3 2026-08-04] n_cfg 纯透传切片（word[5][17:16]，见 pe_pkg 的 word[5] 注释块）。
            // 🔴 本行漏掉是【纯静默】的：上面的 `tens_cmd_o = '0;` 前置让该字段
            //    **有驱动且恒 0** ⇒ 不属 PROJECT_RULES §5.0f 四方向表任一方向，
            //    连 -Wall 都报不出，两闸全绿。唯一能抓它的是 tb 侧驱非 0 的用例
            //    （test_tensor_cmd_mmio_seq 的 n_cfg 臂只覆盖 mmio_seq，覆盖不到本行）。
            //    ⇒ **本行今日零机器覆盖**。~~登记指向 3a-5~~
            //    ▲[3a-4/M2 2026-08-06 改锚]：3a-4/3a-5 已融合为一个战役片，且本行在
            //    **pe_top 层**、不在该片的 tensor 作业面内（M0-M7 结构上够不到它）
            //    ⇒ **登记改指向 3c**（R1-R9 逐行落地那一片；届时 test_pe_top 的
            //    build_desc 加 `w[5] |= n_cfg << 16` 一发打通九层）。
            tens_cmd_o.n_cfg       = slot_current_i[sel_ctx][5][17:16];
            tens_cmd_o.contract    = sel_contract;       // [PHASE4-04]
        end
    end

    // DMA command
    always_comb begin
        dma_cmd_valid_o = 1'b0;
        dma_cmd_o       = '0;

        if (issue_attempt && !is_error_sel &&
            (sel_opcode inside {OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET})) begin
            dma_cmd_valid_o       = 1'b1;
            dma_cmd_o.opcode      = sel_opcode;

            if (sel_opcode == OP_DMA_FILL) begin
                dma_cmd_o.noc_addr = slot_current_i[sel_ctx][1];
                dma_cmd_o.l2_rid   = dst_addr[sel_ctx].rid;
                dma_cmd_o.l2_row   = phys_dst;
            end else if (sel_opcode == OP_DMA_MEMSET) begin
                dma_cmd_o.noc_addr = '0;      // R7.4: no NoC
                dma_cmd_o.l2_rid   = dst_addr[sel_ctx].rid;
                dma_cmd_o.l2_row   = phys_dst;
                dma_cmd_o.memset_val = slot_current_i[sel_ctx][5];
            end else begin
                dma_cmd_o.noc_addr = slot_current_i[sel_ctx][2];
                dma_cmd_o.l2_rid   = src_addr[sel_ctx].rid;
                dma_cmd_o.l2_row   = phys_src;
            end

            dma_cmd_o.len_rows    = len_rows[sel_ctx];
            dma_cmd_o.stride_rows = stride_rows[sel_ctx];
            dma_cmd_o.ctx_id      = sel_ctx;
            dma_cmd_o.flags       = hdr[sel_ctx].flags;
            dma_cmd_o.tag         = dma_alloc_tag;       // D3: attach tag
            // R7.4: 2D DMA params
            dma_cmd_o.outer_count = slot_current_i[sel_ctx][4][15:0];
            dma_cmd_o.contract    = sel_contract;        // [PHASE4-04]
        end
    end

    // Issue handshake: accepted when valid & ready
    //
    // R3.2b+R3.3: Error descriptors (poisoned or region OOB) are treated
    // like NOPs — immediate completion, no exec unit handshake.
    // D6: OP_WAIT also immediate (no exec unit needed).
    always_comb begin
        issue_ok = 1'b0;
        if (is_error_sel) begin
            issue_ok = issue_attempt;
        end else if (is_nop || is_barrier || is_wait) begin
            issue_ok = issue_attempt;
        end else begin
            case (sel_opcode)
                OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT:  // [STEP4-E2E] D5-2
                    issue_ok = vec_cmd_valid_o & vec_cmd_ready_i;
                OP_TENS_GEMM, OP_TENS_CONV:
                    issue_ok = tens_cmd_valid_o & tens_cmd_ready_i;
                OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET:
                    issue_ok = dma_cmd_valid_o & dma_cmd_ready_i;
                default:
                    issue_ok = issue_attempt;
            endcase
        end
    end

    // =========================================================================
    // NOP/BARRIER/WAIT/Error Immediate Done
    //
    // Routes through cp_completion for CHAIN_NEXT and IRQ_ON_DONE processing.
    // D6: OP_WAIT gets immediate done (descriptor consumed), then enters
    //     CTX_WAIT_EVENT. The wake-up happens asynchronously via events.
    // =========================================================================
    always_comb begin
        nop_done_o = '0;
        if (issue_ok && (is_nop || is_barrier || is_wait || is_error_sel))
            nop_done_o[sel_ctx] = 1'b1;
    end

    // =========================================================================
    // R2.7: Issue Snapshot (for CTX_DBG register)
    // =========================================================================
    assign issue_snap_valid_o   = issue_ok;
    assign issue_snap_ctx_o     = sel_ctx;
    assign issue_snap_opcode_o  = hdr[sel_ctx].opcode;
    assign issue_snap_ext_len_o = hdr[sel_ctx].ext_len;

    // =========================================================================
    // R3+R4: Error Pulse
    //
    // Sources: poisoned (R3.2b), region OOB (R3.3), watchdog timeout (R4.1).
    // =========================================================================
    logic [NUM_CTX-1:0] wd_timeout;
    logic               wd_error_valid;
    logic [CTX_ID_W-1:0] wd_error_ctx;

    logic desc_error_valid;
    assign desc_error_valid = issue_ok & is_error_sel;

    assign error_valid_o = desc_error_valid | wd_error_valid;
    assign error_ctx_o   = desc_error_valid ? sel_ctx     : wd_error_ctx;
    assign error_class_o = desc_error_valid
                         ? (is_poisoned_sel ? get_poison_err_class(slot_current_i[sel_ctx][0])
                                            : ERR_REGION_OOB)
                         : ERR_WATCHDOG;

    // =========================================================================
    // R4.1: Per-ctx Watchdog Progress Counter
    //
    // Saturating 16-bit counter per ctx. Resets on progress (issue/done).
    // D6: CTX_WAIT_EVENT is also an active state for watchdog purposes.
    // =========================================================================
    logic [WD_CNT_W-1:0] wd_cnt_q [NUM_CTX];
    logic [NUM_CTX-1:0]  wd_progress;

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            wd_progress[i] = (issue_ok && sel_ctx == CTX_ID_W'(i)) |
                             done_vec_i[i] | done_tens_i[i] | done_dma_i[i];
            wd_timeout[i] = (wd_cnt_q[i] == wd_threshold_i) &&
                            (wd_threshold_i != '0);
        end
    end

    assign wd_timeout_o = wd_timeout;

    always_comb begin
        wd_error_valid = 1'b0;
        wd_error_ctx   = '0;
        for (int i = 0; i < NUM_CTX; i++) begin
            if (wd_timeout[i] && ctx_state_q[i] != CTX_ERROR && !wd_error_valid) begin
                wd_error_valid = 1'b1;
                wd_error_ctx   = CTX_ID_W'(i);
            end
        end
    end

    // =========================================================================
    // D6/R7.2: Event System — Combinational Logic
    //
    // Per-ctx event_pending_q accumulates sticky event bits from 5 sources.
    // OP_WAIT stores mask; when (event_pending & wait_mask) != 0, ctx wakes.
    //
    // Same-cycle delivery: event_set is OR'd with event_pending BEFORE
    // checking the mask, so a done in the same cycle as CTX_WAIT_EVENT
    // entry can trigger immediate wake (1-cycle latency).
    //
    // On wake, matched bits (pending & mask) are auto-cleared.
    // =========================================================================
    logic [EVT_W-1:0] event_pending_q [NUM_CTX];
    logic [EVT_W-1:0] wait_mask_q     [NUM_CTX];

    // Event sources (combinational, per-ctx)
    logic [EVT_W-1:0] event_set [NUM_CTX];

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            event_set[i]               = '0;
            event_set[i][EVT_DONE_VEC]  = done_vec_i[i];
            event_set[i][EVT_DONE_TENS] = done_tens_i[i];
            event_set[i][EVT_DONE_DMA]  = done_dma_i[i];
            event_set[i][EVT_DOORBELL]  = doorbell_pulse_i[i];
            event_set[i][EVT_IRQ]       = irq_pending_i[i];
        end
    end

    // New event snapshot: existing pending OR new events this cycle
    logic [EVT_W-1:0] event_new [NUM_CTX];

    // Matched bits: only computed when ctx is in CTX_WAIT_EVENT
    logic [EVT_W-1:0] event_matched [NUM_CTX];
    logic [NUM_CTX-1:0] event_wake;      // per-ctx wake signal

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            event_new[i]     = event_pending_q[i] | event_set[i];
            event_matched[i] = (ctx_state_q[i] == CTX_WAIT_EVENT)
                             ? (event_new[i] & wait_mask_q[i])
                             : '0;
            event_wake[i]    = |event_matched[i];
        end
    end

    // [PHASE4-05] Expose event_wake as a formal port so command_processor
    // doesn't need a hierarchical reference to reach it.
    assign event_wake_o = event_wake;

    // Expose event_pending for CSR readout (shows accumulated state)
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_evt_out
            assign event_pending_o[i] = event_pending_q[i];
        end
    endgenerate

    // =========================================================================
    // Credit Delta Signals (combinational)
    //
    // Decrement: only when actually dispatching to an exec unit
    //   (issue_ok AND opcode targets unit AND NOT error/NOP/BARRIER/WAIT)
    // Increment: unconditional on done signal
    // =========================================================================
    logic vec_credit_dec, tens_credit_dec, dma_credit_dec;
    logic vec_credit_inc, tens_credit_inc, dma_credit_inc;

    always_comb begin
        vec_credit_dec  = issue_ok && !is_error_sel &&
                          (sel_opcode inside {OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT});  // [STEP4-E2E] D5-2
        tens_credit_dec = issue_ok && !is_error_sel &&
                          (sel_opcode inside {OP_TENS_GEMM, OP_TENS_CONV});
        dma_credit_dec  = issue_ok && !is_error_sel &&
                          (sel_opcode inside {OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET});

        vec_credit_inc  = |done_vec_i;
        tens_credit_inc = |done_tens_i;
        dma_credit_inc  = |done_dma_i;
    end

    // =========================================================================
    // Sequential: Context State Machine + Tags + Credits + Events + Watchdog
    //
    // Priority (low→high, last-write-wins):
    //   9. doorbell       → IDLE→RUNNABLE
    //   8. auto_promote   → IDLE→RUNNABLE
    //   7. blocked_update → RUNNABLE↔BLOCKED
    //   6. done_detect    → ring_empty+slot_empty → DONE
    //   5. comp_done      → WAIT_*→RUNNABLE
    //   4.5 event_wake    → CTX_WAIT_EVENT→RUNNABLE (D6)
    //   4. issue_ok       → →WAIT_* / RUNNABLE / CTX_WAIT_EVENT(D6)
    //   3. error          → →CTX_ERROR
    //   2. clear_error    → CTX_ERROR→CTX_IDLE
    //   1. reset          → CTX_IDLE (highest priority)
    // =========================================================================
    // [STEP5 slang] Reset body factored into a task so the async reset (!rst_ni)
    // and the synchronous soft_reset_i can each invoke the IDENTICAL reset
    // sequence from separate if-branches. slang rejects ORing a synchronous
    // signal into the async-reset condition ("condition cannot be matched to any
    // signal from the event list"); the split below is behavior-preserving.
    task automatic reset_sched_state;
        for (int i = 0; i < NUM_CTX; i++) begin
            ctx_state_q[i]     <= CTX_IDLE;
            wd_cnt_q[i]        <= '0;
            event_pending_q[i] <= '0;       // D6
            wait_mask_q[i]     <= '0;       // D6
        end
        vec_credit_q  <= SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_VEC);
        tens_credit_q <= SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_TENS);
        dma_credit_q  <= SCOREBOARD_CREDIT_W'(SCOREBOARD_CREDITS_DMA);
        vec_tag_valid_q  <= '0;
        tens_tag_valid_q <= '0;
        dma_tag_valid_q  <= '0;
        for (int t = 0; t < TAG_MAX; t++) begin
            vec_tag_ctx_q[t]  <= '0;
            tens_tag_ctx_q[t] <= '0;
            dma_tag_ctx_q[t]  <= '0;
        end
        rr_ptr_q <= '0;
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            // ── Priority 1: Reset (highest) ──
            reset_sched_state();
        end else if (soft_reset_i) begin
            // [STEP5 slang] sync soft_reset_i split from async reset
            reset_sched_state();
        end else begin

            // ── Watchdog counter update ──
            //
            // D6: CTX_WAIT_EVENT is an active state for watchdog.
            for (int i = 0; i < NUM_CTX; i++) begin
                if (ctx_state_q[i] inside {CTX_RUNNABLE, CTX_BLOCKED,
                                           CTX_WAIT_VEC, CTX_WAIT_TENS,
                                           CTX_WAIT_DMA, CTX_WAIT_EVENT}) begin
                    if (wd_progress[i])
                        wd_cnt_q[i] <= '0;
                    else if (!(&wd_cnt_q[i]))
                        wd_cnt_q[i] <= wd_cnt_q[i] + 1'b1;
                end else begin
                    wd_cnt_q[i] <= '0;
                end
            end

            // ── D6: Event pending accumulation ──
            //
            // Sticky OR of new events. On wake, matched bits cleared.
            // D7: event_clear_i[i] from CSR forces full clear (SW recovery).
            // Must execute BEFORE state transitions that depend on events.
            for (int i = 0; i < NUM_CTX; i++) begin
                if (event_clear_i[i])
                    event_pending_q[i] <= '0;
                else
                    event_pending_q[i] <= event_new[i] & ~event_matched[i];
            end

            // ── Priority 9 (lowest): Doorbell IDLE → RUNNABLE ──
            for (int i = 0; i < NUM_CTX; i++) begin
                if (doorbell_pulse_i[i] && ctx_state_q[i] == CTX_IDLE)
                    ctx_state_q[i] <= CTX_RUNNABLE;
                if (doorbell_pulse_i[i] && ctx_state_q[i] == CTX_DONE)
                    ctx_state_q[i] <= CTX_RUNNABLE;
            end

            // ── Priority 8: Auto-promote IDLE → RUNNABLE ──
            for (int i = 0; i < NUM_CTX; i++) begin
                if (ctx_state_q[i] == CTX_IDLE &&
                    (current_state_i[i] != SLOT_EMPTY ||
                     slot_next_state_i[i] != SLOT_EMPTY)) begin
                    ctx_state_q[i] <= CTX_RUNNABLE;
                end
            end

            // ── Priority 7: RUNNABLE ↔ BLOCKED update ──
            for (int i = 0; i < NUM_CTX; i++) begin
                if (ctx_state_q[i] == CTX_RUNNABLE &&
                    current_state_i[i] == SLOT_VALID &&
                    !can_issue[i]) begin
                    ctx_state_q[i] <= CTX_BLOCKED;
                end
                if (ctx_state_q[i] == CTX_BLOCKED && can_issue[i]) begin
                    ctx_state_q[i] <= CTX_RUNNABLE;
                end
            end

            // ── Priority 6: DONE detection ──
            for (int i = 0; i < NUM_CTX; i++) begin
                if ((ctx_state_q[i] inside {CTX_RUNNABLE, CTX_BLOCKED}) &&
                    current_state_i[i] == SLOT_EMPTY &&
                    slot_next_state_i[i] == SLOT_EMPTY &&
                    ring_tail_i[i] == ring_head_i[i]) begin
                    ctx_state_q[i] <= CTX_DONE;
                end
            end

            // ── Priority 5: Completion WAIT_* → RUNNABLE ──
            //
            // R4.1: state transition only for non-ERROR ctx.
            // Credit return is unconditional (separate section below).
            for (int i = 0; i < NUM_CTX; i++) begin
                if (done_vec_i[i] && ctx_state_q[i] == CTX_WAIT_VEC)
                    ctx_state_q[i] <= CTX_RUNNABLE;
                if (done_tens_i[i] && ctx_state_q[i] == CTX_WAIT_TENS)
                    ctx_state_q[i] <= CTX_RUNNABLE;
                if (done_dma_i[i] && ctx_state_q[i] == CTX_WAIT_DMA)
                    ctx_state_q[i] <= CTX_RUNNABLE;
            end

            // ── Priority 4.5: D6 Event Wake-up ──
            //
            // When CTX_WAIT_EVENT and (event_pending|event_set) & mask != 0,
            // wake to RUNNABLE. Matched bits already cleared above.
            // event_wake is combinational from event_matched.
            for (int i = 0; i < NUM_CTX; i++) begin
                if (event_wake[i] && ctx_state_q[i] == CTX_WAIT_EVENT)
                    ctx_state_q[i] <= CTX_RUNNABLE;
            end

            // ── Priority 4: Issue → WAIT_* / RUNNABLE / CTX_WAIT_EVENT ──
            //
            // Credit decrement handled in unified section below.
            // D3: tag allocation handled in tag section below.
            // D6: OP_WAIT → store mask, enter CTX_WAIT_EVENT.
            if (issue_ok) begin
                rr_ptr_q <= sel_ctx + CTX_ID_W'(1);

                case (sel_opcode)
                    OP_VEC_LOAD, OP_VEC_STORE, OP_VEC_ACT, OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT:  // [STEP4-E2E] D5-2
                        if (!is_error_sel)
                            ctx_state_q[sel_ctx] <= CTX_WAIT_VEC;
                    OP_TENS_GEMM, OP_TENS_CONV:
                        if (!is_error_sel)
                            ctx_state_q[sel_ctx] <= CTX_WAIT_TENS;
                    OP_DMA_FILL, OP_DMA_EVICT, OP_DMA_MEMSET:
                        if (!is_error_sel)
                            ctx_state_q[sel_ctx] <= CTX_WAIT_DMA;
                    OP_WAIT: begin                                  // D6
                        wait_mask_q[sel_ctx] <= slot_current_i[sel_ctx][4][EVT_W-1:0];
                        ctx_state_q[sel_ctx] <= CTX_WAIT_EVENT;
                    end
                    OP_NOP, OP_BARRIER:
                        ctx_state_q[sel_ctx] <= CTX_RUNNABLE;
                    default:
                        ctx_state_q[sel_ctx] <= CTX_RUNNABLE;
                endcase
            end

            // ── Priority 3: Error → CTX_ERROR ──
            //
            // Overrides issue's WAIT_*/RUNNABLE for error descriptors.
            // Watchdog can fire from any active state.
            if (issue_ok && is_error_sel) begin
                ctx_state_q[sel_ctx] <= CTX_ERROR;
            end
            for (int i = 0; i < NUM_CTX; i++) begin
                if (wd_timeout[i] && ctx_state_q[i] != CTX_ERROR)
                    ctx_state_q[i] <= CTX_ERROR;
            end

            // ── Priority 2: CLEAR_ERROR → CTX_ERROR → CTX_IDLE ──
            for (int i = 0; i < NUM_CTX; i++) begin
                if (clear_error_i[i] && ctx_state_q[i] == CTX_ERROR) begin
                    ctx_state_q[i]     <= CTX_IDLE;
                    event_pending_q[i] <= '0;    // D6: clear events on recovery
                    wait_mask_q[i]     <= '0;
                end
            end

            // ── D3/D4: Tag allocation (on issue) and deallocation (on done) ──
            //
            // Allocation: set tag_valid, write tag_ctx (on exec unit dispatch)
            // Deallocation: clear tag_valid via direct index from done_tag
            if (vec_credit_dec) begin
                vec_tag_valid_q[vec_alloc_tag]  <= 1'b1;
                vec_tag_ctx_q[vec_alloc_tag]    <= sel_ctx;
            end
            if (vec_tag_do_free)
                vec_tag_valid_q[done_vec_tag_i] <= 1'b0;

            if (tens_credit_dec) begin
                tens_tag_valid_q[tens_alloc_tag]  <= 1'b1;
                tens_tag_ctx_q[tens_alloc_tag]    <= sel_ctx;
            end
            if (tens_tag_do_free)
                tens_tag_valid_q[done_tens_tag_i] <= 1'b0;

            if (dma_credit_dec) begin
                dma_tag_valid_q[dma_alloc_tag]  <= 1'b1;
                dma_tag_ctx_q[dma_alloc_tag]    <= sel_ctx;
            end
            if (dma_tag_do_free)
                dma_tag_valid_q[done_dma_tag_i] <= 1'b0;

            // ── Scoreboard credit: unified net-delta update ──
            //
            // R4.1 CRITICAL: credit increment (done) is UNCONDITIONAL.
            // Even if ctx is CTX_ERROR, done still returns the credit.
            vec_credit_q  <= vec_credit_q
                           + SCOREBOARD_CREDIT_W'(vec_credit_inc)
                           - SCOREBOARD_CREDIT_W'(vec_credit_dec);
            tens_credit_q <= tens_credit_q
                           + SCOREBOARD_CREDIT_W'(tens_credit_inc)
                           - SCOREBOARD_CREDIT_W'(tens_credit_dec);
            dma_credit_q  <= dma_credit_q
                           + SCOREBOARD_CREDIT_W'(dma_credit_inc)
                           - SCOREBOARD_CREDIT_W'(dma_credit_dec);
        end
    end

    // =========================================================================
    // R5.1: Performance Counters (CP-side)
    //
    // 32-bit saturating counters. Clear on hard_reset and soft_reset.
    // Gated by perf_cnt_en_i (from PERF_CTRL CSR).
    //
    // 9 counter types:
    //   per-ctx (×4):  blocked_cycles, barrier_stalls, starved_cycles
    //   global (×2):   total_issue, total_done
    // =========================================================================
    logic [PERF_CNT_W-1:0] perf_ctx_blocked_q [NUM_CTX];
    logic [PERF_CNT_W-1:0] perf_ctx_barrier_q [NUM_CTX];
    logic [PERF_CNT_W-1:0] perf_ctx_starved_q [NUM_CTX];
    logic [PERF_CNT_W-1:0] perf_total_issue_q;
    logic [PERF_CNT_W-1:0] perf_total_done_q;

    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_perf_out
            assign perf_ctx_blocked_o[i] = perf_ctx_blocked_q[i];
            assign perf_ctx_barrier_o[i] = perf_ctx_barrier_q[i];
            assign perf_ctx_starved_o[i] = perf_ctx_starved_q[i];
        end
    endgenerate
    assign perf_total_issue_o = perf_total_issue_q;
    assign perf_total_done_o  = perf_total_done_q;

    // Saturating increment helper
    function automatic logic [PERF_CNT_W-1:0] sat_inc(
        input logic [PERF_CNT_W-1:0] val
    );
        return (&val) ? val : val + 1'b1;
    endfunction

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < NUM_CTX; i++) begin
                perf_ctx_blocked_q[i] <= '0;
                perf_ctx_barrier_q[i] <= '0;
                perf_ctx_starved_q[i] <= '0;
            end
            perf_total_issue_q <= '0;
            perf_total_done_q  <= '0;
        end else if (soft_reset_i) begin
            // [STEP5 slang] sync soft_reset_i split from async reset
            for (int i = 0; i < NUM_CTX; i++) begin
                perf_ctx_blocked_q[i] <= '0;
                perf_ctx_barrier_q[i] <= '0;
                perf_ctx_starved_q[i] <= '0;
            end
            perf_total_issue_q <= '0;
            perf_total_done_q  <= '0;
        end else if (perf_cnt_en_i) begin
            // Per-ctx: blocked, barrier, starved
            for (int i = 0; i < NUM_CTX; i++) begin
                // Blocked: ctx is BLOCKED (resource busy or dep unmet)
                if (ctx_state_q[i] == CTX_BLOCKED)
                    perf_ctx_blocked_q[i] <= sat_inc(perf_ctx_blocked_q[i]);

                // Barrier: ctx is BLOCKED and opcode is OP_BARRIER
                if (ctx_state_q[i] == CTX_BLOCKED &&
                    current_state_i[i] == SLOT_VALID &&
                    hdr[i].opcode == OP_BARRIER)
                    perf_ctx_barrier_q[i] <= sat_inc(perf_ctx_barrier_q[i]);

                // Starved: ctx is RUNNABLE but not selected (has work, not picked)
                if (ctx_state_q[i] == CTX_RUNNABLE &&
                    current_state_i[i] == SLOT_VALID &&
                    can_issue[i] &&
                    !(issue_ok && sel_ctx == CTX_ID_W'(i)))
                    perf_ctx_starved_q[i] <= sat_inc(perf_ctx_starved_q[i]);
            end

            // Global: total issue and total done
            if (issue_ok)
                perf_total_issue_q <= sat_inc(perf_total_issue_q);

            if (|done_vec_i || |done_tens_i || |done_dma_i ||
                (issue_ok && (is_nop || is_barrier || is_wait)))
                perf_total_done_q <= sat_inc(perf_total_done_q);
        end
    end

endmodule

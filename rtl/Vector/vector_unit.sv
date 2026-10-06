// =============================================================================
// vector_unit.sv — Vector Unit Top-Level (H-Tensor PE)
//
// [VEC-PIPE ⑥ 2026-07-18] VST_ACTIVE runs multiple phases per compute pass
//   (LANE capture -> REDUCE consume) — pipeline cut at the lane_array|reduce
//   boundary that removes the SoC-critical ctrl_q->cmx_lane single-cycle cone
//   prefix. See the state-enum comment block for the full story.
// [C5 2026-07-24] a THIRD leading phase (PH_MC) was added ahead of it: the
//   operand select + E4M3 mant_corr correction front now own their own clock
//   period and land in src0_lane_q/src1_lane_q, so the lane add chain no longer
//   sits in series with them (deployed binding 2805 ps -> see §C5).
//
// v6.0 Round 3b changes (data-path fixes — second and final touch to this file):
//   - Bug #3 fix: cross-pass REDUCE_STAT combine now uses a dedicated 40-bit
//     path. New internal function combine_reduce_stat_40b_to_reduce() takes
//     partial_stat_mant_q / partial_stat_exp_q (latched pass-0 raw window
//     sum) plus reduce_stat_raw_mant / _exp (current pass raw window sum)
//     and returns a vec_reduce_result_t. [S-STAT v1.2, prereg §70 + §74.1]
//     the body is now an exact 41-bit aligned add with a sticky bit, shaped
//     ONCE by vec_pkg::vec_stat_shape (RNE to 20 bits, O-IB Inf/NaN codes,
//     flush-to-zero) — the old single >>19 truncation, 10-bit exponent
//     difference and 10-bit +19 wrap are gone. This
//     activates the Round 3a "dead" partial_stat_*_q registers. Previous
//     behavior combined via partial_reduce_q (post-truncation 21-bit),
//     discarding the cross-pass precision that CL-5 was supposed to protect.
//   - Bug #4 fix: new partial_lane_results_q[VEC_LANES] register array
//     latches pass-0 lane results when (num_passes==2 && pass_idx==0 &&
//     !reduce_en && !renorm_en && lane_valid). The new combinational
//     selector effective_lane_results drives result_packer's lane_results_i
//     and, under block32 lane-only dual-egress, chooses the latched pass-0
//     data for window 0 and lane_results_q ([VEC-PIPE ⑥] registered) for window 1. Previously,
//     both windows carried pass-1 data — window 0's elements [0:15] were
//     lost entirely.
//   - Bug #6 fix: egress_window_q semantics clarified and advance timing
//     corrected. It is the CURRENT egress window selector (not a "completed
//     windows count"). It now advances only when the current window has
//     been successfully emitted:
//       - fp_egr_accepted in VST_ACTIVE  → advance immediately (same cycle)
//       - rw_gnt_i       in VST_L2_WB   → advance on completion
//     The pre-v6 code advanced on entry to L2_WB, causing window-0 data to
//     be written at address dst_ref+1 (window 1's slot) while window 1 was
//     never written at all. This bug was latent because Bug #2 made all L2
//     writes zero; Round 3a exposed it by fixing Bug #2.
//
// Round 3b intentionally does NOT touch:
//   - vec_reduce_cluster.sv (stat_raw outputs are sufficient; see decision #5)
//   - vec_pkg.sv (function is module-local; no new types needed)
//   - Any other SV file
//
// After Round 3b, vector_unit.sv is done for v6.0. Round 4 only adds
// assertions, optional cp_csr mapping, and the standalone testbench.
//
// v6.0 Round 3a changes (control-plane fixes only — data path untouched):
//   - Bug #1 fix: watchdog_timeout now compares against VEC_WATCHDOG_THRESHOLD
//     (Round 1 localparam = 1023, safely fits the 10-bit counter).
//     Pre-v6 code used VEC_MAX_OP_CYCLES[9:0] which evaluated to 10'd0 and
//     made the watchdog fire on every ACTIVE cycle immediately. Resolved.
//   - Bug #2 fix: new result_cap_q / result_cap_valid_q registers capture
//     the full bs_capsule_t at (last_pass && result_valid) in VST_ACTIVE.
//     VST_L2_WB now sources its payload from result_cap_q, eliminating the
//     all-zero writes that previously occurred because pipe_active drops
//     to 0 before result_packer is read. Latching the full capsule (not
//     just payload) anticipates Phase 2 L2 Scale Sidecar integration.
//     Latch condition is intentionally wide: last_pass && result_valid —
//     does NOT filter by result_escape_needed, because escape-spill writes
//     must carry real data too.
//   - Scale decode strict routing: new scale_any_error signal aggregates
//     vec_scale_adapter.error_o reports for src0/src1 (gated by their
//     loaded flags and need_src1). When asserted in VST_ACTIVE, FSM
//     pre-empts all other transitions and enters VST_ERROR with
//     error_q = VERR_SCALE_DECODE. Priority rationale (Round 3a decision):
//       1. scale_any_error  → ERROR  (correctness > progress)
//       2. watchdog_timeout → L2_WB  (progress guard)
//       3. !last_pass       → stay ACTIVE (multi-pass)
//       4. escape_needed    → L2_WB  (lossless spill)
//       5. fp_egr_accepted  → DONE or stay (window cycling)
//       6. otherwise        → L2_WB  (fallback)
//   - VERR_ROLE_MISORDER formalization: VST_WAIT_OP0 / VST_WAIT_OP1 role
//     stall timeout now sets error_q = VERR_ROLE_MISORDER instead of
//     overloading VERR_INTERNAL. Dedicated code defined in vec_pkg
//     (Round 1).
//
// Round 3a intentionally does NOT touch:
//   - active_src0_cap / active_src1_cap selection (Round 3b — Bug #4)
//   - combined_reduce / effective_renorm / effective_reduce (Round 3b)
//   - partial_stat_mant_q / partial_stat_exp_q read paths (Round 3b — Bug #3)
//   - element unpack, lane array, reduce cluster, renorm engine, packer
//   - module port signatures, perf counter logic, fp_egr_valid
//
// Historical changes (retained for traceability):
//   v2 from v1:
//     - Dual scale adapter: independent scale decode for src0 and src1 (B1.2)
//     - Operand role dispatch: FSM routes capsules by operand_role (B1.1)
//     - Multi-pass controller: block32 = 2 passes of 16 elements (B2)
//     - Escape → L2 write-back: escape is lossless spill, not data loss (B5)
//     - Scale passthrough to packer: non-renorm paths preserve scale (B3)
//     - scale_inline_valid checked before decode (B4)
//     - L2 address from dst_ref, not scale_ref (C2)
//     - done_o includes VST_ERROR for credit return (C1)
//     - Dead code removed: done_pulse, err_pulse (cleanup)
//     - 16-lane element unpack (VEC_LANES=16)
//     - Block32 double-capsule collection (src0_cap_b_q, src1_cap_b_q)
//     - Reduce partial accumulation across passes
//     - Renorm global max_exp combine across passes
//   v4 internal closures (CL-1..CL-10): sign-flip fix, exact contract match,
//     block32 dual capsule output (renorm path), HOL guard, 40-bit STAT
//     per-pass, precise scale_changed, reduce-result contract, ACTIVE
//     watchdog route, NaN escape relaxation, assertion pack.
//
// Architecture (unchanged from v4):
//   ┌───────────────────────────────────────────────────────────────────┐
//   │ vector_unit                                                       │
//   │                                                                   │
//   │  desc ──► [desc_decode] ──ctrl──► pipeline control                │
//   │                                                                   │
//   │  fpath ──► [fastpath_if] ──► [ingress_arb] ──► [op_queue]        │
//   │  L2 RO ──► (resident) ──►         │                               │
//   │                      ┌────────────┘                               │
//   │               [role dispatch + window select]                     │
//   │                      │                                            │
//   │  [scale_adapter_s0] ──► [lane_array] ──► [reduce_cluster]        │
//   │  [scale_adapter_s1] ──►       │                │                  │
//   │                        [renorm_quant] ◄────────┘                  │
//   │                               │                                   │
//   │   (partial accum) ◄──── [multi-pass controller]                   │
//   │                               │                                   │
//   │                        [result_packer] ──► [fastpath_if egress]   │
//   │                               │         ──► L2 RW (keep-local)    │
//   │                                 ▲                                 │
//   │                                 │ v6.0: result_cap_q latch        │
//   │                                                                   │
//   │  FSM: IDLE → WAIT_OP0 → WAIT_OP1 → ACTIVE → L2_WB → DONE       │
//   │       Extra exit:  ACTIVE ─scale_any_error─► ERROR (v6.0 R3a)    │
//   │  Counters: 17 × 32-bit saturating                                 │
//   │  Done/Error: done_o fires on DONE and ERROR (credit always returned)│
//   └───────────────────────────────────────────────────────────────────┘
//
// Author:  H-Tensor Project
// Version: 6.0 (Round 3b — data-path fixes: Bug #3 cross-pass 40-bit,
//          Bug #4 lane-only block32 pass-0 latch, Bug #6 egress_window timing)
// =============================================================================

module vector_unit
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        soft_reset_i,

    // Descriptor Interface
    input  logic            desc_valid_i,
    output logic            desc_ready_o,
    input  vec_exec_desc_t  desc_i,

    // L2 Scratchpad — RO Port
    output logic                   ro_req_o,
    input  logic                   ro_gnt_i,
    input  logic                   ro_rvalid_i,
    output logic [L2_BANK_AW-1:0]  ro_row_o,
    input  logic [511:0]           ro_rdata_i,

    // L2 Scratchpad — RW Port
    output logic                   rw_req_o,
    input  logic                   rw_gnt_i,
    output logic [L2_BANK_AW-1:0]  rw_row_o,
    output logic [15:0]            rw_bank_mask_o,
    output logic [511:0]           rw_wdata_o,

    // Tensor↔Vector Fast Path
    input  logic            t2v_valid_i,
    output logic            t2v_ready_o,
    input  bs_capsule_t     t2v_cap_i,
    output logic            t2v_miss_valid_o,
    output fp_miss_reason_e t2v_miss_reason_o,

    output logic            v2t_valid_o,
    input  logic            v2t_ready_i,
    output bs_capsule_t     v2t_cap_o,
    input  logic            v2t_miss_valid_i,
    input  fp_miss_reason_e v2t_miss_reason_i,

    // Completion (done_o fires on DONE and ERROR for credit return)
    output logic              done_o,
    output logic [1:0]        done_ctx_o,
    output logic [TAG_W-1:0]  done_tag_o,

    // Error
    output logic              err_valid_o,
    output vec_error_e        err_code_o,

    // Status
    output logic              busy_o,

    // Performance Counters
    output logic [PERF_CNT_W-1:0] perf_cnt_o [VEC_NUM_PERF_CNTS],
    input  logic              perf_cnt_en_i
);

    // =========================================================================
    // FSM States (same 7 states as v1, multi-pass handled internally)
    // =========================================================================
    // [HW-REVIEW T3-FF/FF3b-c] two new block-boundary states for multi-block streaming
    // RESADD. block_count<=1 NEVER enters them (strict superset). VST_BLK_NEXT is the
    // non-retiring per-block teardown (the analogue of VST_DONE that does NOT assert
    // done_o, so done_o/perf/CP-credit fire exactly once per descriptor); VST_BLK_SETUP
    // lazily fetches the per-16-block scale-sidecar row before the next block's operands.
    // [C-MX STORE ⑦] three new states for the compact-MX store:
    // VST_CMX_PREP (review F8) is a ONE-cycle requantize pre-compute stage —
    // the 16x requantizer cone starts from the REGISTERED result_cap_q and
    // lands in registers (compact_payload_q / compact_scale_q), so it owns a
    // full clock period instead of stacking on top of the live vec datapath
    // cone (post-route evidence: 108.8ns single-cycle cone at a 70ns signoff
    // clock when the scale latch fed from the live result_capsule).
    // VST_SCRD reads the sidecar row on the RO port; VST_SCWB merges this
    // command's scale lane(s) and writes the whole row back (mask 16'hFFFF).
    // Non-compact ops NEVER enter any of them (gated by compact_wb_d/_q) —
    // the legacy store still goes VST_ACTIVE -> VST_L2_WB directly, zero
    // added cycles.
    //
    // [VEC-PIPE ⑥ / C5] VST_ACTIVE internally runs THREE phases per compute
    // pass (active_phase_q: MC correct -> LANE capture -> REDUCE consume) —
    // two stacked pipeline cuts. ⑥ cut the lane_array|reduce boundary (F8's
    // sibling: F8 cut the requant cone BELOW result_cap_q, ⑥ cut the
    // lane->reduce->combine cone ABOVE it); C5 then cut the operand-select +
    // mant_corr correction front off the head of the lane add chain.
    // No new enum state is added; the phase counter lives beside the FSM.
    typedef enum logic [3:0] {
        VST_IDLE      = 4'd0,
        VST_WAIT_OP0  = 4'd1,
        VST_WAIT_OP1  = 4'd2,
        VST_ACTIVE    = 4'd3,
        VST_L2_WB     = 4'd4,
        VST_DONE      = 4'd5,
        VST_ERROR     = 4'd6,
        VST_BLK_NEXT  = 4'd7,
        VST_BLK_SETUP = 4'd8,
        VST_SCRD      = 4'd9,
        VST_SCWB      = 4'd10,
        VST_CMX_PREP  = 4'd11,
        VST_CMX_PREP1 = 4'd12,
        // [C8-c 2026-07-25] leading FRONT stage: registers the per-lane
        // requantizer front (cmx_norm_q/cmx_eff_q/cmx_nz_q) so PREP1 runs the
        // shared-exp max tree from REGISTERED eff/nz.
        VST_CMX_PREP0 = 4'd13,
        // [T1 2026-07-26] requantizer-back align stage: registers the per-lane
        // back-ALIGN products (cmx_al_*_q) so PREP runs the round/encode half
        // only. Chain is now ACTIVE -> PREP0 -> PREP1 -> PREP2 -> PREP ->
        // L2_WB (one per egress window).
        VST_CMX_PREP2 = 4'd14
    } vec_state_e;

    vec_state_e state_q, state_d;

    // =========================================================================
    // Descriptor Decode
    // =========================================================================
    vec_ctrl_t   ctrl;
    logic        ctrl_valid;
    vec_error_e  decode_error;

    // [HW-REVIEW T3-FF/FF2] Resident-SRC1 supported configs = an EXACT-MATCH whitelist:
    //   block16 + E4M3 (NVFP4, single 256b capsule)  OR
    //   block32 + E8M0 (OCP-MX, 2-capsule reader — FF2: 2 sequential 256b RO reads, abs
    //                   scale aligns each window by the shared src1_scale_ref via the
    //                   E8M0 abs path in vec_scale_adapter).
    // Any other (block_size, scale_format) pair fails LOUD at accept (-> VST_ERROR), never
    // deadlocks in VST_WAIT_OP1 or silently mis-scales. vec_cmd_to_desc derives scale_format
    // from block_size, so these are the only consistent pairs reachable via the command path;
    // the explicit pairing is defense-in-depth for a directly-driven descriptor. (Review
    // C1/SRC1-VC-1/SRC1-VC-2; [HW-REVIEW T3] per-residual scale rides desc.src1_scale_ref.)
    logic resident_unsupported;
    assign resident_unsupported = desc_i.src1_resident
        && !( (desc_i.block_size == BLOCK_SIZE_16 && desc_i.scale_format == SCALE_E4M3)
           || (desc_i.block_size == BLOCK_SIZE_32 && desc_i.scale_format == SCALE_E8M0) );

    vec_desc_decode u_desc_decode (
        .desc_i   ( desc_i       ),
        .valid_i  ( desc_valid_i && state_q == VST_IDLE ),
        .ctrl_o   ( ctrl         ),
        .valid_o  ( ctrl_valid   ),
        .error_o  ( decode_error )
    );

    // =========================================================================
    // Latched Control + Multi-Pass Registers
    // =========================================================================
    vec_ctrl_t   ctrl_q;
    vec_error_e  error_q;
    logic [15:0] dst_ref_q;          // v2: latched from desc_i.dst_ref (C2 fix)
    logic [1:0]  num_passes_q;       // 1 or 2 (from ctrl.num_passes)

    // [STEP4-E2E §11.4] Resident-SRC1 producer: for a RESADD with desc.src1_resident,
    // the Vector reads the residual from L2 (its own RO master) in VST_WAIT_OP1 and
    // presents it as an OP_SRC1 capsule on the ingress Source A (vs the fast path).
    // Existing RESADD (src1_resident=0) is untouched — the reader stays RSD_IDLE,
    // ro_req stays 0, resident_valid stays 0 (identical to the prior fast-path SRC1).
    logic [15:0]                 src1_ref_q;        // latched residual L2 row
    logic                        src1_resident_q;   // latched mode bit
    logic signed [15:0]          src1_scale_ref_q;  // [HW-REVIEW T3] latched resident SRC1 abs block exp
    localparam logic [2:0] RSD_IDLE=3'd0, RSD_REQ=3'd1, RSD_WAIT=3'd2, RSD_CAP=3'd3, RSD_DONE=3'd4;
    logic [2:0]                  rsd_state_q;       // resident-read FSM
    logic [HALF_STRIPE_W-1:0]    rsd_data_q;        // captured residual payload (256b)
    logic                        rsd_cap_idx_q;     // [HW-REVIEW T3-FF/FF2] block32 residual
                                                    //   window index (0/1): which 256b capsule
                                                    //   the 2-read reader is fetching/presenting.
    logic                        resident_ready;    // ingress accepted the resident capsule
    logic [1:0]  pass_idx_q;         // current pass (0 or 1)
    logic        sub_count_q;        // capsule sub-counter within WAIT_OP states
    logic        src0_loaded_q, src1_loaded_q;

    // Capsule latches — primary (pass 0) and secondary (pass 1, block32 only)
    bs_capsule_t src0_cap_q, src1_cap_q;          // pass 0 capsules
    bs_capsule_t src0_cap_b_q, src1_cap_b_q;      // pass 1 capsules (block32)

    // Number of capsules needed per operand: 1 for block16, 2 for block32
    logic caps_per_operand;
    assign caps_per_operand = (num_passes_q == 2'd2);

    // CL-4: Role misorder stall counter
    //   Counts consecutive cycles where queue head has wrong operand_role.
    //   After ROLE_STALL_LIMIT cycles, triggers ERROR (prevents HOL deadlock).
    localparam int ROLE_STALL_LIMIT = 64;
    logic [6:0] role_stall_cnt_q;

    // CL-8: Active state watchdog counter
    //   Counts cycles spent in VST_ACTIVE (including multi-pass).
    //   After VEC_MAX_OP_CYCLES, forces fallback to L2_WB.
    logic [9:0] watchdog_cnt_q;  // up to 1024
    // HW-REVIEW T4: no-progress operand-wait watchdog. Counts cycles in
    //   VST_WAIT_OP0/OP1 with no accepted operand (oq_pop_ready) — covers a
    //   missing fast-path operand AND a hung resident-SRC1 read. role_stall_cnt
    //   only counts wrong-ORDER capsules present; on genuine NON-delivery the
    //   queue is empty so it never fires, and watchdog_cnt_q only runs in
    //   VST_ACTIVE — so without this the unit stalls forever and never returns
    //   its CP credit (done_o only fires on DONE/ERROR).
    logic [9:0] op_wait_cnt_q;

    // ── [HW-REVIEW T3-FF/FF3b-c] Multi-block streaming RESADD outer-loop state ──
    //   A resident residual spanning N = block_count blocks, each with its OWN absolute
    //   block exponent read from an L2 scale-sidecar (16 signed-16b exps per 256b row).
    //   The outer block index blk_idx_q drives per-block addressing (read/write/scale),
    //   nesting OVER the existing 1-bit block32 inner-window machinery. All of this is
    //   GATED by streaming_mode_q, which is FALSE for block_count<=1 -> byte-identical.
    logic [15:0] blk_idx_q;        // outer block index k (0..block_count-1)
    logic [15:0] block_count_q;    // N (clamped >=1 at latch)
    logic [15:0] sidecar_base_q;   // physical L2 row of exp[0] (cp_scheduler xlat'd)
    logic        streaming_mode_q; // src1_resident && block_count>1 (latched from desc_i)
    logic        degraded_q;       // FOLD-6: sticky — a streaming watchdog spill occurred;
                                   //   forces err_valid_o at the final VST_DONE (no silent success)
    logic [9:0]  l2wb_wait_cnt_q;  // FOLD-5: streaming L2_WB write-stall watchdog (rw_gnt never grants)
    logic [1:0]  fp_blk_accept_cnt_q; // FOLD-3: fast-path SRC0 capsules accepted for the current
                                   //   block (streaming only); caps the fast path at caps_per_block so
                                   //   an eager producer's block k+1 SRC0 can't jump ahead of block k's
                                   //   resident SRC1 in the shared ingress FIFO.
    // Scale-sidecar lazy cache (one 256b row = 16 exps), refreshed per 16-block group.
    localparam logic [1:0] SC_CHECK=2'd0, SC_REQ=2'd1, SC_WAIT=2'd2, SC_RDY=2'd3;
    logic [1:0]               sc_state_q;
    logic [HALF_STRIPE_W-1:0] sc_row_q;   // cached sidecar row
    logic [11:0]              sc_grp_q;    // group tag = blk_idx[15:4] of the cached row
    logic                     sc_valid_q;  // cache holds a valid row

    // ── [HW-REVIEW T3-FF/FF3b-c] streaming combinational guards ──
    logic [15:0] block_count_eff_in; // clamp 0->1 of the INCOMING desc.block_count
    logic        streaming_in;       // FOLD-4: derive streaming from desc_i, NOT block_count_q
    logic        more_blocks;        // another block remains after blk_idx_q
    logic [1:0]  caps_per_block;     // 1 (block16) or 2 (block32 = 2 windows)
    logic [15:0] blk_row_off;        // additive per-block row offset = k * caps_per_block
    logic        sc_cache_hit;       // cached sidecar row covers the current block's group
    logic        sc_ready;           // sidecar exp for the current block is available
    assign block_count_eff_in = (desc_i.block_count == 16'd0) ? 16'd1 : desc_i.block_count;
    assign streaming_in       = desc_i.src1_resident && (block_count_eff_in > 16'd1);
    assign more_blocks        = streaming_mode_q && ((blk_idx_q + 16'd1) < block_count_q);
    assign caps_per_block     = caps_per_operand ? 2'd2 : 2'd1;
    assign blk_row_off        = caps_per_operand ? {blk_idx_q[14:0], 1'b0} : blk_idx_q;
    assign sc_cache_hit       = sc_valid_q && (sc_grp_q == blk_idx_q[15:4]);
    assign sc_ready           = sc_cache_hit || (sc_state_q == SC_RDY);

    // CL-5: 40-bit STAT partial accumulator for block32 cross-pass precision
    //   Holds pass-0 raw window sum (S-STAT v1.2 S9): unsigned mant normalized
    //   to bit39 (or 0) and a 12-bit signed exponent, rm*2^re exact.
    //   Written in the !last_pass branch of VST_ACTIVE when reduce_mode ==
    //   REDUCE_STAT and num_passes == 2.
    //   READ PATH (v6.0 Round 3b — activated this round): consumed by
    //   combine_reduce_stat_40b_to_reduce() in the REDUCE_STAT branch of
    //   the combined_reduce always_comb. Prior to Round 3b these registers
    //   were written but never read — Bug #3.
    logic [REDUCE_STAT_W-1:0]        partial_stat_mant_q;
    logic signed [STAT_EXP_W-1:0]    partial_stat_exp_q;

    // ── v6.0 Round 3a: Result capsule latch (Bug #2 fix) ──
    // Snapshots result_capsule at (VST_ACTIVE && last_pass && result_valid).
    // VST_L2_WB reads from result_cap_q.payload instead of the live
    // result_capsule, because result_packer outputs drive to zero once
    // pipe_active falls (which happens on the state→L2_WB transition).
    //
    // Full bs_capsule_t is latched (not just payload) so Phase 2 L2 Scale
    // Sidecar can source metadata (elem_fmt/block_size/scale_format/
    // scale_epoch/inline_scale/layout_tag) from the same register without
    // another round of RTL changes.
    //
    // result_cap_valid_q follows standard valid-bit semantics:
    //   reset / soft_reset  → 0
    //   latch event         → 1 (capsule is stable and represents a real
    //                            pipeline result for the current op)
    //   VST_DONE / VST_ERROR → 0 (invalidate before releasing the op)
    //
    // For block32 dual-capsule egress, this register is re-latched at
    // each window's last_pass cycle, so its content tracks the currently
    // egressing window. The pre-existing egress_window_q addressing in
    // VST_L2_WB is preserved unchanged by Round 3a.
    bs_capsule_t result_cap_q;
    logic        result_cap_valid_q;

    // ── [C-MX STORE ⑦] compact-MX store state ──
    // compact_scale_q[w]: per-egress-window scale (16b; E8M0 uses the low 8b
    //   byte, E4M3/NVFP4 the full 16b signed unclamped ref_exp), REGISTERED in
    //   the VST_CMX_PREP pipeline stage (review F8) from the requantizer bank
    //   fed by result_cap_q. Indexed by egress_window_q, so window 0/1 of a
    //   block32 store each get their own independently-normalized scale.
    // compact_payload_q: the requantized narrow payload (FP4 64b in [63:0] /
    //   FP8 128b), REGISTERED in VST_CMX_PREP alongside compact_scale_q
    //   (review F8: the requantizer cone runs result_cap_q -> PREP registers
    //   and owns a full clock; the rw_wdata_o cone becomes trivial. The
    //   pre-F8 shape — scale latched same-cycle from the LIVE result_capsule
    //   and payload combinational into the port — measured a 108.8ns
    //   single-cycle cone post-route at a 70ns signoff clock).
    // compact_wb_q: this op's L2 write-back is a compact-MX store (requantized
    //   narrow payload + sidecar RMW). Latched at the result_cap_q latch point
    //   (same cycle, same predicate; its D-cone is only ctrl decode + the
    //   registered-capsule scale decode — cheap); qualified everywhere by
    //   result_cap_valid_q (watchdog-forced spill with no result keeps today's
    //   full-mask zero write). NOT latched (lossless full-payload fallback)
    //   when the capsule scale is not a representable power of 2 or the
    //   block32 fragments disagree on the block scale (reviews F2/F3); the
    //   !result_escape_needed term is a defensive guard only — a STORE
    //   (VEC_UNPACK, renorm_en=0) has result_escape_needed structurally 0,
    //   and compact quantize underflow-to-0 is MX-inherent loss, not escape.
    // sc_wb_row_q: sidecar row captured in VST_SCRD for the read-modify-write
    //   (dedicated register — deliberately NOT the streaming-RESADD sc_row_q
    //   cache, to keep the two mechanisms disentangled).
    // scrd_wait_q: VST_SCRD RO handshake phase (0 = requesting until ro_gnt_i,
    //   1 = waiting the 1-cycle-later ro_rvalid_i) — same protocol as SC_REQ/
    //   SC_WAIT in VST_BLK_SETUP.
    logic [15:0]              compact_scale_q [2];
    logic [127:0]             compact_payload_q;
    logic                     compact_wb_q;
    logic [HALF_STRIPE_W-1:0] sc_wb_row_q;
    logic                     scrd_wait_q;

    // ── v6.0 Round 3b: Pass-0 lane results latch (Bug #4 fix) ──
    // Snapshots lane_results[VEC_LANES] at the !last_pass cycle of VST_ACTIVE
    // when the op is a block32 lane-only primitive (need_src1 irrelevant;
    // VEC_PACK / VEC_UNPACK / VEC_MOE_DISPATCH_PACK in block32 mode).
    //
    // The issue being fixed:
    //   active_src0_cap / active_src1_cap use pass_idx_q for window
    //   selection. By the time last_pass==1, pass_idx_q==1 and lane_results
    //   contain pass-1 element data. Without this latch, the dual-capsule
    //   egress would emit pass-1 data at BOTH windows, losing elements
    //   [0:15] of the original block entirely.
    //
    // Gate condition (explicit all 4 predicates per Round 3b decision #2):
    //   num_passes_q == 2           (block32 only)
    //   pass_idx_q   == 0           (pass-0 completion, before pass_idx++)
    //   !ctrl_q.reduce_en           (reduce path outputs scalar, no dual egress)
    //   !ctrl_q.renorm_en           (renorm path has its own combine mechanism)
    //   lane_valid_q                ([VEC-PIPE ⑥] registered lane output is stable)
    //
    // partial_lane_valid_q semantics:
    //   reset / soft_reset / DONE / ERROR → 0
    //   latch event → 1
    //   Consumed by effective_lane_results selector to choose source.
    //
    // Future note: when Future Plan Phase 6 introduces the 32-element
    // result buffer for global renorm re-alignment, this register array
    // becomes a natural subset of that buffer and can be refactored away
    // (or kept — the semantics are compatible).
    vec_lane_result_t partial_lane_results_q [VEC_LANES];
    logic             partial_lane_valid_q;

    // ── [VEC-PIPE ⑥] LANE|REDUCE pipeline cut (F8's sibling: F8 cut the
    // requant cone BELOW result_cap_q, this cuts the lane->reduce->combine
    // cone ABOVE it). VST_ACTIVE splits each compute pass into two phases:
    //   LANE   phase (active_phase_q=0): ctrl broadcast + lane array compute,
    //          captured into lane_results_q at the phase boundary;
    //   REDUCE phase (active_phase_q=1): reduce/renorm/xpass-combine/packer run
    //          from the REGISTERED source, and all pre-existing ACTIVE latches
    //          and state transitions execute.
    // result_valid is single-rooted in lane_valid (all three packer branches
    // derive from valid_i), so restricting lane_valid_q to the REDUCE phase
    // self-gates every downstream latch predicate — no per-consumer rewrites.
    //
    // ── [C5 2026-07-24] THREE phases (was two) ──────────────────────────────
    //   PH_MC     : the E4M3 precise mant_corr correction front (vec_lane_prep)
    //               runs on the freshly selected operands and lands in
    //               src0_lane_q/src1_lane_q;
    //   PH_LANE   : the lane add/compare chain runs from the REGISTERED
    //               operands and lands in lane_results_q (as before);
    //   PH_REDUCE : reduce/renorm/xpass-combine/packer + every pre-existing
    //               ACTIVE latch and state transition (as before).
    // Measured motive: the deployed binding path was
    //   pass_idx_q -> operand select (509 ps) -> mant_corr multiply (517 ps)
    //   -> align+add+guard-fit (1764 ps) -> lane_results_q  = 2805 ps,
    // i.e. the operand-select + correction front was in series with the whole
    // add chain in ONE clock. PH_MC splits it (~1180 | ~1684 ps).
    // ── [C8-b 2026-07-25] FOUR phases (was three) ───────────────────────────
    //   PH_RENORM : the renorm/quant engine runs from the REGISTERED
    //               lane_results_q and lands in renorm_result_q. Pressured
    //               evidence: the ⑥ capture arc lane_results_q → renorm
    //               (~1016 ps) → xpass (~1104 ps incl. packer) → result_cap_q
    //               was 2160.88 ps in ONE cycle (AnchorPlan §C8,
    //               c8_probe_cmxlane_20260725.log); the renorm|xpass module
    //               boundary splits it ~1100 | ~1100.
    //   PH_REDUCE : reduce/xpass-combine/packer + every pre-existing ACTIVE
    //               latch and state transition — now consuming the REGISTERED
    //               renorm_result_q via a second one-cycle valid token
    //               (lane_valid_q2). Value-preserving: lane_results_q (loaded
    //               at the PH_LANE boundary) and ctrl_q are HELD across
    //               PH_RENORM→PH_REDUCE, so renorm(x) registered at PH_RENORM
    //               equals the live value the old single-cycle phase used.
    // [C9-b 2026-07-25] FIVE phases (was four): PH_RENORM2 runs the renorm
    // BACK half (escape/re-align/pack) from the PH_RENORM-registered front
    // (max/min-exp tree) — the 1750.47 ps lane_results_q -> u_renorm ->
    // renorm_result_q arc (a1_probes tier-3) splits at the front|back module
    // boundary. Rotor widened to 3 bits.
    // [MC2 2026-07-26] SIX phases (was five): PH_MC2 runs the alignment-
    // control + negate BACK half of the old PH_MC from the REGISTERED
    // src*_lane_q (the front — operand select + mant_corr multiply — already
    // meets on its own: signoff src0/src1_lane_q MET +26/+33 while the
    // mc_abs_diff_q tail rode select+multiply+compare in ONE cycle, -88.17;
    // T1c_Preflight_LaneUngate_MC2Split §0/§1.2).
    // [LANE2 2026-07-26] SEVEN phases (was six): the lane ADD/SUB arm itself
    // splits align|arith at the vec_lane_align|vec_lane_addsub leaf boundary.
    //   PH_LANE  : the alignment front (operand route + tz_shifter) runs on
    //              the REGISTERED operands + shift controls and lands in
    //              lane_align_q/lane_sticky_q (the 21b/lane seam);
    //   PH_LANE2 : the arithmetic back half (assemble + 21b add + guard-fit
    //              + special branches) runs from the seam + the same HELD
    //              registers and lands in lane_results_q (as before).
    // Measured motive: the last signoff wall was the ONE-cycle align+add
    // chain (~1489 ps) with the opt_merge-folded shared-flag broadcast head
    // (~224 ps) riding it (m1v_t1c 1766.20, -96.20 — LANE2_Preflight §0/§1.5).
    // [MC2F 2026-07-27] EIGHT phases (was seven): PH_SEL runs the operand
    // SELECT front (pass_idx window select + element unpack) one phase ahead
    // of the mant_corr multiply. The old PH_MC ran select+multiply in one
    // cycle = the src*_lane_q signoff wall (V0-D: select head ~744ps +
    // multiply cone ~745ps + write tail ~223ps). PH_MC now consumes the
    // REGISTERED src*_sel_q / mc2f_corr_* / mc2f_precise_q only.
    // 🔴 3-bit rotor is now SATURATED (8 phases = 3'd0..3'd7): any further
    // phase insertion must first widen active_phase_q to 4 bits.
    localparam logic [2:0] PH_SEL     = 3'd0;
    localparam logic [2:0] PH_MC      = 3'd1;
    localparam logic [2:0] PH_MC2     = 3'd2;
    localparam logic [2:0] PH_LANE    = 3'd3;
    localparam logic [2:0] PH_LANE2   = 3'd4;
    localparam logic [2:0] PH_RENORM  = 3'd5;
    localparam logic [2:0] PH_RENORM2 = 3'd6;
    localparam logic [2:0] PH_REDUCE  = 3'd7;

    logic [2:0]       active_phase_q;   // 0=SEL 1=MC 2=MC2 3=LANE 4=LANE2 5=RENORM 6=RENORM2 7=REDUCE
    logic             lane_valid_q;     // 1 during PH_RENORM (renorm-front token)
    logic             lane_valid_q2;    // [C8-b][C9-b] 1 during PH_RENORM2 (renorm-back token)
    logic             lane_valid_q3;    // [C9-b] 1 during PH_REDUCE (reduce/packer token)
    vec_lane_result_t lane_results_q [VEC_LANES];

    // [LANE2 2026-07-26] the align|arith seam: the PH_LANE-registered shifter
    // output + sticky (20b+1b x 16 = 336 DFF). Written on EVERY PH_LANE visit
    // (valid or not — same always-written-first contract as rn_front_*_q);
    // PH_LANE2 is reachable only via PH_LANE (no-skip arc asserted below), so
    // the seam is never consumed stale. X-clean '0 reset only.
    logic signed [VEC_SHIFT_WIDTH-1:0] lane_align_q  [VEC_LANES];
    logic                              lane_sticky_q [VEC_LANES];
    // live per-lane outputs of the PH_LANE align leaves (sampled by always_ff;
    // src*_prep same generate-array pattern — no generate-scope XMR)
    logic signed [VEC_SHIFT_WIDTH-1:0] lane_align_d  [VEC_LANES];
    logic                              lane_sticky_d [VEC_LANES];

    // [C5] registered, already-corrected lane operands (the PH_MC output).
    vec_elem_t        src0_lane_q [VEC_LANES];
    vec_elem_t        src1_lane_q [VEC_LANES];

    // [MC2F 2026-07-27] the select|multiply seam: operands as SELECTED
    // (window-muxed + unpacked) but NOT yet corrected, registered at the
    // PH_SEL boundary (nominal 30b x 16 x 2; exp/is_nan are lane-uniform and
    // is_inf is constant 0, so synthesis folds them — disclosed, harmless).
    // Plus the correction controls (the mant_corr BYPASS leg — preflight
    // §0.4): registering the operands alone would leave the live
    // vec_scale_adapter decode cone feeding the multiply directly.
    vec_elem_t        src0_sel_q [VEC_LANES];
    vec_elem_t        src1_sel_q [VEC_LANES];
    logic [7:0]       mc2f_corr_s0_q, mc2f_corr_s1_q;
    logic             mc2f_precise_q;

    // [C9 2026-07-25] C-minimal shift-control cut: the LANE_ADD/SUB alignment
    // controls (abs_diff[5:0] + shift_src1_side) are registered one phase
    // ahead of PH_LANE (7b x 16 = 112 DFF). The lane array consumes them via
    // its ext_* ports, freeing PH_LANE from the serial exp-compare ->
    // shifter-control resolution (the 1770.31 ps PH_LANE wall, §C9).
    // [MC2 2026-07-26] now resolved in PH_MC2 from the REGISTERED
    // src*_lane_q (the old PH_MC ran select+multiply+compare in one cycle =
    // the -88.17 mc_abs_diff_q signoff wall; front alone is MET +26/+33).
    // Registered identity: values == vec_lane_shift_ctrl(src*_lane_q) by
    // construction (shadow tripwire below pins this against hoist drift).
    logic [5:0]       mc_abs_diff_q   [VEC_LANES];
    logic             mc_shift_src1_q [VEC_LANES];

    // [T1b 2026-07-26] LANE_SUB negate pre-application: the op-adjusted 17-bit
    // src1 mantissa (eff_src1_mant) is resolved ([MC2] in PH_MC2, from the
    // REGISTERED src1_lane_q) + the HELD ctrl_q.lane_op, and
    // registered here (17b x 16 = 272 DFF). The lane array consumes it via
    // ext_eff_src1_mant_i, freeing PH_LANE's add chain from the lane_op
    // decode + broadcast front. Signoff evidence @1670 RC
    // (t1_arcdecomp_vector_20260726.log B5): ctrl_q[40]^[41] (lane_op[1:0]
    // XOR) -> AND3 single point -> ~400ps buffer tree -> negate-select at the
    // adder head riding the FULL align+add chain = 2174.98 ps
    // (lane_results_q wall, slack -210.23) while the data-only arcs
    // (src*_lane_q ->) sit at -33. Registered identity: value ==
    // op-negate(src1_lane_q) by construction (shadow tripwire below).
    logic signed [VEC_MANT_W:0] mc_eff_s1_q [VEC_LANES];

    // =========================================================================
    // Fast Path Interface
    // =========================================================================
    logic           fp_ing_valid,  fp_ing_ready;
    bs_capsule_t    fp_ing_cap;
    logic           fp_egr_valid,  fp_egr_ready;
    bs_capsule_t    fp_egr_cap;
    logic           fp_egr_accepted, fp_egr_rejected;
    fp_miss_reason_e fp_egr_reject_reason;
    logic           oq_full;

    vec_fastpath_if u_fastpath (
        .clk_i, .rst_ni,
        .t2v_valid_i, .t2v_ready_o, .t2v_cap_i,
        .t2v_miss_valid_o, .t2v_miss_reason_o,
        .ing_valid_o    ( fp_ing_valid ),
        .ing_ready_i    ( fp_ing_ready ),
        .ing_cap_o      ( fp_ing_cap   ),
        .vec_busy_i     ( busy_o       ),
        .queue_full_i   ( oq_full      ),
        .v2t_valid_o, .v2t_ready_i, .v2t_cap_o,
        .v2t_miss_valid_i, .v2t_miss_reason_i,
        .egr_valid_i    ( fp_egr_valid    ),
        .egr_ready_o    ( fp_egr_ready    ),
        .egr_cap_i      ( fp_egr_cap      ),
        .egr_accepted_o ( fp_egr_accepted ),
        .egr_rejected_o ( fp_egr_rejected ),
        .egr_reject_reason_o ( fp_egr_reject_reason )
    );

    // =========================================================================
    // Ingress Arbiter
    // =========================================================================
    logic           arb_out_valid, arb_out_ready;
    bs_capsule_t    arb_out_cap;
    logic           arb_miss_valid;
    fp_miss_reason_e arb_miss_reason;
    logic           arb_miss_fpath;

    // [STEP4-E2E §11.4] Resident path driven by the resident-SRC1 reader (below).
    // resident_valid asserts while the captured residual capsule awaits ingress
    // acceptance; resident_cap is assembled to MATCH ctrl_q's contract so
    // vec_ingress_arb's exact block_size/scale_format/scale_epoch check passes.
    logic           resident_valid;
    bs_capsule_t    resident_cap;
    assign resident_valid = (rsd_state_q == RSD_CAP);
    always_comb begin
        resident_cap                    = '0;
        resident_cap.payload            = rsd_data_q;
        resident_cap.elem_fmt           = ELEM_BFP_INTERNAL;
        resident_cap.block_size         = ctrl_q.block_size;
        resident_cap.scale_format       = ctrl_q.scale_format;
        resident_cap.layout_tag         = 4'd0;
        // [HW-REVIEW T3] per-residual ABSOLUTE block scale: exponent in scale_ref
        // (software-provided via the descriptor, desc.src1_scale_ref -> src1_scale_ref_q),
        // inline_scale = bit8 (ABS_EXP_PRESENT) + 0x38 byte. The abs path (vec_scale_adapter)
        // aligns by scale_ref for BOTH supported residents: block16/E4M3 (0x38 -> mant_corr
        // 128 identity) and, since FF2, block32/E8M0 (the 0x38 byte is a don't-care
        // placeholder — the E8M0 abs branch ignores it and forces mant_corr 128). For
        // block32 the SAME scale_ref + byte are presented on BOTH window capsules (one shared
        // scale over 32 elems); the payload (rsd_data_q) differs per window. The L2 RO port is
        // payload-only (256b half-stripe, top zero-extended) so the scale rides the command,
        // not an L2 sidecar.
        // [HW-REVIEW T3-FF/FF3b-c] per-block absolute exponent. For multi-block streaming
        // (streaming_mode_q) the block's exp[k] comes from the cached scale-sidecar row
        // (lane k mod 16); for single-block (today) it stays the latched desc.src1_scale_ref.
        // For block32 BOTH windows of block k present the SAME exp[k] (blk_idx_q is stable
        // across the two windows), one shared scale over the 32 elements.
        resident_cap.scale_ref          = streaming_mode_q
                                        ? pe_pkg::sidecar_scale_k(sc_row_q, blk_idx_q[3:0])
                                        : src1_scale_ref_q;
        resident_cap.inline_scale       = 32'h138;
        resident_cap.scale_inline_valid = 1'b1;
        resident_cap.scale_epoch        = ctrl_q.scale_epoch;
        resident_cap.operand_role       = pe_pkg::OP_SRC1;
        resident_cap.fwd_eligible       = 1'b1;   // don't-care on resident path
        resident_cap.producer           = pe_pkg::DOMAIN_VECTOR;
    end

    // [HW-REVIEW T3-FF/FF3b-c, FOLD-3] Fast-path SRC0 accept-limiter for streaming.
    //   The ingress arb gives the fast path PRIORITY over the resident SRC1 and only
    //   checks block/format/epoch (never operand_role), and ctrl_valid_i admits capsules
    //   in BOTH WAIT_OP0 and WAIT_OP1. So an eager producer streaming block k+1's SRC0
    //   would (a) win over block k's resident SRC1 in WAIT_OP1, and (b) slip a 2nd SRC0
    //   into block k's WAIT_OP0 ahead of the resident SRC1 -> shared-FIFO role-misorder.
    //   Fix: in streaming mode close the fast path during WAIT_OP1 (resident only) and
    //   cap WAIT_OP0 acceptance at caps_per_block. Non-streaming is fully open (dual
    //   fast-path operands) so single-block / non-resident RESADD is byte-identical.
    logic fp_stream_block, fp_valid_gated, fp_accept;
    assign fp_stream_block = streaming_mode_q
        && ( (state_q == VST_WAIT_OP1)
          || (state_q == VST_WAIT_OP0 && (fp_blk_accept_cnt_q >= caps_per_block)) );
    assign fp_valid_gated  = fp_ing_valid && !fp_stream_block;
    assign fp_accept       = fp_valid_gated && fp_ing_ready;   // a fast-path capsule was pushed

    vec_ingress_arb u_ingress_arb (
        .clk_i, .rst_ni,
        .resident_valid_i ( resident_valid ),
        .resident_ready_o ( resident_ready ),
        .resident_cap_i   ( resident_cap   ),
        .fpath_valid_i    ( fp_valid_gated ),
        .fpath_ready_o    ( fp_ing_ready   ),
        .fpath_cap_i      ( fp_ing_cap     ),
        .ctrl_i           ( ctrl_q         ),
        .ctrl_valid_i     ( state_q inside {VST_WAIT_OP0, VST_WAIT_OP1} ),
        .out_valid_o      ( arb_out_valid  ),
        .out_ready_i      ( arb_out_ready  ),
        .out_cap_o        ( arb_out_cap    ),
        .miss_valid_o     ( arb_miss_valid ),
        .miss_reason_o    ( arb_miss_reason),
        .miss_from_fpath_o( arb_miss_fpath )
    );

    // =========================================================================
    // Operand Queue
    // =========================================================================
    logic           oq_pop_valid, oq_pop_ready;
    bs_capsule_t    oq_pop_cap;
    logic           oq_empty;

    vec_operand_queue u_op_queue (
        .clk_i, .rst_ni,
        .flush_i      ( soft_reset_i  ),
        .push_valid_i ( arb_out_valid ),
        .push_ready_o ( arb_out_ready ),
        .push_cap_i   ( arb_out_cap   ),
        .pop_valid_o  ( oq_pop_valid  ),
        .pop_ready_i  ( oq_pop_ready  ),
        .pop_cap_o    ( oq_pop_cap    ),
        .count_o      ( /* unused */  ),
        .full_o       ( oq_full       ),
        .empty_o      ( oq_empty      )
    );

    // =========================================================================
    // Operand Role Dispatch — Queue Pop Gating (B1.1 fix + CL-4 HOL fix)
    //
    // Pop is allowed only when:
    //   1. FSM is in a WAIT state
    //   2. Queue head's operand_role matches the expected role for that state
    //      WAIT_OP0 expects OP_SRC0, WAIT_OP1 expects OP_SRC1
    // If role doesn't match, pop_ready stays 0 and capsule remains in queue.
    //
    // CL-4 fix: Detect role misorder (queue head has wrong role for current
    // state) and report error after a grace period. This prevents indefinite
    // HOL blocking when producer sends capsules in wrong order.
    //
    // Contract requirement (documented here and in VEC_Interface_Contract):
    //   Producers MUST send operands in SRC0-first order for dual-operand ops.
    //   If SRC1 arrives before SRC0, the Vector Unit will stall for
    //   ROLE_STALL_LIMIT cycles, then report VERR_ROLE_MISORDER and return
    //   the credit via ERROR path.
    // =========================================================================
    logic role_match;
    logic role_misorder;  // CL-4: queue head has wrong role

    always_comb begin
        role_match    = 1'b0;
        role_misorder = 1'b0;
        case (state_q)
            VST_WAIT_OP0: begin
                role_match    = (oq_pop_cap.operand_role == OP_SRC0);
                role_misorder = oq_pop_valid && (oq_pop_cap.operand_role != OP_SRC0);
            end
            VST_WAIT_OP1: begin
                role_match    = (oq_pop_cap.operand_role == OP_SRC1);
                role_misorder = oq_pop_valid && (oq_pop_cap.operand_role != OP_SRC1);
            end
            default: begin
                role_match    = 1'b0;
                role_misorder = 1'b0;
            end
        endcase
    end

    assign oq_pop_ready = (state_q inside {VST_WAIT_OP0, VST_WAIT_OP1})
                        && oq_pop_valid && role_match;

    // =========================================================================
    // Dual Scale Adapters (B1.2 fix)
    //
    // Independent decode for src0 and src1. Each adapter reads from its
    // respective capsule's inline_scale, gated by scale_inline_valid (B4 fix).
    // =========================================================================
    vec_internal_scale_t adapted_scale_src0, adapted_scale_src1;
    logic                scale_valid_src0,   scale_valid_src1;
    logic                scale_error_src0,   scale_error_src1;

    // Active capsule for current pass (window selection)
    // [C-MX STORE ⑦ F3] "一块一指数" invariant note: at last_pass (pass_idx=1)
    // this mux selects the SECOND capsule, so the result packer's scale
    // passthrough tags BOTH block32 egress windows with cap_b's scale
    // metadata. The compact store therefore requires both SRC0 fragments to
    // decode to the SAME block scale (cmx_frag_mismatch check) — a mismatch
    // falls back losslessly to the full-payload write.
    bs_capsule_t active_src0_cap, active_src1_cap;
    assign active_src0_cap = (pass_idx_q == 2'd0) ? src0_cap_q : src0_cap_b_q;
    assign active_src1_cap = (pass_idx_q == 2'd0) ? src1_cap_q : src1_cap_b_q;

    vec_scale_adapter u_scale_adapter_src0 (
        .raw_scale_i          ( active_src0_cap.inline_scale[7:0]    ),
        .scale_format_i       ( ctrl_q.scale_format                   ),
        .scale_inline_valid_i ( active_src0_cap.scale_inline_valid    ),
        // [HW-REVIEW T3] absolute-scale alignment: unclamped block exp from scale_ref
        .abs_exp_i            ( $signed(active_src0_cap.scale_ref)     ),
        .abs_exp_valid_i      ( active_src0_cap.inline_scale[BS_ABS_EXP_BIT]
                                && (ctrl_q.scale_format inside {SCALE_E4M3, SCALE_E8M0}) ),
        .valid_i              ( ctrl_q.scale_adapt_en && src0_loaded_q ),
        .scale_o              ( adapted_scale_src0                    ),
        .valid_o              ( scale_valid_src0                      ),
        .error_o              ( scale_error_src0                      )
    );

    vec_scale_adapter u_scale_adapter_src1 (
        .raw_scale_i          ( active_src1_cap.inline_scale[7:0]    ),
        .scale_format_i       ( ctrl_q.scale_format                   ),
        .scale_inline_valid_i ( active_src1_cap.scale_inline_valid    ),
        // [HW-REVIEW T3] absolute-scale alignment: unclamped block exp from scale_ref
        .abs_exp_i            ( $signed(active_src1_cap.scale_ref)     ),
        .abs_exp_valid_i      ( active_src1_cap.inline_scale[BS_ABS_EXP_BIT]
                                && (ctrl_q.scale_format inside {SCALE_E4M3, SCALE_E8M0}) ),
        .valid_i              ( ctrl_q.scale_adapt_en && src1_loaded_q && ctrl_q.need_src1 ),
        .scale_o              ( adapted_scale_src1                    ),
        .valid_o              ( scale_valid_src1                      ),
        .error_o              ( scale_error_src1                      )
    );

    // =========================================================================
    // v6.0 Round 3a: Scale decode error aggregation
    //
    // Strict semantics (Round 3a decision ①): when an adapter reports
    // error_o=1 while its scale is actually required by the current op,
    // treat it as a contract violation and route to VST_ERROR with
    // VERR_SCALE_DECODE. Do NOT convert to escape (that path is reserved
    // for numeric range issues, per CL-9 + vec_renorm_quant semantics).
    //
    // Error is gated by:
    //   - ctrl_q.scale_adapt_en : we only care about decode results when
    //                             the pipeline is actually consuming scale
    //   - src*_loaded_q         : ignore adapter errors before the capsule
    //                             has arrived (adapters are combinational
    //                             over raw_scale_i and may momentarily see
    //                             stale input during WAIT_OPn)
    //   - ctrl_q.need_src1      : for src1, only relevant for dual-operand
    //                             primitives (RESADD / MERGE)
    //
    // Legal identity fallback (scale_inline_valid=0 when needed) is handled
    // inside vec_scale_adapter itself — it does NOT set error_o in that
    // case, so it does NOT trigger VERR_SCALE_DECODE here.
    // =========================================================================
    logic scale_any_error;
    always_comb begin
        scale_any_error = 1'b0;
        if (ctrl_q.scale_adapt_en) begin
            if (src0_loaded_q && scale_error_src0)
                scale_any_error = 1'b1;
            if (src1_loaded_q && ctrl_q.need_src1 && scale_error_src1)
                scale_any_error = 1'b1;
        end
    end

    // =========================================================================
    // Element Unpack (16-lane, window-selected, dual independent scale)
    //
    // pass_idx selects which capsule pair provides element data:
    //   pass 0 → src0_cap_q / src1_cap_q
    //   pass 1 → src0_cap_b_q / src1_cap_b_q (block32 only)
    //
    // src0 elements use adapted_scale_src0.exp_adj
    // src1 elements use adapted_scale_src1.exp_adj (independently decoded)
    // =========================================================================
    vec_elem_t src0_elems [VEC_LANES];
    vec_elem_t src1_elems [VEC_LANES];

    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            // src0 elements
            if (src0_loaded_q && i * VEC_MANT_W + VEC_MANT_W <= BS_CAP_PAYLOAD_W) begin
                logic signed [VEC_MANT_W-1:0] raw_mant;
                raw_mant = active_src0_cap.payload[i*VEC_MANT_W +: VEC_MANT_W];

                src0_elems[i].mant    = raw_mant;
                src0_elems[i].exp     = adapted_scale_src0.exp_adj;  // independent src0 scale
                src0_elems[i].sign    = raw_mant[VEC_MANT_W-1];
                src0_elems[i].is_zero = (raw_mant == '0);
                src0_elems[i].is_nan  = adapted_scale_src0.special_nan;
                src0_elems[i].is_inf  = 1'b0;
            end else begin
                src0_elems[i] = VEC_ELEM_ZERO;
            end

            // src1 elements (for dual-operand ops — independent scale)
            if (src1_loaded_q && ctrl_q.need_src1
                && i * VEC_MANT_W + VEC_MANT_W <= BS_CAP_PAYLOAD_W) begin
                logic signed [VEC_MANT_W-1:0] raw_mant1;
                raw_mant1 = active_src1_cap.payload[i*VEC_MANT_W +: VEC_MANT_W];

                src1_elems[i].mant    = raw_mant1;
                src1_elems[i].exp     = adapted_scale_src1.exp_adj;  // independent src1 scale
                src1_elems[i].sign    = raw_mant1[VEC_MANT_W-1];
                src1_elems[i].is_zero = (raw_mant1 == '0);
                src1_elems[i].is_nan  = adapted_scale_src1.special_nan;
                src1_elems[i].is_inf  = 1'b0;
            end else begin
                src1_elems[i] = VEC_ELEM_ZERO;
            end
        end
    end

    // =========================================================================
    // Lane Array
    // =========================================================================
    vec_lane_result_t lane_results [VEC_LANES];
    logic             lane_valid;
    logic             pipe_active;

    assign pipe_active = (state_q == VST_ACTIVE);

    // =========================================================================
    // D10: E4M3 precise-mode gate (mant_corr into the RESADD lane)
    //
    // Engage precise correction when the operands carry an E4M3 block scale and
    // the lane is doing a dual-operand aligned add (LANE_ADD / LANE_SUB). Both
    // operand mantissas are then multiplied by their independently-decoded
    // mant_corr/128 (adapted_scale_src0/src1). For E8M0 (or identity fallback)
    // mant_corr == 128, so even if engaged the correction is an exact no-op;
    // gating on SCALE_E4M3 keeps intent explicit and avoids needless switching.
    // The leaf is combinational and gated inside vec_lane_array to LANE_ADD/SUB,
    // so non-RESADD lane ops are unaffected regardless of this signal.
    // =========================================================================
    logic e4m3_precise_lane;
    assign e4m3_precise_lane = ctrl_q.scale_adapt_en
                             && (ctrl_q.scale_format == SCALE_E4M3)
                             && ctrl_q.lane_en
                             && (ctrl_q.lane_op == LANE_ADD || ctrl_q.lane_op == LANE_SUB);

    // =========================================================================
    // [C5 2026-07-24] PH_MC — precise-correction front, one stage EARLY
    //
    // The very same `vec_lane_prep` leaf that vec_lane_array instantiates
    // internally (single source of truth — see vec_lane_array.sv bottom) is run
    // here on src*_elems, and its output is REGISTERED into src*_lane_q during
    // PH_MC. The lane array is then fed the already-corrected operands with
    // e4m3_precise_i tied 0, which is BIT-IDENTICAL for every lane_op:
    //   · the caller already gates e4m3_precise_lane on lane_op ∈ {ADD,SUB}
    //     (:809-812 below), and vec_lane_array only consumes the correction in
    //     that same branch — so for every other op es == src by construction;
    //   · for ADD/SUB the array's own prep becomes the identity (precise=0), so
    //     it sees exactly the operands its internal prep would have produced.
    // Net effect = the operand select + mant_corr multiply move out of the lane
    // add chain's clock period. Value-preserving, latency-only (+1 phase/pass).
    // =========================================================================
    vec_elem_t src0_prep [VEC_LANES];
    vec_elem_t src1_prep [VEC_LANES];

    // [MC2F] prep now consumes the PH_SEL-REGISTERED seam exclusively: the
    // selected operands (src*_sel_q) AND the correction controls
    // (mc2f_corr_*/mc2f_precise_q — the §0.4 bypass leg; round_rne_i is a
    // constant and needs no register). The PH_MC multiply cone therefore
    // launches from flops only — no live select/scale-decode leg remains
    // (struct gate: -from {pass_idx_q, cap_q, loaded_q, ctrl_q} must be dead).
    generate
        for (genvar gp = 0; gp < VEC_LANES; gp++) begin : gen_lane_prep
            vec_lane_prep u_prep_s0 (
                .src_i          ( src0_sel_q[gp]               ),  // [MC2F] registered PH_SEL output
                .e4m3_precise_i ( mc2f_precise_q               ),  // [MC2F]
                .mant_corr_i    ( mc2f_corr_s0_q               ),  // [MC2F]
                .round_rne_i    ( 1'b1 ),  // RNE for the scale-correction multiply
                .es_o           ( src0_prep[gp]                )
            );
            vec_lane_prep u_prep_s1 (
                .src_i          ( src1_sel_q[gp]               ),  // [MC2F]
                .e4m3_precise_i ( mc2f_precise_q               ),  // [MC2F]
                .mant_corr_i    ( mc2f_corr_s1_q               ),  // [MC2F]
                .round_rne_i    ( 1'b1 ),
                .es_o           ( src1_prep[gp]                )
            );
        end
    endgenerate

    // =========================================================================
    // [LANE2 2026-07-26] PH_LANE — alignment front, one phase EARLY
    //
    // The very same `vec_lane_align` leaf that vec_lane_addsub instantiates in
    // its standalone contract (single source of truth — see vec_lane_array.sv
    // bottom) is run here on the REGISTERED operands + shift controls, and its
    // output is REGISTERED into lane_align_q/lane_sticky_q during PH_LANE. The
    // lane array (ALIGN_INTERNAL=0 below) then runs the arithmetic BACK half
    // in PH_LANE2 from the seam. Inputs are BY CONSTRUCTION the ones the
    // array-internal leaf would consume: src0_i==src0_lane_q passes through
    // untouched (PRECISE_INTERNAL=0), eff_src1==mc_eff_s1_q (ext valid tied),
    // ctrl=={mc_shift_src1_q, mc_abs_diff_q} (ext valid tied). Value-
    // preserving, latency-only (+1 phase/pass).
    // =========================================================================
    generate
        for (genvar ga = 0; ga < VEC_LANES; ga++) begin : gen_ph_align
            vec_lane_align u_ph_align (
                .es0_mant_i      ( src0_lane_q[ga].mant ),
                .eff_src1_mant_i ( mc_eff_s1_q[ga]      ),
                .shift_src1_i    ( mc_shift_src1_q[ga]  ),
                .abs_diff_i      ( mc_abs_diff_q[ga]    ),
                .shift_out_o     ( lane_align_d[ga]     ),
                .sticky_o        ( lane_sticky_d[ga]    )
            );
        end
    endgenerate

    vec_lane_array #(
        .PRECISE_INTERNAL ( 1'b0 ),  // [C5] correction applied in PH_MC above;
                                     // drops the 32 now-dead in-array multipliers
        .ALIGN_INTERNAL   ( 1'b0 )   // [LANE2] alignment applied in PH_LANE above;
                                     // the arm consumes the registered seam
    ) u_lane_array (
        .src0_i              ( src0_lane_q        ),  // [C5] registered PH_MC output
        .src1_i              ( src1_lane_q        ),  // [C5]
        .lane_op_i           ( ctrl_q.lane_op     ),
        .valid_i             ( pipe_active && ctrl_q.lane_en ),
        .e4m3_precise_i      ( 1'b0               ),  // [C5] correction already applied
        .mant_corr_s0_i      ( 8'd128             ),  // [C5] identity (dead under precise=0)
        .mant_corr_s1_i      ( 8'd128             ),  // [C5]
        .precise_round_rne_i ( 1'b1 ),
        .ext_shift_ctrl_valid_i ( 1'b1            ),  // [C9] PH_MC-registered controls
        .ext_abs_diff_i      ( mc_abs_diff_q      ),  // [C9]
        .ext_shift_src1_i    ( mc_shift_src1_q    ),  // [C9]
        .ext_src1_neg_valid_i ( 1'b1              ),  // [T1b] PH_MC-registered negate
        .ext_eff_src1_mant_i ( mc_eff_s1_q        ),  // [T1b]
        .ext_shift_out_i     ( lane_align_q       ),  // [LANE2] PH_LANE-registered seam
        .ext_shift_sticky_i  ( lane_sticky_q      ),  // [LANE2]
        .result_o            ( lane_results       ),
        .valid_o             ( lane_valid         )
    );

    // =========================================================================
    // Reduce Cluster + Multi-Pass Partial Accumulation
    // =========================================================================
    vec_reduce_result_t reduce_result;       // current pass result
    vec_reduce_result_t partial_reduce_q;    // latched pass-0 partial
    // In REDUCE_STAT mode, partial_reduce_q is retained only for NaN/Inf
    // status carry; mant/exp combine uses partial_stat_* + stat_raw_* path
    // through combine_reduce_stat_40b_to_reduce() (Round 3b decision #5).

    // CL-5: raw STAT window sum of the current pass (S-STAT v1.2 S9)
    logic [REDUCE_STAT_W-1:0]        reduce_stat_raw_mant;
    logic signed [STAT_EXP_W-1:0]    reduce_stat_raw_exp;

    vec_reduce_cluster u_reduce (
        .lane_results_i  ( lane_results_q        ),  // [VEC-PIPE ⑥] registered LANE-phase source
        .mode_i          ( ctrl_q.reduce_mode    ),
        .valid_i         ( lane_valid_q3 && ctrl_q.reduce_en ),  // [C8-b][C9-b] REDUCE-phase token
        .result_o        ( reduce_result         ),
        .stat_raw_mant_o ( reduce_stat_raw_mant  ),  // CL-5
        .stat_raw_exp_o  ( reduce_stat_raw_exp   )   // CL-5
    );

    // Multi-pass reduce combine (for block32: combine pass-0 partial + pass-1)
    vec_reduce_result_t combined_reduce;

    // =========================================================================
    // v6.0 Round 3b (Bug #3 fix): Cross-pass REDUCE_STAT combine at full
    // 40-bit precision.
    //
    // Closes CL-5 by actually USING partial_stat_mant_q / partial_stat_exp_q.
    // The pre-v6 code wrote these registers every pass-0 but never read
    // them on pass-1 — cross-pass STAT combine went through the 21-bit
    // partial_reduce_q path, defeating the 40-bit tree benefit at the
    // block-level boundary.
    //
    // [S-STAT v1.2, prereg §70 + §74.1.2] body replaced (待-2, F2 / F4 / F5 / F6):
    //   inputs are the two per-pass raw window sums (rm, re): rm unsigned,
    //   bit39-normalized or 0; re 12-bit signed. The larger-exponent side is
    //   `big`; the other (`sml`) is shifted right by min(|d|, 41) with the
    //   shifted-out bits kept as a sticky; z = big + (sml >> sh) is EXACT in 41 bits
    //   (z[40] | z[39] = 1), and vec_stat_shape rounds it ONCE (RNE, 20-bit
    //   significand, O-IB Inf/NaN, flush-to-zero) — the same shaping function
    //   vec_reduce_cluster uses per pass, so block16 and block32 obey one rule.
    //   A pass whose raw mant is 0 contributes nothing (zero is an identity).
    //
    // NaN/Inf: aggregated from the scalar flags parameters. This sidesteps
    // the need to add new ports to vec_reduce_cluster (per Round 3b
    // decision #5 — partial_reduce_q retained purely for its is_nan/is_inf
    // carry). partial_reduce_q.is_inf also carries a pass-0 overflow; ORing
    // it is safe because partial sums are non-negative and RNE is monotone.
    //
    // Parameter types (MAJOR-2): mant ports are UNSIGNED (a signed 40-bit
    // port would sign-extend bit39 into z[40]), exp ports are STAT_EXP_W.
    // =========================================================================
    function automatic vec_reduce_result_t combine_reduce_stat_40b_to_reduce(
        input logic [REDUCE_STAT_W-1:0]        partial_mant,
        input logic signed [STAT_EXP_W-1:0]    partial_exp,
        input logic [REDUCE_STAT_W-1:0]        current_mant,
        input logic signed [STAT_EXP_W-1:0]    current_exp,
        input logic                            partial_nan,
        input logic                            partial_inf,
        input logic                            current_nan,
        input logic                            current_inf,
        input logic                            both_valid
    );
        vec_reduce_result_t            result;
        logic [REDUCE_STAT_W-1:0]      big, sml;   // not 'small': a Verilog charge-strength keyword
        logic [STAT_Z_W-1:0]           z;
        logic signed [STAT_EXP_W-1:0]  y;
        logic signed [12:0]            d;
        logic [5:0]                    sh;
        logic                          nz_p, nz_c, st;

        nz_p = partial_mant[REDUCE_STAT_W-1];
        nz_c = current_mant[REDUCE_STAT_W-1];
        d    = 13'(partial_exp) - 13'(current_exp);                       // signed, |d| <= 2081
        if (d >= 13'sd0) begin
            big = partial_mant; sml = current_mant; y = partial_exp;
            sh  = (d  > 13'sd41) ? 6'd41 : 6'(d);
        end else begin
            big = current_mant; sml = partial_mant; y = current_exp;
            sh  = (-d > 13'sd41) ? 6'd41 : 6'(-d);
        end
        st = |(sml & ~({REDUCE_STAT_W{1'b1}} << sh));                   // sh >= 40 ⇒ all-ones mask
        case ({nz_p, nz_c})
            2'b11:   z = STAT_Z_W'(big) + STAT_Z_W'(sml >> sh);
            2'b10:   begin z = STAT_Z_W'(partial_mant); y = partial_exp; st = 1'b0; end
            2'b01:   begin z = STAT_Z_W'(current_mant); y = current_exp; st = 1'b0; end
            default: begin z = '0;                      y = '0;          st = 1'b0; end
        endcase
        result       = vec_stat_shape(z, y, st, partial_nan | current_nan,
                                      partial_inf | current_inf);
        result.valid = both_valid;
        return result;
    endfunction

    // HW-REVIEW T2 (merge-gate): value-correct cross-pass REDUCE_MAX combine of
    // the two block32 half-maxes (was a sign-blind exp-first compare inline below).
    vec_reduce_result_t rmax_combined;
    vec_reduce_max_combine u_rmax (
        .a_i ( partial_reduce_q ),
        .b_i ( reduce_result    ),
        .y_o ( rmax_combined    )
    );

    always_comb begin
        if (num_passes_q == 2'd1 || pass_idx_q == 2'd0) begin
            // Single pass or first pass: use current result directly.
            // (For pass 0 in block32, combined_reduce is ignored — the
            //  FSM latches partial_reduce_q / partial_stat_*_q and never
            //  reads combined_reduce until pass 1.)
            combined_reduce = reduce_result;
        end else if (ctrl_q.reduce_mode == REDUCE_STAT) begin
            // v6.0 Round 3b (Bug #3): cross-pass REDUCE_STAT goes through
            // the 40-bit helper. Uses partial_stat_*_q for pass-0 mant/exp
            // at full precision; NaN/Inf piggyback on partial_reduce_q
            // because the stat_raw_* ports don't carry those flags (see
            // Round 3b decision #5 — vec_reduce_cluster is not modified).
            combined_reduce = combine_reduce_stat_40b_to_reduce(
                .partial_mant (partial_stat_mant_q),
                .partial_exp  (partial_stat_exp_q),
                .current_mant (reduce_stat_raw_mant),
                .current_exp  (reduce_stat_raw_exp),
                .partial_nan  (partial_reduce_q.is_nan),
                .partial_inf  (partial_reduce_q.is_inf),
                .current_nan  (reduce_result.is_nan),
                .current_inf  (reduce_result.is_inf),
                .both_valid   (partial_reduce_q.valid & reduce_result.valid)
            );
        end else begin
            // Second pass, REDUCE_MAX or REDUCE_SUM: 21-bit combine
            // (unchanged from pre-v6 — STAT was incorrectly sharing this
            //  path, which was the Bug #3 root cause).
            combined_reduce.is_nan = partial_reduce_q.is_nan | reduce_result.is_nan;
            combined_reduce.is_inf = partial_reduce_q.is_inf | reduce_result.is_inf;
            combined_reduce.valid  = partial_reduce_q.valid  & reduce_result.valid;

            if (ctrl_q.reduce_mode == REDUCE_MAX) begin
                // HW-REVIEW T2 (merge-gate): value-correct max combine. The old
                // exp-first compare here was SIGN-BLIND (a high-exp negative half
                // beat a low-exp positive half) — the same defect fixed in
                // pair_max/LANE_MAX, missed at this third site. vec_reduce_max_combine
                // aligns the lower-exp half then signed-compares.
                combined_reduce.mant = rmax_combined.mant;
                combined_reduce.exp  = rmax_combined.exp;
            end else begin
                // REDUCE_SUM: aligned addition of two partial sums at 21-bit
                // width. Shift clamp to REDUCE_W (21) is sufficient here
                // because summands are 21-bit accumulators and shifts
                // beyond that annihilate the operand.
                logic signed [VEC_EXP_W-1:0] ediff;
                logic [5:0] abs_ediff_clamped;
                ediff = partial_reduce_q.exp - reduce_result.exp;

                if (ediff >= VEC_EXP_W'(0))
                    abs_ediff_clamped = (ediff > VEC_EXP_W'(REDUCE_W))
                                      ? 6'(REDUCE_W) : 6'(ediff);
                else
                    abs_ediff_clamped = (-ediff > VEC_EXP_W'(REDUCE_W))
                                      ? 6'(REDUCE_W) : 6'(-ediff);

                if (ediff >= VEC_EXP_W'(0)) begin
                    combined_reduce.exp  = partial_reduce_q.exp;
                    combined_reduce.mant = partial_reduce_q.mant
                                         + (reduce_result.mant >>> abs_ediff_clamped);
                end else begin
                    combined_reduce.exp  = reduce_result.exp;
                    combined_reduce.mant = (partial_reduce_q.mant >>> abs_ediff_clamped)
                                         + reduce_result.mant;
                end
            end
        end
    end

    // =========================================================================
    // Renorm / Quant Engine + Multi-Pass Max Exp Combine
    // =========================================================================
    vec_renorm_result_t renorm_result;               // current pass (live, PH_RENORM cycle)
    // [C8-b] registered at the PH_RENORM boundary; every PH_REDUCE consumer
    // (global combine / xpass win1 / effective_renorm / partial_* latches)
    // reads this copy. lane_results_q + ctrl_q + adapted_scale_src0 are HELD
    // across PH_RENORM→PH_REDUCE, so the registered value equals the live one
    // the old single-cycle phase consumed (pure retiming).
    vec_renorm_result_t renorm_result_q;
    logic signed [VEC_EXP_W-1:0] partial_max_exp_q;  // pass-0 max_exp
    logic        partial_escape_q;                    // pass-0 escape flag

    // [C9-b] the renorm engine is now instantiated as its two halves with a
    // register boundary between them (front/back split, vec_renorm_quant.sv):
    //   PH_RENORM : u_renorm_front runs the max/min-exp tree on the
    //               REGISTERED lane_results_q -> rn_front_*_q (24 DFF);
    //   PH_RENORM2: u_renorm_back runs escape/re-align/pack from the
    //               REGISTERED front outputs + the HELD lane_results_q/ctrl_q
    //               -> renorm_result, captured into renorm_result_q.
    // Value-preserving: lane_results_q, ctrl_q and adapted_scale_src0 are all
    // HELD across PH_RENORM->PH_RENORM2->PH_REDUCE, and the composed wrapper
    // (front+back combinational) is bit-identical to the pre-split module —
    // registering the 6-signal boundary is a pure retime of the same values.
    logic signed [VEC_EXP_W-1:0] rn_front_max_q, rn_front_min_q;
    logic rn_front_normal_q, rn_front_nan_q, rn_front_inf_q, rn_front_ovf_q;
    logic signed [VEC_EXP_W-1:0] rn_front_max, rn_front_min;
    logic rn_front_normal, rn_front_nan, rn_front_inf, rn_front_ovf;

    vec_renorm_front u_renorm_front (
        .lane_results_i ( lane_results_q  ),  // [VEC-PIPE ⑥] registered LANE-phase source
        .ctrl_i         ( ctrl_q          ),
        .max_exp_o      ( rn_front_max    ),
        .min_exp_o      ( rn_front_min    ),
        .any_normal_o   ( rn_front_normal ),
        .any_nan_o      ( rn_front_nan    ),
        .any_inf_o      ( rn_front_inf    ),
        .any_overflow_o ( rn_front_ovf    )
    );

    vec_renorm_back u_renorm_back (
        .lane_results_i ( lane_results_q     ),  // HELD across the split
        .ctrl_i         ( ctrl_q             ),
        .valid_i        ( lane_valid_q2 && ctrl_q.renorm_en ),  // [C9-b] RENORM2-phase token
        .orig_scale_i   ( adapted_scale_src0 ),  // CL-6
        .max_exp_i      ( rn_front_max_q     ),  // [C9-b] PH_RENORM-registered
        .min_exp_i      ( rn_front_min_q     ),
        .any_normal_i   ( rn_front_normal_q  ),
        .any_nan_i      ( rn_front_nan_q     ),
        .any_inf_i      ( rn_front_inf_q     ),
        .any_overflow_i ( rn_front_ovf_q     ),
        .result_o       ( renorm_result      )
    );

    // Global max_exp for multi-pass renorm (computed in vector_unit, not renorm module)
    logic signed [VEC_EXP_W-1:0] global_max_exp;
    logic global_escape_needed;

    always_comb begin
        // [C8-b] all PH_REDUCE consumers read the REGISTERED renorm_result_q.
        if (num_passes_q == 2'd1 || pass_idx_q == 2'd0) begin
            global_max_exp      = renorm_result_q.new_scale.exp_adj;
            global_escape_needed = renorm_result_q.escape_needed;
        end else begin
            // Combine: larger of pass-0 and pass-1 max_exp
            global_max_exp = (partial_max_exp_q > renorm_result_q.new_scale.exp_adj)
                           ? partial_max_exp_q : renorm_result_q.new_scale.exp_adj;
            global_escape_needed = partial_escape_q | renorm_result_q.escape_needed;
        end
    end

    // For multi-pass renorm: each pass is locally aligned by vec_renorm_quant,
    // then vec_renorm_xpass re-aligns BOTH windows to global_max_exp (toward
    // zero) before egress — so the capsule's single shared exponent matches the
    // mantissas of both windows. (HW-REVIEW T2: previously the lower-exp window
    // was relabeled at global without re-shift → 2^|ΔE| silent inflation.)
    logic [BS_CAP_PAYLOAD_W-1:0] partial_packed_mant_q;  // pass-0 packed mants

    // HW-REVIEW T2: cross-pass re-alignment. Pass-0 (partial_packed_mant_q) is
    // aligned to its LOCAL max partial_max_exp_q; pass-1 (renorm_result) to its
    // local renorm_result.new_scale.exp_adj. Both are emitted under global_max_exp,
    // so the lower-exp window MUST be re-shifted toward zero by (global - local)
    // or it is silently inflated by 2^|ΔE|. vec_renorm_xpass does both re-shifts
    // (the higher-exp window's delta is 0). Replaces the old relabel-without-reshift.
    logic [2*BS_CAP_PAYLOAD_W-1:0] xpass_packed;
    vec_renorm_xpass u_xpass (
        .win0_i       ( partial_packed_mant_q                            ),
        .exp0_i       ( partial_max_exp_q                                ),
        .win1_i       ( renorm_result_q.packed_mant[BS_CAP_PAYLOAD_W-1:0] ),  // [C8-b] registered
        .exp1_i       ( renorm_result_q.new_scale.exp_adj                ),  // [C8-b] registered
        .global_exp_i ( global_max_exp                                   ),
        .packed_o     ( xpass_packed                                     )
    );

    // =========================================================================
    // Result Packer (with scale passthrough ports, B3 fix)
    //
    // CL-3: Block32 dual-capsule egress mechanism.
    //   A block32 result contains 32 elements but a capsule holds only 16.
    //   For non-reduce block32 paths, the FSM outputs TWO capsules sequentially:
    //     egress_window_q=0: elements [0:15]  (pass-0 data)
    //     egress_window_q=1: elements [16:31] (pass-1 data)
    //   For reduce paths: single scalar capsule, skip windowed egress.
    //   For block16: single capsule, skip windowed egress.
    // =========================================================================
    bs_capsule_t    result_capsule;
    logic           result_valid;
    logic           result_escape_needed;

    // CL-3: Egress window counter for block32 dual-capsule output
    //   Only active when block32 AND non-reduce path.
    logic        block32_dual_egress;
    // v6.0 Round 3b (Bug #6 clarification): egress_window_q is the CURRENT
    // egress window selector (not "completed count", not "next to process").
    //   egress_window_q == 0 → rw_row = dst_ref + 0, emitting window 0
    //   egress_window_q == 1 → rw_row = dst_ref + 1, emitting window 1
    // Advances ONLY when the current window has been successfully emitted:
    //   - VST_ACTIVE + fp_egr_accepted  → advance same-cycle (fast path
    //                                     consumes window 0 → proceed to
    //                                     window 1 next ACTIVE cycle)
    //   - VST_L2_WB  + rw_gnt_i         → advance when the L2 write of
    //                                     the current window is accepted
    // NEVER advances on entry-to-L2_WB. Pre-v6 code did, causing window 0
    // data to be written at dst_ref+1 and window 1 to be skipped entirely.
    logic        egress_window_q;         // 0 = current window 0, 1 = current window 1
    logic        egress_both_done;        // both windows egressed

    assign block32_dual_egress = (num_passes_q == 2'd2) && !ctrl_q.reduce_en;
    assign egress_both_done    = !block32_dual_egress || (egress_window_q == 1'b1);

    // For multi-pass: override renorm result with combined values
    vec_renorm_result_t effective_renorm;

    always_comb begin
        effective_renorm = renorm_result_q;   // [C8-b] registered PH_RENORM output
        // [C8-b] QUALIFY the registered valid with the REDUCE-phase token —
        // the C6-review V2 lesson: a registered valid HOLDS after its
        // consumption cycle (renorm_result_q.valid stays 1 through the next
        // pass's PH_MC/PH_LANE and re-fires the packer's renorm branch,
        // tripping the ⑥ result_valid|->PH_REDUCE tripwire — caught by
        // test_vec_resadd_stream on first run). lane_valid_q2 is the piped
        // token: 1 exactly in the PH_REDUCE cycle this result belongs to.
        effective_renorm.valid = renorm_result_q.valid & lane_valid_q3;   // [C9-b]
        if (num_passes_q == 2'd2 && pass_idx_q == 2'd1 && ctrl_q.renorm_en) begin
            // Final compute pass: inject global max_exp and combine packed mants.
            // HW-REVIEW T2: both windows come from vec_renorm_xpass already
            // re-aligned to global_max_exp (toward-zero), so neither is inflated.
            effective_renorm.new_scale.exp_adj = global_max_exp;
            effective_renorm.escape_needed     = global_escape_needed;
            effective_renorm.packed_mant[2*BS_CAP_PAYLOAD_W-1:0] = xpass_packed;
        end

        // CL-3: Window selection for dual-capsule egress.
        //   When egress_window_q=1, shift the high 256 bits down to low position
        //   so the result_packer (which always takes [BS_CAP_PAYLOAD_W-1:0]) gets
        //   the second half of the block.
        if (block32_dual_egress && egress_window_q && ctrl_q.renorm_en) begin
            effective_renorm.packed_mant[BS_CAP_PAYLOAD_W-1:0]
                = effective_renorm.packed_mant[2*BS_CAP_PAYLOAD_W-1:BS_CAP_PAYLOAD_W];
        end
    end

    // =========================================================================
    // v6.0 Round 3b (Bug #4 fix): Effective lane results selector for
    // lane-only block32 dual-capsule egress.
    //
    // Problem fixed:
    //   active_src0_cap / active_src1_cap use pass_idx_q for window
    //   selection. By last_pass (pass_idx_q == 1), lane_results carries
    //   pass-1 element data. Without this selector, BOTH dual-capsule
    //   windows would emit pass-1 data, losing elements [0:15] entirely.
    //
    // Selection logic (all four predicates explicit per Round 3b decision #3):
    //   block32_dual_egress    : only engage during dual-capsule egress
    //   egress_window_q == 0   : only for the first window
    //   !ctrl_q.reduce_en      : reduce path outputs scalar, orthogonal
    //                            to dual egress (per CL-3 design)
    //   !ctrl_q.renorm_en      : renorm path uses its own combine via
    //                            effective_renorm (packed_mant window shift)
    //   partial_lane_valid_q   : the pass-0 snapshot is populated
    //
    // When engaged → result_packer sees pass-0 lane results (correct data
    //                for output elements [0:15] of the block)
    // Otherwise     → result_packer sees live lane_results (reduce path,
    //                renorm path, block16 single-pass, or block32 window 1)
    // =========================================================================
    vec_lane_result_t effective_lane_results [VEC_LANES];
    always_comb begin
        if (block32_dual_egress
            && (egress_window_q == 1'b0)
            && !ctrl_q.reduce_en
            && !ctrl_q.renorm_en
            && partial_lane_valid_q) begin
            effective_lane_results = partial_lane_results_q;
        end else begin
            effective_lane_results = lane_results_q;  // [VEC-PIPE ⑥]
        end
    end

    // For multi-pass reduce: use combined result on final pass
    vec_reduce_result_t effective_reduce;
    assign effective_reduce = (num_passes_q == 2'd2 && pass_idx_q == 2'd1)
                            ? combined_reduce : reduce_result;

    vec_result_packer u_result_packer (
        .lane_results_i            ( effective_lane_results      ),  // v6.0 R3b
        .lane_valid_i              ( lane_valid_q3               ),  // [VEC-PIPE ⑥][C8-b][C9-b] REDUCE-phase token
        .reduce_result_i           ( effective_reduce            ),
        .renorm_result_i           ( effective_renorm            ),
        .ctrl_i                    ( ctrl_q                      ),
        .src_scale_ref_i           ( active_src0_cap.scale_ref   ),
        .src0_inline_scale_i       ( active_src0_cap.inline_scale       ),  // B3 fix
        .src0_scale_inline_valid_i ( active_src0_cap.scale_inline_valid ),  // B3 fix
        .capsule_o                 ( result_capsule              ),
        .valid_o                   ( result_valid                ),
        .escape_needed_o           ( result_escape_needed        )
    );

    // =========================================================================
    // Fast Path Egress Connection (CL-3: block32 dual-capsule aware)
    //
    // For block32 non-reduce: egress fires on each window (2 cycles).
    // For block16 or reduce: single egress on last_pass.
    // =========================================================================
    logic last_pass;
    assign last_pass = (pass_idx_q == num_passes_q - 2'd1);

    // CL-3: egress is valid when:
    //   - Pipeline is active, compute passes done (last_pass=1), result is valid
    //   - For single-capsule: always valid on last_pass
    //   - For dual-capsule (block32 non-reduce): valid on each egress window
    assign fp_egr_valid = pipe_active && last_pass && result_valid;
    assign fp_egr_cap   = result_capsule;

    // =========================================================================
    // [C-MX STORE ⑦] Compact-MX L2-store — decode + 16x requantizer bank
    //
    // An OP_VEC_STORE (VEC_UNPACK) whose descriptor carries a block-scaled
    // elem_fmt (MXFP4/MXFP8 — MXINT8 is NOT supported and falls back to the
    // legacy full-payload store) writes the REQUANTIZED narrow encoding to L2
    // instead of the 256b internal capsule payload:
    //   MXFP4: 16 x FP4 E2M1  =  64b payload / window (bank mask 16'h0003)
    //   MXFP8: 16 x FP8 E4M3FN = 128b payload / window (bank mask 16'h000F)
    // plus a per-window block scale written into an L2 scale-sidecar row via a
    // read-modify-write (VST_SCRD -> VST_SCWB, mask 16'hFFFF).
    //
    // Scale-sidecar wire format (vector_unit-local convention; the pe_pkg-level
    // doc/helper lands with the next pe_pkg batch — pe_pkg is frozen while the
    // ASAP7 Tensor P&R make is running):
    //   E4M3 (NVFP4, block16): 16b signed UNCLAMPED ref_exp lanes, 16 per 256b
    //     row (FF3a-compatible: pe_pkg::sidecar_scale_k reads it back):
    //       row  = sidecar_base + (k >> 4);  bits = [16*(k & 4'hF) +: 16]
    //   E8M0 (block32, per-16-element scale; not an OCP MX 32-element block): 8b byte = ref_exp + 127, DENSE 32 per 256b row:
    //       row  = sidecar_base + (k >> 5);  bits = [8*(k & 5'h1F) +: 8]
    //   k = index of this command's w-th 16-element sub-block (STORE is
    //   non-streaming: block_count=1, blk_idx_q=0 -> k = egress window w).
    //
    // Numeric semantics == Model/bfp_golden.py requantize_block_golden(cells,
    // 4/8, 'FP', OUT_ROUND_RNE, scale_format) with cell value = lane16 x
    // 2^blk_exp (blk_exp = the SANCTIONED capsule scale decode below): each
    // lane's 17b |mant| (17b to survive -32768) feeds a D9 requantizer leaf
    // (kind_fp=1, RNE); shared_exp self-normalizes as the max eff_o over
    // nonzero lanes (same structure as tensor_result_packer); FP ref_exp =
    // shared_exp. An ALL-ZERO window matches the golden all_zero branch:
    // payload 0 and scale 0 (E8M0 byte 0x00 / E4M3 ref 0x0000).
    //
    // Capsule scale contract ([C-MX ⑦] review F2): blk_exp is decoded per the
    // matrix below, mirroring vec_scale_adapter (:76-120) / bfp_golden
    // abs_scale_decode — NOT a bare read of scale_ref (real E8M0 producers,
    // tensor_result_packer :181-186 / vec_result_packer, carry the exponent in
    // the inline BYTE with bit8=0 and scale_ref=0):
    //   scale_inline_valid=0          -> identity 2^0 (adapter legal fallback)
    //   inline_scale[8]=1 (abs codec) -> saturate12(signed scale_ref)
    //       (E4M3 abs with byte[2:0]!=0 -> mant_corr!=1.0, not a power of 2
    //        -> FALLBACK)
    //   inline_scale[8]=0 && E8M0     -> byte - 127 (byte 0xFF = NaN scale
    //        -> FALLBACK; unreachable via the cmd path — scale_any_error
    //        pre-empts to VST_ERROR — kept as belt-and-braces)
    //   inline_scale[8]=0 && E4M3     -> FALLBACK (clamped 4b byte exponent +
    //        possible mantissa bits: not losslessly a power of 2)
    // FALLBACK = compact_wb_q not latched -> the store degrades LOSSLESSLY to
    // the legacy full-mask 256b payload write with NO sidecar write. Loud/
    // lossless over silently mis-scaled.
    //
    // Block-fragment invariant ([C-MX ⑦] review F3): a block32 store's two
    // SRC0 capsules must carry ONE block scale ("一块一指数" — the
    // vec_result_packer passthrough tags BOTH windows with the pass-1
    // capsule's metadata via active_src0_cap, see its pass_idx_q mux). If the
    // two fragments decode to different {ok, exp}, the whole store falls back.
    //
    // Lossiness ([C-MX ⑦] review F5): compact narrowing is the MX format's
    // INHERENT lossy quantization — a lane underflowing to elem 0 is correct
    // output (golden's `escape` flag is informational and deliberately NOT
    // consumed; the 16 underflow_o ports below are left unconnected on
    // purpose). result_escape_needed in the compact_wb_q predicate is a
    // defensive guard only — structurally 0 for a STORE (renorm_en=0).
    //
    // Sidecar RMW atomicity ([C-MX ⑦] review F4 — USAGE CONSTRAINT): the RMW
    // is snapshot(VST_SCRD) -> merge -> full-row write-back(VST_SCWB), NOT
    // atomic. Another L2 master (DMA fill / a second producer) writing the
    // same sidecar row between the snapshot and the write-back loses its
    // update. Software must treat a sidecar row as SINGLE-PRODUCER while a
    // compact store targeting it is in flight (same unprotected-concurrency
    // contract as raw DMA fill).
    // =========================================================================
    logic compact_fmt_fp4, compact_fmt_fp8, compact_fmt_ok, compact_scale_e4m3;
    assign compact_fmt_fp4    = (ctrl_q.elem_fmt == ELEM_MXFP4);
    assign compact_fmt_fp8    = (ctrl_q.elem_fmt == ELEM_MXFP8);
    // Store (VEC_UNPACK) only — defense-in-depth for directly-driven descriptors
    // that tag another primitive block-scaled. MXINT8 excluded (not decoded).
    assign compact_fmt_ok     = (compact_fmt_fp4 | compact_fmt_fp8)
                              && (ctrl_q.prim_id == VEC_UNPACK);
    assign compact_scale_e4m3 = (ctrl_q.scale_format == SCALE_E4M3);   // NVFP4 flavor

    localparam int CMX_EXP_W = 12;   // requantizer EXP_W (M37-style widened)

    // ── [C-MX ⑦ F2] sanctioned per-capsule block-scale decode ──
    // Returns {ok, exp12}. ok=0 => the scale is not a losslessly-representable
    // power of 2 under this flavor => the store must FALL BACK to the legacy
    // full-payload write. Saturation (not wrap) into the 12b requantizer
    // exponent domain follows the vec_scale_adapter abs-path policy.
    function automatic logic [CMX_EXP_W:0] cmx_scale_decode(
        input bs_capsule_t cap,
        input logic        e4m3
    );
        logic                        ok;
        logic signed [CMX_EXP_W-1:0] e;
        ok = 1'b0;
        e  = '0;
        if (!cap.scale_inline_valid) begin
            ok = 1'b1;                                   // identity 2^0
        end else if (cap.inline_scale[BS_ABS_EXP_BIT]) begin
            if (e4m3 && cap.inline_scale[2:0] != 3'b000) begin
                ok = 1'b0;                               // (1+m/8)x2^e: non-pow2
            end else begin
                ok = 1'b1;                               // abs codec: signed scale_ref
                if      ($signed(cap.scale_ref) >  16'sd2047) e = 12'sd2047;
                else if ($signed(cap.scale_ref) < -16'sd2048) e = -12'sd2048;
                else    e = CMX_EXP_W'($signed(cap.scale_ref));
            end
        end else if (!e4m3) begin
            if (cap.inline_scale[7:0] == 8'hFF) begin
                ok = 1'b0;                               // NaN scale byte
            end else begin
                ok = 1'b1;                               // legacy E8M0 byte carrier
                e  = CMX_EXP_W'({4'd0, cap.inline_scale[7:0]}) - 12'sd127;
            end
        end else begin
            ok = 1'b0;    // byte-carried E4M3: clamped/possibly-fractional
        end
        return {ok, e};
    endfunction

    // [C-MX ⑦ F8] Requantizer source = the REGISTERED result_cap_q, always.
    // The bank's outputs are consumed ONLY in VST_CMX_PREP (one cycle after
    // the ACTIVE latch, when result_cap_q is valid), where they are registered
    // into compact_payload_q / compact_scale_q. The pre-F8 live/registered mux
    // (result_capsule when pipe_active) stacked the requantizer cone on top of
    // the full vec datapath cone into compact_scale_q — post-route measured
    // 108.8ns single-cycle at a 70ns signoff clock (WNS -37ns, 216 endpoints,
    // repair blew area 1.58->2.34mm2). Now the cone is result_cap_q -> PREP
    // registers and owns a full period.

    // [C-MX ⑦ F2/F3] decoded block scales:
    //   cmx_dec_cap    — from the registered result_cap_q: drives the
    //                    requantizer cell exponent in VST_CMX_PREP;
    //   cmx_dec_active — from active_src0_cap (a mux of registered capsules):
    //                    the compact_wb_q latch gate at the ACTIVE latch cycle
    //                    (the result packer passes this capsule's scale
    //                    metadata through verbatim, so cmx_dec_cap equals it
    //                    one cycle later by construction);
    //   cmx_dec_s0a/b  — both block32 SRC0 fragments (one-scale-per-block
    //                    invariant check).
    logic [CMX_EXP_W:0]          cmx_dec_cap, cmx_dec_active, cmx_dec_s0a, cmx_dec_s0b;
    logic                        compact_scale_ok;
    logic signed [CMX_EXP_W-1:0] compact_blk_exp;
    logic                        cmx_frag_mismatch;
    assign cmx_dec_cap       = cmx_scale_decode(result_cap_q,    compact_scale_e4m3);
    assign cmx_dec_active    = cmx_scale_decode(active_src0_cap, compact_scale_e4m3);
    assign cmx_dec_s0a       = cmx_scale_decode(src0_cap_q,      compact_scale_e4m3);
    assign cmx_dec_s0b       = cmx_scale_decode(src0_cap_b_q,    compact_scale_e4m3);
    assign compact_scale_ok  = cmx_dec_active[CMX_EXP_W];
    assign compact_blk_exp   = cmx_dec_cap[CMX_EXP_W-1:0];
    // block32 only (caps_per_operand): fragments must agree on {ok, exp}
    assign cmx_frag_mismatch = caps_per_operand && (cmx_dec_s0a != cmx_dec_s0b);

    // [C-MX ⑦ F8] compact_wb_q D-value (shared by the ACTIVE latch and the
    // FSM's ACTIVE->VST_CMX_PREP routing so they can never diverge).
    logic compact_wb_d;
    assign compact_wb_d = compact_fmt_ok && compact_scale_ok
                       && !cmx_frag_mismatch && !result_escape_needed;

    logic signed [15:0]          cmx_lane [VEC_LANES];
    logic [16:0]                 cmx_abs  [VEC_LANES];   // 17b: |-32768| representable
    logic signed [CMX_EXP_W-1:0] cmx_eff  [VEC_LANES];
    logic signed [7:0]           cmx_elem [VEC_LANES];   // FP4 in [3:0] / FP8 in [7:0]
    logic [VEC_LANES-1:0]        cmx_lane_nz;

    logic signed [CMX_EXP_W-1:0] cmx_shared_exp;
    logic                        cmx_any_nz;
    // [C-MX ⑦ C3] pipeline registers: the shared-exp max (and any-nonzero) are
    // latched in VST_CMX_PREP1 and read one cycle later by the per-lane encode in
    // VST_CMX_PREP, splitting the ~6262 ps result_cap_q->compact_payload_q requant
    // bank at the max. Value-preserving: result_cap_q (latched in the prior
    // VST_ACTIVE, :2066) and ctrl_q (loaded at VST_IDLE, :1921) are HELD across
    // PREP1->PREP, so these equal the live values the old single-cycle PREP used;
    // eff_o is independent of shared_exp_i (requantizer.sv front) => no comb loop.
    logic signed [CMX_EXP_W-1:0] cmx_shared_exp_q;
    logic                        cmx_any_nz_q;

    // [C8-a 2026-07-25] the per-lane requantizer FRONT (lzc/norm/eff — all
    // shared_exp-INDEPENDENT) is ALSO registered in VST_CMX_PREP1, so the
    // VST_CMX_PREP encode cone shrinks to the BACK half only (rel_exp,
    // fp_encode, pack). Same value-preservation argument as C3: the front's
    // inputs (result_cap_q lanes + compact_blk_exp from held capsule scale)
    // are HELD across PREP1->PREP, so front(x) registered at PREP1 equals the
    // live front(x) the old PREP cone recomputed. Pressured evidence: the ⑦
    // encode arc was 2186.83 ps with front+back stacked in one cycle
    // (M2M3_AnchorPlan §C8, c8_probe_cmxlane_20260725.log).
    logic [47:0]                 cmx_norm   [VEC_LANES];  // front live (PREP1 cycle)
    logic [47:0]                 cmx_norm_q [VEC_LANES];  // registered for PREP
    logic signed [CMX_EXP_W-1:0] cmx_eff_q  [VEC_LANES];
    logic [VEC_LANES-1:0]        cmx_nz_q;

    // [T1 2026-07-26] requantizer BACK align|round/encode split. VST_CMX_PREP2
    // (between PREP1 and PREP) runs requantizer_back_align from the REGISTERED
    // norm/eff (PREP0) + shared_exp (PREP1) and lands in these registers; the
    // PREP cycle runs requantizer_back_encode from them ONLY. Same value-
    // preservation argument as C3/C8-a: every align input is HELD across
    // PREP2->PREP, so align(x) registered at PREP2 equals the live align(x)
    // the old single-cycle PREP cone computed. Signoff evidence @1670 RC
    // (t1_arcdecomp_vector_20260726.log): the stacked cone was 2175.75 ps
    // (ctrl_q start, slack -223.36 = the m1v_c9s deployed wall); the same
    // scan also caught a LIVE result_cap_q -> scale_decode -> back residual
    // (2052.81 — the "kind_fp=1 const-folds the INT path" claim is incomplete
    // under ABC logic sharing). Both die here by construction: the encode
    // instance reads registers only, and both instances' INT ifaces are tied
    // off (kind_fp_i is tied 1 -> INT arm is dead at the elem mux).
    // cmx_fp4_q: PREP0-registered format decode (ctrl_q is HELD from VST_IDLE
    // -> registered identity) — removes the live ctrl_q config-decode front
    // from the PREP1/PREP2/PREP cones.
    logic [4:0]                  cmx_al_mfield   [VEC_LANES];  // align live (PREP2 cycle)
    logic [4:0]                  cmx_al_mfield_q [VEC_LANES];  // registered for PREP
    logic [3:0]                  cmx_al_eunb     [VEC_LANES];
    logic [3:0]                  cmx_al_eunb_q   [VEC_LANES];
    logic [VEC_LANES-1:0]        cmx_al_rbit,   cmx_al_rbit_q;
    logic [VEC_LANES-1:0]        cmx_al_stick,  cmx_al_stick_q;
    logic [VEC_LANES-1:0]        cmx_al_normal, cmx_al_normal_q;
    logic                        cmx_fp4_q;

    generate
        for (genvar gi = 0; gi < VEC_LANES; gi++) begin : gen_cmx_rq
            logic signed [16:0] cmx_s17;
            assign cmx_lane[gi]    = result_cap_q.payload[gi*VEC_MANT_W +: VEC_MANT_W];
            assign cmx_s17         = {cmx_lane[gi][15], cmx_lane[gi]};   // sign-extend 16->17
            assign cmx_abs[gi]     = cmx_s17[16] ? 17'(-cmx_s17) : 17'(cmx_s17);
            assign cmx_lane_nz[gi] = (cmx_lane[gi] != 16'sd0);

            // [C8-a] FRONT — runs in the PREP1 cycle; eff_o feeds the max tree
            // (same as pre-C8), norm/eff are registered for the PREP cycle.
            requantizer_front #(
                .CELL_MANT_W ( 48        ),
                .EXP_W       ( CMX_EXP_W )
            ) u_cmx_rq_front (
                .cell_mant_i   ( {31'd0, cmx_abs[gi]} ),        // zero-extend 17->48
                // [C-MX ⑦ F2] SANCTIONED decoded block exponent (saturated,
                // no 16->12 wrap), NOT a bare scale_ref read — see the
                // capsule-scale-contract matrix above.
                .cell_exp_i    ( compact_blk_exp      ),
                .cell_is_nan_i ( 1'b0                 ),        // Vector lanes: no specials
                .cell_is_inf_i ( 1'b0                 ),
                .norm_o        ( cmx_norm[gi]         ),
                .eff_o         ( cmx_eff[gi]          ),
                .is_zero_o     (                      ),        // tree uses cmx_lane_nz
                .is_special_o  (                      )
            );

            // [T1 2026-07-26] BACK-ALIGN — runs in the PREP2 cycle from the
            // PREP0/PREP1 registers; its FP align products land in the
            // cmx_al_*_q registers below. INT iface tied off (kind_fp=1 ->
            // the INT arm is dead at the elem mux; the tie also kills the
            // measured LIVE result_cap_q/scale_decode residual at the root).
            requantizer_back_align #(
                .CELL_MANT_W ( 48        ),
                .EXP_W       ( CMX_EXP_W )
            ) u_cmx_rq_al (
                .cell_mant_i    ( '0                   ),  // INT arm unused (kind_fp=1)
                .cell_exp_i     ( '0                   ),
                .norm_i         ( cmx_norm_q[gi]       ),  // [C8-a] registered in PREP0
                .eff_i          ( cmx_eff_q[gi]        ),  // [C8-a] registered in PREP0
                .shared_exp_i   ( cmx_shared_exp_q     ),  // [C-MX ⑦ C3] registered in VST_CMX_PREP1
                .target_w_sel_i ( cmx_fp4_q ? 2'd0 : 2'd1 ),  // [T1] PREP0-registered decode
                .int_trunc_o    (                      ),  // INT arm unused
                .int_rbit_o     (                      ),
                .int_sticky_o   (                      ),
                .fp_mfield_o    ( cmx_al_mfield[gi]    ),
                .fp_rbit_o      ( cmx_al_rbit[gi]      ),
                .fp_stick_o     ( cmx_al_stick[gi]     ),
                .fp_eunb_o      ( cmx_al_eunb[gi]      ),
                .fp_normal_o    ( cmx_al_normal[gi]    )
            );

            // [C8-a][T1] BACK-ENCODE — runs in the PREP cycle from the PREP2-
            // registered align products only (cell_sign is a held result_cap_q
            // bit: 1-gate merge, no deep arc).
            requantizer_back_encode #(
                .CELL_MANT_W ( 48        ),
                .EXP_W       ( CMX_EXP_W ),
                .OUT_W       ( 8         )
            ) u_cmx_rq (
                .int_trunc_i    ( 64'd0                ),  // INT arm unused (kind_fp=1)
                .int_rbit_i     ( 1'b0                 ),
                .int_sticky_i   ( 1'b0                 ),
                .fp_mfield_i    ( cmx_al_mfield_q[gi]  ),  // [T1] registered in PREP2
                .fp_rbit_i      ( cmx_al_rbit_q[gi]    ),  // [T1] registered in PREP2
                .fp_stick_i     ( cmx_al_stick_q[gi]   ),  // [T1] registered in PREP2
                .fp_eunb_i      ( cmx_al_eunb_q[gi]    ),  // [T1] registered in PREP2
                .fp_normal_i    ( cmx_al_normal_q[gi]  ),  // [T1] registered in PREP2
                .cell_sign_i    ( cmx_lane[gi][15]     ),
                .is_zero_i      ( ~cmx_nz_q[gi]        ),  // [C8-a] registered in PREP0
                .is_special_i   ( 1'b0                 ),
                .target_w_sel_i ( cmx_fp4_q ? 2'd0 : 2'd1 ),  // [T1] PREP0-registered decode
                .kind_fp_i      ( 1'b1                 ),
                .round_rne_i    ( 1'b1                 ),
                .elem_o         ( cmx_elem[gi]         ),
                // [C-MX ⑦ F5] deliberately unconnected: underflow-to-0 is the
                // MX format's inherent lossy narrowing, not an error/escape.
                .underflow_o    (                      ),
                .zero_o         (                      ),
                .special_o      (                      ),
                .fp_todo_o      (                      )
            );
        end
    endgenerate

    // shared_exp = max eff over nonzero lanes (tensor_result_packer :86-98
    // structure; no comb loop — eff_o does not depend on shared_exp_i).
    // [C-MX ⑦ C3b] BALANCED into a 4-level pairwise (valid,eff)-combine tree.
    // The prior 16-deep LINEAR scan became the post-⑦-split stage-1 binding wall
    // (m1v_c3split: 5093 ps, masking the reduce cone). BIT-IDENTICAL: max is
    // associative + commutative, and eff=0 when neither operand is valid matches
    // the linear init (cmx_shared_exp='0 for an all-zero window). Value-preserving
    // restructure (RED-2: committed separately from the ⑦-split retiming); the
    // existing byte-exact compact tests (scale byte + payload both derive from
    // shared_exp, incl. the all-zero cases) are the guard.
    logic signed [CMX_EXP_W-1:0] mx_eff [VEC_LANES];   // in-place reduction nodes
    logic                        mx_v   [VEC_LANES];
    always_comb begin
        for (int i = 0; i < VEC_LANES; i++) begin
            // [C8-c] leaves are the PREP0-REGISTERED front outputs (was the
            // live cmx_eff/cmx_lane_nz): registered identity — same values,
            // one state later, tree freed from the select+decode+front cone.
            mx_eff[i] = cmx_eff_q[i];
            mx_v[i]   = cmx_nz_q[i];
        end
        // combine node (i) with node (i+span), halving each level: 16->8->4->2->1.
        for (int span = 1; span < VEC_LANES; span = span << 1) begin
            for (int i = 0; i + span < VEC_LANES; i = i + (span << 1)) begin
                // read mx_v[i] (old) for the eff decision, THEN update mx_v[i].
                if      (mx_v[i] && mx_v[i+span])
                    mx_eff[i] = (mx_eff[i] > mx_eff[i+span]) ? mx_eff[i] : mx_eff[i+span];
                else if (mx_v[i+span] && !mx_v[i])
                    mx_eff[i] = mx_eff[i+span];
                else if (!mx_v[i] && !mx_v[i+span])
                    mx_eff[i] = '0;
                // else (mx_v[i] && !mx_v[i+span]): keep mx_eff[i] unchanged.
                mx_v[i] = mx_v[i] | mx_v[i+span];
            end
        end
        cmx_shared_exp = mx_eff[0];
        cmx_any_nz     = mx_v[0];
    end

    // Scale encode (FP kind: ref_exp = shared_exp, tensor_result_packer :137).
    // E8M0: byte = ref_exp + 127 (wrap, packer :148); E4M3/NVFP4: the sidecar
    // carries the 16b signed UNCLAMPED ref_exp (abs codec, NOT the clamped E4M3
    // byte). All-zero window -> 0 on both flavors (golden all_zero branch).
    // [F8] Registered into compact_scale_q[egress_window_q] in VST_CMX_PREP.
    logic [15:0] compact_scale_now;
    always_comb begin
        if (!cmx_any_nz_q)                                           // [C-MX ⑦ C3] registered
            compact_scale_now = 16'd0;
        else if (compact_scale_e4m3)
            compact_scale_now = 16'($signed(cmx_shared_exp_q));      // [C-MX ⑦ C3] registered
        else
            compact_scale_now = {8'd0, 8'(cmx_shared_exp_q + 12'sd127)};  // [C-MX ⑦ C3] registered
    end

    // Compact payload — combinational from the requantizer bank (result_cap_q
    // source); [F8] registered into compact_payload_q in VST_CMX_PREP, which
    // is what VST_L2_WB drives onto rw_wdata_o (trivial port cone).
    logic [127:0] compact_payload;
    always_comb begin
        compact_payload = '0;
        if (cmx_fp4_q) begin    // [T1] PREP0-registered decode (ctrl_q held)
            for (int i = 0; i < VEC_LANES; i++)
                compact_payload[i*4 +: 4] = cmx_elem[i][3:0];
        end else begin
            for (int i = 0; i < VEC_LANES; i++)
                compact_payload[i*8 +: 8] = cmx_elem[i][7:0];
        end
    end

    // ── sidecar addressing + RMW row merge ──
    // k0 = sidecar sub-block index of egress window 0 (= blk_row_off, which is
    // 0 for the non-streaming STORE; kept general so the arithmetic stays
    // honest if a future streaming store advances blk_idx_q).
    logic [15:0]           cmx_k0, cmx_sc_row16;
    logic [L2_BANK_AW-1:0] cmx_sc_row;
    assign cmx_k0       = blk_row_off;
    assign cmx_sc_row16 = compact_scale_e4m3
                        ? (sidecar_base_q + {4'd0,  cmx_k0[15:4]})    // 16 x 16b / row
                        : (sidecar_base_q + {5'd0,  cmx_k0[15:5]});   // 32 x  8b / row
    assign cmx_sc_row   = cmx_sc_row16[L2_BANK_AW-1:0];

    // Merge this command's scale lane(s) into the captured sidecar row. A
    // block32 store's two windows (k0, k0+1) always share one sidecar row here
    // (k0 = 0 non-streaming), so a single RMW covers both.
    logic [HALF_STRIPE_W-1:0] cmx_sc_merged;
    always_comb begin
        logic [15:0] cmx_k1;                    // window-1 sub-block index
        cmx_k1        = cmx_k0 + 16'd1;
        cmx_sc_merged = sc_wb_row_q;
        if (compact_scale_e4m3) begin
            cmx_sc_merged[16*cmx_k0[3:0] +: 16] = compact_scale_q[0];
            if (block32_dual_egress)
                cmx_sc_merged[16*cmx_k1[3:0] +: 16] = compact_scale_q[1];
        end else begin
            cmx_sc_merged[8*cmx_k0[4:0] +: 8] = compact_scale_q[0][7:0];
            if (block32_dual_egress)
                cmx_sc_merged[8*cmx_k1[4:0] +: 8] = compact_scale_q[1][7:0];
        end
    end

    // =========================================================================
    // Control Signals
    // =========================================================================
    assign desc_ready_o = (state_q == VST_IDLE);
    assign busy_o       = (state_q != VST_IDLE);

    // =========================================================================
    // L2 RW Port — Address from dst_ref (C2 fix), payload from result capsule
    //   CL-3: For block32 dual-window, second window writes to dst_ref + 1
    // =========================================================================
    logic l2_wb_active;
    assign l2_wb_active = (state_q == VST_L2_WB);

    // [HW-REVIEW T3-FF/FF3b-c] 16b per-block base rows (sum first, then slice — Verilator
    // does not allow a bit-select on a parenthesized expression).
    logic [15:0] ro_pay_row16, rw_row16;
    assign ro_pay_row16 = src1_ref_q + blk_row_off;
    assign rw_row16     = dst_ref_q  + blk_row_off;

    always_comb begin
        // [HW-REVIEW T3-FF/FF3b-c] the single 256b RO port carries BOTH the residual payload
        // reads (RSD reader, in WAIT_OP1) and the per-16-block scale-sidecar read (in
        // VST_BLK_SETUP). They are temporally DISJOINT (BLK_SETUP precedes WAIT_OP1) and the
        // l2_ro_arbiter has no outstanding counter, so only one request is ever in flight.
        ro_req_o       = (rsd_state_q == RSD_REQ)                          // [STEP4-E2E §11.4] payload
                       || (state_q == VST_BLK_SETUP && sc_state_q == SC_REQ)  // sidecar row read
                       || (state_q == VST_SCRD && !scrd_wait_q);   // [C-MX ⑦] sidecar RMW read
        // [HW-REVIEW T3-FF/FF2/FF3b-c] payload row = src1_ref + k*caps_per_block + window
        //   (block32 window 1 reads the consecutive row, same half_sel; block16/window0
        //   rsd_cap_idx_q=0). At blk_idx_q=0 (single-block) blk_row_off=0 -> byte-identical.
        //   sidecar row = sidecar_base + (k>>4) (one 256b row holds 16 exps).
        // [C-MX ⑦] the three RO users are temporally disjoint: RSD runs in
        //   WAIT_OP1, SC_REQ in VST_BLK_SETUP, the compact RMW read in VST_SCRD.
        if (state_q == VST_BLK_SETUP)
            ro_row_o   = sidecar_base_q[L2_BANK_AW-1:0]
                       + L2_BANK_AW'(blk_idx_q[15:4]);
        else if (state_q == VST_SCRD)
            ro_row_o   = cmx_sc_row;
        else
            ro_row_o   = ro_pay_row16[L2_BANK_AW-1:0]
                       + L2_BANK_AW'({8'd0, rsd_cap_idx_q});
        rw_req_o       = l2_wb_active || (state_q == VST_SCWB);   // [C-MX ⑦] sidecar write-back
        // CL-3 + FF3b-c: offset by egress_window (block32 dual) AND by k*caps_per_block (stream)
        // [C-MX ⑦] VST_SCWB targets the sidecar row instead.
        if (state_q == VST_SCWB)
            rw_row_o   = cmx_sc_row;
        else
            rw_row_o   = rw_row16[L2_BANK_AW-1:0]
                       + L2_BANK_AW'({8'd0, egress_window_q});
        // [C-MX ⑦] compact payload writes use a NARROW bank mask (FP4: 2 banks /
        // 64b, FP8: 4 banks / 128b) so the untouched banks of the row are never
        // clobbered; the sidecar RMW writes the whole (merged) row. Non-compact
        // keeps the legacy full mask.
        if (state_q == VST_SCWB)
            rw_bank_mask_o = 16'hFFFF;
        else if (l2_wb_active && compact_wb_q && result_cap_valid_q)
            rw_bank_mask_o = compact_fmt_fp4 ? 16'h0003 : 16'h000F;
        else
            rw_bank_mask_o = l2_wb_active ? 16'hFFFF : 16'h0000;
        rw_wdata_o     = '0;
        if (state_q == VST_SCWB) begin
            // [C-MX ⑦] merged sidecar row (RMW write phase)
            rw_wdata_o[HALF_STRIPE_W-1:0] = cmx_sc_merged;
        end else if (l2_wb_active && compact_wb_q && result_cap_valid_q) begin
            // [C-MX ⑦ F8] requantized compact payload from the VST_CMX_PREP
            // pipeline register (trivial cone to the port; only the masked
            // low banks carry meaningful data).
            if (compact_fmt_fp4)
                rw_wdata_o[63:0]  = compact_payload_q[63:0];
            else
                rw_wdata_o[127:0] = compact_payload_q;
        end else if (l2_wb_active) begin
            // v6.0 Round 3a (Bug #2 fix): source payload from the latched
            // result_cap_q rather than the live result_capsule. The live
            // packer output collapses to zero once pipe_active falls on
            // the state→L2_WB transition, which previously caused every
            // L2 spill to write 256 bits of zero. result_cap_q is snapshot
            // in VST_ACTIVE on (last_pass && result_valid) — see the FSM
            // sequential block below.
            rw_wdata_o[BS_CAP_PAYLOAD_W-1:0] = result_cap_q.payload;
        end
    end

    // =========================================================================
    // FSM Next-State Logic
    //
    // State flow:
    //   IDLE ──desc_valid──► WAIT_OP0
    //   WAIT_OP0 ──capsules collected──► WAIT_OP1 (if need_src1) or ACTIVE
    //            ──role_stall_timeout──► ERROR (CL-4: prevents HOL deadlock;
    //                                            v6.0 R3a: VERR_ROLE_MISORDER)
    //   WAIT_OP1 ──capsules collected──► ACTIVE
    //            ──role_stall_timeout──► ERROR (CL-4; v6.0 R3a: VERR_ROLE_MISORDER)
    //   ACTIVE ──scale_any_error──► ERROR (v6.0 R3a: VERR_SCALE_DECODE)  [HIGHEST]
    //          ──watchdog_timeout──► L2_WB (CL-8)
    //          ──!last_pass──► stay ACTIVE (multi-pass iteration)
    //          ──last_pass + escape_needed──► L2_WB (B5: lossless spill)
    //          ──last_pass + fpath_accept──► DONE (if both windows done) or
    //                                        stay ACTIVE (next window, CL-3)
    //          ──last_pass + fallback──► L2_WB
    //                                    ([C-MX ⑦ F8] compact store: ──► CMX_PREP
    //                                     ──1 cycle──► L2_WB; same for a compact
    //                                     watchdog spill)
    //   L2_WB ──rw_gnt + more windows pending──► ACTIVE (CL-3 return)
    //         ──rw_gnt + all windows done──► DONE
    //                                    ([C-MX ⑦] compact store: ──► SCRD ──►
    //                                     SCWB ──rw_gnt──► DONE, sidecar RMW)
    //   DONE ──(1 cycle)──► IDLE
    //   ERROR ──(1 cycle)──► IDLE  (also fires done_o, C1 fix)
    //
    // VST_ACTIVE priority order (v6.0 Round 3a, from highest to lowest):
    //   1. scale_any_error  → ERROR   (correctness: contract violation)
    //   2. watchdog_timeout → L2_WB   (progress: graceful degradation)
    //   3. !last_pass       → ACTIVE  (normal multi-pass advance)
    //   4. escape_needed    → L2_WB   (numeric range: forced spill)
    //   5. fp_egr_accepted  → DONE / ACTIVE (fast path consumed capsule)
    //   6. otherwise        → L2_WB   (fast path refused, keep-local)
    // =========================================================================
    logic role_stall_timeout;
    logic watchdog_timeout;
    logic operand_timeout;   // HW-REVIEW T4: no operand arrived for too long
    assign operand_timeout    = (op_wait_cnt_q >= 10'(VEC_WATCHDOG_THRESHOLD));
    assign role_stall_timeout = (role_stall_cnt_q >= ROLE_STALL_LIMIT[6:0]);
    // v6.0 Round 3a (Bug #1 fix): use VEC_WATCHDOG_THRESHOLD (Round 1).
    //   Pre-v6 expression was (watchdog_cnt_q >= VEC_MAX_OP_CYCLES[9:0]).
    //   VEC_MAX_OP_CYCLES = 1024 = 11'b10000000000 → its low 10 bits are
    //   all zero, so the comparison degraded to (cnt >= 0) = always true.
    //   Every ACTIVE cycle fired watchdog immediately. See vec_pkg §1.
    assign watchdog_timeout   = (watchdog_cnt_q >= 10'(VEC_WATCHDOG_THRESHOLD));
    // [HW-REVIEW T3-FF/FF3b-c, FOLD-5] streaming L2_WB write-stall watchdog (rw_gnt never grants).
    logic l2wb_timeout;
    assign l2wb_timeout       = (l2wb_wait_cnt_q >= 10'(VEC_WATCHDOG_THRESHOLD));

    always_comb begin
        state_d = state_q;

        case (state_q)
            VST_IDLE: begin
                if (desc_valid_i) begin
                    // [STEP4-E2E §11.4] unsupported resident config -> VST_ERROR (fail loud).
                    // [HW-REVIEW T3-FF/FF3b-c] a streaming RESADD (resident, block_count>1)
                    // goes through VST_BLK_SETUP first so block 0's scale-sidecar is fetched
                    // on the SAME path as blocks 1..N-1; single-block keeps the legacy arm.
                    if (!(ctrl_valid && !resident_unsupported))
                        state_d = VST_ERROR;
                    else
                        state_d = streaming_in ? VST_BLK_SETUP : VST_WAIT_OP0;
                end
            end

            VST_WAIT_OP0: begin
                // CL-4: role stall timeout → ERROR (credit return + error report)
                // HW-REVIEW T4: operand_timeout (no operand ever arrived) → ERROR
                if (role_stall_timeout || operand_timeout) begin
                    state_d = VST_ERROR;
                end else if (oq_pop_ready) begin
                    logic all_src0;
                    all_src0 = (!caps_per_operand)
                             || (caps_per_operand && sub_count_q);
                    if (all_src0) begin
                        state_d = ctrl_q.need_src1 ? VST_WAIT_OP1 : VST_ACTIVE;
                    end
                end
            end

            VST_WAIT_OP1: begin
                // CL-4: role stall timeout → ERROR
                // HW-REVIEW T4: operand_timeout (no operand / hung resident read) → ERROR
                if (role_stall_timeout || operand_timeout) begin
                    state_d = VST_ERROR;
                end else if (oq_pop_ready) begin
                    logic all_src1;
                    all_src1 = (!caps_per_operand)
                             || (caps_per_operand && sub_count_q);
                    if (all_src1) begin
                        state_d = VST_ACTIVE;
                    end
                end
            end

            VST_ACTIVE: begin
                // v6.0 Round 3a priority #1: scale decode error pre-empts
                //   all other transitions. A contract violation in scale
                //   metadata must be surfaced immediately; letting watchdog
                //   or escape overtake would mask the root cause.
                if (scale_any_error) begin
                    state_d = VST_ERROR;
                // v6.0 Round 3a priority #2: CL-8 watchdog timeout → L2_WB
                // [C-MX ⑦ F8] ... via VST_CMX_PREP when the pending spill is a
                // compact one (compact_wb_q from a previously-latched window,
                // result_cap_valid_q data) — the PREP stage re-derives the
                // registered payload/scale from result_cap_q, preserving the
                // pre-F8 "data = last latched capsule" watchdog-spill
                // semantics. Non-compact watchdog spill: direct L2_WB, as
                // before.
                end else if (watchdog_timeout) begin
                    state_d = (compact_wb_q && result_cap_valid_q)
                            ? VST_CMX_PREP0 : VST_L2_WB;  // [C8-c] via 2-stage leading split
                end else if (active_phase_q != PH_REDUCE) begin
                    // [VEC-PIPE ⑥ / C5 / MC2] non-REDUCE phases (MC/MC2/LANE/
                    // RENORM/RENORM2): only the pipeline-boundary captures
                    // happen these cycles; latches/egress/pass advance wait
                    // for PH_REDUCE. scale_any_error / watchdog keep their
                    // old priority above.
                    state_d = VST_ACTIVE;
                end else if (!last_pass) begin
                    // Multi-pass intermediate: stay in ACTIVE, next pass on next cycle
                    state_d = VST_ACTIVE;
                end else begin
                    // Final compute pass reached. Handle egress.
                    //
                    // CL-3: For block32 non-reduce, we need to output TWO capsules.
                    //   egress_window_q tracks which window is being output:
                    //     window 0: first 16 elements
                    //     window 1: second 16 elements
                    //   For single-capsule paths (block16, reduce): egress_both_done=1
                    //   immediately, so we skip the window loop.

                    if (result_escape_needed) begin
                        // B5 fix: escape → forced L2 write-back (lossless spill)
                        // ([C-MX ⑦] compact_wb_d is 0 under escape by
                        //  construction — escape spills never go compact,
                        //  so no VST_CMX_PREP on this arm.)
                        state_d = VST_L2_WB;
                    end else if (fp_egr_accepted) begin
                        // Fast path accepted this window's capsule
                        if (egress_both_done) begin
                            // [HW-REVIEW T3-FF/FF3b-c] block done. If more residual blocks
                            // remain, go to the (non-retiring) VST_BLK_NEXT instead of DONE
                            // so done_o/perf/CP-credit fire exactly once for the whole stream.
                            state_d = more_blocks ? VST_BLK_NEXT : VST_DONE;
                        end else begin
                            // CL-3: more windows to egress — stay in ACTIVE
                            state_d = VST_ACTIVE;
                        end
                    end else begin
                        // CL-8 fix: catch-all fallback to L2_WB
                        // [C-MX ⑦ F8] compact store (compact_wb_d about to be
                        // latched with this window's result) detours through
                        // the one-cycle VST_CMX_PREP requantize stage first;
                        // result_valid mirrors the latch predicate so PREP is
                        // only entered when result_cap_q is being loaded.
                        // Non-compact: direct VST_L2_WB, zero added cycles.
                        state_d = (result_valid && compact_wb_d)
                                ? VST_CMX_PREP0 : VST_L2_WB;  // [C8-c] via 2-stage leading split
                    end
                end
            end

            VST_L2_WB: begin
                if (rw_gnt_i) begin
                    // CL-3: after L2 write, check if more egress windows remain
                    if (block32_dual_egress && !egress_both_done) begin
                        state_d = VST_ACTIVE;  // return for second window
                    end else if (compact_wb_q && result_cap_valid_q) begin
                        // [C-MX STORE ⑦] all compact payload windows written ->
                        // scale-sidecar RMW (read the row, merge, write back).
                        state_d = VST_SCRD;
                    end else begin
                        // [HW-REVIEW T3-FF/FF3b-c] block written. More residual blocks ->
                        // VST_BLK_NEXT (not DONE), else the once-per-descriptor DONE.
                        state_d = more_blocks ? VST_BLK_NEXT : VST_DONE;
                    end
                // [HW-REVIEW T3-FF/FF3b-c, FOLD-5] streaming-only L2_WB write-stall watchdog:
                // VST_L2_WB advances ONLY on rw_gnt_i, so a hung RW port would deadlock the
                // stream (and is hit N times). A streaming write-stall is a loud VST_ERROR
                // (a hung write cannot be gracefully continued). Single-block is untouched.
                end else if (streaming_mode_q && l2wb_timeout) begin
                    state_d = VST_ERROR;
                end
            end

            // [HW-REVIEW T3-FF/FF3b-c] per-block teardown: NEVER asserts done_o (see :done_o
            // decode below). One cycle: increments blk_idx_q + applies the per-block reset
            // union (sequential block), then sets up the next block's sidecar.
            VST_BLK_NEXT:  state_d = VST_BLK_SETUP;

            // [HW-REVIEW T3-FF/FF3b-c, FOLD-2] sidecar fetch for the current block. The
            // operand_timeout exit is MANDATORY in the NEXT-STATE block — writing error_q
            // in the sequential block alone does not move the FSM, so a hung sidecar read
            // would deadlock without this (mirrors the WAIT_OP* operand_timeout arms).
            VST_BLK_SETUP: begin
                if (operand_timeout) state_d = VST_ERROR;
                else                 state_d = sc_ready ? VST_WAIT_OP0 : VST_BLK_SETUP;
            end

            // [C-MX STORE ⑦ F8] one-cycle requantize pre-compute stage: the
            // sequential block registers compact_payload_q + compact_scale_q
            // from the requantizer bank (result_cap_q source) this cycle;
            // [C-MX ⑦ C3] leading requantize stage: register the shared-exp max
            // this cycle (sequential arm below), then run the per-lane encode in
            // VST_CMX_PREP. Unconditional; PREP is reachable ONLY from here.
            // [C8-c] FRONT stage ahead of PREP1: registers cmx_norm/eff/nz this
            // cycle so the PREP1 max tree reads registered leaves. PREP1 is
            // reachable ONLY from here.
            // [T1] PREP2 between PREP1 and PREP: registers the back-ALIGN
            // products so PREP runs the round/encode half only.
            VST_CMX_PREP0: state_d = VST_CMX_PREP1;
            VST_CMX_PREP1: state_d = VST_CMX_PREP2;
            VST_CMX_PREP2: state_d = VST_CMX_PREP;
            // unconditionally proceed to the L2 payload write.
            VST_CMX_PREP: state_d = VST_L2_WB;

            // [C-MX STORE ⑦] sidecar RMW read: request until ro_gnt_i
            // (scrd_wait_q flips in the sequential block), then advance on the
            // 1-cycle-later ro_rvalid_i (SC_REQ/SC_WAIT protocol). Hang
            // semantics match the non-streaming VST_L2_WB (hold to grant,
            // no dedicated watchdog).
            VST_SCRD:  if (scrd_wait_q && ro_rvalid_i) state_d = VST_SCWB;

            // [C-MX STORE ⑦] sidecar merged-row write-back; hold to grant.
            // STORE is non-streaming (more_blocks=0) -> DONE; the more_blocks
            // arm keeps the exit symmetric with VST_L2_WB.
            VST_SCWB:  if (rw_gnt_i) state_d = more_blocks ? VST_BLK_NEXT : VST_DONE;

            VST_DONE:  state_d = VST_IDLE;
            VST_ERROR: state_d = VST_IDLE;
            default:   state_d = VST_IDLE;
        endcase
    end

    // =========================================================================
    // [STEP4-E2E §11.4] Resident-SRC1 reader FSM.
    //   Triggers ONLY in VST_WAIT_OP1 with src1_resident_q (RESADD resident mode).
    //   RSD_REQ asserts ro_req (row=src1_ref_q) until ro_gnt; RSD_WAIT captures
    //   ro_rdata on ro_rvalid; RSD_CAP holds resident_valid until the ingress arb
    //   accepts (resident_ready); RSD_DONE waits for the op to retire. Re-armed
    //   when the core returns to VST_IDLE. ro_half_sel_o tracks half_sel_q
    //   (vector_unit_top), so the residual must be placed in the matching L2 half.
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rsd_state_q   <= RSD_IDLE;
            rsd_data_q    <= '0;
            rsd_cap_idx_q <= 1'b0;
        end else if (soft_reset_i) begin   // [STEP5 slang] sync soft-reset (mirror)
            rsd_state_q   <= RSD_IDLE;
            rsd_data_q    <= '0;
            rsd_cap_idx_q <= 1'b0;
        end else if (state_q == VST_IDLE || state_q == VST_BLK_NEXT) begin
            // [HW-REVIEW T3-FF/FF3b-c] re-arm per OP (IDLE) AND per BLOCK (BLK_NEXT): each
            // streaming block re-runs the reader from scratch (window index back to 0).
            rsd_state_q   <= RSD_IDLE;
            rsd_cap_idx_q <= 1'b0;               // [T3-FF/FF2] reset window index
        end else begin
            case (rsd_state_q)
                RSD_IDLE: if (state_q == VST_WAIT_OP1 && src1_resident_q) rsd_state_q <= RSD_REQ;
                RSD_REQ:  if (ro_gnt_i)    rsd_state_q <= RSD_WAIT;
                RSD_WAIT: if (ro_rvalid_i) begin
                              rsd_data_q  <= ro_rdata_i[HALF_STRIPE_W-1:0];
                              rsd_state_q <= RSD_CAP;
                          end
                // [HW-REVIEW T3-FF/FF2] block32 residual = TWO 256b windows. After window 0
                // is accepted by the ingress arb (resident_ready), loop back to read window 1
                // (row src1_ref_q+1, same half) and present it as the 2nd OP_SRC1 capsule;
                // the existing block32 sink (sub_count -> src1_cap_b_q) collects both. The OQ
                // buffers window 0 at acceptance, so rsd_data_q may be overwritten by window 1.
                RSD_CAP:  if (resident_ready) begin
                              if (caps_per_operand && rsd_cap_idx_q == 1'b0) begin
                                  rsd_cap_idx_q <= 1'b1;
                                  rsd_state_q   <= RSD_REQ;   // fetch window 1
                              end else begin
                                  rsd_state_q   <= RSD_DONE;
                              end
                          end
                RSD_DONE: ; // hold until VST_IDLE re-arm
                default:  rsd_state_q <= RSD_IDLE;
            endcase
        end
    end

    // =========================================================================
    // FSM Sequential Logic (v2.1: CL-4/CL-5/CL-8 registers)
    // =========================================================================
    // [STEP5 slang] The async reset (rst_ni) and the synchronous soft_reset_i must
    // be separate branches: the yosys-slang synth frontend rejects ORing
    // soft_reset_i (no edge in the @(posedge clk or negedge rst_ni) sensitivity
    // list) into the async-reset `if`. The shared reset values are factored into
    // reset_vst_main() so the async and sync paths are single-source and cannot
    // diverge. Behavior is identical (soft_reset_i was already synchronous).
    task automatic reset_vst_main;
        state_q            <= VST_IDLE;
        ctrl_q             <= '0;
        error_q            <= VERR_NONE;
        dst_ref_q          <= '0;
        src1_ref_q         <= '0;            // [STEP4-E2E §11.4]
        src1_resident_q    <= 1'b0;          // [STEP4-E2E §11.4]
        src1_scale_ref_q   <= 16'sd0;        // [HW-REVIEW T3]
        num_passes_q       <= 2'd1;
        pass_idx_q         <= 2'd0;
        sub_count_q        <= 1'b0;
        src0_cap_q         <= '0;
        src1_cap_q         <= '0;
        src0_cap_b_q       <= '0;
        src1_cap_b_q       <= '0;
        src0_loaded_q      <= 1'b0;
        src1_loaded_q      <= 1'b0;
        partial_reduce_q   <= '0;
        partial_max_exp_q  <= '0;
        partial_escape_q   <= 1'b0;
        partial_packed_mant_q <= '0;
        // CL-4: role stall counter
        role_stall_cnt_q   <= '0;
        // CL-5: 40-bit STAT partial accumulator
        partial_stat_mant_q <= '0;
        partial_stat_exp_q  <= '0;
        // CL-8: watchdog counter
        watchdog_cnt_q     <= '0;
        // HW-REVIEW T4: operand-wait watchdog
        op_wait_cnt_q      <= '0;
        // CL-3: egress window counter
        egress_window_q    <= 1'b0;
        // v6.0 Round 3a: result capsule latch + its valid bit
        result_cap_q       <= '0;
        result_cap_valid_q <= 1'b0;
        // v6.0 Round 3b: pass-0 lane results latch (Bug #4)
        for (int i = 0; i < VEC_LANES; i++)
            partial_lane_results_q[i] <= '0;
        partial_lane_valid_q <= 1'b0;
        // [VEC-PIPE ⑥] LANE|REDUCE pipeline cut state (async and soft_reset
        // both funnel through this task — single-source reset discipline)
        active_phase_q <= PH_SEL;             // [C5→MC2→LANE2→MC2F] 3-bit rotor, 8 phases (saturated)
        lane_valid_q   <= 1'b0;
        lane_valid_q2  <= 1'b0;   // [C8-b]
        lane_valid_q3  <= 1'b0;   // [C9-b]
        renorm_result_q <= '0;    // [C8-b] X-clean only; PH_RENORM2 always writes first
        // [C9-b] renorm front boundary regs (X-clean only; PH_RENORM writes first)
        rn_front_max_q    <= '0;
        rn_front_min_q    <= '0;
        rn_front_normal_q <= 1'b0;
        rn_front_nan_q    <= 1'b0;
        rn_front_inf_q    <= 1'b0;
        rn_front_ovf_q    <= 1'b0;
        for (int i = 0; i < VEC_LANES; i++)
            lane_results_q[i] <= '0;
        // [C5] PH_MC operand pipeline registers
        for (int i = 0; i < VEC_LANES; i++) begin
            src0_lane_q[i] <= '0;
            src1_lane_q[i] <= '0;
            // [MC2F] select seam registers (X-clean only; PH_SEL always
            // writes before PH_MC consumes — no-skip arc asserted)
            src0_sel_q[i]  <= '0;
            src1_sel_q[i]  <= '0;
            // [C9] shift-control registers (X-clean only; [MC2] PH_MC2 always
            // writes them before PH_LANE consumes — no-skip arc asserted)
            mc_abs_diff_q[i]   <= '0;
            mc_shift_src1_q[i] <= 1'b0;
            // [T1b] negate pre-application register (same X-clean contract,
            // [MC2] writer is PH_MC2)
            mc_eff_s1_q[i]     <= '0;
            // [LANE2] align seam registers (X-clean only; PH_LANE always
            // writes before PH_LANE2 consumes — no-skip arc asserted)
            lane_align_q[i]    <= '0;
            lane_sticky_q[i]   <= 1'b0;
        end
        // [MC2F] correction-control seam (same X-clean contract, writer PH_SEL)
        mc2f_corr_s0_q <= 8'd0;
        mc2f_corr_s1_q <= 8'd0;
        mc2f_precise_q <= 1'b0;
        // [HW-REVIEW T3-FF/FF3b-c] streaming outer-loop state
        blk_idx_q           <= 16'd0;
        block_count_q       <= 16'd1;
        sidecar_base_q      <= 16'd0;
        streaming_mode_q    <= 1'b0;
        degraded_q          <= 1'b0;
        l2wb_wait_cnt_q     <= '0;
        fp_blk_accept_cnt_q <= 2'd0;
        sc_state_q          <= SC_CHECK;
        sc_row_q            <= '0;
        sc_grp_q            <= '0;
        sc_valid_q          <= 1'b0;
        // [C-MX STORE ⑦] compact store state (soft_reset in VST_CMX_PREP/
        // VST_SCRD/VST_SCWB must come back to a clean IDLE — single-source
        // via this task)
        compact_scale_q[0]  <= 16'd0;
        compact_scale_q[1]  <= 16'd0;
        compact_payload_q   <= 128'd0;
        // [C-MX ⑦ C3] only reset needed for the split regs: VST_CMX_PREP1 always
        // writes them before VST_CMX_PREP reads them (SVA below), so per-op teardown
        // clears are unnecessary — this clears power-on/soft-reset X only.
        cmx_shared_exp_q    <= '0;
        cmx_any_nz_q        <= 1'b0;
        // [C8-a] same contract for the front regs (PREP1 always writes first).
        // [T1] and for the back-ALIGN regs (PREP2 always writes first).
        for (int ci = 0; ci < VEC_LANES; ci++) begin
            cmx_norm_q[ci]      <= '0;
            cmx_eff_q[ci]       <= '0;
            cmx_al_mfield_q[ci] <= '0;
            cmx_al_eunb_q[ci]   <= '0;
        end
        cmx_al_rbit_q       <= '0;
        cmx_al_stick_q      <= '0;
        cmx_al_normal_q     <= '0;
        cmx_fp4_q           <= 1'b0;
        cmx_nz_q            <= '0;
        compact_wb_q        <= 1'b0;
        sc_wb_row_q         <= '0;
        scrd_wait_q         <= 1'b0;
    endtask

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)           reset_vst_main();
        else if (soft_reset_i) reset_vst_main();
        else begin
            state_q <= state_d;

            case (state_q)
                VST_IDLE: begin
                    if (desc_valid_i) begin
                        ctrl_q         <= ctrl;
                        error_q        <= resident_unsupported ? VERR_BAD_BLOCK_SIZE : decode_error;
                        dst_ref_q      <= desc_i.dst_ref;   // C2 fix
                        src1_ref_q     <= desc_i.src1_ref;      // [STEP4-E2E §11.4]
                        src1_resident_q<= desc_i.src1_resident; // [STEP4-E2E §11.4]
                        src1_scale_ref_q <= desc_i.src1_scale_ref; // [HW-REVIEW T3] per-residual abs exp
                        num_passes_q   <= ctrl.num_passes;
                        pass_idx_q     <= 2'd0;
                        sub_count_q    <= 1'b0;
                        src0_loaded_q  <= 1'b0;
                        src1_loaded_q  <= 1'b0;
                        role_stall_cnt_q <= '0;  // CL-4: reset on new descriptor
                        watchdog_cnt_q   <= '0;  // CL-8: reset on new descriptor
                        op_wait_cnt_q    <= '0;  // HW-REVIEW T4: reset on new descriptor
                        egress_window_q  <= 1'b0; // CL-3: reset egress window
                        // [HW-REVIEW T3-FF/FF3b-c] latch streaming context. FOLD-4:
                        // streaming_mode_q derives from desc_i (NOT the registered
                        // block_count_q), else a small-N op after a large-N op would
                        // mis-arm streaming. block_count_q is clamped 0->1 at latch.
                        blk_idx_q        <= 16'd0;
                        block_count_q    <= block_count_eff_in;
                        sidecar_base_q   <= desc_i.sidecar_base;
                        streaming_mode_q <= streaming_in;
                        degraded_q       <= 1'b0;
                        l2wb_wait_cnt_q  <= '0;
                        fp_blk_accept_cnt_q <= 2'd0;
                        sc_state_q       <= SC_CHECK;
                        sc_valid_q       <= 1'b0;   // force a fresh sidecar fetch for the new op
                    end
                end

                VST_WAIT_OP0: begin
                    // CL-4: count role stall cycles
                    if (role_misorder)
                        role_stall_cnt_q <= role_stall_cnt_q + 7'd1;
                    else
                        role_stall_cnt_q <= '0;  // reset on match or no valid capsule

                    // CL-4 + v6.0 Round 3a: set dedicated error code on role stall timeout
                    //   Pre-v6 code overloaded VERR_INTERNAL for this condition.
                    //   Round 1 introduced VERR_ROLE_MISORDER as the formal code.
                    if (role_stall_timeout)
                        error_q <= VERR_ROLE_MISORDER;

                    // HW-REVIEW T4: no-progress operand watchdog (reset on accept)
                    if (oq_pop_ready) op_wait_cnt_q <= '0;
                    else              op_wait_cnt_q <= op_wait_cnt_q + 10'd1;
                    // role_stall (wrong-order) takes precedence on a tie cycle so the
                    // diagnostic code is correct (HW-REVIEW T4 merge-gate).
                    if (operand_timeout && !role_stall_timeout)
                        error_q <= VERR_OPERAND_TIMEOUT;

                    // [HW-REVIEW T3-FF/FF3b-c, FOLD-3] count fast-path SRC0 capsules accepted
                    // for THIS block; the combinational fp_stream_block gate closes the fast
                    // path once this reaches caps_per_block, so block k+1's SRC0 cannot jump
                    // ahead of block k's resident SRC1. Reset per block in VST_BLK_NEXT.
                    if (streaming_mode_q && fp_accept)
                        fp_blk_accept_cnt_q <= fp_blk_accept_cnt_q + 2'd1;

                    if (oq_pop_ready) begin
                        if (!sub_count_q) begin
                            src0_cap_q  <= oq_pop_cap;  // first src0 capsule
                            sub_count_q <= caps_per_operand ? 1'b1 : 1'b0;
                            src0_loaded_q <= !caps_per_operand; // loaded if only 1 needed
                        end else begin
                            src0_cap_b_q <= oq_pop_cap; // second src0 capsule (block32)
                            sub_count_q  <= 1'b0;       // reset for WAIT_OP1
                            src0_loaded_q <= 1'b1;
                        end
                    end
                end

                VST_WAIT_OP1: begin
                    // CL-4: count role stall cycles
                    if (role_misorder)
                        role_stall_cnt_q <= role_stall_cnt_q + 7'd1;
                    else
                        role_stall_cnt_q <= '0;

                    // CL-4 + v6.0 Round 3a: dedicated role-misorder code (see WAIT_OP0)
                    if (role_stall_timeout)
                        error_q <= VERR_ROLE_MISORDER;

                    // HW-REVIEW T4: no-progress operand watchdog (covers hung resident read)
                    if (oq_pop_ready) op_wait_cnt_q <= '0;
                    else              op_wait_cnt_q <= op_wait_cnt_q + 10'd1;
                    // role_stall (wrong-order) takes precedence on a tie cycle so the
                    // diagnostic code is correct (HW-REVIEW T4 merge-gate).
                    if (operand_timeout && !role_stall_timeout)
                        error_q <= VERR_OPERAND_TIMEOUT;

                    if (oq_pop_ready) begin
                        if (!sub_count_q) begin
                            src1_cap_q  <= oq_pop_cap;
                            sub_count_q <= caps_per_operand ? 1'b1 : 1'b0;
                            src1_loaded_q <= !caps_per_operand;
                        end else begin
                            src1_cap_b_q <= oq_pop_cap;
                            sub_count_q  <= 1'b0;
                            src1_loaded_q <= 1'b1;
                        end
                    end
                end

                VST_ACTIVE: begin
                    // CL-8: increment watchdog
                    watchdog_cnt_q <= watchdog_cnt_q + 10'd1;

                    // [HW-REVIEW T3-FF/FF3b-c, FOLD-6] A streaming watchdog_timeout takes the
                    // existing graceful spill to L2_WB (writes the block, the stream continues),
                    // but that would otherwise report a CLEAN final DONE. Latch a sticky degraded
                    // flag so the final VST_DONE asserts err_valid_o — a watchdog-truncated stream
                    // can never report silent success. Single-block keeps today's semantics (gated).
                    // Also stamp VERR_DEGRADED (only if no harder code is pending) so the degraded
                    // DONE carries an unambiguous code instead of VERR_NONE (review T3-FF/FF3b-c).
                    if (streaming_mode_q && watchdog_timeout) begin
                        degraded_q <= 1'b1;
                        if (error_q == VERR_NONE)
                            error_q <= VERR_DEGRADED;
                    end

                    // v6.0 Round 3a: scale decode error → set dedicated code
                    //   (FSM state transition to VST_ERROR is handled in the
                    //    next-state combinational block; this only updates
                    //    error_q so ERROR state sees the right code.)
                    if (scale_any_error)
                        error_q <= VERR_SCALE_DECODE;

                    // v6.0 Round 3a (Bug #2 fix): latch result capsule for L2_WB
                    //   Wide condition per Round 3a decision 疑点 A: does NOT
                    //   filter by result_escape_needed because escape-spill
                    //   writes (forced L2 WB on numeric-range overflow) must
                    //   also carry real payload data, not zeros.
                    //
                    //   For block32 dual-capsule egress this fires at each
                    //   window's last_pass cycle, so result_cap_q tracks the
                    //   window being egressed. For block16 / reduce paths it
                    //   fires exactly once per op.
                    //
                    //   Note: in v4 RTL prior to Round 3b, lane-only block32
                    //   result_capsule at last_pass contains pass-1 data at
                    //   both windows (Bug #4). Round 3a's latch faithfully
                    //   records whatever result_capsule contains; Round 3b
                    //   will fix the upstream selection so the latch then
                    //   captures the correct per-window data automatically.
                    if (last_pass && result_valid) begin
                        result_cap_q       <= result_capsule;
                        result_cap_valid_q <= 1'b1;
                        // [C-MX STORE ⑦] compact-store flag latch — SAME cycle,
                        // SAME predicate as the result_cap_q latch. Its D-cone
                        // (compact_wb_d) is only ctrl decode + the REGISTERED
                        // active_src0_cap scale decode — cheap. Gates (F2/F3/F5):
                        //   compact_scale_ok   — capsule scale decodes to a
                        //     power of 2 (else LOSSLESS full-payload fallback)
                        //   !cmx_frag_mismatch — block32 fragments carry ONE
                        //     block scale (else whole-store fallback)
                        //   !result_escape_needed — DEFENSIVE only: a STORE
                        //     (renorm_en=0) has it structurally 0; quantize
                        //     underflow-to-0 is NOT escape (MX-inherent loss).
                        // [F8] the per-window payload/scale themselves are NOT
                        // computed here anymore: the FSM detours through the
                        // one-cycle VST_CMX_PREP stage, which registers them
                        // from the requantizer bank fed by result_cap_q —
                        // breaking the pre-F8 108.8ns live-datapath+requant
                        // single-cycle cone into two <=1-period cones.
                        compact_wb_q <= compact_wb_d;
                    end

                    if ((active_phase_q == PH_REDUCE) && !last_pass) begin
                        // [VEC-PIPE ⑥ / C5 / MC2] REDUCE-phase gate is load-
                        // bearing: an advance in any earlier phase (MC/MC2/
                        // LANE/...) would step pass_idx_q more than once per
                        // pass and pollute partial_reduce_q with valid=0
                        // results (block32).
                        // Intermediate pass: latch partial results, advance counter
                        pass_idx_q <= pass_idx_q + 2'd1;

                        if (ctrl_q.reduce_en) begin
                            partial_reduce_q <= reduce_result;

                            // CL-5: for REDUCE_STAT, also latch full 40-bit result
                            if (ctrl_q.reduce_mode == REDUCE_STAT) begin
                                partial_stat_mant_q <= reduce_stat_raw_mant;
                                partial_stat_exp_q  <= reduce_stat_raw_exp;
                            end
                        end

                        if (ctrl_q.renorm_en) begin
                            partial_max_exp_q <= renorm_result_q.new_scale.exp_adj;      // [C8-b]
                            partial_escape_q  <= renorm_result_q.escape_needed;          // [C8-b]
                            partial_packed_mant_q <= renorm_result_q.packed_mant[BS_CAP_PAYLOAD_W-1:0]; // [C8-b]
                        end

                        // v6.0 Round 3b (Bug #4 fix): latch pass-0 lane
                        //   results for lane-only block32 dual egress.
                        //   All 4 predicates explicit per Round 3b decision #2:
                        //     num_passes_q == 2  → block32 (not block16)
                        //     pass_idx_q   == 0  → pass-0 completion moment
                        //                          (redundant under !last_pass
                        //                          for block32, but kept
                        //                          explicit to prevent future
                        //                          misuse)
                        //     !reduce_en         → reduce has no dual egress
                        //     !renorm_en         → renorm has its own combine
                        //     lane_valid_q       → registered lane output is stable
                        if ((num_passes_q == 2'd2) && (pass_idx_q == 2'd0)
                            && !ctrl_q.reduce_en && !ctrl_q.renorm_en
                            && lane_valid_q3) begin   // [C8-b][C9-b] REDUCE-phase token
                            partial_lane_results_q <= lane_results_q;
                            partial_lane_valid_q   <= 1'b1;
                        end
                    end
                    // v6.0 Round 3b (Bug #6 fix): Final-pass egress window advance.
                    //   egress_window_q advances ONLY on fp_egr_accepted in
                    //   VST_ACTIVE — the fast path consumed the current
                    //   window same-cycle, so we can move on next cycle.
                    //   The pre-v6 logic also advanced on (state_d == VST_L2_WB),
                    //   which caused the L2_WB write to happen with the wrong
                    //   egress_window_q value — writing window-0 data to
                    //   dst_ref+1 and never writing window 1 at all.
                    //   Under the v6.0 timing, the L2_WB path instead advances
                    //   egress_window_q in VST_L2_WB on rw_gnt_i (see below).
                    if (last_pass && block32_dual_egress && fp_egr_accepted) begin
                        egress_window_q <= egress_window_q + 1'b1;
                    end
                end

                VST_L2_WB: begin
                    // v6.0 Round 3b (Bug #6 fix): advance egress_window_q
                    // on L2 write completion. For block32 dual-capsule
                    // fallback, the FSM next-state logic returns to
                    // VST_ACTIVE after the first L2 write (when
                    // egress_window_q is about to become 1) to emit the
                    // second window. Advancing here — same cycle as
                    // rw_gnt_i — means the subsequent VST_ACTIVE re-entry
                    // immediately sees the updated window selector.
                    //
                    // For block16 / reduce / single-capsule paths,
                    // block32_dual_egress is 0 and this is a no-op; the
                    // next-state logic routes L2_WB → DONE on rw_gnt_i.
                    //
                    // Separately, result_cap_valid_q is kept asserted
                    // through L2_WB so rw_wdata_o remains valid across
                    // any multi-cycle grant handshake. It is cleared on
                    // DONE/ERROR.
                    if (rw_gnt_i && block32_dual_egress && !egress_both_done) begin
                        egress_window_q <= egress_window_q + 1'b1;
                    end
                    // [HW-REVIEW T3-FF/FF3b-c, FOLD-5] streaming L2_WB write-stall watchdog.
                    // VST_L2_WB advances ONLY on rw_gnt_i; a hung RW port (hit N times under
                    // streaming) would deadlock. Count no-grant cycles -> loud VST_ERROR
                    // (next-state). Single-block leaves l2wb_wait_cnt_q at 0 (gated), no change.
                    if (rw_gnt_i)               l2wb_wait_cnt_q <= '0;
                    else if (streaming_mode_q)  l2wb_wait_cnt_q <= l2wb_wait_cnt_q + 10'd1;
                    if (streaming_mode_q && l2wb_timeout)
                        error_q <= VERR_OPERAND_TIMEOUT;
                end

                // [HW-REVIEW T3-FF/FF3b-c] per-block teardown+advance. Apply the UNION of the
                // IDLE-entry reset and the DONE/ERROR teardown so block k+1 starts byte-identical
                // to a fresh op, then advance the block index. Partial accumulators are NOT reset
                // (self-overwritten by each block's pass-0, matching today's IDLE behavior).
                VST_BLK_NEXT: begin
                    blk_idx_q            <= blk_idx_q + 16'd1;
                    pass_idx_q           <= 2'd0;
                    sub_count_q          <= 1'b0;
                    src0_loaded_q        <= 1'b0;
                    src1_loaded_q        <= 1'b0;
                    egress_window_q      <= 1'b0;
                    role_stall_cnt_q     <= '0;
                    watchdog_cnt_q       <= '0;
                    op_wait_cnt_q        <= '0;
                    l2wb_wait_cnt_q      <= '0;
                    fp_blk_accept_cnt_q  <= 2'd0;
                    result_cap_valid_q   <= 1'b0;
                    partial_lane_valid_q <= 1'b0;
                    // [C-MX STORE ⑦] cleared at the same points as result_cap_valid_q
                    compact_wb_q         <= 1'b0;
                    compact_scale_q[0]   <= 16'd0;
                    compact_scale_q[1]   <= 16'd0;
                    compact_payload_q    <= 128'd0;
                    scrd_wait_q          <= 1'b0;
                    // FOLD-1: re-evaluate the sidecar cache so a 16-block group crossing REFETCHES
                    // (without this sc_state_q parks in SC_RDY and block>=16 reuses block-0's row).
                    // sc_valid_q / sc_grp_q / sc_row_q PERSIST (lazy cache within a group).
                    sc_state_q           <= SC_CHECK;
                end

                // [HW-REVIEW T3-FF/FF3b-c] lazy scale-sidecar fetch (one 256b row = 16 exps).
                // SC_CHECK reuses the cached row within a 16-block group; a miss reads one row.
                // FOLD-2: a hung read trips op_wait_cnt_q -> operand_timeout -> VST_ERROR.
                VST_BLK_SETUP: begin
                    case (sc_state_q)
                        SC_CHECK: sc_state_q <= sc_cache_hit ? SC_RDY : SC_REQ;
                        SC_REQ:   if (ro_gnt_i) sc_state_q <= SC_WAIT;
                        SC_WAIT:  if (ro_rvalid_i) begin
                                      sc_row_q   <= ro_rdata_i[HALF_STRIPE_W-1:0];
                                      sc_grp_q   <= blk_idx_q[15:4];
                                      sc_valid_q <= 1'b1;
                                      sc_state_q <= SC_RDY;
                                  end
                        SC_RDY:   ; // hold until next-state advances to VST_WAIT_OP0 (sc_ready)
                        default:  sc_state_q <= SC_CHECK;
                    endcase
                    // FOLD-2: no-progress backstop while actually fetching the sidecar row.
                    if (sc_state_q == SC_REQ || sc_state_q == SC_WAIT)
                        op_wait_cnt_q <= op_wait_cnt_q + 10'd1;
                    else
                        op_wait_cnt_q <= '0;
                    // Set the dedicated code so the loud VST_ERROR exit (next-state) reports it
                    // (mirrors the WAIT_OP0/OP1 arms — without this the ERROR carries VERR_NONE).
                    if (operand_timeout)
                        error_q <= VERR_OPERAND_TIMEOUT;
                end

                // [C-MX STORE ⑦ F8] one-cycle requantize pre-compute stage:
                // register the narrow payload + this window's scale from the
                // requantizer bank (source = result_cap_q, loaded on the
                // previous cycle's ACTIVE latch — or holding the last latched
                // capsule on the watchdog-spill route). egress_window_q is the
                // CURRENT window here: it advances only at L2_WB grant, so
                // [C-MX ⑦ C3] leading requantize stage — register the shared-exp
                // max (and any-nonzero) AHEAD of the per-lane encode. result_cap_q
                // (latched in the prior VST_ACTIVE) and ctrl_q (VST_IDLE) are HELD
                // across PREP1->PREP, so these equal the live values the old
                // single-cycle PREP saw (value-preserving; requantizer.sv:81 eff_o
                // is independent of shared_exp_i => no combinational loop).
                // [C8-c] FRONT stage: register the per-lane requantizer FRONT
                // (was in PREP1 since C8-a) one state earlier, so the PREP1
                // max tree consumes REGISTERED eff/nz leaves instead of the
                // live ctrl_q-select -> scale-decode -> front cone in series
                // with the tree (the 1807.44 ps arc-3 binding wall). Same
                // held-input value-preservation argument: result_cap_q and
                // ctrl_q are HELD across PREP0->PREP1->PREP.
                VST_CMX_PREP0: begin
                    cmx_norm_q       <= cmx_norm;
                    cmx_eff_q        <= cmx_eff;
                    cmx_nz_q         <= cmx_lane_nz;
                    cmx_fp4_q        <= compact_fmt_fp4;   // [T1] ctrl_q held -> registered identity
                end
                VST_CMX_PREP1: begin
                    cmx_shared_exp_q <= cmx_shared_exp;
                    cmx_any_nz_q     <= cmx_any_nz;
                end
                // [T1] back-ALIGN products land here; PREP encodes from these.
                VST_CMX_PREP2: begin
                    cmx_al_mfield_q  <= cmx_al_mfield;
                    cmx_al_eunb_q    <= cmx_al_eunb;
                    cmx_al_rbit_q    <= cmx_al_rbit;
                    cmx_al_stick_q   <= cmx_al_stick;
                    cmx_al_normal_q  <= cmx_al_normal;
                end
                // window 0 PREPs with index 0 and window 1 with index 1.
                VST_CMX_PREP: begin
                    compact_payload_q                <= compact_payload;
                    compact_scale_q[egress_window_q] <= compact_scale_now;
                end

                // [C-MX STORE ⑦] scale-sidecar RMW read: assert ro_req (comb)
                // until ro_gnt_i, then capture ro_rdata on the 1-cycle-later
                // ro_rvalid_i (same protocol as SC_REQ/SC_WAIT in BLK_SETUP).
                VST_SCRD: begin
                    if (scrd_wait_q) begin
                        if (ro_rvalid_i) begin
                            sc_wb_row_q <= ro_rdata_i[HALF_STRIPE_W-1:0];
                            scrd_wait_q <= 1'b0;   // next-state advances to SCWB
                        end
                    end else if (ro_gnt_i) begin
                        scrd_wait_q <= 1'b1;
                    end
                end

                VST_DONE, VST_ERROR: begin
                    src0_loaded_q <= 1'b0;
                    src1_loaded_q <= 1'b0;
                    pass_idx_q    <= 2'd0;
                    role_stall_cnt_q <= '0;  // CL-4: clear
                    watchdog_cnt_q   <= '0;  // CL-8: clear
                    egress_window_q  <= 1'b0; // CL-3: clear
                    // v6.0 Round 3a: invalidate the result latch before the
                    // next op enters ACTIVE. Data in result_cap_q becomes
                    // stale; keeping valid=0 prevents any accidental reuse.
                    result_cap_valid_q <= 1'b0;
                    // v6.0 Round 3b: same rationale for partial_lane_valid_q —
                    // the latched pass-0 lane results are stale for the
                    // next op and must not be accidentally consumed.
                    partial_lane_valid_q <= 1'b0;
                    // [C-MX STORE ⑦] compact latches are stale for the next op
                    // (cleared at the same points as result_cap_valid_q).
                    compact_wb_q         <= 1'b0;
                    compact_scale_q[0]   <= 16'd0;
                    compact_scale_q[1]   <= 16'd0;
                    compact_payload_q    <= 128'd0;
                    scrd_wait_q          <= 1'b0;
                end

                default: ;
            endcase

            // [VEC-PIPE ⑥] phase flip + phase-boundary captures. Kept OUTSIDE
            // the case so no state arm can miss them. NOTE: when
            // scale_any_error/watchdog preempt ACTIVE during a compute phase,
            // lane_valid_q stays 1 for one cycle in the successor state — this
            // is intentional and harmless (every consumer is state-gated); do
            // NOT add lane_valid_q consumers outside VST_ACTIVE without a
            // state gate.
            // [C5][C8-b][C9-b][MC2][LANE2][MC2F] eight-phase rotor SEL -> MC
            // -> MC2 -> LANE -> LANE2 -> RENORM -> RENORM2 -> REDUCE -> SEL.
            // Leaving ACTIVE (or an L2_WB window re-entry) always restarts at
            // PH_SEL, so the select front is always re-sampled before the
            // multiply consumes it (identity: within a pass — and across the
            // L2_WB re-entry of the SAME window — pass_idx_q/caps/ctrl_q have
            // no write point, so the re-sampled value is bit-identical).
            if (state_q == VST_ACTIVE)
                active_phase_q <= (active_phase_q == PH_REDUCE) ? PH_SEL
                                                               : active_phase_q + 3'd1;
            else
                active_phase_q <= PH_SEL;

            // [MC2F] PH_SEL: register the SELECTED (window-muxed + unpacked)
            // operands and the correction controls for the multiply phase.
            // Written on EVERY PH_SEL visit; consumers gated by the no-skip
            // discipline (PH_MC only via PH_SEL).
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_SEL)) begin
                src0_sel_q <= src0_elems;
                src1_sel_q <= src1_elems;
                mc2f_corr_s0_q <= adapted_scale_src0.mant_corr;
                mc2f_corr_s1_q <= adapted_scale_src1.mant_corr;
                mc2f_precise_q <= e4m3_precise_lane;
            end
            // [C5] PH_MC: register the corrected operands for the next phase.
            // [MC2 2026-07-26] the alignment-control/negate writes moved to
            // PH_MC2 below — PH_MC now carries the multiply front ONLY
            // ([MC2F] the select head moved out to PH_SEL above).
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_MC)) begin
                src0_lane_q <= src0_prep;
                src1_lane_q <= src1_prep;
            end
            // [MC2] PH_MC2: register the alignment controls [C9] + the
            // op-adjusted src1 mantissa [T1b] from the REGISTERED operands.
            // Registered identity: src*_lane_q were loaded from src*_prep at
            // the PH_MC boundary and src*_prep's inputs + ctrl_q are HELD
            // within the pass, so f(src*_lane_q)@PH_MC2 == the old
            // f(src*_prep)@PH_MC bit-for-bit (identity assertion below pins
            // the load-source pair; C9/T1b shadow tripwires keep the consumer
            // side pinned during PH_LANE).
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_MC2)) begin
                for (int i = 0; i < VEC_LANES; i++) begin
                    {mc_shift_src1_q[i], mc_abs_diff_q[i]}
                        <= vec_lane_shift_ctrl(src0_lane_q[i], src1_lane_q[i]);
                    mc_eff_s1_q[i] <= (ctrl_q.lane_op == LANE_SUB)
                        ? -((VEC_MANT_W+1)'(signed'(src1_lane_q[i].mant)))
                        :  (VEC_MANT_W+1)'(signed'(src1_lane_q[i].mant));
                end
            end

            // [LANE2] PH_LANE boundary: register the alignment-front outputs
            // (the seam). Written on EVERY PH_LANE visit — consumers are gated
            // by the no-skip discipline (PH_LANE2 only via PH_LANE) + tokens.
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_LANE)) begin
                for (int i = 0; i < VEC_LANES; i++) begin
                    lane_align_q[i]  <= lane_align_d[i];
                    lane_sticky_q[i] <= lane_sticky_d[i];
                end
            end
            // [LANE2] token re-anchor: lane_results_q now lands at the
            // PH_LANE2 boundary; PH_LANE is a token-free seam phase (same
            // pattern as PH_MC/PH_MC2). Downstream q2/q3 hops unchanged.
            lane_valid_q <= (state_q == VST_ACTIVE) && (active_phase_q == PH_LANE2)
                            && lane_valid;
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_LANE2))
                lane_results_q <= lane_results;

            // [C8-b][C9-b] PH_RENORM boundary: register the renorm FRONT
            // (max/min tree) outputs; PH_RENORM2 boundary: register the renorm
            // BACK output (renorm_result_q). Both are written on EVERY visit
            // of their phase (valid or not) — consumers are all gated by the
            // piped tokens / PH_REDUCE latch predicates.
            lane_valid_q2 <= (state_q == VST_ACTIVE) && (active_phase_q == PH_RENORM)
                             && lane_valid_q;
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_RENORM)) begin
                rn_front_max_q    <= rn_front_max;
                rn_front_min_q    <= rn_front_min;
                rn_front_normal_q <= rn_front_normal;
                rn_front_nan_q    <= rn_front_nan;
                rn_front_inf_q    <= rn_front_inf;
                rn_front_ovf_q    <= rn_front_ovf;
            end
            lane_valid_q3 <= (state_q == VST_ACTIVE) && (active_phase_q == PH_RENORM2)
                             && lane_valid_q2;
            if ((state_q == VST_ACTIVE) && (active_phase_q == PH_RENORM2))
                renorm_result_q <= renorm_result;
        end
    end

    // =========================================================================
    // Completion Output (C1 fix: ERROR also fires done_o for credit return)
    //
    // done_o fires on both VST_DONE and VST_ERROR. This ensures the CP
    // scheduler always receives a completion event and can return the credit.
    // err_valid_o fires only on VST_ERROR (additional error information).
    // =========================================================================
    assign done_o     = (state_q == VST_DONE) || (state_q == VST_ERROR);
    assign done_ctx_o = ctrl_q.ctx_id;
    assign done_tag_o = ctrl_q.tag;

    // [HW-REVIEW T3-FF/FF3b-c, FOLD-6] err_valid_o also fires at the final VST_DONE of a
    // streaming op that was watchdog-degraded (degraded_q) — the credit still returns via
    // done_o, but the host learns the stream was truncated/degraded (no silent success).
    // degraded_q is 0 for every non-streaming op, so single-block behavior is unchanged.
    assign err_valid_o = (state_q == VST_ERROR) || (state_q == VST_DONE && degraded_q);
    assign err_code_o  = error_q;

    // =========================================================================
    // Performance Counters (17 × 32-bit saturating)
    // =========================================================================
    logic [PERF_CNT_W-1:0] perf_q [VEC_NUM_PERF_CNTS];

    generate
        for (genvar i = 0; i < VEC_NUM_PERF_CNTS; i++) begin : gen_perf_out
            assign perf_cnt_o[i] = perf_q[i];
        end
    endgenerate

    logic [VEC_NUM_PERF_CNTS-1:0] perf_inc;

    always_comb begin
        perf_inc = '0;

        perf_inc[VCNT_ISSUE]        = desc_valid_i && desc_ready_o;
        perf_inc[VCNT_BUSY_CYCLES]  = (state_q != VST_IDLE);
        perf_inc[VCNT_FASTPATH_IN]  = fp_ing_valid && fp_ing_ready;
        perf_inc[VCNT_FASTPATH_OUT] = fp_egr_accepted;
        perf_inc[VCNT_FASTPATH_MISS]= (arb_miss_valid && arb_miss_fpath) || t2v_miss_valid_o;
        perf_inc[VCNT_KEEP_LOCAL]   = (state_q == VST_L2_WB) && rw_gnt_i;
        perf_inc[VCNT_WRITEBACK]    = 1'b0;  // no cross-PE writeback yet

        // v2: escape counted when spill completes (L2_WB grant), not on detection
        perf_inc[VCNT_ESCAPE]       = (state_q == VST_L2_WB) && rw_gnt_i
                                    && result_escape_needed;

        perf_inc[VCNT_RENORM]       = (state_q == VST_DONE)
                                    && (ctrl_q.prim_id == VEC_RENORM);
        perf_inc[VCNT_REQUANT]      = 1'b0;

        perf_inc[VCNT_REDUCE_MAX]   = (state_q == VST_DONE)
                                    && (ctrl_q.prim_id == VEC_REDUCE_MAX);
        perf_inc[VCNT_REDUCE_SUM]   = (state_q == VST_DONE)
                                    && (ctrl_q.prim_id == VEC_REDUCE_SUM);

        perf_inc[VCNT_BLOCK16]      = (state_q == VST_DONE)
                                    && (ctrl_q.block_size == BLOCK_SIZE_16);
        perf_inc[VCNT_BLOCK32]      = (state_q == VST_DONE)
                                    && (ctrl_q.block_size == BLOCK_SIZE_32);

        perf_inc[VCNT_SCALE_E8M0]   = (state_q == VST_DONE)
                                    && (ctrl_q.scale_format == SCALE_E8M0);
        perf_inc[VCNT_SCALE_E4M3]   = (state_q == VST_DONE)
                                    && (ctrl_q.scale_format == SCALE_E4M3);

        perf_inc[VCNT_SCALE_STALL]  = (state_q inside {VST_WAIT_OP0, VST_WAIT_OP1})
                                    && !oq_pop_valid;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin                       // [STEP5 slang] async reset
            for (int i = 0; i < VEC_NUM_PERF_CNTS; i++)
                perf_q[i] <= '0;
        end else if (soft_reset_i) begin         // [STEP5 slang] sync soft-reset (mirror)
            for (int i = 0; i < VEC_NUM_PERF_CNTS; i++)
                perf_q[i] <= '0;
        end else if (perf_cnt_en_i) begin
            for (int i = 0; i < VEC_NUM_PERF_CNTS; i++) begin
                if (perf_inc[i])
                    perf_q[i] <= vec_sat_inc(perf_q[i]);
            end
        end
    end

    // =========================================================================
    // Simulation-Only Debug
    // =========================================================================
`ifndef SYNTHESIS
    // [VEC-PIPE ⑥] phase-discipline guards (vec_assertions.sv is not bound in
    // any gate, so these live inline). The second property is a strict subset
    // of the first — kept for readability, not counted as independent coverage.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && result_valid) |-> (active_phase_q == PH_REDUCE));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        fp_egr_valid |-> (active_phase_q == PH_REDUCE));

    // [C5] the operand pipeline register must always be loaded by PH_MC before
    // the add chain is captured in PH_LANE — i.e. a LANE phase is only ever
    // reached through an MC phase (the rotor never skips).
    // [C8-b] the `active_phase_q != 2'd3` tripwire is RETIRED: 2'd3 is now the
    // legal PH_REDUCE encoding. The no-skip discipline is instead pinned for
    // the two new arcs: RENORM only via LANE, REDUCE only via RENORM (so
    // renorm_result_q is always freshly written before PH_REDUCE consumes it,
    // the same always-written-first contract as the C3/C8-a PREP1 regs).
    // [MC2] the no-skip chain gains the MC->MC2 arc; LANE is now reachable
    // only via MC2 (which loaded mc_*_q the cycle before — the same
    // always-written-first contract, one phase later).
    // [LANE2] the chain gains the LANE->LANE2 arc: PH_LANE2 (whose arithmetic
    // back half consumes lane_align_q/lane_sticky_q) is reachable only via
    // PH_LANE (which loaded the seam the cycle before) — the seam is never
    // consumed stale; RENORM is now reachable only via LANE2.
    // [MC2F] the chain gains the SEL->MC arc: PH_MC (whose multiply consumes
    // src*_sel_q/mc2f_corr_*/mc2f_precise_q) is reachable only via PH_SEL
    // (which loaded the seam the cycle before) — the seam is never consumed
    // stale, including after any leave-ACTIVE restart.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_MC)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_SEL));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_MC2)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_MC));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_LANE)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_MC2));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_LANE2)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_LANE));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_RENORM)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_LANE2));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_RENORM2)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_RENORM));
    // [C9-b] REDUCE only via RENORM2 — renorm_result_q is always freshly
    // written (back half, from the registered front) before PH_REDUCE
    // consumes it; same always-written-first contract as C8-b.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_ACTIVE && active_phase_q == PH_REDUCE)
            |-> $past(state_q == VST_ACTIVE && active_phase_q == PH_RENORM2));

    // [C5] TWO structural tripwires for the correction-front move. Pre-C5 the
    // correction sat physically INSIDE vec_lane_array's LANE_ADD/LANE_SUB case
    // arm, which gave two free structural guarantees that the move gives up:
    //
    //  (1) even a mis-set e4m3_precise_i could not reach LANE_MAX/CLAMP/SIGN_INJ
    //      /... — they read src0_i/src1_i outside that arm. Now the corrected
    //      operand IS src*_i, so widening e4m3_precise_lane to another lane_op
    //      would silently feed every branch corrected mantissas.
    //  (2) vec_lane_array's default-assignment block (:144-151) sources
    //      result_o.sign from src0_i.sign; the NaN sub-branch of LANE_ADD/SUB
    //      does NOT overwrite .sign, so post-move that fall-through carries the
    //      CORRECTED sign instead of the raw one.
    //
    // Both are provably inert TODAY: vec_scale_adapter only ever emits
    // mant_corr ∈ [128,240] (≥ 1.0) and vec_mant_corr_mul cannot saturate in the
    // 17-bit domain (max |product| = 32768*1.875 = 61440 < 65536), so a normal
    // operand keeps |corrected| ≥ |raw| ≥ 1 and renorm17 (>>1) preserves the MSB
    // ⇒ es.sign ≡ src.sign; zero/NaN/Inf operands are skipped by the prep's own
    // guard. Assert exactly those two premises so the day either one changes the
    // gate goes RED instead of drifting silently (RED-2 discipline).
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        e4m3_precise_lane |-> (ctrl_q.lane_op inside {LANE_ADD, LANE_SUB}));

    // [MC2F] comparison basis moved to the REGISTERED seam (review R4 pinned:
    // ungated + sel_q basis — prep is now f(src*_sel_q), so "prep does not
    // flip the sign of its REGISTERED input" is data-independent and holds
    // every cycle, including stale-sel windows after DONE; an elems basis
    // would false-fire whenever elems moves on while sel_q holds).
    logic c5_prep_sign_ok;
    always_comb begin
        c5_prep_sign_ok = 1'b1;
        for (int i = 0; i < VEC_LANES; i++) begin
            if ((src0_prep[i].sign != src0_sel_q[i].sign)
             || (src1_prep[i].sign != src1_sel_q[i].sign))
                c5_prep_sign_ok = 1'b0;
        end
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni) c5_prep_sign_ok);

    // [MC2F] correction-control seam identity (the §0.4 bypass leg): during
    // PH_MC the PH_SEL-registered controls must equal the live decode —
    // adapted_scale_src*/ctrl_q are HELD within the pass (same contract as
    // the per-lane select-seam tripwire in gen_c9_shadow below).
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        ((state_q == VST_ACTIVE) && (active_phase_q == PH_MC)) |->
        ((mc2f_corr_s0_q == adapted_scale_src0.mant_corr)
         && (mc2f_corr_s1_q == adapted_scale_src1.mant_corr)
         && (mc2f_precise_q == e4m3_precise_lane)))
        else $error("[MC2F] correction-control seam identity mismatch");

    // [C-MX ⑦ C3][T1] value-preservation tripwire for the requant-bank split:
    // VST_CMX_PREP (where compact_payload_q/compact_scale_q are latched from
    // the per-lane ENCODE using the cmx_al_*_q align products) is reachable
    // ONLY from VST_CMX_PREP2 (which loaded cmx_al_*_q the cycle before) — the
    // align products are never read unregistered/stale. (This tripwire fired
    // during the T1 surgery itself when PREP2 was inserted before it was
    // updated — teeth proven, 2026-07-26.)
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_CMX_PREP) |-> $past(state_q == VST_CMX_PREP2));

    // [T1] same contract one stage earlier: PREP2 (whose back-align reads
    // cmx_shared_exp_q) is reachable ONLY from PREP1 (which loaded it the
    // cycle before) — the C3 shared-exp never-stale guarantee transfers to
    // the align stage.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_CMX_PREP2) |-> $past(state_q == VST_CMX_PREP1));

    // [C8-c] same always-written-first contract one stage earlier: PREP1
    // (whose max tree reads cmx_eff_q/cmx_nz_q) is reachable ONLY from PREP0
    // (which loaded them the cycle before) — the front regs are never read
    // stale. RED-2 tripwire for the C8-c retiming.
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (state_q == VST_CMX_PREP1) |-> $past(state_q == VST_CMX_PREP0));

    // [C9 V4] front_q equivalence shadow tripwire: during PH_LANE the
    // registered shift controls must equal what the lane array's in-place
    // fallback would compute from the REGISTERED operands (both sides are
    // vec_pkg::vec_lane_shift_ctrl — this pins the §C5 es0/es1-hoist RED-2
    // drift trap: any future edit that changes WHICH operands feed either
    // side breaks the identity and fires here).
    generate
        for (genvar gt = 0; gt < VEC_LANES; gt++) begin : gen_c9_shadow
            // [MC2F] select-seam identity tripwire (live compare, MC2 :3029
            // same pattern): during PH_MC the PH_SEL-registered operands must
            // equal the LIVE unpack outputs — the select-cone inputs
            // (pass_idx_q/caps/loaded_q/ctrl_q/adapted_scale) are HELD within
            // the pass, so any drift (a new mid-pass write point, a HELD-set
            // violation) fires here. No leaf function migrated (the unpack
            // mux stays the single live source feeding this register), so the
            // live compare IS the full-strength shadow; the synthesis-side
            // attack surface is owned by the §3 struct-gate dead-arc probes.
            assert property (@(posedge clk_i) disable iff (!rst_ni)
                ((state_q == VST_ACTIVE) && (active_phase_q == PH_MC)) |->
                ((src0_sel_q[gt] == src0_elems[gt])
                 && (src1_sel_q[gt] == src1_elems[gt])))
                else $error("[MC2F] select-seam identity mismatch lane %0d", gt);
            // [MC2] operand-hold identity: the operands registered at the
            // PH_MC boundary still equal the LIVE prep outputs during PH_MC2
            // (prep inputs + ctrl_q HELD within the pass) — restores an
            // INDEPENDENT compute pair after the mc_*_q load source moved to
            // src*_lane_q (review MC2-3: post-move the C9/T1b shadows below
            // compare same-source terms, so alone they no longer pin the C5
            // es-hoist drift trap). [MC2F] RHS semantic note: src*_prep is
            // now f(src*_sel_q, mc2f_corr_*, mc2f_precise_q) — this identity
            // guards the SEL-seam->MC-boundary hop; the SEL seam itself is
            // pinned by the [MC2F] tripwire above (guard chain re-anchored).
            assert property (@(posedge clk_i) disable iff (!rst_ni)
                ((state_q == VST_ACTIVE) && (active_phase_q == PH_MC2)) |->
                ((src0_lane_q[gt] == src0_prep[gt])
                 && (src1_lane_q[gt] == src1_prep[gt])))
                else $error("[MC2] operand-hold identity mismatch lane %0d", gt);
            // [LANE2] mc_*_q are now consumed in BOTH PH_LANE (the align
            // front) and PH_LANE2 (assemble/res_exp) — the shadow pin extends
            // to both phases (values HELD, so the identity must keep holding).
            assert property (@(posedge clk_i) disable iff (!rst_ni)
                ((state_q == VST_ACTIVE)
                 && ((active_phase_q == PH_LANE)
                     || (active_phase_q == PH_LANE2))) |->
                ({mc_shift_src1_q[gt], mc_abs_diff_q[gt]} ==
                 vec_lane_shift_ctrl(src0_lane_q[gt], src1_lane_q[gt])))
                else $error("[C9] shift-ctrl shadow mismatch lane %0d", gt);
            // [T1b] negate pre-application shadow tripwire: the registered
            // op-adjusted mantissa must equal the negate recomputed from the
            // REGISTERED operand + the held lane_op — pins the same hoist
            // drift trap for the eff_src1_mant cut.
            assert property (@(posedge clk_i) disable iff (!rst_ni)
                ((state_q == VST_ACTIVE)
                 && ((active_phase_q == PH_LANE)
                     || (active_phase_q == PH_LANE2))) |->
                (mc_eff_s1_q[gt] ==
                 ((ctrl_q.lane_op == LANE_SUB)
                    ? -((VEC_MANT_W+1)'(signed'(src1_lane_q[gt].mant)))
                    :  (VEC_MANT_W+1)'(signed'(src1_lane_q[gt].mant)))))
                else $error("[T1b] eff-src1 shadow mismatch lane %0d", gt);

            // [LANE2] align-seam freshness shadow: a DEDICATED second
            // vec_lane_align instance whose inputs are pulled straight from
            // the HELD registers — deliberately NOT referencing the datapath
            // gen_ph_align/u_ph_align hierarchy, so a mis-wired datapath
            // instance cannot satisfy this check by construction (review
            // GK-3: the MC2-3 same-source-degeneration lesson, third-offense
            // defense). During PH_LANE2 the registered seam must equal the
            // recompute from the held sources. CATCHES: PH_LANE write
            // missing/stale + datapath align instance input mis-wiring.
            // CANNOT catch: the array not consuming the ext seam — that is
            // the seam-level mutation red + struct GATE-1/2 territory
            // (LANE2_Preflight §7-5).
            logic signed [VEC_SHIFT_WIDTH-1:0] lane2_shadow_so;
            logic                              lane2_shadow_sk;
            vec_lane_align u_lane2_shadow (
                .es0_mant_i      ( src0_lane_q[gt].mant ),
                .eff_src1_mant_i ( mc_eff_s1_q[gt]      ),
                .shift_src1_i    ( mc_shift_src1_q[gt]  ),
                .abs_diff_i      ( mc_abs_diff_q[gt]    ),
                .shift_out_o     ( lane2_shadow_so      ),
                .sticky_o        ( lane2_shadow_sk      )
            );
            assert property (@(posedge clk_i) disable iff (!rst_ni)
                ((state_q == VST_ACTIVE) && (active_phase_q == PH_LANE2)) |->
                ((lane_align_q[gt] == lane2_shadow_so)
                 && (lane_sticky_q[gt] == lane2_shadow_sk)))
                else $error("[LANE2] align-seam freshness mismatch lane %0d", gt);
        end
    endgenerate

    // [S-STAT v1.2 A1] (prereg §70.2 / §74.1.2): on the product path every
    // contributing REDUCE_STAT lane carries the block exponent, so the
    // exponent span of contributing lanes is <= 2 (renorm17 +/-1 headroom).
    // span <= 2 implies e_i >= G - 17 for every lane (P3), i.e. the 40-bit
    // window of vec_reduce_cluster is inert and the pass sum is exact. Same
    // gating as u_reduce.valid_i.
    logic stat_a1_span_ok;
    always_comb begin
        logic                        any;
        logic signed [VEC_EXP_W+1:0] emax, emin;
        any  = 1'b0;
        emax = '0;
        emin = '0;
        for (int i = 0; i < VEC_LANES; i++) begin
            if (!(lane_results_q[i].is_zero || (lane_results_q[i].mant == '0)
                  || lane_results_q[i].is_nan || lane_results_q[i].is_inf)) begin
                if (!any || ((VEC_EXP_W+2)'(signed'(lane_results_q[i].exp)) > emax))
                    emax = (VEC_EXP_W+2)'(signed'(lane_results_q[i].exp));
                if (!any || ((VEC_EXP_W+2)'(signed'(lane_results_q[i].exp)) < emin))
                    emin = (VEC_EXP_W+2)'(signed'(lane_results_q[i].exp));
                any = 1'b1;
            end
        end
        stat_a1_span_ok = !any || ((emax - emin) <= (VEC_EXP_W+2)'(2));
    end
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        (lane_valid_q3 && ctrl_q.reduce_en && (ctrl_q.reduce_mode == REDUCE_STAT))
            |-> stat_a1_span_ok)
        else $error("[S-STAT A1] contributing REDUCE_STAT lanes span more than 2 exponents");

    always_ff @(posedge clk_i) begin
        if (rst_ni && !soft_reset_i) begin
            if (state_q == VST_DONE)
                $display("[vector_unit] Op complete: prim=%s ctx=%0d tag=%0d fpath=%0b pass=%0d",
                         ctrl_q.prim_id.name(), ctrl_q.ctx_id, ctrl_q.tag,
                         fp_egr_accepted, num_passes_q);
            if (state_q == VST_ERROR)
                $display("[vector_unit] Error+Done: code=%s ctx=%0d tag=%0d",
                         error_q.name(), ctrl_q.ctx_id, ctrl_q.tag);
        end
    end
`endif

endmodule

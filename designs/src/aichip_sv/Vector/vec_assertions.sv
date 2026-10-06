// =============================================================================
// vec_assertions.sv — SystemVerilog Assertions for Vector Unit
//
// Bind module: attached to vector_unit via `bind` statement (see bottom).
// Covers all critical behavioral contracts for the Vector Unit datapath,
// control FSM, fast path protocol, and performance counters.
//
// v6.0 Round 4 additions (6 new asserts + 4 new covers):
//   §V.22  no_premature_watchdog       — Bug #1 regression guard
//   §V.23  l2_wb_writes_latched_payload — Bug #2 verification
//   §V.24  lane_only_b32_w0_uses_partial — Bug #4 verification
//   §V.25  scale_error_routes_to_error  — 3a scale-decode strict routing
//   §V.26  role_misorder_uses_new_code  — 3a VERR code rename
//   §V.27  egress_window_advance_timing — Bug #6 timing correctness
//
//   §V.28  cover_scale_error_fired               — VERR_SCALE_DECODE exercised
//   §V.29  cover_role_misorder_fired             — VERR_ROLE_MISORDER exercised
//   §V.30  cover_b32_dual_egress_l2_fallback     — Bug #6 critical path hit
//   §V.31  cover_b32_lane_only_pass0_latch       — Bug #4 latch event hit
//
//   Note: REDUCE_STAT 40-bit cross-pass combine correctness is verified by
//   end-to-end TB numerical comparison rather than RTL assertion (Round 4
//   decision #1: assertions are for invariants, not arithmetic equality).
//
// v2 changes from v1:
//   - §V.1:  ACTIVE can self-loop (multi-pass)
//   - §V.3b: Scale passthrough assertion (non-renorm paths preserve scale)
//   - §V.7:  done_o fires on DONE and ERROR (credit return on both)
//   - §V.9:  Soft reset clears multi-pass registers
//   - §V.10: New cover points for multi-pass, escape→L2_WB, operand role
//   - §V.11: Operand role dispatch assertions
//   - §V.12: Dual scale independence assertion
//   - §V.13: Multi-pass bounds assertions
//   - §V.14: Escape → L2_WB (not direct DONE) assertion
//   - §V.15: scale_inline_valid gating assertion
//
// Assertion sections:
//   §V.1  FSM Legal Transitions
//   §V.2  Descriptor Gate: block_size / scale_format
//   §V.3  Capsule Identity / Scale Preservation
//   §V.4  Fast Path Eligibility Constraints
//   §V.5  Operand Queue Invariants
//   §V.6  Result Packer Field Completeness
//   §V.7  Completion / Done / Error Correctness
//   §V.8  Performance Counter Monotonicity & Saturation
//   §V.9  Soft Reset Completeness
//   §V.10 Functional Coverage
//   §V.11 Operand Role Dispatch
//   §V.12 Dual Scale Independence
//   §V.13 Multi-Pass Bounds
//   §V.14 Escape Path Routing
//   §V.15 Scale Inline Valid Gating
//   §V.16-V.21  CL-1 through CL-10 internal closure checks
//   §V.22-V.27  v6.0 Round 4 asserts
//   §V.28-V.31  v6.0 Round 4 cover points
//
// Simulation only — all assertions gated by `ifndef SYNTHESIS`.
//
// Author:  H-Tensor Project
// Version: 6.0 (Round 4 — v6.0 assert + cover additions)
// =============================================================================

`ifndef SYNTHESIS

module vec_assertions
    import pe_pkg::*;
    import vec_pkg::*;
(
    input logic         clk_i,
    input logic         rst_ni,
    input logic         soft_reset_i,

    // ── FSM state ──
    // [REVIVE 2026-07-24] was [2:0] — vector_unit's vec_state_e is 4-bit
    // (13 states, VST_CMX_PREP1=12). The 3-bit ports silently truncated
    // (VST_CMX_PREP=11 → 3 = "ACTIVE"), so every state-conditioned property
    // was checking the wrong state. HANDOFF_2026-07-24 §7 既有缺口.
    input logic [3:0]   state_q,
    input logic [3:0]   state_d,

    // ── Descriptor interface ──
    input logic         desc_valid_i,
    input logic         desc_ready_o,

    // ── Latched control ──
    input vec_ctrl_t    ctrl_q,
    input vec_error_e   error_q,

    // ── Multi-pass state (v2) ──
    input logic [1:0]   pass_idx_q,
    input logic [1:0]   num_passes_q,
    input logic         last_pass,
    input logic         sub_count_q,
    input logic [15:0]  dst_ref_q,

    // ── Operand state ──
    input logic         src0_loaded_q,
    input logic         src1_loaded_q,

    // ── Operand role dispatch (v2) ──
    input logic         role_match,
    input logic         oq_pop_ready,
    input logic         oq_pop_valid,
    input bs_capsule_t  oq_pop_cap,

    // ── Operand queue ──
    input logic         oq_full,
    input logic         oq_empty,
    input logic [$clog2(VEC_OQ_DEPTH):0] oq_count,

    // ── Fast path ingress ──
    input logic             t2v_valid,
    input logic             t2v_ready,
    input logic             t2v_miss_valid,
    input fp_miss_reason_e  t2v_miss_reason,

    // ── Fast path egress ──
    input logic             v2t_valid,
    input logic             v2t_ready,
    input logic             fp_egr_accepted,
    input logic             fp_egr_rejected,

    // ── Result packer ──
    input logic             result_valid,
    input logic             result_escape_needed,
    input bs_capsule_t      result_capsule,

    // ── Active capsules (v2) ──
    input bs_capsule_t      active_src0_cap,

    // ── Completion ──
    input logic             done_o,
    input logic [1:0]       done_ctx_o,
    input logic [TAG_W-1:0] done_tag_o,
    input logic             err_valid_o,

    // ── Perf counters ──
    input logic [PERF_CNT_W-1:0] perf_q [VEC_NUM_PERF_CNTS],
    input logic                  perf_cnt_en,

    // ── v2.1: CL-3/CL-4/CL-8 signals ──
    input logic                  egress_window_q,      // CL-3: dual-capsule egress window
    input logic                  role_stall_timeout,    // CL-4: role HOL stall timeout
    input logic                  watchdog_timeout,      // CL-8: active state watchdog

    // ── v6.0 Round 3a/3b: signals observed by §V.22-V.31 ──
    input logic                  scale_any_error,       // R3a: scale decode error aggregate
    input logic                  result_cap_valid_q,    // R3a: latched result capsule valid
    input logic                  partial_lane_valid_q,  // R3b: lane-only pass-0 latch valid
    input logic                  block32_dual_egress,   // R3b: convenience — dual-egress gate
    input logic                  rw_gnt_i,              // R3b: L2 write-grant (Bug #6 timing)
    input logic                  fp_egr_valid           // R3b: egress offer
    // [N16] removed duplicate `last_pass` input — already declared above (~L88).
    // The frozen Vector bind snapshot listed it twice; strict SV/Verilator reject it.
);

    // =========================================================================
    // Local aliases for FSM state encoding
    //
    // [REVIVE 2026-07-24] widened to 4-bit + the six states the FSM gained
    // since v6.0 (streaming blocks + ⑦ compact store + C3 split stage).
    // MUST mirror vector_unit.sv vec_state_e (declared module-local there,
    // so a bind module cannot import it — keep this table in sync).
    // =========================================================================
    localparam bit [3:0] S_IDLE      = 4'd0;
    localparam bit [3:0] S_WAIT_OP0  = 4'd1;
    localparam bit [3:0] S_WAIT_OP1  = 4'd2;
    localparam bit [3:0] S_ACTIVE    = 4'd3;
    localparam bit [3:0] S_L2_WB     = 4'd4;
    localparam bit [3:0] S_DONE      = 4'd5;
    localparam bit [3:0] S_ERROR     = 4'd6;
    localparam bit [3:0] S_BLK_NEXT  = 4'd7;
    localparam bit [3:0] S_BLK_SETUP = 4'd8;
    localparam bit [3:0] S_SCRD      = 4'd9;
    localparam bit [3:0] S_SCWB      = 4'd10;
    localparam bit [3:0] S_CMX_PREP  = 4'd11;
    localparam bit [3:0] S_CMX_PREP1 = 4'd12;
    localparam bit [3:0] S_CMX_PREP0 = 4'd13;   // [C8-c] leading front stage
    localparam bit [3:0] S_CMX_PREP2 = 4'd14;   // [T1] back-align stage (PREP1->PREP2->PREP)

    // =========================================================================
    // §V.1 FSM Legal Transitions
    //
    // [REVIVE 2026-07-24] rewritten against the CURRENT 13-state FSM
    // (vector_unit.sv state_d always_comb, :1706-1884): streaming blocks
    // (BLK_NEXT/BLK_SETUP), ⑦ compact store (CMX_PREP1→CMX_PREP→L2_WB,
    // SCRD→SCWB sidecar RMW). IDLE is allowed in every exit set: soft_reset
    // forces IDLE while the property is disabled, and the first enabled
    // sample would otherwise read as an illegal arc.
    // v2 note kept: ACTIVE self-loops for multi-pass/phases/egress windows.
    // =========================================================================

    property fsm_idle_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_IDLE && state_q != S_IDLE)
        |-> (state_q inside {S_WAIT_OP0, S_BLK_SETUP, S_ERROR});
    endproperty
    a_fsm_idle: assert property (fsm_idle_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from IDLE to state %0d", state_q);

    property fsm_wait_op0_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_WAIT_OP0 && state_q != S_WAIT_OP0)
        |-> (state_q inside {S_WAIT_OP1, S_ACTIVE, S_ERROR, S_IDLE});
    endproperty
    a_fsm_wait_op0: assert property (fsm_wait_op0_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from WAIT_OP0 to state %0d", state_q);

    property fsm_wait_op1_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_WAIT_OP1 && state_q != S_WAIT_OP1)
        |-> (state_q inside {S_ACTIVE, S_ERROR, S_IDLE});
    endproperty
    a_fsm_wait_op1: assert property (fsm_wait_op1_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from WAIT_OP1 to state %0d", state_q);

    // ACTIVE exits: DONE (fast-path egress done) / BLK_NEXT (streaming, more
    // blocks) / L2_WB (escape or non-compact spill) / CMX_PREP0 (⑦ compact
    // spill, both watchdog and normal arms — [C8-c] the 2-stage leading split
    // now enters at PREP0; a direct ACTIVE→PREP1 is ILLEGAL) / ERROR.
    property fsm_active_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_ACTIVE && state_q != S_ACTIVE)
        |-> (state_q inside {S_DONE, S_BLK_NEXT, S_L2_WB, S_CMX_PREP0, S_ERROR, S_IDLE});
    endproperty
    a_fsm_active: assert property (fsm_active_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from ACTIVE to state %0d", state_q);

    // L2_WB exits: ACTIVE (block32 second window) / SCRD (compact sidecar
    // RMW) / BLK_NEXT (streaming) / DONE / ERROR (streaming write-stall).
    property fsm_l2wb_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_L2_WB && state_q != S_L2_WB)
        |-> (state_q inside {S_ACTIVE, S_SCRD, S_BLK_NEXT, S_DONE, S_ERROR, S_IDLE});
    endproperty
    a_fsm_l2wb: assert property (fsm_l2wb_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from L2_WB to state %0d", state_q);

    property fsm_blk_next_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_BLK_NEXT)
        |-> (state_q inside {S_BLK_SETUP, S_IDLE});
    endproperty
    a_fsm_blk_next: assert property (fsm_blk_next_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from BLK_NEXT to state %0d", state_q);

    property fsm_blk_setup_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_BLK_SETUP && state_q != S_BLK_SETUP)
        |-> (state_q inside {S_WAIT_OP0, S_ERROR, S_IDLE});
    endproperty
    a_fsm_blk_setup: assert property (fsm_blk_setup_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from BLK_SETUP to state %0d", state_q);

    // ⑦/C3/C8-c/T1 split requantize chain: PREP0 → PREP1 → PREP2 → PREP →
    // L2_WB, all unconditional.
    property fsm_cmx_prep0_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_CMX_PREP0)
        |-> (state_q inside {S_CMX_PREP1, S_IDLE});
    endproperty
    a_fsm_cmx_prep0: assert property (fsm_cmx_prep0_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from CMX_PREP0 to state %0d", state_q);

    property fsm_cmx_prep1_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_CMX_PREP1)
        |-> (state_q inside {S_CMX_PREP2, S_IDLE});
    endproperty
    a_fsm_cmx_prep1: assert property (fsm_cmx_prep1_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from CMX_PREP1 to state %0d", state_q);

    property fsm_cmx_prep2_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_CMX_PREP2)
        |-> (state_q inside {S_CMX_PREP, S_IDLE});
    endproperty
    a_fsm_cmx_prep2: assert property (fsm_cmx_prep2_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from CMX_PREP2 to state %0d", state_q);

    property fsm_cmx_prep_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_CMX_PREP)
        |-> (state_q inside {S_L2_WB, S_IDLE});
    endproperty
    a_fsm_cmx_prep: assert property (fsm_cmx_prep_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from CMX_PREP to state %0d", state_q);

    property fsm_scrd_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_SCRD && state_q != S_SCRD)
        |-> (state_q inside {S_SCWB, S_IDLE});
    endproperty
    a_fsm_scrd: assert property (fsm_scrd_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from SCRD to state %0d", state_q);

    property fsm_scwb_exits;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_SCWB && state_q != S_SCWB)
        |-> (state_q inside {S_BLK_NEXT, S_DONE, S_IDLE});
    endproperty
    a_fsm_scwb: assert property (fsm_scwb_exits)
        else $error("[VEC_ASSERT §V.1] Illegal exit from SCWB to state %0d", state_q);

    property fsm_done_returns_idle;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_DONE) |-> (state_q == S_IDLE);
    endproperty
    a_fsm_done: assert property (fsm_done_returns_idle)
        else $error("[VEC_ASSERT §V.1] DONE did not return to IDLE");

    property fsm_error_returns_idle;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_ERROR) |-> (state_q == S_IDLE);
    endproperty
    a_fsm_error: assert property (fsm_error_returns_idle)
        else $error("[VEC_ASSERT §V.1] ERROR did not return to IDLE");

    // =========================================================================
    // §V.2 Descriptor Gate: block_size / scale_format
    // =========================================================================

    property desc_accepted_valid_block_size;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_IDLE && state_q == S_WAIT_OP0)
        |-> ($past(desc_valid_i) &&
             (ctrl_q.block_size inside {BLOCK_SIZE_16, BLOCK_SIZE_32}));
    endproperty
    a_desc_bs: assert property (desc_accepted_valid_block_size)
        else $error("[VEC_ASSERT §V.2] Accepted descriptor with invalid block_size");

    property desc_accepted_valid_scale_format;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_IDLE && state_q == S_WAIT_OP0)
        |-> (ctrl_q.scale_format inside {SCALE_E8M0, SCALE_E4M3, SCALE_NONE});
    endproperty
    a_desc_sf: assert property (desc_accepted_valid_scale_format)
        else $error("[VEC_ASSERT §V.2] Accepted descriptor with invalid scale_format");

    // =========================================================================
    // §V.3 Capsule Identity / Scale Preservation
    //
    // (a) ctx_id and tag in result capsule must match latched ctrl_q
    // (b) Non-renorm paths must preserve src0 inline_scale (B3 fix)
    // =========================================================================

    property result_capsule_ctx_preserved;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid)
        |-> (result_capsule.ctx_id == ctrl_q.ctx_id);
    endproperty
    a_ctx_preserve: assert property (result_capsule_ctx_preserved)
        else $error("[VEC_ASSERT §V.3a] Result capsule ctx_id mismatch");

    property result_capsule_tag_preserved;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid)
        |-> (result_capsule.tag == ctrl_q.tag);
    endproperty
    a_tag_preserve: assert property (result_capsule_tag_preserved)
        else $error("[VEC_ASSERT §V.3a] Result capsule tag mismatch");

    // B3 fix: non-renorm output capsule must carry src0's inline_scale
    property scale_passthrough_non_renorm;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid && !ctrl_q.renorm_en)
        |-> (result_capsule.inline_scale == active_src0_cap.inline_scale &&
             result_capsule.scale_inline_valid == active_src0_cap.scale_inline_valid);
    endproperty
    a_scale_passthrough: assert property (scale_passthrough_non_renorm)
        else $error("[VEC_ASSERT §V.3b] Non-renorm path did not preserve src0 inline_scale");

    // =========================================================================
    // §V.4 Fast Path Eligibility Constraints
    // =========================================================================

    property egress_fwd_eligible;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        v2t_valid |-> result_capsule.fwd_eligible;
    endproperty
    a_egr_fwd: assert property (egress_fwd_eligible)
        else $error("[VEC_ASSERT §V.4a] Egress with fwd_eligible=0");

    property egress_no_multi_consumer;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        v2t_valid |-> !result_capsule.multi_consumer;
    endproperty
    a_egr_mc: assert property (egress_no_multi_consumer)
        else $error("[VEC_ASSERT §V.4b] Egress with multi_consumer=1");

    // [REVIVE 2026-07-24] the v1 form `(t2v_valid && !t2v_ready) |-> miss_valid`
    // conflated REJECTION with BACKPRESSURE. The fastpath contract
    // (vec_fastpath_if.sv:171,177) is: miss fires only on the eligibility
    // pre-check failing (`!ing_pre_ok`); an eligible offer under downstream
    // backpressure (`!ing_ready_i`) legitimately holds with ready=0, miss=0 —
    // the streaming benches hit this on their first offer. First fired (and
    // was triaged as assertion-stale) in test_vec_resadd_stream.
    // Kept invariant: miss and a stalled-but-pending offer are consistent —
    // miss may only fire while an offer is actually being refused.
    property ingress_miss_consistent;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        t2v_miss_valid |-> (t2v_valid && !t2v_ready);
    endproperty
    a_ing_miss: assert property (ingress_miss_consistent)
        else $error("[VEC_ASSERT §V.4c] miss_valid without a refused ingress offer");

    // =========================================================================
    // §V.5 Operand Queue Invariants
    // =========================================================================

    property oq_count_bounded;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        oq_count <= ($clog2(VEC_OQ_DEPTH)+1)'(VEC_OQ_DEPTH);
    endproperty
    a_oq_count: assert property (oq_count_bounded)
        else $error("[VEC_ASSERT §V.5a] Queue count %0d > DEPTH %0d",
                    oq_count, VEC_OQ_DEPTH);

    property oq_full_consistent;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        oq_full |-> (oq_count == ($clog2(VEC_OQ_DEPTH)+1)'(VEC_OQ_DEPTH));
    endproperty
    a_oq_full: assert property (oq_full_consistent)
        else $error("[VEC_ASSERT §V.5b] Queue full but count=%0d", oq_count);

    property oq_empty_consistent;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        oq_empty |-> (oq_count == '0);
    endproperty
    a_oq_empty: assert property (oq_empty_consistent)
        else $error("[VEC_ASSERT §V.5b] Queue empty but count=%0d", oq_count);

    // =========================================================================
    // §V.6 Result Packer Field Completeness
    // =========================================================================

    property result_producer_domain;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid)
        |-> (result_capsule.producer == DOMAIN_VECTOR);
    endproperty
    a_result_domain: assert property (result_producer_domain)
        else $error("[VEC_ASSERT §V.6a] Result capsule producer != DOMAIN_VECTOR");

    property result_block_size_valid;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid)
        |-> (result_capsule.block_size inside {BLOCK_SIZE_16, BLOCK_SIZE_32});
    endproperty
    a_result_bs: assert property (result_block_size_valid)
        else $error("[VEC_ASSERT §V.6b] Result capsule has invalid block_size");

    // v2: result operand_role must be OP_SRC0
    property result_operand_role;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid)
        |-> (result_capsule.operand_role == OP_SRC0);
    endproperty
    a_result_role: assert property (result_operand_role)
        else $error("[VEC_ASSERT §V.6c] Result capsule operand_role != OP_SRC0");

    // =========================================================================
    // §V.7 Completion / Done / Error Correctness
    //
    // v2: done_o fires on DONE and ERROR (credit return on both paths).
    //   (a) done_o fires only in DONE or ERROR state
    //   (b) done_ctx/tag match ctrl_q
    //   (c) err_valid fires only in ERROR state
    //   (d) On ERROR: both done_o AND err_valid must be asserted (co-assertion)
    // =========================================================================

    // v2: done_o allowed in both DONE and ERROR
    property done_in_done_or_error;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        done_o |-> (state_q inside {S_DONE, S_ERROR});
    endproperty
    a_done_state: assert property (done_in_done_or_error)
        else $error("[VEC_ASSERT §V.7a] done_o asserted outside DONE/ERROR (state=%0d)", state_q);

    property done_ctx_matches;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        done_o |-> (done_ctx_o == ctrl_q.ctx_id);
    endproperty
    a_done_ctx: assert property (done_ctx_matches)
        else $error("[VEC_ASSERT §V.7b] done_ctx mismatch");

    property done_tag_matches;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        done_o |-> (done_tag_o == ctrl_q.tag);
    endproperty
    a_done_tag: assert property (done_tag_matches)
        else $error("[VEC_ASSERT §V.7b] done_tag mismatch");

    // [REVIVE 2026-07-24] was `state_q == S_ERROR` — stale: FOLD-6 made
    // err_valid_o ALSO fire at the final VST_DONE of a watchdog-degraded
    // streaming op (vector_unit.sv err_valid_o decode).
    property err_only_in_error_state;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        err_valid_o |-> (state_q inside {S_ERROR, S_DONE});
    endproperty
    a_err_state: assert property (err_only_in_error_state)
        else $error("[VEC_ASSERT §V.7c] err_valid asserted outside VST_ERROR/degraded-DONE");

    // v2: ERROR must fire BOTH done_o and err_valid_o (credit return + error report)
    property error_fires_done;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ERROR) |-> (done_o && err_valid_o);
    endproperty
    a_err_done: assert property (error_fires_done)
        else $error("[VEC_ASSERT §V.7d] VST_ERROR: done_o and err_valid_o must both be 1");

    // =========================================================================
    // §V.8 Performance Counter Monotonicity & Saturation
    // =========================================================================

    generate
        for (genvar ci = 0; ci < VEC_NUM_PERF_CNTS; ci++) begin : gen_perf_mono

            property perf_monotonic;
                @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
                perf_cnt_en |-> (perf_q[ci] >= $past(perf_q[ci]));
            endproperty
            a_perf_mono: assert property (perf_monotonic)
                else $error("[VEC_ASSERT §V.8] Counter[%0d] decreased", ci);

            property perf_saturate;
                @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
                (&$past(perf_q[ci])) |-> (&perf_q[ci]);
            endproperty
            a_perf_sat: assert property (perf_saturate)
                else $error("[VEC_ASSERT §V.8] Counter[%0d] wrapped past saturation", ci);

        end
    endgenerate

    // =========================================================================
    // §V.9 Soft Reset Completeness
    //
    // v2: also clears multi-pass registers (pass_idx_q, num_passes_q).
    // =========================================================================

    property soft_reset_returns_idle;
        @(posedge clk_i) disable iff (!rst_ni)
        soft_reset_i |=> (state_q == S_IDLE);
    endproperty
    a_srst_idle: assert property (soft_reset_returns_idle)
        else $error("[VEC_ASSERT §V.9] State not IDLE after soft_reset");

    property soft_reset_clears_operands;
        @(posedge clk_i) disable iff (!rst_ni)
        soft_reset_i |=> (!src0_loaded_q && !src1_loaded_q);
    endproperty
    a_srst_ops: assert property (soft_reset_clears_operands)
        else $error("[VEC_ASSERT §V.9] Operands not cleared after soft_reset");

    property soft_reset_clears_pass;
        @(posedge clk_i) disable iff (!rst_ni)
        soft_reset_i |=> (pass_idx_q == 2'd0);
    endproperty
    a_srst_pass: assert property (soft_reset_clears_pass)
        else $error("[VEC_ASSERT §V.9] pass_idx_q not cleared after soft_reset");

    // =========================================================================
    // §V.10 Functional Coverage
    // =========================================================================

    c_fpath_accept: cover property (
        @(posedge clk_i) disable iff (!rst_ni) t2v_valid && t2v_ready);

    c_fpath_egress: cover property (
        @(posedge clk_i) disable iff (!rst_ni) fp_egr_accepted);

    c_fpath_miss: cover property (
        @(posedge clk_i) disable iff (!rst_ni) t2v_miss_valid);

    c_l2_wb: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        $past(state_q) == S_L2_WB && state_q == S_DONE);

    // v2: escape → L2_WB (not direct DONE)
    c_escape_to_l2wb: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        $past(state_q) == S_ACTIVE && state_q == S_L2_WB && result_escape_needed);

    c_dual_op: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        $past(state_q, 2) == S_WAIT_OP0 &&
        $past(state_q)    == S_WAIT_OP1 &&
        state_q           == S_ACTIVE);

    c_block16: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        done_o && ctrl_q.block_size == BLOCK_SIZE_16);

    c_block32: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        done_o && ctrl_q.block_size == BLOCK_SIZE_32);

    c_scale_e4m3: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        done_o && ctrl_q.scale_format == SCALE_E4M3);

    c_error: cover property (
        @(posedge clk_i) disable iff (!rst_ni) state_q == S_ERROR);

    c_srst_active: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        state_q != S_IDLE && soft_reset_i);

    // v2: multi-pass ACTIVE self-loop
    c_multi_pass_loop: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        $past(state_q) == S_ACTIVE && state_q == S_ACTIVE);

    // v2: error with credit return
    c_error_with_done: cover property (
        @(posedge clk_i) disable iff (!rst_ni)
        done_o && err_valid_o);

    // =========================================================================
    // §V.11 Operand Role Dispatch (v2)
    //
    // Queue pop must only fire when operand_role matches the expected role
    // for the current FSM wait state.
    // =========================================================================

    property wait_op0_accepts_src0_only;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_WAIT_OP0 && oq_pop_ready)
        |-> (oq_pop_cap.operand_role == OP_SRC0);
    endproperty
    a_role_op0: assert property (wait_op0_accepts_src0_only)
        else $error("[VEC_ASSERT §V.11] WAIT_OP0 accepted capsule with role != SRC0");

    property wait_op1_accepts_src1_only;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_WAIT_OP1 && oq_pop_ready)
        |-> (oq_pop_cap.operand_role == OP_SRC1);
    endproperty
    a_role_op1: assert property (wait_op1_accepts_src1_only)
        else $error("[VEC_ASSERT §V.11] WAIT_OP1 accepted capsule with role != SRC1");

    // =========================================================================
    // §V.13 Multi-Pass Bounds (v2)
    //
    // pass_idx_q must never exceed num_passes_q - 1.
    // num_passes_q must be 1 or 2.
    // =========================================================================

    property pass_idx_bounded;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE) |-> (pass_idx_q < num_passes_q);
    endproperty
    a_pass_bound: assert property (pass_idx_bounded)
        else $error("[VEC_ASSERT §V.13] pass_idx_q=%0d >= num_passes_q=%0d",
                    pass_idx_q, num_passes_q);

    property num_passes_valid;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q != S_IDLE) |-> (num_passes_q inside {2'd1, 2'd2});
    endproperty
    a_num_passes: assert property (num_passes_valid)
        else $error("[VEC_ASSERT §V.13] num_passes_q=%0d not in {1,2}", num_passes_q);

    // block_size=32 must have 2 passes (with VEC_LANES=16)
    property block32_dual_pass;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && ctrl_q.block_size == BLOCK_SIZE_32)
        |-> (num_passes_q == 2'd2);
    endproperty
    a_block32_pass: assert property (block32_dual_pass)
        else $error("[VEC_ASSERT §V.13] block_size=32 but num_passes != 2");

    // =========================================================================
    // §V.14 Escape Path Routing (v2)
    //
    // Escape must route to L2_WB, not directly to DONE.
    // This ensures the result is spilled (lossless) instead of lost.
    // =========================================================================

    property escape_routes_to_l2wb;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_ACTIVE && $past(result_escape_needed) && $past(last_pass))
        |-> (state_q inside {S_L2_WB, S_IDLE});  // S_IDLE only on soft_reset
    endproperty
    a_escape_l2wb: assert property (escape_routes_to_l2wb)
        else $error("[VEC_ASSERT §V.14] Escape did not route to L2_WB (went to state %0d)",
                    state_q);

    // =========================================================================
    // §V.16 LANE_ADD Result Sign Consistency (CL-1 / CL-10)
    //
    // After LANE_ADD, the result mantissa sign bit must equal the result
    // sign flag. A mismatch indicates the CL-1 sign-flip bug.
    // =========================================================================

    generate
        for (genvar li = 0; li < VEC_LANES; li++) begin : gen_lane_sign_check
            property lane_add_sign_consistent;
                @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
                (state_q == S_ACTIVE && result_valid
                 && ctrl_q.lane_op inside {LANE_ADD, LANE_SUB}
                 && !result_capsule.status_flags[0]   // not NaN
                 && !result_capsule.status_flags[1])   // not Inf
                |-> 1'b1;  // placeholder — full per-lane check requires lane result exposure
            endproperty
        end
    endgenerate

    // =========================================================================
    // §V.17 Multi-Pass Reduce Shift Safety (CL-5 / CL-10)
    //
    // When combining two partial reduce results across passes, the exponent
    // difference must be within safe shift range. If it exceeds REDUCE_W,
    // one partial is completely lost.
    // =========================================================================

    // (Note: requires exposing partial_reduce_q and reduce_result internals.
    //  For v2.1, this is a design-time constraint verified by code review.
    //  Full assertion requires adding these signals to the bind interface.)

    // =========================================================================
    // §V.18 Block32 Dual-Capsule Egress Completeness (CL-3 / CL-10)
    //
    // For block32 non-reduce operations, the FSM must output exactly 2
    // capsules (one per window) before reaching DONE.
    // =========================================================================

    property block32_egress_complete;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_DONE && ctrl_q.block_size == BLOCK_SIZE_32 && !ctrl_q.reduce_en)
        |-> ($past(egress_window_q) == 1'b1 || $past(state_q) == S_ERROR);
    endproperty
    a_block32_egress: assert property (block32_egress_complete)
        else $error("[VEC_ASSERT §V.18] Block32 non-reduce completed without outputting both windows");

    // =========================================================================
    // §V.19 Operand Role Misorder Detection (CL-4 / CL-10)
    //
    // The role stall counter must not reach timeout without triggering ERROR.
    // This verifies the CL-4 HOL blocking fix is working correctly.
    // =========================================================================

    property role_stall_triggers_error;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (role_stall_timeout && state_q inside {S_WAIT_OP0, S_WAIT_OP1})
        |=> (state_q == S_ERROR);
    endproperty
    a_role_stall: assert property (role_stall_triggers_error)
        else $error("[VEC_ASSERT §V.19] Role stall timeout did not trigger ERROR");

    // =========================================================================
    // §V.20 Reduce Result Not Direct-Forwarded (CL-7 / CL-10)
    //
    // Reduce results must have fwd_eligible=0 and layout_tag=LAYOUT_SCALAR_REDUCE.
    // Direct-forwarding a scalar to Tensor Unit would cause data misinterpretation.
    // =========================================================================

    property reduce_result_no_fwd;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && result_valid && ctrl_q.reduce_en)
        |-> (!result_capsule.fwd_eligible
             && result_capsule.layout_tag == LAYOUT_SCALAR_REDUCE);
    endproperty
    a_reduce_no_fwd: assert property (reduce_result_no_fwd)
        else $error("[VEC_ASSERT §V.20] Reduce result has fwd_eligible=1 or wrong layout_tag");

    // =========================================================================
    // §V.21 Watchdog Timeout Routes to L2_WB (CL-8 / CL-10)
    // =========================================================================

    property watchdog_routes_to_l2wb;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(state_q) == S_ACTIVE && $past(watchdog_timeout))
        |-> (state_q inside {S_L2_WB, S_IDLE});
    endproperty
    a_watchdog: assert property (watchdog_routes_to_l2wb)
        else $error("[VEC_ASSERT §V.21] Watchdog timeout did not route to L2_WB");

    // =========================================================================
    // v6.0 Round 4 — §V.22 through §V.27: assertion coverage for Round 1-3b
    //                    fixes. Each targets a specific bug or decision.
    // =========================================================================

    // =========================================================================
    // §V.22 No Premature Watchdog (Bug #1 regression guard, v6.0 Round 3a)
    //
    // Pre-v6 code used VEC_MAX_OP_CYCLES[9:0] which evaluated to 0, firing
    // the watchdog on the first ACTIVE cycle of every op. After Round 3a,
    // the watchdog uses VEC_WATCHDOG_THRESHOLD (1023) — the timeout must
    // NOT fire when ACTIVE is first entered.
    //
    // Detection: transition into ACTIVE implies watchdog_timeout is false.
    // Counter starts at 0 on entry (cleared by DONE/ERROR); 0 < 1023, so
    // timeout must be 0. A violation would indicate either:
    //   (a) Bug #1 regression (wrong width comparison)
    //   (b) watchdog_cnt_q reset bug
    // =========================================================================

    property no_premature_watchdog;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && $past(state_q) != S_ACTIVE)
        |-> !watchdog_timeout;
    endproperty
    a_no_premature_watchdog: assert property (no_premature_watchdog)
        else $error("[VEC_ASSERT §V.22] Watchdog fired on ACTIVE entry (Bug #1 regression)");

    // =========================================================================
    // §V.23 L2_WB Writes Latched Payload (Bug #2 verification, v6.0 Round 3a)
    //
    // When the FSM is in VST_L2_WB actively writing (rw_req_o implied by
    // l2_wb_active), result_cap_valid_q MUST be asserted. Otherwise the
    // write is sourcing stale or zeroed data from an invalid latch state.
    //
    // Round 3a sets result_cap_valid_q at (VST_ACTIVE && last_pass &&
    // result_valid). Since VST_L2_WB can only be reached from VST_ACTIVE,
    // and that transition requires last_pass to be true (except for
    // scale_any_error which goes to ERROR, not L2_WB), the latch must be
    // valid by the time L2_WB begins writing.
    //
    // Exception: immediately after soft_reset the assertion is disabled.
    // =========================================================================

    property l2_wb_writes_latched_payload;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_L2_WB)
        |-> result_cap_valid_q;
    endproperty
    a_l2_wb_latched: assert property (l2_wb_writes_latched_payload)
        else $error("[VEC_ASSERT §V.23] VST_L2_WB with result_cap_valid_q=0 (Bug #2 regression — will write stale/zero payload)");

    // =========================================================================
    // §V.24 Lane-Only Block32 Window 0 Uses Partial Latch (Bug #4 verification)
    //
    // When in the lane-only block32 dual-egress path at window 0, the
    // partial_lane_valid_q must be asserted — meaning the pass-0 latch
    // was successfully populated during the preceding pass-0 compute cycle.
    //
    // This is a pre-condition for effective_lane_results to source the
    // correct window-0 data. Without the latch being valid, the selector
    // would fall through to live lane_results (which carry pass-1 data
    // at this point), reintroducing Bug #4.
    //
    // Gated by block32_dual_egress to avoid false triggers on block16 or
    // reduce/renorm paths.
    // =========================================================================

    property lane_only_b32_w0_uses_partial;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && last_pass
         && block32_dual_egress
         && !ctrl_q.reduce_en && !ctrl_q.renorm_en
         && (egress_window_q == 1'b0)
         && fp_egr_valid)
        |-> partial_lane_valid_q;
    endproperty
    a_lane_b32_w0_partial: assert property (lane_only_b32_w0_uses_partial)
        else $error("[VEC_ASSERT §V.24] Lane-only block32 window 0 egress without valid partial_lane_latch (Bug #4 regression)");

    // =========================================================================
    // §V.25 Scale Error Routes to ERROR with Dedicated Code (v6.0 Round 3a)
    //
    // Strict semantics (Round 3a decision ①): scale_any_error in VST_ACTIVE
    // must route to VST_ERROR with error_q == VERR_SCALE_DECODE. No other
    // downstream path (watchdog/escape/L2_WB) is allowed to absorb this.
    //
    // Priority verification: even if watchdog_timeout happens to be true
    // in the same cycle, scale_any_error wins (the next-state mux puts it
    // at priority #1 in VST_ACTIVE).
    // =========================================================================

    property scale_error_routes_to_error;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ACTIVE && scale_any_error)
        |=> (state_q == S_ERROR && error_q == VERR_SCALE_DECODE);
    endproperty
    a_scale_error: assert property (scale_error_routes_to_error)
        else $error("[VEC_ASSERT §V.25] scale_any_error did not route to VERR_SCALE_DECODE / VST_ERROR");

    // =========================================================================
    // §V.26 Role Misorder Uses New VERR Code (v6.0 Round 3a rename)
    //
    // Pre-v6 code overloaded VERR_INTERNAL (4'd9) for role stall timeout.
    // Round 3a introduced VERR_ROLE_MISORDER (4'd10) as the dedicated code.
    // When role_stall_timeout fires in WAIT_OPn, the resulting ERROR state
    // must carry VERR_ROLE_MISORDER, not VERR_INTERNAL.
    // =========================================================================

    property role_misorder_uses_new_code;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(role_stall_timeout)
         && $past(state_q inside {S_WAIT_OP0, S_WAIT_OP1})
         && state_q == S_ERROR)
        |-> (error_q == VERR_ROLE_MISORDER);
    endproperty
    a_role_new_code: assert property (role_misorder_uses_new_code)
        else $error("[VEC_ASSERT §V.26] Role-stall ERROR uses wrong error_q (expected VERR_ROLE_MISORDER = 10, got %0d)",
                    error_q);

    // =========================================================================
    // §V.27 Egress Window Advance Timing (Bug #6 verification, v6.0 Round 3b)
    //
    // egress_window_q may only advance (0→1) at two defined moments:
    //   (a) VST_ACTIVE with fp_egr_accepted   → fast path consumed current window
    //   (b) VST_L2_WB with rw_gnt_i            → L2 write of current window done
    //
    // Any advance at other moments indicates a regression of Bug #6.
    //
    // Implementation note: the property checks "if egress_window_q went from
    // 0 to 1 this cycle, then one of the two conditions held in the previous
    // cycle". The reset/DONE/ERROR clear of egress_window_q (1→0) is
    // intentionally out of scope here — only the 0→1 advance is guarded.
    // =========================================================================

    property egress_window_advance_timing;
        @(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(egress_window_q) == 1'b0 && egress_window_q == 1'b1)
        |->
        (   ($past(state_q) == S_ACTIVE && $past(fp_egr_accepted) && $past(last_pass) && $past(block32_dual_egress))
         || ($past(state_q) == S_L2_WB  && $past(rw_gnt_i) && $past(block32_dual_egress))
        );
    endproperty
    a_egress_advance: assert property (egress_window_advance_timing)
        else $error("[VEC_ASSERT §V.27] egress_window_q advanced at unauthorized moment (Bug #6 regression)");

    // =========================================================================
    // v6.0 Round 4 — §V.28 through §V.31: cover properties for path exercise.
    //
    // These ensure the testbench actually exercises the Round 1-3b code
    // paths. A cover that never fires indicates test gap (not a bug).
    // =========================================================================

    // §V.28 — VERR_SCALE_DECODE actually fired at least once in the run
    cover property (@(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ERROR && error_q == VERR_SCALE_DECODE));

    // §V.29 — VERR_ROLE_MISORDER actually fired at least once in the run
    cover property (@(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_ERROR && error_q == VERR_ROLE_MISORDER));

    // §V.30 — Block32 dual-egress L2 fallback path exercised (Bug #6 critical path)
    //   Specifically: in L2_WB, block32_dual_egress=1, window 0 still being
    //   written (egress_window_q==0), on rw_gnt_i the window advances.
    cover property (@(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        (state_q == S_L2_WB && block32_dual_egress
         && egress_window_q == 1'b0 && rw_gnt_i));

    // §V.31 — Lane-only block32 pass-0 latch event exercised (Bug #4 critical path)
    //   The moment partial_lane_valid_q transitions 0→1.
    cover property (@(posedge clk_i) disable iff (!rst_ni || soft_reset_i)
        ($past(partial_lane_valid_q) == 1'b0 && partial_lane_valid_q == 1'b1));

endmodule

// =============================================================================
// Bind Statement
//
// Attaches vec_assertions to vector_unit at elaboration time.
// All signals are referenced via hierarchical paths into vector_unit internals.
// =============================================================================

bind vector_unit vec_assertions i_vec_assertions (
    .clk_i          ( clk_i          ),
    .rst_ni         ( rst_ni         ),
    .soft_reset_i   ( soft_reset_i   ),

    // FSM
    .state_q        ( state_q        ),
    .state_d        ( state_d        ),

    // Descriptor
    .desc_valid_i   ( desc_valid_i   ),
    .desc_ready_o   ( desc_ready_o   ),

    // Latched control
    .ctrl_q         ( ctrl_q         ),
    .error_q        ( error_q        ),

    // Multi-pass state (v2)
    .pass_idx_q     ( pass_idx_q     ),
    .num_passes_q   ( num_passes_q   ),
    .last_pass      ( last_pass      ),
    .sub_count_q    ( sub_count_q    ),
    .dst_ref_q      ( dst_ref_q      ),

    // Operand state
    .src0_loaded_q  ( src0_loaded_q  ),
    .src1_loaded_q  ( src1_loaded_q  ),

    // Operand role dispatch (v2)
    .role_match     ( role_match     ),
    .oq_pop_ready   ( oq_pop_ready   ),
    .oq_pop_valid   ( oq_pop_valid   ),
    .oq_pop_cap     ( oq_pop_cap     ),

    // Queue
    .oq_full        ( oq_full                 ),
    .oq_empty       ( u_op_queue.empty_o      ),
    .oq_count       ( u_op_queue.count_o      ),

    // Fast path ingress
    .t2v_valid      ( t2v_valid_i             ),
    .t2v_ready      ( t2v_ready_o             ),
    .t2v_miss_valid ( t2v_miss_valid_o        ),
    .t2v_miss_reason( t2v_miss_reason_o       ),

    // Fast path egress
    .v2t_valid      ( v2t_valid_o             ),
    .v2t_ready      ( v2t_ready_i             ),
    .fp_egr_accepted( fp_egr_accepted         ),
    .fp_egr_rejected( fp_egr_rejected         ),

    // Result packer
    .result_valid        ( result_valid          ),
    .result_escape_needed( result_escape_needed  ),
    .result_capsule      ( result_capsule        ),

    // Active capsules (v2)
    .active_src0_cap     ( active_src0_cap       ),

    // Completion
    .done_o         ( done_o         ),
    .done_ctx_o     ( done_ctx_o     ),
    .done_tag_o     ( done_tag_o     ),
    .err_valid_o    ( err_valid_o    ),

    // Perf counters
    .perf_q         ( perf_q         ),
    .perf_cnt_en    ( perf_cnt_en_i  ),

    // v2.1: CL-3/CL-4/CL-8 signals
    .egress_window_q    ( egress_window_q    ),
    .role_stall_timeout ( role_stall_timeout  ),
    .watchdog_timeout   ( watchdog_timeout    ),

    // v6.0 Round 3a/3b signals (for §V.22-V.31)
    .scale_any_error      ( scale_any_error      ),  // R3a
    .result_cap_valid_q   ( result_cap_valid_q   ),  // R3a
    .partial_lane_valid_q ( partial_lane_valid_q ),  // R3b
    .block32_dual_egress  ( block32_dual_egress  ),  // R3b (R3a-derived wire)
    .rw_gnt_i             ( rw_gnt_i             ),  // top-level input port
    .fp_egr_valid         ( fp_egr_valid         )   // R3b
    // [N16] removed duplicate `.last_pass` pin (connected above) to match the
    // de-duplicated port list.
);

`endif // SYNTHESIS

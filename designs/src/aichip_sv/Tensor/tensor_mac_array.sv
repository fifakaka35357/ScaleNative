// ============================================================================
// Tensor MAC Array v4.3 (Round E1 / R6) — 16x16 Systolic Array
// ============================================================================
//
// 16x16 systolic array of MAC cells with scale sideband and OS skew. This is
// the compute fabric of the Tensor Unit. It instantiates 256 MAC cells,
// wires the weight/activation/psum/scale systolic passes, manages the OS
// skew shift registers, and holds the sparse ingress queue.
// [C1 2026-07-31] 双 SCU 已删除（D-SPARSE-NM-2026-07-31，见模块中部墓碑注）。
//
// Previously named upe_array_sparse. Renamed as part of the Round E naming
// cleanup — "UPE array" was ambiguous; the new name makes explicit that
// this is a MAC cell array (the compute fabric), not the whole Tensor Unit.
//
// ----------------------------------------------------------------------------
// Round E1 / R6 changes (THIS ROUND — the biggest structural shift):
// ----------------------------------------------------------------------------
//
//   (1) RENAMES
//       - File:   upe_array_sparse.sv → tensor_mac_array.sv
//       - Module: upe_array_sparse → tensor_mac_array
//       - Import: upe_pkg → tensor_pkg
//       - Type:   upe_mode_e → tensor_mode_e
//       - Submodule: upe_core_sparse u_upe → mac_cell u_mac
//       - Assertion tag: UPE_ARRAY → TENSOR_MAC_ARRAY
//       - Helper: (mode inside {MXFP4, MXFP8, MXINT8}) → mode_is_mx(mode)
//
//   (2) OFU SIDECAR MIGRATION — REMOVED all 256 per-MAC OFU instances
//
//       This is THE core physical step of the Vector Unit OFU Sidecar
//       Migration described in Vector_Unit_OFU_Sidecar_Design_Plan.md.
//
//       Removed from inside gen_col:
//         upe_output_format_unit u_ofu (...)  [x 256 instances]
//
//       Removed ports (no longer relevant at Tensor Unit level):
//         INPUT:   ofu_fmt         (ofu_fmt_e)
//         INPUT:   ofu_round_mode  (ofu_round_e)
//         OUTPUT:  ofu_result      [ROWS][COLS] (32-bit formatted)
//         OUTPUT:  ofu_valid       [ROWS][COLS]
//
//       Physical impact: -200K gates (-10% to -15% of Tensor Unit area).
//       Architectural impact: Tensor Unit's output contract is now PURE
//       block-float (fp_acc_output_t only), as required by paper §8.4.5's
//       "arithmetically independent but format-compatible" framing.
//
//       output_format_unit.sv (formerly upe_output_format_unit.sv) is
//       preserved in the codebase. Testbenches may instantiate it as a
//       golden model. Phase E3 will wrap it as a 16-lane Vector sidecar.
//
//   (3) NEW: Snapshot bank infrastructure
//
//       Every MAC cell (R3) now holds a fp_acc_snapshot_q register that
//       latches on capture_fire. This array:
//
//         - Receives capture_fire from the tile controller (R5) and
//           broadcasts it to all 256 MAC cells uniformly.
//
//         - Collects all 256 fp_acc_snapshot outputs into the internal
//           bundle pe_fp_acc_snapshot[ROWS][COLS] (15.6K bit aggregate,
//           wholly internal to this module).
//
//         - Exposes a new row-read interface to the egress fragmentizer
//           (R4) via three new top-level ports:
//
//             INPUT:  snapshot_read_row [3:0]   (row index, 0..15)
//             INPUT:  snapshot_read_en           (informational)
//             OUTPUT: snapshot_row_data [COLS]   (combinational row mux)
//
//           The row mux is pure combinational — no read latency. Cost is
//           16 x (16:1 MUX x 61-bit) ≈ 15K gates, a small overhead compared
//           to the 200K-gate savings from OFU removal (net ≈ -185K gates).
//
//       Design rationale: distributed storage (per-cell snapshot register),
//       centralized control (single capture_fire broadcast), row-structured
//       readout (single row mux at array top level). See
//       Vector_Unit_OFU_Sidecar_Design_Plan.md §5.2 and Q3 refinement.
//
//   (4) ~~CODE OPT #2: sparse_deq_valid assertion tightened~~
//       【3a-1 S2 2026-08-03 已随 K 令牌通路退役而删除】
//
//       原文记述的那条守卫是
//         (sparse_exec_mode != EXEC_SPARSE_STRUCT) |-> !(sparse_deq_valid && ctrl_frag_ready)
//       ——「稀疏 fragment 泄漏进 dense tile」的唯一守门。队列删除后它失去观测量，
//       随本步一并删除。**这是一笔覆盖净损失**：等价物（描述符层面的 WS×sparse 拒收
//       + 可观测 sticky）由 3a-7 补。
//
//       同时死亡的还有 tensor_sparse_ingress_queue.sv:277-288 的两条 $fatal 级
//       逐拍影子恒等（K1a rd_valid_next / K1c dense_k_advance_next）——
//       🔴 3a-6 重写 K1a/K1c 影子时**不得假设「影子还在」**。
//
//   (5) CODE OPT #4: Removed pe_skip[ROWS][COLS] dead wire
//
//       The original array collected per-MAC skip_accumulation outputs
//       into pe_skip[ROWS][COLS] but never read from that array — it was
//       dead code from an earlier design where skip was aggregated at
//       array level for debug counters.
//
//       Fix: removed the pe_skip declaration entirely. The mac_cell's
//       skip_accumulation output is left unconnected at the instantiation
//       site (SystemVerilog allows this for outputs; synthesis will tie
//       it to a no-load net).
//
//   (6) CODE OPT #5: Named intermediate for weight_load logic
//
//       The original inline expression:
//         .weight_load (dataflow_sel ? weight_load : array_step_en)
//
//       mixes two different semantics in one expression:
//         - WS mode (dataflow_sel=1): explicit weight_load pulse
//         - OS mode (dataflow_sel=0): continuous streaming via step_en
//
//       Fix: introduced a named intermediate signal
//         logic weight_load_effective;
//         assign weight_load_effective = dataflow_sel ? weight_load : array_step_en;
//       with an explanatory comment. The mac_cell port now takes
//       .weight_load(weight_load_effective), making the semantic explicit.
//
//   (7) MAC_CELL INSTANTIATION UPDATES
//
//       - Module name: upe_core_sparse → mac_cell
//       - Instance name: u_upe → u_mac
//       - NEW input connection: .capture_fire(capture_fire)
//       - NEW output connection: .fp_acc_snapshot(pe_fp_acc_snapshot[r][c])
//       - REMOVED connection: .result_valid() (mac_cell no longer has this port)
//       - CHANGED: .skip_accumulation() (now unconnected, was pe_skip[r][c])
//       - CHANGED: .weight_load(weight_load_effective) (named intermediate)
//
// ----------------------------------------------------------------------------
// v4.2c Round C features — REMOVED in R6 (OFU migration above)
//
//   P2-1 (per-PE OFU instantiation): REMOVED. See change (2) above.
//
// v4.2b Round B features retained:
//
//   P1-3 (sparse ingress queue): ~~unchanged~~ **REMOVED [3a-1 S2 2026-08-03]**。
//   规格 §4.1「K 令牌通路退役」：per-tile 常数 N ⇒ 确定性节拍，稀疏 K 步长由
//   controller 内部纯函数给出，不再需要 Vector 递送 fragment 令牌。
//   删除面 = 队列实例 + 10 个端口（sparse_frag_×3 / ctrl_frag_ready /
//   sparse_deq_×5 / sparse_queue_level）+ 参数 SPARSE_QUEUE_EN + 两条 P1-3 SVA。
//   🔴 **保留** ZEROSKIP_EN（C1 已把原 SPARSE_EN 拆成两个独立参数，与队列零交集）
//   与 sparse_exec_mode（下面新守卫的唯一观测量）。
//
// v4.2 features retained:
//
//   A6: scale_loaded flags clear on tile_start
//   A8: ~~Weight boundary MUX gates on weight_scu_valid~~（[C1] SCU 删除后 mux 已移除）
//   A4: active_tail_mask propagated to all MAC cells via .lane_valid
//   P0-2: result_valid is driven by ctrl_result_valid (authoritative)
//
//   CONTROL SPLIT: issue_en / array_step_en propagated to cells
//     issue_en      → mac_cell.mac_en
//     array_step_en → skew shift registers, act_reg, weight_scale_pass
//
// v4.1 features retained:
//   - OS skewed input timing (per-row shift registers, depth=r)
//   - MX scale systolic sideband (symmetric with data pass)
//   - Scale boundary hold registers (load-on-valid, hold-otherwise)
//   - ~~Dual SCU (weight/activation) for adaptive zero-skip~~（[C1 2026-07-31] 已删除）
//   - OS/WS runtime dataflow selection
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R6 — OFU removal + snapshot infrastructure + code opts)
// ============================================================================

module tensor_mac_array
  import tensor_pkg::*;
#(
  parameter int ROWS       = 16,
  parameter int COLS       = 16,
  parameter int DATA_WIDTH = 16,
  parameter int ACC_WIDTH  = ACC_WIDTH_DEFAULT,  // 48
  // [3a-1 S2] ZEROSKIP_EN 的身份自 N:M 起变化：它不再是「可选优化」，而是**正确性前提**
  //   —— 规格 §4.3 的 N=1 零行气泡与 §2.1 尾窗 pad 的正确性都建立在「零积对累加器
  //   位精确恒等」上（mac_fp_acc_align.sv:227 + mac_fp_accumulator.sv:223）。
  //   ⇒ ZEROSKIP_EN=0 与稀疏执行互斥。
  parameter bit ZEROSKIP_EN     = 1'b1,  // [C1 2026-07-31] per-cell 零门控（原 SPARSE_EN 的 mac_cell 臂）
  // [3a-1 S2 2026-08-03] parameter bit SPARSE_QUEUE_EN 已删（K 令牌通路退役）。
  //   全仓零 override 实证：tb/Makefile 无 -G、8 个 .py docstring 无、
  //   7 个 ORFS config.mk 无、elaborate_smoke.sh 无 ⇒ gen_no_sparse_queue 臂从未 elaborate。
  // [P4/D-CONV-BASE] secondary ablation: faithful-v4.2c 256x per-MAC OFU. Default
  // 0 = bit-identical. =1 instantiates one output_format_unit per cell (tapping the
  // cell snapshot) as an AREA-measurement harness (XOR-digest keeps them alive).
  parameter bit CONVERTER_PER_MAC = 1'b0
) (
  input  logic               clk,
  input  logic               rst_n,

  // =========================================================================
  // Global Control (v4.2: split signals from tile controller)
  // =========================================================================
  input  tensor_mode_e       mode,
  input  logic               issue_en,        // v4.2: cell may consume new K data
  input  logic               array_step_en,   // v4.2: systolic pipeline advances
  input  logic               weight_load,
  input  logic               clear_acc,

  // =========================================================================
  // Snapshot Capture Control (R6 NEW)
  // =========================================================================
  //
  // capture_fire is a 1-cycle pulse from tensor_tile_controller (R5).
  // Broadcast to every MAC cell; triggers atomic latching of each cell's
  // fp_acc_out into its fp_acc_snapshot_q register.
  //
  // The snapshot bank can then be read by tensor_egress_fragmentizer (R4)
  // via the snapshot_read_* port group below, while the accumulator
  // itself is cleared and reused by the next tile.
  input  logic               capture_fire,

  // =========================================================================
  // Snapshot Bank Row Read Interface (R6 NEW)
  // =========================================================================
  //
  // Driven by tensor_egress_fragmentizer during ST_SCAN. The row mux is
  // pure combinational — there is NO read latency. The fragmentizer's
  // row_cnt_q drives snapshot_read_row, and the selected row of 16 snapshot
  // cells appears on snapshot_row_data within the same cycle.
  //
  // snapshot_read_en is currently informational only (for assertions and
  // debug). A future optimization may use it to gate the row mux for
  // power saving, but the current implementation always evaluates the
  // mux combinationally.
  input  logic [3:0]         snapshot_read_row,
  input  logic               snapshot_read_en,
  output fp_acc_output_t     snapshot_row_data [COLS],

  // =========================================================================
  // Lane Valid / Tail Mask (v4.2: from tile controller)
  // =========================================================================
  input  logic [3:0]         active_tail_mask, // Per-lane valid → all cells

  // =========================================================================
  // [K1c 2026-07-27] one-beat-early control views (from tile controller)
  // =========================================================================
  // Next-state mirrors of the four cell-broadcast controls. Registered here
  // in FOUR per-quadrant tensor_ctrl_quad instances (8x8 each) so every
  // quadrant's copy(t) == the live signal(t) — per-beat identity retime that
  // cuts the state_q/step_en decode+broadcast head out of the cell cones
  // (T-1: 345ps decode + 1006ps ladder; review F1-stepen: the step_en comb
  // leg through weight_stream_out rides into the multiply cones). The LIVE
  // ports above keep driving the array-level skew SRs / scale passes /
  // recapture registers (shallow enable endpoints — unchanged).
  input  logic [3:0]         ctrl_tail_mask_d,
  input  logic               ctrl_clear_acc_d,
  input  logic               ctrl_capture_fire_d,
  input  logic               ctrl_step_d,

  // =========================================================================
  // Runtime Dataflow Selection
  // =========================================================================
  // 0 = Output Stationary:  psum_in=0, local accumulation
  // 1 = Weight Stationary:  psum chain connected, results from bottom row
  input  logic               dataflow_sel,

  // =========================================================================
  // Sparse Execution Mode（~~v4.2: Vector-assisted path~~）
  // =========================================================================
  // [3a-1 S2 2026-08-03] 「Vector-assisted」措辞随 K 令牌通路退役而作废：
  //   稀疏执行不再由 Vector 递送 fragment，改为 per-tile 常数 N 的确定性节拍。
  //   本端口**保留**（D11）—— 它是下方 Assertions 段新守卫的唯一观测量；
  //   语义在 3a-3 由 n_cfg 描述符链重定义。
  input  exec_sparse_mode_e  sparse_exec_mode,

  // =========================================================================
  // [3a-1 S2 2026-08-03] Sparse Fragment Fast Path — 全部 10 个端口已删除
  // =========================================================================
  //   写侧 sparse_frag_valid / sparse_frag_ready / sparse_frag_in
  //   读侧 ctrl_frag_ready / sparse_deq_valid / sparse_deq_valid_next /
  //        sparse_deq_k_advance / sparse_deq_k_advance_next / sparse_deq_group_last
  //   状态 sparse_queue_level
  // 规格 §4.1「K 令牌通路退役」。上方 sparse_exec_mode 保留 —— 它是新守卫的唯一观测量。

  // =========================================================================
  // Tile Lifecycle (v4.2: from controller)
  // =========================================================================
  input  logic               tile_start,      // Pulse: new tile (clears scale_loaded)

  // v4.2a P0-2: Authoritative result_valid from tile controller.
  input  logic               ctrl_result_valid,

  // =========================================================================
  // Data Inputs
  // =========================================================================
  input  logic [DATA_WIDTH-1:0] weight_in  [COLS],
  input  logic               weight_valid,
  input  logic [DATA_WIDTH-1:0] act_in     [ROWS],
  input  logic               act_valid,

  // =========================================================================
  // INT/MX Result Output (from psum chain)
  // =========================================================================
  output logic signed [ACC_WIDTH-1:0] result [ROWS][COLS],
  output logic               result_valid,

  // =========================================================================
  // FP Accumulator Results (raw block-float, live — for debug/TB)
  // =========================================================================
  //
  // NOTE: These are the LIVE fp_acc_out signals (not snapshots). They are
  // useful for testbenches that want to observe compute in progress, but
  // they are NOT the contract path for tile results — that is the snapshot
  // bank, accessed via snapshot_row_data above.
  //
  // Phase E2+ integration should route egress fragments through the
  // snapshot bank, not fp_result. This port group may be removed in a
  // future round once TB infrastructure is updated.
  output fp_acc_output_t     fp_result [ROWS][COLS],

  // [P4/D-CONV-BASE] 256x per-MAC OFU ablation digest (XOR-reduce of all 256
  // formatted FP results; keeps the ablation OFU bank from being optimized away).
  // Tied '0 when CONVERTER_PER_MAC=0.
  output logic [31:0]        pmac_ofu_digest,

  // =========================================================================
  // MX Scale Sideband (v4.1 R4: per-row/col, block-boundary update)
  // =========================================================================
  input  logic [7:0]         weight_scale_in    [COLS],
  input  logic               weight_scale_valid [COLS],
  input  logic [7:0]         act_scale_in       [ROWS],
  input  logic               act_scale_valid    [ROWS]
);

  // ==========================================================================
  // Internal Signals
  // ==========================================================================

  // Systolic data pass-through arrays
  logic [DATA_WIDTH-1:0]      weight_pass [ROWS+1][COLS]; // North→South
  logic [DATA_WIDTH-1:0]      act_pass    [ROWS][COLS+1]; // West→East
  // [STEP4-E2E] Scoped UNOPTFLAT waiver: psum_pass is a FORWARD systolic partial-
  // sum chain (row r drives row r+1 via psum_out=int_acc_reg+psum_in). In OS mode
  // pe_psum_in is muxed to 0 (no feedback); in WS mode it is a feed-forward column
  // chain that settles in one pass — not a true combinational cycle. Scoped here so
  // the project build does not blanket-suppress genuine loops elsewhere (matches the
  // vec_lane_array SV-2 waiver). Needed for the cocotb (full-elaborate) E2E builds.
  /* verilator lint_off UNOPTFLAT */
  logic signed [ACC_WIDTH-1:0] psum_pass  [ROWS+1][COLS]; // North→South
  /* verilator lint_on UNOPTFLAT */

  // MX Scale systolic pass — structure 1, symmetric with data
  logic [7:0]                 weight_scale_pass [ROWS+1][COLS]; // North→South
  logic [7:0]                 act_scale_pass    [ROWS][COLS+1]; // West→East

  // Boundary hold registers (protocol b: load-on-valid, hold)
  logic [7:0]                 weight_scale_hold [COLS];
  logic [7:0]                 act_scale_hold    [ROWS];

  // Scale loaded flags (for assertion / optional hardware guard)
  logic                       weight_scale_loaded [COLS];
  logic                       act_scale_loaded    [ROWS];

  // Activation systolic registers (array-level, 1-cycle delay per column)
  logic [DATA_WIDTH-1:0]      act_reg     [ROWS][COLS];

  // Per-MAC outputs
  logic [3:0]                 pe_sparsity_map     [ROWS][COLS];
  fp_acc_output_t             pe_fp_acc_out       [ROWS][COLS];
  fp_acc_output_t             pe_fp_acc_snapshot  [ROWS][COLS];  // R6 NEW: snapshot bundle

  // R6 (code opt #4): pe_skip[ROWS][COLS] REMOVED (was dead wire).
  // The mac_cell skip_accumulation output is left unconnected at instantiation.

  // R6 code-opt-#5 weight_load_effective REMOVED ([K1c-b] 2026-07-28): dead
  // since K1c — every mac_cell takes the per-quadrant wle_quad view instead
  // (see the QI localparam in the cell generate below); the dual-semantic
  // note lives on at that assign.

  // ==========================================================================
  // [K1c-b 2026-07-28] second per-quadrant bank: ARRAY-level step copies
  // ==========================================================================
  //
  // The array-level array_step_en consumers (recapture, skew SRs, act_reg/
  // act_scale_pass, weight_scale_pass) move off the controller's live net onto
  // four dedicated per-quadrant copies, killing the full-die relay wall
  // (weight_scale_pass slack -564.79, batch-2 postcts). A SEPARATE MODULE is
  // load-bearing twice over:
  //   1. keep_hierarchy (SYNTH_KEEP_MODULES, base config dc84b2207) is the
  //      only production-proven survival mechanism for same-input clones;
  //   2. a second register inside tensor_ctrl_quad would FOLD — opt_merge
  //      merges same-D same-type flops within one module scope (preflight
  //      §0.5: the B' dead end).
  // The cell-facing quad trees (tensor_ctrl_quad) keep their proven 612-760
  // sink load; this bank carries the ~14.2k array-level EN endpoints on its
  // own quadrant-local trees (A-vs-B ruling, preflight §1.1).
  logic quad_step_arr [4];

  generate
    for (genvar gq = 0; gq < 4; gq++) begin : gen_step_quad
      tensor_step_quad u_step_quad (
        .clk           (clk),
        .rst_n         (rst_n),
        .step_d_i      (ctrl_step_d),
        .step_en_arr_o (quad_step_arr[gq])
      );

      // [K1c-b] shadow identity: the array copy must equal the LIVE
      // controller output on EVERY beat (K1c S1 discipline; a diverging
      // beat is NEW-1-class data corruption).
      // synopsys translate_off
      assert property (@(posedge clk) disable iff (!rst_n)
          quad_step_arr[gq] == array_step_en
      ) else $fatal(1, "K1CB: step_quad %0d diverged from live array_step_en (%0b/%0b)",
                    gq, quad_step_arr[gq], array_step_en);
      // synopsys translate_on
    end
  endgenerate

  // ==========================================================================
  // A1 fix (2026-07-06): OS operand + scale recapture stage
  // ==========================================================================
  //
  // The weight/act operand SRAMs (sky130 sram_2kbyte_1rw1r) launch dout on the
  // FALLING edge, so the un-registered arc
  //   SRAM(negedge) -> operand_fetch -> array boundary MAC -> fp_acc -> acc_mant
  // is a HALF-CYCLE path (period/2). In OS the weights STREAM every issue_en
  // (tensor_external_modules.sv:870), so that arc is a real per-cycle limiter
  // and it capped the sky130 signoff at ~13.8 MHz (72.55 ns incl-macro), while
  // the standard-cell reg2reg ceiling is ~48 ns / 20.6 MHz. This stage
  // recaptures the per-cycle operand + scale sidebands on the RISING edge,
  // splitting that arc into
  //   (a) SRAM(negedge) -> recapture reg : short half-cycle, huge margin
  //   (b) recapture reg  -> MAC -> fp_acc : full cycle (~33 ns)
  // removing the SRAM-macro arc as an OS binding constraint. TARGET (not yet
  // proven): OS Fmax rises toward the standard-cell reg2reg ceiling (~20.6 MHz).
  // This is UNVERIFIED until the post-fix re-P&R STA — and note the pre-fix STA's
  // #1 worst path is a SEPARATE egress reg->output-port arc (egress_frag_escape,
  // u_result_packer, -4.62ns @70ns), which this stage does NOT touch.
  // [2026-07-31 CORRECTION] The old wording called it "a primary-output
  // port-budget artifact" -- that is TOO GENEROUS and has misled a downstream
  // analysis. ASAP7 @1670ps measures 9226.30 ps total / **7810.99 ps of pure
  // data delay**; that is real combinational delay, NOT an artifact of the
  // 100 ps io_dly budget. Correct framing: a REAL long path, already deferred
  // by decision D-FINAL-RTLSET (item (5) packer pipelining -> future work) and
  // disclosed in PPA_Tables_SSOT; at pe_top it is the #2 wall (the #1 is the
  // Vector compact-MX arc, 8815.35 ps -- see SSOT row aichip_pe_top-ASAP7).
  // It is still reported separately from the reg2reg Fmax, which remains
  // correct -- but do not describe it as a budget artifact.
  //
  // Cost: +1 cycle of operand latency in OS -> DRAIN_CYCLES_OS is bumped +1 in
  // tensor_tile_controller.sv (31 -> 32) to accumulate the now-1-cycle-later
  // last wavefront (issue_count becomes K + 32). Gated by array_step_en so it
  // advances in lockstep with the skew SRs and stays coherent through sparse
  // frag stalls (issue_en == array_step_en in OS). The prior-tile drain
  // zero-pad flushes these regs to 0 before the next tile's head bubble.
  //
  // OS ONLY: WS bypasses to the direct inputs (bit-identical to the pre-fix
  // array — the register still clocks but its output is unused in WS, exactly
  // like the OS-only skew shift registers below). Preserves the frozen-WS core.
  //
  // USAGE GUARD (pre-existing flush contract, see the skew SR note ~line 700):
  // the recapture regs (and the skew SRs) are flushed to 0 only by the prior
  // tile's OS drain zero-pad, NOT by tile_start. On a WS->OS tile transition
  // with NO intervening rst_n, a WS tile leaves stale NONZERO operands here
  // (WS never zero-pads), which the next OS tile's head would accumulate. Issue
  // a rst_n (or an OS flush tile) on any WS->OS mode switch. Inert for the
  // BF16-OS / OS->OS scope (gemm_chain) and the frozen-WS scope.
  // --------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] weight_in_q          [COLS];
  logic                  weight_valid_q;
  logic [DATA_WIDTH-1:0] act_in_q             [ROWS];
  logic                  act_valid_q;
  logic [7:0]            weight_scale_in_q    [COLS];
  logic                  weight_scale_valid_q [COLS];
  logic [7:0]            act_scale_in_q       [ROWS];
  logic                  act_scale_valid_q    [ROWS];

  // [K1c-b 2026-07-28] recapture split per quadrant-column/row: each slice
  // clocks on its CONSUMER quadrant's array copy (weight col c feeds skew
  // chain c -> row-0 cell(0,c): QI = c/8; act row r feeds col-0 cell(r,0):
  // QI = (r/8)*2). The two shared valid bits ride quad 0's copy (arbitrary
  // under the per-beat identity lemma — preflight §1.2 disclosure). Per-flop
  // behavior is bit-identical to the pre-split single block: same reset,
  // same data, and quad_step_arr[q](t) == array_step_en(t) on every beat
  // (shadow SVA in gen_step_quad).
  generate
    for (genvar gc = 0; gc < COLS; gc++) begin : gen_recap_wcol
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          weight_in_q[gc]          <= '0;
          weight_scale_in_q[gc]    <= 8'd0;
          weight_scale_valid_q[gc] <= 1'b0;
        end else if (quad_step_arr[gc / 8]) begin       // [K1c-b]
          weight_in_q[gc]          <= weight_in[gc];
          weight_scale_in_q[gc]    <= weight_scale_in[gc];
          weight_scale_valid_q[gc] <= weight_scale_valid[gc];
        end
      end
    end
    for (genvar gr = 0; gr < ROWS; gr++) begin : gen_recap_arow
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          act_in_q[gr]          <= '0;
          act_scale_in_q[gr]    <= 8'd0;
          act_scale_valid_q[gr] <= 1'b0;
        end else if (quad_step_arr[(gr / 8) * 2]) begin  // [K1c-b]
          act_in_q[gr]          <= act_in[gr];
          act_scale_in_q[gr]    <= act_scale_in[gr];
          act_scale_valid_q[gr] <= act_scale_valid[gr];
        end
      end
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      weight_valid_q <= 1'b0;
      act_valid_q    <= 1'b0;
    end else if (quad_step_arr[0]) begin                 // [K1c-b] shared bits
      weight_valid_q <= weight_valid;
      act_valid_q    <= act_valid;
    end
  end

  // OS (dataflow_sel=0): use the recaptured operands/scales. WS (=1): direct.
  logic [DATA_WIDTH-1:0] weight_in_eff          [COLS];
  logic                  weight_valid_eff;
  logic [DATA_WIDTH-1:0] act_in_eff             [ROWS];
  logic                  act_valid_eff;
  logic [7:0]            weight_scale_in_eff    [COLS];
  logic                  weight_scale_valid_eff [COLS];
  logic [7:0]            act_scale_in_eff       [ROWS];
  logic                  act_scale_valid_eff    [ROWS];

  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      weight_in_eff[c]          = dataflow_sel ? weight_in[c]          : weight_in_q[c];
      weight_scale_in_eff[c]    = dataflow_sel ? weight_scale_in[c]    : weight_scale_in_q[c];
      weight_scale_valid_eff[c] = dataflow_sel ? weight_scale_valid[c] : weight_scale_valid_q[c];
    end
    for (int r = 0; r < ROWS; r++) begin
      act_in_eff[r]          = dataflow_sel ? act_in[r]          : act_in_q[r];
      act_scale_in_eff[r]    = dataflow_sel ? act_scale_in[r]    : act_scale_in_q[r];
      act_scale_valid_eff[r] = dataflow_sel ? act_scale_valid[r] : act_scale_valid_q[r];
    end
    weight_valid_eff = dataflow_sel ? weight_valid : weight_valid_q;
    act_valid_eff    = dataflow_sel ? act_valid    : act_valid_q;
  end

  // ==========================================================================
  // [3a-1 S2 2026-08-03] Sparse Ingress Queue（v4.2b Round B — P1-3）已删除
  // ==========================================================================
  //
  // 规格 §4.1「K 令牌通路退役」（`D-SPARSE-SPEC-2026-08-01` 连带批②）：
  // per-tile 常数 N ⇒ 稀疏 K 步长是 controller 内部纯函数，不再由 Vector 递送
  // fragment 令牌 ⇒ 队列、双臂 generate、12 条 tie、SPARSE_QUEUE_DEPTH、
  // 内部信号 sparse_deq_data / sparse_queue_full / sparse_queue_empty 全部删除，
  // 文件 Tensor/tensor_sparse_ingress_queue.sv 同 commit 删除。
  //
  // 🔴 原 gen_no_sparse_queue 臂里的 C1 挂死守卫**不是原地搬家，是覆盖新增**：
  //    它活在 `SPARSE_QUEUE_EN=0` 的 generate 臂里，而该参数全仓零 override
  //    ⇒ 那条臂**从未 elaborate 过一次**，守卫从未通电（RED-0 实证：写 0x08=0x01
  //    后零 Assertion failed、零 %Error，tile 只是静默挂死超时 ——
  //    aichip_run_logs/3a1_guard_red0_20260802.txt）。
  //    改写后的守卫在下方 Assertions 段的**无条件作用域**里（这半句今天仍真）。
  //    ▲[3a-4/M2 2026-08-06 订正] ~~红证 = RED-1。~~ —— **RED-1（`0x08=0x01`）已于本片
  //    按计划由红转绿**（C1 白名单放宽到 `{EXEC_DENSE, EXEC_SPARSE_STRUCT}`）。
  //    今天该守卫的红证 = **保留编码两发**：`0x08=0x03`（`EXEC_SPARSE_RESERVED`）与
  //    `0x08=0x02`（`EXEC_DENSE_RESERVED`，M2 新补，把负控补齐到 2/2）；
  //    另有 WS 绊线一发（`dataflow_sel=1` × 非 dense）。
  //    历史红证 log 的失效注记见 `aichip_run_logs/*_sidecar_20260806.md`（逐份，不改 log 正文）。

  // ==========================================================================
  // [C1 2026-07-31] 双 SCU（adaptive zero-skip）已删除 —— D-SPARSE-NM-2026-07-31。
  // SCU 是恒等变换（压错轴 + scatter-back 逆映射，SPARSE_NM_Decision_and_Cost §1），
  // 且 sparse_compress_en 自 D-SCU-RESERVED 起恒 0（MMIO 0x08 bit4 RESERVED 语义
  // 不变，守门 = tb/test_scu_tile.py::test_scu_tile_bit_reserved）。
  // 回收（m1t_b56 网表实测）：24,387 cell / 902 DFF / ~0.84% stdcell 面积。
  // ==========================================================================

  // ==========================================================================
  // Scale Boundary Hold Registers (v4.2: A6 fix — tile_start clears loaded)
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int c = 0; c < COLS; c++) begin
        weight_scale_hold[c]   <= 8'd0;
        weight_scale_loaded[c] <= 1'b0;
      end
      for (int r = 0; r < ROWS; r++) begin
        act_scale_hold[r]   <= 8'd0;
        act_scale_loaded[r] <= 1'b0;
      end
    end else if (tile_start) begin
      // v4.2 A6: Clear loaded flags on new tile boundary.
      // Hold values are NOT cleared — if the same scale is reused,
      // controller can immediately re-assert scale_valid.
      for (int c = 0; c < COLS; c++)
        weight_scale_loaded[c] <= 1'b0;
      for (int r = 0; r < ROWS; r++)
        act_scale_loaded[r] <= 1'b0;
    end else begin
      for (int c = 0; c < COLS; c++) begin
        if (weight_scale_valid_eff[c]) begin
          weight_scale_hold[c]   <= weight_scale_in_eff[c];
          weight_scale_loaded[c] <= 1'b1;
        end
      end
      for (int r = 0; r < ROWS; r++) begin
        if (act_scale_valid_eff[r]) begin
          act_scale_hold[r]   <= act_scale_in_eff[r];
          act_scale_loaded[r] <= 1'b1;
        end
      end
    end
  end

  // ==========================================================================
  // Boundary Initialization with OS/WS MUX + Scale Pass
  // ==========================================================================
  //
  // [C1 2026-07-31] SCU 已删除，boundary 直通（原 v4.2 A8 的 scu_valid mux 随之移除）。
  // --------------------------------------------------------------------------
  // F2 (HW-REVIEW T1): Weight column-skew — mirror of the activation row-skew.
  // --------------------------------------------------------------------------
  // Pre-skew weight (direct), exactly like act_pre_skew.
  logic [DATA_WIDTH-1:0] wgt_pre_skew       [COLS];
  logic [7:0]            wgt_scale_pre_skew [COLS];
  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      wgt_pre_skew[c] = weight_in_eff[c];
      wgt_scale_pre_skew[c] = weight_scale_hold[c];
    end
  end

  // Column-skew shift registers (triangular: column c has depth c), transposed
  // mirror of act_skew_sr (row r depth r). So B[k][c] reaches weight_pass[0][c]
  // delayed by c, matching A[r][k]'s row-skew of r; combined with the per-row
  // weight hop and the pre-register weight multiply (mac_cell dataflow_sel=0),
  // B[k][c] and A[r][k] meet at cell(r,c) on the same cycle (k+r+c+1).
  // Clocked by array_step_en so the OS pipeline advances in COMPUTE and DRAIN.
  // Reset only on rst_n; the tail zero-pad (operand_fetch) flushes these between
  // back-to-back tiles. The matching skew on the scale keeps it aligned with data.
  logic [DATA_WIDTH-1:0] wgt_skew_sr        [COLS][COLS];
  logic [7:0]            wgt_scale_skew_sr  [COLS][COLS];

  generate
    for (genvar c = 0; c < COLS; c++) begin : gen_wgt_skew_col
      // Partial sum from top: always 0 at boundary (OS local accumulation)
      assign psum_pass[0][c] = '0;

      if (c == 0) begin : gen_wgt_skew_bypass
        // Column 0: no skew (direct connection), mirror of act row 0.
        assign weight_pass[0][0]       = wgt_pre_skew[0];
        assign weight_scale_pass[0][0] = wgt_scale_pre_skew[0];
      end else begin : gen_wgt_skew_delay
        // Column c: depth-c shift register on both data and scale.
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            for (int d = 0; d < c; d++) begin
              wgt_skew_sr[c][d]       <= '0;
              wgt_scale_skew_sr[c][d] <= 8'd0;
            end
          end else if (quad_step_arr[c / 8]) begin  // [K1c-b] chain c feeds cell(0,c)
            // Stage 0: load from pre-skew input
            wgt_skew_sr[c][0]       <= wgt_pre_skew[c];
            wgt_scale_skew_sr[c][0] <= wgt_scale_pre_skew[c];
            // Stages 1..c-1: shift chain
            for (int d = 1; d < c; d++) begin
              wgt_skew_sr[c][d]       <= wgt_skew_sr[c][d-1];
              wgt_scale_skew_sr[c][d] <= wgt_scale_skew_sr[c][d-1];
            end
          end
        end
        // Output: skewed in OS (dataflow_sel=0); in WS (=1) the weight boundary
        // is the DIRECT pre-skew value, bit-identical to the pre-T1 array (WS is
        // weight-stationary — the column-skew is an OS-only construct). This keeps
        // the WS weight path untouched even though the SR still clocks (unused).
        assign weight_pass[0][c]       = dataflow_sel ? wgt_pre_skew[c]
                                                      : wgt_skew_sr[c][c-1];
        assign weight_scale_pass[0][c] = dataflow_sel ? wgt_scale_pre_skew[c]
                                                      : wgt_scale_skew_sr[c][c-1];
      end
    end
  endgenerate

  // ==========================================================================
  // OS Skewed Input Timing (v4.1 Round 5 — P13)
  // ==========================================================================
  //
  // v4.2: Skew shift registers gated by array_step_en (was compute_en).

  // Pre-skew activation: direct
  logic [DATA_WIDTH-1:0] act_pre_skew [ROWS];
  logic [7:0]            act_scale_pre_skew [ROWS];

  always_comb begin
    for (int r = 0; r < ROWS; r++) begin
      act_pre_skew[r] = act_in_eff[r];
      act_scale_pre_skew[r] = act_scale_hold[r];
    end
  end

  // Skew shift registers (triangular: row r has depth r)
  logic [DATA_WIDTH-1:0] act_skew_sr       [ROWS][ROWS];  // [row][stage]
  logic [7:0]            act_scale_skew_sr  [ROWS][ROWS];

  generate
    for (genvar r = 0; r < ROWS; r++) begin : gen_skew_row
      if (r == 0) begin : gen_skew_bypass
        // Row 0: no skew (direct connection)
        assign act_pass[0][0]       = act_pre_skew[0];
        assign act_scale_pass[0][0] = act_scale_pre_skew[0];
      end else begin : gen_skew_delay
        // Row r: depth-r shift register
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n) begin
            for (int d = 0; d < r; d++) begin
              act_skew_sr[r][d]       <= '0;
              act_scale_skew_sr[r][d] <= 8'd0;
            end
          end else if (quad_step_arr[(r / 8) * 2]) begin  // [K1c-b] chain r feeds cell(r,0)
            // Stage 0: load from pre-skew input
            act_skew_sr[r][0]       <= act_pre_skew[r];
            act_scale_skew_sr[r][0] <= act_scale_pre_skew[r];
            // Stages 1..r-1: shift chain
            for (int d = 1; d < r; d++) begin
              act_skew_sr[r][d]       <= act_skew_sr[r][d-1];
              act_scale_skew_sr[r][d] <= act_scale_skew_sr[r][d-1];
            end
          end
        end
        // Output: last stage of shift register
        assign act_pass[r][0]       = act_skew_sr[r][r-1];
        assign act_scale_pass[r][0] = act_scale_skew_sr[r][r-1];
      end
    end
  endgenerate

  // ==========================================================================
  // Activation Systolic Registers + Scale Pass Pipeline (Array-Level)
  // ==========================================================================
  //
  // v4.2: Gated by array_step_en (was compute_en).
  // Pipeline must advance in both COMPUTE and DRAIN phases.
  generate
    for (genvar r = 0; r < ROWS; r++) begin : gen_act_reg_row
      for (genvar c = 0; c < COLS; c++) begin : gen_act_reg_col
        // [K1c-b] consumer-rule quadrant: this register feeds cell(r,c+1)
        // (clamped at the east edge); its EN takes that quadrant's array
        // copy. Per-beat identical to array_step_en (shadow SVA).
        localparam int QIA = (r / 8) * 2 + ((((c + 1) > 15) ? 15 : (c + 1)) / 8);

        // ---- Activation data pass (west→east) ----
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            act_reg[r][c] <= '0;
          else if (quad_step_arr[QIA])       // [K1c-b] was array_step_en
            act_reg[r][c] <= act_pass[r][c];
        end
        assign act_pass[r][c+1] = act_reg[r][c];

        // ---- Act scale pass (west→east, symmetric with data) ----
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            act_scale_pass[r][c+1] <= 8'd0;
          else if (quad_step_arr[QIA])       // [K1c-b] was array_step_en
            act_scale_pass[r][c+1] <= act_scale_pass[r][c];
        end
      end
    end
  endgenerate

  // ==========================================================================
  // 2D MAC Cell Array + Weight Scale Pass Pipeline (R6: OFU removed)
  // ==========================================================================
  //
  // This generate block instantiates 256 (ROWS×COLS) mac_cell modules.
  //
  // R6 structural changes vs v4.2c:
  //   - Submodule: upe_core_sparse → mac_cell
  //   - Instance name: u_upe → u_mac
  //   - NEW connection: .capture_fire (broadcast from array top-level)
  //   - NEW connection: .fp_acc_snapshot (collected into pe_fp_acc_snapshot)
  //   - REMOVED: per-PE upe_output_format_unit u_ofu (...) instantiation
  //   - REMOVED: .result_valid () (mac_cell no longer has this port)
  //   - CHANGED: .skip_accumulation() left unconnected (pe_skip wire removed)
  //   - CHANGED: .weight_load(weight_load_effective) uses named intermediate

  // ==========================================================================
  // [K1c 2026-07-27] per-quadrant control clone registers
  // ==========================================================================
  //
  // Four instances of tensor_ctrl_quad (module at the bottom of this file —
  // LANE2/C5 file-placement discipline, zero VERILOG_FILES change), one per
  // 8x8 quadrant: QI = (r/8)*2 + (c/8). Each registers the controller's
  // next-state views, so quad copy(t) == live signal(t) on every beat.
  // SURVIVAL MECHANISM (2026-07-27 netlist-measured; the earlier "distinct
  // module instances never merge" claim was WRONG and cost a synth run):
  //   opt_merge hashes on (cell type, input connections) and has NO
  //   cross-instance exemption — four same-input clones ALWAYS fold once
  //   they land in the same module. mac_cell x256 survives because each
  //   cell's inputs differ, not because it is a separate module.
  //   asap7 sets SYNTH_MINIMUM_KEEP_SIZE=1000 (platforms/asap7/config.mk:27)
  //   and synth.tcl:131-138 runs `keep_hierarchy -min_cost`, which ungroups
  //   a 7-flop module like this one — after which the fold is inevitable.
  //   The ONLY production-proven way to hold the boundary is
  //   SYNTH_KEEP_MODULES (synth.tcl:75-93 → setattr keep_hierarchy 1);
  //   precedent: vec_lane_align (376 cells, well under 1000) keeps all 16
  //   module definitions in m1v_lane2's netlist because aichip_vector sets
  //   that variable. m1t_c6b/config.mk sets it for tensor_ctrl_quad.
  //   🔴 Without that variable set for the design being built, this generate
  //   collapses to ONE register set driving all 256 cells.
  // ========================================================================
  // [K1c-c 2026-07-30] 银行 2（cell 侧使能）从 4 个 8x8 象限细分到
  //   **16 个 4x4 子块**：SB = (r/4)*4 + (c/4)。
  //
  // 为什么只细分这一条银行（逐信号实测归属，批5 覆盖探针 §2-3）：
  //   · 银行 2 = 本数组 `quad_*`（tensor_ctrl_quad）-> 喂 mac_cell 的
  //     array_step_en / weight_stream_en / clear_acc / capture_fire / lane_valid
  //     ⇒ **全部违例族都挂在它下面**，且批4a 实测 c6f 系 4/4 族的 worst 路径
  //     都起自 `gen_ctrl_quad[1].u_ctrl_quad/step_en_o`，广播段
  //     **1135.42 ps / 20 级 = 全径 60.3%**（k1cc_cover_20260730.log）。
  //   · 银行 1 = `quad_step_arr`（tensor_step_quad）-> 喂 skew 链 / recapture /
  //     act_reg / weight_scale_pass，这些族**全部 MET**（worst +351.46~+971.65）
  //     ⇒ **不动**。连带好处：`k1cb_synth_structprobe.tcl` 的反序解码与三向量
  //     断言 1521/1124/275 全部服务银行 1 ⇒ **无需重算**。
  //
  // DFF 账（§5.0c-2 逐信号列表复核）：ctrl 7 flop × 4 = 28 -> 7 × 16 = 112，
  //   step 1 × 4 = 4 不变 ⇒ 32 -> 116 = **+84 DFF**。
  //   （🔴 文档反复出现的"+24 DFF"全仓无推导；那是另一种只细分 step 信号的
  //     读法。本实现取"整条银行 2 细分"——多 72 个 flop 换掉一个新模块 +
  //     退役 step_en_o 端口 + 影子 SVA 搬迁的全部风险，在 2.85M 实例的设计里
  //     84 个 flop 是 0.003%。）
  //
  // 恒等性：Lemma 1（`K1cb_Preflight_ArrayStepQuad_GRA_2026-07-28.md` §1.3）
  //   —— 16 个副本同为 posedge 无门控寄存器、同 D 网、同 rst_n、同复位值 0
  //   ⇒ 逐拍同值 ⇒ 任意归属在功能上无关，只影响物理跨度与结构硬门记账。
  //   跨子块数据传递（weight_stream_out r->r+1 等）的边界从 1 条（7|8）变成
  //   3 条（3|4、7|8、11|12），Lemma 1 的锁步论证逐条照用。
  //   影子 SVA 随 genvar 自动扩到 16 个实例。
  // ⚠️ 存活依赖 SYNTH_KEEP_MODULES 含 tensor_ctrl_quad（模块名未变，配置无需改）：
  //   KEEP 阻止 ungroup ⇒ opt_merge 看不穿模块边界 ⇒ 16 个同 D 副本不被折叠。
  //   这正是 K1c-b 的 4 个副本存活的同一机制。
  // ========================================================================
  logic [3:0] quad_tail_mask   [16];
  logic       quad_clear_acc   [16];
  logic       quad_capture_fire[16];
  logic       quad_step_en     [16];

  generate
    for (genvar gq = 0; gq < 16; gq++) begin : gen_ctrl_quad
      tensor_ctrl_quad u_ctrl_quad (
        .clk            (clk),
        .rst_n          (rst_n),
        .tail_mask_d_i  (ctrl_tail_mask_d),
        .clear_acc_d_i  (ctrl_clear_acc_d),
        .capture_fire_d_i (ctrl_capture_fire_d),
        .step_d_i       (ctrl_step_d),
        .tail_mask_o    (quad_tail_mask[gq]),
        .clear_acc_o    (quad_clear_acc[gq]),
        .capture_fire_o (quad_capture_fire[gq]),
        .step_en_o      (quad_step_en[gq])
      );

      // [K1c] per-quadrant shadow identity: the clone must equal the LIVE
      // controller output on EVERY beat (the live nets stay alive via the
      // array-level consumers + MMIO perf counters). A diverging beat is
      // NEW-1-class data corruption — $fatal, K1a S1 discipline.
      // synopsys translate_off
      assert property (@(posedge clk) disable iff (!rst_n)
          (quad_tail_mask[gq] == active_tail_mask)
          && (quad_clear_acc[gq] == clear_acc)
          && (quad_capture_fire[gq] == capture_fire)
          && (quad_step_en[gq] == array_step_en)
      ) else $fatal(1, "K1C-c: subblock %0d/16 clone diverged from live controls (tm %h/%h clr %0b/%0b cap %0b/%0b step %0b/%0b)",
                    gq, quad_tail_mask[gq], active_tail_mask,
                    quad_clear_acc[gq], clear_acc,
                    quad_capture_fire[gq], capture_fire,
                    quad_step_en[gq], array_step_en);
      // synopsys translate_on
    end
  endgenerate

  generate
    for (genvar r = 0; r < ROWS; r++) begin : gen_row
      for (genvar c = 0; c < COLS; c++) begin : gen_col

        // [K1c] quadrant index + per-quadrant weight_load view: the OS
        // branch of weight_load_effective is array_step_en (:392-393) — it
        // must follow the quadrant copy or the step_en comb leg re-enters
        // the weight path (the review F1-stepen leg). dataflow_sel is
        // quasi-static (tile_desc_q) and weight_load_en stays on the live
        // net (WS LOAD phase only — not a measured wall).
        // [K1c-c] 4x4 子块索引（原 4 象限：(r/8)*2 + (c/8)）。
        // consumer rule 不变：寄存器归其消费 cell 的块 —— 这里消费者就是本 cell。
        localparam int QI = (r / 4) * 4 + (c / 4);
        logic wle_quad;
        assign wle_quad = dataflow_sel ? weight_load : quad_step_en[QI];

        // OS/WS psum input MUX
        logic signed [ACC_WIDTH-1:0] pe_psum_in;
        assign pe_psum_in = dataflow_sel ? psum_pass[r][c] : '0;

        mac_cell #(
          .ACC_WIDTH     (ACC_WIDTH),
          .WEIGHT_REG_EN (1'b1),
          .ZEROSKIP_EN   (ZEROSKIP_EN)
        ) u_mac (
          // Clock / Reset
          .clk              (clk),
          .rst_n            (rst_n),

          // Control ([K1c] cell-broadcast controls take the QUADRANT copies;
          // per-beat identity with the live nets — shadow SVA above)
          .mode             (mode),
          .mac_en           (issue_en),             // v4.2: was compute_en
          .array_step_en    (quad_step_en[QI]),     // §C6 stage clock-enable [K1c]
          .clear_acc        (quad_clear_acc[QI]),   // [K1c]

          // OS-GEMM T1: pre-register weight multiply in OS (dataflow_sel=0)
          .dataflow_sel     (dataflow_sel),

          // R6 NEW: Snapshot capture pulse (broadcast to all cells)
          .capture_fire     (quad_capture_fire[QI]), // [K1c]

          // v4.2: Lane valid / tail mask from controller
          .lane_valid       (quad_tail_mask[QI]),   // [K1c]

          // Weight path (north→south systolic)
          .weight_in        (weight_pass[r][c]),
          .weight_load      (wle_quad),              // [K1c] OS branch = quadrant step
          .weight_stream_en (quad_step_en[QI]),      // [K1c]
          .weight_stream_out(weight_pass[r+1][c]),

          // Activation (from array-level systolic registers)
          .act_in           (act_pass[r][c]),

          // MX scale from systolic sideband pass
          .mx_scale_a_cur   (act_scale_pass[r][c]),
          .mx_scale_b_cur   (weight_scale_pass[r][c]),

          // Partial sum chain (north→south)
          .psum_in          (pe_psum_in),
          .psum_out         (psum_pass[r+1][c]),

          // FP accumulator outputs (live + snapshot)
          .fp_acc_out       (pe_fp_acc_out[r][c]),
          .fp_acc_snapshot  (pe_fp_acc_snapshot[r][c]),  // R6 NEW

          // Sparsity (adaptive, not structured)
          .sparsity_map_in  (4'b0000),
          .sparsity_map_out (pe_sparsity_map[r][c]),
          .skip_accumulation()  // R6 (code opt #4): pe_skip dead wire removed
        );

        // ---- Weight scale pass (north→south, symmetric with data) ----
        // [K1c-b] consumer-rule quadrant: this register feeds cell(r+1,c)
        // (clamped at the south edge); EN takes that quadrant's array copy.
        localparam int QIW = ((((r + 1) > 15) ? 15 : (r + 1)) / 8) * 2 + (c / 8);
        always_ff @(posedge clk or negedge rst_n) begin
          if (!rst_n)
            weight_scale_pass[r+1][c] <= 8'd0;
          else if (quad_step_arr[QIW])           // [K1c-b] was array_step_en
            weight_scale_pass[r+1][c] <= weight_scale_pass[r][c];
        end

        // ----- Result Collection -----
        assign result[r][c]    = psum_pass[r+1][c];
        assign fp_result[r][c] = pe_fp_acc_out[r][c];

        // R6: per-MAC OFU instantiation REMOVED.
        //     See Vector_Unit_OFU_Sidecar_Design_Plan.md §5.5 for details.
        //     output_format_unit.sv is preserved in the codebase but is no
        //     longer instantiated here. Testbenches may use it as a golden
        //     model. Phase E3 will wrap it as a Vector-side 16-lane sidecar.

      end // gen_col
    end // gen_row
  endgenerate

  // ==========================================================================
  // [P4/D-CONV-BASE] SECONDARY ABLATION — faithful-v4.2c 256x per-MAC OFU bank
  // ==========================================================================
  // CONVERTER_PER_MAC=1 re-introduces one OFU per MAC cell (the v4.2c arrangement
  // R6 removed), formatting each cell's snapshot to standard FP. This is an AREA-
  // measurement harness: the 256 formatted results are XOR-reduced + registered to
  // a digest output so synthesis can't optimize the bank away. =0 ties the digest
  // to '0 and elaborates nothing (bit-identical). See ConverterBased_Baseline_Plan.
  generate
    if (CONVERTER_PER_MAC) begin : gen_pmac
      logic [31:0] pmac_res [ROWS][COLS];
      for (genvar r = 0; r < ROWS; r++) begin : gen_pmac_row
        for (genvar c = 0; c < COLS; c++) begin : gen_pmac_col
          output_format_unit u_pmac_ofu (
            .acc_in     (pe_fp_acc_snapshot[r][c]),
            .out_fmt    (OUT_FMT_FP32),     // widest fmt = full OFU area exercised
            .round_mode (OUT_ROUND_RNE),
            .result     (pmac_res[r][c]),
            .ofu_valid  ()
          );
        end
      end
      logic [31:0] pmac_xor;
      always_comb begin
        pmac_xor = '0;
        for (int r = 0; r < ROWS; r++)
          for (int c = 0; c < COLS; c++)
            pmac_xor = pmac_xor ^ pmac_res[r][c];
      end
      logic [31:0] pmac_digest_q;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pmac_digest_q <= '0;
        else        pmac_digest_q <= pmac_xor;
      end
      assign pmac_ofu_digest = pmac_digest_q;
    end else begin : gen_no_pmac
      assign pmac_ofu_digest = '0;
    end
  endgenerate

  // ==========================================================================
  // Snapshot Bank Row Mux (R6 NEW)
  // ==========================================================================
  //
  // The snapshot bank is physically distributed (one 61-bit register per
  // MAC cell) but is exposed to the egress fragmentizer through a single
  // row-selection MUX at the array top level.
  //
  //   pe_fp_acc_snapshot[r][c] : distributed storage (256 cell-local regs)
  //   snapshot_read_row         : row index from fragmentizer (0..15)
  //   snapshot_row_data[c]      : selected row, one fp_acc_output_t per col
  //
  // Structure: 16 parallel 16:1 muxes (one per column), each selecting the
  // correct row's cell based on snapshot_read_row. Pure combinational —
  // no read latency. Total cost ≈ 15K gates (small compared to the 200K
  // gates saved by removing the per-MAC OFU instances).
  //
  // snapshot_read_en is currently informational (fragmentizer asserts it
  // during SCAN, but the row mux output is always available). A future
  // low-power optimization could gate the mux on read_en.
  //
  // Timing invariant: the fragmentizer's snapshot_read_row is valid any
  // time snapshot_row_data is being sampled. When snapshot_read_en is 0,
  // the fragmentizer ignores snapshot_row_data (and the mux output is
  // still combinationally valid but simply not consumed downstream).

  always_comb begin
    for (int c = 0; c < COLS; c++)
      snapshot_row_data[c] = pe_fp_acc_snapshot[snapshot_read_row][c];
  end

  // ==========================================================================
  // Result Valid Generation (v4.2a P0-2 — unified)
  // ==========================================================================
  //
  // v4.2a: result_valid is driven by the controller's authoritative
  // ctrl_result_valid input. This eliminates dual result_valid semantics
  // (controller done pulse vs array edge-detect) that existed in v4.2.
  //
  // The edge-detect signal is retained as debug_result_valid for standalone
  // array testing where no controller is present. It should NOT be used
  // in integrated systems.

  assign result_valid = ctrl_result_valid;

  // ---- Debug fallback (standalone array testing only) ----
  logic array_step_en_d1;
  logic debug_result_valid;  // NOT connected to output — debug only

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      array_step_en_d1 <= 1'b0;
    else
      array_step_en_d1 <= array_step_en;
  end

  assign debug_result_valid = array_step_en_d1 & ~array_step_en;

  // ==========================================================================
  // Assertions
  // ==========================================================================
  // synopsys translate_off

  // A1 defense: clear_acc must not coincide with issue_en at array level
  assert property (@(posedge clk) disable iff (!rst_n)
      !(clear_acc && issue_en)
  ) else $fatal(1, "TENSOR_MAC_ARRAY [A1]: clear_acc and issue_en simultaneous");

  // A6 verification: after tile_start, scale_loaded must be cleared
  assert property (@(posedge clk) disable iff (!rst_n)
      tile_start |=> (!weight_scale_loaded[0] && !act_scale_loaded[0])
  ) else $error("TENSOR_MAC_ARRAY [A6]: scale_loaded not cleared after tile_start");

  // R4 (updated): MX mode issue_en requires scales loaded
  // R6: uses mode_is_mx() helper from tensor_pkg.
  generate
    for (genvar c = 0; c < COLS; c++) begin : gen_wscale_assert
      assert property (@(posedge clk) disable iff (!rst_n)
          mode_is_mx(mode) && issue_en
          |-> weight_scale_loaded[c]
      ) else $error("TENSOR_MAC_ARRAY: MX issue started before weight_scale_loaded[%0d]", c);
    end

    for (genvar r = 0; r < ROWS; r++) begin : gen_ascale_assert
      assert property (@(posedge clk) disable iff (!rst_n)
          mode_is_mx(mode) && issue_en
          |-> act_scale_loaded[r]
      ) else $error("TENSOR_MAC_ARRAY: MX issue started before act_scale_loaded[%0d]", r);
    end
  endgenerate

  // ---- v4.2b Round B assertions ----
  //
  // [3a-1 S2 2026-08-03] 两条 P1-3 SVA 已随队列删除：
  //   (a) `tile_start |=> (sparse_queue_level == '0)` —— 观测量消失。
  //   (b) `(sparse_exec_mode != EXEC_SPARSE_STRUCT) |-> !(sparse_deq_valid && ctrl_frag_ready)`
  //       —— 「稀疏 fragment 泄漏进 dense tile」的唯一守门，**覆盖净损失**，
  //       等价物（描述符层面 WS×sparse 拒收 + 可观测 sticky）由 3a-7 补。

  // ---- [3a-1 S2 → 3a-4/M2 已放宽] 保留编码守卫（原「稀疏执行挂死守卫」）----
  //
  // ▲**[3a-4/M2 2026-08-06] 本块整体订正 —— 下面划掉的是放宽前的理由，保留以备追溯。**
  //   ~~K token path retired: sparse execution has no data source until 3a-3..3a-6.~~
  //   ~~本窗口内任何 EXEC_SPARSE_STRUCT 请求都会让 tile FSM 停摆（S2 后）或**静默~~
  //   ~~退化成 dense 算出看起来合理但错的结果**（S3 后，比挂死更坏）⇒ 不可恢复，$fatal。~~
  //
  // **今天的真值**：白名单已放宽为 `inside {EXEC_DENSE, EXEC_SPARSE_STRUCT}`。
  //   放宽的**转移论证是结构性的、不是声称的**：`sparse_exec_mode` 在本模块实测
  //   零数据通路消费者（全部命中 = 若干注释 + 端口声明 :254 + 本断言本体）
  //   ⇒ 放宽后 `EXEC_SPARSE_STRUCT` 在阵列里与 dense **逐位同构**。
  //   上面那句「静默退化成 dense…比挂死更坏」写于稀疏臂还在等 fragment 数据的年代，
  //   而 `frag_*` 入口端口已全删 —— **没有东西可退化了**（交接 2026-08-05 §0.2 已判其过期）。
  // 🔴 **本臂现在守的是保留编码**：`EXEC_DENSE_RESERVED=2'b10` 与
  //   `EXEC_SPARSE_RESERVED=2'b11` 仍必红，它们是白名单形态的**负控**（见下）。
  // 🔴 稀疏臂**可达 ≠ 已验证**：本片（M2）只打开可达性；pad 算术归 M4、
  //   `{4,0}` 相位与 k_step 归 M6′、数值 oracle 归 3c R5（显式真空）。
  //
  // 🔴 白名单形态 `inside {…}`，不是黑名单 `!= EXEC_SPARSE_STRUCT`：
  //    后者会放保留编码 EXEC_DENSE_RESERVED=2'b10 与 EXEC_SPARSE_RESERVED=2'b11 过闸
  //    （tensor_external_modules.sv 的 `8'h08:` 解码分支是裸类型转换
  //     exec_sparse_mode_e'(mmio_wr_data[1:0])，不做合法性校验；tensor_pkg.sv 的
  //     is_valid_descriptor 实测也不校验 sparse_mode）。
  // 🔴 `disable iff (!rst_n)` 不可省：dense 侧安全的另一半依据是
  //    tensor_tile_controller.sv 的 `tile_desc_q <= '0`（EXEC_DENSE == 2'b00）。
  //    ▲[3a-3] 上面三处原为钉行号（:607 / tensor_pkg:669 / tile_controller:582），
  //      实测后两个已漂（tensor_pkg.sv 当时只有 662 行、is_valid_descriptor 实为 :645；
  //      tile_desc_q <= '0 实为 :590）⇒ 一律改构件名锚（HANDOFF §3 明规）。
  //
  // ▲[3a-3 已落 2026-08-04] 原 `[3a-TEMP] n_cfg 臂由 3a-3 补` 已兑现，但**不在本模块**：
  //    本模块无 n_cfg 端口（加端口 = PROJECT_RULES §5.0f 的端口手术，其中两个方向纯静默），
  //    而描述符在 tensor_tile_controller 里本来就可见 ⇒ n_cfg 臂落在
  //    **tensor_tile_controller 的 §11 断言区**，tag = `TENSOR_TILE_CTRL [3a-3]`，
  //    观测量 tile_desc_q.n_cfg，$fatal 级。
  // 🔴 两臂【合取不替换】：本臂守 exec（[1:0]），那边守 n_cfg（[3:2]），是 0x08 里
  //    两个可独立驱动的字段。删本臂 ⇒ 直写 0x08=0x01/0x03 无人拦（3a-1 RED-1/RED-2
  //    的红臂当场退回零覆盖）。
  //    dataflow_sel × sparse 的组合拒收、以及 n_cfg 保留值的**写入时拒收**仍归 3a-7/3a-8。
  // 🔴 断言不进综合 ⇒ 本步起到 3a-8 硬闸落地前，不得跑 3d delta-synth。
  assert property (@(posedge clk) disable iff (!rst_n)
      sparse_exec_mode inside {EXEC_DENSE, EXEC_SPARSE_STRUCT}
  ) else $fatal(1, "TENSOR_MAC_ARRAY [3a-1]: sparse_exec_mode=%s unsupported (reserved encoding)",
                sparse_exec_mode.name());

  // ---- [3a-4/M2] C1-b：WS × 非 dense 的**仿真绊线**（堵 D3 敞口）------------
  //
  // 为什么放宽 C1 会开出这个敞口：`tensor_operand_fetch` 的两条 zero_pad 都带
  // `dataflow_sel == 1'b0` 门（OS-only），而 3a-1 S2 删掉的 P1-3(b) SVA
  // 正是「稀疏 fragment 泄漏进 dense tile」的唯一守门（本文件 :1100-1105 立的账，
  // 等价物归 3a-7）。⇒ 放宽后若有人跑 `WS × EXEC_SPARSE_STRUCT`，pad 拍不被强零，
  // 垃圾权重会真的进阵列，而且**算得出看起来合理的结果**。
  //
  // 🔴 措辞纪律（PROJECT_RULES §5.0d C7）：本条是 **$fatal 级仿真绊线**，不是硬闸、
  //    不是「已拒收」。描述符层面的**真拒收**（`is_valid_descriptor` 加
  //    `(dataflow_sel && sparse) → 0` + 可观测 sticky）仍归 **3a-7**（规格 §5.4）。
  // 🔴 本绊线当期**零覆盖**：全仓无 tile 级 WS 用例（`tensor_cmd_mmio_seq.sv` 的
  //    `A_CTRL` 写值 bit8 恒落在 `24'd0` 内、`tb/test_*.py` 无一处写 bit8）
  //    ⇒ 按 §5.0d 型 9，落笔当天已跑一发**人造 WS 注入**并落盘
  //    （`aichip_run_logs/s3a45_m2_probe_c1b_ws_20260806.log`）。
  // 🔴 dataflow_sel 本就是本模块端口（:254、顶层 :701 已接）⇒ 本条**无端口手术**。
  assert property (@(posedge clk) disable iff (!rst_n)
      !(dataflow_sel && (sparse_exec_mode != EXEC_DENSE))
  ) else $fatal(1, "TENSOR_MAC_ARRAY [3a-4/M2] WS-GUARD: dataflow_sel=1 with sparse_exec_mode=%s — WS x sparse has no zero-pad (os_zero_pad is OS-only); real rejection belongs to 3a-7",
                sparse_exec_mode.name());

  // ==========================================================================
  // [3a-7/P3 2026-08-05] ZEROSKIP-GUARD —— `ZEROSKIP_EN=0 与稀疏执行互斥`
  // ==========================================================================
  //
  // 本模块参数区（见上方 ZEROSKIP_EN 的头注）自 3a-1 S2 起就写着这句定性，
  // 但**至今只有注释、零检查**（3a-6 裁决把它二择一路由到 3a-7，两个分支一个都没落
  // —— 3a-7/R0 完整性审计以 major M14 点名，全仓 grep ZEROSKIP 零 assert）。
  //
  // 🔴 **为什么是 runtime SVA 而不是 elaboration 期 `if (!ZEROSKIP_EN) $fatal`**
  //   （预登记 §8.4 原写 elaboration 期，此处按下述规范性理由改判并留痕）：
  //   那句定性是**条件式**的 ——「ZEROSKIP_EN=0 **与稀疏执行**互斥」，
  //   而稀疏与否是 **per-tile 运行时**的（`sparse_mode` 随描述符走，规格 §5.1a-bis 逐字
  //   「同一 workload 里 tile A 走 dense、tile B 走 2:4 完全合法」）
  //   ⇒ elaboration 期**看不到**它，无条件 `$fatal` 会把「dense-only 下 ZEROSKIP_EN=0」
  //   这个合法配置也一并禁掉 —— 那比定性本身**更强**，属于借实现之名改规格。
  //   本条严格按定性的字面落：**只在真的跑稀疏 tile 时才响**。
  //
  // 机理（为什么互斥）：规格 §4.3 的 N=1 零行气泡与 §2.1 的尾窗 pad，其正确性建立在
  //   「零积对累加器**位精确**恒等」上（`mac_fp_acc_align.sv` 与 `mac_fp_accumulator.sv`
  //   的 align_skip 零积位精确）。ZEROSKIP_EN=0 时 `mac_cell` 不做零门控
  //   （`mac_cell.sv` 的 `mul_prod_gated` / `fp_acc_skip` 两处都带 `ZEROSKIP_EN &&`）
  //   ⇒ 零填充拍会真的进累加链，位精确恒等的前提消失。
  //
  // 🔴 措辞：本条是 `$fatal` 级**仿真绊线**，不是硬闸（`§5.0d` C7）。
  // 🔴 红样本：把 `ZEROSKIP_EN` 默认值临时改成 `1'b0` 后跑稀疏载体，本条必须响
  //   （执行件 = `aichip_run_logs/s3a7_p3_redarms_20260805.sh` 的 M3 臂，带 trap）。
  assert property (@(posedge clk) disable iff (!rst_n)
      (sparse_exec_mode != EXEC_DENSE) |-> ZEROSKIP_EN
  ) else $fatal(1, "TENSOR_MAC_ARRAY [3a-7/P3] ZEROSKIP-GUARD: sparse_exec_mode=%s with ZEROSKIP_EN=0 — N:M zero-pad correctness requires per-cell zero gating (align_skip bit-exact identity); the two are mutually exclusive",
                sparse_exec_mode.name());

  // ---- R6 NEW assertions ----

  // R6-1: snapshot_read_row must be within valid bounds.
  // If ROWS=16, snapshot_read_row is [3:0] so it cannot exceed 15, but
  // this assertion future-proofs against parameter changes.
  // [2026-07-24] the bound was `ROWS[3:0]`, which slices ROWS down to the INDEX's
  // own width: for ROWS=16 that is 4'd0, so the check read `row < 0` and fired on
  // every snapshot read. (Never showed because tb/Makefile lacked --assert.)
  // Compare one bit wider — which is also what makes the "future-proof against
  // parameter changes" intent actually work.
  assert property (@(posedge clk) disable iff (!rst_n)
      snapshot_read_en |-> ({1'b0, snapshot_read_row} < 5'(ROWS))
  ) else $error("TENSOR_MAC_ARRAY [R6-1]: snapshot_read_row out of range");

  // R6-2: capture_fire and clear_acc must not overlap at array level.
  // This mirrors the mac_cell defense-in-depth assertion; it catches
  // any wiring bug that would cause simultaneous capture and clear.
  assert property (@(posedge clk) disable iff (!rst_n)
      !(capture_fire && clear_acc)
  ) else $fatal(1, "TENSOR_MAC_ARRAY [R6-2]: capture_fire and clear_acc asserted simultaneously");

  // synopsys translate_on

endmodule

// ============================================================================
// [K1c 2026-07-27] tensor_ctrl_quad — per-quadrant control clone register
// ============================================================================
//
// A SEPARATE MODULE is NECESSARY BUT NOT SUFFICIENT for the four copies to
// survive (2026-07-27 netlist-measured — the first attempt lost all four to
// one). The module boundary only holds if the design's config lists this
// module in SYNTH_KEEP_MODULES: asap7's SYNTH_MINIMUM_KEEP_SIZE=1000
// ungroups anything this small, and once ungrouped, opt_merge folds the
// four same-input register sets by structural hash. See the banner above
// the generate block for the full mechanism and the vec_lane_align
// precedent. Reset values mirror the live signals' reset-time values
// (IDLE: mask 0, clear/capture/step 0).
module tensor_ctrl_quad (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [3:0] tail_mask_d_i,
    input  logic       clear_acc_d_i,
    input  logic       capture_fire_d_i,
    input  logic       step_d_i,
    output logic [3:0] tail_mask_o,
    output logic       clear_acc_o,
    output logic       capture_fire_o,
    output logic       step_en_o
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tail_mask_o    <= 4'b0000;
      clear_acc_o    <= 1'b0;
      capture_fire_o <= 1'b0;
      step_en_o      <= 1'b0;
    end else begin
      tail_mask_o    <= tail_mask_d_i;
      clear_acc_o    <= clear_acc_d_i;
      capture_fire_o <= capture_fire_d_i;
      step_en_o      <= step_d_i;
    end
  end
endmodule

// ============================================================================
// [K1c-b 2026-07-28] tensor_step_quad — per-quadrant ARRAY-level step copy
// ============================================================================
//
// One flop per quadrant, registering the controller's next-state step view —
// per-beat identical to array_step_en and to tensor_ctrl_quad.step_en_o.
// A SEPARATE MODULE (not a second output of tensor_ctrl_quad) because
// opt_merge folds same-D same-type flops within one module scope; the module
// boundary + SYNTH_KEEP_MODULES (base config, ORFS commit dc84b2207) is the
// only production-proven survival mechanism (K1c batch-2 netlist evidence,
// preflight §0.5). Reset mirrors the live signal's reset value (IDLE: 0).
module tensor_step_quad (
    input  logic clk,
    input  logic rst_n,
    input  logic step_d_i,
    output logic step_en_arr_o
);
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) step_en_arr_o <= 1'b0;
    else        step_en_arr_o <= step_d_i;
  end
endmodule

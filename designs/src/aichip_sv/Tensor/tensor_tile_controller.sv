// ============================================================================
// Tensor Tile Controller v4.3 (Round E1 / R5)
// ============================================================================
//
// Controls a single tile GEMM operation on the 16x16 MAC cell array. This is
// the orchestration brain of the Tensor Unit — it tracks tile lifecycle state,
// drives issue/drain/capture control signals, and manages the snapshot bank
// handshake with the egress fragmentizer.
//
// Previously named upe_tile_controller. Renamed as part of the Round E
// naming cleanup — "UPE tile" was ambiguous; the new name makes clear this
// is the Tensor Unit's tile lifecycle controller.
//
// ----------------------------------------------------------------------------
// Round E1 / R5 changes (THIS ROUND — multiple structural changes):
// ----------------------------------------------------------------------------
//
//   (1) RENAMES
//       - File:   upe_tile_controller.sv → tensor_tile_controller.sv
//       - Module: upe_tile_controller → tensor_tile_controller
//       - Import: upe_pkg → tensor_pkg
//       - Type:   upe_mode_e → tensor_mode_e
//       - Assertion tag: "TILE_CTRL" → "TENSOR_TILE_CTRL"
//       - Helper: 3-mode `(== MXFP4 || MXFP8 || MXINT8)` → `mode_is_mx(mode_q)`
//
//   (2) NEW FSM STATE: ST_CAPTURE (architectural contract)
//
//       The tile lifecycle gains a 1-cycle ST_CAPTURE state between ST_DRAIN
//       and ST_DONE. This is where `capture_fire` is asserted to all 256
//       MAC cells, atomically latching their fp_acc_out into the snapshot
//       bank (see mac_cell.sv Section 11).
//
//       New lifecycle:
//         IDLE → LOAD_WEIGHT → CLEAR_ACC → COMPUTE → DRAIN → CAPTURE → DONE
//                                                                   ^
//                                                               NEW (1 cycle)
//
//       The 1-cycle ST_CAPTURE overhead is architectural INTENT, not
//       implementation inefficiency. Future collapsed optimization can
//       merge CAPTURE with DRAIN's final cycle without changing the
//       4-phase contract (COMPUTE / DRAIN / CAPTURE / ROW_SCAN) at the
//       abstract level. Keeping it explicit makes the lifecycle clear for
//       verification, debug, and paper exposition.
//
//   (3) NEW: Snapshot bank handshake
//
//       - Input  snapshot_bank_available: from tensor_egress_fragmentizer.
//         High only when fragmentizer is in EG_IDLE (bank empty). The
//         DRAIN → CAPTURE transition is gated on this signal to prevent
//         overwriting a previous tile's snapshot while its egress row-scan
//         is still in progress.
//
//       - Output capture_fire: 1-cycle pulse during ST_CAPTURE, broadcast
//         to all 256 MAC cells via tensor_mac_array (R6).
//
//       - Output capture_done: 1-cycle pulse during ST_DONE, sent to
//         tensor_egress_fragmentizer to start the row scan. (Asserted
//         the cycle AFTER capture_fire so the snapshot bank is stable.)
//
//   (4) NEW: Descriptor-centric interface (code opt #6)
//
//       Replaced individual command ports (`mode`, `k_total`,
//       `sparse_exec_mode`) with a single authoritative `tile_desc` input
//       of type `tile_descriptor_t` (from tensor_pkg). This consolidates
//       all per-tile parameters into one struct and makes the descriptor
//       field addition path (new fields in future rounds) straightforward.
//
//       - NEW input:  tile_desc         (tile_descriptor_t — all per-tile params)
//       - NEW output: tile_desc_active  (latched copy, for R9 egress routing)
//       - REMOVED:    mode, k_total, sparse_exec_mode (individual ports)
//       - KEPT:       ~~frag_dense_k_advance, frag_valid, frag_group_last~~
//                     【3a-1 S3 2026-08-03 已全部删除】K 令牌通路退役后不存在
//                     per-cycle 稀疏握手信号；稀疏 K 步长是本模块内部纯函数。
//
//       Internal wiring: the controller latches tile_desc into tile_desc_q
//       on the start pulse. All per-tile parameters (mode_q, k_total_q,
//       sparse_mode_q, pack_advance_q) are derived combinationally from
//       tile_desc_q. This eliminates redundant registers and centralizes
//       state in a single descriptor.
//
//   (5) DRAIN cycle count: 15 → 16 minimum (1-cycle extra for bank handshake)
//
//       The ST_DRAIN cycle counter now runs 0..DRAIN_CYCLES (inclusive,
//       16 values), with array_step_en active only for cnt < DRAIN_CYCLES
//       (cnt 0..14, 15 cycles of stepping matching the original). The
//       extra cnt == DRAIN_CYCLES cycle is the bank_available handshake
//       cycle: if the bank is ready, state_d = ST_CAPTURE; if not, the
//       counter saturates at DRAIN_CYCLES and we stall until bank ready.
//
//       Impact: back-to-back tile throughput penalty ≈ 1 cycle per tile,
//       entirely negligible (for K=64, drain = 16/(64+16) ≈ 20% of total
//       time, so 1/16 overhead = 1.25% total slowdown).
//
// ----------------------------------------------------------------------------
// Features retained from v4.2c (unchanged):
// ----------------------------------------------------------------------------
//
//   A1: clear_acc in dedicated ST_CLEAR_ACC state, never overlaps issue/step
//   B3: k_iters_calc uses input k_total on start cycle (not stale register)
//   A4: active_tail_mask[3:0] generated for PE tail mask enforcement
//   P0-1: k_will_be_done combinational look-ahead (no COMPUTE bubble)
//   P1-1: ~~Sparse stall freezes entire pipeline (issue AND array_step)~~
//         【3a-1 S3】该 rationale 已作废（规格 §4.3 推翻 + K 令牌通路退役后无 stall）。
//         断言体 :1031-1035 本片 keep（D12），但它是**结构恒真占位、覆盖=0**：
//         issue_d/step_d 在 ST_COMPUTE 的三个子臂里全部同值 ⇒ 后件无条件为真。
//         🔴 3a-5 让两臂重新分叉时它才恢复判伪能力，届时必须先造红样本。
//   P1-2: ~~frag_ready is authoritative, no combinational ready<->valid loop~~【S3 删除】
//   P2-2: ~~frag_group_last triggers early DRAIN transition in sparse mode~~【S3 删除】
//   P2-3: MX_BLOCK_SIZE parameterized via tensor_pkg (shift-based boundary)
//
// Split control signals (v4.2):
//   issue_en      — PE may consume new K data (mac_en)
//   array_step_en — Systolic pipeline advances (OS skew, act/scale pass)
//
//   ST_COMPUTE (dense):  issue_en = 1, array_step_en = 1
//   ST_COMPUTE (sparse): issue_en = 1, array_step_en = 1   [3a-1 S3：逐字等于 dense 臂；
//                        原为 frag_valid，确定性稀疏节拍由 3a-5 落]
//   ST_DRAIN (stepping): issue_en = 0, array_step_en = 1
//   ST_DRAIN (waiting):  issue_en = 0, array_step_en = 0   (R5 NEW)
//   ST_CAPTURE:          issue_en = 0, array_step_en = 0   (R5 NEW)
//   Others:              issue_en = 0, array_step_en = 0
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R5 — tensor_pkg migration + ST_CAPTURE + descriptor interface)
// ============================================================================

module tensor_tile_controller
  import tensor_pkg::*;
#(
  parameter int ROWS = 16,
  parameter int COLS = 16
) (
  input  logic               clk,
  input  logic               rst_n,

  // =========================================================================
  // Command Interface (R5: descriptor-centric)
  // =========================================================================
  //
  // start pulse latches tile_desc into tile_desc_q. After latching, all
  // per-tile parameters (mode, k_total, sparse_mode, pack_advance) are
  // derived combinationally from tile_desc_q.
  input  logic               start,        // Pulse: begin tile GEMM
  input  tile_descriptor_t   tile_desc,    // Full per-tile descriptor (39 bits)

  // =========================================================================
  // [3a-1 S3 2026-08-03] Sparse Runtime Handshake —— 五个输入端口已删除
  // =========================================================================
  //   frag_dense_k_advance / frag_valid / frag_valid_next /
  //   frag_k_advance_next / frag_group_last
  // 规格 §4.1「K 令牌通路退役」：per-tile 常数 N ⇒ 稀疏 K 步长是本模块内部纯函数，
  // 不再由 Vector 经队列递送 fragment 令牌。产生方（sparse ingress queue）已随 S2 删除。

  // =========================================================================
  // Snapshot Bank Handshake (R5 NEW)
  // =========================================================================
  //
  // snapshot_bank_available: from tensor_egress_fragmentizer.
  //   HIGH only when fragmentizer is in EG_IDLE (bank empty and ready for
  //   a new tile snapshot). The DRAIN → CAPTURE transition is gated on
  //   this flag to prevent tile overwrite.
  input  logic               snapshot_bank_available,

  // =========================================================================
  // Status
  // =========================================================================
  output logic               busy,
  output logic               done,             // Pulse: tile GEMM complete

  // =========================================================================
  // Array Control — Split Signals
  // =========================================================================
  // issue_en:      PE may consume new K data (weight×act multiply fires)
  // array_step_en: Systolic pipeline advances (OS skew, act/scale pass, weight stream)
  output logic               issue_en,
  output logic               array_step_en,
  // [K1c 2026-07-27] one-beat-early (next-state) views of the four
  // array-broadcast controls, exported for the per-quadrant clone registers
  // in tensor_mac_array (tensor_ctrl_quad ×4). Each quadrant register's
  // output(t) == the live signal(t) — per-beat identity, same K1a contract.
  // The LIVE outputs below stay untouched (MMIO perf counters and every
  // non-array consumer keep their existing semantics and nets).
  output logic [3:0]         active_tail_mask_d,
  output logic               clear_acc_d,
  output logic               capture_fire_d,
  output logic               array_step_en_d,

  // =========================================================================
  // Accumulator Control
  // =========================================================================
  output logic               clear_acc,        // Pulse: clear accumulators (1 cycle)
  output logic               weight_load_en,   // High during LOAD_WEIGHT phase

  // =========================================================================
  // Snapshot Capture Control (R5 NEW)
  // =========================================================================
  //
  // capture_fire: 1-cycle pulse during ST_CAPTURE. Broadcast to all 256
  //   MAC cells via tensor_mac_array (R6). On the posedge ending ST_CAPTURE,
  //   each cell's fp_acc_snapshot_q latches its fp_acc_out.
  //
  // capture_done: 1-cycle pulse during ST_DONE (one cycle AFTER capture_fire).
  //   At this point the snapshot bank contents are stable (registered).
  //   Sent to tensor_egress_fragmentizer to start the row scan.
  output logic               capture_fire,
  output logic               capture_done,

  // =========================================================================
  // K Iteration Info
  // =========================================================================
  output logic               result_valid,     // Pulse: tile result ready (in snapshot)
  output logic [3:0]         active_tail_mask, // Per-lane valid mask → cells (v4.2 A4)

  // =========================================================================
  // MX Scale Boundary
  // =========================================================================
  output logic               mx_scale_tick,    // Pulse: MX block boundary this cycle
  output logic               mx_mode_active,   // Current tile uses MX format

  // =========================================================================
  // Tile Lifecycle
  // =========================================================================
  output logic               tile_start_out,   // Pulse: new tile (clears scale_loaded)

  // =========================================================================
  // [3a-1 S3 2026-08-03] Sparse Fragment Flow Control —— frag_ready 输出已删除
  // =========================================================================
  //   它是 P1-2「authoritative ready，无组合 ready↔valid 环」契约在 RTL 里的**全部实体**
  //   （全文件 P1-2 只有头注与产生式两处，无 P1-2 命名 SVA）。消费方 = 已删的队列读口。

  // =========================================================================
  // Active Descriptor (R5 NEW — for R9 egress routing)
  // =========================================================================
  //
  // Full latched descriptor of the current tile. Valid from the start pulse
  // through the ST_IDLE cycle of the NEXT tile (when a new descriptor is
  // latched). tensor_unit_top (R9) must latch its own copy on capture_fire
  // for use during the subsequent egress row scan, because by the time the
  // fragmentizer is emitting rows, this controller may already be working
  // on the next tile.
  output tile_descriptor_t   tile_desc_active,

  // =========================================================================
  // Debug / Monitoring
  // =========================================================================
  output logic [15:0]        dense_k_cursor_out // Dense-K position in current tile
);

  // ==========================================================================
  // Section 1: FSM State Definition (R5: added ST_CAPTURE)
  // ==========================================================================

  typedef enum logic [2:0] {
    ST_IDLE        = 3'd0,
    ST_LOAD_WEIGHT = 3'd1,
    ST_CLEAR_ACC   = 3'd2,   // v4.2: dedicated clear state (A1 fix)
    ST_COMPUTE     = 3'd3,
    ST_DRAIN       = 3'd4,   // v4.2: OS skew drain (separated from COMPUTE)
    ST_CAPTURE     = 3'd5,   // R5 NEW: snapshot bank latch (1 cycle)
    ST_DONE        = 3'd6
  } state_e;

  state_e state_q, state_d;

  // ==========================================================================
  // Section 2: Latched Descriptor + Derived Parameters (R5: descriptor-centric)
  // ==========================================================================
  //
  // tile_desc_q is the single source of truth for all per-tile parameters.
  // It is latched on the start pulse (ST_IDLE) and remains stable until
  // the next tile's start pulse. All individual parameters (mode_q,
  // sparse_mode_q, k_total_q, pack_advance_q) are derived combinationally
  // from tile_desc_q, eliminating redundant state.

  tile_descriptor_t tile_desc_q;

  tensor_mode_e      mode_q;
  exec_sparse_mode_e sparse_mode_q;
  ncfg_e             n_cfg_q;          // [3a-3] per-tile N:M 配置（描述符链的终点）
  logic [15:0]       k_total_q;
  logic [7:0]        pack_advance_q;

  assign mode_q         = tile_desc_q.mode;
  assign sparse_mode_q  = tile_desc_q.sparse_mode;
  // [3a-3] n_cfg 展开。**本片的链止于此** —— 今天 n_cfg 的唯一消费者是下方 §11
  //   断言区的 [3a-3] 绊线；进 ctrl_quad（16 象限 mod-N 相位）归 3a-5，
  //   数据通路（压实行数 ⌈K/4⌉×N、k_step {4,0}）归 3a-4/3a-5。
  //   N 的数值一律经 tensor_pkg 的 ncfg_survivors() 取，禁 open-code（用户 2026-08-04 拍板）。
  assign n_cfg_q        = tile_desc_q.n_cfg;
  assign k_total_q      = tile_desc_q.k_total;
  assign pack_advance_q = dense_pack_advance(tile_desc_q.mode);

  assign tile_desc_active = tile_desc_q;

  // ==========================================================================
  // [3a-4/M4] A1 —— k_total_pad：稀疏臂收官判据的 K 视图
  // ==========================================================================
  //
  // 结构化稀疏按 M=4 的窗口压实，尾窗不足 4 个元素时仍占一个完整窗口
  // ⇒ 稀疏臂的 dense-K 行程必须补齐到 Kp = ⌈K/4⌉ × 4，否则最后一个窗口的
  // 存活元素发不完。dense 臂（R1 的 8 个 case 全在此臂）**逐字不受影响**：
  // 下方每一处 pad 都是 per-arm 选择，dense 侧仍读 k_total_q / k_total_d_v。
  //
  // 🔴 为什么是纯组合的派生量、而不是 tile_descriptor_t 的新字段：
  //    新字段会连坐 ENTRY_W 与 desc_queue，且在 3d delta-synth 禁跑窗口（到 3a-8）
  //    内产出一笔未综合、未测量的账。**也不新起 `_q` 寄存器** —— 它是 k_total 的
  //    纯函数，多一个寄存器就多一条要证明"与 k_total_q 同步"的义务。
  // 🔴 M=4 是已拍板的常量（D-SPARSE-*：M=4、N 可配 {4,2,1}），不经 ncfg_survivors()
  //    —— 那个函数是 **N** 的唯一来源，不是 M 的。N 的用处在权重腿上界
  //    （tensor_external_modules.sv 的 ⌈K/4⌉×N），那里必须过它。
  // 🔴 单一公式、两域各取一份：写成 function 而不是两处 open-code，
  //    是为了让"两域口径永远一致"成为结构事实（§5.0d 型 15 的温床是散落的抄写）。
  //    半格恒等正控 K=24（Kp=24，与 K 同值）就是用来抓 ((K+4)>>2)<<2 /
  //    (K&~3)+4 这两类只在 K%4==0 上分叉的手滑式的。
  // 🔴 诚实登记一个**未被任何闸覆盖**的角：k_total > 65532 时 `k + 3` 绕 2^16 ⇒ Kp 回绕。
  //    与 K1A-MASK 那条已登记的 2^16 角**不同**——K1A-MASK 抓不住它（等式两边共用同一个
  //    pad 视图，恒等式仍成立）。判定 = 操作上不可达（K 由 MMIO 0x04 写入，
  //    真实 tile 的 K 是数百量级），与既有 `k_total > 65280` 角同级处置，不另设闸。
  function automatic logic [15:0] k_total_pad4(input logic [15:0] k);
    return ((k + 16'd3) >> 2) << 2;
  endfunction

  logic [15:0] k_total_pad_q;    // 寄存视图（tile_desc_q 域）
  assign k_total_pad_q = k_total_pad4(k_total_q);

  // Weight load duration
  localparam int WEIGHT_LOAD_CYCLES = COLS;

  // MX mode detection — R5: uses mode_is_mx() helper from tensor_pkg
  assign mx_mode_active = mode_is_mx(mode_q);

  // ==========================================================================
  // Section 3: K Tracking — Dense K Cursor
  // ==========================================================================
  //
  // dense_k_cursor tracks position in the original dense K coordinate space.
  // Dense mode:  advances by pack_advance_q each cycle (fixed per mode)
  // Sparse mode: ~~[3a-1 S3] 逐字等于 dense 臂（原为 frag_dense_k_advance，来自 fragment desc）~~
  //              ~~▲[3a-4/M4] **步长**仍逐字等于 dense（k_step 重写归 M6′）~~
  //              ▲**[3a-5/M6′ 2026-08-03 已兑现]（原文划掉保留）**：稀疏臂步长改为
  //                `sparse_k_advance(n_cfg, pack_advance, phase)` = **dense-K 步长 4/N**。
  //                收官判据自 M4 起已是 pad 视图（下方 A2/A3），本级不动它。
  //
  // Tile is complete when dense_k_cursor >= ~~k_total_q~~
  //   ▲[3a-4/M4] **per-arm**：dense 臂 `>= k_total_q`；稀疏臂 `>= k_total_pad_q`（= Kp）。

  logic [15:0] dense_k_cursor_q;   // Current position in dense K space
  logic [15:0] k_step;             // How much K advances this cycle
  logic        k_done;             // All K elements consumed (registered)

  // ==========================================================================
  // [3a-5/M6′] 稀疏臂的 dense-K 步长 = 4/N，与 N=1 的 {4,0} 气泡相位
  // ==========================================================================
  //
  // 【算术出处】已批规格 §3 的节拍表 + §4.3 + §6.3 订正框，三方一致：
  //   cursor 必须走完 dense-K 空间 Kp = ⌈K/4⌉×4；拍数 × 步长 = Kp；
  //   而规格 §3 的发行拍数 = ⌈K/4⌉ × N × (N==1 ? 2 : 1)
  //   ⇒ 步长 = 4/N。N=1 的 {4,0} 是同一式的**相位实现**（每 2 拍推进 4）。
  //
  // 🔴🔴 **[3a-5/M6′ 收口后对抗审查发现，逐字订正]**：~~2⌈K/4⌉ 拍走完 Kp，与 §6.3
  //   订正框的发行拍数逐字吻合~~ —— **这句是错的**。实际 COMPUTE 拍数 = **2⌈K/4⌉ − 1**：
  //   `k_will_be_done`（:426 的前瞻）在 cursor = Kp−4 的 **issue 拍**就命中
  //   （Kp−4 + 4 >= Kp），当拍即转 DRAIN ⇒ **末尾那个气泡拍被吞掉**。
  //   ⇒ 与规格 §6.3 的 `2×⌈K/4⌉` **差 1 拍**。
  //   **本片不裁决谁对**（RTL 行为 / 规格公式 / drain 起点规则三者），因为 N=1 在本片
  //   结构上不可达（见下方零覆盖登记）⇒ 跑不出、也红不了。
  //   🔴 **列为 3a-6 的【开工前置裁决项】**：3a-6 在给 N=1 预登记期望数【之前】，
  //   必须先裁决这三者哪个是权威，否则那一片的预登记数从落笔起就是错的。
  //   N=2 / N=4 **不受影响**（步长恒为常数 2 / pack_advance ⇒ 无尾部气泡可被吞），
  //   本级实测 0x2e/0x2e/0x30 与 0x3a/0x3a/0x3e/0x3e 即其证。
  //
  // 🔴 **N=4 分支返回 `pack_advance` 入参，不是硬编码 8'd1** —— 这不是风格问题：
  //   今天稀疏臂逐字等于 dense 臂（`pack_advance_q`），BF16 下它恰是 1，但
  //   `MODE_FP8/MXFP8` 返 2、`FP4/MXFP4/UINT4_SIMD` 返 4。硬编码 1 会**悄悄改掉**
  //   「N=4 稀疏 × packed 模式」的行为，而那条路径**全仓零测试、改了也不会红**。
  //   返回入参 ⇒「N=4 ⇒ 与 dense 逐位同」对**所有 mode** 成立，是结构事实不是巧合。
  //
  // 🔴 **N 一律经 `ncfg_survivors()` 取，禁 open-code**（用户 2026-08-04 拍板，纪律锚见 :288）。
  //   `NCFG_RESERVED` 解码为 N=3（不在批准集 {4,2,1}）⇒ default 臂返回 `pack_advance`，
  //   即退回 dense 行为：给一个**确定**的值，禁把它当「可执行的 3:4」用。
  //   ~~该编码在仿真里由下方 §11 的 C2 白名单臂 $fatal 拦下；真拒收归 3a-7/3a-8。~~
  //   ▲**[3a-7/P5 2026-08-06 订正]：前半已落地，后半仍未落。**
  //   · `NCFG_RESERVED` 的**真拒收 = 已落地**（3a-7/P5）：`tensor_external_modules.sv` 的
  //     `assign desc_push_valid = start_pulse && !desc_reject;` 让它在 **MMIO 写入时**
  //     就被丢弃、不入队（`is_valid_descriptor` 的臂 B）。
  //     🔴 **随之而来的后果**：它**再也到不了下方的 C2 白名单臂** —— 该臂对
  //     `NCFG_RESERVED` 已**结构性不可达**。红证改由 MMIO 层探针承载
  //     （`tb/scratch_guard_probe.py` 的 P4 发：`GP-CSR … bit2=1` + 零真签名）。
  //   · **3a-8 的临时闸仍未落**（「`n_cfg != NCFG_DENSE` 即拒」，蓝图项 8 的可拆闸），
  //     它与上面那条**寿命相反** ⇒ 🔴 **禁并进同一个谓词**（D-SPARSE-3A7-SCOPE-2026-08-05）。
  //
  // 🔴 **本片零覆盖登记**：N=1 臂**落地未通电**（真 oracle = 3c 的 R3）。且
  //   `tensor_operand_fetch` 侧的「权重流逐拍插零行」（规格 §4.3）**本片未落** ——
  //   它要把相位送进 operand_fetch（又一次端口手术，而 M4 已实测该模块所有输入端口的
  //   漏接对 R1 全静默），本片零覆盖 ⇒ 落它拿不到任何守门。按 BuildSheet §3 的边界
  //   ~~留给 3a-6（它同时给 N=1 载体）~~。**禁称本片覆盖了 N=1。**
  //   ▲**[3a-6/P0 订正，`D-SPARSE-3A6-PREREQ-2026-08-04` Q5]：交织的责任片 = 3b / 3c，不是 3a-6。**
  //     理由正是上一句自己写的那条 ——「零覆盖 ⇒ 落它拿不到任何守门」**在 3a-6 同样成立**
  //     （3a-6 仍只是节拍载体，而交织对**节拍**零影响 ⇒ 载体对它零鉴别力）；
  //     且 §4.3 的 `sel=0` 半边在 3a **结构上落不了**（`sparsity_map_in` 今天在
  //     `tensor_mac_array.sv:943` 被 tie 死，征用它是蓝图 3b 第 3 项）⇒ 硬落也最多落半条。
  //     连带：已拍板的 `wgt_row_q` **单计数器**（`D-SPARSE-FROZENCORE-V2-2026-08-02` ②）
  //     同批转出（该标识符至今全 RTL 零命中）。**3a-6 只给 N=1 载体，不动权重数据通路。**
  //     唯一定义处 = `Review/Stage3a45_Fusion_BuildSheet_2026-08-06.md` §3 第 14 条。
  //   `N=2 / N=1 × packed 模式`规格未定义（v1 = BF16 only）⇒ 亦为显式真空。
  //
  // 🔴🔴 **[3a-6 施工前置条件 · M6′ 收口后对抗审查发现]**：
  //   本臂的 `{4,0}` 气泡拍上 `k_step = 0` ⇒ cursor 不推进，而本文件 **:1225-1229 的
  //   CURSOR MONOTONICITY SVA** 的前件（`ST_COMPUTE && !k_done &&
  //   sparse_mode_q inside {EXEC_DENSE, EXEC_SPARSE_STRUCT}`）在气泡拍上**全部成立**
  //   ⇒ 后件 `cursor > $past(cursor)` 恒假 ⇒ **每个气泡拍必发 $error**。
  //   **本片不可达**（N=1 被 :1365 的 C2 白名单臂 `$fatal(1)` 在描述符落定后的第一个
  //   时钟沿截断，远早于进 ST_COMPUTE；留档实测 = `s3a45_m5p_guard_p3_20260806.log`，
  //   写 `0x08=0x04` 后 15 ns 即 abort）⇒ 本级三闸绿不是侥幸，是该分支无法通电。
  //   🔴 **3a-6 放宽 C2 到含 NCFG_1OF4 的【同一次改动】里，必须一并给该 SVA 的稀疏臂
  //   开气泡口**，否则第一个 N=1 tile 就会撞它，而报文写的是「cursor not advancing」
  //   ⇒ 红因会被路由到「相位实现错了」，真相却是「SVA 没给气泡开口」。
  //   （好消息：它会在放宽 C2 的同一次运行里立刻暴露，不存在被本片掩盖后遗留的风险。）
  function automatic logic [7:0] sparse_k_advance(input ncfg_e       n,
                                                  input logic [7:0]  pack_advance,
                                                  input logic        phase);
    case (ncfg_survivors(n))
      3'd4:    return pack_advance;                  // N=4：逐字等于 dense 臂（R1 与 N=4 探针的保护）
      3'd2:    return 8'd2;                          // N=2：k_step = 2/拍（规格 §3）
      3'd1:    return phase ? 8'd0 : 8'd4;           // N=1：{4,0} 气泡节拍（规格 §4.3）
      default: return pack_advance;                  // N=3 保留值：退回 dense，给确定值
    endcase
  endfunction

  // 相位 FF（规格 §4.3 的相位契约，逐字三条）：
  //   ① 相位 FF 在 controller  ② ST_CLEAR_ACC 清零（规格 §6.2 的复位锚 = clear_acc 脉冲）
  //   ③ COMPUTE 首拍 = issue 相（phase==0）
  // ③ 由 ①②「只在 COMPUTE 翻转」共同保证：进 COMPUTE 时 phase 必为 0。
  // 🔴 用 clear_acc 而不是「step 计数 mod N」当锚：后者在 (J+34) mod N ≠ 0 的 b2b tile 上
  //   会相位反转（规格 §6.2 逐字）。
  logic k_phase_q;
  logic k_phase_d;

  // v4.2a (P0-1): Combinational look-ahead for last-issue detection.
  logic        k_will_be_done;

  always_comb begin
    if (sparse_mode_q == EXEC_SPARSE_STRUCT)
      // ~~[3a-1 S3] 占位：稀疏臂**逐字等于** dense 臂。确定性 k_step 由 3a-5 落。~~
      // ▲**[3a-5/M6′] 已落**：dense-K 步长 = 4/N（N=1 走 {4,0} 相位）。
      k_step = {8'd0, sparse_k_advance(n_cfg_q, pack_advance_q, k_phase_q)};
    else
      k_step = {8'd0, pack_advance_q};   // 🔴 dense 臂逐字不动（R1 走本臂）
  end

  // [3a-5/M6′] 相位次态 + 相位寄存器。单独一个 always_ff，**不扰动 Section 9 的
  //   `unique case (state_q)` 结构**（那里每加一条分支都要连坐所有臂的复核）。
  //   `k_phase_d` 同时是 K1c 侧 `k_step_d8` 的相位输入（下一拍的 k_step 是 controller
  //   内部纯函数，不需要任何外部指针状态 —— 见下方 F1-K1C 那段的 3a-1 S3 记述）。
  assign k_phase_d = (state_q == ST_CLEAR_ACC) ? 1'b0
                   : (state_q == ST_COMPUTE)   ? ~k_phase_q
                                               :  k_phase_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) k_phase_q <= 1'b0;
    else        k_phase_q <= k_phase_d;
  end

  always_comb begin
    if (sparse_mode_q == EXEC_SPARSE_STRUCT)
      // [3a-4/M4] A2 —— 稀疏臂换 pad 视图（~~[3a-1 S3] 占位：逐字等于 dense 臂~~）。
      //   两臂自本行起**真正分叉**：K%4≠0 时 Kp > K ⇒ 稀疏臂多跑 Kp−K 拍。
      k_will_be_done = (dense_k_cursor_q + k_step >= k_total_pad_q);
    else
      // Dense: always deterministic —— 🔴 逐字不动（R1 的 8 个 case 全走本臂）
      k_will_be_done = (dense_k_cursor_q + k_step >= k_total_q);
  end

  // [3a-1 S3] ~~v4.2c (P2-2): Sparse early completion via group_last descriptor flag.~~
  //   `sparse_group_last_fire` 及其唯一消费点（DRAIN 转移的第 (3) 条路径）已删除 ——
  //   它的两个输入 frag_valid / frag_group_last 随 K 令牌通路退役。
  //   🔴 覆盖净损失：P2-2 SVA 一并删除，等价物（确定性尾窗收官判据）由 3a-4 落。

  // [3a-4/M4] A3 —— 今天无双臂槽位（本行原是单臂），**先拆双臂再加 pad**。
  //   拆双臂本身也是 M6′ 的槽位：那天稀疏臂会换成相位计数器的收官判据。
  assign k_done = (sparse_mode_q == EXEC_SPARSE_STRUCT)
                ? (dense_k_cursor_q >= k_total_pad_q)
                : (dense_k_cursor_q >= k_total_q);

  // ==========================================================================
  // Section 4: K Iteration Count Calculation (for weight-load pre-compute)
  // ==========================================================================
  //
  // k_iters_calc is still computed for debug visibility. Weight load timing
  // doesn't change (always COLS cycles).
  //
  // B3 FIX: On the start cycle (state_q == ST_IDLE), k_iters_calc uses
  // the INPUT tile_desc.k_total directly, not the stale tile_desc_q.
  // This ensures the first tile after reset computes the correct count.

  logic [15:0] k_iters_calc;

  always_comb begin
    // B3 fix: use tile_desc input when latching, tile_desc_q otherwise
    automatic logic [15:0]       k_src;
    automatic logic [7:0]        pa;
    automatic exec_sparse_mode_e sp;

    k_src = (state_q == ST_IDLE) ? tile_desc.k_total       : k_total_q;
    pa    = (state_q == ST_IDLE) ? dense_pack_advance(tile_desc.mode)
                                  : pack_advance_q;
    sp    = (state_q == ST_IDLE) ? tile_desc.sparse_mode   : sparse_mode_q;

    // [3a-4/M4] S0-1 裁决：本量**跟 pad**（稀疏臂），理由 = 它自称"这个 tile 会跑几轮
    //   K 迭代"，而稀疏臂的行程自 M4 起是 Kp 不是 K，不跟就是一个自相矛盾的调试量。
    //   🔴 **诚实登记：本信号今日行为死** —— 全仓无消费者（`grep -rn k_iters_calc`
    //   只命中本模块的定义处与注释），所以本片**所有闸对本行都零鉴别力**，
    //   它靠的是"与 k_done 同源同式"这条结构约束，不是任何一条红臂。
    //   同族的反向裁决见 §7 的 mx_scale_tick（S0-2：**不**跟 pad）。
  //   🔴 **▲[3a-5/M6′ 订正]**：上面那句「稀疏臂的行程自 M4 起是 Kp」自 M6′ 起**不再充分** ——
  //   稀疏臂走完 Kp 用的**拍数**是 `Kp / (4/N)`（N=2 ⇒ Kp/2），而本量的除数 `pa` 仍是
  //   **dense 步长** `pack_advance_q` ⇒ 稀疏臂下本量高估 `4/N` 倍。
  //   **不改**：本信号仍**行为死**（全仓无消费者），改它拿不到任何守门，且会给
  //   「它到底该数什么」引入一个本片无法裁决的口径问题（轮数？拍数？dense-K 元素数？）。
  //   ⇒ 与 §4.3 的 N=1 拍数裁决**同批**交 3a-6；在此之前**禁引用本量做任何判据**。
    if (sp == EXEC_SPARSE_STRUCT)
      k_src = k_total_pad4(k_src);

    unique case (pa)
      8'd4:    k_iters_calc = (k_src + 16'd3) >> 2;
      8'd2:    k_iters_calc = (k_src + 16'd1) >> 1;
      default: k_iters_calc = k_src;  // pack_advance = 1
    endcase
  end

  // ==========================================================================
  // Section 5: Cycle Counter (general purpose)
  // ==========================================================================

  logic [15:0] cycle_cnt_q;

  // Drain duration. HW-REVIEW T1 (F4) is OUTPUT-STATIONARY-only: the OS-GEMM
  // wavefront's last real product lands at cell(ROWS-1,COLS-1) at cycle
  // K + ROWS + COLS - 1 (relative to first issue_en): +2 operand latency (SRAM
  // read + the A1 OS recapture stage, tensor_mac_array.sv) + (ROWS-1)+(COLS-1)
  // skew/hop transport. COMPUTE issues K cycles (0..K-1), so OS drain must keep
  // stepping AND accumulating for ROWS+COLS = 32 cycles (cnt 0..31 = cycles
  // K..K+31) to capture that final product.
  //   A1 fix (2026-07-06): was ROWS+COLS-1 = 31 before the OS operand recapture
  //   register; the extra +1 latency (which removes the negedge-SRAM half-cycle
  //   arc as an OS binding constraint — targeting the ~20.6 MHz reg2reg ceiling,
  //   to be confirmed by post-fix re-P&R STA) shifts the last wavefront one cycle
  //   later, so the drain (and issue_count = K + DRAIN_CYCLES_OS, mirrored by the
  //   gemm_egress cocotb DRAIN_ACC constant) grows by exactly 1.
  //
  // WS (weight-stationary) is UNCHANGED from the pre-T1 array: ROWS-1 = 15 drain
  // steps, issue_en held low (no skewed-tail accumulation — WS results come from
  // the INT psum chain, not the OS fp_acc). The OS-only rework (drain length,
  // issue_en-in-drain, full tail-mask, operand zero-pad, operand recapture) is
  // gated on dataflow_sel so WS stays bit-identical (the frozen-core requirement).
  //   cnt 0..drain_limit-1: active stepping (OS: + accumulate)
  //   cnt == drain_limit:   drain physically complete, waiting for snapshot bank
  // 🔴 [K1b 2026-08-08] 34 → 35：mac_cell 在 `lru_out` 处新增 **c6g 缝**（第二个共享 rank），
  //    把签核临界路径 1628.11 ps / 126 级切成 936.34 / 691.77 ps。判据 =
  //    aichip_run_logs/b58k1b_prereg_20260808.md；靶 = b58k1_grange_verdict_20260808.md。
  //    ⚠️ 撞车提醒：DRAIN_CYCLES_OS_SPARSE 本来就是 35（= OS+1），本刀后它变 36；
  //       且 mac_cell.sv Section 8D 的注释把 35 预留给 **M4 顺序版** —— 本次的 35 是
  //       **K1b 的前馈切分**，与 M4 的环手术无关。凡硬编码 35 处须逐个判明指的是哪一个。
  localparam logic [15:0] DRAIN_CYCLES_OS = ROWS[15:0] + COLS[15:0] + 16'd3;  // 35 (A1: +1 OS recapture; §C6: +1 FP feedforward; §C6-b/c: +1 c6f shared front rank; §K1b: +1 c6g seam)
  localparam logic [15:0] DRAIN_CYCLES_WS = ROWS[15:0] - 16'd1;               // 15 (original)

  // ---- [3a-6/P2] 稀疏臂 drain = 35（规格 §6.3 `issue_cnt == 发行拍数 + 35`）-------
  //   机理：规格 §6.3 给稀疏臂配 **+1 拍权重滞后 L(n_cfg)**（dense L=0，2:4 与 1:4 L=1）
  //   ⇒ 最后一个真实权重行晚一拍呈现 ⇒ 最后一个乘积晚一拍出阵列 ⇒ drain 窗口 +1。
  //
  // 🔴🔴 **分臂谓词 = n_cfg，不是 exec**（`D-SPARSE-3A6-PREREQ-2026-08-04` Q2 用户拍板）。
  //   两者只在 **`exec=EXEC_SPARSE_STRUCT ∧ n_cfg=NCFG_DENSE`** 这一格给相反答案，
  //   而那一格正是 **N=4 恒等点探针**（`tb/scratch_pad_probe.py`）的配置：
  //     · 按 n_cfg 判（本实现）⇒ 该发仍 34 ⇒ 探针四发期望**逐字不变**，恒等点保住；
  //     · 按 exec 判        ⇒ 该发被拖进 35 ⇒ **N=4 恒等点当场破**。
  //   🔴 **改这个谓词 = 改判据**：改前必须先复活并跑 `tb/scratch_pad_probe.py`
  //      取改前活体基线（BuildSheet §3 第 7 条），并同批翻写它的 `M4_EXPECT`
  //      与预登记 §3 表 —— 两处都不在本文件里。
  //   （本文件此前所有分臂谓词都是 exec；本行是第一处 n_cfg 型分臂谓词。
  //    `ncfg_survivors()` 纪律管的是「取 N 的**数值**」，不管枚举分臂谓词，两者不冲突。）
  //
  // 🔴 **今天 L(n_cfg) 还没落**（`tensor_operand_stream`/`tensor_operand_fetch` 侧的
  //   「权重流逐拍零行交织 + 滞后」按 `D-SPARSE-3A6-PREREQ-2026-08-04` Q5 **转出 3b/3c**）
  //   ⇒ 本常数目前**比物理需要多一拍**。这是**已登记的过渡态**，不是缺陷：
  //   多出来的那一拍落在 `k_done` 之后的零填充窗口里（0×0 累加，OS 下对结果无影响），
  //   只把稀疏发的 `issue_count` 抬高 1（= cadence 载体三发翻值的**全部来源**）。
  //   **3b 落 L(n_cfg)=1 那天本常数不再需要改** —— 届时它才第一次「名副其实」。
  //   唯一定义处 = `Review/Stage3a45_Fusion_BuildSheet_2026-08-06.md` §3 第 2/14 条。
  localparam logic [15:0] DRAIN_CYCLES_OS_SPARSE = DRAIN_CYCLES_OS + 16'd1;  // 35

  logic        os_mode;
  logic [15:0] drain_limit;
  assign os_mode     = (tile_desc_q.dataflow_sel == 1'b0);
  // 🔴 本行与下方 `drain_limit_d_v`（次态视图）**必须同批同值分叉** ——
  //    影子参考 `issue_ref`/`step_ref` 吃本行，实现 `issue_d`/`step_d` 与 K1c 尾窗掩码
  //    吃那一行；只改一处 ⇒ `cycle_cnt_q == 34` 那拍两侧分叉 ⇒ K1A 逐拍 $fatal。
  //    自证 = `grep -n 'drain_limit' tensor_tile_controller.sv` 必须返回两条结构同构的 assign。
  assign drain_limit = os_mode ? ((n_cfg_q != NCFG_DENSE) ? DRAIN_CYCLES_OS_SPARSE
                                                          : DRAIN_CYCLES_OS)
                               : DRAIN_CYCLES_WS;

  // drain_steps_done: 1 when all drain steps have been taken and we are now
  // waiting for snapshot_bank_available. Used to gate array_step_en off (no more
  // steps) and to enable the DRAIN → CAPTURE transition.
  logic drain_steps_done;
  assign drain_steps_done = (state_q == ST_DRAIN)
                          && (cycle_cnt_q == drain_limit);

  // ==========================================================================
  // Section 6: Tail Mask Generation (A4 fix)
  // ==========================================================================
  //
  // v4.2: active_tail_mask[3:0] is output to all cells every cycle.
  // - Non-tail cycles: all active lanes for the current mode
  // - Last K group (partial): only lanes with valid data are set
  // - Non-compute states: all zeros (no active lanes)

  // [K1a-mask 2026-07-26] the 16-bit k_total−cursor subtract and the
  // cursor+k_step compare were the deep front of the active_tail_mask
  // broadcast cone — same startpoint (dense_k_cursor_q), same 256-cell
  // broadcast, same input_mux data-cone entry as the array_step_en wall
  // (T2_Preflight §3b-5: the shadow path that would cap K1a's benefit).
  // k_remaining_q is registered one beat early from the SAME next-state
  // values as the K1a issue/step registration (Section 8b):
  //     k_remaining_q(t) == k_total_q(t) − dense_k_cursor_q(t)   (exact,
  //   ▲[3a-4/M4] 上式的 `k_total_q` 自本片起是 **per-arm 视图**：稀疏臂读
  //   `k_total_pad_q`（A5/A6/A7 三处 verbatim 同改）。恒等式的**形式**不变 ——
  //   变的只是等式两边共用的那个 K 视图，所以 K1A-MASK 仍是纯寄存器传输恒等式。
  // pure register-transfer identity, every beat — no state masking needed).
  // is_last_k_group is rewritten onto it: k_remaining ≤ k_step ⟺
  // cursor+k_step ≥ k_total, and k_remaining ≠ 0 ⟺ cursor < k_total
  // (unsigned underflow on overshoot makes k_remaining huge ⇒ both forms 0).
  // Sole divergence corner: cursor+k_step wrapping 2^16 (k_total > 65280),
  // operationally unreachable and pinned by the K1A-MASK runtime SVA below.
  logic [15:0] k_remaining_q;
  logic is_last_k_group;
  assign is_last_k_group = (k_remaining_q <= {8'd0, k_step})
                         && (k_remaining_q != 16'd0);

  // Number of remaining K elements at the start of last group (registered view)
  logic [15:0] k_remaining;
  assign k_remaining = k_remaining_q;

  always_comb begin
    if (state_q == ST_COMPUTE && is_last_k_group) begin
      // Generate per-lane mask based on how many elements remain
      unique case (mode_q)
        MODE_FP4, MODE_MXFP4, MODE_UINT4_SIMD: begin
          // 4-lane modes: remaining can be 1..4 elements
          unique case (k_remaining[1:0])
            2'd0: active_tail_mask = 4'b1111;  // 4 remaining (or multiple of 4)
            2'd1: active_tail_mask = 4'b0001;  // 1 remaining
            2'd2: active_tail_mask = 4'b0011;  // 2 remaining
            2'd3: active_tail_mask = 4'b0111;  // 3 remaining
          endcase
        end
        MODE_FP8, MODE_MXFP8: begin
          // 2-lane modes: remaining can be 1..2 elements
          active_tail_mask = k_remaining[0] ? 4'b0001 : 4'b0011;
        end
        default: begin
          // Single-element modes (BF16/UINT8/MXINT8): always 1 lane
          active_tail_mask = LANE_MASK_1;
        end
      endcase
    end else if (state_q == ST_COMPUTE) begin
      // Non-tail cycle: all lanes for this mode
      active_tail_mask = mode_full_lane_mask(mode_q);
    end else if (os_mode && state_q == ST_DRAIN && cycle_cnt_q < drain_limit) begin
      // HW-REVIEW T1 (F3), OS ONLY: during the accumulate-drain the cells multiply
      // the still-in-flight REAL wavefront operands, so lanes must stay ENABLED
      // (else mac_input_mux would tail-mask the real tail products to zero — the
      // same dropped-tail defect by another path). Zero-padded boundary operands
      // (index >= k_total) multiply to 0 regardless of the mask. Full mask is
      // exact for single-element modes (BF16/MXINT8/UINT8/UINT4); for the packed
      // sub-element modes (FP4/FP8 x2/x4) a partial last-K group is NOT re-masked
      // per-element during the drain wavefront — a documented limitation, out of
      // the BF16 OS-GEMM scope (see Tensor_GEMM_Rewire_Plan §5/§6). WS keeps the
      // original all-zero drain mask (issue_en is low in WS drain anyway).
      active_tail_mask = mode_full_lane_mask(mode_q);
    end else begin
      // Not in compute/drain-step phase
      active_tail_mask = 4'b0000;
    end
  end

  // ==========================================================================
  // Section 7: MX Scale Boundary Tick (cursor-based, parameterized)
  // ==========================================================================
  //
  // v4.2c (P2-3): scale tick fires when dense_k_cursor crosses a
  // MX_BLOCK_SIZE-element boundary (default 32, configurable in tensor_pkg).

  logic [15:0] block_idx_before;
  logic [15:0] block_idx_after;

  assign block_idx_before = dense_k_cursor_q >> MX_BLOCK_LOG2;
  assign block_idx_after  = (dense_k_cursor_q + k_step) >> MX_BLOCK_LOG2;

  // [K1a-pre0 2026-07-26] issue_en qualification: the tick count is a pure
  // function of the ISSUED cursor trajectory (first-block prefetch at
  // cursor==0 + block-boundary crossings) and must be stall-independent.
  // Unqualified, a sparse frag-stall sitting at cursor==0 re-fired the tick
  // EVERY stall beat (42 ticks in a 60-beat entry-stall window — red evidence
  // k1a_pre0_mxtick_red_20260726.log) and scale_offset_q ran away = permanent
  // block-scale stream misalignment. Dense COMPUTE has issue_en=1 whenever
  // !k_done, so this is bit-identical for every dense tile; found by the K1a
  // adversarial preflight (T2_Preflight_StepEnBroadcast §3b-6).
  //
  // 🔴 [3a-1 S3 2026-08-03] **上述论据已失效，但 `&& issue_en` 限定【保留】。**
  //   sparse frag-stall 通路随 K 令牌退役而消失（本片起 issue_en 在 ST_COMPUTE 恒 1），
  //   所以那段红证（k1a_pre0_mxtick_red_20260726.log）现在是**历史**、不是现役论据。
  //   ⇒ 本限定在 3a-1..3a-4 窗口内是冗余项：删掉 dense 逐位相同、**R1 完全瞎**
  //     （BF16 无 mx_mode_active，基线 #CSR 0x14=0）。
  //   ⇒ 3a-5 落 N=1 的 {4,0} 相位后（气泡拍 step 全速而 issue 分相），它会**重新变成
  //     活约束**。禁止以「通路已删」为由删除它。同族登记见清单 §2 C 表。
  // 🔴 [3a-4/M4] S0-2 裁决：本行**不加任何 pad 项**（与 S0-1 的 k_iters_calc 相反 ——
  //   两条一并裁决，不许留成"没想到"）。理由：block scale 的流是按**真实** K 元素配的，
  //   pad 拍上没有对应的 scale，加一个 pad 口径的边界项就是凭空多发 tick、让
  //   scale_offset_q 跑飞（同款失效在 K1a preflight 实付过：k1a_pre0_mxtick_red_20260726.log）。
  //   本行唯一的 K 依赖是 `!k_done`（A3），故 pad 拍仍算 COMPUTE 拍 —— 这是**有意**的：
  //   pad 拍确实还在发行、array 也还在 step。
  //   🔴 **显式登记一个未解决的角**（不主张已处理）：pad 拍跨过 MX_BLOCK_SIZE 边界时
  //   会多发一次 tick（K ≡ 30/31 mod 32 可构造）。本片 K∈{23..26}、Kp≤28，**不可达**；
  //   且 BF16 下 mx_mode_active 恒 0 ⇒ 整条恒 0，本片所有闸对本裁决**全瞎**。
  //   该角的家 = 3c（MX × 稀疏数值 oracle）。
  assign mx_scale_tick = (state_q == ST_COMPUTE)
                       && mx_mode_active
                       && !k_done
                       && issue_en
                       && ((dense_k_cursor_q == 16'd0)
                        || (block_idx_after != block_idx_before));

  // ==========================================================================
  // Section 8: FSM Next-State Logic (R5: added ST_CAPTURE)
  // ==========================================================================

  always_comb begin
    state_d = state_q;

    unique case (state_q)

      ST_IDLE: begin
        if (start)
          state_d = ST_LOAD_WEIGHT;
      end

      ST_LOAD_WEIGHT: begin
        if (cycle_cnt_q == WEIGHT_LOAD_CYCLES[15:0] - 16'd1)
          state_d = ST_CLEAR_ACC;
      end

      // A1 fix: Dedicated accumulator clear state. Exactly 1 cycle.
      ST_CLEAR_ACC: begin
        state_d = ST_COMPUTE;
      end

      ST_COMPUTE: begin
        // Two completion paths for COMPUTE → DRAIN:
        //   (1) k_done (registered): defensive fallback
        //   (2) k_will_be_done (combinational P0-1): last issue this cycle
        // [3a-1 S3] 原第 (3) 条 sparse_group_last_fire (P2-2, Vector early completion)
        //   已删除：其输入 frag_valid/frag_group_last 随 K 令牌通路退役。
        if (k_done || k_will_be_done)
          state_d = ST_DRAIN;
      end

      // R5 MODIFIED: DRAIN → CAPTURE gated on snapshot_bank_available.
      //
      // The drain counter runs 0..DRAIN_CYCLES. For cnt in 0..DRAIN_CYCLES-1,
      // array_step_en=1 (active stepping). At cnt == DRAIN_CYCLES, all steps
      // are complete and we wait for the snapshot bank to become available.
      // If the bank is not ready, we saturate the counter and stall.
      ST_DRAIN: begin
        if (drain_steps_done && snapshot_bank_available)
          state_d = ST_CAPTURE;
      end

      // R5 NEW: Snapshot capture state.
      // Exactly 1 cycle. capture_fire=1, all cells latch fp_acc_out into
      // their snapshot_q register. Unconditionally transitions to ST_DONE.
      ST_CAPTURE: begin
        state_d = ST_DONE;
      end

      ST_DONE: begin
        state_d = ST_IDLE;
      end

      default: state_d = ST_IDLE;

    endcase
  end

  // ==========================================================================
  // Section 9: State Register + Sequential Updates
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q          <= ST_IDLE;
      cycle_cnt_q      <= 16'd0;
      dense_k_cursor_q <= 16'd0;
      tile_desc_q      <= '0;
    end else begin
      state_q <= state_d;

      unique case (state_q)

        // ---- IDLE: Latch descriptor on start (R5) ----
        ST_IDLE: begin
          cycle_cnt_q      <= 16'd0;
          dense_k_cursor_q <= 16'd0;
          if (start) begin
            // R5: single descriptor latch replaces 4 individual latches
            tile_desc_q <= tile_desc;
          end
        end

        // ---- LOAD_WEIGHT: Count weight-load cycles ----
        ST_LOAD_WEIGHT: begin
          if (state_d == ST_CLEAR_ACC)
            cycle_cnt_q <= 16'd0;     // Reset counter for clear phase
          else
            cycle_cnt_q <= cycle_cnt_q + 16'd1;
        end

        // ---- CLEAR_ACC: Single-cycle accumulator clear ----
        ST_CLEAR_ACC: begin
          cycle_cnt_q <= 16'd0;       // Reset counter for compute phase
        end

        // ---- COMPUTE: Advance dense K cursor ----
        ST_COMPUTE: begin
          if (!k_done) begin
            // [3a-4/M4] S0-3 极性统一：本组三处（本行 / 次态镜像 / CURSOR MONOTONICITY）
            //   一律以 `== EXEC_SPARSE_STRUCT` 作 then 臂。今天两臂逐字相同 ⇒ 本改动
            //   **零行为变更、零守门**（R1 逐位恒真、七条 mutation 红臂无一敏感）
            //   ⇒ 判据是 §5.0f 式的代码行计数自证，不是任何一条仿真闸。
            //   不统一的代价在 M6′：两臂那天真分叉，三处里漏改的那处会变成 split-brain，
            //   而红因会被退路表路由回 A7/A8（M4 的 pad 参考式）⇒ 无法单机构归因。
            if (sparse_mode_q == EXEC_SPARSE_STRUCT) begin
              // ~~[3a-1 S3] 稀疏臂逐字等于 dense 臂~~（原为 `else if (frag_valid)` +
              //   frag_dense_k_advance；K 令牌退役后不存在 stall，故裸 else）。
              //   ~~🔴 保留双臂骨架给 3a-5 留槽位，禁止塌成单臂。~~
              //   ▲**[3a-5/M6′] 槽位已用上，两臂自本行起【真分叉】**：稀疏臂消费 `k_step`
              //   （= 4/N，N=1 走 {4,0} 相位），dense 臂仍 `pack_advance_q`。
              //   🔴 **这一行才是真正的「k_step 重写」**：不改它，上面那个 `always_comb`
              //   算出来的 `k_step` 就只被 `k_will_be_done`/`is_last_k_group` 读到，
              //   而 cursor 不走 ⇒ **拍数不翻 ⇒ 载体守门恒绿**（假绿）。
              dense_k_cursor_q <= dense_k_cursor_q + k_step;
            end else begin
              dense_k_cursor_q <= dense_k_cursor_q + {8'd0, pack_advance_q};
            end
          end

          // When transitioning to DRAIN, reset cycle_cnt for drain counter
          if (state_d == ST_DRAIN)
            cycle_cnt_q <= 16'd0;
        end

        // ---- DRAIN: Advance drain counter (R5: saturates at DRAIN_CYCLES) ----
        //
        // Counter runs 0..DRAIN_CYCLES (16 values for ROWS=16).
        // cnt 0..DRAIN_CYCLES-1: active stepping (array steps once per cycle)
        // cnt == DRAIN_CYCLES:   drain complete, waiting for bank handshake
        //                        (counter saturates, no further increment)
        ST_DRAIN: begin
          if (cycle_cnt_q < drain_limit)
            cycle_cnt_q <= cycle_cnt_q + 16'd1;
          // else: saturated at drain_limit — drain physically done
        end

        // ---- CAPTURE (R5 NEW): Reset counter for next tile ----
        ST_CAPTURE: begin
          cycle_cnt_q <= 16'd0;
        end

        // ---- DONE: Reset cursor for next tile ----
        ST_DONE: begin
          cycle_cnt_q      <= 16'd0;
          dense_k_cursor_q <= 16'd0;
        end

        default: ;

      endcase
    end
  end

  // ==========================================================================
  // Section 10: Output Signal Generation
  // ==========================================================================

  // ---- Status ----
  assign busy = (state_q != ST_IDLE);
  assign done = (state_q == ST_DONE);

  // ---- Tile lifecycle ----
  // Pulse on IDLE→LOAD_WEIGHT transition — used to clear scale_loaded flags
  assign tile_start_out = (state_q == ST_IDLE) && start;

  // ---- Weight loading ----
  assign weight_load_en = (state_q == ST_LOAD_WEIGHT);

  // ---- Accumulator clear (A1 fix) ----
  assign clear_acc = (state_q == ST_CLEAR_ACC);

  // ---- Snapshot capture control (R5 NEW) ----
  //
  // capture_fire pulses in ST_CAPTURE (1 cycle), latching snapshot_q in
  // every MAC cell at the posedge ending the ST_CAPTURE cycle.
  //
  // capture_done pulses in ST_DONE (1 cycle), which is the cycle AFTER
  // capture_fire. At this point snapshot_q is stable (registered), and
  // the fragmentizer can safely start reading.
  assign capture_fire = (state_q == ST_CAPTURE);
  assign capture_done = (state_q == ST_DONE);

  // ---- Split control signals (v4.2a) ----
  //
  // R5: ST_CAPTURE added (both signals = 0).
  // R5: ST_DRAIN stepping now gated on (cnt < DRAIN_CYCLES) to stall
  //     array_step_en during the bank-available handshake cycle.
  //
  //   ST_COMPUTE (dense):              issue_en = 1, array_step_en = 1
  //   ST_COMPUTE (sparse):             issue_en = 1, array_step_en = 1
  //     [3a-1 S3] 原为 frag ready / frag stall 两行；K 令牌退役后无 stall 态，
  //     稀疏臂逐字等于 dense 臂。确定性稀疏节拍（含 N=1 的 {4,0} 相位）由 3a-5 落。
  //   ST_COMPUTE (k_done):             issue_en = 0, array_step_en = 0
  //   ST_DRAIN (OS stepping):          issue_en = 1, array_step_en = 1  (T1: accumulate skewed tail)
  //   ST_DRAIN (WS stepping):          issue_en = 0, array_step_en = 1  (original WS, drain=15)
  //   ST_DRAIN (waiting for bank):     issue_en = 0, array_step_en = 0
  //   ST_CAPTURE:                      issue_en = 0, array_step_en = 0
  //   Others:                          issue_en = 0, array_step_en = 0

  // [K1a 2026-07-26] issue_en / array_step_en are now REGISTERED outputs.
  //
  // The old combinational cone (kept below as issue_ref/step_ref in
  // the translate_off shadow — [3a-1 S3] 它的 **sparse 臂已随实现同步改写为恒真占位**，
  // 其余四臂仍是逐字副本，故 "verbatim" 现在只对 k_done/dense/DRAIN/CAPTURE 成立)
  // decoded {state_q, k_done(cursor), sparse_mode,
  // frag_valid, cycle_cnt} and then broadcast ctrl_array_step_en raw to all
  // 256 MAC cells — the m1t signoff wall (worst 15 endpoints, slack −1220,
  // t2_arcdecomp_tensor_20260726.log): ~345ps decode + 19-stage BUFx16f tree
  // + slew-degraded entry gates riding the multiplier/LRU data cones via the
  // input_mux zero-gating. Here the SAME per-arm function is evaluated one
  // beat early on next-state values — state_d, k_done_next(cursor_d),
  // ~~frag_valid_next (queue count_d mirror, T2_Preflight §3b-2)~~【3a-1 S3 删除】, cycle_cnt_d,
  // tile_desc_d views — so {issue,step}_q(t) equals the old comb value(t) on
  // EVERY beat (registered identity: waveforms, golden, latency all
  // unchanged). A mis-predicted beat is NEW-1-class data corruption (§3b-3),
  // which is why every arm is mirrored exactly (including the defensive
  // k_done arm — reachable with a K=0 descriptor) and the shadow SVA below
  // pins the identity at runtime under --assert.
  //
  // -- next-state views (latch beat mirrored exactly; never leaning on state masking) --
  tile_descriptor_t tile_desc_d;
  assign tile_desc_d = ((state_q == ST_IDLE) && start) ? tile_desc : tile_desc_q;

  exec_sparse_mode_e sparse_mode_d_v;
  logic [15:0]       k_total_d_v;
  logic              os_mode_d_v;
  ncfg_e             n_cfg_d_v;        // [3a-6/P2] drain 分臂谓词的次态视图
  logic [15:0]       drain_limit_d_v;
  assign sparse_mode_d_v = tile_desc_d.sparse_mode;
  assign k_total_d_v     = tile_desc_d.k_total;
  assign os_mode_d_v     = (tile_desc_d.dataflow_sel == 1'b0);
  assign n_cfg_d_v       = tile_desc_d.n_cfg;
  // 🔴 [3a-6/P2] 与上方 `drain_limit`（寄存视图，:546 附近）**结构逐字同构** ——
  //    两者分叉即 K1A 逐拍 $fatal（响亮，非 fail-open）。谓词与理由见那一处的长注释。
  assign drain_limit_d_v = os_mode_d_v ? ((n_cfg_d_v != NCFG_DENSE) ? DRAIN_CYCLES_OS_SPARSE
                                                                    : DRAIN_CYCLES_OS)
                                       : DRAIN_CYCLES_WS;

  // [3a-4/M4] A1 的次态域副本（同一个 k_total_pad4，两域口径结构性一致）。
  logic [15:0] k_total_pad_d_v;
  assign k_total_pad_d_v = k_total_pad4(k_total_d_v);

  // cursor_d / cnt_d: exact mirrors of the Section 9 sequential arms.
  logic [15:0] dense_k_cursor_d;
  logic [15:0] cycle_cnt_d;
  always_comb begin
    dense_k_cursor_d = dense_k_cursor_q;
    cycle_cnt_d      = cycle_cnt_q;
    unique case (state_q)
      ST_IDLE: begin
        cycle_cnt_d      = 16'd0;
        dense_k_cursor_d = 16'd0;
      end
      ST_LOAD_WEIGHT: begin
        if (state_d == ST_CLEAR_ACC) cycle_cnt_d = 16'd0;
        else                         cycle_cnt_d = cycle_cnt_q + 16'd1;
      end
      ST_CLEAR_ACC: cycle_cnt_d = 16'd0;
      ST_COMPUTE: begin
        if (!k_done) begin
          // [3a-4/M4] S0-3 极性统一（本组第二处；第一处 = 上方时序臂，第三处 = M2 已拓的
          //   CURSOR MONOTONICITY SVA）。🔴 镜像臂的极性必须与被镜像的时序臂一致，
          //   否则 M6′ 分叉那天两者会各自选到对方的臂 —— 而 K1A-MASK 只会告诉你
          //   "cursor 对不上"，不会告诉你是极性写反了。
          if (sparse_mode_q == EXEC_SPARSE_STRUCT)
            // [3a-1 S3] 与上方时序臂 ST_COMPUTE 逐字同步（per-arm exact mirror）。
            //   🔴 不同步的当场闸 = K1A-MASK（下方 $fatal）：k_remaining_q 无使能地
            //   寄存 k_total_d_v − dense_k_cursor_d，而 k_total_q(t+1)==k_total_d_v(t)
            //   ⇒ 断言在 t+1 拍化简为 dense_k_cursor_d(t)==dense_k_cursor_q(t+1) 的
            //   **全 16 位相等**，任何一位偏差下一拍就炸。K1A 恒等那条只在偏差跨过
            //   k_total 阈值时才响（中间隔着 k_done_next 比较器），不是这一行的闸。
            //   🔴 **本条实测过**：M4 极性统一时手滑把 else 臂连同语句一起删掉，
            //   dense 发第 1/8 拍就 `%Fatal ... (q 23 live 22)` —— 一个字都没跑到 CSR。
            //   ▲**[3a-5/M6′]**：稀疏臂改消费 `k_step`，与上方时序臂 **K2 逐字同步**。
            //   两处只改一处 ⇒ K1A-MASK 当场 `$fatal`（那正是它存在的意义）。
            dense_k_cursor_d = dense_k_cursor_q + k_step;
          else
            dense_k_cursor_d = dense_k_cursor_q + {8'd0, pack_advance_q};
        end
        if (state_d == ST_DRAIN) cycle_cnt_d = 16'd0;
      end
      ST_DRAIN:   if (cycle_cnt_q < drain_limit) cycle_cnt_d = cycle_cnt_q + 16'd1;
      ST_CAPTURE: cycle_cnt_d = 16'd0;
      ST_DONE: begin
        cycle_cnt_d      = 16'd0;
        dense_k_cursor_d = 16'd0;
      end
      default: ;
    endcase
  end

  logic k_done_next;
  // [3a-4/M4] A4 —— 拆双臂 + pad。🔴 选择子必须是 `sparse_mode_d_v`（次态视图），
  //   用 `sparse_mode_q` 会在 latch 拍（ST_IDLE + start）选错臂 ⇒ 与 A3 的 k_done
  //   分叉一拍 ⇒ 被 K1A（registered issue/step diverged）当场抓住。
  assign k_done_next = (sparse_mode_d_v == EXEC_SPARSE_STRUCT)
                     ? (dense_k_cursor_d >= k_total_pad_d_v)
                     : (dense_k_cursor_d >= k_total_d_v);

  // -- f: per-arm mirror of the reference cone, on next-state values --
  logic issue_d, step_d;
  always_comb begin
    unique case (state_d)
      ST_COMPUTE: begin
        if (k_done_next) begin
          issue_d = 1'b0;
          step_d  = 1'b0;
        end else if (sparse_mode_d_v == EXEC_SPARSE_STRUCT) begin
          // [3a-1 S3] 稀疏臂逐字等于 dense 臂（原为 frag_valid_next 同时喂两侧）
          issue_d = 1'b1;
          step_d  = 1'b1;
        end else begin
          issue_d = 1'b1;
          step_d  = 1'b1;
        end
      end
      ST_DRAIN: begin
        issue_d = os_mode_d_v && (cycle_cnt_d < drain_limit_d_v);
        step_d  = (cycle_cnt_d < drain_limit_d_v);
      end
      ST_CAPTURE: begin
        issue_d = 1'b0;
        step_d  = 1'b0;
      end
      default: begin
        issue_d = 1'b0;
        step_d  = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      issue_en      <= 1'b0;   // == old comb IDLE arm
      array_step_en <= 1'b0;
      k_remaining_q <= 16'd0;  // == k_total(0) − cursor(0)
    end else begin
      issue_en      <= issue_d;
      array_step_en <= step_d;
      // [K1a-mask] k_total_q(t) − cursor_q(t), computed on next-state values
      // [3a-4/M4] A5 —— 规格 §2.1「三处 verbatim 同改」之一（另两处 = A6 的
      //   k_remaining_d、A7 的 K1A-MASK 参考式）。🔴 三处口径必须逐字一致，
      //   任一处漏改 ⇒ K1A-MASK 当场 $fatal（这正是它存在的意义）。
      k_remaining_q <= ((sparse_mode_d_v == EXEC_SPARSE_STRUCT)
                        ? k_total_pad_d_v : k_total_d_v) - dense_k_cursor_d;
    end
  end

  // ==========================================================================
  // [K1c 2026-07-27] next-state views of the array-broadcast controls
  // ==========================================================================
  //
  // Verbatim per-arm mirrors of the Section 6 tail-mask cone and the
  // clear_acc/capture_fire state decodes, evaluated on the SAME next-state
  // views the K1a issue/step registration uses (state_d, tile_desc_d,
  // cycle_cnt_d, drain_limit_d_v) plus:
  //   k_remaining_d      == the value registered into k_remaining_q (:above)
  //   k_step_d8          == next-beat k_step: ~~sparse arm from the queue's
  //                         dense_k_advance_next pipe (a controller-side
  //                         re-derivation cannot see the queue pointer state
  //                         — review F1-K1C)~~, dense arm from tile_desc_d
  //                         (pack_advance_q(t+1) == f(tile_desc_d(t))).
  //   🔴 [3a-1 S3 2026-08-03] **F1-K1C 那条约束已解除**（显式记述，不得默默删）：
  //     它的前提是「下一拍步长住在队列指针里，controller 侧无法自行推导」。
  //     K 令牌通路退役后，队列不存在，下一拍步长是 **controller 内部纯函数**
  //     （dense/sparse 两臂都由 tile_desc_d.mode 推出）⇒ 约束的前提消失。
  //     本片两臂同值；3a-5 落 N=1 {4,0} 相位时，sparse 臂改为相位计数器的纯函数，
  //     仍不需要任何外部指针状态。
  // Consumed ONLY by the tensor_ctrl_quad clone registers in the array; the
  // per-quadrant shadow SVAs there pin quad_q(t) == live(t) every beat.
  logic [15:0] k_remaining_d;
  // [3a-4/M4] A6 —— 与 A5 逐字同式（「三处 verbatim 同改」之二）。
  assign k_remaining_d = ((sparse_mode_d_v == EXEC_SPARSE_STRUCT)
                          ? k_total_pad_d_v : k_total_d_v) - dense_k_cursor_d;

  logic [7:0] k_step_d8;
  // ~~[3a-1 S3] 稀疏臂逐字等于 dense 臂~~（原为 frag_k_advance_next，即队列 rd_ptr_d 镜像）。
  //   dense_pack_advance 是 `function automatic`，同一 continuous assign 内出现两次安全。
  //   ▲**[3a-5/M6′] 稀疏臂改为下一拍的 `sparse_k_advance`**（次态视图：`tile_desc_d.n_cfg`
  //   + `k_phase_d`）—— 正是上方 F1-K1C 那段 3a-1 S3 记述预告的形态：
  //   「3a-5 落 N=1 {4,0} 相位时，sparse 臂改为相位计数器的纯函数，仍不需要任何外部指针状态」。
  //   🔴 它喂的是 `is_last_k_group_d`（K1c 侧），与 `k_step`(t+1) 必须逐字同值，
  //   否则 ctrl_quad 的逐拍影子 SVA 会红。
  assign k_step_d8 = (sparse_mode_d_v == EXEC_SPARSE_STRUCT)
                   ? sparse_k_advance(tile_desc_d.n_cfg,
                                      dense_pack_advance(tile_desc_d.mode), k_phase_d)
                   : dense_pack_advance(tile_desc_d.mode);

  logic is_last_k_group_d;
  assign is_last_k_group_d = (k_remaining_d <= {8'd0, k_step_d8})
                           && (k_remaining_d != 16'd0);

  always_comb begin
    if (state_d == ST_COMPUTE && is_last_k_group_d) begin
      unique case (tile_desc_d.mode)
        MODE_FP4, MODE_MXFP4, MODE_UINT4_SIMD: begin
          unique case (k_remaining_d[1:0])
            2'd0: active_tail_mask_d = 4'b1111;
            2'd1: active_tail_mask_d = 4'b0001;
            2'd2: active_tail_mask_d = 4'b0011;
            2'd3: active_tail_mask_d = 4'b0111;
          endcase
        end
        MODE_FP8, MODE_MXFP8: begin
          active_tail_mask_d = k_remaining_d[0] ? 4'b0001 : 4'b0011;
        end
        default: begin
          active_tail_mask_d = LANE_MASK_1;
        end
      endcase
    end else if (state_d == ST_COMPUTE) begin
      active_tail_mask_d = mode_full_lane_mask(tile_desc_d.mode);
    end else if (os_mode_d_v && state_d == ST_DRAIN
                 && cycle_cnt_d < drain_limit_d_v) begin
      active_tail_mask_d = mode_full_lane_mask(tile_desc_d.mode);
    end else begin
      active_tail_mask_d = 4'b0000;
    end
  end

  assign clear_acc_d    = (state_d == ST_CLEAR_ACC);
  assign capture_fire_d = (state_d == ST_CAPTURE);
  assign array_step_en_d = step_d;

  // [K1c][WS-guard, review F4-WS] WS×FP-acc is an ARCHITECTURAL EXCLUSION
  // guarded only by convention (is_valid_descriptor checks no dataflow×mode
  // cross): warn loudly in sim if a WS tile ever runs an FP-acc mode.
  // synopsys translate_off
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE && !os_mode)
        |-> (mode_q inside {MODE_UINT4_SIMD, MODE_UINT8})
  ) else $warning("K1C/WS-GUARD: WS tile running an FP-acc mode (mode %0d) — architectural exclusion, results undefined", mode_q);
  // synopsys translate_on

  // -- shadow reference: the pre-K1a combinational cone --
  //    [3a-1 S3] verbatim 身份**部分降级**：k_done / dense / DRAIN / CAPTURE 四臂仍是
  //    pre-K1a 逐字副本；**sparse 臂**已随实现改成恒真占位（D14 授权的最小替换，
  //    不做独立性重写）。~~恢复为真正独立的影子 = 3a-6 的验收项。~~
  //    ▲**[3a-6/P3 2026-08-05] 已兑现，但兑现方式与当初的设想不同 —— 必须读清楚**：
  //      本块的 sparse 臂**仍然是 `1'b1`，而且这是对的** —— 实现在 COMPUTE 里
  //      issue/step 恒 1（含 N=1 的气泡拍），任何独立重推导给出的也是 1
  //      ⇒ 把它改写成别的形状只会制造假红。**真正的独立性落在下方
  //      `[3a-6/P3] K1a / K1c 影子的【独立性重写】` 那一整块**：自带相位 FF +
  //      COMPUTE 拍数闭式，抓的是「拍数/相位/步长」而不是「issue 电平」。
  //      ⇒ 本处的登记从「待重写」改为「**本臂无独立性可言，鉴别力由下方块承担**」。
  // 🔴🔴 **[3a-6/P3 实付学费，留痕]** 下面这行 `translate_off` 曾在本次订正里**被一并删掉**
  //   （文本替换的 old 串把它裹进去了）⇒ 整个 K1a 影子块 + K1A/K1A-MASK 断言 + 下方 P3 块
  //   **全部掉出 translate_off 区，会被综合**。verilator lint **不报**，三闸也**全绿**
  //   —— 抓住它的是 P3 静态自检的「零综合」臂（`s3a6_p3_independence_selfcheck_20260805.sh`）。
  //   教训：**改注释也能改坏结构**；凡在 pragma 附近做文本替换，替换后必须重数 pragma 配对。
  // synopsys translate_off
  logic issue_ref, step_ref;
  always_comb begin
    unique case (state_q)
      ST_COMPUTE: begin
        if (k_done) begin
          // Defensive: k_done should trigger DRAIN via k_will_be_done.
          issue_ref = 1'b0;
          step_ref  = 1'b0;
        end else if (sparse_mode_q == EXEC_SPARSE_STRUCT) begin
          // [3a-1 S3] 稀疏臂逐字等于 dense 臂（原为 P1-1 的 issue_ref = frag_valid）。
          //   🔴 影子的 verbatim 身份因此**降级**：k_done / dense / DRAIN / CAPTURE
          //   四臂仍是 pre-K1a 逐字副本，**只有 sparse 臂**随实现同步改成恒真占位。
          //   这是 D14 授权内的最小替换（不做独立性重写），~~恢复时点 = 3a-5~~。
          //   ▲[3a-4/M2 2026-08-06 订正]：**恢复时点 = 3a-6**，与上方 `:921` 的
          //   「恢复为真正独立的影子 = 3a-6 的验收项」、蓝图 3a 项 6「K1a/K1c 影子
          //   **全套**重写（独立性验收）」、规格 §4.1 三处一致。
          //   （本行原写 3a-5 与 `:921` 互斥，属一次成文的措辞手滑；戊案审查裁决
          //    §2-M-1 判「四锚三比一指向 3a-6」，K1a+K1c **整套**留 3a-6。）
          issue_ref = 1'b1;
          step_ref  = 1'b1;
        end else begin
          // Dense mode: always issue, always step
          issue_ref = 1'b1;
          step_ref  = 1'b1;
        end
      end

      // HW-REVIEW T1 (F3): accumulate the skewed wavefront tail — OS ONLY.
      //   OS: during DRAIN stepping (cnt < drain_limit=31) the late-arriving real
      //   products for the far cells are still propagating through the skew/hop
      //   chains, so mac_en (issue_en) MUST stay high to accumulate them. The
      //   operand boundary is zero-padded for indices >= k_total (operand_fetch),
      //   so the extra cycles add exactly 0 for cells that have finished.
      //   WS: issue_en stays LOW in DRAIN (bit-identical to the pre-T1 array — WS
      //   results come from the INT psum chain, not the OS fp_acc). array_step_en
      //   follows drain_limit (WS=15, OS=31). At cnt == drain_limit both drop and
      //   we wait for the snapshot bank.
      ST_DRAIN: begin
        issue_ref = os_mode && (cycle_cnt_q < drain_limit);
        step_ref  = (cycle_cnt_q < drain_limit);
      end

      // R5: ST_CAPTURE — no compute activity, just capture_fire (handled above)
      ST_CAPTURE: begin
        issue_ref = 1'b0;
        step_ref  = 1'b0;
      end

      default: begin
        issue_ref = 1'b0;
        step_ref  = 1'b0;
      end
    endcase
  end

  // [K1a] the registered-identity tripwire: the registered outputs must equal
  // the verbatim pre-K1a combinational cone on EVERY beat, in every arm
  // (COMPUTE dense/sparse/k_done, DRAIN OS/WS/bank-wait, CAPTURE, idle). A
  // single diverging beat is NEW-1-class data corruption (fragment drop /
  // skew misalignment), so this is $fatal, not $error. Complements the
  // existing P1-1/R5-7/R5-8 assertions (kept verbatim above/below — they are
  // free per-arm equivalence checks and must never be "adapted" to the new
  // implementation).
  assert property (@(posedge clk) disable iff (!rst_n)
      (issue_en == issue_ref) && (array_step_en == step_ref)
  ) else $fatal(1, "K1A: registered issue/step diverged from the comb reference (issue %0b/%0b step %0b/%0b state %0d)",
                issue_en, issue_ref, array_step_en, step_ref, state_q);

  // [K1a-mask] registered-identity tripwires: the registered remaining count
  // must equal the live subtract, and the rewritten is_last must equal the
  // pre-K1a cursor-form, on every beat (incl. the 2^16-wrap corner the
  // algebraic proof excludes).
  // [3a-4/M4] A7 / A8 —— 参考式的 K 视图跟着 A5/A6 换 pad（谓词用 `sparse_mode_q`，
  //   因为断言比的是**寄存后**的 t 拍值）。这是「三处 verbatim 同改」之三。
  //   🔴 A7 有**两处**文字：断言体一处、`$fatal` 参数里 `k_total_q - dense_k_cursor_q`
  //   的第二次出现一处。漏掉后者会得到一条自相矛盾的报文 —— 断言按 pad 口径判红，
  //   报文里的 "live" 值却按原始 K 口径打印，归因时会被直接带偏。
  assert property (@(posedge clk) disable iff (!rst_n)
      k_remaining_q == (((sparse_mode_q == EXEC_SPARSE_STRUCT)
                         ? k_total_pad_q : k_total_q) - dense_k_cursor_q)
  ) else $fatal(1, "K1A-MASK: k_remaining_q diverged (q %0d live %0d)",
                k_remaining_q, ((sparse_mode_q == EXEC_SPARSE_STRUCT)
                                ? k_total_pad_q : k_total_q) - dense_k_cursor_q);
  assert property (@(posedge clk) disable iff (!rst_n)
      is_last_k_group == ((dense_k_cursor_q + k_step >= ((sparse_mode_q == EXEC_SPARSE_STRUCT)
                                                         ? k_total_pad_q : k_total_q))
                          && (dense_k_cursor_q < ((sparse_mode_q == EXEC_SPARSE_STRUCT)
                                                  ? k_total_pad_q : k_total_q)))
  ) else $fatal(1, "K1A-MASK: is_last_k_group diverged from the cursor form");

  // ==========================================================================
  // [3a-6/P3] K1a / K1c 影子的【独立性重写】—— 从 COMPUTE 拍计数 × n_cfg 重推导
  // ==========================================================================
  // **为什么非做不可**（本块存在的唯一理由，别当成锦上添花）：
  //   · K1a 侧 `issue_ref`/`step_ref` 的**稀疏臂**自 3a-1 S3 起是「恒真占位」——
  //     它与实现逐字相同 ⇒ 对稀疏臂**零鉴别力**（`:1157` 的降级登记就是说这件事）。
  //   · K1c 侧 `k_step_d8` 至今是拿**实现自己的 `k_phase_d`** 再算一遍
  //     ⇒ **相位错了两边一起错**，ctrl_quad 的逐拍影子 SVA 结构上抓不住。
  //   两者合起来 = 「影子」这个名字在稀疏路径上是空的。本块把它填实。
  //
  // **验收三条**（唯一定义处 = `Review/Stage3a45_Fusion_BuildSheet_2026-08-06.md` §3 第 1 条）：
  //   ① **从 COMPUTE 拍计数 × `n_cfg` 独立重推导** —— 本块用**闭式**算「这个 tile 应该在
  //      COMPUTE 里待几拍」，**不镜像实现的游标机器**：全块不读
  //      `dense_k_cursor_q` / `k_total_pad_q` / `k_remaining_q` / `is_last_k_group` /
  //      `k_will_be_done` / `k_done` 中的任何一个。它只读**描述符**（`k_total_q` /
  //      `mode_q` / `n_cfg_q` / `sparse_mode_q`）与**状态机**（`state_q` / `state_d`）——
  //      那是输入，不是被验对象。
  //   ② 🔴 **禁与实现共享相位 FF** —— 本块自带 `ref_phase_q`，与 `k_phase_q` 是**两个
  //      独立寄存器**、各自由各自的组合逻辑驱动，并逐拍断言两者同值。
  //   ③ **先红后绿** —— 红样本落盘，路径见 3a-6 台账 P3 段。
  //
  // 🔴 **全块在 `translate_off` 内 ⇒ 零综合、零面积、零时序**（3d 禁跑窗口内的硬要求）。
  // 🔴 **闭式的三个锚点在落笔前已用【已实测的三个数】交叉验证过**（不是纸面推导）：
  //      dense K=23 ⇒ 23 拍，`0x0c = 23+34 = 0x39`（`s3a6_p1_probe_before_20260804.log` 的 dense 对照发）
  //      N=4  K=23 ⇒ Kp=24 拍，`0x0c = 24+34 = 0x3a`（同 log 的 sparse 发）
  //      N=2  K=23 ⇒ 12 拍，`0x0c = 12+35 = 0x2f`（P2 闸2 的 cadence 载体）
  //    ⇒ 若本块首跑就红，先怀疑闭式而不是实现（三个锚点已经把闭式钉在实测上）。
  function automatic logic [15:0] ref_ceil_div(input logic [15:0] a, input logic [15:0] b);
    ref_ceil_div = (b == 16'd0) ? 16'd0 : (a + b - 16'd1) / b;
  endfunction

  logic        ref_sparse;
  logic [7:0]  ref_pack;
  logic [15:0] ref_kp;          // ⌈K/4⌉×4 —— 独立写，**不读** k_total_pad_q
  logic [15:0] ref_beats_exp;   // 闭式：本 tile 应有的 COMPUTE 拍数
  logic [7:0]  ref_k_step;      // 由**本块自己的相位**重推导的步长
  logic [15:0] ref_beat_q;      // 本块自己的 COMPUTE 拍计数
  logic        ref_phase_q;     // 🔴 本块自己的相位 FF（②的执行点）

  assign ref_sparse = (sparse_mode_q == EXEC_SPARSE_STRUCT);
  assign ref_pack   = dense_pack_advance(mode_q);
  assign ref_kp     = ((k_total_q + 16'd3) >> 2) << 2;

  always_comb begin
    if (!ref_sparse) begin
      // dense：每拍推进 pack ⇒ ⌈K/pack⌉ 拍
      ref_beats_exp = ref_ceil_div(k_total_q, {8'd0, ref_pack});
    end else if (ref_kp == 16'd0) begin
      ref_beats_exp = 16'd0;                          // 防御：空 tile 不该进 COMPUTE
    end else begin
      unique case (ncfg_survivors(n_cfg_q))
        3'd4:    ref_beats_exp = ref_ceil_div(ref_kp, {8'd0, ref_pack});  // k_step = pack
        3'd2:    ref_beats_exp = ref_ceil_div(ref_kp, 16'd2);             // k_step = 2
        // N=1：{4,0} 气泡 ⇒ 每 2 拍推进 4 ⇒ 到 Kp 需 2×(Kp/4) 拍，
        //   而末尾那个气泡拍被 k_will_be_done 的前瞻吞掉（规格 §6.3 的 drain 起点规则，
        //   `D-SPARSE-3A6-PREREQ-2026-08-04` Q3 裁决）⇒ −1。
        3'd1:    ref_beats_exp = (ref_kp >> 1) - 16'd1;
        default: ref_beats_exp = ref_ceil_div(ref_kp, {8'd0, ref_pack});  // N=3 保留值：退回 dense
      endcase
    end
  end

  always_comb begin
    if (!ref_sparse) ref_k_step = ref_pack;
    else begin
      unique case (ncfg_survivors(n_cfg_q))
        3'd4:    ref_k_step = ref_pack;
        3'd2:    ref_k_step = 8'd2;
        3'd1:    ref_k_step = ref_phase_q ? 8'd0 : 8'd4;   // 🔴 用【本块的】相位
        default: ref_k_step = ref_pack;
      endcase
    end
  end

  // 本块自己的两个 FF —— 结构上与实现的 k_phase_q 同形，但**是另一个寄存器**。
  //   同形是故意的：任何一边的驱动逻辑被改坏，两者立刻分叉（这正是影子要抓的）。
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ref_beat_q  <= 16'd0;
      ref_phase_q <= 1'b0;
    end else if (state_q == ST_CLEAR_ACC) begin
      ref_beat_q  <= 16'd0;
      ref_phase_q <= 1'b0;
    end else if (state_q == ST_COMPUTE) begin
      ref_beat_q  <= ref_beat_q + 16'd1;
      ref_phase_q <= ~ref_phase_q;
    end
  end

  // A. 【①的执行点】离开 COMPUTE 的那一拍，实走拍数必须等于闭式
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE && state_d != ST_COMPUTE)
      |-> ((ref_beat_q + 16'd1) == ref_beats_exp)
  ) else $fatal(1, "K1A-REF: COMPUTE beats %0d != independent form %0d (K=%0d n_cfg=%s sparse=%0b pack=%0d)",
                ref_beat_q + 16'd1, ref_beats_exp, k_total_q, n_cfg_q.name(), ref_sparse, ref_pack);

  // B. 【②的执行点】两个独立相位 FF 必须逐拍同值
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) |-> (ref_phase_q == k_phase_q)
  ) else $fatal(1, "K1C-REF: phase FF diverged (ref %0b impl %0b beat %0d)",
                ref_phase_q, k_phase_q, ref_beat_q);

  // C. 用本块相位重推导的步长必须与实现同值（K1c 侧 k_step_d8 共享相位的补偿）
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) |-> (k_step[7:0] == ref_k_step)
  ) else $fatal(1, "K1C-REF: k_step %0d != independent form %0d (n_cfg=%s ref_phase %0b)",
                k_step[7:0], ref_k_step, n_cfg_q.name(), ref_phase_q);
  // synopsys translate_on

  // [3a-1 S3] ~~Sparse fragment flow control (P1-2: authoritative ready)~~ 已删除

  // ---- Result valid ----
  //
  // R5: result_valid still pulses in ST_DONE, but the semantic shift is
  // worth noting — it now means "tile result is in the snapshot bank and
  // egress scan has started", rather than "accumulator contents are the
  // tile result". External consumers see it as the tile completion pulse
  // regardless.
  assign result_valid = (state_q == ST_DONE);

  // ---- Debug ----
  assign dense_k_cursor_out = dense_k_cursor_q;

  // ==========================================================================
  // Section 11: Assertions
  // ==========================================================================
  // synopsys translate_off

  // ---- A1 CRITICAL: clear_acc mutual exclusion ----
  assert property (@(posedge clk) disable iff (!rst_n)
      !(clear_acc && issue_en)
  ) else $fatal(1, "TENSOR_TILE_CTRL [A1]: clear_acc and issue_en asserted simultaneously");

  assert property (@(posedge clk) disable iff (!rst_n)
      !(clear_acc && array_step_en)
  ) else $fatal(1, "TENSOR_TILE_CTRL [A1]: clear_acc and array_step_en asserted simultaneously");

  // ---- B3: k_total_q valid at ST_CLEAR_ACC ----
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_CLEAR_ACC) |-> (k_total_q > 16'd0)
  ) else $error("TENSOR_TILE_CTRL [B3]: k_total_q is zero at ST_CLEAR_ACC — start with K=0?");

  // ---- CURSOR MONOTONICITY ----
  // 🔴 [3a-4/M2 · C1-d] 谓词由 `== EXEC_DENSE` **拓成双臂**。
  //   拓之前它写死 dense ⇒ M2 放宽 `tensor_mac_array` 的 exec 白名单、稀疏臂第一次
  //   可达之后，这条 SVA 在**载体上会整条熄灭**（前件恒假），而 3a-4 改的正是 cursor
  //   的收官谓词 ⇒ 最需要它的那一刻它不在。
  //   今天两臂**逐字同值**（稀疏臂是 3a-1 S3 的占位，见 :320-323）⇒ 本改动**红惰性**、
  //   对 dense 逐位零扰；它的作用是在 M4/M6′ 两臂真分叉时**继续守着两边**。
  // 🔴 边界（防误判成漏改）：本处属 **M2**；`:628` / `:769` 两处反极性组的
  //   **极性统一归 M4 的 S0-3** ⇒ **M2 收口时该反极性组的【代码行】计数应为 2，不是 0**
  //   （BuildSheet M4 段的自证框是唯一定义处）。
  // 🔴🔴 自证口径必须**排除注释行**，否则本条注释自己就会被数进去（本片实测：
  //   全文 grep = 3、代码行 = 2）—— 这是「判据文本自指」陷阱在本战役的**第三次**实付
  //   （前两次在 M0 检查器）。正确口径见 BuildSheet M4 自证框。
  // ~~原式（3a-4/M2 拓双臂后的形态，已被 3a-6/P4 取代，划掉保留以便追溯）~~：
  //   ~~|=> (dense_k_cursor_q > $past(dense_k_cursor_q))~~
  //
  // ==========================================================================
  // 🔴🔴 **[3a-6/P4 2026-08-05] 气泡口 —— 这是一次【加强】，不是放宽。读清楚再动。**
  // ==========================================================================
  // **为什么必须动**：M6′ 落的 N=1 `{4,0}` 气泡拍上 `k_step = 0` ⇒ cursor 不推进
  //   ⇒ 原式前件成立而后件恒假 ⇒ **每个气泡拍必 `$error`**（`--assert` 下 abort、闸2 判红）。
  //   本片之前 N=1 不可达（被下方 C2 白名单臂先 `$fatal` 截断），P4 放宽 C2 的**同一次改动**
  //   里必须一并处理 —— 否则第一个 N=1 tile 就撞它，而报文写「cursor not advancing」
  //   ⇒ **红因被路由到「相位实现错了」**，真相却是「SVA 没给气泡开口」。
  //
  // 🔴 **禁用改法（BuildSheet §3 第 5 条 (5-b)，同批已进 §5 退路表；三条都是净损失）**：
  //   ⛔ 把后件 `>` 改成 `>=` —— cursor 在 COMPUTE 内只做 `+k_step`（非负）
  //      ⇒ 改完**结构恒真** = `§5.0d 型 9` 教科书形态，而**三闸对恒真 SVA 全盲**。
  //   ⛔ 整条 `disable` 稀疏臂 / 把前件的 `sparse_mode_q inside {…}` 收成 dense-only
  //      —— 那是回退 M2 的 C1-d 拓双臂；`Stage3a1_TokenRetirement_BuildSheet_2026-08-02.md:404`
  //      对**同一条 SVA** 早已写死「免费守卫，删一条就是净损失」。
  //   ⛔ 照旧注释写的「改用『issue 拍上才要求单调』的谓词」—— **它在今天是空操作**：
  //      `issue_d` 在 ST_COMPUTE 的两个非 `k_done_next` 子臂逐字都是 `1'b1`（Section 8b），
  //      而本条前件已含 `!k_done` ⇒ 加 `&& issue_en` 前后完全等价，照它改仍每个气泡拍 `$error`。
  //      **(5-c) 的登记点就是这一句。**
  //
  // **本次的开法 = 把「单调」升级成「精确 + 活性」两条，判伪面严格变大**：
  //   [C-1 精确推进] cursor(t+1) 必须**恰好** = cursor(t) + k_step(t)。
  //       比原式强：原式只要求「变大」，本式连**变大多少**都钉死；气泡拍
  //       （k_step=0 ⇒ cursor 不动）自然落在等式内，不需要任何豁免口。
  //       实现侧对应行 = Section 9 的 `dense_k_cursor_q <= dense_k_cursor_q + k_step`
  //       （dense 臂写 `pack_advance_q`，而 dense 的 `k_step` 逐字等于它 ⇒ 两臂同式）。
  //   [C-2 气泡活性] 不允许**连续两拍** `k_step == 0`。
  //       它接住原式唯一比 C-1 强的地方 —— **liveness**：C-1 允许 `k_step ≡ 0` 的死循环
  //       （cursor 永不推进而等式恒真）。C-2 堵死它，且报文保留逐字 `cursor not advancing`
  //       以便红因路由不变。`{4,0}` 在 N=1 上恰好一拍气泡 ⇒ 对正确实现零误报；
  //       dense / N=4 / N=2 的 k_step 恒 ≥1 ⇒ 前件恒假、真空成立。
  //   ⇒ **C-1 ∧ C-2 严格强于原式**。
  //   🔴 **红样本 (5-a) 已跑**：cursor 推进量改 `k_step+1` ⇒ C-1 红；稀疏臂 k_step 钉死恒 0
  //     ⇒ C-2 红。两份 log 落盘，路径见 3a-6 台账 P4 段。
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) && !k_done
      && (sparse_mode_q inside {EXEC_DENSE, EXEC_SPARSE_STRUCT})
      |=> (dense_k_cursor_q == $past(dense_k_cursor_q) + $past(k_step))
  ) else $error("TENSOR_TILE_CTRL [C-1]: dense_k_cursor advance != k_step (cursor %0d past %0d k_step %0d) — mode-agnostic since 3a-4/M2, exact form since 3a-6/P4",
                dense_k_cursor_q, $past(dense_k_cursor_q), $past(k_step));

  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) && !k_done
      && (sparse_mode_q inside {EXEC_DENSE, EXEC_SPARSE_STRUCT})
      && (k_step == 16'd0) && (state_d == ST_COMPUTE)
      |=> (k_step != 16'd0)
  ) else $error("TENSOR_TILE_CTRL [C-2]: dense_k_cursor not advancing in COMPUTE — two consecutive zero k_step beats (气泡口只许一拍)");

  // ---- TAIL MASK VALIDITY ----
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) |-> (active_tail_mask != 4'b0000)
  ) else $error("TENSOR_TILE_CTRL [A4]: active_tail_mask is all-zero during COMPUTE");

  // [3a-1 S3] ~~SPARSE K ADVANCE~~ 已删除。
  //   本条属 3a-2（`sparse_expected_k_advance` 除名）的工作面，但它引用 frag_dense_k_advance
  //   与 frag_valid ⇒ **被强制拉进本 commit**，否则本步结束时 elaborate 硬红。
  //   🔴 覆盖账：它是 $warning 级，**两个闸都不看**（run_all.py 只认 PASS/FAIL 正则、
  //   elaborate_smoke.sh 只 grep %Error 且 --lint-only 无 --assert）⇒ 删它零覆盖损失。

  // ---- STATE INVARIANT: at most one phase-defining output is active ----
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({weight_load_en, clear_acc, issue_en, capture_fire})
  ) else $error("TENSOR_TILE_CTRL: multiple phase signals active simultaneously");

  // ---- v4.2a Round A assertions (retained) ----

  // P0-1: k_will_be_done in COMPUTE always triggers DRAIN transition
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) && k_will_be_done
      |-> (state_d == ST_DRAIN)
  ) else $error("TENSOR_TILE_CTRL [P0-1]: k_will_be_done did not trigger DRAIN transition");

  // P0-1: No COMPUTE bubble — k_done should never persist in COMPUTE
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) |-> !k_done
  ) else $warning("TENSOR_TILE_CTRL [P0-1]: k_done while still in COMPUTE — possible off-by-one");

  // P1-1: Sparse stall coherence — issue_en == array_step_en in sparse COMPUTE
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_COMPUTE) && (sparse_mode_q == EXEC_SPARSE_STRUCT) && !k_done
      |-> (issue_en == array_step_en)
  ) else $error("TENSOR_TILE_CTRL [P1-1]: issue_en != array_step_en during sparse COMPUTE");

  // ---- v4.2c Round C assertions (retained) ----

  // [3a-1 S3] ~~P2-2: sparse_group_last_fire in COMPUTE always triggers DRAIN~~ 已删除
  //   （观测量随 sparse_group_last_fire 一并消失）。**覆盖净损失**：等价物 = 确定性尾窗
  //   收官判据，由 3a-4 落（`k_total_pad` + `k_done`/`k_will_be_done` 双臂）。

  // P2-3: MX_BLOCK_SIZE must be a power of 2 (compile-time check)
  initial begin
    if ((MX_BLOCK_SIZE & (MX_BLOCK_SIZE - 1)) != 0)
      $fatal(1, "TENSOR_TILE_CTRL [P2-3]: MX_BLOCK_SIZE (%0d) is not a power of 2", MX_BLOCK_SIZE);
    if (MX_BLOCK_SIZE < 8 || MX_BLOCK_SIZE > 128)
      $fatal(1, "TENSOR_TILE_CTRL [P2-3]: MX_BLOCK_SIZE (%0d) out of range [8..128]", MX_BLOCK_SIZE);
  end

  // ==========================================================================
  // ---- R5 NEW assertions ----
  // ==========================================================================

  // R5-1: capture_fire is exactly the ST_CAPTURE indicator
  assert property (@(posedge clk) disable iff (!rst_n)
      capture_fire == (state_q == ST_CAPTURE)
  ) else $error("TENSOR_TILE_CTRL [R5-1]: capture_fire inconsistent with ST_CAPTURE state");

  // R5-2: capture_done is exactly the ST_DONE indicator
  assert property (@(posedge clk) disable iff (!rst_n)
      capture_done == (state_q == ST_DONE)
  ) else $error("TENSOR_TILE_CTRL [R5-2]: capture_done inconsistent with ST_DONE state");

  // R5-3: ST_CAPTURE must transition to ST_DONE in next cycle (1-cycle contract)
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_CAPTURE) |=> (state_q == ST_DONE)
  ) else $error("TENSOR_TILE_CTRL [R5-3]: ST_CAPTURE did not transition to ST_DONE in next cycle");

  // R5-4: DRAIN → CAPTURE transition requires snapshot_bank_available.
  //       This prevents overwriting a previous tile's snapshot.
  assert property (@(posedge clk) disable iff (!rst_n)
      ((state_q == ST_DRAIN) && (state_d == ST_CAPTURE))
      |-> snapshot_bank_available
  ) else $error("TENSOR_TILE_CTRL [R5-4]: DRAIN → CAPTURE without snapshot_bank_available");

  // R5-5: capture_fire and clear_acc must never overlap.
  //       Enforces the invariant checked in mac_cell's defense-in-depth assertion.
  assert property (@(posedge clk) disable iff (!rst_n)
      !(capture_fire && clear_acc)
  ) else $fatal(1, "TENSOR_TILE_CTRL [R5-5]: capture_fire and clear_acc asserted simultaneously");

  // R5-6: Descriptor legality check on start.
  //       Uses the is_valid_descriptor() helper from tensor_pkg.
  //
  // 🔴 [3a-7/P3 2026-08-05] `$error` → `$fatal`（规格 §5.4 逐字「R5-6 断言升 $fatal」）。
  //   本条与 3a-7/P3 给 is_valid_descriptor 新加的三条臂**同 commit**。
  //
  // 【采样时点，判读矩阵靠它】本条采的是 `tile_desc`（controller 的**输入端口**，接
  //   tensor_unit_top 的 `dq_rd_desc`），**未锁存**；而 tensor_mac_array 侧的两条白名单臂
  //   观测的是 `ctrl_tile_desc_active` ← `tile_desc_q`（本文件在 ST_IDLE+start 那一拍才装载）
  //   ⇒ **R5-6 比它们早一拍**。凡三条新臂命中的注入，**R5-6 先响并 abort**，
  //   下游 tag 不再出现。tb/scratch_guard_probe.py 的期望矩阵已同批重挂为**双锚**
  //   （模块 tag + 报文关键字），因为 R5-6 与下方 [3a-3] 臂同模块同 tag，只有关键字能区分：
  //     · 本条报文含 `illegal descriptor`
  //     · [3a-3] 白名单臂报文含 `unsupported`
  //   关键字取自**现役报文正文**（语义描述，不是版本号）⇒ 不违探针的「禁钉版本号」纪律。
  //
  // 🔴 措辞：升 `$fatal` 改的是**仿真告警的响度**，**不是**拒收 ——
  //   `desc_push_valid` 未加门，非法描述符照样入队（型 15 的定性到 P5 才失效）。
  assert property (@(posedge clk) disable iff (!rst_n)
      ((state_q == ST_IDLE) && start) |-> is_valid_descriptor(tile_desc)
  ) else $fatal(1, "TENSOR_TILE_CTRL [R5-6]: illegal descriptor at start (exec_class/out_class combination)");

  // ==========================================================================
  // [3a-3 2026-08-04] n_cfg 白名单臂 —— 与 tensor_mac_array 的 exec 臂【合取，不替换】
  // ==========================================================================
  //
  // 🔴 措辞纪律（PROJECT_RULES §5.0d C7）：本条**不是**硬闸、**不是**写入时拒收。
  //    它是 $fatal 级【仿真绊线】。n_cfg 保留值的真正拒收归 3a-7
  //    （is_valid_descriptor 补保留值判）~~与 3a-8（CP poison / cp_desc_fetch 的
  //    wi==4 分支 —— 该分支今天不存在，实测只有 wi==6）~~。
  //    ▲订正（2026-08-05，3a-7 开工前对抗审查裁决 §1.3）：`wi==4` 编码拒归 **3a-7**，
  //    不是 3a-8。3a-8 的是【触发集 n_cfg≠0 的临时硬闸】，蓝图项 8 逐字「3b/3c 落地后拆闸」；
  //    而 `wi==4` 的 `2'b11` 拒是【触发集 {2'b11} 的永久编码拒】，🔴 **不随临时闸拆除**。
  //    两者并成一条 ⇒ 拆临时闸当天连坐拆掉永久拒 ⇒ 硅上静默复发。
  //    （`wi==4` 分支今天确实仍不存在 —— 这句仍成立，由 3a-7/P2 落。）
  //
  // 【为什么要有它】3a-3 当天 n_cfg 无读回口（规格 §5.2）、零消费者，逐端口行为与
  //    n_cfg=00 位位相同 ⇒ 第 5-9 层【全部漏改都是静默的】：第 5/9 层复位分支已赋
  //    ⇒ 无 UNDRIVEN 无 LATCH；第 7 层的 UNDRIVEN 两闸都盲。
  //    本臂是这几层唯一**不需新增端口/新增探针**的可执行观测点 —— 它把「描述符链
  //    到底通没通」变成可红可绿。验收判据 = 红臂矩阵 P3/P4 + P5 mutation
  //    （注释掉 desc_out.n_cfg 后 P3 必须由红转绿；仍红 ⇒ 本臂没在观测被 plumb 的值）。
  //
  // 【为什么必须与 exec 臂合取而不是替换】0x08 有两个可独立驱动的字段：
  //    [1:0] exec 与 [3:2] n_cfg，decoder 是两条互不校验的裸锁存。
  //    直写 0x08=0x04 ⇒ (exec=EXEC_DENSE, n_cfg=NCFG_1OF4)：mac_array 的
  //    白名单臂放行、控制器按 dense 跑。删掉 exec 臂则镜像成立。
  //    ▲[3a-4/M2 2026-08-06 订正] 原文此处写的是 `~~inside {EXEC_DENSE}~~`；
  //      M2 已把该臂放宽为 `inside {EXEC_DENSE, EXEC_SPARSE_STRUCT}`。
  //      **本段的论证不受影响**（它只需要「exec 臂对 `0x08=0x04` 放行」，放宽后更放行）；
  //      改的只是那个集合的字面。~~🔴 **本臂（n_cfg 侧，C2）本片不动** ——
  //      放宽到 `{NCFG_DENSE, NCFG_2OF4}` 归 **M5′**，`2'b01`/`2'b11` 届时仍拒收~~
  //      ▲**[3a-4/M5′ 2026-08-03 已兑现]（原文划掉保留）**：本臂已放宽为
  //      `inside {NCFG_DENSE, NCFG_2OF4}`。**`NCFG_1OF4 = 2'b01` 与 `NCFG_RESERVED = 2'b11`
  //      继续拒收** —— 这不是保守，是**判据完整性**：下方【为什么要有它】段的验收判据
  //      P3（`0x08=0x04`，n_cfg=NCFG_1OF4）必须保持红，否则 P5 mutation 锚
  //      （「注释掉 `desc_out.n_cfg` 后 P3 必须由红转绿」）退化为恒绿
  //      ⇒ 3a-3 的 B6「链是通的、不是恒 0 死链」唯一正向证明当场蒸发。
  //      （保住 P3/P4/P5 三锚，理由见裁决 §4 的 §8-1/§8-2）
  //      🔴 **本次放宽的活体正证 = 红→绿样本对，不是放宽后那三个数**：
  //        放宽前 `tb/test_tensor_sparse_cadence.py` 三发全部 `%Fatal ... n_cfg=NCFG_2OF4
  //        unsupported`（红证 `aichip_run_logs/s3a45_m5p_carrier_red_k{23,24,25}_20260806.log`，
  //        报文逐字点名 NCFG_2OF4 ⇒ n_cfg 确实抵达 controller）；放宽后三发全过。
  //        🔴 **放宽后那三个数与「n_cfg 恒 0 死链」在数值上不可区分**（k_step 未重写
  //        ⇒ 拍数 = Kp，与 N 无关）⇒ **禁称「已证明 n_cfg 被消费」**；
  //        n_cfg 进入数据通路的正证要等 M6′ 的翻值（Kp+34 → ⌈K/4⌉×2+34）。
  //    两臂在不同模块，合取的自证靠红臂矩阵「本模块 tag ≥1」那半条
  //    （$fatal(1) 首发即 abort ⇒ 「另一模块 tag=0」近乎恒真、不承载证明力）。
  //
  // 🔴 disable iff (!rst_n) 不可省，且本臂的正确性押在 NCFG_DENSE == 2'b00 上：
  //    dense 侧安全的两个锚 = tensor_external_modules 的 reg_n_cfg <= NCFG_DENSE
  //    与本文件下方的 tile_desc_q <= '0。改编码则本臂在每个 dense tile 上假红。
  //
  // 观测量取 tile_desc_q（latch 后）：与 mac_array 臂看到的是同一拍的同一份描述符。
  // 🔴🔴 **[3a-6/P4 2026-08-05] 放宽到含 `NCFG_1OF4`，写法 = 【合取式】不是字面加项**
  //   （`D-SPARSE-3A6-PREREQ-2026-08-04` **Q1** 用户拍板；仓内同款体例 =
  //   `Tensor/tensor_mac_array.sv:1173` 的 WS-GUARD）。
  //
  // **为什么不能写成字面加项 `inside {NCFG_DENSE, NCFG_2OF4, NCFG_1OF4}`**：
  //   那样 `tb/scratch_guard_probe.py` 的 **P3 发**（`0x08=0x04`，
  //   `exec=EXEC_DENSE ∧ n_cfg=NCFG_1OF4`）会**由红转绿** ⇒ **P5 mutation 锚退化为恒绿**
  //   ⇒ 3a-3 的 B6「链是通的、不是恒 0 死链」**唯一正向证明当场蒸发**
  //   （依赖链逐字在 `scratch_guard_probe.py` 的 P5 段：「P5 的有效性依赖 P3 保持红」）。
  //   合取式只放行**真正要用它的那一种 tile**（N=1 稀疏执行），P3 那一发因 `exec=EXEC_DENSE`
  //   **仍被拒收** ⇒ 守备面是**收窄**不是拆除，P5 锚原地有效、BuildSheet §3 第 11 条自动免除。
  //
  // 🔴 **代价与新增验收（不是白拿的）**：
  //   ① 白名单臂从单字段变双字段合取，与规格 §5.1a 的 n_cfg 值分派表口径有距离 ⇒ 收口报告须登记；
  //   ② **放宽当天必须实测「P3 发仍红」并落盘** —— 否则「合取式生效了」与「根本没放宽」
  //      在证据上不可区分（`§5.0d 型 3` 的空集绿）。唯一定义处 = 预登记 §9 末段。
  //   ③ `NCFG_RESERVED`（`2'b11`）**继续无条件拒收**，P4 发不受影响。
  //
  // 🔴 措辞：本条是 **$fatal 级仿真绊线 / 白名单臂**，**不是硬闸**。
  //   ~~描述符层面的真拒收归 3a-7（规格 §5.4）~~
  //   ▲**[3a-7/P5 2026-08-06 订正]：描述符层面的真拒收【已落地】** ——
  //   `tensor_external_modules.sv` 的 `assign desc_push_valid = start_pulse && !desc_reject;`。
  //   🔴🔴 **这改变了本臂的现役职责，必须看懂再改本臂**：
  //   门只拦 `is_valid_descriptor` 判**非法**的描述符（保留值、EXEC_NONE×ESCAPE_FMT、
  //   FORMAT_ONLY×native、WS×非dense）。而本臂拒的是「**合法但本实现不支持**」的组合
  //   —— 典型是 `(exec=EXEC_DENSE, n_cfg=NCFG_1OF4)`：两个字段**都不是保留值**、
  //   `dataflow_sel=0` ⇒ **门放行、照样入队** ⇒ **本臂是它唯一的守门**。
  //   ⇒ 🔴 **P5 之后，本臂是 `tensor_tile_controller` 里【唯一仍有红样本】的描述符类断言**
  //     （R5-6 已因门的存在对非法描述符结构性不可达）。它的红样本 =
  //     `tb/scratch_guard_probe.py` 的 **P3 发**（`0x08=0x04`，关键字 `unsupported`）。
  //     **动本臂前必须先跑那一发**；它同时是 3a-3「n_cfg 链是通的」的唯一正向证明。
  //   · **3a 末态临时闸仍归 3a-8**（蓝图项 8 的「n_cfg≠0 即拒」会打掉本片两个合法载体
  //     ⇒ 须留豁免口，见 BuildSheet §3 第 13 条）。
  assert property (@(posedge clk) disable iff (!rst_n)
      (n_cfg_q inside {NCFG_DENSE, NCFG_2OF4})
      || ((n_cfg_q == NCFG_1OF4) && (sparse_mode_q == EXEC_SPARSE_STRUCT))
  ) else $fatal(1, "TENSOR_TILE_CTRL [3a-3]: n_cfg=%s unsupported (exec=%s；1:4 只在 exec=EXEC_SPARSE_STRUCT 下放行，保留值一律拒)",
                n_cfg_q.name(), sparse_mode_q.name());

  // R5-7: array_step_en during DRAIN is precisely bounded by drain progress
  //       (drain_limit = OS 31 / WS 15). Active stepping while cnt < drain_limit;
  //       0 on the bank-wait cycle (cnt == drain_limit).
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_DRAIN) |->
        (array_step_en == (cycle_cnt_q < drain_limit))
  ) else $error("TENSOR_TILE_CTRL [R5-7]: array_step_en inconsistent with drain progress");

  // R5-8 (HW-REVIEW T1): issue_en accumulates the skewed tail in OS DRAIN only;
  // in WS it stays low through DRAIN (bit-identical to the pre-T1 array). This
  // pins the dataflow gating of the accumulate-tail rework.
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == ST_DRAIN) |->
        (issue_en == (os_mode && (cycle_cnt_q < drain_limit)))
  ) else $error("TENSOR_TILE_CTRL [R5-8]: issue_en not OS-gated / inconsistent in DRAIN");

  // synopsys translate_on

endmodule

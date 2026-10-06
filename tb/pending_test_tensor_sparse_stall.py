"""🔴 PENDING（3a-1 起，2026-08-02）—— 本文件已【退出门禁】。

`pending_` 前缀 = 退出 `tb/run_all.py:20` 的 `test_*.py` glob 的**唯一机制**
（全仓此前无 `pending_` 先例，故就地写明，免得后人以为是笔误）。

## 为什么退役

规格 §4.1「K 令牌通路整体退役」把本文件赖以成立的前提整体推翻：
  · fragment 通路（`sparse_frag_*` / `frag_valid` / `frag_dense_k_advance` …）本身被删；
  · 「稀疏靠 frag_valid 驱动、stall 时冻结整条流水」的语义被 §4.3 的
    **权重流零行气泡节拍 {4,0}**（act/step 全速自由跑）取代；
  · 它的 TOPLEVEL `tb_tensor_gemm_sparse.sv` 已随 3a-1 **删除**（它引用的端口不复存在）。
  · docstring 里关于 `sparse_expected_k_advance(BF16)=2` 的推导也作废
    —— 该函数由 3a-2 除名（旧值域 FP4→8/FP8→4/default→2 编码的是旧 N:2N 方案）。

## 复活条件（缺一不可）

1. **3c 金标重写**：`Model/nm_sparse_golden.py` 到位（nm_prune/nm_pack/nm_expand，独立写禁抄 RTL）；
2. **新 harness**：旧的 `tb_tensor_gemm_sparse.sv` 已删，须按 N:M 新语义重建
   （meta 旁带 + 确定性节拍，不再有 fragment 握手）；
3. 判据按规格 §8.2 R2/R3 重写（本文件现有的 stall 计数/丢行签名全部不适用）。

🔴 复活时**不得**直接 `git revert` 本次改名 —— 那会把上面三条前提一并复活成假绿。

---

（以下为退役前原文，保留作机理档案）


test_tensor_sparse_stall.py — §A2/§C6 prerequisite guard (M3 preflight, 2026-07-24):
EXEC_SPARSE_STRUCT frag-stall + back-to-back multi-tile accumulation vs the exact
GEMM golden.

HISTORY (red→green, evidence in aichip_run_logs/m3_*_20260724.log): born as
pending_test_* and RED on the pre-fix RTL — the free-running in_range_d
(tensor_external_modules.sv, OS zero-pad mask) read 0 on the first array step
after a frag stall and dropped the REAL operand row held in the SRAM dout
register (one row per stall event; mismatch == golden minus exactly those rows).
GREEN since the NEW-1 hold-between-issues fix. Renamed into the run_all glob as
a standing guard. Full mechanism + review:
Review/C6_Preflight_ValidQual_SparseStall_2026-07-24.md.

What it proves (M2M3_AnchorPlan_ExecOrder §A2 "MISSING EVIDENCE"):
  - An EXEC_SPARSE_STRUCT tile is dense flow control + stalls: the fragment
    payload fields are RESERVED (tensor_pkg.sv:402-403, unused anywhere); operands
    still stream from SRAM. With dense_k_advance=1 a sparse tile must therefore
    produce BIT-IDENTICAL results to the dense tile over the same A/B — any
    difference is a flow-control/accumulation defect. (dense_k_advance=1 differs
    from sparse_expected_k_advance(BF16)=2, which only trips a $warning-severity
    assert, tensor_tile_controller.sv:755-759 — deliberate: with advance=2 the
    os_zero_pad boundary (offset-based) diverges from the cursor-based k_done and
    the drain re-admits real SRAM rows, a separate deferred-sparse-producer
    semantic gap we do NOT bake into a golden.)
  - test 1 (control, no stalls): sparse plumbing == dense golden.
  - test 2 (frag stalls injected): stall/resume must not lose or re-add products.
    On failure the diagnostic solver decomposes the mismatch into a dropped-row
    set (identifies operand-path masking bugs by name).
  - test 3 (back-to-back two stalled tiles, no reset): the §A2 inter-tile-gap
    scenario (CAPTURE..CLEAR_ACC) on top of stalls.
  These are also the negative controls for the §C6 feedforward cut: the naive
  valid-held form (register valid clocked by array_step_en, no qualification)
  re-adds the pre-stall product S+1 times — invisible to every dense guard
  (proven: m3_mutant_dense_guard_20260724.log 2/2 PASS), RED here
  (m3_mutant_sparse_red_20260724.log).

Run: cd tb && make MODULE=test_tensor_sparse_stall TOPLEVEL=tb_tensor_gemm_sparse \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_sparse_ingress_queue.sv ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_sparse.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from cocotb.utils import get_sim_time
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g
import gemm_operands as go   # 批 4a: 去混叠激励 + 硬闸（见该模块头注）

# MMIO register addresses (tensor_cmd_decoder)
A_CTRL, A_KTOTAL, A_SPARSE, A_OUTCTRL, A_EPOCH = 0x00, 0x04, 0x08, 0x0C, 0x10
A_WGT, A_ACT, A_SCL, A_RES = 0x14, 0x18, 0x1C, 0x20

MODE_BF16 = 4
EXEC_SPARSE_STRUCT = 1     # tensor_pkg exec_sparse_mode_e
SP_GROUP_1OF2 = 0          # BF16 group kind
ROWS = COLS = 16


# ── low-level drivers (same conventions as test_tensor_gemm_core) ─────────────

async def reset(dut):
    for s in ("mmio_wr_valid", "mmio_wr_addr", "mmio_wr_data", "mmio_rd_addr",
              "dma_wgt_en", "dma_act_en", "dma_scale_en", "dma_addr",
              "dma_data", "dma_scl_wgt", "dma_scl_act", "egress_ready",
              "sparse_frag_valid", "sparse_frag_bits"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def mmio(dut, seq):
    for addr, data in seq:
        dut.mmio_wr_valid.value = 1
        dut.mmio_wr_addr.value = addr
        dut.mmio_wr_data.value = data
        await RisingEdge(dut.clk)
    dut.mmio_wr_valid.value = 0
    await FallingEdge(dut.clk)


async def dma_row(dut, kind, addr, data256):
    dut.dma_wgt_en.value = 1 if kind == "wgt" else 0
    dut.dma_act_en.value = 1 if kind == "act" else 0
    dut.dma_scale_en.value = 1 if kind == "scl" else 0
    dut.dma_addr.value = addr
    dut.dma_data.value = data256
    await RisingEdge(dut.clk)
    dut.dma_wgt_en.value = 0
    dut.dma_act_en.value = 0
    dut.dma_scale_en.value = 0


def pack_row(vals):
    w = 0
    for i, v in enumerate(vals):
        w |= (g.bf16_bits(float(v)) & 0xFFFF) << (i * 16)
    return w


def snap_cell(snap_int, r, c):
    return (snap_int >> ((r * COLS + c) * 61)) & ((1 << 61) - 1)


# ── sparse fragment encoding (packed sparse_tensor_frag_t, tensor_pkg.sv:401) ──
#   [72:57] act_payload  [56:41] wgt_payload  [40:33] act_scale  [32:25] wgt_scale
#   desc[24:0] = [24:23] sparse_mode  [22:21] sparse_group  [20:13] dense_k_advance
#                [12:9] tail_mask     [8] group_last        [7:0] meta_epoch
def frag_bits(k_adv=1, last=False, epoch=0x05, tail_mask=0x1):
    return ((EXEC_SPARSE_STRUCT << 23) | (SP_GROUP_1OF2 << 21) |
            ((k_adv & 0xFF) << 13) | ((tail_mask & 0xF) << 9) |
            ((1 if last else 0) << 8) | (epoch & 0xFF))


async def feed_frags(dut, nfrags, gaps, epoch=0x05):
    """Enqueue nfrags flow-control fragments (dense_k_advance=1), respecting
    wr_ready backpressure. gaps = {frag_idx: idle cycles BEFORE that enqueue} —
    a gap larger than the 4-deep ingress queue guarantees a real consumption
    stall (verified via sparse_stall_cnt, not assumed)."""
    await FallingEdge(dut.clk)
    for i in range(nfrags):
        for _ in range(gaps.get(i, 0)):
            await FallingEdge(dut.clk)
        dut.sparse_frag_valid.value = 1
        dut.sparse_frag_bits.value = frag_bits(last=(i == nfrags - 1), epoch=epoch)
        while not int(dut.sparse_frag_ready.value):
            await FallingEdge(dut.clk)
        await RisingEdge(dut.clk)          # transfer completes on this edge
        await FallingEdge(dut.clk)
        dut.sparse_frag_valid.value = 0


async def run_sparse_tile(dut, K, gaps, WGT, ACT, epoch=0x05, timeout=2500):
    """Program + start one OS BF16 EXEC_SPARSE_STRUCT tile, feed K fragments with
    the given stall schedule, wait for capture. Returns (snap, stall_delta)."""
    stall0 = int(dut.sparse_stall_cnt.value)
    await mmio(dut, [
        (A_CTRL,    MODE_BF16 << 4),           # mode=BF16, dataflow_sel=0 (OS)
        (A_KTOTAL,  K),
        (A_SPARSE,  EXEC_SPARSE_STRUCT),       # 0x08[1:0] = structured sparse
        (A_OUTCTRL, 0x00),
        (A_EPOCH,   epoch),
        (A_WGT,     WGT),
        (A_ACT,     ACT),
        (A_SCL,     0),
        (A_RES,     0x200),
        (A_CTRL,    (MODE_BF16 << 4) | 1),     # start pulse (also flushes queue)
    ])
    feeder = cocotb.start_soon(feed_frags(dut, K, gaps, epoch))
    snap = None
    for _ in range(timeout):
        await FallingEdge(dut.clk)
        if int(dut.tu_capture_done.value) == 1:
            await FallingEdge(dut.clk)
            snap = int(dut.snap_flat.value)
            break
    assert snap is not None, "sparse tile did not capture (timeout)"
    assert feeder.done(), "fragment feeder still pending after capture"
    return snap, int(dut.sparse_stall_cnt.value) - stall0


def check_snapshot(snap_int, C_golden):
    bad = []
    for r in range(ROWS):
        for c in range(COLS):
            d = g.decode_fp_acc_out(snap_cell(snap_int, r, c), MODE_BF16)
            if d["is_nan"] or d["is_inf"] or abs(d["value"] - C_golden[r][c]) > 1e-6:
                bad.append((r, c, d["value"], C_golden[r][c]))
    return bad


def got_matrix(snap_int):
    return [[g.decode_fp_acc_out(snap_cell(snap_int, r, c), MODE_BF16)["value"]
             for c in range(COLS)] for r in range(ROWS)]


def dropped_row_hypothesis(A, B, got, exp, K):
    """Exact solve of exp - got == sum_{k in S} outer_k(A,B) for S ⊆ {0..K-1}:
    least-squares on the 0/1 indicator (normal equations + Gaussian elimination),
    rounded and then verified EXACTLY. Returns (S, verified). Diagnostic only —
    identifies which operand rows were replaced by zero (the in_range_d
    stall-resume mask defect)."""
    R = [[exp[r][c] - got[r][c] for c in range(COLS)] for r in range(ROWS)]
    for r in range(ROWS):
        for c in range(COLS):
            if abs(R[r][c] - round(R[r][c])) > 1e-6:
                return None, False
            R[r][c] = int(round(R[r][c]))
    outer = [[[A[r][k] * B[k][c] for c in range(COLS)] for r in range(ROWS)]
             for k in range(K)]
    # normal equations G x = y over the K-dim 0/1 indicator
    G = [[sum(outer[i][r][c] * outer[j][r][c] for r in range(ROWS) for c in range(COLS))
          for j in range(K)] for i in range(K)]
    y = [sum(outer[i][r][c] * R[r][c] for r in range(ROWS) for c in range(COLS))
         for i in range(K)]
    M = [[float(G[i][j]) for j in range(K)] + [float(y[i])] for i in range(K)]
    for col in range(K):                      # partial-pivot Gaussian elimination
        piv = max(range(col, K), key=lambda i: abs(M[i][col]))
        if abs(M[piv][col]) < 1e-9:
            return None, False                # singular (duplicate outer products)
        M[col], M[piv] = M[piv], M[col]
        for i in range(K):
            if i != col and M[i][col] != 0.0:
                f = M[i][col] / M[col][col]
                for j in range(col, K + 1):
                    M[i][j] -= f * M[col][j]
    x = [M[i][K] / M[i][i] for i in range(K)]
    if any(min(abs(v), abs(v - 1.0)) > 0.25 for v in x):
        return None, False                    # not a 0/1 drop pattern
    S = [k for k in range(K) if x[k] > 0.5]
    verified = all(R[r][c] == sum(outer[k][r][c] for k in S)
                   for r in range(ROWS) for c in range(COLS))
    return sorted(S), verified


def fail_msg(tag, bad, A, B, got, exp, K, stall):
    S, exact = dropped_row_hypothesis(A, B, got, exp, K)
    hyp = ("mismatch EXACTLY equals golden minus operand rows k=%s "
           "(dropped-row signature)" % S) if exact else \
          ("mismatch does NOT reduce to a dropped-row set (solver: %s) — "
           "re-add or other corruption in play" % (S,))
    head = "\n  ".join("cell(%2d,%2d): got %.4f  expected %.4f"
                       % (r, c, gv, ev) for (r, c, gv, ev) in bad[:12])
    return ("%s: %d/256 cells != golden after %d real stall cycles.\n  DIAG: %s\n  %s%s"
            % (tag, len(bad), stall, hyp, head, "\n  ..." if len(bad) > 12 else ""))


# ── operand set (same style as test_tensor_gemm_core: BF16-exact small ints) ──

# (K, seed_r, seed_c) -> (saltA, saltB)，由 tb/salt_search.py 搜出。
# 判据：assert_dealiased(A,B,C) 全过 且 assert_no_zero_cells(C) 全过；
# 同 K 的不同 seed 金标必须互异。新增 (K,seed) 组合必须重跑搜索后登记在此。
_SALTS = {
    (24, 1, 3): (37, 15),
    (20, 1, 3): (30, 141),
    (20, 2, 1): (32, 211),
}


def make_operands(K, seed_r=1, seed_c=3):
    # 🔴 批 4a 去混叠: 旧的 ((r + seed_r*2k) % 7) / ((seed_c*k + c) % 5) 让 A 的行向量
    # 以 7、B 的列向量以 5 为周期 —— r↔r±7 / c↔c±5 的 D 错接对金标不可见。改无周期
    # 散列构造, 值域不变 (A∈[-3,3], B∈[-2,2]); seed 对映射成 salt 保持两组激励互异。
    # 🔴 批 5: 旧式 salt = seed_r*16+seed_c 把 A/B 绑成同一个 salt，且从未被
    # 「零 cell = 0」筛过 —— 实测 K=24 seed(1,3) 有 12 个、K=20 seed(1,3) 有 14 个、
    # K=20 seed(2,1) 有 5 个零 cell。改为按 (K, seed) 查表，salt 由 tb/salt_search.py
    # 搜出（两条闸全过 + 同 K 的两组 seed 金标互异，保持"两组激励互异"的原意）。
    key = (K, seed_r, seed_c)
    if key not in _SALTS:
        raise AssertionError(
            "sparse_stall: (K=%d, seed=(%d,%d)) 无预搜 salt —— 新增用例必须先跑 "
            "tb/salt_search.py 取零 cell=0 的解，禁止沿用旧公式（fail-open 第 5 员）"
            % key)
    sa, sb = _SALTS[key]
    A = go.make_A(K, ROWS, salt=sa)
    B = go.make_B(K, COLS, salt=sb)
    C_chk = g.gemm_bf16_golden(A, B)
    tag = "sparse_stall/K%d/seed(%d,%d)" % (K, seed_r, seed_c)
    go.assert_dealiased(A, B, C_chk, tag=tag)
    go.assert_no_zero_cells(C_chk, tag=tag)
    return A, B


async def load_operands(dut, A, B, K, wgt_base, act_base, pad=36):
    for k in range(K):
        await dma_row(dut, "wgt", wgt_base + k, pack_row([B[k][c] for c in range(COLS)]))
        await dma_row(dut, "act", act_base + k, pack_row([A[r][k] for r in range(ROWS)]))
    for j in range(pad):   # nonzero garbage beyond K — zero-pad window must ignore it
        await dma_row(dut, "wgt", wgt_base + K + j,
                      pack_row([(((K + j) * 2 + c) % 11) - 5 for c in range(COLS)]))
        await dma_row(dut, "act", act_base + K + j,
                      pack_row([(((K + j) * 3 + r) % 11) - 5 for r in range(ROWS)]))
    await FallingEdge(dut.clk)


# ══ test 1 — control: sparse mode, NO stalls → must equal dense golden ═══════

@cocotb.test()
async def test_sparse_nostall_control(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    K = 24
    A, B = make_operands(K)
    golden = g.gemm_bf16_golden(A, B)
    await load_operands(dut, A, B, K, 0x020, 0x100)

    t0 = get_sim_time("ns")
    snap, stall = await run_sparse_tile(dut, K, gaps={}, WGT=0x020, ACT=0x100)
    t1 = get_sim_time("ns")
    dut._log.info("sparse no-stall control: stall cycles = %d" % stall)

    bad = check_snapshot(snap, golden)
    if bad:
        raise AssertionError(fail_msg("SPARSE-NOSTALL (control)", bad, A, B,
                                      got_matrix(snap), golden, K, stall))
    dut._log.info("sparse no-stall control: 256/256 == dense golden (K=%d)" % K)

    # [3a-1 2026-08-02] 原有 r1_archive 位样本记录已随本文件 pending 一并摘除
    # （与 tb/snap_baseline.py 的 EXPECTED_CASES["r1_archive"] 成对；.snap 保留原地作历史证据）。


# ══ test 2 — frag stalls injected mid-tile → still must equal dense golden ═══

@cocotb.test()
async def test_sparse_stall_single_tile(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    K = 24
    GAPS = {5: 6, 9: 3, 14: 7, 20: 2, 23: 5}   # idle enqueue cycles before frag i
    A, B = make_operands(K)
    golden = g.gemm_bf16_golden(A, B)
    await load_operands(dut, A, B, K, 0x020, 0x100)

    snap, stall = await run_sparse_tile(dut, K, gaps=GAPS, WGT=0x020, ACT=0x100)
    assert stall > 0, ("stall schedule produced ZERO real consumption stalls — "
                       "test is vacuous, enlarge the gaps")
    dut._log.info("sparse stalled tile: %d real stall cycles" % stall)

    bad = check_snapshot(snap, golden)
    if bad:
        raise AssertionError(fail_msg("SPARSE-STALL", bad, A, B,
                                      got_matrix(snap), golden, K, stall))
    dut._log.info("sparse stalled tile: 256/256 == dense golden despite %d stall "
                  "cycles (K=%d)" % (stall, K))


# ══ test 3 — back-to-back two stalled sparse tiles, NO reset between ═════════

@cocotb.test()
async def test_sparse_stall_back_to_back(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    K = 20
    GAPS_A = {4: 5, 11: 8, 16: 3}
    GAPS_B = {2: 6, 8: 4, 15: 9, 19: 5}
    A1, B1 = make_operands(K, seed_r=1, seed_c=3)
    A2, B2 = make_operands(K, seed_r=2, seed_c=1)
    G1 = g.gemm_bf16_golden(A1, B1)
    G2 = g.gemm_bf16_golden(A2, B2)
    await load_operands(dut, A1, B1, K, 0x020, 0x100)
    await load_operands(dut, A2, B2, K, 0x300, 0x400)

    snapA, stallA = await run_sparse_tile(dut, K, gaps=GAPS_A, WGT=0x020, ACT=0x100)
    snapB, stallB = await run_sparse_tile(dut, K, gaps=GAPS_B, WGT=0x300, ACT=0x400)
    assert stallA > 0 and stallB > 0, \
        "a tile saw zero real stalls (A=%d B=%d) — vacuous" % (stallA, stallB)
    dut._log.info("b2b sparse: tile A %d / tile B %d stall cycles" % (stallA, stallB))

    badA = check_snapshot(snapA, G1)
    badB = check_snapshot(snapB, G2)
    msgs = []
    if badA:
        msgs.append(fail_msg("B2B tile A", badA, A1, B1, got_matrix(snapA), G1, K, stallA))
    if badB:
        msgs.append(fail_msg("B2B tile B", badB, A2, B2, got_matrix(snapB), G2, K, stallB))
    if msgs:
        raise AssertionError("\n".join(msgs))
    dut._log.info("b2b sparse stalled tiles: both 256/256 == golden (K=%d)" % K)


# ---------------------------------------------------------------------------
# 4. [K1a-pre0 2026-07-26] MX x sparse scale-tick invariant (pre-issue window).
#
#    mx_scale_tick's spec: fire on ISSUE beats only (cursor==0 first-block
#    prefetch / MX-block-boundary crossing). Found by the K1a adversarial
#    preflight (wf_cd90d3df): tensor_tile_controller.sv Section 7 has NO issue
#    qualification, so an MXFP4 sparse tile stalled at COMPUTE entry
#    (fragment queue dry, cursor==0) re-fires the tick EVERY stall beat ->
#    scale_offset_q runs away -> block-scale stream permanently misaligned.
#    This probe never issues a fragment at all: the tile sits stalled in
#    ST_COMPUTE for a fixed window and the tick count must stay 0 (the first
#    legal tick coincides with the first issue beat, which never comes).
#    RED on the unqualified RTL (delta ~= stall beats). Deliberately the LAST
#    test in the file: the tile is left mid-flight (no capture) by design.
# ---------------------------------------------------------------------------
MODE_MXFP4 = 5


@cocotb.test()
async def test_mx_sparse_scale_tick_invariant(dut):
    """MXFP4 sparse tile stalled at entry: mx_scale_tick must NOT fire."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    K = 8
    await mmio(dut, [
        (A_CTRL,    MODE_MXFP4 << 4),          # mode=MXFP4, dataflow_sel=0 (OS)
        (A_KTOTAL,  K),
        (A_SPARSE,  EXEC_SPARSE_STRUCT),
        (A_OUTCTRL, 0x00),
        (A_EPOCH,   0x05),
        (A_WGT,     0x020),
        (A_ACT,     0x100),
        (A_SCL,     0),
        (A_RES,     0x200),
        (A_CTRL,    (MODE_MXFP4 << 4) | 1),    # start pulse
    ])
    # no fragments fed: the sparse tile enters ST_COMPUTE and stalls at
    # cursor==0. Window > LOAD_WEIGHT(16)+CLEAR_ACC so real stall beats occur.
    tick0 = int(dut.mx_tick_cnt.value)
    stall0 = int(dut.sparse_stall_cnt.value)
    for _ in range(60):
        await FallingEdge(dut.clk)
    stall_delta = int(dut.sparse_stall_cnt.value) - stall0
    tick_delta = int(dut.mx_tick_cnt.value) - tick0
    dut._log.info("[mx-tick] pre-issue stall window: stalls=%d mx_scale_ticks=%d "
                  "(invariant expects 0)" % (stall_delta, tick_delta))
    assert stall_delta > 0, "no real stall observed - vacuous window"
    assert tick_delta == 0, \
        "mx_scale_tick fired %d times during a pre-issue sparse stall " \
        "(unqualified cursor==0 arm: scale stream misalignment bug)" % tick_delta

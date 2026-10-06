"""_r1_preproof.py —— 一次性红绿自证载体（3a 步骤 0，2026-08-02）。

## 它证明什么

判据文件 `Review/R1_Baseline_Criteria_2026-08-02.md §4` 要求在采基线之前先修三处
**自包含性缺陷**，而「修完之后位样本还是原来那个」这件事不许推定，必须实测：

| 改动 | 改前 | 改后 |
|---|---|---|
| 各 tile 自写 PAD 垃圾行 | b2b **一行 PAD 都不写** ⇒ 尾窗吃 `test_tensor_gemm_core` 留在 mem 里的残值 | 每 tile 写自己的 K..K+35 |
| b2b tileB 基址 | `0x300/0x400`，**双双越 `SRAM_DEPTH=512` 界**（靠 Verilator 索引截断才能跑） | `0x0C8`（界内、与 tileA 不相交） |
| 垃圾值域 | `((k*3+r)%11)-5` **含 0**（0 会被 `mac_zero_detect` 的 skip_accumulation 吃掉） | `[-5,-1] ∪ [1,5]` |

本模块用**改造前**的激励跑同一条采样锚，记进 `r1_preproof` 组；
`aichip_run_logs/r1_baseline_capture_20260802.sh` 随后比对
`r1_preproof/*.snap` 与 `r1_dense/*.snap` 的 `#FLAT_SHA256`：

* **逐位相同** ⇒ 三处改动对 dense 位样本无影响，基线可采（预期结果，`os_zero_pad` 掩住尾窗）；
* **不同** ⇒ 今天的尾窗掩蔽就有洞 —— 比 R1 更早的红，**停机报用户**。

## 纪律

- 文件名以 `_` 开头 ⇒ **不匹配 `run_all.py:20` 的 `test_*.py` glob**，不进门禁计数。
- 只从 `test_tensor_gemm_core` 导入辅助件（reset/mmio/dma_row/pack_row/_capture/
  _program_and_run/_meta），使**唯一变量**就是上表那三处激励差异。
- **保留不删**（原计划「用完即删」已推翻）：删了这份，自包含性自证就只剩一句结论、
  无法复现。它不进门禁计数、不进 elaborate 清单、编译复用 `tb_tensor_gemm_core` 顶层，
  留存成本 ≈ 0；复现命令见本文件末的 `Run:` 行。
  实测结论（2026-08-02，`aichip_run_logs/r1_baseline_capture_20260802.txt` 阶段 3）：
  三个共有 case 的位样本与 cadence **改前 == 改后逐位相同**
  （k24 cadence=78 / b2b tileA=74 / tileB=74）⇒ 今天的 `os_zero_pad` 尾窗掩蔽是密的。

Run: cd tb && make MODULE=_r1_preproof TOPLEVEL=tb_tensor_gemm_core \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_core.sv"
"""
import sys, os
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g
import gemm_operands as go
import snap_baseline as sb
import test_tensor_gemm_core as T   # 只借辅助件，其 @cocotb.test 不会被本 MODULE 收集

ROWS = COLS = 16
PAD = 36


# ── 改造【前】的垃圾行构造（值域含 0）───────────────────────────────────────
def old_garb_wgt(k):
    return T.pack_row([((k * 2 + c) % 11) - 5 for c in range(COLS)])


def old_garb_act(k):
    return T.pack_row([((k * 3 + r) % 11) - 5 for r in range(ROWS)])


async def old_load_with_pad(dut, A, B, K, wgt_base, act_base):
    """改造前 test_tensor_gemm_core 的装载顺序（含它自己的 PAD）。"""
    for k in range(K):
        await T.dma_row(dut, "wgt", wgt_base + k, T.pack_row([B[k][c] for c in range(COLS)]))
    for k in range(K):
        await T.dma_row(dut, "act", act_base + k, T.pack_row([A[r][k] for r in range(ROWS)]))
    for k in range(K, K + PAD):
        await T.dma_row(dut, "wgt", wgt_base + k, old_garb_wgt(k))
        await T.dma_row(dut, "act", act_base + k, old_garb_act(k))
    await FallingEdge(dut.clk)


async def old_load_no_pad(dut, A, B, K, wgt_base, act_base):
    """改造前 b2b 的装载：**零 PAD**（尾窗吃残值）。"""
    for k in range(K):
        await T.dma_row(dut, "wgt", wgt_base + k, T.pack_row([B[k][c] for c in range(COLS)]))
        await T.dma_row(dut, "act", act_base + k, T.pack_row([A[r][k] for r in range(ROWS)]))
    await FallingEdge(dut.clk)


@cocotb.test()
async def preproof_gemm_core(dut):
    """改造前的 K=24 主用例（定义序 1 —— 必须与改造后同序，b2b 的残值来源就是它）。"""
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)

    K = 24
    EPOCH, WGT, ACT, RES = 0x05, 0x020, 0x100, 0x200
    A = go.make_A(K, ROWS, salt=24)
    B = go.make_B(K, COLS, salt=50)
    C = g.gemm_bf16_golden(A, B)
    go.assert_dealiased(A, B, C, tag="preproof/gemm_core")
    go.assert_no_zero_cells(C, tag="preproof/gemm_core")

    await old_load_with_pad(dut, A, B, K, WGT, ACT)
    dut.egress_ready.value = 1
    snap, snap_re, cyc = await T._program_and_run(dut, K, EPOCH, WGT, ACT, RES)
    assert snap is not None, "preproof gemm_core: tile did not complete"
    bad = T._check_snapshot(snap, C)
    assert not bad, "preproof gemm_core: %d/256 != golden: %s" % (len(bad), bad[:8])

    sb.record("r1_preproof", "gemm_core_k24", snap,
              T._meta("preproof_gemm_core", 1, cyc, K, 24, 50, EPOCH, WGT, ACT, RES, C),
              snap_int_recheck=snap_re, log=dut._log)


@cocotb.test()
async def preproof_b2b(dut):
    """改造前的 b2b：零 PAD + tileB 越界基址 0x300/0x400。"""
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)
    dut.egress_ready.value = 1

    K = 20
    EPOCH, RES = 0x05, 0x200
    WA, AA, WB, AB = 0x020, 0x100, 0x300, 0x400     # 原值（WB/AB 越 SRAM_DEPTH=512 界）

    A1 = go.make_A(K, ROWS, salt=5);   B1 = go.make_B(K, COLS, salt=41)
    A2 = go.make_A(K, ROWS, salt=19);  B2 = go.make_B(K, COLS, salt=127)
    G1 = g.gemm_bf16_golden(A1, B1);   G2 = g.gemm_bf16_golden(A2, B2)
    for (A_, B_, C_, t) in ((A1, B1, G1, "preproof/b2b/A"), (A2, B2, G2, "preproof/b2b/B")):
        go.assert_dealiased(A_, B_, C_, tag=t)
        go.assert_no_zero_cells(C_, tag=t)
    assert G1 != G2

    # 改造前的交错装载顺序（逐 k 四写），零 PAD
    for k in range(K):
        await T.dma_row(dut, "wgt", WA + k, T.pack_row([B1[k][c] for c in range(COLS)]))
        await T.dma_row(dut, "act", AA + k, T.pack_row([A1[r][k] for r in range(ROWS)]))
        await T.dma_row(dut, "wgt", WB + k, T.pack_row([B2[k][c] for c in range(COLS)]))
        await T.dma_row(dut, "act", AB + k, T.pack_row([A2[r][k] for r in range(ROWS)]))
    await FallingEdge(dut.clk)

    snapA, snapA_re, cycA = await T._program_and_run(dut, K, EPOCH, WA, AA, RES)
    snapB, snapB_re, cycB = await T._program_and_run(dut, K, EPOCH, WB, AB, RES)
    assert snapA is not None and snapB is not None, "preproof b2b: tile did not capture"
    assert not T._check_snapshot(snapA, G1), "preproof b2b tileA != golden"
    assert not T._check_snapshot(snapB, G2), "preproof b2b tileB != golden"

    sb.record("r1_preproof", "gemm_core_b2b_k20_tileA", snapA,
              T._meta("preproof_b2b", 2, cycA, K, 5, 41, EPOCH, WA, AA, RES, G1),
              snap_int_recheck=snapA_re, log=dut._log)
    sb.record("r1_preproof", "gemm_core_b2b_k20_tileB", snapB,
              T._meta("preproof_b2b", 2, cycB, K, 19, 127, EPOCH, WB, AB, RES, G2),
              snap_int_recheck=snapB_re, log=dut._log)

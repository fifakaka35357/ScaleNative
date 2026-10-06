"""
Array-level SCU integration probe — does enabling `sparse_compress_en` (MMIO 0x08
bit4) preserve GEMM correctness?  (P2/M1 "先测后定" decision data, 2026-07-23.)

Context
-------
The SCU (test_scu_compress.py) faithfully LEFT-COMPACTS non-zero packs and emits
`idx_out` = each survivor's ORIGINAL position. But in tensor_mac_array.sv the array
consumes the compacted data BY POSITION and never reads `idx_out`/`nnz_count`:

    tensor_mac_array.sv:708  wgt_pre_skew[c] = (... sparse_compress_en ...)
                                              ? weight_compressed[c]   // survivor c
                                              : weight_in_eff[c];      // original c
    (weight_idx / weight_nnz declared at :371-372, connected at :585/:587, NEVER read)

In an output-stationary systolic array B[k][c] must meet A[r][k] at cell (r,c) on
cycle k+r+c+1. Left-compacting operands without scattering them back via `idx`
therefore routes survivors into the WRONG rows/columns whenever a tile has interior
operand zeros → a wrong matrix product. Today this is masked only because nothing
in the 124-case suite ever sets the bit (reset value 0).

Resolution (decision A, 2026-07-23): the `scu_en` bit (MMIO 0x08 [4]) is now
RESERVED and tied 0 at the descriptor (tensor_external_modules.sv desc_out), so
firmware can never trip the defect. This file is the GUARD that the tie-off holds.

What this file measures
-----------------------
Same real tensor_unit_top / same OS BF16 tile as test_tensor_gemm_core, on operands
that contain deliberate INTERIOR zeros:
  * test_scu_tile_control      — write 0x08=0x00 → snapshot MUST equal the dense
                                 golden (baseline; tile & bench are sound).
  * test_scu_tile_bit_reserved — write 0x08=0x10 (would set scu_en if it were live)
                                 → snapshot MUST STILL equal the dense golden,
                                 because the bit is tied off. If this ever diverges,
                                 someone un-tied scu_en without making the array
                                 consume idx_out/nnz_count — the 253/256-cell defect
                                 is back. SMODE is hardwired ADAPTIVE
                                 (tensor_unit_top.sv:708); 0x10 sets bit4 only.

Red/green proof of the guard (HISTORICAL, 2026-07-23): restoring `reg_sparse_compress_en`
+ desc_out wiring made this test go RED at 253/256 — the measurement that justified
the tie-off. [C1 2026-07-31] SCU RTL has since been DELETED (D-SPARSE-NM-2026-07-31),
so that red arm is no longer constructible; this test is hereby re-judged as the
**CSR reserved-bit write-inertness guard** for MMIO 0x08 bit4 (writing bit4 must
remain a no-op forever — the bit stays RESERVED per D-SCU-RESERVED).

Run: cd tb && make MODULE=test_scu_tile TOPLEVEL=tb_tensor_gemm_core \
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
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g
import gemm_operands as go   # 批 4a: 去混叠激励 + 硬闸（见该模块头注）
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from cocotb.utils import get_sim_time
import snap_baseline as sb   # [3a 步骤 0] 位样本存档组（默认 no-op）

A_CTRL, A_KTOTAL, A_SPARSE, A_OUTCTRL, A_EPOCH = 0x00, 0x04, 0x08, 0x0C, 0x10
A_WGT, A_ACT, A_SCL, A_RES = 0x14, 0x18, 0x1C, 0x20
MODE_BF16 = 4
ROWS = COLS = 16


def _record_archive(dut, case, tb, deforder, snap, snap2, cyc, C_golden, sparse_wr):
    """[3a 步骤 0] 记进 `r1_archive` 组 —— **不进 R1 判据**，只作存档。

    存档理由：本文件是全仓唯一在 dense 路径上写 MMIO 0x08 的用例，而规格 §5.2 正要把
    0x08 重定义为 [1:0]=exec / [3:2]=n_cfg（bit4 仍 RESERVED）⇒ 改造前后的位样本对照
    是「0x08 语义改动没有碰坏 dense」的直接证据。退役条件见判据文件 §2.3。

    ▲[3a-3 2026-08-04] §5.2 已落地，§2.3 的「随 §5.2 落地重判」在此兑现
      （重判全文 = R1_Baseline_Criteria §2.3b）。**结论 = 两 case 全部留任**，
      退役条件改为「随 3a-7 的 is_valid_descriptor 保留值处置重判」。
      0x08 写口今日真值 = [1:0] exec(exec_sparse_mode_e) / [3:2] n_cfg(ncfg_e) /
      [4] scu_en(RESERVED, tied-0) / [31:5] 未解码。
      · 本文件写的两个值 0x00 与 0x10 的 [3:2] **都是 2'b00 = NCFG_DENSE**
        ⇒ 激励值、断言、位样本一律**不改**。
      · test_scu_tile_bit_reserved 因此获得一个新职能：它同时是
        「写 bit4 不会溅到 n_cfg」的位级对照 —— 若 n_cfg 被错放到 bit4 及以上，
        本 case 的语义会变成「写了稀疏配置却断言 dense 结果」而**当天两闸仍全绿**
        （要到 3a-4 接上数据通路才炸）⇒ 本 case 是 HANDOFF C2 的执行件。
    🔴 该组不做跨 case 互异自证：control 与 bit_reserved 按 `D-SCU-RESERVED` 的守门语义
    **必须**逐位相同（那正是这条守门要证明的事）。
    """
    sb.record("r1_archive", case, snap, {
        "tb": "test_scu_tile.py::" + tb,
        "deforder": deforder,
        "anchor": "tu_capture_done_high+1FallingEdge(recheck+2)",
        "cycles": cyc,
        "param": "K=%d saltA=49 saltB=26 zero_sprinkled=1 mmio0x08=0x%02x "
                 "PAD=0 EPOCH=0x05 WGT=0x020 ACT=0x100 RES=0x200" % (K, sparse_wr),
        "sramspan": "wgt=0x020..0x%03x act=0x100..0x%03x" % (0x020 + K - 1, 0x100 + K - 1),
        "distinct_golden": len({v for row in C_golden for v in row}),
    }, snap_int_recheck=snap2, log=dut._log)


async def reset(dut):
    for s in ("mmio_wr_valid", "mmio_wr_addr", "mmio_wr_data", "mmio_rd_addr",
              "dma_wgt_en", "dma_act_en", "dma_scale_en", "dma_addr",
              "dma_data", "dma_scl_wgt", "dma_scl_act", "egress_ready"):
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
    dut.dma_addr.value = addr
    dut.dma_data.value = data256
    await RisingEdge(dut.clk)
    dut.dma_wgt_en.value = 0
    dut.dma_act_en.value = 0


def pack_row(vals):
    w = 0
    for i, v in enumerate(vals):
        w |= (g.bf16_bits(float(v)) & 0xFFFF) << (i * 16)
    return w


def snap_cell(snap_int, r, c):
    return (snap_int >> ((r * COLS + c) * 61)) & ((1 << 61) - 1)


# Operands WITH interior zeros (so adaptive compaction actually shifts positions).
K = 24


def make_operands():
    # 🔴 批 4a 去混叠 (值域不变 A∈[-3,3]/B∈[-2,2]; 下面的"撒零"逻辑原样保留 ——
    # 它是本测试的目的所在, 去混叠只换底纹不换零位策略)。
    # 🔴 批 5: salt 3/3 有 6 个零 cell（2 个在 SE）。改 (49,26) —— salt_search.py
    # 在【撒零后】的金标上搜出的解，零 cell = 0。
    A = go.make_A(K, ROWS, salt=49)
    B = go.make_B(K, COLS, salt=26)
    # sprinkle interior zeros: whole act rows and weight cols at several k
    for k in range(K):
        if k % 4 == 1:                       # zero out lane 5 of act at these k
            for r in range(ROWS):
                if r in (5, 6, 11):
                    A[r][k] = 0
        if k % 3 == 0:                       # zero out a few weight cols
            for c in (2, 9, 14):
                B[k][c] = 0
    # 撒零之后才判去混叠 —— 撒零本身可能重新造出重复行/列
    # 🔴 批 5: 补 assert_no_zero_cells（撒零后的金标）—— 此前只判去混叠，
    # 零 cell 完全无人看守。金标必须在这里算（撒零已生效）。
    C_chk = g.gemm_bf16_golden(A, B)
    go.assert_dealiased(A, B, C_chk, tag="scu_tile")
    go.assert_no_zero_cells(C_chk, tag="scu_tile")
    return A, B


async def _run_tile(dut, compress_en):
    await reset(dut)
    dut.egress_ready.value = 1
    A, B = make_operands()
    C_golden = g.gemm_bf16_golden(A, B)
    WGT_BASE, ACT_BASE, RES_BASE, EPOCH = 0x020, 0x100, 0x200, 0x05
    for k in range(K):
        await dma_row(dut, "wgt", WGT_BASE + k, pack_row([B[k][c] for c in range(COLS)]))
        await dma_row(dut, "act", ACT_BASE + k, pack_row([A[r][k] for r in range(ROWS)]))
    await FallingEdge(dut.clk)

    seq = [
        (A_CTRL,    MODE_BF16 << 4),
        (A_KTOTAL,  K),
        (A_SPARSE,  0x10 if compress_en else 0x00),   # bit4 = sparse_compress_en
        (A_OUTCTRL, 0x00),
        (A_EPOCH,   EPOCH),
        (A_WGT,     WGT_BASE),
        (A_ACT,     ACT_BASE),
        (A_SCL,     0),
        (A_RES,     RES_BASE),
        (A_CTRL,    (MODE_BF16 << 4) | 1),            # start pulse, LAST
    ]
    await mmio(dut, seq)
    t0 = get_sim_time("ns")
    for _ in range(700):
        await FallingEdge(dut.clk)
        if int(dut.tu_capture_done.value) == 1:
            t1 = get_sim_time("ns")
            await FallingEdge(dut.clk)
            snap = int(dut.snap_flat.value)
            for _ in range(2):                       # [3a 步骤 0] 窗内二次采样自证
                await FallingEdge(dut.clk)
            snap2 = int(dut.snap_flat.value)
            bad = []
            for r in range(ROWS):
                for c in range(COLS):
                    d = g.decode_fp_acc_out(snap_cell(snap, r, c), MODE_BF16)
                    if d["is_nan"] or d["is_inf"] or abs(d["value"] - C_golden[r][c]) > 1e-6:
                        bad.append((r, c, d["value"], C_golden[r][c]))
            return bad, snap, snap2, int(round((t1 - t0) / 10.0)), C_golden
    return None, None, None, None, C_golden


@cocotb.test()
async def test_scu_tile_control(dut):
    """compress_en=0 on a zero-sprinkled tile: array must compute the exact dense GEMM."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    bad, snap, snap2, cyc, C = await _run_tile(dut, compress_en=0)
    assert bad is not None, "control tile never captured"
    assert not bad, ("control (compress_en=0) diverged from golden in %d/256 cells — "
                     "the bench/tile is unsound, fix before trusting the compress probe: %s"
                     % (len(bad), bad[:8]))
    dut._log.info("SCU tile control: compress_en=0 == dense golden (256/256) on zero-sprinkled tile")
    _record_archive(dut, "scu_tile_control", "test_scu_tile_control", 1, snap, snap2, cyc, C, 0x00)


@cocotb.test()
async def test_scu_tile_bit_reserved(dut):
    """Writing 0x08 bit4 (scu_en) must be INERT — the bit is reserved/tied 0.

    Guards decision A: if this diverges, scu_en was re-enabled without teaching the
    array to consume idx_out/nnz_count, resurrecting the 253/256-cell corruption.
    """
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    bad, snap, snap2, cyc, C = await _run_tile(dut, compress_en=1)   # writes 0x08=0x10; must be ignored
    assert bad is not None, "reserved-bit tile never captured"
    dut._log.info("SCU tile reserved: writing scu_en=1 changed %d/256 cells (must be 0)"
                  % (len(bad) if bad else 0))
    assert not bad, ("writing scu_en (0x08 bit4) altered %d/256 cells — the bit is NOT "
                     "tied off; the SCU misroute defect is live again "
                     "(tensor_mac_array.sv:708 consumes compacted data by position, "
                     "idx_out/nnz_count still unconsumed): %s" % (len(bad), bad[:8]))
    _record_archive(dut, "scu_tile_bit_reserved", "test_scu_tile_bit_reserved", 2,
                    snap, snap2, cyc, C, 0x10)

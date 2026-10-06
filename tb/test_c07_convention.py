"""
cocotb regression for mac_cell — focus: C07 source rebias (frozen convention).

C07 freezes the block-float convention to value = mant * 2^exp with mant an
INTEGER (F=0). Each source must subtract its mantissa-packing fractional bits at
its output so the accumulator state obeys F=0:
    mac_lru  FP4 -> exp-6     FP8 -> exp-10
    mac_cell BF16 -> exp-14   MXINT8 -> already 0
This test drives a single MAC accumulation per mode and checks the decoded
fp_acc_out (with golden F collapsed to 0) equals the true product value. It is
the BF16 coverage that C06/D4 do not provide, and pins the FP4/FP8 rebias too.

Run: cd tb && make MODULE=test_c07_convention TOPLEVEL=mac_cell \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_lru.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_fp_acc_align.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_cell.sv"
"""
import os
import sys
import math
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

FP4, FP8, BF16 = g.MODE_FP4, g.MODE_FP8, g.MODE_BF16
LANE_MASK = {FP4: 0xF, FP8: 0x3, BF16: 0x1}


async def reset(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    for sig, val in (("rst_n", 0), ("mode", FP4), ("mac_en", 0), ("clear_acc", 0),
                     ("array_step_en", 1),   # §C6: clocks the FP feedforward stage
                     ("capture_fire", 0), ("lane_valid", 0), ("weight_in", 0),
                     ("weight_load", 0), ("weight_stream_en", 0), ("act_in", 0),
                     ("mx_scale_a_cur", 127), ("mx_scale_b_cur", 127),
                     ("psum_in", 0), ("sparsity_map_in", 0)):
        getattr(dut, sig).value = val
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_mac(dut, mode, weight, act):
    dut.mode.value = mode
    dut.weight_in.value = weight & 0xFFFF
    dut.weight_load.value = 1
    dut.clear_acc.value = 1
    dut.array_step_en.value = 0   # §C6: controller never steps during CLEAR_ACC
    dut.mac_en.value = 0
    dut.act_in.value = 0
    dut.lane_valid.value = 0
    await RisingEdge(dut.clk)

    dut.weight_load.value = 0
    dut.clear_acc.value = 0
    dut.array_step_en.value = 1
    dut.act_in.value = act & 0xFFFF
    dut.lane_valid.value = LANE_MASK[mode]
    dut.mac_en.value = 1
    await RisingEdge(dut.clk)

    dut.mac_en.value = 0
    dut.lane_valid.value = 0
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: stage → accumulator consumption edge
    await RisingEdge(dut.clk)   # settle: read the registered fp_acc_out race-free
    return int(dut.fp_acc_out.value)


def golden(mode, weight, act):
    if mode == FP4:
        a = [(weight >> (4 * i)) & 0xF for i in range(4)]
        b = [(act >> (4 * i)) & 0xF for i in range(4)]
        return g.mac_lru_golden(FP4, a, b, [0, 0], [0, 0])["value"]
    if mode == FP8:
        a = [(weight >> (8 * i)) & 0xFF for i in range(2)]
        b = [(act >> (8 * i)) & 0xFF for i in range(2)]
        return g.mac_lru_golden(FP8, [0]*4, [0]*4, a, b)["value"]
    return g.bf16_decode(weight) * g.bf16_decode(act)   # BF16


# (label, mode, weight, act)
# FP4: 1.0=0x2 1.5=0x3 0.5sub=0x1 2.0=0x4   FP8 E4M3: 1.0=0x38
# BF16: 1.0=0x3F80 1.5=0x3FC0 2.0=0x4000 3.0=0x4040 -1.5=0xBFC0
CASES = [
    ("FP4  1.0*1.0 → 1.0",   FP4,  0x0002, 0x0002),
    ("FP4  dot=5.0",         FP4,  0x4132, 0x2222),
    ("FP4  0.5sub*1.5",      FP4,  0x0001, 0x0003),
    ("FP8  1.0*1.0 → 1.0",   FP8,  0x0038, 0x0038),
    ("FP8  dot=2.0",         FP8,  0x3838, 0x3838),
    ("BF16 1.0*1.5 → 1.5",   BF16, 0x3F80, 0x3FC0),
    ("BF16 1.5*1.5 → 2.25",  BF16, 0x3FC0, 0x3FC0),   # product-overflow path
    ("BF16 1.0*-1.5 → -1.5", BF16, 0x3F80, 0xBFC0),
    ("BF16 2.0*3.0 → 6.0",   BF16, 0x4000, 0x4040),
    # =========================================================================
    # 🔴 2026-08-14 新增：**LRU 臂的负尾数向量**（红臂）
    #
    # **为什么**：Step 3 发刀前的 114-agent 审查（F3）逐条清点全仓，发现
    #   走 LRU 臂（FP4/FP8/MXFP4/MXFP8）的测试向量**全部是非负数** ——
    #   全表唯一的负值 `0xBFC0` 走的是 **BF16 臂**。加上 `tb/Makefile` 与
    #   `elaborate_smoke.sh` 都带 `-Wno-WIDTHEXPAND`，
    #   ⇒ 「`lru_result_t.mant`(15b) → 16b 时写成**零扩展**而不是符号扩展」这个错法，
    #     **全仓 190 个 cocotb test 一个都不会红**（LRU 臂的每个负乘积会变成 +32768 附近的大正数，
    #     而 BF16/MXINT8 完全正常）。这是候选刀 **K1c-A**（合并 c6 秩三个寄存器）
    #     最可能的实现错误，却处在守门的结构性盲区里。
    #
    # 🔴 这几条**先于任何 RTL 改动落盘**，并须在**改前的 RTL 上跑绿**
    #   —— 否则就是「为改动而写的测试」。
    #
    # 编码：FP4 = E2M1，**sign = nibble 的 bit[3]** ⇒ −1.0=0xA、−1.5=0xB
    #       FP8 = E4M3，**sign = byte 的 bit[7]** ⇒ −1.0=0xB8
    #   （四条的期望值已用金标 `mac_lru_golden` 独立复算过，见落盘记录）
    # =========================================================================
    ("FP4  -1.0*1.0 → -1.0", FP4,  0x000A, 0x0002),
    ("FP4  -1.5*1.0 → -1.5", FP4,  0x000B, 0x0002),
    ("FP4  -1.0*-1.0 → 1.0", FP4,  0x000A, 0x000A),   # 双负 → 正：抓「只翻一次符号」
    ("FP8  -1.0*1.0 → -1.0", FP8,  0x00B8, 0x0038),
    ("FP8  -1.0*-1.0 → 1.0", FP8,  0x00B8, 0x00B8),   # 同上
]


@cocotb.test()
async def test_c07_source_rebias(dut):
    """fp_acc_out must decode (F=0) to the true per-element product value."""
    await reset(dut)
    fails = []
    for label, mode, w, a in CASES:
        raw = await run_mac(dut, mode, w, a)
        rtl = g.decode_fp_acc_out(raw, mode)
        gold = golden(mode, w, a)
        ok = math.isclose(rtl["value"], gold, rel_tol=1e-9, abs_tol=1e-15)
        dut._log.info(f"{label:24s}: rtl={rtl['value']:+.6g} gold={gold:+.6g} "
                      f"{'OK' if ok else 'FAIL'}  (mant={rtl['mant']} exp={rtl['exp']} sign={rtl['sign']})")
        if not ok:
            fails.append(f"{label}: rtl={rtl['value']} gold={gold}")
    assert not fails, "C07 source-rebias mismatches:\n  " + "\n  ".join(fails)

"""
cocotb regression for tb_mac_ofu — focus: C07 end-to-end (mac_cell → OFU).

Drives a real MAC accumulation per mode and checks the Class-C escape FP output
decodes back to the true product value. This is the integration guard for C07:
it fails unless BOTH the source rebias (mac_lru/mac_cell) AND the OFU +47
normalization are correct and consistent (N10: "must change together").

Run: cd tb && make MODULE=test_mac_ofu TOPLEVEL=tb_mac_ofu \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_lru.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_fp_acc_align.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_cell.sv \
        ../rtl/Tensor/output_format_unit.sv tb_mac_ofu.sv"
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
MXFP4, MXFP8, MXINT8 = g.MODE_MXFP4, g.MODE_MXFP8, g.MODE_MXINT8
LANE_MASK = {FP4: 0xF, FP8: 0x3, BF16: 0x1, MXFP4: 0xF, MXFP8: 0x3, MXINT8: 0x1}


async def reset(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    for sig, val in (("rst_n", 0), ("mode", FP4), ("mac_en", 0), ("clear_acc", 0),
                     ("array_step_en", 1),   # §C6: clocks the FP feedforward stage
                     ("lane_valid", 0), ("weight_in", 0), ("weight_load", 0),
                     ("act_in", 0), ("mx_scale_a_cur", 127), ("mx_scale_b_cur", 127),
                     ("out_fmt", g.OUT_FMT_FP32), ("round_mode", g.OUT_ROUND_RTZ)):
        getattr(dut, sig).value = val
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run(dut, mode, weight, act, scale_a, scale_b, fmt):
    dut.mode.value = mode
    dut.weight_in.value = weight & 0xFFFF
    dut.weight_load.value = 1
    dut.clear_acc.value = 1
    dut.array_step_en.value = 0   # §C6: controller never steps during CLEAR_ACC
    dut.mac_en.value = 0
    dut.act_in.value = 0
    dut.lane_valid.value = 0
    dut.mx_scale_a_cur.value = scale_a & 0xFF
    dut.mx_scale_b_cur.value = scale_b & 0xFF
    dut.out_fmt.value = fmt
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
    await RisingEdge(dut.clk)   # settle: read the registered result race-free
    return int(dut.ofu_result.value), int(dut.ofu_valid.value)


def true_value(mode, weight, act, scale_a, scale_b):
    if mode in (FP4, FP8):
        if mode == FP4:
            a = [(weight >> (4 * i)) & 0xF for i in range(4)]
            b = [(act >> (4 * i)) & 0xF for i in range(4)]
            return g.mac_lru_golden(FP4, a, b, [0, 0], [0, 0])["value"]
        a = [(weight >> (8 * i)) & 0xFF for i in range(2)]
        b = [(act >> (8 * i)) & 0xFF for i in range(2)]
        return g.mac_lru_golden(FP8, [0]*4, [0]*4, a, b)["value"]
    if mode == BF16:
        return g.bf16_decode(weight) * g.bf16_decode(act)
    return g.mac_cell_mx_golden(mode, weight, act, scale_a, scale_b)["value"]


# (label, mode, weight, act, scale_a, scale_b, fmt)
CASES = [
    ("FP4  dot=5.0          → FP32", FP4,  0x4132, 0x2222, 127, 127, g.OUT_FMT_FP32),
    ("FP8  dot=2.0          → BF16", FP8,  0x3838, 0x3838, 127, 127, g.OUT_FMT_BF16),
    ("BF16 1.5*1.5=2.25     → FP32", BF16, 0x3FC0, 0x3FC0, 127, 127, g.OUT_FMT_FP32),
    ("BF16 2.0*3.0=6.0      → FP16", BF16, 0x4000, 0x4040, 127, 127, g.OUT_FMT_FP16),
    ("MXFP4 dot5 s=130,124  → FP32", MXFP4, 0x4132, 0x2222, 130, 124, g.OUT_FMT_FP32),
    ("MXFP8 dot2 s=129,127  → FP32", MXFP8, 0x3838, 0x3838, 129, 127, g.OUT_FMT_FP32),
    ("MXINT8 3*5 s=139,127  → FP32", MXINT8, 0x0003, 0x0005, 139, 127, g.OUT_FMT_FP32),
    ("MXINT8 -4*7 s=139,127 → BF16", MXINT8, 0x00FC, 0x0007, 139, 127, g.OUT_FMT_BF16),
]


@cocotb.test()
async def test_c07_end_to_end(dut):
    """Full block-float → Class-C escape FP must equal the true product value."""
    await reset(dut)
    fails = []
    for label, mode, w, a, sa, sb, fmt in CASES:
        res, valid = await run(dut, mode, w, a, sa, sb, fmt)
        val, is_nan, is_inf = g.decode_target_fp(res, fmt)
        expect = true_value(mode, w, a, sa, sb)
        ok = valid == 1 and not is_nan and not is_inf \
            and math.isclose(val, expect, rel_tol=1e-6, abs_tol=1e-15)
        dut._log.info(f"{label:30s}: rtl={val:+.6g} expect={expect:+.6g} "
                      f"{'OK' if ok else 'FAIL'}  (raw=0x{res:08x} valid={valid})")
        if not ok:
            fails.append(f"{label}: rtl={val} expect={expect}")
    assert not fails, "C07 end-to-end mismatches:\n  " + "\n  ".join(fails)

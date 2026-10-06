"""
cocotb regression for mac_cell — focus: E1 (NVFP4 E4M3 block scale).

An OCP-MX E8M0 scale is a pure power of two; an NVFP4 E4M3 scale also carries a
mantissa: value = (1 + m3/8) * 2^(exp-7). E1 decomposes it in the MAC cell —
exponent → mx_offset (double bias 14 + sig4 norm 6 = 20), significand product →
a correction multiplied into the LRU mantissa, renormalized into the 15-bit field
with sticky. This test drives MXFP4/MXFP8 with scale_format=SCALE_E4M3 and checks
fp_acc_out == dot * decode_E4M3(scale_a) * decode_E4M3(scale_b).

Run: cd tb && make MODULE=test_e1_e4m3 TOPLEVEL=mac_cell \
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

MXFP4, MXFP8 = g.MODE_MXFP4, g.MODE_MXFP8
LANE_MASK = {MXFP4: 0xF, MXFP8: 0x3}


async def reset(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    for sig, val in (("rst_n", 0), ("mode", MXFP4), ("mac_en", 0), ("clear_acc", 0),
                     ("array_step_en", 1),   # §C6: clocks the FP feedforward stage
                     ("capture_fire", 0), ("lane_valid", 0), ("weight_in", 0),
                     ("weight_load", 0), ("weight_stream_en", 0), ("act_in", 0),
                     ("mx_scale_a_cur", 0x38), ("mx_scale_b_cur", 0x38),
                     ("scale_format", g.SCALE_E4M3), ("psum_in", 0), ("sparsity_map_in", 0)):
        getattr(dut, sig).value = val
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_e4m3(dut, mode, weight, act, scale_a, scale_b):
    dut.mode.value = mode
    dut.scale_format.value = g.SCALE_E4M3
    dut.weight_in.value = weight & 0xFFFF
    dut.weight_load.value = 1
    dut.clear_acc.value = 1
    dut.array_step_en.value = 0   # §C6: controller never steps during CLEAR_ACC
    dut.mac_en.value = 0
    dut.act_in.value = 0
    dut.lane_valid.value = 0
    dut.mx_scale_a_cur.value = scale_a & 0xFF
    dut.mx_scale_b_cur.value = scale_b & 0xFF
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


# E4M3 scale bytes: 1.0=0x38 1.5=0x3C 2.0=0x40 0.5=0x30 1.25=0x3A
# (label, mode, weight, act, scale_a, scale_b)
CASES = [
    ("MXFP4 1.0*1.0 s=1.0,1.0   → 1.0",   MXFP4, 0x0002, 0x0002, 0x38, 0x38),
    ("MXFP4 1.0*1.0 s=1.5,1.0   → 1.5",   MXFP4, 0x0002, 0x0002, 0x3C, 0x38),
    ("MXFP4 1.0*1.0 s=1.5,1.5   → 2.25",  MXFP4, 0x0002, 0x0002, 0x3C, 0x3C),
    ("MXFP4 1.0*1.0 s=2.0,0.5   → 1.0",   MXFP4, 0x0002, 0x0002, 0x40, 0x30),
    ("MXFP4 1.0*1.0 s=0.5,0.5   → 0.25",  MXFP4, 0x0002, 0x0002, 0x30, 0x30),
    ("MXFP4 dot=5.0 s=1.5,1.5   → 11.25", MXFP4, 0x4132, 0x2222, 0x3C, 0x3C),
    ("MXFP4 dot=5.0 s=1.25,2.0  → 12.5",  MXFP4, 0x4132, 0x2222, 0x3A, 0x40),
    ("MXFP8 1.0*1.0 s=1.5,1.0   → 1.5",   MXFP8, 0x0038, 0x0038, 0x3C, 0x38),
    ("MXFP8 dot=2.0 s=1.25,1.25 → 3.125", MXFP8, 0x3838, 0x3838, 0x3A, 0x3A),
]


@cocotb.test()
async def test_e1_e4m3_block_scale(dut):
    """MXFP4/MXFP8 with E4M3 block scale: fp_acc_out == dot * E4M3(a) * E4M3(b)."""
    await reset(dut)
    fails = []
    for label, mode, w, a, sa, sb in CASES:
        raw = await run_e4m3(dut, mode, w, a, sa, sb)
        rtl = g.decode_fp_acc_out(raw, mode)
        gold = g.mac_cell_mx_golden(mode, w, a, sa, sb, scale_format=g.SCALE_E4M3)
        ok = math.isclose(rtl["value"], gold["value"], rel_tol=1e-6, abs_tol=1e-12)
        dut._log.info(f"{label:34s}: rtl={rtl['value']:+.6g} gold={gold['value']:+.6g} "
                      f"{'OK' if ok else 'FAIL'}  (mant={rtl['mant']} exp={rtl['exp']} sign={rtl['sign']})")
        if not ok:
            fails.append(f"{label}: rtl={rtl['value']} gold={gold['value']}")
    assert not fails, "E1 E4M3 block-scale mismatches:\n  " + "\n  ".join(fails)


@cocotb.test()
async def test_e1_e4m3_scale_nan(dut):
    """E4M3 scale NaN ({exp=1111,mant=111}=0x7F) must force the accumulator to NaN."""
    await reset(dut)
    raw = await run_e4m3(dut, MXFP4, 0x0002, 0x0002, 0x7F, 0x38)
    rtl = g.decode_fp_acc_out(raw, MXFP4)
    dut._log.info(f"MXFP4 E4M3 scale=0x7F NaN: is_nan={rtl['is_nan']}")
    assert rtl["is_nan"] == 1, f"E4M3 scale NaN not latched: is_nan={rtl['is_nan']}"

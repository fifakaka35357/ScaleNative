"""
cocotb regression for mac_cell — focus: C06 (MX block-scale DOUBLE bias).

mac_cell folds the two E8M0 block scales (activation + weight) into the product
exponent via mx_offset (mac_cell.sv Section 7B). Each E8M0 scale carries bias 127,
so the combined offset must subtract 254 (two biases), not 127. The pre-fix RTL
subtracts only 127 → every MX result is 2^127 too large.

This is observed end-to-end by driving a single clocked MAC accumulation (clear →
one valid cycle) and decoding the registered fp_acc_out against the golden model.

Run: cd tb && make MODULE=test_mac_cell_mx TOPLEVEL=mac_cell \
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

MXFP4  = g.MODE_MXFP4
MXFP8  = g.MODE_MXFP8
MXINT8 = g.MODE_MXINT8

# Default per-mode lane masks (tensor_pkg mode_full_lane_mask).
LANE_MASK = {MXFP4: 0xF, MXFP8: 0x3, MXINT8: 0x1}


async def reset(dut):
    """Start clock, drive all inputs to safe defaults, release reset."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst_n.value           = 0
    dut.mode.value            = MXFP4
    dut.mac_en.value          = 0
    dut.array_step_en.value   = 1   # §C6: clocks the FP feedforward stage
    dut.clear_acc.value       = 0
    dut.capture_fire.value    = 0
    dut.lane_valid.value      = 0
    dut.weight_in.value       = 0
    dut.weight_load.value     = 0
    dut.weight_stream_en.value = 0
    dut.act_in.value          = 0
    dut.mx_scale_a_cur.value  = 127
    dut.mx_scale_b_cur.value  = 127
    dut.psum_in.value         = 0
    dut.sparsity_map_in.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_mx_mac(dut, mode, weight, act, scale_a, scale_b):
    """Clear the accumulator, run ONE valid MX MAC cycle, return packed fp_acc_out."""
    lane_valid = LANE_MASK[mode]

    # Cycle A: latch weight + clear accumulator (mac_en=0, so no accumulation).
    dut.mode.value           = mode
    dut.weight_in.value      = weight & 0xFFFF
    dut.weight_load.value    = 1
    dut.clear_acc.value      = 1
    dut.array_step_en.value  = 0   # §C6: controller never steps during CLEAR_ACC
    dut.mac_en.value         = 0
    dut.act_in.value         = 0
    dut.lane_valid.value     = 0
    dut.mx_scale_a_cur.value = scale_a & 0xFF
    dut.mx_scale_b_cur.value = scale_b & 0xFF
    await RisingEdge(dut.clk)

    # Cycle B: one valid compute — acc_is_zero so the accumulator adopts the product.
    dut.weight_load.value = 0
    dut.clear_acc.value   = 0
    dut.array_step_en.value = 1
    dut.act_in.value      = act & 0xFFFF
    dut.lane_valid.value  = lane_valid
    dut.mac_en.value      = 1
    await RisingEdge(dut.clk)

    # Settle: with the §C6 stage, cycle B's product is consumed at the FIRST
    # settle edge; read one edge later so the registered fp_acc_out is race-free.
    dut.mac_en.value     = 0
    dut.lane_valid.value = 0
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: stage → accumulator consumption edge
    await RisingEdge(dut.clk)
    return int(dut.fp_acc_out.value)


# (label, mode, weight, act, scale_a, scale_b)
# FP4  E2M1: 1.0=0x2 1.5=0x3 0.5sub=0x1 2.0=0x4   FP8 E4M3: 1.0=0x38
CASES = [
    ("MXFP4 1.0*1.0  s=127,127 → 1.0",  MXFP4, 0x0002, 0x0002, 127, 127),
    ("MXFP4 1.0*1.0  s=128,127 → 2.0",  MXFP4, 0x0002, 0x0002, 128, 127),
    ("MXFP4 1.0*1.0  s=130,124 → 1.0",  MXFP4, 0x0002, 0x0002, 130, 124),
    ("MXFP4 dot=5.0  s=127,127 → 5.0",  MXFP4, 0x4132, 0x2222, 127, 127),
    ("MXFP4 dot=5.0  s=126,127 → 2.5",  MXFP4, 0x4132, 0x2222, 126, 127),
    ("MXFP8 1.0*1.0  s=127,127 → 1.0",  MXFP8, 0x0038, 0x0038, 127, 127),
    ("MXFP8 dot=2.0  s=127,127 → 2.0",  MXFP8, 0x3838, 0x3838, 127, 127),
    ("MXFP8 dot=2.0  s=129,127 → 8.0",  MXFP8, 0x3838, 0x3838, 129, 127),
    ("MXINT8 3*5     s=139,127 → 15.0", MXINT8, 0x0003, 0x0005, 139, 127),
    ("MXINT8 -4*7    s=139,127 → -28.0", MXINT8, 0x00FC, 0x0007, 139, 127),
    ("MXINT8 -2*-3   s=139,127 → 6.0",  MXINT8, 0x00FE, 0x00FD, 139, 127),
    ("MXINT8 3*5     s=127,127 → 15*2^-12", MXINT8, 0x0003, 0x0005, 127, 127),
]


@cocotb.test()
async def test_c06_double_bias(dut):
    """All MX modes: fp_acc_out must equal per-element dot × 2^(scale_a+scale_b-254)."""
    await reset(dut)
    fails = []
    for label, mode, w, a, sa, sb in CASES:
        raw = await run_mx_mac(dut, mode, w, a, sa, sb)
        rtl = g.decode_fp_acc_out(raw, mode)
        gold = g.mac_cell_mx_golden(mode, w, a, sa, sb)
        ok = math.isclose(rtl["value"], gold["value"], rel_tol=1e-9, abs_tol=1e-15)
        dut._log.info(f"{label:34s}: rtl={rtl['value']:+.6g} gold={gold['value']:+.6g} "
                      f"{'OK' if ok else 'FAIL'}  (mant={rtl['mant']} exp={rtl['exp']} sign={rtl['sign']})")
        if not ok:
            fails.append(f"{label}: rtl={rtl['value']} gold={gold['value']}")
    assert not fails, "C06 MX double-bias mismatches:\n  " + "\n  ".join(fails)


@cocotb.test()
async def test_c06_scale_nan(dut):
    """E8M0 scale == 0xFF must force the accumulator to NaN (regression guard, unaffected by C06)."""
    await reset(dut)
    raw = await run_mx_mac(dut, MXFP4, 0x0002, 0x0002, 0xFF, 127)
    rtl = g.decode_fp_acc_out(raw, MXFP4)
    dut._log.info(f"MXFP4 scale=0xFF NaN: is_nan={rtl['is_nan']}")
    assert rtl["is_nan"] == 1, f"scale NaN not latched: is_nan={rtl['is_nan']}"

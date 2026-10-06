"""
cocotb regression for mac_cell — focus: M35 (catastrophic-cancellation exp anchor).

acc_exp only ever moves UP (max of prod/acc, +1 on overflow); it is never lowered.
After exact cancellation the mantissa is 0 but acc_exp stays anchored at the
historical maximum, so subsequent small products land >SHIFT_MAX away and are
flushed to a 1-LSB sticky at the stale-high exponent — a huge, order-dependent
error (the true small sum is lost AND the stale exponent inflates the sticky).

Directed vector (the review's +X, -X, +small sequence), one accumulation per cycle
into the same dot (BF16, lane 0):
  +2^20, -2^20  (mantissa cancels to exactly 0),  then 4 * 2^-10.
Correct result = 4 * 2^-10 = 2^-8. Pre-fix the accumulator is stuck at exp≈6 and
the four small products become sticky LSBs there → result ≈ 4*2^6 = 256.

Run: cd tb && make MODULE=test_m35_cancel TOPLEVEL=mac_cell \
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

BF16 = g.MODE_BF16

# BF16 bit patterns
P2_20  = 0x4980   # +2^20
N2_20  = 0xC980   # -2^20
P2_m10 = 0x3A80   # +2^-10
ONE    = 0x3F80   # +1.0


async def reset(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    for sig, val in (("rst_n", 0), ("mode", BF16), ("mac_en", 0), ("clear_acc", 0),
                     ("array_step_en", 1),   # §C6: clocks the FP feedforward stage
                     ("capture_fire", 0), ("lane_valid", 0), ("weight_in", 0),
                     ("weight_load", 0), ("weight_stream_en", 0), ("act_in", 0),
                     ("mx_scale_a_cur", 127), ("mx_scale_b_cur", 127),
                     ("scale_format", g.SCALE_E8M0), ("psum_in", 0), ("sparsity_map_in", 0)):
        getattr(dut, sig).value = val
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def acc_bf16(dut, weight, act, clear):
    dut.mode.value = BF16
    dut.weight_in.value = weight & 0xFFFF
    dut.weight_load.value = 1
    dut.clear_acc.value = 1 if clear else 0
    # §C6: controller never steps during CLEAR_ACC; on chained (clear=False)
    # calls this edge keeps stepping and consumes the previous stage product.
    dut.array_step_en.value = 0 if clear else 1
    dut.mac_en.value = 0
    dut.act_in.value = 0
    dut.lane_valid.value = 0
    await RisingEdge(dut.clk)

    dut.weight_load.value = 0
    dut.clear_acc.value = 0
    dut.array_step_en.value = 1
    dut.act_in.value = act & 0xFFFF
    dut.lane_valid.value = 0x1
    dut.mac_en.value = 1
    await RisingEdge(dut.clk)
    dut.mac_en.value = 0
    dut.lane_valid.value = 0


@cocotb.test()
async def test_m35_cancel_then_small(dut):
    """+2^20, -2^20, then 4*2^-10 must accumulate to 2^-8 (not stale-exp sticky garbage)."""
    await reset(dut)
    await acc_bf16(dut, P2_20, ONE, clear=True)    # +2^20
    await acc_bf16(dut, N2_20, ONE, clear=False)   # -2^20  → mantissa cancels to 0
    for _ in range(4):
        await acc_bf16(dut, P2_m10, ONE, clear=False)  # +2^-10 x4
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: last stage product → accumulator
    await RisingEdge(dut.clk)   # settle: race-free read
    rtl = g.decode_fp_acc_out(int(dut.fp_acc_out.value), BF16)

    expect = 4 * (2.0 ** -10)   # 2^-8 = 0.00390625
    ok = math.isclose(rtl["value"], expect, rel_tol=1e-9, abs_tol=1e-15)
    dut._log.info(f"M35 cancel+small: rtl={rtl['value']:.10g} expect={expect:.10g} "
                  f"{'OK' if ok else 'FAIL'}  (mant={rtl['mant']} exp={rtl['exp']})")
    assert ok, f"M35 cancellation anchor: rtl={rtl['value']} expect={expect}"


@cocotb.test()
async def test_m35_no_regress_deep_accumulate(dut):
    """Regression guard: 64 * (1.5*1.5) BF16 must still sum exactly (no truncation)."""
    await reset(dut)
    HALF3 = 0x3FC0   # 1.5
    await acc_bf16(dut, HALF3, HALF3, clear=True)
    for _ in range(63):
        await acc_bf16(dut, HALF3, HALF3, clear=False)
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: last stage product → accumulator
    await RisingEdge(dut.clk)   # settle: race-free read
    rtl = g.decode_fp_acc_out(int(dut.fp_acc_out.value), BF16)
    expect = 64 * 2.25
    ok = math.isclose(rtl["value"], expect, rel_tol=1e-9, abs_tol=1e-12)
    dut._log.info(f"M35 deep-acc: rtl={rtl['value']:.10g} expect={expect:.10g} "
                  f"{'OK' if ok else 'FAIL'}  (mant={rtl['mant']} exp={rtl['exp']})")
    assert ok, f"M35 deep-accumulate regressed: rtl={rtl['value']} expect={expect}"

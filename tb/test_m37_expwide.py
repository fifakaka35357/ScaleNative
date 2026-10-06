"""
cocotb regression for mac_cell — focus: M37 (10-bit exp-diff wraparound).

mac_fp_acc_align computes exp_diff = prod_exp - acc_exp in a 10-bit signed domain.
Under extreme-but-legal MX scales the operand exponents span far enough that the
subtraction overflows ±511 and wraps, flipping the shift DIRECTION: a tiny stale
accumulator wrongly stays dominant while the large incoming product is shifted to
sticky → catastrophic silent error.

Construct that span across TWO accumulations (no clear between):
  cycle 1: MXFP8 2^-9 * 2^-9 with E8M0 scale 0,0   → prod_exp ≈ -282
  cycle 2: MXFP8 448  * 448   with E8M0 scale 254,254 → prod_exp ≈ +261
  exp_diff ≈ 543 > 511 → 10-bit wrap → -481 (wrong sign).
The correct result is dominated by the huge cycle-2 product; the tiny cycle-1
term is far below precision. Pre-fix the result collapses to the tiny term.

Run: cd tb && make MODULE=test_m37_expwide TOPLEVEL=mac_cell \
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

MXFP8 = g.MODE_MXFP8


async def reset(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    for sig, val in (("rst_n", 0), ("mode", MXFP8), ("mac_en", 0), ("clear_acc", 0),
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


async def accumulate(dut, weight, act, scale_a, scale_b, clear):
    """One MXFP8 accumulation cycle (lane_valid=0x3). clear=1 starts a fresh dot."""
    dut.mode.value = MXFP8
    dut.scale_format.value = g.SCALE_E8M0
    dut.weight_in.value = weight & 0xFFFF
    dut.weight_load.value = 1
    dut.clear_acc.value = 1 if clear else 0
    # §C6: controller never steps during CLEAR_ACC; on chained (clear=False)
    # calls this edge keeps stepping and consumes the previous stage product.
    dut.array_step_en.value = 0 if clear else 1
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
    dut.lane_valid.value = 0x3
    dut.mac_en.value = 1
    await RisingEdge(dut.clk)
    dut.mac_en.value = 0
    dut.lane_valid.value = 0


@cocotb.test()
async def test_m37_extreme_exp_span(dut):
    """Two accumulations spanning >511 in exponent must not wrap the shift direction."""
    await reset(dut)

    # FP8 E4M3: 2^-9 subnormal = 0x01 ; 448.0 (max finite) = 0x7E
    SUB = 0x0001   # lane 0 = 2^-9, lane 1 = 0
    MAX = 0x007E   # lane 0 = 448, lane 1 = 0

    # cycle 1: tiny product, tiny scale (no clear yet → this is the clear+first)
    await accumulate(dut, SUB, SUB, 0x00, 0x00, clear=True)
    # cycle 2: huge product, huge scale (accumulate into the same dot)
    await accumulate(dut, MAX, MAX, 0xFE, 0xFE, clear=False)
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: last stage product → accumulator
    await RisingEdge(dut.clk)   # settle: race-free read
    raw = int(dut.fp_acc_out.value)
    rtl = g.decode_fp_acc_out(raw, MXFP8)

    # Golden: the two terms, summed at infinite precision (cycle-2 dominates).
    t1 = g.mac_cell_mx_golden(MXFP8, SUB, SUB, 0x00, 0x00)["value"]
    t2 = g.mac_cell_mx_golden(MXFP8, MAX, MAX, 0xFE, 0xFE)["value"]
    expect = t1 + t2

    rel = abs(rtl["value"] - expect) / abs(expect)
    dut._log.info(f"M37 span: rtl={rtl['value']:.6e} expect={expect:.6e} "
                  f"(t2={t2:.3e} t1={t1:.3e}) rel_err={rel:.3e} "
                  f"mant={rtl['mant']} exp={rtl['exp']}")
    # Pre-fix the exp_diff wraps, the huge cycle-2 product is flushed to sticky and
    # the result collapses to the tiny cycle-1 term (rel_err ~ 1.0). Post-fix it
    # tracks the cycle-2 magnitude.
    assert rel < 1e-3, f"M37 exp-diff wrap: rtl={rtl['value']:.6e} expect={expect:.6e}"

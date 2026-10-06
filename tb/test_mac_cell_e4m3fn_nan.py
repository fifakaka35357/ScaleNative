"""
[C2 anchor ③-companion, 2026-07-25] mac_cell-level E4M3FN DATA-operand NaN —
the decode at mac_lru.sv:308-311 ({exp=1111,frac=111} = byte 0x7F/0xFF) has
never been driven by any test (the existing NaN tests cover only the block
SCALE byte, mac_cell.sv:620-646 — a different detector).

WHY it matters: §A1 names prod_is_nan/prod_is_inf as never-asserted; the LRU
data-NaN is the only hardware route that can set lru_in.is_nan from real
operand bytes (E4M3FN has no Inf — mac_lru.sv:311 keeps lane_is_inf 0, so the
accumulator Inf arms are covered by the direct TB test_fp_acc_specials).

Oracle: NaN flag semantics only (accumulator latches is_nan; value is stale
by contract) + a near-miss negative control (0x77 = exp 1110, frac 111 → a
LEGAL finite, must NOT flag).

RED protocol: mutate mac_lru.sv:309-310 `lane_is_nan[i] = 1'b0;` (detector
disabled) => both nan cases FAIL, the near-miss control still PASSES.

Run: cd tb && make MODULE=test_mac_cell_e4m3fn_nan TOPLEVEL=mac_cell \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_lru.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_fp_acc_align.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_cell.sv"
"""
import os
import sys
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
                     ("array_step_en", 1),
                     ("capture_fire", 0), ("lane_valid", 0), ("weight_in", 0),
                     ("weight_load", 0), ("weight_stream_en", 0), ("act_in", 0),
                     ("mx_scale_a_cur", 0x38), ("mx_scale_b_cur", 0x38),
                     ("scale_format", g.SCALE_E4M3), ("psum_in", 0), ("sparsity_map_in", 0)):
        getattr(dut, sig).value = val
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_fp8(dut, weight, act):
    dut.mode.value = MXFP8
    dut.weight_in.value = weight & 0xFFFF
    dut.weight_load.value = 1
    dut.clear_acc.value = 1
    dut.array_step_en.value = 0
    dut.mac_en.value = 0
    dut.act_in.value = 0
    dut.lane_valid.value = 0
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
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: stage → accumulator consumption edge
    await RisingEdge(dut.clk)   # settle
    return g.decode_fp_acc_out(int(dut.fp_acc_out.value), MXFP8)


@cocotb.test()
async def test_act_operand_nan_0x7f(dut):
    """act lane0 = 0x7F (E4M3FN NaN, sign 0): prod_is_nan -> acc is_nan."""
    await reset(dut)
    r = await run_fp8(dut, 0x3838, (0x38 << 8) | 0x7F)
    assert r["is_nan"] == 1, "E4M3FN 0x7F act operand did not flag NaN: %r" % r


@cocotb.test()
async def test_weight_operand_nan_0xff(dut):
    """weight lane1 = 0xFF (E4M3FN NaN, sign 1 — sign ignored by decode):
    prod_is_nan -> acc is_nan."""
    await reset(dut)
    r = await run_fp8(dut, (0xFF << 8) | 0x38, 0x3838)
    assert r["is_nan"] == 1, "E4M3FN 0xFF weight operand did not flag NaN: %r" % r


@cocotb.test()
async def test_near_miss_0x77_is_finite(dut):
    """Negative control: 0x77 (exp=1110, frac=111 = 15.0*2^..., a LEGAL max
    finite) must NOT flag NaN — pins the exact 7-bit all-ones decode."""
    await reset(dut)
    r = await run_fp8(dut, 0x3838, (0x38 << 8) | 0x77)
    assert r["is_nan"] == 0, "0x77 wrongly decoded as NaN: %r" % r
    assert r["value"] != 0.0, "0x77 lane must contribute a finite product: %r" % r

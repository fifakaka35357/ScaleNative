"""
cocotb regression for mac_lru — focus: M36 (sticky consistency at the clamp site).

The datapath's chosen sticky strategy is OR-into-LSB (align path + R3 BF16 fix +
LRU non-clamp branch all inject the shifted-out residue into the operand LSB).
But the LRU's CLAMP branch (shift_dist > DMAX) computes the sticky and then drops
it (it zeroes the aligned lane without injecting bit0), inconsistent with the
non-clamp branch. M36 completes the strategy: the clamp branch also injects sticky.

Constructed case (FP8, 2 lanes):
  lane0 = 2.0 * 2.0  (expP = +2, the max-exp lane → aligned mantissa = 1024, even)
  lane1 = 2^-6 * 2^-6 (expP = -12 → shift_dist = 14 > FP8_DMAX(13) → CLAMPED, residue!=0)
The clamped lane should contribute a sticky 1 LSB to the reduction:
  fixed:   reduced mant = 1025 (odd)   pre-fix: 1024 (sticky dropped, even).

Run: cd tb && make MODULE=test_m36_sticky TOPLEVEL=mac_lru \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_lru.sv"
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

MODE_FP8 = g.MODE_FP8


@cocotb.test()
async def test_m36_clamp_sticky(dut):
    """A clamped FP8 lane with residue must inject a sticky 1 LSB (OR-into-LSB consistency)."""
    Z4 = [0, 0, 0, 0]
    # FP8 E4M3: 2.0 = {0,1000,000} = 0x40 ; 2^-6 = {0,0001,000} = 0x08
    fp8_a = [0x40, 0x08]   # lane0 = 2.0, lane1 = 2^-6
    fp8_b = [0x40, 0x08]

    dut.mode.value = MODE_FP8
    for i in range(4):
        dut.fp4_a[i].value = 0
        dut.fp4_b[i].value = 0
    for i in range(2):
        dut.fp8_a[i].value = fp8_a[i]
        dut.fp8_b[i].value = fp8_b[i]
    await Timer(1, "ns")

    rtl = g.decode_lru_out(int(dut.lru_out.value), MODE_FP8)
    mant = rtl["mant"]
    dut._log.info(f"M36 clamp sticky: mant={mant} exp={rtl['exp']} "
                  f"(lane0=1024 + clamped-lane1 sticky → expect 1025/odd)")
    # lane0 (max-exp) contributes 1024 (even); the clamped lane1 (2^-6*2^-6,
    # shift 14 > DMAX 13, residue nonzero) must add a sticky 1 → 1025.
    assert mant == 1025, (
        f"M36 clamp sticky dropped: mant={mant} (expected 1025; pre-fix 1024)")

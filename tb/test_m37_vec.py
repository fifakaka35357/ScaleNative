"""
cocotb regression for vec_renorm_quant — M37-Vec (10-bit exp-spread wraparound).

vec_renorm_quant computes the exponent spread (max_exp - min_exp) in a 10-bit
signed domain to decide escape (precision-loss spill). Under a legal but wide
spread (>511) the subtraction wraps NEGATIVE, so `spread > 14` reads false and
escape is silently MISSED exactly when precision loss is catastrophic. M37-Vec
widens the spread/shift arithmetic to 12-bit.

Directed: two normal lanes at exp=+300 and exp=-300 (spread=600), rest zero.
  fixed:   escape_needed = 1 (600 > 14)
  pre-fix: 600 wraps to -424 in 10-bit → -424 > 14 is false → escape_needed = 0.

Run: cd tb && make MODULE=test_m37_vec TOPLEVEL=vec_renorm_quant \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv"
(Step 2: retargeted to the unified pe_pkg SSOT; was Vector/Unchanged/PE/pe_pkg.sv)
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

# vec_lane_result_t packed layout (32-bit, MSB first):
#   mant[31:16] | exp[15:6] | sign[5] | is_zero[4] | is_nan[3] | is_inf[2] | overflow[1] | underflow[0]
def pack_lane(mant=0, exp=0, sign=0, is_zero=0, is_nan=0, is_inf=0, overflow=0, underflow=0):
    return (((mant & 0xFFFF) << 16) | ((exp & 0x3FF) << 6) | ((sign & 1) << 5)
            | ((is_zero & 1) << 4) | ((is_nan & 1) << 3) | ((is_inf & 1) << 2)
            | ((overflow & 1) << 1) | (underflow & 1))


async def drive(dut, lanes):
    for i in range(16):
        dut.lane_results_i[i].value = lanes[i]
    dut.ctrl_i.value = 0           # all-zero: active_lanes=16 (default), escape_req=0
    dut.orig_scale_i.value = 0
    dut.valid_i.value = 1
    await Timer(1, "ns")
    raw = int(dut.result_o.value)
    return (raw >> 1) & 1          # escape_needed = bit[1] (valid=bit0)


@cocotb.test()
async def test_m37_vec_escape_spread(dut):
    """A >511 exponent spread must assert escape_needed (no 10-bit wrap)."""
    # lane0 exp=+300, lane1 exp=-300 (both normal, nonzero); rest zero-masked.
    lanes = [pack_lane(is_zero=1)] * 16
    lanes = list(lanes)
    lanes[0] = pack_lane(mant=256, exp=300, is_zero=0)
    lanes[1] = pack_lane(mant=256, exp=-300, is_zero=0)
    escape = await drive(dut, lanes)
    dut._log.info(f"M37-Vec spread=600: escape_needed={escape} (expect 1; pre-fix 0 via wrap)")
    assert escape == 1, f"M37-Vec: spread>511 wrapped, escape missed (escape_needed={escape})"


@cocotb.test()
async def test_m37_vec_no_false_escape(dut):
    """A small in-range spread must NOT escape (regression guard)."""
    lanes = [pack_lane(is_zero=1) for _ in range(16)]
    lanes[0] = pack_lane(mant=256, exp=5, is_zero=0)
    lanes[1] = pack_lane(mant=256, exp=2, is_zero=0)   # spread=3 < 14
    escape = await drive(dut, lanes)
    dut._log.info(f"M37-Vec spread=3: escape_needed={escape} (expect 0)")
    assert escape == 0, f"M37-Vec: small spread falsely escaped (escape_needed={escape})"

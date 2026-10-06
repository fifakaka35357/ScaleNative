"""
cocotb regression for vec_reduce_cluster — M37-Vec (reduce-side exponent widening).

Closes the review-gate MAJOR: the three reduce-side M37-Vec edits (pair_sum ediff,
pair_sum_stat ediff, STAT 2*exp saturation) shipped with no test. Unlike renorm,
the reduce datapath has NO escape mechanism, so a wrapped ediff / sign-flipped
2*exp silently corrupts SUM/variance results.

(a) SUM: lane0 exp=+300, lane1 exp=-300 (spread 600). pair_sum must keep the
    larger (lane0) dominant → result exp = +300. Pre-fix the 10-bit ediff wraps
    to -424 → the LARGER operand is flushed → result collapses to exp=0/mant=0.
(b) STAT: a lane with exp=+300 (|exp|>255) → 2*exp=600 must not wrap. Originally
    "saturate to +511 in the 10-bit stat exp"; ▲ S-STAT v1.2 (prereg
    soc600_prereg_20260902.md §70.3 / §74.1.4, 待-2): the raw STAT port is now the
    exact window sum (rm, re) with a 12-bit signed re — decoded as signed12 it is
    574 (rm 0x9C40000000) — and result_o is the O-IB Inf code (-2^20, 511, nan 0,
    inf 1), both computed at run time by Model/bfp_golden.py (stat_raw_golden /
    stat_sumsq_golden). The pre-fix RTL reports raw exp 511 here (10-bit
    saturation), so this case is the one FAIL of this file on the pre-fix RTL (J1).

Run: cd tb && make MODULE=test_m37_vec_reduce TOPLEVEL=vec_reduce_cluster \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv \
        ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv"
(Step 2: retargeted to the unified pe_pkg SSOT; was Vector/Unchanged/PE/pe_pkg.sv)
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Model"))
import bfp_golden as g  # noqa: E402

REDUCE_SUM  = 2
REDUCE_STAT = 3


# vec_lane_result_t (32-bit): mant[31:16] exp[15:6] sign[5] is_zero[4] is_nan[3] is_inf[2] overflow[1] underflow[0]
def pack_lane(mant=0, exp=0, sign=0, is_zero=0, is_nan=0, is_inf=0):
    return (((mant & 0xFFFF) << 16) | ((exp & 0x3FF) << 6) | ((sign & 1) << 5)
            | ((is_zero & 1) << 4) | ((is_nan & 1) << 3) | ((is_inf & 1) << 2))


def signed10(x):
    x &= 0x3FF
    return x - 1024 if x & 0x200 else x


def signed12(x):
    x &= 0xFFF
    return x - 4096 if x & 0x800 else x


def signed21(x):
    x &= 0x1FFFFF
    return x - (1 << 21) if x & (1 << 20) else x


async def drive(dut, lanes, mode):
    for i in range(16):
        dut.lane_results_i[i].value = lanes[i]
    dut.mode_i.value = mode
    dut.valid_i.value = 1
    await Timer(1, "ns")
    raw = int(dut.result_o.value)
    # vec_reduce_result_t (34-bit): mant[33:13] exp[12:3] is_nan[2] is_inf[1] valid[0]
    res_exp = signed10((raw >> 3) & 0x3FF)
    stat_exp = signed10(int(dut.stat_raw_exp_o.value))
    return res_exp, stat_exp


@cocotb.test()
async def test_m37_reduce_sum_spread(dut):
    """SUM pair_sum with >511 exponent spread must keep the larger operand dominant."""
    lanes = [pack_lane(mant=0, exp=0, is_zero=1) for _ in range(16)]
    lanes[0] = pack_lane(mant=1000, exp=300, is_zero=0)    # dominant
    lanes[1] = pack_lane(mant=4,    exp=-300, is_zero=0)   # negligible (spread 600)
    res_exp, _ = await drive(dut, lanes, REDUCE_SUM)
    dut._log.info(f"M37-Vec reduce SUM: result_exp={res_exp} (expect 300; pre-fix wraps → 0)")
    assert res_exp == 300, f"SUM ediff wrap: result_exp={res_exp} (expected 300)"


@cocotb.test()
async def test_m37_reduce_stat_saturate(dut):
    """STAT 2*exp for |exp|>255 must not sign-flip via a 10-bit wrap (S-STAT v1.2 expectation)."""
    lanes = [pack_lane(mant=0, exp=0, is_zero=1) for _ in range(16)]
    lanes[0] = pack_lane(mant=100, exp=300, is_zero=0)     # 2*300 = 600: beyond a 10-bit exponent
    glanes = [dict(mant=0, exp=0, is_zero=1, is_nan=0, is_inf=0) for _ in range(16)]
    glanes[0] = dict(mant=100, exp=300, is_zero=0, is_nan=0, is_inf=0)
    exp_raw = tuple(g.stat_raw_golden(glanes))              # (0x9C40000000, 574)
    exp_res = tuple(g.stat_sumsq_golden([glanes]))          # O-IB Inf (-1048576, 511, 0, 1)
    for i in range(16):
        dut.lane_results_i[i].value = lanes[i]
    dut.mode_i.value = REDUCE_STAT
    dut.valid_i.value = 1
    await Timer(1, "ns")
    raw_mant = int(dut.stat_raw_mant_o.value) & ((1 << 40) - 1)
    raw_exp = signed12(int(dut.stat_raw_exp_o.value))      # §70.3: raw exp decoded as signed12
    r = int(dut.result_o.value)
    # vec_reduce_result_t (34-bit): mant[33:13] exp[12:3] is_nan[2] is_inf[1] valid[0]
    res = (signed21((r >> 13) & 0x1FFFFF), signed10((r >> 3) & 0x3FF), (r >> 2) & 1, (r >> 1) & 1)
    dut._log.info(f"M37-Vec reduce STAT: raw=(0x{raw_mant:X},{raw_exp}) result={res} "
                  f"(expect raw=(0x{exp_raw[0]:X},{exp_raw[1]}) result={exp_res}; pre-fix raw exp 511)")
    assert (raw_mant, raw_exp) == exp_raw, \
        f"STAT raw port: (0x{raw_mant:X},{raw_exp}) != golden (0x{exp_raw[0]:X},{exp_raw[1]})"
    assert res == exp_res, f"STAT result_o: {res} != golden {exp_res}"

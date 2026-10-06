"""
cocotb regression for vec_reduce_max_combine — block32 cross-pass REDUCE_MAX
combine (HW-REVIEW T2, merge-gate blocker fix).

Bug (merge-gate, confirmed major): the TIER-2 sign-blind value-max fix patched the
16-lane reduce tree (pair_max) and LANE_MAX, but MISSED a third max-comparison
site — the block32 cross-pass combine in vector_unit.sv, which combines the two
16-element half-maxes. It still did an exp-first sign-blind compare, so for a
block32 VEC_REDUCE_MAX a high-exponent NEGATIVE half wrongly beat a low-exponent
POSITIVE half -> silent wrong max (the softmax-prep config the TIER-2 work targets).
tb_vec_reduce_max only drove the 16-lane single-pass tree, so it could not catch it.

Fix: extract the combine into vec_reduce_max_combine (aligned signed-value compare,
mirroring pair_max), unit-tested here against an independent Fraction oracle.

Run: cd tb && make MODULE=test_vec_reduce_max_combine TOPLEVEL=vec_reduce_max_combine \
  VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
  ../rtl/Vector/vec_reduce_max_combine.sv"
"""
from fractions import Fraction

import cocotb
from cocotb.triggers import Timer

REDUCE_W = 21
EXP_W = 10


def to_u(x, w):
    return x & ((1 << w) - 1)


def to_s(x, w):
    x &= (1 << w) - 1
    return x - (1 << w) if x & (1 << (w - 1)) else x


def pack(mant, exp, is_nan=0, is_inf=0, valid=1):
    # vec_reduce_result_t (34b): mant[33:13] exp[12:3] is_nan[2] is_inf[1] valid[0]
    return ((to_u(mant, REDUCE_W) << 13) | (to_u(exp, EXP_W) << 3)
            | ((is_nan & 1) << 2) | ((is_inf & 1) << 1) | (valid & 1))


def val(mant, exp):
    return Fraction(mant) * (Fraction(2) ** exp)


async def combine(dut, a, b):
    """a, b = (mant, exp). Returns (mant, exp) of y_o."""
    dut.a_i.value = pack(*a)
    dut.b_i.value = pack(*b)
    await Timer(1, "ns")
    raw = int(dut.y_o.value)
    return (to_s((raw >> 13) & ((1 << REDUCE_W) - 1), REDUCE_W),
            to_s((raw >> 3) & 0x3FF, EXP_W))


def golden(a, b):
    return a if val(*a) >= val(*b) else b


@cocotb.test()
async def test_combine_pos_beats_highexp_neg(dut):
    """+1*2^0 (=+1) vs -1*2^5 (=-32): the low-exp POSITIVE half is the max.
    The old exp-first combine wrongly picked the high-exp negative."""
    a, b = (1, 0), (-1, 5)
    got = await combine(dut, a, b)
    g = golden(a, b)                      # (1, 0)
    dut._log.info(f"pos/highexp-neg: rtl={got} golden={g}")
    assert got == g, f"got {got}, expected {g} (value-blind combine picked the negative)"


@cocotb.test()
async def test_combine_samesign_crossexp(dut):
    """+1000*2^0 (=1000) vs +1*2^9 (=512): larger VALUE wins despite lower exp."""
    a, b = (1000, 0), (1, 9)
    got = await combine(dut, a, b)
    g = golden(a, b)                      # (1000, 0)
    assert got == g, f"got {got}, expected {g}"


@cocotb.test()
async def test_combine_equal_exp(dut):
    """Equal exp: larger signed mantissa wins (b)."""
    a, b = (5, 3), (9, 3)
    got = await combine(dut, a, b)
    assert got == (9, 3), f"got {got}, expected (9,3)"


@cocotb.test()
async def test_combine_both_negative(dut):
    """Two negative halves at different exps: the least-negative VALUE is the max.
    -3*2^0 (=-3) vs -1*2^4 (=-16): max = -3 (the low-exp one)."""
    a, b = (-3, 0), (-1, 4)
    got = await combine(dut, a, b)
    g = golden(a, b)                      # (-3, 0)
    assert got == g, f"got {got}, expected {g}"


@cocotb.test()
async def test_combine_flags(dut):
    """is_nan/is_inf OR, valid AND propagate."""
    dut.a_i.value = pack(1, 0, is_nan=1, valid=1)
    dut.b_i.value = pack(2, 0, is_inf=1, valid=0)
    await Timer(1, "ns")
    raw = int(dut.y_o.value)
    assert (raw >> 2) & 1 == 1, "is_nan must OR"
    assert (raw >> 1) & 1 == 1, "is_inf must OR"
    assert raw & 1 == 0, "valid must AND (0 here)"

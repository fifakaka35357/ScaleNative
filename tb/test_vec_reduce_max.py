"""
cocotb regression for the VEC_REDUCE_MAX path (TIER-2 silent-value fix).

Bug (confirmed 2026-06-20 HW review): VEC_REDUCE_MAX mapped to LANE_MAX with a
zero src1 (need_src1==0), so the lane computed max(src0, 0) — ReLU-clamping every
NEGATIVE element to a zero element carrying exp=0. The reduce tree (vec_reduce_
cluster.pair_max) compares exponent-first, so those phantom exp=0 zeros beat real
elements whenever the block's shared exponent is negative. Net: VEC_REDUCE_MAX
silently returns 0 (a wrong, too-large maximum) for any block whose true max is
negative, and for mixed-sign blocks at a negative exponent. softmax max-subtract
and block max-magnitude extraction would be corrupted. Zero prior coverage.

Fix: lane_op_from_primitive(VEC_REDUCE_MAX) -> LANE_REDUCE_P (passthrough). All
16 elements keep the shared block exponent, and the tree's same-exp signed-mant
pair_max yields the correct value-max. The reduce tree itself is unchanged.

The oracle is an INDEPENDENT plain-Python argmax over value = mant * 2^exp
(Fraction-exact), structurally unrelated to the RTL shift/compare tree.

Run: cd tb && make MODULE=test_vec_reduce_max TOPLEVEL=tb_vec_reduce_max \
  VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
  ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
  ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv \
  ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv ../tb/tb_vec_reduce_max.sv"
"""
from fractions import Fraction

import cocotb
from cocotb.triggers import Timer

VEC_LANES = 16


def pack_elem(mant=0, exp=0, sign=0, is_zero=0, is_nan=0, is_inf=0):
    # vec_elem_t (30b) MSB-first: mant[29:14] exp[13:4] sign[3] is_zero[2] is_nan[1] is_inf[0]
    return (((mant & 0xFFFF) << 14) | ((exp & 0x3FF) << 4) | ((sign & 1) << 3)
            | ((is_zero & 1) << 2) | ((is_nan & 1) << 1) | (is_inf & 1))


def signed(x, w):
    x &= (1 << w) - 1
    return x - (1 << w) if x & (1 << (w - 1)) else x


async def reduce_max(dut, elems):
    """elems: list of (mant, exp). Drives src0, returns (res_mant, res_exp)."""
    for i in range(VEC_LANES):
        m, e = elems[i]
        dut.src0_i[i].value = pack_elem(mant=m, exp=e, sign=1 if m < 0 else 0,
                                        is_zero=1 if m == 0 else 0)
    await Timer(1, "ns")
    raw = int(dut.result_o.value)
    # vec_reduce_result_t (34b): mant[33:13] exp[12:3] is_nan[2] is_inf[1] valid[0]
    res_mant = signed((raw >> 13) & ((1 << 21) - 1), 21)
    res_exp = signed((raw >> 3) & 0x3FF, 10)
    return res_mant, res_exp


def golden_max(elems):
    """Independent oracle: argmax of mant*2^exp; return (mant, exp) of the winner."""
    best = max(elems, key=lambda me: Fraction(me[0]) * (Fraction(2) ** me[1]))
    return best


@cocotb.test()
async def test_reduce_max_all_negative(dut):
    """All-negative block at a negative shared exponent: max = least-negative.
    Pre-fix returns 0 (ReLU clamp); post-fix returns the true max element."""
    E = -3
    mants = [-5, -12, -3, -20, -7, -9, -2, -15, -4, -30, -6, -8, -11, -1, -13, -10]
    elems = [(m, E) for m in mants]
    res_m, res_e = await reduce_max(dut, elems)
    gm, ge = golden_max(elems)                      # (-1, -3)
    dut._log.info(f"all-neg: rtl=({res_m},{res_e}) golden=({gm},{ge})")
    assert (res_m, res_e) == (gm, ge), \
        f"REDUCE_MAX all-negative: got ({res_m},{res_e}), expected ({gm},{ge}) " \
        f"(pre-fix collapses to (0,0) via ReLU clamp)"


@cocotb.test()
async def test_reduce_max_mixed_sign_neg_exp(dut):
    """Mixed-sign block at negative exponent: the phantom exp=0 zeros (from ReLU'd
    negatives) beat the real positive max in the exp-first tree pre-fix."""
    E = -2
    mants = [9, -3, 2, -7, 0, 5, -1, 4, -20, 1, -2, 8, -6, 3, -4, 7]
    elems = [(m, E) for m in mants]
    res_m, res_e = await reduce_max(dut, elems)
    gm, ge = golden_max(elems)                      # (9, -2)
    dut._log.info(f"mixed-neg-exp: rtl=({res_m},{res_e}) golden=({gm},{ge})")
    assert (res_m, res_e) == (gm, ge), \
        f"REDUCE_MAX mixed/neg-exp: got ({res_m},{res_e}), expected ({gm},{ge}) " \
        f"(pre-fix collapses to (0,0): phantom exp=0 zero outranks real max)"


@cocotb.test()
async def test_reduce_max_all_positive_guard(dut):
    """Regression guard: all-positive at positive exp already worked pre-fix;
    the fix must not break it."""
    E = 1
    mants = [1, 9, 4, 2, 7, 3, 5, 8, 6, 0, 1, 2, 3, 4, 5, 6]
    elems = [(m, E) for m in mants]
    res_m, res_e = await reduce_max(dut, elems)
    gm, ge = golden_max(elems)                      # (9, 1)
    dut._log.info(f"all-pos: rtl=({res_m},{res_e}) golden=({gm},{ge})")
    assert (res_m, res_e) == (gm, ge), \
        f"REDUCE_MAX all-positive guard: got ({res_m},{res_e}), expected ({gm},{ge})"


# ── cross-exponent cases: exercise the reduce tree's value-aware pair_max ──
# (per-element exponents survive through LANE_REDUCE_P, so pair_max sees a real
# cross-exp compare — the sign-blind exp-first version got these wrong.)
@cocotb.test()
async def test_reduce_max_crossexp_pos_beats_highexp_neg(dut):
    """A small POSITIVE at a low exp is the max, not a large NEGATIVE at the
    highest exp (pre-fix pair_max picked the highest exponent, sign-blind)."""
    elems = [(-1, 5)] * 16
    elems[3] = (3, -2)       # true max value (+0.75) at a NEGATIVE exponent, so a
                             # phantom exp=0 zero (pre-fix ReLU clamp) would outrank it
    elems[9] = (-50, 9)      # highest exponent but large negative
    res_m, res_e = await reduce_max(dut, elems)
    gm, ge = golden_max(elems)                      # (3, -2)
    dut._log.info(f"xexp pos/neg: rtl=({res_m},{res_e}) golden=({gm},{ge})")
    assert (res_m, res_e) == (gm, ge), \
        f"pair_max sign-blind: got ({res_m},{res_e}), expected ({gm},{ge})"


@cocotb.test()
async def test_reduce_max_crossexp_samesign(dut):
    """Same-sign cross-exp: +1000*2^5 (=32000) beats +1*2^9 (=512) despite the
    lower exponent (exp-first compare was wrong for un-normalized block-float)."""
    elems = [(1, -3)] * 16
    elems[2] = (1000, 5)
    elems[11] = (1, 9)       # highest exp, tiny value
    res_m, res_e = await reduce_max(dut, elems)
    gm, ge = golden_max(elems)                      # (1000, 5)
    dut._log.info(f"xexp samesign: rtl=({res_m},{res_e}) golden=({gm},{ge})")
    assert (res_m, res_e) == (gm, ge), \
        f"pair_max exp-first: got ({res_m},{res_e}), expected ({gm},{ge})"

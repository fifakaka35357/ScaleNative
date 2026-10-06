"""
cocotb regression for vec_mant_corr_mul (D10) — E4M3 precise-mode mantissa correction.

Drives the combinational leaf with (mant, mant_corr, round) and checks mant_o /
overflow_o against the golden (Model/bfp_golden.py mant_corr_apply_golden). Covers
identity (128), all E4M3 mant_corr values {128..240}, both signs, RTZ/RNE rounding,
the min/max clamp, and a randomized sweep.

Run: cd tb && make MODULE=test_vec_mant_corr_mul TOPLEVEL=vec_mant_corr_mul \
        VERILOG_SOURCES="../rtl/Vector/vec_mant_corr_mul.sv"
"""
import os
import sys
import random
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

# the 8 legal E4M3 mant_corr values: (1 + m3/8) * 128
E4M3_CORR = [(8 + m) << 4 for m in range(8)]   # 128,144,160,176,192,208,224,240


def to2c(v, bits):
    return v & ((1 << bits) - 1)


async def ev(dut, mant, corr, rne):
    dut.mant_i.value = to2c(mant, 16)
    dut.mant_corr_i.value = corr
    dut.round_rne_i.value = rne
    await Timer(1, "ns")
    return g.signed(int(dut.mant_o.value), 16), int(dut.overflow_o.value)


@cocotb.test()
async def test_mant_corr_mul(dut):
    fails = []
    mants = [0, 1, -1, 100, -100, 1000, -1000, 16384, -16384, 12345, -12345,
             32767, -32768, 20000, -20000, 2, 7, 255, -255]
    for mant in mants:
        for corr in E4M3_CORR:
            for rne in (0, 1):
                rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
                exp_m, exp_ovf = g.mant_corr_apply_golden(mant, corr, rm)
                got_m, got_ovf = await ev(dut, mant, corr, rne)
                lbl = f"mant={mant} corr={corr} rne={rne}"
                if got_m != exp_m:
                    fails.append(f"{lbl}: mant rtl={got_m} gold={exp_m}")
                if got_ovf != (1 if exp_ovf else 0):
                    fails.append(f"{lbl}: ovf rtl={got_ovf} gold={exp_ovf}")

    # identity: mant_corr=128 must be a no-op for every mantissa
    for mant in mants:
        got_m, got_ovf = await ev(dut, mant, 128, 0)
        if got_m != mant or got_ovf:
            fails.append(f"identity mant={mant}: rtl={got_m} ovf={got_ovf}")

    # randomized
    rng = random.Random(0xD10)
    for _ in range(300):
        mant = rng.randint(-32768, 32767)
        corr = rng.choice(E4M3_CORR)
        rne = rng.randint(0, 1)
        rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
        exp_m, exp_ovf = g.mant_corr_apply_golden(mant, corr, rm)
        got_m, got_ovf = await ev(dut, mant, corr, rne)
        if got_m != exp_m or got_ovf != (1 if exp_ovf else 0):
            fails.append(f"rand mant={mant} corr={corr} rne={rne}: "
                         f"rtl=({got_m},{got_ovf}) gold=({exp_m},{exp_ovf})")

    assert not fails, "vec_mant_corr_mul mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:30]))
    dut._log.info("vec_mant_corr_mul: all cases match golden (D10 mant_corr application)")


def _independent_corr(mant, corr, rne):
    """From-scratch oracle (GOLD-5): exact rational mant*corr/128 rounded by an
    independent round-half-even / toward-zero, then the leaf's documented clamp.
    Shares NO code path with mant_corr_apply_golden (no >>7, no copied RNE)."""
    from fractions import Fraction
    sign = mant < 0
    exact = Fraction(abs(int(mant)) * (corr & 0xFF), 128)
    fl = exact.numerator // exact.denominator        # exact >= 0 -> floor
    rem = exact - fl
    if rne:
        q = fl + 1 if (rem > Fraction(1, 2) or (rem == Fraction(1, 2) and (fl & 1))) else fl
    else:
        q = fl                                       # toward zero (magnitude floor)
    if not sign:                                     # leaf clamp: QMAX=2^15-1
        ovf = q > 32767
        return (32767 if ovf else q), ovf
    ovf = q > 32768                                  # QMIN_MAG=2^15
    return (-32768 if q >= 32768 else -q), ovf


@cocotb.test()
async def test_independent_oracle(dut):
    """Cross-check RTL against an independent Fraction oracle, and confirm the
    golden agrees with it too — so a rounding/clamp error SHARED by RTL and
    golden cannot hide (N19 / GOLD-5)."""
    fails = []
    rng = random.Random(0x5ADD)
    samples = [0, 1, -1, 17475, -17475, 17476, -17476, 32767, -32768, 21845, -21846]
    samples += [rng.randint(-32768, 32767) for _ in range(600)]
    for mant in samples:
        for corr in E4M3_CORR:
            for rne in (0, 1):
                ind_m, ind_ovf = _independent_corr(mant, corr, rne)
                got_m, got_ovf = await ev(dut, mant, corr, rne)
                rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
                gold_m, gold_ovf = g.mant_corr_apply_golden(mant, corr, rm)
                lbl = f"mant={mant} corr={corr} rne={rne}"
                if got_m != ind_m or got_ovf != (1 if ind_ovf else 0):
                    fails.append(f"{lbl}: rtl=({got_m},{got_ovf}) indep=({ind_m},{ind_ovf})")
                if gold_m != ind_m or (1 if gold_ovf else 0) != (1 if ind_ovf else 0):
                    fails.append(f"{lbl}: GOLDEN=({gold_m},{gold_ovf}) indep=({ind_m},{ind_ovf})")
    assert not fails, "independent-oracle mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:30]))
    dut._log.info("vec_mant_corr_mul: RTL and golden both match the independent Fraction oracle")

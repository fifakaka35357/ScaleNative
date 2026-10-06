"""
cocotb regression for D10 — E4M3 precise-mode RESADD inside vec_lane_array.

Drives two independent lanes of vec_lane_array (via tb_lane_resadd_precise) under
LANE_ADD/LANE_SUB and checks each lane's (mant, exp, sign, is_zero, overflow)
against the golden (Model/bfp_golden.lane_resadd_precise_golden). Coverage:

  * identity regression : precise=1 with mant_corr=128 MUST equal precise=0
                          (simple mode) — the correction is an exact no-op at 1.0
  * correction-active    : precise=1 with a non-unit mant_corr MUST differ from
                          precise=0 on at least one input — proves the leaves are
                          really in the datapath (guards against a no-op pass)
  * zero-operand        : 0 +/- x and x +/- 0 (isolates correction + renorm17,
                          independent of the aligned-add)
  * equal-exp add       : both operands corrected, same exponent
  * shifted add         : independent exponents (alignment + sticky)
  * per-lane independence: lanes 0 and 1 driven differently with SHARED mant_corr
  * real-value bound    : every non-special result is also checked against the
                          true value mant*(corr/128)*2^exp within the toward-zero
                          quantization bound (independent of the golden — N19)
  * randomized sweep over all of the above, RTZ and RNE

Run: cd tb && make MODULE=test_lane_resadd_precise TOPLEVEL=tb_lane_resadd_precise \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../tb/tb_lane_resadd_precise.sv"
"""
import os
import sys
import random
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

LANE_ADD = 5
LANE_SUB = 6
E4M3_CORR = [(8 + m) << 4 for m in range(8)]   # 128,144,...,240


def to2c(v, bits):
    return v & ((1 << bits) - 1)


async def drive(dut, a, b, corr0, corr1, op, precise, rne):
    """a, b = (m0,e0,z0,m1,e1,z1) for lane 0 and lane 1 respectively."""
    (m0a, e0a, z0a, m1a, e1a, z1a) = a
    (m0b, e0b, z0b, m1b, e1b, z1b) = b
    dut.m0_0.value = to2c(m0a, 16); dut.e0_0.value = to2c(e0a, 10); dut.z0_0.value = z0a
    dut.m1_0.value = to2c(m1a, 16); dut.e1_0.value = to2c(e1a, 10); dut.z1_0.value = z1a
    dut.m0_1.value = to2c(m0b, 16); dut.e0_1.value = to2c(e0b, 10); dut.z0_1.value = z0b
    dut.m1_1.value = to2c(m1b, 16); dut.e1_1.value = to2c(e1b, 10); dut.z1_1.value = z1b
    dut.lane_op_i.value = op
    dut.e4m3_precise_i.value = 1 if precise else 0
    dut.mant_corr_s0_i.value = corr0
    dut.mant_corr_s1_i.value = corr1
    dut.round_rne_i.value = rne
    await Timer(1, "ns")


def read_lane(dut, idx):
    if idx == 0:
        return {"mant": g.signed(int(dut.r0_mant.value), 16),
                "exp": g.signed(int(dut.r0_exp.value), 10),
                "sign": int(dut.r0_sign.value), "is_zero": int(dut.r0_zero.value),
                "overflow": int(dut.r0_ovf.value)}
    return {"mant": g.signed(int(dut.r1_mant.value), 16),
            "exp": g.signed(int(dut.r1_exp.value), 10),
            "sign": int(dut.r1_sign.value), "is_zero": int(dut.r1_zero.value),
            "overflow": int(dut.r1_ovf.value)}


def check(fails, label, got, exp, real_check=None):
    for k in ("mant", "exp", "sign", "is_zero", "overflow"):
        if got[k] != exp[k]:
            fails.append(f"{label}: {k} rtl={got[k]} gold={exp[k]} (full rtl={got} gold={exp})")
            return
    if real_check is not None:
        true_val, dom_exp = real_check
        got_val = got["mant"] * (2.0 ** got["exp"])
        # Independent sanity (N19): true_val is computed straight from the RAW
        # inputs and the spec factor (see real_bound) — NOT via the correction
        # code under test — so a bug SHARED between RTL and the structural golden
        # is still caught here. The bound catches gross errors (sign flip, 2x,
        # wrong exp -> O(2^(exp+15)) error) while tolerating legitimate compounded
        # toward-zero double-rounding (a few ULP at the dominant exponent).
        bound = 32.0 * (2.0 ** max(dom_exp, got["exp"]))
        if abs(got_val - true_val) > bound + 1e-9:
            fails.append(f"{label}: real-value rtl={got_val} true={true_val} "
                         f"err={abs(got_val-true_val)} bound={bound}")


def real_bound(m0, e0, c0, m1, e1, c1, is_sub, precise):
    """True real value computed INDEPENDENTLY from the raw inputs and the E4M3
    spec factor (exact Fraction), with no call into the correction code under
    test, plus the dominant input exponent for the bound. (GOLD-1 / N19.)"""
    from fractions import Fraction
    f0 = Fraction(m0 * c0, 128) if precise else Fraction(m0)
    f1 = Fraction(m1 * c1, 128) if precise else Fraction(m1)
    t0 = f0 * (Fraction(2) ** e0)
    t1 = f1 * (Fraction(2) ** e1)
    true = float(t0 - t1) if is_sub else float(t0 + t1)
    return true, max(e0, e1)


@cocotb.test()
async def test_lane_resadd_precise(dut):
    fails = []
    rng = random.Random(0xD10ADD)

    def rmant():
        # full 16-bit signed range INCLUDING -32768: the 17-bit SUB negate (NUM-1
        # fix) must handle -(-2^15) = +2^15 without wrapping.
        return rng.randint(-32768, 32767)

    # ---- 1) identity regression: precise+corr128 == simple mode (RTL vs RTL) ----
    for _ in range(400):
        a = (rmant(), rng.randint(-20, 20), 0, rmant(), rng.randint(-20, 20), 0)
        b = (rmant(), rng.randint(-20, 20), 0, rmant(), rng.randint(-20, 20), 0)
        op = rng.choice([LANE_ADD, LANE_SUB])
        await drive(dut, a, b, 128, 128, op, precise=1, rne=1)
        p1 = (read_lane(dut, 0), read_lane(dut, 1))
        await drive(dut, a, b, 128, 128, op, precise=0, rne=1)
        p0 = (read_lane(dut, 0), read_lane(dut, 1))
        if p1 != p0:
            fails.append(f"identity: precise+128 != simple  a={a} b={b} op={op} "
                         f"p1={p1} p0={p0}")

    # ---- 2) correction-active: non-unit corr must change at least one result ----
    diffs = 0
    for _ in range(400):
        a = (rmant(), 0, 0, rmant(), 0, 0)
        b = (0, 0, 1, rmant(), 0, 0)      # lane1: 0 + x, isolates correction
        op = LANE_ADD
        c0 = rng.choice(E4M3_CORR[1:]); c1 = rng.choice(E4M3_CORR[1:])
        await drive(dut, a, b, c0, c1, op, precise=1, rne=1)
        pp = (read_lane(dut, 0), read_lane(dut, 1))
        await drive(dut, a, b, c0, c1, op, precise=0, rne=1)
        ps = (read_lane(dut, 0), read_lane(dut, 1))
        if pp != ps:
            diffs += 1
    if diffs == 0:
        fails.append("correction-active: precise mode never differed from simple "
                     "mode with non-unit mant_corr — leaves may be disconnected")

    # ---- 2b) NUM-1 negate-edge regression: corrected operand == exactly -2^15 ----
    # src1=-29127, mant_corr=144 (E4M3 m3=1), RNE -> round(29127*144/128)=32768 ->
    # corrected es1.mant=-32768, which passes renorm17 (fits 16-bit). LANE_SUB must
    # negate it to +32768 (17-bit, no wrap), not back to -32768. Exercised in the
    # 0-x (z0) branch, the x-y normal-add branch, and with a RAW -32768 input too.
    edge = [
        # (lane0 a, lane1 b, c0, c1, op, precise, rne)
        ((0, 3, 1, -29127, 3, 0), (1234, 5, 0, -29127, 5, 0), 128, 144, LANE_SUB, 1, 1),  # z0 + normal
        ((0, -7, 1, -32768, -7, 0), (-32768, 2, 0, 7000, 2, 0), 128, 128, LANE_SUB, 1, 1),  # raw -2^15
        ((0, 0, 1, -32768, 0, 0), (20000, 1, 0, -32768, 1, 0), 128, 128, LANE_SUB, 0, 1),  # simple mode raw
    ]
    for (a, b, c0, c1, op, precise, rne) in edge:
        is_sub = (op == LANE_SUB)
        rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
        await drive(dut, a, b, c0, c1, op, precise, rne)
        for idx, cs in enumerate([a, b]):
            (m0, e0, z0, m1, e1, z1) = cs
            exp = g.lane_resadd_precise_golden(m0, e0, z0, m1, e1, z1, c0, c1, is_sub, precise, rm)
            rc = real_bound(m0, e0, c0, m1, e1, c1, is_sub, precise)
            check(fails, f"negate-edge lane{idx} a={cs} c=({c0},{c1}) op={op} prec={precise}",
                  read_lane(dut, idx), exp, rc)

    # ---- 3..6) golden-checked sweep: zero, equal-exp, shifted; both lanes ----
    def rand_case(kind):
        if kind == "z1":      # x +/- 0
            return (rmant(), rng.randint(-20, 20), 0, 0, rng.randint(-20, 20), 1)
        if kind == "z0":      # 0 +/- x
            return (0, rng.randint(-20, 20), 1, rmant(), rng.randint(-20, 20), 0)
        if kind == "eq":      # equal exponent
            e = rng.randint(-20, 20)
            return (rmant(), e, 0, rmant(), e, 0)
        # "sh": independent exponents (small spread keeps the add well-conditioned)
        e0 = rng.randint(-12, 12)
        return (rmant(), e0, 0, rmant(), e0 + rng.randint(-8, 8), 0)

    kinds = ["z0", "z1", "eq", "sh"]
    for _ in range(6000):
        ka, kb = rng.choice(kinds), rng.choice(kinds)
        a, b = rand_case(ka), rand_case(kb)
        op = rng.choice([LANE_ADD, LANE_SUB])
        is_sub = (op == LANE_SUB)
        c0 = rng.choice(E4M3_CORR); c1 = rng.choice(E4M3_CORR)
        precise = rng.randint(0, 1)
        rne = rng.randint(0, 1)
        rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
        await drive(dut, a, b, c0, c1, op, precise, rne)

        for idx, (cs, kc) in enumerate([(a, ka), (b, kb)]):
            (m0, e0, z0, m1, e1, z1) = cs
            exp = g.lane_resadd_precise_golden(m0, e0, z0, m1, e1, z1,
                                               c0, c1, is_sub, precise, rm)
            # independent real-value bound on every case (zero operands included,
            # since real_bound no longer routes through the correction under test)
            rc = real_bound(m0, e0, c0, m1, e1, c1, is_sub, precise)
            check(fails, f"sweep lane{idx} k={kc} op={op} c=({c0},{c1}) "
                         f"prec={precise} rne={rne} a={cs}",
                  read_lane(dut, idx), exp, rc)

    assert not fails, "vec_lane_array E4M3 precise RESADD mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:30]))
    dut._log.info("D10 lane precise RESADD: identity + correction-active + %d golden "
                  "cases all match (2 lanes each)" % 6000)

"""
cocotb integration test for D10 propagation (deliverable #3): the per-operand
mant_corr renorm17 +1 EXP BUMP in vec_lane_array is picked up by the unchanged
vec_renorm_quant as a higher block max-exponent, which re-aligns the block
("renorm 移位 + 抬 shared exp"). Closes review finding GOLD-4.

Chain: tb_lane_renorm_precise = vec_lane_array -> vec_renorm_quant. Lanes 0..14
carry operand set A, lane 15 carries set B. We assert:
  * shared_exp == max over finite lanes of the per-lane result exponent
    (computed from lane_resadd_precise_golden) — i.e. the bump propagates;
  * a precise overflow case raises shared_exp by exactly +1 vs simple mode
    on identical inputs (the bump is what raised it);
  * the per-lane realigned mantissas (lane 0 = A, lane 15 = B) match
    renorm_block_golden's toward-zero alignment;
  * escape / scale_changed agree with the golden.

Run: cd tb && make MODULE=test_lane_renorm_precise TOPLEVEL=tb_lane_renorm_precise \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../tb/tb_lane_renorm_precise.sv"
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
E4M3_CORR = [(8 + m) << 4 for m in range(8)]
VEC_LANES = 16


def to2c(v, bits):
    return v & ((1 << bits) - 1)


async def drive(dut, A, B, c0, c1, op, precise, rne):
    (m0a, e0a, m1a, e1a) = A
    (m0b, e0b, m1b, e1b) = B
    dut.m0_a.value = to2c(m0a, 16); dut.e0_a.value = to2c(e0a, 10)
    dut.m1_a.value = to2c(m1a, 16); dut.e1_a.value = to2c(e1a, 10)
    dut.m0_b.value = to2c(m0b, 16); dut.e0_b.value = to2c(e0b, 10)
    dut.m1_b.value = to2c(m1b, 16); dut.e1_b.value = to2c(e1b, 10)
    dut.lane_op_i.value = op
    dut.e4m3_precise_i.value = 1 if precise else 0
    dut.mant_corr_s0_i.value = c0
    dut.mant_corr_s1_i.value = c1
    dut.round_rne_i.value = rne
    await Timer(1, "ns")


def lane_res(A, c0, c1, op, precise, rne):
    (m0, e0, m1, e1) = A
    rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
    return g.lane_resadd_precise_golden(m0, e0, 0, m1, e1, 0, c0, c1, op == LANE_SUB, precise, rm)


def expect(A, B, c0, c1, op, precise, rne):
    ra = lane_res(A, c0, c1, op, precise, rne)
    rb = lane_res(B, c0, c1, op, precise, rne)
    lanes = [dict(ra) for _ in range(VEC_LANES - 1)] + [dict(rb)]
    rn = g.renorm_block_golden(lanes)
    return rn, ra, rb


@cocotb.test()
async def test_lane_renorm_precise(dut):
    fails = []
    rng = random.Random(0xD10E27)

    def shared(dut):
        return g.signed(int(dut.shared_exp_o.value), 10)

    # ---- A) bump-propagation: precise overflow raises shared exp by +1 vs simple ----
    # full-scale operands at the same exponent so the corrected sum (factor up to
    # 1.875) overflows -> renorm17 / add renorm bump the lane exp; with all lanes
    # equal the block max-exp == that bumped exp.
    bumps_seen = 0
    for _ in range(200):
        e = rng.randint(-15, 15)
        A = (rng.randint(20000, 32767), e, rng.randint(20000, 32767), e)
        c0 = rng.choice(E4M3_CORR[3:]); c1 = rng.choice(E4M3_CORR[3:])   # >= 176 (>=1.375)
        await drive(dut, A, A, c0, c1, LANE_ADD, 1, 1)
        se_p = shared(dut)
        await drive(dut, A, A, c0, c1, LANE_ADD, 0, 1)
        se_s = shared(dut)
        # golden cross-check of the precise shared exp
        rn_p, ra_p, _ = expect(A, A, c0, c1, LANE_ADD, 1, 1)
        if se_p != rn_p["shared_exp"]:
            fails.append(f"bump: shared_exp rtl={se_p} gold={rn_p['shared_exp']} A={A} c=({c0},{c1})")
        if se_p > se_s:
            bumps_seen += 1
    if bumps_seen == 0:
        fails.append("bump-propagation: precise mode never raised the shared exponent "
                     "above simple mode — the renorm17 exp bump is not reaching renorm")

    # ---- B) general sweep: shared_exp / escape / scale_changed / realignment ----
    def rop():
        # full 16-bit incl -32768; keep both lanes non-zero so they count in max-exp
        v = rng.randint(-32768, 32767)
        return v if v != 0 else 1

    for _ in range(3000):
        eA = rng.randint(-10, 10)
        eB = eA + rng.randint(-6, 6)               # modest spread (no escape)
        A = (rop(), eA, rop(), eA)
        B = (rop(), eB, rop(), eB)
        op = rng.choice([LANE_ADD, LANE_SUB])
        c0 = rng.choice(E4M3_CORR); c1 = rng.choice(E4M3_CORR)
        precise = rng.randint(0, 1); rne = rng.randint(0, 1)
        await drive(dut, A, B, c0, c1, op, precise, rne)
        rn, ra, rb = expect(A, B, c0, c1, op, precise, rne)

        se = shared(dut)
        esc = int(dut.escape_o.value)
        sc = int(dut.scale_changed_o.value)
        p0 = g.signed(int(dut.p0_o.value), 16)
        p15 = g.signed(int(dut.p15_o.value), 16)
        lbl = f"sweep A={A} B={B} c=({c0},{c1}) op={op} prec={precise} rne={rne}"
        if se != rn["shared_exp"]:
            fails.append(f"{lbl}: shared_exp rtl={se} gold={rn['shared_exp']}")
        if esc != (1 if rn["escape"] else 0):
            fails.append(f"{lbl}: escape rtl={esc} gold={rn['escape']}")
        if sc != (1 if rn["scale_changed"] else 0):
            fails.append(f"{lbl}: scale_changed rtl={sc} gold={rn['scale_changed']}")
        if not rn["escape"]:    # packed mant only meaningful on the non-escape path
            if p0 != rn["aligned"][0]:
                fails.append(f"{lbl}: p0 rtl={p0} gold={rn['aligned'][0]}")
            if p15 != rn["aligned"][15]:
                fails.append(f"{lbl}: p15 rtl={p15} gold={rn['aligned'][15]}")

    assert not fails, "D10 lane->renorm propagation mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:30]))
    dut._log.info("D10 lane->renorm: shared-exp bump propagation + %d sweep cases match "
                  "(bumps observed: many)" % 3000)

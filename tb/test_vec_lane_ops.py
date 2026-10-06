"""
cocotb regression for vec_lane_array LANE_MAX / LANE_ABS / LANE_SIGN_INJ
(TIER-2 silent-value fixes, HW review 2026-06-20).

Two confirmed corners on these (currently non-MVP) lane ops:

1. LANE_MAX (VEC_MAX_ELEM) used a SIGN-BLIND exponent-first compare for two
   finite operands of differing exponent: a large-magnitude NEGATIVE at a high
   exponent wrongly beat a small POSITIVE at a low exponent (e.g.
   max(+1*2^2, -100*2^8) returned the -100*2^8 operand). Even same-sign it was
   wrong for un-normalized block-float (+1000*2^5 vs +1*2^10). Fix: align the
   lower-exp operand to the higher exponent then compare as a signed value.

2. LANE_ABS / LANE_SIGN_INJ negated a 16-bit signed mantissa in 16 bits, so an
   operand of exactly -2^15 (0x8000) wrapped to itself, producing a result whose
   mantissa bit15=1 while sign=0 (an unrepresentable +2^15 with inconsistent
   sign — silent corruption). Fix: negate in a 17-bit domain and renorm
   (>>1, exp+1), lossless and consistent (same NUM-1 pattern as LANE_SUB/D10).

(LANE_CLAMP was also flagged but its -2^15 case is unreachable: the clamp branch
requires abs0 > abs_thresh and abs_thresh==0x8000 is the maximum magnitude, so
nothing can exceed it — left unchanged.)

Harness: reuses tb_lane_resadd_precise (flattens vec_lane_array, lane 0 driven).
Oracle: independent plain-Python value math (Fraction-exact).

Run: cd tb && make MODULE=test_vec_lane_ops TOPLEVEL=tb_lane_resadd_precise \
  VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
  ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
  ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../tb/tb_lane_resadd_precise.sv"
"""
from fractions import Fraction

import cocotb
from cocotb.triggers import Timer

LANE_ABS = 2
LANE_CLAMP = 3
LANE_MAX = 4
LANE_SIGN_INJ = 8
LANE_MERGE_LO = 9
LANE_MERGE_HI = 10
LANE_SPLIT = 11
LANE_OP_RESERVED_13 = 13   # hole in vec_lane_op_e -> default arm


def to_u(x, w):
    return x & ((1 << w) - 1)


def to_s(x, w):
    x &= (1 << w) - 1
    return x - (1 << w) if x & (1 << (w - 1)) else x


def val(mant, exp):
    return Fraction(mant) * (Fraction(2) ** exp)


async def drive_lane0(dut, op, m0, e0, m1=0, e1=0, z0=0, z1=0):
    dut.lane_op_i.value = op
    dut.e4m3_precise_i.value = 0
    dut.mant_corr_s0_i.value = 128
    dut.mant_corr_s1_i.value = 128
    dut.round_rne_i.value = 0
    # lane 0
    dut.m0_0.value = to_u(m0, 16); dut.e0_0.value = to_u(e0, 10); dut.z0_0.value = z0
    dut.m1_0.value = to_u(m1, 16); dut.e1_0.value = to_u(e1, 10); dut.z1_0.value = z1
    # lane 1 (unused) -> zeros
    dut.m0_1.value = 0; dut.e0_1.value = 0; dut.z0_1.value = 1
    dut.m1_1.value = 0; dut.e1_1.value = 0; dut.z1_1.value = 1
    await Timer(1, "ns")
    return (to_s(int(dut.r0_mant.value), 16), to_s(int(dut.r0_exp.value), 10),
            int(dut.r0_sign.value))


# ───────────────────────── LANE_MAX ─────────────────────────
@cocotb.test()
async def test_lane_max_pos_beats_highexp_neg(dut):
    """max(+1*2^2, -100*2^8): the small POSITIVE is the max, not the high-exp neg."""
    m, e, s = await drive_lane0(dut, LANE_MAX, 1, 2, -100, 8)
    assert val(m, e) == val(1, 2), f"got {m}*2^{e}={float(val(m,e))}, expected +1*2^2=4"


@cocotb.test()
async def test_lane_max_samesign_crossexp(dut):
    """max(+1000*2^5=32000, +1*2^10=1024): larger VALUE wins despite lower exp."""
    m, e, s = await drive_lane0(dut, LANE_MAX, 1000, 5, 1, 10)
    assert val(m, e) == val(1000, 5), f"got {float(val(m,e))}, expected 32000"


@cocotb.test()
async def test_lane_max_equal_exp_guard(dut):
    """Equal-exp path (unchanged): larger signed mantissa wins."""
    m, e, s = await drive_lane0(dut, LANE_MAX, 5, 3, 9, 3)
    assert (m, e) == (9, 3), f"got ({m},{e}), expected (9,3)"


# ───────────────────────── LANE_ABS ─────────────────────────
@cocotb.test()
async def test_lane_abs_min_corner(dut):
    """|-2^15 * 2^e| must be the representable +2^15*2^e (renorm: 2^14 at e+1),
    NOT 0x8000 with sign=0 (the wrap)."""
    e0 = 3
    m, e, s = await drive_lane0(dut, LANE_ABS, -32768, e0)
    assert val(m, e) == val(1, 15 + e0), f"|−2^15·2^{e0}| wrong: {m}*2^{e}"
    assert s == 0 and m >= 0, f"sign/mant inconsistent: mant={m} sign={s}"


@cocotb.test()
async def test_lane_abs_normal(dut):
    """Ordinary negative: plain |x|, no exp change."""
    m, e, s = await drive_lane0(dut, LANE_ABS, -5, 7)
    assert (m, e, s) == (5, 7, 0), f"got ({m},{e},{s}), expected (5,7,0)"


# ──────────────────────── LANE_SIGN_INJ ─────────────────────
@cocotb.test()
async def test_lane_sign_inj_min_corner(dut):
    """Inject + sign onto -2^15: result = +2^15*2^e (renorm), sign consistent."""
    e0 = 2
    # src0.mant=-32768 (sign=1); src1 positive (m1=+1 -> src1.sign=0) -> flip
    m, e, s = await drive_lane0(dut, LANE_SIGN_INJ, -32768, e0, m1=1, e1=0)
    assert val(m, e) == val(1, 15 + e0), f"sign-inj corner wrong: {m}*2^{e}"
    assert s == 0 and m >= 0, f"sign/mant inconsistent: mant={m} sign={s}"


@cocotb.test()
async def test_lane_sign_inj_normal(dut):
    """Inject - sign onto +7: result = -7, sign=1."""
    m, e, s = await drive_lane0(dut, LANE_SIGN_INJ, 7, 4, m1=-1, e1=0)
    assert (m, e, s) == (-7, 4, 1), f"got ({m},{e},{s}), expected (-7,4,1)"


# ────────────── [C9 V3-3 guard, 2026-07-25] non-ADD small ops ──────────────
# WHY: CLAMP / MERGE_LO / MERGE_HI / SPLIT / default had ZERO tests anywhere in
# the project — a rewritten lane case statement that picked the wrong source
# bundle (or swapped s0/s1) stayed green through the whole suite. MERGE_HI is
# the ideal swap probe: it is the ONLY op whose result comes from src1.
# Oracle = frozen RTL semantics (value-preservation: lock in current behaviour).
# RED protocol (mutations applied to vec_lane_array.sv then reverted):
#   M3: LANE_MERGE_HI arm -> elem(src0)      => merge_hi test FAILS
#   M4: LANE_MERGE_LO arm -> elem(src1)      => merge_lo test FAILS
#   M5: LANE_SPLIT arm    -> elem(src1)      => split test FAILS
#   M6: CLAMP arm drops sign application     => clamp_fires_negative FAILS

@cocotb.test()
async def test_lane_merge_hi_takes_src1(dut):
    """MERGE_HI = elem(src1) exactly (the s0/s1 swap probe): (-9,2,sign=1)."""
    m, e, s = await drive_lane0(dut, LANE_MERGE_HI, 7, 4, m1=-9, e1=2)
    assert (m, e, s) == (-9, 2, 1), f"MERGE_HI must take src1: got ({m},{e},{s})"


@cocotb.test()
async def test_lane_merge_lo_takes_src0(dut):
    """MERGE_LO = elem(src0) exactly: (7,4,sign=0)."""
    m, e, s = await drive_lane0(dut, LANE_MERGE_LO, 7, 4, m1=-9, e1=2)
    assert (m, e, s) == (7, 4, 0), f"MERGE_LO must take src0: got ({m},{e},{s})"


@cocotb.test()
async def test_lane_split_passthrough(dut):
    """SPLIT passes src0 through UNCHANGED (mant AND exp).
    NOTE the RTL header comment says 'set lane index in exp field' but the
    implementation is a plain passthrough — this test locks in the ACTUAL
    frozen behaviour (consumers depend on exp surviving)."""
    m, e, s = await drive_lane0(dut, LANE_SPLIT, -123, 5, m1=44, e1=9)
    assert (m, e, s) == (-123, 5, 1), f"SPLIT must pass src0: got ({m},{e},{s})"


@cocotb.test()
async def test_lane_clamp_fires_negative(dut):
    """CLAMP |−500|>300: result = sign(src0)×|thresh| = −300, exp KEEPS src0's,
    overflow flag set."""
    m, e, s = await drive_lane0(dut, LANE_CLAMP, -500, 6, m1=300, e1=0)
    ovf = int(dut.r0_ovf.value)
    assert (m, e, s, ovf) == (-300, 6, 1, 1), \
        f"CLAMP(-500,thr=300): got (m={m},e={e},s={s},ovf={ovf}), expected (-300,6,1,1)"


@cocotb.test()
async def test_lane_clamp_negative_threshold(dut):
    """CLAMP uses |src1.mant| as threshold: thresh=-300 behaves like +300."""
    m, e, s = await drive_lane0(dut, LANE_CLAMP, 500, 6, m1=-300, e1=0)
    ovf = int(dut.r0_ovf.value)
    assert (m, e, s, ovf) == (300, 6, 0, 1), \
        f"CLAMP(+500,thr=-300): got (m={m},e={e},s={s},ovf={ovf}), expected (300,6,0,1)"


@cocotb.test()
async def test_lane_clamp_no_fire(dut):
    """|src0| <= thresh: pure passthrough, overflow=0."""
    m, e, s = await drive_lane0(dut, LANE_CLAMP, 200, 6, m1=300, e1=0)
    ovf = int(dut.r0_ovf.value)
    assert (m, e, s, ovf) == (200, 6, 0, 0), \
        f"CLAMP no-fire: got (m={m},e={e},s={s},ovf={ovf}), expected (200,6,0,0)"


@cocotb.test()
async def test_lane_reserved_op_passthrough(dut):
    """Reserved opcode 13 lands in the default arm = elem(src0) passthrough."""
    m, e, s = await drive_lane0(dut, LANE_OP_RESERVED_13, 55, 3, m1=-7, e1=1)
    assert (m, e, s) == (55, 3, 0), f"default arm must pass src0: got ({m},{e},{s})"

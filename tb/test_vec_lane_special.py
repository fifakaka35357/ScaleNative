"""
cocotb regression for vec_lane_array NaN/Inf special-value semantics in
LANE_ADD / LANE_SUB — the §C9 V3 blind spot #1 (2026-07-25).

WHY this did not exist: no TB in the project drove is_nan/is_inf into the lane
array (tb_lane_resadd_precise forces them to 0 and cannot express a NaN with
sign=1, since it hardwires sign = mant[15] and NaN mantissas are 0). So the
special-value branches (vec_lane_array.sv:331-362) and the default `.sign`
fall-through (:164-171 — the NaN arm deliberately does NOT write sign, relying
on the default assignment from src0) could be moved across a register boundary
wrongly and the whole 144/51 suite stayed green.

WHY it matters NOW: C9 (C-minimal shift-control cut) re-partitions the
LANE_ADD/SUB cone between PH_MC and PH_LANE. If the cut re-derives the special
branches from partially-registered operands, sign/flag transport breaks — these
tests are the teeth for exactly that.

Oracle: hand-derived from the FROZEN RTL semantics (value-preservation
discipline: lock in current behaviour, do not "fix" it):
  * NaN arm: is_nan=1, mant=0, exp=0; sign NOT written -> falls through to
    default = src0.sign (raw src0, even when the NaN is on src1).
  * es0 Inf arm: result = elem(es0)  (inf flag, sign=es0.sign, mant/exp pass).
  * es1 Inf arm: is_inf=1, mant=0, exp=0, sign = (SUB ? ~es1.sign : es1.sign).
  * Inf+Inf: same_sign (ADD: s0==s1, SUB: s0!=s1) -> Inf sign=es0.sign;
    opposite -> NaN (sign falls through to src0.sign).
All cases use e4m3_precise_i=0 (es == raw src, identity prep).

RED protocol (2026-07-25, mutations applied to vec_lane_array.sv then reverted):
  M1: NaN arm += `result_o[g].sign = 1'b0;`   -> sign fall-through cases FAIL
  M2: es1-Inf arm sign := es1.sign (drop ~ for SUB) -> sub_normal_minus_inf FAILS

Run: cd tb && make MODULE=test_vec_lane_special TOPLEVEL=tb_lane_special \
  VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
  ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
  ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../tb/tb_lane_special.sv"
"""
import cocotb
from cocotb.triggers import Timer

LANE_ADD = 5
LANE_SUB = 6


def to_u(x, w):
    return x & ((1 << w) - 1)


def to_s(x, w):
    x &= (1 << w) - 1
    return x - (1 << w) if x & (1 << (w - 1)) else x


async def drive(dut, op, a, b):
    """a/b = dicts for lane0 src0/src1: m,e,s,z,n,i (missing keys default 0)."""
    dut.lane_op_i.value = op
    dut.e4m3_precise_i.value = 0
    dut.mant_corr_s0_i.value = 128
    dut.mant_corr_s1_i.value = 128
    dut.round_rne_i.value = 0
    for pfx, d in (("0", a), ("1", b)):
        getattr(dut, "m%s_0" % pfx).value = to_u(d.get("m", 0), 16)
        getattr(dut, "e%s_0" % pfx).value = to_u(d.get("e", 0), 10)
        getattr(dut, "s%s_0" % pfx).value = d.get("s", 0)
        getattr(dut, "z%s_0" % pfx).value = d.get("z", 0)
        getattr(dut, "n%s_0" % pfx).value = d.get("n", 0)
        getattr(dut, "i%s_0" % pfx).value = d.get("i", 0)
        # lane 1 idle (zero elements)
        getattr(dut, "m%s_1" % pfx).value = 0
        getattr(dut, "e%s_1" % pfx).value = 0
        getattr(dut, "s%s_1" % pfx).value = 0
        getattr(dut, "z%s_1" % pfx).value = 1
        getattr(dut, "n%s_1" % pfx).value = 0
        getattr(dut, "i%s_1" % pfx).value = 0
    await Timer(1, "ns")
    return dict(mant=to_s(int(dut.r0_mant.value), 16), exp=to_s(int(dut.r0_exp.value), 10),
                sign=int(dut.r0_sign.value), zero=int(dut.r0_zero.value),
                nan=int(dut.r0_nan.value), inf=int(dut.r0_inf.value))


NAN_NEG = dict(m=0, e=0, s=1, n=1)   # NaN carrying sign=1 (inexpressible in the old harness)
NAN_POS = dict(m=0, e=0, s=0, n=1)
INF_POS = dict(m=0, e=0, s=0, i=1)
INF_NEG = dict(m=0, e=0, s=1, i=1)


# ───────────── NaN arm: sign falls through from RAW src0 ─────────────
@cocotb.test()
async def test_add_nan_src0_sign_fallthrough(dut):
    """NaN(sign=1) + normal: is_nan=1, mant=exp=0, sign=1 (src0.sign fall-through)."""
    r = await drive(dut, LANE_ADD, NAN_NEG, dict(m=5, e=3))
    assert (r["nan"], r["inf"], r["mant"], r["exp"]) == (1, 0, 0, 0), r
    assert r["sign"] == 1, "NaN sign fall-through broken (expected src0.sign=1): %r" % r
    r = await drive(dut, LANE_ADD, NAN_POS, dict(m=5, e=3))
    assert (r["nan"], r["sign"]) == (1, 0), r


@cocotb.test()
async def test_add_nan_src1_sign_is_src0s(dut):
    """normal + NaN: is_nan=1; sign = src0.sign (default fall-through, NOT src1's)."""
    r = await drive(dut, LANE_ADD, dict(m=-5, e=3, s=1), NAN_POS)
    assert (r["nan"], r["inf"], r["mant"], r["exp"]) == (1, 0, 0, 0), r
    assert r["sign"] == 1, "NaN-on-src1: sign must fall through from src0 (=1): %r" % r
    r = await drive(dut, LANE_SUB, dict(m=5, e=3, s=0), NAN_NEG)
    assert (r["nan"], r["sign"]) == (1, 0), r


# ───────────── Inf arms: direction transport ─────────────
@cocotb.test()
async def test_add_inf_src0(dut):
    """±Inf + normal = ±Inf (result = elem(es0): sign/mant/exp pass from src0)."""
    r = await drive(dut, LANE_ADD, INF_NEG, dict(m=7, e=2))
    assert (r["inf"], r["nan"], r["sign"], r["mant"], r["exp"]) == (1, 0, 1, 0, 0), r
    r = await drive(dut, LANE_ADD, INF_POS, dict(m=7, e=2))
    assert (r["inf"], r["sign"]) == (1, 0), r


@cocotb.test()
async def test_add_normal_plus_inf(dut):
    """normal + ±Inf = ±Inf (sign = es1.sign for ADD)."""
    r = await drive(dut, LANE_ADD, dict(m=7, e=2), INF_NEG)
    assert (r["inf"], r["nan"], r["sign"], r["mant"], r["exp"]) == (1, 0, 1, 0, 0), r
    r = await drive(dut, LANE_ADD, dict(m=7, e=2), INF_POS)
    assert (r["inf"], r["sign"]) == (1, 0), r


@cocotb.test()
async def test_sub_normal_minus_inf(dut):
    """normal - (+Inf) = -Inf; normal - (-Inf) = +Inf  (sign = ~es1.sign for SUB)."""
    r = await drive(dut, LANE_SUB, dict(m=7, e=2), INF_POS)
    assert (r["inf"], r["nan"], r["sign"]) == (1, 0, 1), \
        "SUB inf sign inversion broken: %r" % r
    r = await drive(dut, LANE_SUB, dict(m=7, e=2), INF_NEG)
    assert (r["inf"], r["sign"]) == (1, 0), r


@cocotb.test()
async def test_inf_inf_combos(dut):
    """Inf+Inf same dir -> Inf(src0.sign); opposite dir -> NaN. SUB flips src1 dir.

    FROZEN-SEMANTICS QUIRK (do not 'fix' the expectation): in the Inf±Inf arm
    the NaN outcome sets is_nan=1 but does NOT clear is_inf — and the default
    assignment already loaded is_inf = src0.is_inf = 1. So Inf+(-Inf) yields
    {is_nan=1, is_inf=1}: consumers must check is_nan FIRST (they do — the NaN
    branches everywhere have priority). A cut that 'cleans this up' changes
    observable flags; this test pins the current encoding."""
    r = await drive(dut, LANE_ADD, INF_POS, INF_POS)
    assert (r["inf"], r["nan"], r["sign"]) == (1, 0, 0), r
    r = await drive(dut, LANE_ADD, INF_NEG, INF_NEG)
    assert (r["inf"], r["nan"], r["sign"]) == (1, 0, 1), r
    r = await drive(dut, LANE_ADD, INF_POS, INF_NEG)
    assert (r["nan"], r["inf"], r["sign"]) == (1, 1, 0), \
        "Inf + (-Inf): NaN with leftover inf flag + src0.sign fall-through: %r" % r
    # SUB: same raw signs == opposite effective dirs -> NaN (same leftover-inf quirk)
    r = await drive(dut, LANE_SUB, INF_POS, INF_POS)
    assert (r["nan"], r["inf"], r["sign"]) == (1, 1, 0), "Inf - Inf must be NaN: %r" % r
    # SUB: opposite raw signs == same effective dirs -> Inf, sign = es0.sign
    r = await drive(dut, LANE_SUB, INF_POS, INF_NEG)
    assert (r["inf"], r["nan"], r["sign"]) == (1, 0, 0), r

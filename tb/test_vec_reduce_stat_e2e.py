"""
cocotb end-to-end regression for REDUCE_STAT (VEC_RMSNORM_PARTIAL) through the REAL
vector_unit — S-STAT v1.2 block16 / block32 (cross-pass combine).

Prereg: aichip_run_logs/soc600_prereg_20260902.md §70 (待-2 / #285 ⑬⑭) + §74.1 (scheme C,
O-IB; §74.1 wins over §70 where they differ). Harness = tb_vec_reduce_stat_e2e.sv:
vector_unit driven on desc_i (the command path cannot reach RMSNORM_PARTIAL — CP wiring is
out of scope, §70.1), SRC0 capsules on t2v with an E8M0 scale on the absolute-exponent path
(scale_ref = signed block exponent), result on the keep-local L2 write
(payload[20:0] = mant, payload[30:21] = exp, rest 0), is_nan / is_inf read by hierarchical
reference from u_vu.result_cap_q.status_flags[1:0] (§70.3 MINOR-5; a missing field fails
elaboration — fail-closed).

An e2e lane is (payload lane16, block exponent of its capsule) with is_zero = (lane16 == 0):
every pass must be "one exponent, zero lanes carry it, no NaN/Inf" (checked per vector, a
non-realizable vector is a test defect). The expectation is Model/bfp_golden.py
stat_sumsq_golden on the REALIZED lanes (== the prereg table value, also checked).

Seven tests (prereg §70.3; grouping of the design draft):
  block16 subset (B1a B1d B1f B2b B3a B3c B3e B5b B5c B6b B6c B8) · one pass all-zero
  (X1 X2 X12) · exponent-sign boundaries (X3 X3b X3c X4) · cross-pass sticky (X5) ·
  16/32 consistency (X6 X8 X9 X11 + C1/C2/C3 relations) · combined overflow (X7) ·
  random e2e_U (seed 0x5A7C x 64, all block32).
Status flags are part of every compared tuple (X1, X2, X7 and the random group included).

STATVEC side channel: identical contract to test_vec_reduce_stat.py — collect first, assert
at the end, append to $AICHIP_STATVEC_DIR/test_vec_reduce_stat_e2e.txt when set:
  STATVEC-GEN test_vec_reduce_stat_e2e <test> set=e2e_U seed=0x5A7C n=64 md5=<GEN_MD5>
  STATVEC test_vec_reduce_stat_e2e <test> <id> rtl=M,E,nan,inf exp=M,E,nan,inf harness=OK|BAD OK|BAD
(rtl=NONE when the vector produced no result). harness= covers harness / protocol problems only
(not e2e-realizable, descriptor / capsule not accepted, MISS, err_valid, RO request, v2t egress,
no done within 400 cycles, write count / row / mask, payload bits above [30:0]) and is independent
of any value mismatch: the J1 run on the pre-fix RTL must see harness=OK on every vector, so a
broken harness is caught there instead of surfacing as an RTL failure in J2 (I3 review MINOR-2).
The last field covers everything. The C1/C2/C3 relation checks emit no
STATVEC line (they are asserted in-test only; the judge's id set is the prereg's).

Run: cd tb && make MODULE=test_vec_reduce_stat_e2e TOPLEVEL=tb_vec_reduce_stat_e2e \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv \
        ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv \
        ../rtl/Vector/vec_assertions.sv \
        ../tb/tb_vec_reduce_stat_e2e.sv"
"""
import hashlib
import inspect
import os
import sys

import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Model"))
import bfp_golden as g  # noqa: E402

MODULE = "test_vec_reduce_stat_e2e"
E2E_SET = ("e2e_U", 0x5A7C, 64)          # prereg §74.1.5 JSON `random.e2e_U`
DST_ROW = 0x040


def _sx(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def _gen_md5():
    return hashlib.md5(inspect.getsource(g.stat_random_vectors).encode()).hexdigest()


def realize(p):
    """One pass -> (payload, block exponent, realized lanes) or raise ValueError (not e2e-realizable)."""
    if len(p) != 16:
        raise ValueError("pass has %d lanes" % len(p))
    if any(l["is_nan"] or l["is_inf"] for l in p):
        raise ValueError("NaN / Inf lane cannot be produced by an E8M0 abs capsule")
    if any((l["mant"] == 0) != bool(l["is_zero"]) for l in p):
        raise ValueError("is_zero must equal (mant == 0) on the e2e path")
    exps = {l["exp"] for l in p if l["mant"] != 0}
    if len(exps) > 1:
        raise ValueError("non-zero lanes carry %d exponents (e2e has one block exponent)" % len(exps))
    blk = exps.pop() if exps else p[0]["exp"]
    if not -512 <= blk <= 511:
        raise ValueError("block exponent %d outside [-512, 511]" % blk)
    payload = 0
    for i, l in enumerate(p):
        payload |= (l["mant"] & 0xFFFF) << (16 * i)
    lanes = [dict(mant=l["mant"], exp=blk, is_zero=int(l["mant"] == 0), is_nan=0, is_inf=0) for l in p]
    return payload, blk, lanes


async def reset(dut):
    for s in ("desc_valid_i", "block32_i", "dst_row_i", "tag_i", "cap_valid_i",
              "cap_payload_i", "cap_scale_ref_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def start(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)


async def run_vector(dut, reals, tag):
    """Issue one RMSNORM_PARTIAL (block16 = 1 capsule, block32 = 2) and capture the result.
    Returns (rtl tuple or None, [problems])."""
    probs = []
    dut.block32_i.value = 1 if len(reals) == 2 else 0
    dut.dst_row_i.value = DST_ROW
    dut.tag_i.value = tag & 7
    dut.desc_valid_i.value = 1
    ok = False
    for _ in range(50):
        await RisingEdge(dut.clk_i)
        if int(dut.desc_ready_o.value) == 1:
            ok = True
            break
    dut.desc_valid_i.value = 0
    if not ok:
        return None, ["descriptor never accepted"]
    await FallingEdge(dut.clk_i)
    for k, (payload, blk, _) in enumerate(reals):
        dut.cap_payload_i.value = payload
        dut.cap_scale_ref_i.value = blk & 0xFFFF
        dut.cap_valid_i.value = 1
        acc = False
        for _ in range(60):
            await RisingEdge(dut.clk_i)
            if int(dut.miss_valid_o.value) == 1:
                probs.append("capsule %d MISS reason=%d" % (k, int(dut.miss_reason_o.value)))
                break
            if int(dut.cap_ready_o.value) == 1:
                acc = True
                break
        dut.cap_valid_i.value = 0
        if not acc:
            probs.append("capsule %d never accepted" % k)
            return None, probs
        await FallingEdge(dut.clk_i)
    writes, done = [], False
    for _ in range(400):
        await FallingEdge(dut.clk_i)
        if int(dut.err_valid_o.value) == 1:
            probs.append("err_valid_o (code %d)" % int(dut.err_code_o.value))
        if int(dut.ro_req_o.value) == 1:
            probs.append("unexpected L2 RO request")
        if int(dut.v2t_valid_o.value) == 1:
            probs.append("unexpected v2t egress (result must stay keep-local)")
        if int(dut.rw_req_o.value) == 1:                       # rw_gnt is tied 1
            writes.append((int(dut.rw_row_o.value), int(dut.rw_bank_mask_o.value),
                           int(dut.rw_wdata_o.value), int(dut.cap_status_flags_o.value)))
        if int(dut.done_o.value) == 1:
            done = True
            break
    if not done:
        probs.append("no done_o within 400 cycles")
    if len(writes) != 1:
        probs.append("expected exactly 1 L2 write (scalar reduce result), got %d" % len(writes))
        return None, sorted(set(probs))
    row, mask, wdata, sf = writes[0]
    if row != DST_ROW:
        probs.append("write row 0x%x != dst 0x%x" % (row, DST_ROW))
    if mask != 0xFFFF:
        probs.append("write mask 0x%04x != 0xFFFF" % mask)
    if wdata >> 31:
        probs.append("payload bits above [30:0] are not zero (0x%x)" % (wdata >> 31))
    rtl = (_sx(wdata, 21), _sx(wdata >> 21, 10), sf & 1, (sf >> 1) & 1)
    return rtl, sorted(set(probs))


def _statvec_lines(lines):
    d = os.environ.get("AICHIP_STATVEC_DIR")
    if not d:
        return None
    d = os.path.realpath(d)
    here = os.path.realpath(os.path.dirname(os.path.abspath(__file__)))
    if d == here or d.startswith(here + os.sep):
        return "AICHIP_STATVEC_DIR=%s lies inside the tb directory %s (run_all cleans sim_build; " \
               "the side channel must live outside it)" % (d, here)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, MODULE + ".txt"), "a", encoding="utf-8") as f:
        for ln in lines:
            f.write(ln + "\n")
    return None


def _t(x):
    return "NONE" if x is None else ",".join(str(v) for v in x)


async def run_set(dut, test, items, gen=None, extra=None):
    """items = [(id, passes, table_expect_or_None)]; extra = async fn(dut, results) -> [failures]
    for in-test relation checks. Collect everything, write STATVEC, then assert."""
    await start(dut)
    fails, lines, results = [], [], {}
    if gen is not None:
        lines.append("STATVEC-GEN %s %s set=%s seed=0x%X n=%d md5=%s" % (MODULE, test, gen[0], gen[1], gen[2], _gen_md5()))
    for n, (vid, passes, texp) in enumerate(items):
        harness, bad = [], []
        try:
            reals = [realize(p) for p in passes]
        except ValueError as e:
            reals, harness = None, ["not e2e-realizable: %s" % e]
        exp = rtl = None
        if reals is not None:
            exp = tuple(g.stat_sumsq_golden([r[2] for r in reals]))
            if texp is not None and tuple(texp) != exp:
                bad.append("golden on realized lanes %s != table %s" % (exp, tuple(texp)))
            rtl, probs = await run_vector(dut, reals, n)
            harness += probs
            if rtl != exp:
                bad.append("rtl %s != golden %s" % (_t(rtl), _t(exp)))
        bad = harness + bad
        results[vid] = rtl
        lines.append("STATVEC %s %s %s rtl=%s exp=%s harness=%s %s"
                     % (MODULE, test, vid, _t(rtl), _t(exp), "BAD" if harness else "OK", "BAD" if bad else "OK"))
        if bad:
            fails.append("%s: %s" % (vid, "; ".join(bad)))
    if extra is not None:
        fails += await extra(dut, results)
    err = _statvec_lines(lines)
    if err:
        fails.insert(0, err)
    dut._log.info("%s: %d vectors, %d failures" % (test, len(items), len(fails)))
    assert not fails, "%s: %d failures:\n  %s" % (test, len(fails), "\n  ".join(fails[:40]))


def table_items(ids):
    H6 = g.STAT_H6_VECTORS
    return [(vid, H6[vid]["passes"], H6[vid]["expect"]) for vid in ids]


# ---------------------------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------------------------
@cocotb.test()
async def test_e2e_block16_subset(dut):
    """block16 (one pass, one capsule): zero identity, -32768, overflow -> O-IB Inf (flags), underflow, RNE tie."""
    await run_set(dut, "block16_subset", table_items(
        ["B1a", "B1d", "B1f", "B2b", "B3a", "B3c", "B3e", "B5b", "B5c", "B6b", "B6c", "B8"]))


@cocotb.test()
async def test_e2e_half_zero(dut):
    """F6: block32 with one all-zero pass (either order) and a far-below second pass (X12, pass1 re = -639)."""
    await run_set(dut, "half_zero", table_items(["X1", "X2", "X12"]))


@cocotb.test()
async def test_e2e_exp_sign(dut):
    """F5: cross-pass exponent difference of 512..600 (beyond 10 bits), both orders."""
    await run_set(dut, "exp_sign", table_items(["X3", "X3b", "X3c", "X4"]))


@cocotb.test()
async def test_e2e_sticky(dut):
    """Cross-pass sticky: the far pass decides an RNE tie (X5 -> 524289)."""
    await run_set(dut, "sticky", table_items(["X5"]))


async def _c123(dut, results):
    """C3: block32(A|A) = (M, E+1) of block16(A) (X6, X8); C1/C2: block32(A|Z) = block32(Z|A) = block16(A)
    (A = X9 pass 0). In-test relation checks on extra e2e runs (no STATVEC line)."""
    H6 = g.STAT_H6_VECTORS
    fails = []
    for vid in ("X6", "X8"):
        pa, pb = H6[vid]["passes"]
        if [dict(l) for l in pa] != [dict(l) for l in pb]:
            fails.append("C3 premise: %s is not A|A" % vid)
            continue
        r16, probs = await run_vector(dut, [realize(pa)], 100)
        r32 = results.get(vid)
        if probs or r16 is None or r32 is None:
            fails.append("C3 %s: block16 run %s %s / block32 %s" % (vid, _t(r16), probs, _t(r32)))
        elif not (r16[2] == r16[3] == 0 and r16[0] != 0 and r32[3] == 0 and r32 == (r16[0], r16[1] + 1, 0, 0)):
            fails.append("C3 %s: block32 %s != (M, E+1) of block16 %s" % (vid, _t(r32), _t(r16)))
    a = H6["X9"]["passes"][0]
    z = [dict(mant=0, exp=a[0]["exp"], is_zero=1, is_nan=0, is_inf=0) for _ in range(16)]
    r16, p16 = await run_vector(dut, [realize(a)], 101)
    raz, paz = await run_vector(dut, [realize(a), realize(z)], 102)
    rza, pza = await run_vector(dut, [realize(z), realize(a)], 103)
    if p16 or paz or pza or r16 is None or not (r16 == raz == rza):
        fails.append("C1/C2 (A = X9 pass 0): block16 %s / A|Z %s / Z|A %s (%s)" % (_t(r16), _t(raz), _t(rza), p16 + paz + pza))
    gold = tuple(g.stat_sumsq_golden([realize(a)[2]]))
    if r16 != gold:
        fails.append("C1/C2 block16(A) %s != golden %s" % (_t(r16), _t(gold)))
    return fails


@cocotb.test()
async def test_e2e_16_32_consistency(dut):
    """Block16 / block32 consistency: X6 X8 X9 X11 + C1/C2/C3 relations on extra runs."""
    await run_set(dut, "consistency_16_32", table_items(["X6", "X8", "X9", "X11"]), extra=_c123)


@cocotb.test()
async def test_e2e_combined_overflow(dut):
    """X7: each pass finite (B5c), the cross-pass sum overflows -> O-IB Inf code with is_inf flag."""
    await run_set(dut, "combined_overflow", table_items(["X7"]))


@cocotb.test()
async def test_e2e_random_U(dut):
    """Random e2e_U (seed 0x5A7C x 64, stratified over the full exponent range: own / shared /
    overflow band / flush band), all block32; flags compared on every vector."""
    name, seed, n = E2E_SET
    recs = g.stat_random_vectors(seed, n, name)
    assert len(recs) == n
    items = [("%s#%d" % (name, i), ps, None) for i, (tags, ps) in enumerate(recs)]
    await run_set(dut, "random_U", items, gen=E2E_SET)

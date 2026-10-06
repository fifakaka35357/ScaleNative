"""
cocotb regression for vec_reduce_cluster REDUCE_STAT (sum of squares) — S-STAT v1.2.

Prereg: aichip_run_logs/soc600_prereg_20260902.md §70 (待-2 / #285 ⑬⑭ numerical fix)
+ §74.1 (scheme C window, O-IB special values; §74.1 wins over §70 where they differ).
Module level: TOPLEVEL = vec_reduce_cluster, lanes driven directly (any lane value is
legal here, including non-U exponent spreads, NaN / Inf lanes and is_zero=0 & mant=0).

Oracle = Model/bfp_golden.py (computed at run time, never hand-typed):
  result_o (STAT)          == stat_sumsq_golden([lanes])          (S1-S8)
  (stat_raw_mant_o, _exp_o) == stat_raw_golden(lanes)              (S9; checked for EVERY
                              vector here, the prereg raw table ids are a subset)
  id vectors               == bfp_golden.STAT_H6_VECTORS (prereg §74.1.4 table, 41 module ids)
  random                   == bfp_golden.stat_random_vectors(seed, n, mode)
                              module_U 0x5A7A x 2000 / module_nonU 0x5A7B x 2000

Eight tests (prereg §70.3 / §74.1.2 Q-C7; ids grouped as in the design draft):
  zero identity (B1a-B1f, B2a, B2b) · max-negative mantissa (B3*) · spread / window (B4*) ·
  overflow / underflow (B5*, B6*) · special values (B7*) · rounding / funnel (B8*) ·
  random U · random non-U.

STATVEC side channel (prereg §70.3 MAJOR-1): every vector is collected FIRST and asserted
at the end of its test, and — when $AICHIP_STATVEC_DIR is set — one line per vector is
APPENDED to $AICHIP_STATVEC_DIR/test_vec_reduce_stat.txt:
  STATVEC-GEN test_vec_reduce_stat <test> set=<mode> seed=0x.... n=<n> md5=<GEN_MD5>
  STATVEC test_vec_reduce_stat <test> <id> rtl=M,E,nan,inf exp=M,E,nan,inf raw=rm,re rawexp=rm,re harness=OK|BAD OK|BAD
(<id> = table id, or <mode>#<i> for random vectors; rm in hex). harness= flags harness / protocol
problems only (here: result_o.valid != 1), independent of any value mismatch, so the J1 run on the
pre-fix RTL proves the harness separately (I3 review MINOR-2); the last field covers everything.
The directory must lie
outside this tb directory (and so outside sim_build, which run_all cleans) — a directory
inside it is refused (the test fails). Unset: no file, the asserts run unchanged.
Raw ports are decoded at their ACTUAL width (the pre-fix RTL has a 10-bit signed raw exp,
the fixed RTL a 12-bit one) so the J1 run on the pre-fix RTL records true values.

Run: cd tb && make MODULE=test_vec_reduce_stat TOPLEVEL=vec_reduce_cluster \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv \
        ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv"
"""
import hashlib
import inspect
import os
import sys

import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Model"))
import bfp_golden as g  # noqa: E402

MODULE = "test_vec_reduce_stat"
REDUCE_STAT = 3
RANDOM_SETS = {"module_U": (0x5A7A, 2000), "module_nonU": (0x5A7B, 2000)}   # prereg §74.1.5 JSON `random`


# ---------------------------------------------------------------------------------------------
# encode / decode
# ---------------------------------------------------------------------------------------------
def _sx(v, w):
    v &= (1 << w) - 1
    return v - (1 << w) if v >> (w - 1) else v


def pack_lane(l):
    """vec_lane_result_t (32b): mant[31:16] exp[15:6] sign[5] is_zero[4] is_nan[3] is_inf[2] ovf[1] udf[0]."""
    return (((l["mant"] & 0xFFFF) << 16) | ((l["exp"] & 0x3FF) << 6) | ((1 if l["mant"] < 0 else 0) << 5)
            | ((l["is_zero"] & 1) << 4) | ((l["is_nan"] & 1) << 3) | ((l["is_inf"] & 1) << 2))


def _width(h):
    try:
        return h.value.n_bits
    except AttributeError:
        return len(h)


async def drive(dut, lanes):
    """Drive one 16-lane STAT pass; return (rtl result tuple, raw (rm, re), valid)."""
    for i in range(16):
        dut.lane_results_i[i].value = pack_lane(lanes[i])
    dut.mode_i.value = REDUCE_STAT
    dut.valid_i.value = 1
    await Timer(1, "ns")
    r = int(dut.result_o.value)          # vec_reduce_result_t (34b): mant[33:13] exp[12:3] nan[2] inf[1] valid[0]
    res = (_sx(r >> 13, 21), _sx(r >> 3, 10), (r >> 2) & 1, (r >> 1) & 1)
    wm, we = _width(dut.stat_raw_mant_o), _width(dut.stat_raw_exp_o)
    rm = int(dut.stat_raw_mant_o.value) & ((1 << wm) - 1)            # unsigned (pre-fix values are >= 0 too)
    re_ = _sx(int(dut.stat_raw_exp_o.value), we)                     # signed at the port's own width
    return res, (rm, re_), r & 1


# ---------------------------------------------------------------------------------------------
# STATVEC side channel
# ---------------------------------------------------------------------------------------------
def _gen_md5():
    return hashlib.md5(inspect.getsource(g.stat_random_vectors).encode()).hexdigest()


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
    return ",".join(str(v) for v in x)


def _raw(x):
    return "0x%X,%d" % (x[0], x[1])


async def run_set(dut, test, items, gen=None):
    """items = [(id, lanes, table_expect_or_None)]. Collect everything, write STATVEC, then assert."""
    fails, lines = [], []
    if gen is not None:
        lines.append("STATVEC-GEN %s %s set=%s seed=0x%X n=%d md5=%s" % (MODULE, test, gen[0], gen[1], gen[2], _gen_md5()))
    for vid, lanes, texp in items:
        exp = tuple(g.stat_sumsq_golden([lanes]))
        rexp = tuple(g.stat_raw_golden(lanes))
        rtl, raw, valid = await drive(dut, lanes)
        harness = [] if valid == 1 else ["result_o.valid = %d" % valid]
        bad = list(harness)
        if texp is not None and tuple(texp) != exp:
            bad.append("golden %s != table %s" % (exp, tuple(texp)))
        if rtl != exp:
            bad.append("result %s != golden %s" % (rtl, exp))
        if raw != rexp:
            bad.append("raw (0x%X,%d) != golden (0x%X,%d)" % (raw + rexp))
        lines.append("STATVEC %s %s %s rtl=%s exp=%s raw=%s rawexp=%s harness=%s %s"
                     % (MODULE, test, vid, _t(rtl), _t(exp), _raw(raw), _raw(rexp),
                        "BAD" if harness else "OK", "BAD" if bad else "OK"))
        if bad:
            fails.append("%s: %s" % (vid, "; ".join(bad)))
    err = _statvec_lines(lines)
    if err:
        fails.insert(0, err)
    dut._log.info("%s: %d vectors, %d mismatches" % (test, len(items), len(fails)))
    assert not fails, "%s: %d / %d vectors wrong:\n  %s" % (test, len(fails), len(items), "\n  ".join(fails[:40]))


def table_items(ids):
    H6 = g.STAT_H6_VECTORS
    out = []
    for vid in ids:
        v = H6[vid]
        assert len(v["passes"]) == 1, "%s is not a block16 (module) vector" % vid
        out.append((vid, v["passes"][0], v["expect"]))
    return out


def random_items(mode):
    seed, n = RANDOM_SETS[mode]
    recs = g.stat_random_vectors(seed, n, mode)
    assert len(recs) == n
    return [("%s#%d" % (mode, i), ps[0], None) for i, (tags, ps) in enumerate(recs)], (mode, seed, n)


# ---------------------------------------------------------------------------------------------
# tests
# ---------------------------------------------------------------------------------------------
@cocotb.test()
async def test_stat_zero_identity(dut):
    """F1: zero lanes (is_zero, any exp; is_zero=0 & mant=0) are an additive identity; empty pass = (0,0)."""
    await run_set(dut, "zero_identity", table_items(["B1a", "B1b", "B1c", "B1d", "B1e", "B1f", "B2a", "B2b"]))


@cocotb.test()
async def test_stat_max_negative(dut):
    """-32768 lanes: |m| = 2^15 squared exactly; up to 16 of them (window top bits)."""
    await run_set(dut, "max_negative", table_items(["B3a", "B3b", "B3c", "B3e"]))


@cocotb.test()
async def test_stat_spread_window(dut):
    """F2/F3: exponent spread, window grid, scheme-C exactness (B4d/e/f) and error tightness (B4g)."""
    await run_set(dut, "spread_window", table_items(["B4a", "B4b", "B4c", "B4d", "B4e", "B4f", "B4g"]))


@cocotb.test()
async def test_stat_overflow_underflow(dut):
    """F4/F7: rounding before range check; overflow -> O-IB Inf, underflow -> (0,0); key 512 > 511 (B5h)."""
    await run_set(dut, "overflow_underflow",
                  table_items(["B5a", "B5b", "B5c", "B5d", "B5f", "B5g", "B5h", "B6a", "B6b", "B6c", "B6d", "B6e"]))


@cocotb.test()
async def test_stat_special(dut):
    """S8 / O-IB: NaN priority, Inf code, NaN / Inf lanes excluded from key and sum (B7d)."""
    await run_set(dut, "special", table_items(["B7a", "B7b", "B7c", "B7d"]))


@cocotb.test()
async def test_stat_rounding_funnel(dut):
    """RNE ties (B8), window LSB visibility (B8w/n/p), funnel clamp boundaries D = 32 / 33 (B8c / B8d)."""
    await run_set(dut, "rounding_funnel", table_items(["B8", "B8w", "B8n", "B8p", "B8c", "B8d"]))


@cocotb.test()
async def test_stat_random_U(dut):
    """Random U passes (one exponent per pass; seed 0x5A7A x 2000)."""
    items, gen = random_items("module_U")
    await run_set(dut, "random_U", items, gen)


@cocotb.test()
async def test_stat_random_nonU(dut):
    """Random non-U passes (span <= 2 / wide / any; seed 0x5A7B x 2000) — window active, still exact vs golden."""
    items, gen = random_items("module_nonU")
    await run_set(dut, "random_nonU", items, gen)

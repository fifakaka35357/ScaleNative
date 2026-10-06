"""
cocotb leaf (HW-REVIEW T3-FF/FF3a): the scale-sidecar decode primitive
pe_pkg::sidecar_scale_k, which pins the multi-block-streaming residual-scale wire
format. Packs N signed block exponents into 256b rows (16 per row) via the golden
codec, then checks the RTL extract of lane (k%16) == the INDEPENDENT golden unpack,
for distinct + NEGATIVE per-block exps (the sign/lane discriminators). Also
self-checks the scale-stream codec round-trip + resadd_stream_golden (N-block).

Run: cd tb && make MODULE=test_sidecar_scale TOPLEVEL=tb_sidecar_scale \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv ../tb/tb_sidecar_scale.sv"
"""
import cocotb
from cocotb.triggers import Timer
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g


@cocotb.test()
async def test_sidecar_scale_decode(dut):
    """RTL sidecar_scale_k extracts the k-th signed-16b exp from a packed 256b row,
    matching the independent golden codec. Distinct + negative exps (incl. the
    saturation boundaries) discriminate lane-index and sign-extension bugs."""
    fails = []
    exps = [-3, 5, -512, 511, 0, -1, 100, -100, 7, -7, 255, -256, 13, -13, 1, -2]
    rows = g.scale_stream_pack(exps)
    assert len(rows) == 1, "16 exps must pack into exactly one 256b row"
    row = rows[0]
    dut.row_i.value = row
    for lane in range(16):
        dut.lane_i.value = lane
        await Timer(1, "ns")
        rtl = g.signed(int(dut.exp_o.value), 16)
        want = g.scale_stream_unpack(row, lane)
        if rtl != want or want != exps[lane]:
            fails.append("lane %d: rtl=%d unpack=%d packed=%d" % (lane, rtl, want, exps[lane]))
    assert not fails, "sidecar_scale_k mismatches:\n  " + "\n  ".join(fails)
    dut._log.info("FF3a: pe_pkg.sidecar_scale_k extracts all 16 signed-16b block exps "
                  "(distinct + negative, incl. +/-512 boundaries) bit-exact vs the golden codec")


@cocotb.test()
async def test_scale_stream_and_stream_golden(dut):
    """Model self-checks (no DUT): scale_stream_pack/unpack round-trip over a MULTI-row
    stream; resadd_stream_golden reduces to resadd_fastpath_golden at N=1 and applies
    DISTINCT per-block exps independently (the honesty guard)."""
    fails = []
    exps = [(-1) ** k * (k * 7 % 300) for k in range(20)]   # N=20 -> 2 rows
    rows = g.scale_stream_pack(exps)
    if len(rows) != 2:
        fails.append("N=20 should pack into 2 rows, got %d" % len(rows))
    for k, e in enumerate(exps):
        got = g.scale_stream_unpack(rows[k // 16], k % 16)
        if got != e:
            fails.append("stream exp[%d]=%d != %d" % (k, got, e))
    s0 = [10 + i for i in range(16)]
    r0 = [40 + 2 * i for i in range(16)]
    one = g.resadd_stream_golden([s0], [0], [r0], [-2])
    direct = g.resadd_fastpath_golden(s0, 0, r0, -2)
    if one[0]["aligned"] != direct["aligned"] or one[0]["shared_exp"] != direct["shared_exp"]:
        fails.append("resadd_stream_golden N=1 != resadd_fastpath_golden")
    blocks = g.resadd_stream_golden([s0, s0], [0, 0], [r0, r0], [-2, 3])
    if blocks[0]["aligned"] == blocks[1]["aligned"]:
        fails.append("distinct per-block e1 produced identical blocks (oracle not honest)")
    assert not fails, "scale-stream / stream-golden self-checks:\n  " + "\n  ".join(fails)
    dut._log.info("FF3a: scale-stream codec round-trips multi-row; resadd_stream_golden "
                  "reduces to single-block at N=1 and applies per-block exps independently")

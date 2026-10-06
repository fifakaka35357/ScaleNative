"""
cocotb regression for tensor_result_packer (D2) — 48b->16b capsule formation.

Drives one egress row of 16 fp_acc_output_t cells + descriptor metadata, reads the
formed bs_capsule_t (payload 16x16b + inline_scale) and the escape/status outputs,
and checks against the golden capsule_form_golden (Model/bfp_golden.py). Covers
uniform/mixed rows, the escape boundary (spread 14 vs 15), all-zero, NaN/Inf,
random rows, and the E8M0 block-scale byte.

Run: cd tb && make MODULE=test_tensor_result_packer TOPLEVEL=tensor_result_packer \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv"
"""
import os
import sys
import random
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

# bs_capsule_t field bit-offsets from LSB (see pe_pkg.sv §9 struct, MSB-first decl)
OFF_INLINE_SCALE = 35            # inline_scale[31:0]
OFF_SCALE_REF = 67               # scale_ref[15:0] (declared just above inline_scale)
OFF_PAYLOAD = 96                 # payload[255:0]


async def form(dut, cells, *, block_size=1, scale_fmt=0, epoch=0x5A,
               role=0, elem_fmt=8, w_sel=2, rne=0, spread_limit=14):
    for i in range(16):
        c = cells[i] if i < len(cells) else g.acc_cell(0.0)
        bits = g.pack_fp_acc(c["mant48"], c["exp10"], c["sign"], c["is_nan"], c["is_inf"])
        dut.cells_i[i].value = bits
    dut.target_w_sel_i.value = w_sel
    dut.kind_fp_i.value = 0
    dut.round_rne_i.value = rne
    dut.block_size_i.value = block_size
    dut.scale_format_i.value = scale_fmt
    dut.scale_epoch_i.value = epoch
    dut.ctx_id_i.value = 1
    dut.tag_i.value = 2
    dut.elem_fmt_i.value = elem_fmt
    dut.operand_role_i.value = role
    dut.spread_limit_i.value = spread_limit
    await Timer(1, "ns")
    cap = int(dut.capsule_o.value)
    payload = (cap >> OFF_PAYLOAD) & ((1 << 256) - 1)
    mants = [g.signed((payload >> (i * 16)) & 0xFFFF, 16) for i in range(16)]
    inline_scale = (cap >> OFF_INLINE_SCALE) & 0xFFFFFFFF
    scale_ref = (cap >> OFF_SCALE_REF) & 0xFFFF
    return {
        "mants": mants,
        "scale_byte": inline_scale & 0xFF,
        "inline_scale": inline_scale,
        "scale_ref": scale_ref,
        "escape": int(dut.escape_o.value),
        "all_zero": int(dut.all_zero_o.value),
        "nan": int(dut.block_nan_o.value),
        "inf": int(dut.block_inf_o.value),
    }


def check_against_golden(fails, label, rtl, cells, spread_limit=14):
    gold = g.capsule_form_golden(cells, spread_limit=spread_limit,
                                 round_mode=g.OUT_ROUND_RTZ)
    if rtl["escape"] != (1 if gold["escape"] else 0):
        fails.append(f"{label}: escape rtl={rtl['escape']} gold={gold['escape']}")
    if gold["escape"]:
        return                     # on escape the payload is don't-care (Class C)
    if rtl["mants"] != gold["payload_mants"]:
        fails.append(f"{label}: payload rtl={rtl['mants']} gold={gold['payload_mants']}")
    if rtl["scale_byte"] != (gold["inline_scale"] & 0xFF):
        fails.append(f"{label}: scale_byte rtl={rtl['scale_byte']} gold={gold['inline_scale'] & 0xFF}")


@cocotb.test()
async def test_packer(dut):
    fails = []

    # uniform row
    cells = [g.acc_cell(1.0)] * 16
    r = await form(dut, cells)
    check_against_golden(fails, "uniform", r, cells)
    if r["scale_byte"] != (-14 + 127):
        fails.append(f"uniform scale_byte={r['scale_byte']} want {-14+127}")

    # escape boundary
    c14 = [g.acc_cell(1.0), g.acc_cell(2.0 ** -14)] + [g.acc_cell(0.0)] * 14
    c15 = [g.acc_cell(1.0), g.acc_cell(2.0 ** -15)] + [g.acc_cell(0.0)] * 14
    r = await form(dut, c14); check_against_golden(fails, "spread14", r, c14)
    if r["escape"]:
        fails.append("spread14 should NOT escape")
    r = await form(dut, c15); check_against_golden(fails, "spread15", r, c15)
    if not r["escape"]:
        fails.append("spread15 SHOULD escape")

    # 🔴 [2026-09-06] spread 项的【唯一】可观测激励。
    # 为什么必须有它：上面 spread15 那一行是靠 `|lane_uf` 逃逸的 ——
    # W=16/INT 下 ref_exp = shared_exp-14，spread>14 必然让最小 lane 对齐后下溢
    # ⇒ `shared_exp - min_exp > spread_limit` 这一项【被 lane_uf 完全遮蔽】。
    # 实证（变异测试）：把 packer 里 min 的比较方向写反（min 变成 max），
    # 本 TB 在加这一段之前【全绿】—— 即 min_exp 这一半当时零覆盖。
    # 做法 = 把 spread_limit_i 压到 4，用一行 spread=8 的数据：
    #   spread 8 > 4  ⇒ 只能靠 spread 项逃逸（8 <= 14，对齐后不下溢 ⇒ lane_uf=0）
    #   同一行在 spread_limit=14 下必须【不】逃逸 ⇒ 正反两支都可达。
    csp = [g.acc_cell(1.0), g.acc_cell(2.0 ** -8)] + [g.acc_cell(0.0)] * 14
    r4 = await form(dut, csp, spread_limit=4)
    check_against_golden(fails, "spread_lim4", r4, csp, spread_limit=4)
    if not r4["escape"]:
        fails.append("spread_lim4 SHOULD escape via the shared_exp-min_exp term")
    r14 = await form(dut, csp, spread_limit=14)
    check_against_golden(fails, "spread_lim14", r14, csp, spread_limit=14)
    if r14["escape"]:
        fails.append("spread_lim14 on the same row should NOT escape "
                     "(if it does, lane_uf is firing and the term is still masked)")

    # mixed magnitudes / signs
    cells = [g.acc_cell(v) for v in
             [4.0, -2.0, 1.0, -0.5, 6.0, -6.0, 3.0, 1.5,
              2.0, -4.0, 0.5, -1.0, 1.25, -3.0, 0.25, 5.0]]
    r = await form(dut, cells); check_against_golden(fails, "mixed", r, cells)

    # HW-REVIEW TIER-3 (RED-A): an E4M3 INT16 capsule must carry the ABSOLUTE block
    # ref_exp (scale_ref + inline_scale[8]=ABS_EXP_PRESENT), NOT the clamped 4-bit
    # E4M3 byte. The byte stays a valid (clamped) external NVFP4 scale + mant_corr,
    # but internal RESADD alignment decodes the unclamped scale_ref. Two out-of-range
    # cases (ref_exp = -14 and +10), which the 4-bit E4M3 byte CANNOT represent.
    for cells, tag in [([g.acc_cell(1.0)] * 16, "lo"),                       # ref_exp = -14
                       ([g.acc_cell(2.0 ** 24)] * 16, "hi")]:                # ref_exp = +10
        r = await form(dut, cells, scale_fmt=1)                              # SCALE_E4M3
        tref = g.true_ref_exp(cells, w=16)
        dec = g.abs_scale_decode(r["scale_ref"], r["inline_scale"], g.SCALE_E4M3)
        want = max(-512, min(511, tref))
        if dec != want:
            fails.append("E4M3 abs-scale %s: decoded exp=%d != true ref_exp=%d "
                         "(scale_ref=%d inline_scale=%#x byte=%#04x) — packer must emit the "
                         "absolute exponent, not the clamped byte"
                         % (tag, dec, tref, g.signed(r["scale_ref"], 16), r["inline_scale"], r["scale_byte"]))
        # the legacy E4M3 byte itself must still be the clamped/valid NVFP4 scale byte
        if r["scale_byte"] != g._e4m3_scale_encode(tref):
            fails.append("E4M3 byte %s: rtl=%#04x want clamped %#04x (external NVFP4 carrier)"
                         % (tag, r["scale_byte"], g._e4m3_scale_encode(tref)))

    # all-zero row
    cells = [g.acc_cell(0.0)] * 16
    r = await form(dut, cells)
    if not r["all_zero"] or r["escape"]:
        fails.append(f"all-zero: all_zero={r['all_zero']} escape={r['escape']}")

    # NaN / Inf in the row -> escape + status
    cells = [g.acc_cell(1.0)] * 15 + [g.acc_cell(float("nan"))]
    r = await form(dut, cells)
    if not r["nan"] or not r["escape"]:
        fails.append(f"NaN row: nan={r['nan']} escape={r['escape']}")
    cells = [g.acc_cell(1.0)] * 15 + [{"mant48": 0, "exp10": 0, "sign": 0, "is_nan": 0, "is_inf": 1}]
    r = await form(dut, cells)
    if not r["inf"] or not r["escape"]:
        fails.append(f"Inf row: inf={r['inf']} escape={r['escape']}")

    # randomized rows within a bounded spread (so most don't escape)
    rng = random.Random(20260616)
    for t in range(40):
        base = rng.choice([-6, 0, 3, 8])
        cells = []
        for _ in range(16):
            e = base + rng.randint(0, 12)             # keep spread <= 14 mostly
            m = rng.choice([1.0, 1.25, 1.5, 1.75])
            s = rng.choice([1, -1])
            cells.append(g.acc_cell(s * m * (2.0 ** e)))
        r = await form(dut, cells)
        check_against_golden(fails, f"rand{t}", r, cells)

    assert not fails, "tensor_result_packer mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:30]))
    dut._log.info("tensor_result_packer: all rows match capsule_form_golden")

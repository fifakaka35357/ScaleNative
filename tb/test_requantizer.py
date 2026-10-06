"""
cocotb regression for requantizer (D9, INT path) — per-cell block-float narrowing.

Drives the combinational leaf with a (cell, shared_exp, W, round) sweep and checks
elem_o / underflow_o / eff_o / zero_o / special_o against the golden oracle
(Model/bfp_golden.py: requantize_cell_int_golden, eff_unbiased_exp). Covers the
W=16 Vector fast-path lane + W=8/4 compact-MX widths, RTZ/RNE, and the edge cases
the acc_cell sweep alone can't reach (left-shift small mantissa, clamp, NaN, zero).

Run: cd tb && make MODULE=test_requantizer TOPLEVEL=requantizer \
        VERILOG_SOURCES="../rtl/Tensor/requantizer.sv"
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

W_OF = {0: 4, 1: 8, 2: 16}


def to2c(v, bits):
    return v & ((1 << bits) - 1)


async def eval_cell(dut, cell, shared_exp, w_sel, rne, fp=0):
    dut.cell_mant_i.value = cell["mant48"]
    dut.cell_exp_i.value = to2c(cell["exp10"], 12)
    dut.cell_sign_i.value = cell["sign"]
    dut.cell_is_nan_i.value = cell["is_nan"]
    dut.cell_is_inf_i.value = cell["is_inf"]
    dut.shared_exp_i.value = to2c(shared_exp, 12)
    dut.target_w_sel_i.value = w_sel
    dut.kind_fp_i.value = fp
    dut.round_rne_i.value = rne
    await Timer(1, "ns")
    return {
        "elem": g.signed(int(dut.elem_o.value), 16),
        "eff": g.signed(int(dut.eff_o.value), 12),
        "uf": int(dut.underflow_o.value),
        "zero": int(dut.zero_o.value),
        "special": int(dut.special_o.value),
    }


def cell(mant48, exp10, sign=0, is_nan=0, is_inf=0):
    return {"mant48": mant48, "exp10": exp10, "sign": sign, "is_nan": is_nan, "is_inf": is_inf}


@cocotb.test()
async def test_requantizer_int(dut):
    fails = []

    # --- sweep over acc_cell-derived block-float cells ---
    vals = [0.0, 1.0, 6.0, -6.0, 3.0, -3.0, 0.5, 2.0 ** -14, 2.0 ** -15,
            4.0, -1.0, 256.0, -256.0]
    for v in vals:
        c = g.acc_cell(v)
        eff_g = g.eff_unbiased_exp(c["mant48"], c["exp10"]) if c["mant48"] else None
        for dse in [0, 5, 14, 15, -3]:
            se = (eff_g + dse) if eff_g is not None else dse
            for w_sel in (0, 1, 2):
                W = W_OF[w_sel]
                for rne in (0, 1):
                    rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
                    qg, ufg = g.requantize_cell_int_golden(c, se, W, rm)
                    r = await eval_cell(dut, c, se, w_sel, rne)
                    lbl = f"v={v} se={se} W={W} rne={rne}"
                    if r["elem"] != qg:
                        fails.append(f"{lbl}: elem rtl={r['elem']} gold={qg}")
                    exp_uf = 1 if (ufg and c["mant48"] != 0) else 0
                    if r["uf"] != exp_uf:
                        fails.append(f"{lbl}: uf rtl={r['uf']} gold={exp_uf}")
                    if c["mant48"] == 0 and r["zero"] != 1:
                        fails.append(f"{lbl}: zero flag missing")
                    if c["mant48"] != 0 and r["eff"] != eff_g:
                        fails.append(f"{lbl}: eff rtl={r['eff']} gold={eff_g}")

    # --- directed edge cases (not reachable via acc_cell's 40-bit mantissa) ---
    # left-shift: tiny mantissa (large lzc) when it is the block max.
    c = cell(0b11, 0)                       # value 3, eff = 1
    qg, _ = g.requantize_cell_int_golden(c, 1, 16, g.OUT_ROUND_RTZ)
    r = await eval_cell(dut, c, 1, 2, 0)
    if r["elem"] != qg:
        fails.append(f"left-shift: elem rtl={r['elem']} gold={qg}")
    if r["eff"] != 1:
        fails.append(f"left-shift: eff rtl={r['eff']} gold=1")

    # clamp: a cell larger than the (artificially low) shared_exp -> saturate to qmax.
    c = cell(1 << 47, 0)                     # value 2^47, eff = 47
    qg, _ = g.requantize_cell_int_golden(c, 40, 16, g.OUT_ROUND_RTZ)  # se below eff
    r = await eval_cell(dut, c, 40, 2, 0)
    if r["elem"] != qg or qg != 32767:
        fails.append(f"clamp+: elem rtl={r['elem']} gold={qg} (want 32767)")
    c = cell(1 << 47, 0, sign=1)             # negative -> clamp to -2^15
    qg, _ = g.requantize_cell_int_golden(c, 40, 16, g.OUT_ROUND_RTZ)
    r = await eval_cell(dut, c, 40, 2, 0)
    if r["elem"] != qg or qg != -32768:
        fails.append(f"clamp-: elem rtl={r['elem']} gold={qg} (want -32768)")

    # NaN / Inf passthrough.
    r = await eval_cell(dut, cell(0, 0, is_nan=1), 0, 2, 0)
    if r["special"] != 1 or r["elem"] != 0 or r["uf"] != 0:
        fails.append(f"NaN: special={r['special']} elem={r['elem']} uf={r['uf']}")
    r = await eval_cell(dut, cell(0, 0, is_inf=1), 0, 2, 0)
    if r["special"] != 1 or r["elem"] != 0:
        fails.append(f"Inf: special={r['special']} elem={r['elem']}")

    assert not fails, "requantizer INT mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:30]))
    dut._log.info("requantizer INT: all combos match golden")


@cocotb.test()
async def test_requantizer_fp(dut):
    """MXFP path: FP4 E2M1 (W=4) / FP8 E4M3FN (W=8) re-encode of value/2^shared_exp.
    Sweeps x=value/2^shared across (0,2) incl. exact grid points, midpoints (ties),
    subnormal boundary and underflow, both signs, RTZ/RNE — vs requantize_cell_fp_golden."""
    fails = []
    # fine x grid in (0, 2): grid points, midpoints, subnormal/underflow region
    xs = [1.0, 1.5, 1.25, 1.75, 1.9, 1.0625, 0.75, 0.5, 0.625, 0.4375, 0.25,
          0.125, 0.0625, 0.03125, 0.015625, 0.2, 0.9, 1.1, 0.3, 0.06]
    xs = xs + [-v for v in xs]
    for w_sel in (0, 1):              # FP4, FP8
        W = W_OF[w_sel]
        for x in xs:
            c = g.acc_cell(x)
            # shared_exp = 0 -> x' = value/2^0 = x ; rel_exp = eff(x)
            for rne in (0, 1):
                rm = g.OUT_ROUND_RNE if rne else g.OUT_ROUND_RTZ
                bits_g, uf_g = g.requantize_cell_fp_golden(c, 0, W, rm)
                r = await eval_cell(dut, c, 0, w_sel, rne, fp=1)
                elem = int(r["elem"]) & ((1 << W) - 1)
                lbl = f"x={x} W={W} rne={rne}"
                if elem != bits_g:
                    dg = (g.fp4_e2m1_decode(bits_g) if W == 4 else g.fp8_e4m3fn_decode(bits_g)[0])
                    dr = (g.fp4_e2m1_decode(elem) if W == 4 else g.fp8_e4m3fn_decode(elem)[0])
                    fails.append(f"{lbl}: bits rtl=0x{elem:02x}({dr}) gold=0x{bits_g:02x}({dg})")
                if r["uf"] != (1 if uf_g else 0):
                    fails.append(f"{lbl}: uf rtl={r['uf']} gold={uf_g}")
    assert not fails, "requantizer FP mismatches (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:40]))
    dut._log.info("requantizer FP: all combos match golden")

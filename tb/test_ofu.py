"""
cocotb regression for output_format_unit — focus: C07 (unified scaling convention).

Under the frozen convention a block-float accumulator value is value = mant * 2^exp
with mant a 48-bit INTEGER. The OFU left-normalizes mant (leading 1 lands at bit
47-lzc), so the IEEE unbiased exponent is exp + (47 - lzc). The pre-C07 OFU used
exp - lzc (missing the +47) → every Class-C escape result was 2^47 too small.

This test drives synthetic fp_acc_output_t inputs of known value mant*2^exp and
checks that the packed FP result decodes back to that value, across BF16 / FP16 /
FP8(E4M3) / FP32.

Run: cd tb && make MODULE=test_ofu TOPLEVEL=output_format_unit \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/output_format_unit.sv"
"""
import os
import sys
import math
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

FMTS = [("BF16", g.OUT_FMT_BF16), ("FP16", g.OUT_FMT_FP16),
        ("FP8", g.OUT_FMT_FP8), ("FP32", g.OUT_FMT_FP32)]

# (label, mant, exp, sign, true_value)  — value = (-1)^sign * mant * 2^exp
CASES = [
    ("1.0",            1,      0, 0,  1.0),
    ("3.0",            3,      0, 0,  3.0),
    ("16.0",           1,      4, 0,  16.0),
    ("1.25",           5,     -2, 0,  1.25),
    ("96.0",           96,     0, 0,  96.0),
    ("-3.0",           3,      0, 1, -3.0),
    ("FP4-mant 1.0",   64,    -6, 0,  1.0),     # mant as mac_lru FP4 would emit
    ("FP8-mant 1.0",   1024, -10, 0,  1.0),     # mant as mac_lru FP8 would emit
    ("BF16-mant 1.5",  24576, -14, 0, 1.5),     # mant as mac_cell BF16 would emit
    ("BF16-ovf 2.25",  18432, -13, 0, 2.25),
]


async def eval_ofu(dut, mant, exp, sign, fmt, rnd=g.OUT_ROUND_RTZ):
    dut.acc_in.value = g.pack_fp_acc(mant, exp, sign)
    dut.out_fmt.value = fmt
    dut.round_mode.value = rnd
    await Timer(1, "ns")
    return int(dut.result.value), int(dut.ofu_valid.value)


async def eval_ofu_packed(dut, packed, fmt, rnd=g.OUT_ROUND_RTZ):
    dut.acc_in.value = packed
    dut.out_fmt.value = fmt
    dut.round_mode.value = rnd
    await Timer(1, "ns")
    return int(dut.result.value), int(dut.ofu_valid.value)


@cocotb.test()
async def test_c07_ofu_range_special(dut):
    """C07 moved norm_exp (+47), relocating the overflow→Inf / underflow→FTZ
    boundary. Exercise those paths + NaN/Inf passthrough + FP8 E4M3 saturation."""
    BF16, FP16, FP8, FP32 = g.OUT_FMT_BF16, g.OUT_FMT_FP16, g.OUT_FMT_FP8, g.OUT_FMT_FP32
    fails = []
    # (label, packed_acc, fmt, kind)  kind ∈ {inf, zero, nan, sat448}
    cases = [
        ("overflow→Inf BF16",  g.pack_fp_acc(1, 300), BF16, "inf"),
        ("overflow→Inf FP16",  g.pack_fp_acc(1, 300), FP16, "inf"),
        ("overflow→Inf FP32",  g.pack_fp_acc(1, 300), FP32, "inf"),
        ("underflow→0 BF16",   g.pack_fp_acc(1, -300), BF16, "zero"),
        ("underflow→0 FP16",   g.pack_fp_acc(1, -40), FP16, "zero"),
        ("NaN passthrough",    g.pack_fp_acc(64, 0, 0, is_nan=1), BF16, "nan"),
        ("Inf passthrough",    g.pack_fp_acc(64, 0, 0, is_inf=1), FP32, "inf"),
        ("FP8 E4M3 saturate",  g.pack_fp_acc(1, 9), FP8, "sat448"),   # 2^9=512 > 448
    ]
    for label, packed, fmt, kind in cases:
        res, valid = await eval_ofu_packed(dut, packed, fmt)
        val, is_nan, is_inf = g.decode_target_fp(res, fmt)
        if kind == "inf":
            ok = valid == 1 and is_inf
        elif kind == "nan":
            ok = valid == 1 and is_nan
        elif kind == "zero":
            ok = valid == 1 and (not is_nan) and (not is_inf) and val == 0.0
        else:  # sat448
            ok = valid == 1 and abs(abs(val) - 448.0) < 1e-6
        dut._log.info(f"{label:22s}: val={val} is_nan={is_nan} is_inf={is_inf} "
                      f"{'OK' if ok else 'FAIL'} (raw=0x{res:08x})")
        if not ok:
            fails.append(f"{label}: val={val} nan={is_nan} inf={is_inf}")
    assert not fails, "C07 OFU range/special mismatches:\n  " + "\n  ".join(fails)


@cocotb.test()
async def test_c07_ofu_convention(dut):
    """OFU output must decode back to mant*2^exp (IEEE exp = exp + 47 - lzc)."""
    fails = []
    for label, mant, exp, sign, expect in CASES:
        for fname, fmt in FMTS:
            # FP8 E4M3 only spans a narrow range; skip values it cannot hold.
            if fmt == g.OUT_FMT_FP8 and abs(expect) > 448.0:
                continue
            res, valid = await eval_ofu(dut, mant, exp, sign, fmt)
            val, is_nan, is_inf = g.decode_target_fp(res, fmt)
            ok = valid == 1 and not is_nan and not is_inf \
                and math.isclose(val, expect, rel_tol=1e-12, abs_tol=1e-18)
            dut._log.info(f"{label:16s} {fname:4s}: rtl={val:+.6g} expect={expect:+.6g} "
                          f"{'OK' if ok else 'FAIL'}  (raw=0x{res:08x} valid={valid})")
            if not ok:
                fails.append(f"{label}/{fname}: rtl={val} expect={expect}")
    assert not fails, "C07 OFU convention mismatches:\n  " + "\n  ".join(fails)

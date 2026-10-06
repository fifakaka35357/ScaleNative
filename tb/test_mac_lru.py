"""
cocotb regression for mac_lru — focus: D4 (FP4/FP8 element subnormal must not be FTZ'd).

Run: cd tb && make MODULE=test_mac_lru TOPLEVEL=mac_lru \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_lru.sv"
(or via the Makefile defaults).
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

MODE_FP4 = g.MODE_FP4
MODE_FP8 = g.MODE_FP8
TOL = 1e-9


async def eval_lru(dut, mode, fp4_a, fp4_b, fp8_a, fp8_b):
    dut.mode.value = mode
    for i in range(4):
        dut.fp4_a[i].value = fp4_a[i] & 0xF
        dut.fp4_b[i].value = fp4_b[i] & 0xF
    for i in range(2):
        dut.fp8_a[i].value = fp8_a[i] & 0xFF
        dut.fp8_b[i].value = fp8_b[i] & 0xFF
    await Timer(1, "ns")
    return int(dut.lru_out.value)


@cocotb.test()
async def test_fp4_subnormal(dut):
    """FP4 E2M1 subnormal 0.5 (encoding {exp=00,frac=1}) must NOT be flushed to zero."""
    Z4, Z2 = [0, 0, 0, 0], [0, 0]
    # FP4 encodings: 1.0={0,01,0}=0x2  1.5={0,01,1}=0x3  2.0={0,10,0}=0x4
    #                0.5(subnormal)={0,00,1}=0x1   -0.5={1,00,1}=0x9
    cases = [
        ("1.0 * 1.0",        0x2, 0x2, 1.0),    # normal (passes pre-fix; sanity)
        ("1.0 * 1.5",        0x2, 0x3, 1.5),    # normal (sanity)
        ("0.5sub * 1.0",     0x1, 0x2, 0.5),    # D4 — fails pre-fix (flushed to 0)
        ("0.5sub * 0.5sub",  0x1, 0x1, 0.25),   # D4
        ("0.5sub * 1.5",     0x1, 0x3, 0.75),   # D4
        ("-0.5sub * 2.0",    0x9, 0x4, -1.0),   # D4 (sign)
    ]
    fails = []
    for name, a0, b0, expect in cases:
        fp4_a, fp4_b = [a0, 0, 0, 0], [b0, 0, 0, 0]
        raw = await eval_lru(dut, MODE_FP4, fp4_a, fp4_b, Z2, Z2)
        rtl = g.decode_lru_out(raw, MODE_FP4)
        gold = g.mac_lru_golden(MODE_FP4, fp4_a, fp4_b, Z2, Z2)
        ok = abs(rtl["value"] - gold["value"]) < TOL and abs(gold["value"] - expect) < TOL
        dut._log.info(f"FP4 {name:18s}: rtl={rtl['value']:+.6g} gold={gold['value']:+.6g} "
                      f"expect={expect:+.6g}  {'OK' if ok else 'FAIL'}  "
                      f"(mant={rtl['mant']} exp={rtl['exp']} zero={rtl['zero']})")
        if not ok:
            fails.append(f"{name}: rtl={rtl['value']} gold={gold['value']} expect={expect}")
    assert not fails, "FP4 subnormal mismatches:\n  " + "\n  ".join(fails)


@cocotb.test()
async def test_fp8_subnormal(dut):
    """FP8 E4M3FN subnormals (exp=0, frac!=0) must NOT be flushed to zero."""
    Z4, Z2 = [0, 0, 0, 0], [0, 0]
    # FP8 E4M3: 1.0={0,0111,000}=0x38  2.0={0,1000,000}=0x40
    # subnormal frac=4 -> 0.100b * 2^-6 = 2^-7 ; encoding {0,0000,100}=0x04
    # subnormal frac=1 -> 2^-9 ; {0,0000,001}=0x01
    cases = [
        ("1.0 * 1.0",         0x38, 0x38, 1.0),               # normal (sanity)
        ("sub(2^-7) * 1.0",   0x04, 0x38, 2.0 ** -7),         # D4 — fails pre-fix (s=1)
        ("sub(2^-9) * 2.0",   0x01, 0x40, 2.0 ** -8),         # D4 (s=3)
        # D4 review nit: cover the s=2 shift branch (frac[1]=1,frac[2]=0 → frac=2,3)
        # and multi-bit subnormal fracs (5,6,7) so the frac3<<s normalization is
        # exercised beyond single-bit fracs. golden = (f/8)*2^-6 independently.
        ("sub(f=3) * 1.0",    0x03, 0x38, (3 / 8) * 2.0 ** -6),  # s=2
        ("sub(f=2) * 1.0",    0x02, 0x38, (2 / 8) * 2.0 ** -6),  # s=2
        ("sub(f=5) * 1.0",    0x05, 0x38, (5 / 8) * 2.0 ** -6),  # s=1, multi-bit
        ("sub(f=6) * 1.0",    0x06, 0x38, (6 / 8) * 2.0 ** -6),  # s=1, multi-bit
        ("sub(f=7) * 1.0",    0x07, 0x38, (7 / 8) * 2.0 ** -6),  # s=1, multi-bit
    ]
    fails = []
    for name, a0, b0, expect in cases:
        fp8_a, fp8_b = [a0, 0], [b0, 0]
        raw = await eval_lru(dut, MODE_FP8, Z4, Z4, fp8_a, fp8_b)
        rtl = g.decode_lru_out(raw, MODE_FP8)
        gold = g.mac_lru_golden(MODE_FP8, Z4, Z4, fp8_a, fp8_b)
        ok = abs(rtl["value"] - gold["value"]) < TOL and abs(gold["value"] - expect) < TOL
        dut._log.info(f"FP8 {name:18s}: rtl={rtl['value']:+.6g} gold={gold['value']:+.6g} "
                      f"expect={expect:+.6g}  {'OK' if ok else 'FAIL'}  "
                      f"(mant={rtl['mant']} exp={rtl['exp']} zero={rtl['zero']})")
        if not ok:
            fails.append(f"{name}: rtl={rtl['value']} gold={gold['value']} expect={expect}")
    assert not fails, "FP8 subnormal mismatches:\n  " + "\n  ".join(fails)

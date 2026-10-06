"""
cocotb regression for vec_scale_adapter — C11 (missing module, blocked Vector compile).

Pure-combinational dual-format block-scale decoder: E8M0 / E4M3 raw byte →
vec_internal_scale_t {exp_adj, mant_corr, special_nan, special_zero} + error_o.
Spec: VEC_README §3.6/§5.6 and vec_pkg vec_internal_scale_t.

Run: cd tb && make MODULE=test_vec_scale_adapter TOPLEVEL=vec_scale_adapter \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/vec_scale_adapter.sv"
(Step 2: retargeted to the unified pe_pkg SSOT; was Vector/Unchanged/PE/pe_pkg.sv)
"""
import os
import sys
import cocotb
from cocotb.triggers import Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

E8M0 = g.SCALE_E8M0
E4M3 = g.SCALE_E4M3


async def eval_adapter(dut, raw, fmt, inline_valid, valid, abs_exp=0, abs_valid=0):
    dut.raw_scale_i.value = raw & 0xFF
    dut.scale_format_i.value = fmt
    dut.scale_inline_valid_i.value = inline_valid
    dut.valid_i.value = valid
    dut.abs_exp_i.value = abs_exp & 0xFFFF        # [HW-REVIEW T3] absolute block exp
    dut.abs_exp_valid_i.value = abs_valid         # [HW-REVIEW T3] use abs path (E4M3)
    await Timer(1, "ns")
    return (g.decode_vec_internal_scale(int(dut.scale_o.value)),
            int(dut.valid_o.value), int(dut.error_o.value))


# (label, raw, fmt, inline_valid, valid)
CASES = [
    # E8M0: value = 2^(raw-127)
    ("E8M0 127 (2^0)",    0x7F, E8M0, 1, 1),
    ("E8M0 128 (2^1)",    0x80, E8M0, 1, 1),
    ("E8M0 0   (2^-127)", 0x00, E8M0, 1, 1),
    ("E8M0 254 (2^127)",  0xFE, E8M0, 1, 1),
    ("E8M0 0xFF (NaN)",   0xFF, E8M0, 1, 1),
    # E4M3: value = (1+m/8)*2^(exp-7)
    ("E4M3 1.0  {7,000}", 0x38, E4M3, 1, 1),
    ("E4M3 1.5  {7,100}", 0x3C, E4M3, 1, 1),
    ("E4M3 1.875{7,111}", 0x3F, E4M3, 1, 1),
    ("E4M3 2.0  {8,000}", 0x40, E4M3, 1, 1),
    ("E4M3 0.5  {6,000}", 0x30, E4M3, 1, 1),
    ("E4M3 zero {0,000}", 0x00, E4M3, 1, 1),
    ("E4M3 subn {0,100}", 0x04, E4M3, 1, 1),
    ("E4M3 NaN  0x7F",    0x7F, E4M3, 1, 1),
    ("E4M3 NaN  0xFF",    0xFF, E4M3, 1, 1),
    # Identity fallbacks (no error)
    ("inline_valid=0",    0x80, E4M3, 0, 1),
    ("valid=0",           0xFF, E8M0, 1, 0),
    # Unsupported format → error
    ("bad format (2)",    0x38, 2,    1, 1),
]


@cocotb.test()
async def test_c11_scale_adapter(dut):
    """E8M0/E4M3 decode, identity fallbacks, NaN/zero/bad-format error semantics."""
    fails = []
    for label, raw, fmt, iv, v in CASES:
        sc, valid_o, error_o = await eval_adapter(dut, raw, fmt, iv, v)
        gold = g.vec_scale_adapter_golden(raw, fmt, iv, v)
        ok = (sc["exp_adj"] == gold["exp_adj"]
              and sc["mant_corr"] == gold["mant_corr"]
              and sc["special_nan"] == gold["special_nan"]
              and sc["special_zero"] == gold["special_zero"]
              and error_o == gold["error"]
              and valid_o == gold["valid_o"])
        dut._log.info(
            f"{label:20s}: exp_adj={sc['exp_adj']:+d} mant_corr={sc['mant_corr']} "
            f"nan={sc['special_nan']} zero={sc['special_zero']} err={error_o} "
            f"{'OK' if ok else 'FAIL (gold ' + str(gold) + ')'}")
        if not ok:
            fails.append(f"{label}: rtl(exp={sc['exp_adj']},mc={sc['mant_corr']},"
                         f"nan={sc['special_nan']},zero={sc['special_zero']},err={error_o},"
                         f"vld={valid_o}) gold={gold}")
    assert not fails, "C11 vec_scale_adapter mismatches:\n  " + "\n  ".join(fails)


@cocotb.test()
async def test_t3_abs_scale_path(dut):
    """HW-REVIEW TIER-3: E4M3 ABSOLUTE-scale path. With abs_exp_valid_i, exp_adj comes
    from the UNCLAMPED signed abs_exp_i (= scale_ref), saturated to VEC_EXP_W ([-512,511]),
    NOT the 4-bit E4M3 byte exponent [-6,8]. mant_corr still from the byte; the NaN byte
    still flags. Covers exponents outside the legacy E4M3 window."""
    fails = []
    # (abs_exp, byte): exp_adj must be sat(abs_exp); mant_corr from byte[2:0].
    for abs_exp, byte in [(-14, 0x08), (10, 0x78), (-6, 0x38), (8, 0x40),
                          (-500, 0x38), (600, 0x38), (3, 0x3F),     # 0x3F: mant=111 -> mc 240
                          (-512, 0x38), (511, 0x38),                # exact saturation boundaries
                          (-700, 0x38), (512, 0x38)]:               # below/above -> clamp to -512/511
        sc, valid_o, error_o = await eval_adapter(dut, byte, E4M3, 1, 1, abs_exp=abs_exp, abs_valid=1)
        want = max(-512, min(511, abs_exp))
        mc_want = (8 + (byte & 0x7)) << 4
        if sc["exp_adj"] != want or sc["mant_corr"] != mc_want or error_o or sc["special_zero"]:
            fails.append("abs e=%d byte=%#04x: exp_adj=%d (want %d) mant_corr=%d (want %d) "
                         "err=%d zero=%d" % (abs_exp, byte, sc["exp_adj"], want,
                                             sc["mant_corr"], mc_want, error_o, sc["special_zero"]))
    # NaN byte (0x7F) must still flag even on the abs path
    sc, _, error_o = await eval_adapter(dut, 0x7F, E4M3, 1, 1, abs_exp=3, abs_valid=1)
    if not (sc["special_nan"] and error_o):
        fails.append("abs path NaN byte 0x7F: special_nan=%d err=%d (must flag)"
                     % (sc["special_nan"], error_o))
    assert not fails, "TIER-3 abs-scale adapter path:\n  " + "\n  ".join(fails)
    dut._log.info("TIER-3: vec_scale_adapter abs path decodes the unclamped scale_ref "
                  "(sat VEC_EXP_W), mant_corr from byte, NaN byte still flags")


@cocotb.test()
async def test_ff2_e8m0_abs_path(dut):
    """HW-REVIEW T3-FF/FF2 (risk f): E8M0 ABSOLUTE-scale path for block32 resident.
    With abs_exp_valid_i under E8M0, exp_adj comes from the UNCLAMPED signed abs_exp_i
    (= scale_ref), saturated to VEC_EXP_W; mant_corr is ALWAYS 128 (E8M0 has no
    mantissa — must NOT reuse the E4M3 byte mant_corr). Pre-fix the E8M0 arm ignores
    abs_exp_i and byte-decodes the 0x38 placeholder to exp 56-127=-71 (the silent
    power-of-two misalign FF2 must kill). The NaN byte 0xFF still flags."""
    fails = []
    # (abs_exp, byte): exp_adj must be sat(abs_exp); mant_corr ALWAYS 128 (not from byte).
    for abs_exp, byte in [(-2, 0x38), (3, 0x38), (-14, 0x80), (10, 0x40),
                          (-512, 0x38), (511, 0x38),       # exact saturation boundaries
                          (-700, 0x38), (512, 0x38)]:       # below/above -> clamp
        sc, valid_o, error_o = await eval_adapter(dut, byte, E8M0, 1, 1, abs_exp=abs_exp, abs_valid=1)
        want = max(-512, min(511, abs_exp))
        if sc["exp_adj"] != want or sc["mant_corr"] != 128 or error_o or sc["special_zero"]:
            fails.append("E8M0 abs e=%d byte=%#04x: exp_adj=%d (want %d) mant_corr=%d (want 128) "
                         "err=%d zero=%d" % (abs_exp, byte, sc["exp_adj"], want,
                                             sc["mant_corr"], error_o, sc["special_zero"]))
    # NaN byte (0xFF) must still flag even on the E8M0 abs path
    sc, _, error_o = await eval_adapter(dut, 0xFF, E8M0, 1, 1, abs_exp=3, abs_valid=1)
    if not (sc["special_nan"] and error_o):
        fails.append("E8M0 abs NaN byte 0xFF: special_nan=%d err=%d (must flag)"
                     % (sc["special_nan"], error_o))
    assert not fails, "FF2 E8M0 abs-scale adapter path:\n  " + "\n  ".join(fails)
    dut._log.info("FF2: vec_scale_adapter E8M0 abs path decodes the unclamped scale_ref "
                  "(sat VEC_EXP_W), mant_corr always 128, NaN byte still flags")

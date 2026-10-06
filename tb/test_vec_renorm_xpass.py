"""
cocotb regression for vec_renorm_xpass — block32 cross-pass renorm re-alignment
(TIER-2 silent-value fix, HW review 2026-06-20).

Bug: in a block32 (2-pass) renorm, vec_renorm_quant aligns each 16-lane window to
that pass's LOCAL max exponent. The two windows were then emitted under one shared
block exponent = global = max(exp0, exp1), but the lower-exp window's mantissas
were relabeled at global WITHOUT being re-shifted — so a consumer reading
value = mant*2^global saw every element of that window inflated by 2^(global-local).
A gross magnitude error of half the block, silent (no escape).

Fix: vec_renorm_xpass re-shifts each window by (global-local) toward zero before
egress (the higher-exp window's delta is 0, a no-op).

Oracle: an INDEPENDENT Python toward-zero shift (arithmetic floor + carry-back on
negative residue), structurally unrelated to the RTL. Each test also asserts the
fixed output DIFFERS from the buggy relabel-without-reshift (verbatim lower window)
whenever exp0 != exp1 — i.e. the re-shift demonstrably happens.

Run: cd tb && make MODULE=test_vec_renorm_xpass TOPLEVEL=vec_renorm_xpass \
  VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
  ../rtl/Vector/vec_renorm_xpass.sv"
"""
import cocotb
from cocotb.triggers import Timer

VEC_LANES = 16
MW = 16  # VEC_MANT_W


def to_u(x, w):
    return x & ((1 << w) - 1)


def to_s(x, w):
    x &= (1 << w) - 1
    return x - (1 << w) if x & (1 << (w - 1)) else x


def pack_window(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= to_u(m, MW) << (i * MW)
    return v


def unpack_window(val, base_bit):
    return [to_s((val >> (base_bit + i * MW)) & ((1 << MW) - 1), MW) for i in range(VEC_LANES)]


def tz_shift(val, amt):
    """Toward-zero right shift of a signed value (matches mant_tz_shift)."""
    if amt == 0:
        return val
    if amt >= MW:
        return 0
    shifted = val >> amt              # Python >> floors (arithmetic) for negatives
    if val < 0 and (val & ((1 << amt) - 1)) != 0:
        shifted += 1                  # carry back toward zero on negative residue
    return shifted


async def run(dut, win0, exp0, win1, exp1):
    glob = max(exp0, exp1)
    dut.win0_i.value = pack_window(win0)
    dut.win1_i.value = pack_window(win1)
    dut.exp0_i.value = to_u(exp0, 10)
    dut.exp1_i.value = to_u(exp1, 10)
    dut.global_exp_i.value = to_u(glob, 10)
    await Timer(1, "ns")
    raw = int(dut.packed_o.value)
    low = unpack_window(raw, 0)
    high = unpack_window(raw, 256)
    return low, high, glob


def golden(win0, exp0, win1, exp1):
    glob = max(exp0, exp1)
    low = [tz_shift(m, glob - exp0) for m in win0]
    high = [tz_shift(m, glob - exp1) for m in win1]
    return low, high


@cocotb.test()
async def test_xpass_pass1_lower(dut):
    """Window 1 (pass-1) below global: it must be down-shifted, not relabeled."""
    win0 = [100, -200, 50, -7, 300, -1, 9, -9, 12, -33, 77, -88, 5, -5, 1, -1]
    win1 = [9, -7, 11, -9, 13, -5, 1, -3, 15, -15, 2, -2, 4, -4, 6, -6]
    exp0, exp1 = 5, 2                      # global=5, delta1=3
    low, high, _ = await run(dut, win0, exp0, win1, exp1)
    glow, ghigh = golden(win0, exp0, win1, exp1)
    dut._log.info(f"high(rtl)={high}\nhigh(gold)={ghigh}")
    assert low == glow, f"window0 (delta0=0) altered: {low} != {glow}"
    assert high == ghigh, f"window1 re-shift wrong: {high} != {ghigh}"
    assert high != win1, "window1 unchanged — re-shift did NOT happen (bug behavior)"


@cocotb.test()
async def test_xpass_pass0_lower(dut):
    """Window 0 (pass-0) below global: symmetric re-shift of the low window."""
    win0 = [9, -7, 11, -9, 13, -5, 1, -3, 15, -15, 2, -2, 4, -4, 6, -6]
    win1 = [100, -200, 50, -7, 300, -1, 9, -9, 12, -33, 77, -88, 5, -5, 1, -1]
    exp0, exp1 = 1, 7                      # global=7, delta0=6
    low, high, _ = await run(dut, win0, exp0, win1, exp1)
    glow, ghigh = golden(win0, exp0, win1, exp1)
    assert high == ghigh, f"window1 (delta1=0) altered: {high} != {ghigh}"
    assert low == glow, f"window0 re-shift wrong: {low} != {glow}"
    assert low != win0, "window0 unchanged — re-shift did NOT happen (bug behavior)"


@cocotb.test()
async def test_xpass_equal_exp_noop(dut):
    """exp0 == exp1: both deltas 0, output is the verbatim concatenation."""
    win0 = [i - 8 for i in range(16)]
    win1 = [2 * i - 16 for i in range(16)]
    low, high, _ = await run(dut, win0, 3, win1, 3)
    assert low == win0 and high == win1, "equal-exp path must be a no-op"


@cocotb.test()
async def test_xpass_negative_exps(dut):
    """Negative exponents (signed delta) with toward-zero rounding on negatives."""
    win0 = [-9, -7, 7, 9, -1, 1, -15, 15, -2, 2, -8, 8, -3, 3, -16, 16]
    win1 = [123, -456, 789, -7, 0, -1, 2, -2, 33, -33, 4, -4, 5, -5, 6, -6]
    exp0, exp1 = -2, -9                    # global=-2, delta1=7
    low, high, _ = await run(dut, win0, exp0, win1, exp1)
    glow, ghigh = golden(win0, exp0, win1, exp1)
    assert low == glow, f"window0: {low} != {glow}"
    assert high == ghigh, f"window1: {high} != {ghigh}"


@cocotb.test()
async def test_xpass_full_flush(dut):
    """delta >= VEC_MANT_W: the negligible window flushes to all zero."""
    win0 = [1234, -5678, 999, -1000, 7, -7, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5]
    win1 = [50, -60, 70, -80, 9, -9, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5]
    exp0, exp1 = 0, 20                     # global=20, delta0=20 (>=16) -> flush
    low, high, _ = await run(dut, win0, exp0, win1, exp1)
    assert all(m == 0 for m in low), f"window0 should flush to 0: {low}"
    assert high == win1, f"window1 (delta1=0) altered: {high} != {win1}"

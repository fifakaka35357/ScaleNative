"""
[C2 anchor ③, 2026-07-25] mac_fp_accumulator NaN/Inf state machine (:181-203)
— first direct assertions on prod_is_nan/prod_is_inf propagation.

WHY it never ran: today lru_in.is_inf is STRUCTURALLY 0 (E4M3FN has no Inf
encoding, mac_lru.sv:311/:498-500) and no test drives an E4M3FN NaN DATA
operand or a BF16 special into the accumulator — the P7 priority chain
(freeze-on-NaN, Inf latch, Inf+(−Inf)→NaN, the :285 is_inf-masked-by-is_nan
output rule) is fully unguarded. The RTL's own persistence SVAs (:304-307,
:325-329) are `ifndef VERILATOR` — INACTIVE in this flow — so persistence is
asserted explicitly here.

Semantics locked (frozen, hand-derived from :163-241/:279-285):
  * NaN latches and FREEZES mant/exp at their last finite values (stale by
    contract, tensor_pkg.sv:271-272). No saturation.
  * Inf latches sign; further finite products ignored; out.sign=inf_sign.
  * Inf + (−Inf) -> NaN; out.is_inf is masked to 0 once is_nan (:285).
  * Specials latch EVEN when the product is zero-flagged (branches sit above
    the !align_skip guard).

RED protocol (mutations to mac_fp_accumulator.sv, then reverted):
  M-sp1: drop :190 `next_nan = 1'b1` (prod_is_nan arm)  => nan tests FAIL
  M-sp2: drop :195 (Inf+(−Inf)→NaN)                     => inf_collision FAILS
  M-sp3: :285 drop the `!acc_nan_reg` mask               => inf_collision FAILS
                                                            on the is_inf check

Run: cd tb && make MODULE=test_fp_acc_specials TOPLEVEL=mac_fp_accumulator \
  VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_tz_shifter.sv \
  ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE_FP8 = 3
MODE_BF16 = 4


def pack_bf16(mant, exp, zero=0, nan=0, inf=0, inf_sign=0):
    return (((mant & 0xFFFF) << 14) | ((exp & 0x3FF) << 4)
            | (zero << 3) | (nan << 2) | (inf << 1) | inf_sign)


def pack_lru(mant, exp, zero=0, nan=0, inf=0, inf_sign=0):
    return (((mant & 0x7FFF) << 14) | ((exp & 0x3FF) << 4)
            | (zero << 3) | (nan << 2) | (inf << 1) | inf_sign)


def unpack_acc(raw):
    e = (raw >> 3) & 0x3FF
    return dict(mant=(raw >> 13) & ((1 << 48) - 1),
                exp=e - (1 << 10) if e & 0x200 else e,
                sign=(raw >> 2) & 1, nan=(raw >> 1) & 1, inf=raw & 1)


async def reset_and_clear(dut, mode=MODE_BF16):
    dut.clear.value = 0
    dut.valid_in.value = 0
    dut.mode.value = mode
    dut.lru_in.value = 0
    dut.bf16_prod_in.value = 0
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)


async def push_bf16(dut, **kw):
    dut.bf16_prod_in.value = pack_bf16(kw.pop("mant", 0), kw.pop("exp", 0), **kw)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)


async def push_lru(dut, **kw):
    dut.lru_in.value = pack_lru(kw.pop("mant", 0), kw.pop("exp", 0), **kw)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_nan_latch_and_freeze_bf16(dut):
    """finite 5 -> NaN -> finite 7: is_nan latches, mant FROZEN at 5 (stale
    by contract), later finite adds ignored."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push_bf16(dut, mant=5, exp=0)
    await push_bf16(dut, mant=0, exp=0, nan=1)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["nan"], r["inf"]) == (1, 0), "NaN not latched: %r" % r
    await push_bf16(dut, mant=7, exp=0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["nan"], r["mant"]) == (1, 5), \
        "NaN freeze broken (mant must stay stale 5): %r" % r


@cocotb.test()
async def test_nan_latch_lru_fp8_mode(dut):
    """Same latch through the LRU bundle in MODE_FP8 (the E4M3FN NaN route:
    mac_lru drives lru_in.is_nan when an operand byte is 0x7F/0xFF)."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut, mode=MODE_FP8)
    await push_lru(dut, mant=9, exp=0)
    await push_lru(dut, mant=0, exp=0, nan=1)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert r["nan"] == 1, "LRU-path NaN not latched: %r" % r


@cocotb.test()
async def test_inf_latch_and_sign(dut):
    """+Inf latches with sign; a later finite add is ignored; out.sign =
    inf_sign while is_inf && !is_nan."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push_bf16(dut, mant=5, exp=0)
    await push_bf16(dut, mant=0, exp=0, inf=1, inf_sign=1)   # −Inf
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["inf"], r["nan"], r["sign"]) == (1, 0, 1), "-Inf latch wrong: %r" % r
    await push_bf16(dut, mant=7, exp=0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["inf"], r["sign"]) == (1, 1), "Inf must persist over finite adds: %r" % r


@cocotb.test()
async def test_inf_collision_makes_nan(dut):
    """Inf + (−Inf) -> NaN (:193-195), and the output masks is_inf once
    is_nan (:285): out = {is_nan=1, is_inf=0}."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push_bf16(dut, mant=0, exp=0, inf=1, inf_sign=0)   # +Inf
    await push_bf16(dut, mant=0, exp=0, inf=1, inf_sign=1)   # −Inf
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["nan"], r["inf"]) == (1, 0), \
        "Inf+(−Inf) must be NaN with is_inf masked: %r" % r


@cocotb.test()
async def test_special_latches_even_with_zero_flag(dut):
    """The special branches sit ABOVE the !align_skip guard: a product with
    zero=1 AND nan=1 still latches NaN."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push_bf16(dut, mant=0, exp=0, zero=1, nan=1)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert r["nan"] == 1, "zero-flagged NaN product must still latch: %r" % r

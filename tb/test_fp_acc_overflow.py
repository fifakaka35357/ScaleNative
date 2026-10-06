"""
[C2 anchor ①, 2026-07-25] mac_fp_accumulator OVERFLOW branch — the first test
ever to reach it.

WHY it never ran: overflow fires when |sum_mant| crosses bit ACC_W-2 (=46 in
production, mac_fp_accumulator.sv:138). Alignment only shifts right and
|prod_mant| <= 2^15, so reaching 2^46 needs ~2^31 valid cycles — structurally
unreachable in simulation. Under every existing test the M36 renorm branch
(:226-233) incl. next_exp=align_exp+1 (:233) and the renorm sticky OR (:232)
is dead code, and the §A1 mutation evidence shows next_exp +1→+2 leaves the
whole suite green. This TB shrinks ACC_W to 20 via tb_fp_acc_ovf.sv
(INTERNAL_W=21, overflow at |sum| >= 2^18) so the SAME RTL lines execute.

Oracle: hand-computed small-integer cases (documented per test); bfp_golden.py
is NOT touched (golden rewrite is gated work — these anchors are its
prerequisite, HANDOFF_2026-07-25 §3C C2).

RED protocol (mutations applied to mac_fp_accumulator.sv, then reverted):
  M-ovf1: next_exp = align_exp + 10'sd1  ->  + 10'sd2  (M36 arm)
          => test_overflow_exact_power FAILS (exp 2 != 1) and
             test_overflow_renorm_sticky FAILS
  M-ovf2: drop `| renorm_sticky` in the M36 arm
          => ONLY test_overflow_renorm_sticky FAILS (mant 131072 != 131073)
  [GR-A 2026-07-28] renorm is now a compound select
  (neg&sum[0] ? S+2 : S) >>> 1 — no more u_renorm_shifter instance:
  GR-A β (renorm_base = S, dropping the +2):
          => ONLY test_overflow_negative_odd FAILS (131073 != 131071)
  Log: aichip_run_logs/k1cb_gra_mutBETA_red_20260728.log

Run: cd tb && make MODULE=test_fp_acc_overflow TOPLEVEL=tb_fp_acc_ovf \
  VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_tz_shifter.sv \
  ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv \
  ../tb/tb_fp_acc_ovf.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

MODE_BF16 = 4


def pack_bf16(mant, exp, zero=0, nan=0, inf=0, inf_sign=0):
    return (((mant & 0xFFFF) << 14) | ((exp & 0x3FF) << 4)
            | (zero << 3) | (nan << 2) | (inf << 1) | inf_sign)


def unpack_acc(raw):
    return dict(mant=(raw >> 13) & ((1 << 48) - 1),
                exp=((raw >> 3) & 0x3FF) - (1 << 10) if (raw >> 3) & 0x200 else (raw >> 3) & 0x3FF,
                sign=(raw >> 2) & 1, nan=(raw >> 1) & 1, inf=raw & 1)


async def reset_and_clear(dut):
    dut.clear.value = 0
    dut.valid_in.value = 0
    dut.mode.value = MODE_BF16
    dut.lru_in.value = 0
    dut.bf16_prod_in.value = 0
    dut.rst_n.value = 0
    for _ in range(2):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    # sync clear WITHOUT valid (SVA :315-317 forbids clear && valid_in)
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)


async def push(dut, mant, exp):
    dut.bf16_prod_in.value = pack_bf16(mant, exp)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)   # settle edge for race-free read


@cocotb.test()
async def test_overflow_exact_power(dut):
    """16 x {mant=16384, exp=0}: sum crosses 2^18 exactly on the 16th add.
    Hand math: 15 adds -> acc=245760@0 (no ovf, 245760 < 262144). 16th:
    sum=262144=2^18 -> ovf fires (:138) -> renorm 2^18>>1=131072, sticky=0,
    exp=0+1=1 (:233). Value preserved: 131072*2^1 = 2^18."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    for _ in range(15):
        await push(dut, 16384, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"]) == (245760, 0), "pre-ovf state wrong: %r" % r
    await push(dut, 16384, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"], r["sign"]) == (131072, 1, 0), \
        "overflow renorm wrong (M36 branch): %r (mutant +2 gives exp=2)" % r


@cocotb.test()
async def test_overflow_renorm_sticky(dut):
    """15 x 16384 then 1 x 16385: sum=262145 (== 1 mod 4) -> ovf ->
    renorm 262145>>1=131072 (even), renorm_sticky=1 -> mant=131072|1=131073
    (:232), exp=1. Dropping the sticky OR gives 131072 — 1 ulp silently lost."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    for _ in range(15):
        await push(dut, 16384, 0)
    await push(dut, 16385, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"]) == (131073, 1), \
        "renorm sticky lost (:232): %r" % r


@cocotb.test()
async def test_overflow_negative_odd(dut):
    """[GR-A 2026-07-28, review B3-1] NEGATIVE-ODD overflow renorm — the suite's
    first case in this corner (the compound/S+2 arm of the GR-A rewrite lives
    ONLY here; the pre-existing three cases are positive/even/no-ovf and were
    proven blind to a dropped +2 by three independent review replays).
    15 x {-16384} -> acc=-245760@0; then {-16385}: sum=-262145, bits[19:18]=10
    != {2{sign}}=11 -> ovf. Renorm tz: floor(-262145/2)=-131073, toward-zero
    +1 -> -131072, sticky(=sum[0])=1 OR into LSB -> -131071. exp=0+1=1.
    Output (|mant|, exp, sign) = (131071, 1, 1). β mutant (S for S+2) gives
    131073."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    for _ in range(15):
        await push(dut, -16384, 0)
    await push(dut, -16385, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"], r["sign"]) == (131071, 1, 1), \
        "negative-odd overflow renorm wrong (compound arm): %r" % r


@cocotb.test()
async def test_negative_boundary_no_overflow(dut):
    """Asymmetry pin: sum == -2^18 does NOT fire overflow (bits [19:18]=11 ==
    {2{sign}}), the exact two's-complement boundary. 16 x {mant=-16384}:
    acc mant field = |−2^18| = 262144 @ exp 0, sign=1, NO renorm."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    for _ in range(16):
        await push(dut, -16384, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"], r["sign"]) == (262144, 0, 1), \
        "negative boundary semantics changed: %r" % r

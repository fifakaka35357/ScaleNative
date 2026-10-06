"""
[GR-A 2026-07-28] mac_fp_acc_align clamp-arm big-value contract — SHIFT_MAX=4
shrink harness (tb_fp_acc_clamp.sv), review B2-F4/B3-4.

WHY it never bit: the clamp arm ('val flushed to 0, existence kept as sticky')
is value-distinguishable from a bare arithmetic shift only when
|shifter_in| >= 2^shift_amt with shift_amt > SHIFT_MAX. At production
SHIFT_MAX=40 that needs |mant| >= 2^41 — structurally unreachable in
simulation (alignment only shifts right; |prod_mant| <= 2^15), the same
verified-blind class the ACC_W=20 overflow harness was built to kill.
SHIFT_MAX=4 makes the SAME RTL arm value-visible: 128 >= 2^6.

Oracle: hand-computed. adopt {128,e0}; add {1,e6}: exp_diff=+6 > SHIFT_MAX=4
-> clamp: aligned_acc = 0 | sticky(|128|!=0) = 1; sum = 1+1 = 2 @ e6.
δ mutant (clamp arm = bare >>>): raw=128>>6=2, K[0]=res&~raw[0]=1 -> sum=4.
α mutant (drop K[0] post-GR-A): sum=1. Both diverge from 2.

RED protocol: GR-A δ/α mutations to mac_tz_shifter.sv / mac_fp_acc_align.sv,
then reverted (K1cb_Preflight v3 §3.2).

Run: cd tb && make MODULE=test_fp_acc_clamp TOPLEVEL=tb_fp_acc_clamp \
  VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_tz_shifter.sv \
  ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv \
  ../tb/tb_fp_acc_clamp.sv"
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
    e = (raw >> 3) & 0x3FF
    return dict(mant=(raw >> 13) & ((1 << 48) - 1),
                exp=e - (1 << 10) if e & 0x200 else e,
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
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)


async def push(dut, mant, exp):
    dut.bf16_prod_in.value = pack_bf16(mant, exp)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    dut.valid_in.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_clamp_bigval_contract(dut):
    """adopt {128,e0}; add {1,e6} under SHIFT_MAX=4: clamp arm, big value.
    Contract: aligned_acc = 0|sticky = 1 -> sum = 2 @ e6, sign 0.
    δ mutant gives 4; α mutant (post-GR-A) gives 1."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push(dut, 128, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"]) == (128, 0), "adopt wrong: %r" % r
    await push(dut, 1, 6)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"], r["sign"]) == (2, 6, 0), \
        "clamp big-value contract broken: %r" % r

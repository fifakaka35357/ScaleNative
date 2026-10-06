"""
[C2 anchor ②, 2026-07-25] mac_fp_acc_align sticky-OR (:216/:222) — the first
BIT-EXACT assertion on the alignment sticky at production ACC_W=48.

WHY it never bit: under the main gemm stimulus every operand shares one
exponent, so the aligner takes the zero-shift path (mac_tz_shifter.sv:97-99,
sticky=0) — M2M3_AnchorPlan §A1: "shifter_sticky (216/222) and renorm_sticky
always 0". test_m37_expwide executes :216 once via the clamp path but only
checks rel<1e-3, which a 1-LSB sticky loss sits inside. These cases assert
exact integers.

Oracle: hand-computed (each docstring shows the arithmetic). Direct
TOPLEVEL=mac_fp_accumulator (packed-struct ports driven as flat ints).

RED protocol (mutations to mac_fp_acc_align.sv, then reverted).
[GR-A 2026-07-28] the sticky OR-into-LSB lines (:216/:222 of the pre-GR-A
file) are gone — sticky now folds into the K addend (K[0]=res&~raw[0],
K[1]=res&neg&raw[0]) consumed by the accumulator's CSA row. The anchors:
  GR-A α  (drop K[0]): acc/prod-shifted + clamp cases FAIL (this file 4/5 red)
  GR-A α2 (drop K[1]): ONLY test_sticky_negative_residue_quirk FAILS
          (sum mis-detected as 0 -> M35 false re-anchor)
Logs: aichip_run_logs/k1cb_gra_mutALPHA{,2}_red_20260728.log

Run: cd tb && make MODULE=test_fp_acc_sticky TOPLEVEL=mac_fp_accumulator \
  VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_tz_shifter.sv \
  ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv"
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
    dut.clear.value = 1          # never together with valid_in (SVA :315)
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
async def test_sticky_acc_shifted_216(dut):
    """:216 (acc shifted): adopt {3,e0}; add {1,e4}. exp_diff=+4 -> acc 3>>4=0
    + sticky=1 -> aligned_acc=1; sum=1+1=2 @ e4 = 32.0. Dropped OR -> 16.0."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push(dut, 3, 0)
    await push(dut, 1, 4)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"]) == (2, 4), "align sticky :216 lost: %r" % r


@cocotb.test()
async def test_sticky_prod_shifted_222(dut):
    """:222 (prod shifted): adopt {1,e4}; add {3,e0}. exp_diff=-4 -> prod
    3>>4=0 + sticky=1 -> aligned_prod=1; sum=2 @ e4 = 32.0."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push(dut, 1, 4)
    await push(dut, 3, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"]) == (2, 4), "align sticky :222 lost: %r" % r


@cocotb.test()
async def test_sticky_clamp_path(dut):
    """SHIFT_MAX clamp: adopt {3,e0}; add {1,e41}. shift 41 > 40 -> clamp:
    val_out=0, sticky=|3| (mac_tz_shifter.sv:89-92) -> aligned_acc=1;
    sum=2 @ e41."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push(dut, 3, 0)
    await push(dut, 1, 41)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"]) == (2, 41), "clamp sticky lost: %r" % r


@cocotb.test()
async def test_sticky_clamp_neg_acc(dut):
    """[GR-A 2026-07-28, review B3-4] NEGATIVE-value clamp — previously zero
    coverage (the only clamp case used +3). adopt {-3,e0}; add {1,e41}:
    shift 41 > SHIFT_MAX(40) -> clamp: val_out=0, sticky=|-3|!=0=1 ->
    aligned_acc = 0|1 = +1 (negative operand flushed to a positive ulp —
    frozen semantics, same family as the residue quirk above); sum = 1+1 = 2
    @ e41, sign 0."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push(dut, -3, 0)
    await push(dut, 1, 41)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"], r["sign"]) == (2, 41, 0), \
        "negative clamp semantics changed: %r" % r


@cocotb.test()
async def test_sticky_negative_residue_quirk(dut):
    """FROZEN-SEMANTICS pin: sticky ORs into the TWO'S-COMPLEMENT word after
    toward-zero correction. adopt {-3,e0}; add {1,e4}: acc -3>>>4 = -1, tz
    correction +1 -> 0, sticky=1 -> aligned_acc=+1 (a negative residue turns
    into a POSITIVE ulp); sum=+2 @ e4 = +32, sign flips 1->0. Do not 'fix'."""
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset_and_clear(dut)
    await push(dut, -3, 0)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["sign"]) == (3, 1), "adopt of -3 wrong: %r" % r
    await push(dut, 1, 4)
    r = unpack_acc(int(dut.fp_acc_out.value))
    assert (r["mant"], r["exp"], r["sign"]) == (2, 4, 0), \
        "negative-residue sticky semantics changed: %r" % r

"""
cocotb regression for mac_cell — HW-REVIEW TIER-1 weight_mul dataflow mux.

The OS-GEMM re-wire makes the MULTIPLY tap the PRE-register weight in OS mode
(dataflow_sel=0) while keeping the registered, stationary weight in WS mode
(dataflow_sel=1). This is the frozen-leaf compensation for the +1 weight-vs-act
offset, and the adversarial concern is that a wrong mux silently corrupts WS GEMM
(or fails to compensate OS). This test pins the mux directly and INDEPENDENTLY of
the array, by loading a STALE value into weight_reg and then driving a DIFFERENT
value on weight_in at multiply time:

  WS (dataflow_sel=1): product must use weight_reg (the loaded, stationary value),
                       IGNORING the new weight_in  -> proves WS is unperturbed.
  OS (dataflow_sel=0): product must use weight_in (pre-register), IGNORING the
                       stale weight_reg            -> proves the compensation.
  Both: weight_stream_out (south systolic pipeline) must ALWAYS equal weight_reg,
                       independent of dataflow_sel  -> proves the row hop is intact.

A swapped/broken mux makes WS read weight_in (=> stale-vs-new mismatch) or OS read
weight_reg, both caught here. BF16 mode (mx scale unused). Values are small exact
integers so fp_acc_out decodes bit-exact.

Run: cd tb && make MODULE=test_mac_cell_dataflow TOPLEVEL=mac_cell \
        VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_lru.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_fp_acc_align.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_cell.sv"
"""
import os
import sys
import math
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

BF16 = g.MODE_BF16
LANE_MASK_1 = 0x1   # tensor_pkg mode_full_lane_mask(BF16)


async def reset(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    dut.rst_n.value            = 0
    dut.mode.value             = BF16
    dut.mac_en.value           = 0
    dut.array_step_en.value    = 1   # §C6: clocks the FP feedforward stage
    dut.clear_acc.value        = 0
    dut.capture_fire.value     = 0
    dut.lane_valid.value       = 0
    dut.weight_in.value        = 0
    dut.weight_load.value      = 0
    dut.weight_stream_en.value = 0
    dut.dataflow_sel.value     = 1
    dut.act_in.value           = 0
    dut.mx_scale_a_cur.value   = 127
    dut.mx_scale_b_cur.value   = 127
    dut.psum_in.value          = 0
    dut.sparsity_map_in.value  = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def run_bf16_mac(dut, dataflow_sel, w_reg, w_at_b, act):
    """Load w_reg into weight_reg, then multiply with a DIFFERENT weight_in=w_at_b.
    Returns (packed fp_acc_out, weight_stream_out observed at cycle B)."""
    # Cycle A: latch w_reg into weight_reg + clear accumulator (no compute).
    dut.mode.value             = BF16
    dut.dataflow_sel.value     = dataflow_sel
    dut.weight_in.value        = g.bf16_bits(float(w_reg)) & 0xFFFF
    dut.weight_load.value      = 1
    dut.clear_acc.value        = 1
    dut.array_step_en.value    = 0   # §C6: controller never steps during CLEAR_ACC
    dut.mac_en.value           = 0
    dut.act_in.value           = 0
    dut.lane_valid.value       = 0
    dut.weight_stream_en.value = 1     # south pipeline active
    await RisingEdge(dut.clk)

    # Cycle B: one valid compute with a DIFFERENT weight_in. weight_load=0 so
    # weight_reg HOLDS w_reg; weight_in now carries w_at_b.
    dut.weight_load.value = 0
    dut.clear_acc.value   = 0
    dut.array_step_en.value = 1
    dut.weight_in.value   = g.bf16_bits(float(w_at_b)) & 0xFFFF
    dut.act_in.value      = g.bf16_bits(float(act)) & 0xFFFF
    dut.lane_valid.value  = LANE_MASK_1
    dut.mac_en.value      = 1
    await RisingEdge(dut.clk)
    # weight_stream_out is combinational from weight_reg (post-register) — sample
    # it now (cycle B inputs settled): must be w_reg regardless of dataflow_sel.
    stream_out = int(dut.weight_stream_out.value)

    # Settle: with the §C6 stage, cycle B's product is consumed at the FIRST
    # settle edge; read one edge later so the registered fp_acc_out is race-free.
    dut.mac_en.value     = 0
    dut.lane_valid.value = 0
    await RisingEdge(dut.clk)   # §C6-b/c: c6f front rank edge (B.1 latency-only, 2026-07-27)
    await RisingEdge(dut.clk)   # 🔴 [K1b 2026-08-08] c6g seam edge —— **latency-only**：
                                #    只把采样点后移一拍，**金标一位不改**（D-600MHZ-NO-GOLDEN-REWRITE）。
                                #    判据 = aichip_run_logs/b58k1b_prereg_20260808.md R-1
    await RisingEdge(dut.clk)   # §C6: stage → accumulator consumption edge
    await RisingEdge(dut.clk)
    return int(dut.fp_acc_out.value), stream_out


@cocotb.test()
async def test_weight_mul_dataflow_mux(dut):
    await reset(dut)
    fails = []

    # Distinct values so a swapped mux gives a clearly wrong product.
    #   WS: weight_reg=3, weight_in@B=5, act=2 -> WS uses 3 -> 6  (broken: 5 -> 10)
    #   OS: weight_reg=7(stale), weight_in@B=3, act=2 -> OS uses 3 -> 6 (broken: 7 -> 14)
    w_reg_bf16 = g.bf16_bits(3.0)   # the value loaded into weight_reg

    # ---- WS (dataflow_sel=1): multiply must use weight_reg (stationary) ----
    raw, stream = await run_bf16_mac(dut, dataflow_sel=1, w_reg=3.0, w_at_b=5.0, act=2.0)
    ws = g.decode_fp_acc_out(raw, BF16)
    if not math.isclose(ws["value"], 3.0 * 2.0, abs_tol=1e-9):
        fails.append("WS: product=%.4f, expected 6.0 (weight_reg=3*act=2). A wrong mux "
                     "tapping weight_in would give 10.0 — WS GEMM corrupted." % ws["value"])
    if stream != w_reg_bf16:
        fails.append("WS: weight_stream_out=0x%04x != weight_reg(3.0)=0x%04x" % (stream, w_reg_bf16))

    # ---- OS (dataflow_sel=0): multiply must use weight_in (pre-register) ----
    raw, stream = await run_bf16_mac(dut, dataflow_sel=0, w_reg=7.0, w_at_b=3.0, act=2.0)
    os_ = g.decode_fp_acc_out(raw, BF16)
    if not math.isclose(os_["value"], 3.0 * 2.0, abs_tol=1e-9):
        fails.append("OS: product=%.4f, expected 6.0 (weight_in=3*act=2). A wrong mux "
                     "tapping the stale weight_reg would give 14.0 — OS uncompensated." % os_["value"])
    # In OS the south pipeline must STILL stream the registered (stale) weight=7.0.
    if stream != (g.bf16_bits(7.0) & 0xFFFF):
        fails.append("OS: weight_stream_out=0x%04x != weight_reg(7.0)=0x%04x (south pipeline "
                     "must stay on the registered weight)" % (stream, g.bf16_bits(7.0) & 0xFFFF))

    assert not fails, "mac_cell dataflow mux failures:\n  " + "\n  ".join(fails)
    dut._log.info("mac_cell weight_mul mux OK: WS multiplies weight_reg (3*2=6), "
                  "OS multiplies pre-register weight_in (3*2=6 ignoring stale reg=7), "
                  "south stream = weight_reg in both modes")

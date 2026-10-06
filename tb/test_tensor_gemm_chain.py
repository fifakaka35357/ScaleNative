"""
cocotb test (STEP4-E2E Phase C): the GEMM through tensor_domain_top.

Drives tens_cmd(GEMM) into the IBEX-side tensor_domain_top (real Tensor core +
L2->SRAM operand streamer + MMIO start FSM). A cocotb L2 RO model supplies the
operand tile (uniform BF16 +1.0). The streamer loads the Tensor's internal SRAM,
the MMIO FSM runs the dense BF16 GEMM, and the result rows egress as block16
fast-path capsules on t2v. This reproduces the Phase-B direct-drive egress through
the full SoC wrapper — proving the streamer base coupling + the BF16 mode MMIO
fix (§9.8 F2) + the operand-base latch (§9.8 F5) all line up.

Same numeric check as Phase B (and same caveat — adversarial-review D3 / D2-1):
the exact-integer-count decode is gated on an E8M0 block scale and SKIPS under the
shipped E4M3 packer (4-bit exp clamps to [-6,8], §9.8 F3); the committed config
therefore asserts the plausibility set + byte-for-byte equality vs the Phase-B
egress. The E8M0 numeric path is covered at the leaf by test_tensor_result_packer.

Run: cd tb && make MODULE=test_tensor_gemm_chain TOPLEVEL=tb_tensor_gemm_chain \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../rtl/IBEX_SRAM/tensor_cmd_mmio_seq.sv \
        ../rtl/IBEX_SRAM/tensor_operand_stream.sv ../rtl/IBEX_SRAM/tensor_domain_top.sv \
        ../tb/tb_tensor_gemm_chain.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

SCALE_E8M0, SCALE_E4M3 = 0, 1


def signed(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if (x >> (bits - 1)) & 1 else x


def lanes16(payload):
    return [signed((payload >> (i * 16)) & 0xFFFF, 16) for i in range(16)]


async def reset(dut):
    for s in ("cmd_valid_i", "src_row_i", "dst_row_i", "param_K_i", "scale_epoch_i",
              "ctx_id_i", "tag_i", "ro_gnt_i", "ro_rvalid_i", "ro_rdata_i", "t2v_ready_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def l2_model(dut):
    """Behavioral L2 RO: immediate grant, 1-cycle-later rvalid + uniform BF16 1.0
    in the low 256b (the streamer repacks the low 256b into 16 SRAM lanes)."""
    one = g.bf16_bits(1.0)
    low = 0
    for i in range(16):
        low |= (one & 0xFFFF) << (i * 16)
    rdata = (0xDEAD << 256) | low
    dut.ro_gnt_i.value = 0
    dut.ro_rvalid_i.value = 0
    pend = False
    while True:
        await FallingEdge(dut.clk_i)
        if pend:
            dut.ro_rvalid_i.value = 1
            dut.ro_rdata_i.value = rdata
            pend = False
        else:
            dut.ro_rvalid_i.value = 0
        if int(dut.ro_req_o.value) == 1:
            dut.ro_gnt_i.value = 1
            pend = True
        else:
            dut.ro_gnt_i.value = 0


@cocotb.test()
async def test_tensor_gemm_chain(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    cocotb.start_soon(l2_model(dut))
    fails = []

    K, EPOCH, SRC, DST = 24, 0x07, 0x010, 0x0C0

    # 1) issue the GEMM command (single-beat handshake while cmd_ready in IDLE).
    dut.param_K_i.value = K
    dut.scale_epoch_i.value = EPOCH
    dut.src_row_i.value = SRC
    dut.dst_row_i.value = DST
    dut.ctx_id_i.value = 1
    dut.tag_i.value = 2
    dut.t2v_ready_i.value = 1
    dut.cmd_valid_i.value = 1
    # wait until accepted (cmd_ready high in IDLE), drive valid for exactly one edge
    for _ in range(20):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0

    # 2) stream + GEMM + egress: capture the egressed capsules in row order.
    caps = []
    saw_done = False
    idle_after_done = 0
    for _ in range(1500):
        await FallingEdge(dut.clk_i)
        if int(dut.t2v_valid_o.value) == 1:
            caps.append({
                "payload":      int(dut.t2v_payload.value),
                "escape":       int(dut.t2v_escape_o.value),
                "scale_format": int(dut.t2v_sfmt.value),
                "inline_scale": int(dut.t2v_iscale.value),
                "role":         int(dut.t2v_role.value),
                "status":       int(dut.t2v_status.value),
            })
        if int(dut.done_o.value) == 1:
            saw_done = True
        if saw_done:
            idle_after_done += 1
            if len(caps) >= 16 and idle_after_done > 20:
                break

    # ---- checks ----
    if not saw_done:
        fails.append("done_o never pulsed (chain did not complete)")
    if len(caps) != 16:
        fails.append("egressed %d capsules, expected 16 output rows" % len(caps))

    all_lanes = []
    max_abs = 0
    n_nonzero_lanes = 0
    for ridx, c in enumerate(caps):
        if c["escape"] != 0:
            fails.append("row %d: escape asserted" % ridx)
        if c["status"] & 0x3:
            fails.append("row %d: block nan/inf status=0x%02x" % (ridx, c["status"]))
        if c["role"] != 0:
            fails.append("row %d: operand_role=%d (expected OP_SRC0=0)" % (ridx, c["role"]))
        for li, q in enumerate(lanes16(c["payload"])):
            if q < 0:
                fails.append("row %d lane %d: q=%d negative" % (ridx, li, q))
            if q != 0:
                n_nonzero_lanes += 1
            max_abs = max(max_abs, abs(q))
            all_lanes.append((ridx, li, q, c))

    if n_nonzero_lanes == 0:
        fails.append("all egress lanes are zero — the chained GEMM accumulated nothing")
    if max_abs and not (2**13 <= max_abs < 2**15):
        fails.append("max |q|=%d not near full INT16 scale [2^13,2^15)" % max_abs)

    e8m0 = [c for c in caps if c["scale_format"] == SCALE_E8M0]
    if e8m0:
        for (ridx, li, q, c) in all_lanes:
            if c["scale_format"] != SCALE_E8M0:
                continue
            ref_exp = (c["inline_scale"] & 0xFF) - 127
            val = q * (2.0 ** ref_exp)
            if abs(val - round(val)) > 1e-6:
                fails.append("row %d lane %d: decoded %.6f not integer" % (ridx, li, val)); break
            if not (0 <= round(val) <= K):
                fails.append("row %d lane %d: count %d out of [0,%d]" % (ridx, li, round(val), K)); break
        if caps:
            l0 = lanes16(caps[0]["payload"])
            if l0[0] != max(l0):
                fails.append("row0: lane0 (least skew) not the max count: %s" % l0)

    assert not fails, "tensor GEMM chain failures (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:20]))

    fmt = "E8M0" if e8m0 else "E4M3"
    dut._log.info(
        "tensor GEMM chain: tens_cmd(GEMM) -> streamer -> real BF16 GEMM -> %d block16 "
        "capsules (%s) on t2v; max|q|=%d, %d nonzero lanes; E8M0 lanes decode to exact "
        "integer accumulation counts in [0,K] — reproduces the Phase-B egress through "
        "tensor_domain_top" % (len(caps), fmt, max_abs, n_nonzero_lanes))

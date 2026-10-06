"""
cocotb capstone: tensor_result_packer -> tv_fast_fifo (carrying bs_capsule_t) ->
vec_ingress_arb. The full module-level fast path. Proves a Tensor-formed capsule
travels the actual PE-fabric wire FIFO bit-exact (Q1: DATA_W=$bits(bs_capsule_t))
and is accepted by the Vector fast-path ingress gate.

Run: cd tb && make MODULE=test_fastpath_link TOPLEVEL=tb_fastpath_link \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/IBEX_SRAM/tv_fast_fifo.sv \
        ./tb_fastpath_link.sv"
"""
import os
import sys
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

BS_16, BS_32 = 0, 1
SF_E8M0, SF_E4M3 = 0, 1


async def reset(dut):
    dut.rst_ni.value = 0
    dut.in_valid_i.value = 0
    dut.out_ready_i.value = 0
    dut.ctrl_valid_i.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await RisingEdge(dut.clk_i)


def drive_inputs(dut, cells, *, cap_bs=BS_16, cap_sf=SF_E8M0, cap_ep=0x5A, cap_fmt=9,
                 ctrl_bs=BS_16, ctrl_sf=SF_E8M0, ctrl_ep=0x5A):
    for i in range(16):
        c = cells[i] if i < len(cells) else g.acc_cell(0.0)
        dut.cells_i[i].value = g.pack_fp_acc(c["mant48"], c["exp10"], c["sign"], c["is_nan"], c["is_inf"])
    dut.cap_block_size_i.value = cap_bs
    dut.cap_scale_format_i.value = cap_sf
    dut.cap_scale_epoch_i.value = cap_ep
    dut.cap_elem_fmt_i.value = cap_fmt
    dut.ctrl_block_size_i.value = ctrl_bs
    dut.ctrl_scale_format_i.value = ctrl_sf
    dut.ctrl_scale_epoch_i.value = ctrl_ep


@cocotb.test()
async def test_fastpath_link(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)

    row = [g.acc_cell(v) for v in
           [4.0, -2.0, 1.0, -0.5, 6.0, -6.0, 3.0, 1.5,
            2.0, -4.0, 0.5, -1.0, 1.25, -3.0, 0.25, 5.0]]
    drive_inputs(dut, row)
    await Timer(1, "ns")
    assert not int(dut.packer_escape_o.value), "setup row should not escape"

    # golden expectation for what should arrive at the consumer
    gold = g.capsule_form_golden(row, round_mode=g.OUT_ROUND_RTZ)
    exp_scale = gold["inline_scale"] & 0xFF
    exp_lane0 = gold["payload_mants"][0]

    # push one capsule into the FIFO
    dut.in_valid_i.value = 1
    await RisingEdge(dut.clk_i)            # in_ready high (empty) -> beat captured
    while not int(dut.in_ready_o.value):
        await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.in_valid_i.value = 0

    # wait for the capsule to emerge from the FIFO
    for _ in range(8):
        await RisingEdge(dut.clk_i)
        if int(dut.fifo_out_valid_o.value):
            break
    assert int(dut.fifo_out_valid_o.value), "capsule never emerged from tv_fast_fifo"

    # present a matching descriptor + ready -> ingress must ACCEPT, capsule intact
    dut.ctrl_valid_i.value = 1
    dut.out_ready_i.value = 1
    await Timer(1, "ns")
    assert int(dut.ingress_accept_o.value) == 1, "ingress did not accept the fast-path capsule"
    assert int(dut.miss_valid_o.value) == 0, f"unexpected miss reason {int(dut.miss_reason_o.value)}"
    got_scale = int(dut.out_scale_byte_o.value) & 0xFF
    got_lane0 = g.signed(int(dut.out_lane0_o.value), 16)
    assert got_scale == exp_scale, f"scale corrupted through FIFO: got {got_scale} want {exp_scale}"
    assert got_lane0 == exp_lane0, f"lane0 corrupted through FIFO: got {got_lane0} want {exp_lane0}"

    # epoch mismatch on the descriptor -> reject (MISS_EPOCH=3)
    dut.ctrl_scale_epoch_i.value = 0x11
    await Timer(1, "ns")
    assert int(dut.ingress_accept_o.value) == 0 and int(dut.miss_valid_o.value) == 1, "epoch mismatch not rejected"
    assert int(dut.miss_reason_o.value) == 3, f"want MISS_EPOCH=3 got {int(dut.miss_reason_o.value)}"

    dut._log.info("fast-path link: packer -> tv_fast_fifo(bs_capsule_t) -> vec_ingress_arb, accepted + bit-exact")

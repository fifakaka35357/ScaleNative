"""
cocotb test for tensor_operand_stream (STEP4-E2E inc 3b): the L2->Tensor-SRAM
operand streamer. A behavioral L2 RO model answers each read (gnt same cycle,
rvalid+rdata one cycle later) with a per-row data pattern; the test checks the
DMA write stream — phase order (WGT then ACT then SCL), sequential destination
addresses from the bases, and the documented low-256b repack — vs a golden, then
that load_done pulses.

Run: cd tb && make MODULE=test_tensor_operand_stream TOPLEVEL=tb_tensor_operand_stream \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/tensor_operand_stream.sv \
        ../tb/tb_tensor_operand_stream.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

LANES = 16
MASK512 = (1 << 512) - 1


def l2_pattern(row):
    """Deterministic 512b L2 row content. Lane i (16b) = (row<<8)|i in the low
    256b; the high 256b is distinct so we can confirm the streamer ignores it."""
    v = 0
    for i in range(LANES):
        v |= (((row << 8) | i) & 0xFFFF) << (i * 16)
    v |= (0xDEAD << 256)   # high half: must be ignored by the repack
    return v & MASK512


def exp_wgt_act(row):
    """Expected 256b flattened {16x16b} = low 256b of the pattern."""
    return l2_pattern(row) & ((1 << 256) - 1)


def exp_scl(row):
    """Expected scale halves: wgt = low 128b (16x8b), act = next 128b."""
    p = l2_pattern(row)
    return (p & ((1 << 128) - 1), (p >> 128) & ((1 << 128) - 1))


async def reset(dut):
    for s in ("start_i", "n_wgt_i", "n_act_i", "n_scl_i", "l2_wgt_base_i", "l2_act_base_i",
              "l2_scl_base_i", "sram_wgt_base_i", "sram_act_base_i", "sram_scl_base_i",
              "ro_gnt_i", "ro_rvalid_i", "ro_rdata_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def l2_model(dut, log):
    """Drive ro_gnt (= ro_req, immediate grant) and a 1-cycle-later ro_rvalid+rdata.
    Records (row) reads so the test can confirm the source addressing."""
    dut.ro_gnt_i.value = 0
    dut.ro_rvalid_i.value = 0
    pend = None
    while True:
        await FallingEdge(dut.clk_i)
        # deliver rvalid scheduled by the previous grant
        if pend is not None:
            dut.ro_rvalid_i.value = 1
            dut.ro_rdata_i.value = l2_pattern(pend)
            log.append(("read", pend))
            pend = None
        else:
            dut.ro_rvalid_i.value = 0
        # grant the current request (immediate), schedule rvalid for next cycle
        if int(dut.ro_req_o.value) == 1:
            dut.ro_gnt_i.value = 1
            pend = int(dut.ro_row_o.value)
        else:
            dut.ro_gnt_i.value = 0


@cocotb.test()
async def test_tensor_operand_stream(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    reads = []
    cocotb.start_soon(l2_model(dut, reads))

    N_WGT, N_ACT, N_SCL = 3, 2, 1
    L2_WB, L2_AB, L2_SB = 0x40, 0x60, 0x70   # L2 source bases
    SR_WB, SR_AB, SR_SB = 0x10, 0x20, 0x30   # SRAM dest bases
    dut.n_wgt_i.value = N_WGT
    dut.n_act_i.value = N_ACT
    dut.n_scl_i.value = N_SCL
    dut.l2_wgt_base_i.value = L2_WB
    dut.l2_act_base_i.value = L2_AB
    dut.l2_scl_base_i.value = L2_SB
    dut.sram_wgt_base_i.value = SR_WB
    dut.sram_act_base_i.value = SR_AB
    dut.sram_scl_base_i.value = SR_SB

    # build the golden DMA write stream: ('wgt'/'act'/'scl', addr, data...)
    golden = []
    for k in range(N_WGT):
        golden.append(("wgt", SR_WB + k, exp_wgt_act(L2_WB + k)))
    for k in range(N_ACT):
        golden.append(("act", SR_AB + k, exp_wgt_act(L2_AB + k)))
    for k in range(N_SCL):
        w, a = exp_scl(L2_SB + k)
        golden.append(("scl", SR_SB + k, (w, a)))

    # pulse start
    dut.start_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.start_i.value = 0

    # capture the DMA write stream
    captured = []
    done = False
    for _ in range(200):
        await FallingEdge(dut.clk_i)
        if int(dut.dma_wgt_wr_en_o.value) == 1:
            captured.append(("wgt", int(dut.dma_wgt_wr_addr_o.value), int(dut.dma_wgt_wr_data_o.value)))
        if int(dut.dma_act_wr_en_o.value) == 1:
            captured.append(("act", int(dut.dma_act_wr_addr_o.value), int(dut.dma_act_wr_data_o.value)))
        if int(dut.dma_scale_wr_en_o.value) == 1:
            captured.append(("scl", int(dut.dma_scale_wr_addr_o.value),
                             (int(dut.dma_scale_wr_data_wgt_o.value), int(dut.dma_scale_wr_data_act_o.value))))
        if int(dut.load_done_o.value) == 1:
            done = True
            break

    if not done:
        fails.append("load_done never pulsed")
    if len(captured) != len(golden):
        fails.append("write count: got %d exp %d\n   got=%s" %
                     (len(captured), len(golden), [(p, hex(a)) for p, a, _ in captured]))
    else:
        for idx, (g, c) in enumerate(zip(golden, captured)):
            if g[0] != c[0] or g[1] != c[1] or g[2] != c[2]:
                fails.append("write %d: got (%s,%s,%s) exp (%s,%s,%s)" %
                             (idx, c[0], hex(c[1]), c[2], g[0], hex(g[1]), g[2]))

    # source addressing: reads should be l2 bases + offsets, in phase order
    exp_reads = ([L2_WB + k for k in range(N_WGT)] +
                 [L2_AB + k for k in range(N_ACT)] +
                 [L2_SB + k for k in range(N_SCL)])
    got_reads = [r for _, r in reads]
    if got_reads != exp_reads:
        fails.append("L2 source rows: got %s exp %s" %
                     ([hex(x) for x in got_reads], [hex(x) for x in exp_reads]))

    assert not fails, "tensor_operand_stream failures (%d):\n  %s" % (
        len(fails), "\n  ".join(fails))
    dut._log.info("tensor_operand_stream: WGT/ACT/SCL stream + repack + addressing + load_done OK")

"""
cocotb test (STEP4-E2E §11, D-E2E-BENCH P2): REAL l2_subsystem bank-half routing.

Proves the half_sel -> physical-bank mapping through the real l2_rw_arbiter +
behavioral bank SRAM: a Vector RW write with half_sel=1 lands in banks 8-15 (and
0-7 untouched); half_sel=0 lands in banks 0-7 (8-15 untouched). Read back per
physical bank via the dma_evict single-bank port. Hand-computable golden:
bank (base+j) holds wdata[j*32 +: 32], base=8 if half_sel else 0.

The "teeth" are the untouched-half==0 assertions (sim-only: behavioral SRAM
zero-inits) — without them a write that wrongly fanned out to all 16 banks would
still pass a bank-8-only check.

Run: cd tb && make MODULE=test_l2_vec_half_readback TOPLEVEL=tb_l2_vec_half_readback \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_bank.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_ro_arbiter.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_rw_arbiter.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_subsystem.sv \
        ../tb/tb_l2_vec_half_readback.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge


async def reset(dut):
    for s in ("vec_rw_req_i", "vec_rw_row_i", "vec_rw_half_sel_i", "vec_rw_bank_mask_i",
              "vec_rw_wdata_i", "dma_evict_req_i", "dma_evict_bank_i", "dma_evict_row_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def vec_write(dut, row, half_sel, wdata256, fails, mask=0xFF):
    """Lone Vector RW write — grants combinationally; commits at the edge."""
    dut.vec_rw_row_i.value = row
    dut.vec_rw_half_sel_i.value = half_sel
    dut.vec_rw_bank_mask_i.value = mask
    dut.vec_rw_wdata_i.value = wdata256
    dut.vec_rw_req_i.value = 1
    await RisingEdge(dut.clk_i)
    if int(dut.vec_rw_gnt_o.value) != 1:
        fails.append("vec_rw_gnt not asserted for lone write (row=0x%x)" % row)
    dut.vec_rw_req_i.value = 0
    await RisingEdge(dut.clk_i)        # let the write settle


async def evict_read(dut, bank, row):
    """Single-bank readback. gnt combinational (E0); [C2] with l2_bank OUT_REG=1
    the RW-port dout is registered → rvalid+rdata arrive TWO cycles later (E2)."""
    dut.dma_evict_bank_i.value = bank
    dut.dma_evict_row_i.value = row
    dut.dma_evict_req_i.value = 1
    await RisingEdge(dut.clk_i)        # E0: grant
    await RisingEdge(dut.clk_i)        # E1
    await RisingEdge(dut.clk_i)        # E2: rvalid + rdata (2-cycle L2 read)
    val = int(dut.dma_evict_rdata_o.value)
    rv = int(dut.dma_evict_rvalid_o.value)
    dut.dma_evict_req_i.value = 0
    await RisingEdge(dut.clk_i)
    return val, rv


def lane(wdata, j):
    return (wdata >> (j * 32)) & 0xFFFFFFFF


@cocotb.test()
async def test_l2_half_sel_high(dut):
    """half_sel=1 -> banks 8-15 hold the data, banks 0-7 untouched (==0)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    ROW = 0x055
    P = 0
    for k in range(8):
        P |= ((0xA0000000 | (k << 16) | (0xB000 + k)) & 0xFFFFFFFF) << (k * 32)
    await vec_write(dut, ROW, 1, P, fails)
    if not fails:
        for j in range(8):
            val, rv = await evict_read(dut, 8 + j, ROW)
            if rv != 1:
                fails.append("bank %d: no rvalid" % (8 + j))
            elif val != lane(P, j):
                fails.append("bank %d: got 0x%08x exp 0x%08x" % (8 + j, val, lane(P, j)))
        # teeth: the low half must be untouched
        for b in (0, 3, 7):
            val, _ = await evict_read(dut, b, ROW)
            if val != 0:
                fails.append("bank %d (low half) = 0x%08x, expected untouched 0 (half_sel=1 leaked!)" % (b, val))
    assert not fails, "half_sel=1 failures:\n  " + "\n  ".join(fails)
    dut._log.info("P2: half_sel=1 write landed in banks 8-15, banks 0-7 untouched (real l2_rw_arbiter)")


@cocotb.test()
async def test_l2_half_sel_low(dut):
    """half_sel=0 -> banks 0-7 hold the data, banks 8-15 untouched (==0)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    ROW = 0x0AA
    Q = 0
    for k in range(8):
        Q |= ((0xC0000000 | (k << 16) | (0xD000 + k)) & 0xFFFFFFFF) << (k * 32)
    await vec_write(dut, ROW, 0, Q, fails)
    if not fails:
        for j in range(8):
            val, rv = await evict_read(dut, j, ROW)
            if rv != 1:
                fails.append("bank %d: no rvalid" % j)
            elif val != lane(Q, j):
                fails.append("bank %d: got 0x%08x exp 0x%08x" % (j, val, lane(Q, j)))
        for b in (8, 11, 15):
            val, _ = await evict_read(dut, b, ROW)
            if val != 0:
                fails.append("bank %d (high half) = 0x%08x, expected untouched 0 (half_sel=0 leaked!)" % (b, val))
    assert not fails, "half_sel=0 failures:\n  " + "\n  ".join(fails)
    dut._log.info("P2: half_sel=0 write landed in banks 0-7, banks 8-15 untouched")


@cocotb.test()
async def test_l2_both_halves_disjoint(dut):
    """Write both halves at the SAME row -> physically disjoint banks."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    ROW = 0x123
    Q = 0    # low half
    P = 0    # high half
    for k in range(8):
        Q |= ((0x11110000 | k) & 0xFFFFFFFF) << (k * 32)
        P |= ((0x99990000 | k) & 0xFFFFFFFF) << (k * 32)
    await vec_write(dut, ROW, 0, Q, fails)
    await vec_write(dut, ROW, 1, P, fails)
    if not fails:
        for j in range(8):
            v0, _ = await evict_read(dut, j, ROW)
            if v0 != lane(Q, j):
                fails.append("low bank %d: got 0x%08x exp 0x%08x" % (j, v0, lane(Q, j)))
            v1, _ = await evict_read(dut, 8 + j, ROW)
            if v1 != lane(P, j):
                fails.append("high bank %d: got 0x%08x exp 0x%08x" % (8 + j, v1, lane(P, j)))
    assert not fails, "disjoint-halves failures:\n  " + "\n  ".join(fails)
    dut._log.info("P2: both halves written same row are physically disjoint (banks 0-7 vs 8-15)")

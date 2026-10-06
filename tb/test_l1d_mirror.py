"""
cocotb: L1D MIRROR restructure (Memory 波1 Stage C) — directed invariant tests.

l1d_mem was restructured so each word-interleaved bank is an l1d_mirror_bank
(Copy_I + Copy_C + write-consistency FIFO + bypass) providing concurrent
"IBEX 1RW + CP 1R" on SINGLE-PORT macros. The behavioral sim path exercises the
REAL mechanism (single-port cells + FIFO + bypass), so these tests actually
verify it — not the old magic dual-port. See
Review/MemWave1_StageC_Hardened_Design_2026-07-22.md (12 red-green tests T1-T12).

Address map (4KB, word-interleaved): byte_addr[2]=bank, byte_addr[11:3]=word.
Reads are 2-cycle (OUT_REG=1); everything is valid-driven so we just wait for
rvalid. CP reads 64b = {bank1[word], bank0[word]}.

Run: cd tb && make MODULE=test_l1d_mirror TOPLEVEL=l1d_mem \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv \
                         ../rtl/IBEX_SRAM/Memory_Subsystem/l1d_mirror_bank.sv \
                         ../rtl/IBEX_SRAM/Memory_Subsystem/l1d_mem.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

TIMEOUT = 2000


def baddr(bank, word):
    """byte address for (bank, word): [11:3]=word, [2]=bank, [1:0]=0."""
    return ((word & 0x1FF) << 3) | ((bank & 1) << 2)


async def reset(dut):
    dut.rst_ni.value = 0
    dut.soft_reset_i.value = 0
    dut.cpu_req_i.value = 0
    dut.cpu_we_i.value = 0
    dut.cpu_addr_i.value = 0
    dut.cpu_be_i.value = 0
    dut.cpu_wdata_i.value = 0
    dut.cp_req_i.value = 0
    dut.cp_addr_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk_i)


async def ibex_access(dut, byte_addr, we, data=0, be=0xF):
    """Drive one IBEX OBI access; returns read data (for reads). Robust to the
    waited-grant stall: samples gnt at ReadOnly (exactly what the DUT samples at
    the following edge)."""
    dut.cpu_req_i.value = 1
    dut.cpu_we_i.value = we
    dut.cpu_addr_i.value = byte_addr & 0xFFF
    dut.cpu_wdata_i.value = data & 0xFFFFFFFF
    dut.cpu_be_i.value = be & 0xF
    # advance until the access is accepted (gnt high at the sampling edge)
    for _ in range(TIMEOUT):
        await ReadOnly()
        gnt = int(dut.cpu_gnt_o.value)
        await RisingEdge(dut.clk_i)
        if gnt == 1:
            break
    else:
        raise cocotb.result.TestFailure("ibex_access: no grant (stuck)")
    dut.cpu_req_i.value = 0
    dut.cpu_we_i.value = 0
    # wait for the single rvalid response (read data or write ack)
    for _ in range(TIMEOUT):
        await ReadOnly()
        rv = int(dut.cpu_rvalid_o.value)
        rd = int(dut.cpu_rdata_o.value)
        await RisingEdge(dut.clk_i)
        if rv == 1:
            return rd
    raise cocotb.result.TestFailure("ibex_access: no rvalid")


async def ibex_write(dut, bank, word, data, be=0xF):
    await ibex_access(dut, baddr(bank, word), 1, data, be)


async def ibex_read(dut, bank, word):
    return await ibex_access(dut, baddr(bank, word), 0)


async def cp_read(dut, word):
    """CP 64b read of {bank1[word], bank0[word]}."""
    dut.cp_req_i.value = 1
    dut.cp_addr_i.value = word & 0x1FF
    await RisingEdge(dut.clk_i)      # issue at this edge
    dut.cp_req_i.value = 0
    for _ in range(TIMEOUT):
        await ReadOnly()
        rv = int(dut.cp_rvalid_o.value)
        rd = int(dut.cp_rdata_o.value)
        await RisingEdge(dut.clk_i)
        if rv == 1:
            return rd
    raise cocotb.result.TestFailure("cp_read: no rvalid")


async def start(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)


@cocotb.test()
async def test_basic_rw(dut):
    """Sanity: IBEX write then IBEX read-back and CP read (low half)."""
    await start(dut)
    await ibex_write(dut, 0, 5, 0xDEADBEEF)
    rd = await ibex_read(dut, 0, 5)
    assert rd == 0xDEADBEEF, f"IBEX read-back {rd:#x} != 0xDEADBEEF"
    # let any pending drain settle, then CP read
    for _ in range(6):
        await RisingEdge(dut.clk_i)
    cp = await cp_read(dut, 5)
    assert (cp & 0xFFFFFFFF) == 0xDEADBEEF, f"CP low {cp & 0xFFFFFFFF:#x} != 0xDEADBEEF"


@cocotb.test()
async def test_bypass_raw(dut):
    """T1: IBEX write then IMMEDIATE CP read of the same word (before drain) must
    see the NEW value via bypass, not the stale Copy_C."""
    await start(dut)
    await ibex_write(dut, 0, 3, 0x11112222)
    # CP read right away — the write is still in the FIFO / just draining.
    cp = await cp_read(dut, 3)
    assert (cp & 0xFFFFFFFF) == 0x11112222, f"T1 bypass FAIL: CP low {cp & 0xFFFFFFFF:#x} != 0x11112222"


@cocotb.test()
async def test_bypass_same_cycle(dut):
    """T1+T2 (the central RAW hole): a CP read issued the SAME cycle as an IBEX
    write to that word must return the NEW value via the this-cycle-push bypass,
    even though the write drains into Copy_C between issue (N) and output (N+2).
    Catches BOTH bypass-disabled AND recompute-at-output (a drain at N+1 would
    erase a live-FIFO recompute; the frozen-at-issue pipe survives it)."""
    await start(dut)
    W = 12
    # Seed Copy_C[bank0][W] with OLD (write, then let it fully drain).
    await ibex_write(dut, 0, W, 0x0FFFF0FF)
    for _ in range(8):
        await RisingEdge(dut.clk_i)
    OLD = 0x0FFFF0FF
    NEW = 0xF00DBEEF
    # Same cycle: IBEX full-word write bank0[W]=NEW  AND  CP read of W.
    dut.cpu_req_i.value = 1
    dut.cpu_we_i.value = 1
    dut.cpu_addr_i.value = baddr(0, W)
    dut.cpu_wdata_i.value = NEW
    dut.cpu_be_i.value = 0xF
    dut.cp_req_i.value = 1
    dut.cp_addr_i.value = W
    await ReadOnly()
    assert int(dut.cpu_gnt_o.value) == 1, "write not granted on the shared cycle"
    await RisingEdge(dut.clk_i)   # both accepted here (write pushes FIFO, CP read issues)
    dut.cpu_req_i.value = 0
    dut.cpu_we_i.value = 0
    dut.cp_req_i.value = 0        # cp idle next cycle → the write drains at N+1
    for _ in range(TIMEOUT):
        await ReadOnly()
        rv = int(dut.cp_rvalid_o.value)
        rd = int(dut.cp_rdata_o.value) & 0xFFFFFFFF
        await RisingEdge(dut.clk_i)
        if rv == 1:
            break
    assert rd == NEW, f"T1/T2 bypass FAIL: got {rd:#x} (OLD={OLD:#x}, want NEW={NEW:#x})"


@cocotb.test()
async def test_newest_wins(dut):
    """T3: two writes to the same word — CP read must return the NEWEST value
    (tail-priority bypass, or Copy_C after in-order drain)."""
    await start(dut)
    await ibex_write(dut, 0, 9, 0xAAAA0001)
    await ibex_write(dut, 0, 9, 0xBBBB0002)
    cp = await cp_read(dut, 9)
    assert (cp & 0xFFFFFFFF) == 0xBBBB0002, f"T3 newest-wins FAIL: {cp & 0xFFFFFFFF:#x} != 0xBBBB0002"
    # and IBEX read (Copy_I authoritative) also newest
    rd = await ibex_read(dut, 0, 9)
    assert rd == 0xBBBB0002, f"T3 IBEX newest FAIL: {rd:#x} != 0xBBBB0002"


@cocotb.test()
async def test_cross_bank_isolation(dut):
    """T6: a 32b IBEX write to bank0 must NOT corrupt bank1's Copy_C. CP 64b read
    of the same word returns {bank1(unchanged), bank0(written)}."""
    await start(dut)
    await ibex_write(dut, 0, 1, 0xCAFEF00D)   # bank0 only
    for _ in range(6):
        await RisingEdge(dut.clk_i)
    cp = await cp_read(dut, 1)
    low, high = cp & 0xFFFFFFFF, (cp >> 32) & 0xFFFFFFFF
    assert low == 0xCAFEF00D, f"T6 bank0 FAIL: {low:#x} != 0xCAFEF00D"
    assert high == 0x00000000, f"T6 bank1 leak: {high:#x} != 0 (cross-bank enqueue corruption)"


@cocotb.test()
async def test_64b_assembly(dut):
    """T7: CP 64b assembly order = {bank1[word], bank0[word]}."""
    await start(dut)
    await ibex_write(dut, 0, 4, 0xAAAA0000)   # bank0 (low half)
    await ibex_write(dut, 1, 4, 0xBBBB1111)   # bank1 (high half)
    for _ in range(6):
        await RisingEdge(dut.clk_i)
    cp = await cp_read(dut, 4)
    assert cp == 0xBBBB1111AAAA0000, f"T7 assembly FAIL: {cp:#018x} != 0xBBBB1111AAAA0000"


@cocotb.test()
async def test_rmw_subword(dut):
    """T5: SB/SH sub-word write via RMW preserves the other bytes."""
    await start(dut)
    await ibex_write(dut, 0, 2, 0x11223344, be=0xF)       # full word
    await ibex_write(dut, 0, 2, 0x000000AB, be=0x1)        # SB byte0 = 0xAB
    rd = await ibex_read(dut, 0, 2)
    assert rd == 0x112233AB, f"T5 SB FAIL: {rd:#x} != 0x112233AB"
    await ibex_write(dut, 0, 2, 0x5566_0000 >> 0 | 0x5566, be=0x2)  # SH? use be=0x2 byte1
    # be=0x2 writes byte1 only: wdata byte1 = 0x55 -> word becomes 0x112255AB
    await ibex_write(dut, 0, 2, 0x00005500, be=0x2)
    rd2 = await ibex_read(dut, 0, 2)
    assert rd2 == 0x112255AB, f"T5 byte1 FAIL: {rd2:#x} != 0x112255AB"
    # CP read must also see the RMW-merged word (via drain/bypass)
    cp = await cp_read(dut, 2)
    assert (cp & 0xFFFFFFFF) == 0x112255AB, f"T5 CP FAIL: {cp & 0xFFFFFFFF:#x} != 0x112255AB"


@cocotb.test()
async def test_2cycle_interleaved(dut):
    """T8: interleaved reads of different banks return correct data at correct
    cycles (proves the 2-deep rvalid + bank_sel pipes align)."""
    await start(dut)
    await ibex_write(dut, 0, 7, 0x0B0B0B0B)
    await ibex_write(dut, 1, 7, 0x1A1A1A1A)
    r0 = await ibex_read(dut, 0, 7)
    r1 = await ibex_read(dut, 1, 7)
    assert r0 == 0x0B0B0B0B, f"T8 bank0 read {r0:#x} != 0x0B0B0B0B"
    assert r1 == 0x1A1A1A1A, f"T8 bank1 read {r1:#x} != 0x1A1A1A1A"


@cocotb.test()
async def test_fifo_full_no_drop(dut):
    """T4 (invariant 1/3): fill the write-consistency FIFO (drain blocked by holding
    cp_req high), confirm the over-full IBEX write STALLS (gnt low, atomic ~full
    gate), then release the drain and verify NO write was lost — every write reaches
    Copy_C. RED hook: remove the wr_stall term from cpu_gnt_o → the over-full write
    pushes past the FIFO end and corrupts/loses entries."""
    await start(dut)
    DEPTH = 8
    vals = {}
    dut.cp_req_i.value = 1      # block drain for the whole fill
    dut.cp_addr_i.value = 0
    for k in range(DEPTH):
        word = 30 + k
        data = 0xF1F00000 | k
        vals[word] = data
        await ibex_write(dut, 0, word, data)   # cp_req stays high (helper doesn't touch it)
    # The (DEPTH+1)-th write to a full, drain-blocked FIFO must STALL (gnt low).
    word_x = 30 + DEPTH
    data_x = 0xF1F000EE
    vals[word_x] = data_x
    dut.cpu_req_i.value = 1
    dut.cpu_we_i.value = 1
    dut.cpu_addr_i.value = baddr(0, word_x)
    dut.cpu_wdata_i.value = data_x
    dut.cpu_be_i.value = 0xF
    stalled = False
    for _ in range(6):
        await ReadOnly()
        if int(dut.cpu_gnt_o.value) == 0:
            stalled = True
        await RisingEdge(dut.clk_i)
    assert stalled, "T4: over-full write did NOT stall (gnt stayed high) — write-loss risk"
    # Release the drain → the stalled write is accepted, FIFO drains to Copy_C.
    dut.cp_req_i.value = 0
    for _ in range(TIMEOUT):
        await ReadOnly()
        gnt = int(dut.cpu_gnt_o.value)
        await RisingEdge(dut.clk_i)
        if gnt == 1:
            break
    dut.cpu_req_i.value = 0
    dut.cpu_we_i.value = 0
    for _ in range(TIMEOUT):
        await ReadOnly()
        rv = int(dut.cpu_rvalid_o.value)
        await RisingEdge(dut.clk_i)
        if rv == 1:
            break
    for _ in range(4 * (DEPTH + 4)):
        await RisingEdge(dut.clk_i)
    # No write lost: every word reads back its value via CP (Copy_C).
    for word, data in vals.items():
        cp = await cp_read(dut, word)
        assert (cp & 0xFFFFFFFF) == data, f"T4 lost/corrupt write @word{word}: {cp&0xFFFFFFFF:#x} != {data:#x}"


@cocotb.test()
async def test_soft_reset_survives(dut):
    """T9: soft_reset must NOT flush the mirror (FIFO/SRAM SURVIVE). A write not
    yet observed by CP stays consistent across a soft_reset pulse."""
    await start(dut)
    await ibex_write(dut, 0, 6, 0x7E577E57)
    # pulse soft_reset (1 cycle)
    dut.soft_reset_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.soft_reset_i.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk_i)
    cp = await cp_read(dut, 6)
    assert (cp & 0xFFFFFFFF) == 0x7E577E57, f"T9 soft_reset consistency FAIL: {cp & 0xFFFFFFFF:#x} != 0x7E577E57"

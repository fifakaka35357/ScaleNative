"""
cocotb: DMA engine 2D strided transfers — the regression that the pre-tapeout
audit (2026-07-12) was missing.

dma_engine had ZERO tests. That is how this survived to the eve of SoC P&R:

    ST_FILL_RUN gated `ing_pop` with `!inner_done`, yet required
    `inner_done && ing_empty` before advancing the outer loop. The NoC streams
    outer_count x len_rows x 16 words as ONE continuous burst, so at an inner
    boundary the ingress FIFO legitimately still holds words belonging to the
    NEXT outer iteration — and those can never be popped. Every 2D FILL
    (outer_count > 1) deadlocked forever. 1D was accidentally safe (total pushes
    <= total_words), which is precisely why nothing ever noticed.

Since L2 is NOT in the IBEX address space (pe_pkg: "accessed only via
CP/Vec/Tens/DMA"), DMA FILL is the ONLY way weights/activations reach the chip.
A hung 2D FILL is therefore a dead chip, not a corner case.

test_fill_2d is the deadlock regression: on the pre-fix RTL it times out.
The others cover the sibling paths and the address-generation contract.

Run: cd tb && make MODULE=test_dma_2d TOPLEVEL=tb_dma_2d \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/dma_engine.sv \
                         ./tb_dma_2d.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

OP_DMA_FILL   = 0x20
OP_DMA_EVICT  = 0x21
OP_DMA_MEMSET = 0x22

WORDS_PER_ROW = 16          # 16 banks x 32b = one 64B L2 row
TIMEOUT_CYCLES = 20000      # generous; a deadlock blows straight through it


async def reset(dut):
    dut.rst_ni.value = 0
    dut.soft_reset_i.value = 0
    dut.cmd_valid_i.value = 0
    dut.cmd_opcode_i.value = 0
    dut.cmd_l2_row_i.value = 0
    dut.cmd_len_rows_i.value = 0
    dut.cmd_stride_rows_i.value = 0
    dut.cmd_outer_count_i.value = 0
    dut.cmd_memset_val_i.value = 0
    dut.noc_ing_valid_i.value = 0
    dut.noc_ing_data_i.value = 0
    dut.noc_egr_ready_i.value = 1
    dut.probe_idx_i.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk_i)


async def issue(dut, opcode, l2_row, len_rows, outer_count=0, stride_rows=0, memset_val=0):
    """Drive one command through the cmd_valid/cmd_ready handshake."""
    dut.cmd_opcode_i.value = opcode
    dut.cmd_l2_row_i.value = l2_row
    dut.cmd_len_rows_i.value = len_rows
    dut.cmd_stride_rows_i.value = stride_rows
    dut.cmd_outer_count_i.value = outer_count
    dut.cmd_memset_val_i.value = memset_val
    dut.cmd_valid_i.value = 1
    # wait for ready
    for _ in range(100):
        await RisingEdge(dut.clk_i)
        if dut.cmd_ready_o.value == 1:
            break
    else:
        raise AssertionError("DMA never asserted cmd_ready")
    await RisingEdge(dut.clk_i)
    dut.cmd_valid_i.value = 0


async def noc_producer(dut, words):
    """Stream `words` back-to-back into the NoC ingress (one continuous burst).

    This is the real traffic shape: the NoC does not know about inner/outer
    iteration boundaries, it just pushes outer x len x 16 words.
    """
    i = 0
    while i < len(words):
        dut.noc_ing_valid_i.value = 1
        dut.noc_ing_data_i.value = words[i]
        await RisingEdge(dut.clk_i)
        if dut.noc_ing_ready_o.value == 1:
            i += 1
    dut.noc_ing_valid_i.value = 0


async def wait_done(dut, what):
    """Wait for done_o, with a hard timeout that turns a deadlock into a failure."""
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk_i)
        if dut.done_o.value == 1:
            return
    raise AssertionError(
        f"{what}: DMA never raised done_o within {TIMEOUT_CYCLES} cycles — DEADLOCK. "
        "(This is the pre-fix ST_FILL_RUN behaviour: ing_pop gated by !inner_done "
        "while the exit waits for ing_empty, so FIFO words held for the next outer "
        "iteration can never drain.)"
    )


async def probe(dut, row, bank):
    dut.probe_idx_i.value = (row << 4) | bank
    await Timer(1, units="ns")
    return int(dut.probe_data_o.value), int(dut.probe_written_o.value)


def expected_placement(base_row, len_rows, outer_count, stride_rows):
    """Golden AGU: for each outer iteration the base advances by stride_rows;
    within an iteration, word w -> bank = w & 15, row = base + (w >> 4)."""
    eff_outer = max(outer_count, 1)
    total_inner = len_rows * WORDS_PER_ROW
    out = []                       # list of (row, bank) in stream order
    for o in range(eff_outer):
        base = base_row + o * stride_rows
        for w in range(total_inner):
            out.append((base + (w >> 4), w & 15))
    return out


@cocotb.test()
async def test_fill_2d(dut):
    """THE regression: 2D strided FILL (outer_count > 1) must terminate and land
    every word where the AGU promised. Pre-fix RTL deadlocks at the first inner
    boundary and this test times out."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)

    BASE, LEN, OUTER, STRIDE = 8, 2, 3, 5          # 3 iterations x 2 rows x 16 words
    total = LEN * WORDS_PER_ROW * OUTER            # 96 words, one continuous burst
    words = [0xA5A50000 + i for i in range(total)]

    cocotb.start_soon(noc_producer(dut, words))
    await issue(dut, OP_DMA_FILL, BASE, LEN, outer_count=OUTER, stride_rows=STRIDE)
    await wait_done(dut, "2D FILL")

    # Every word must be at its AGU address, in stream order.
    places = expected_placement(BASE, LEN, OUTER, STRIDE)
    assert len(places) == total
    for i, (row, bank) in enumerate(places):
        data, written = await probe(dut, row, bank)
        assert written == 1, f"word {i} -> row {row} bank {bank}: never written"
        assert data == words[i], (
            f"word {i} landed wrong: row {row} bank {bank} holds 0x{data:08x}, "
            f"expected 0x{words[i]:08x} (outer base advance broken?)"
        )
    dut._log.info(
        "2D FILL: %d words across %d outer iterations (stride %d) — terminated, "
        "all placements exact.", total, OUTER, STRIDE)


@cocotb.test()
async def test_fill_1d_unchanged(dut):
    """1D FILL was accidentally safe pre-fix — prove the fix did not regress it."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)

    BASE, LEN = 3, 2
    total = LEN * WORDS_PER_ROW
    words = [0x1234_0000 + i for i in range(total)]

    cocotb.start_soon(noc_producer(dut, words))
    await issue(dut, OP_DMA_FILL, BASE, LEN, outer_count=1)   # 1 == 1D
    await wait_done(dut, "1D FILL")

    for i, (row, bank) in enumerate(expected_placement(BASE, LEN, 1, 0)):
        data, written = await probe(dut, row, bank)
        assert written == 1 and data == words[i], (
            f"1D word {i} at row {row} bank {bank}: got 0x{data:08x} "
            f"(written={written}), expected 0x{words[i]:08x}")
    dut._log.info("1D FILL: %d words, all placements exact.", total)


@cocotb.test()
async def test_fill_back_to_back_2d(dut):
    """Two 2D FILLs in a row: the second must not inherit FIFO state from the first.
    Exercises the ST_IDLE ingress-FIFO flush added alongside the deadlock fix."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)

    for run, (base, tag) in enumerate([(16, 0xBEEF0000), (64, 0xCAFE0000)]):
        LEN, OUTER, STRIDE = 1, 2, 4
        total = LEN * WORDS_PER_ROW * OUTER
        words = [tag + i for i in range(total)]

        cocotb.start_soon(noc_producer(dut, words))
        await issue(dut, OP_DMA_FILL, base, LEN, outer_count=OUTER, stride_rows=STRIDE)
        await wait_done(dut, f"2D FILL run {run}")

        for i, (row, bank) in enumerate(expected_placement(base, LEN, OUTER, STRIDE)):
            data, written = await probe(dut, row, bank)
            assert written == 1 and data == words[i], (
                f"run {run} word {i} at row {row} bank {bank}: got 0x{data:08x}, "
                f"expected 0x{words[i]:08x} (stale FIFO carry-over between commands?)")
        # let the engine settle back into IDLE before the next command
        for _ in range(5):
            await RisingEdge(dut.clk_i)
    dut._log.info("back-to-back 2D FILL: no cross-command FIFO contamination.")


@cocotb.test()
async def test_memset_2d(dut):
    """2D MEMSET writes the constant to every AGU address (no NoC, no FIFO)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)

    BASE, LEN, OUTER, STRIDE, VAL = 100, 1, 3, 2, 0xDEADBEEF
    await issue(dut, OP_DMA_MEMSET, BASE, LEN,
                outer_count=OUTER, stride_rows=STRIDE, memset_val=VAL)
    await wait_done(dut, "2D MEMSET")

    for (row, bank) in expected_placement(BASE, LEN, OUTER, STRIDE):
        data, written = await probe(dut, row, bank)
        assert written == 1 and data == VAL, (
            f"MEMSET row {row} bank {bank}: got 0x{data:08x} (written={written}), "
            f"expected 0x{VAL:08x}")
    dut._log.info("2D MEMSET: constant landed at all %d addresses.",
                  LEN * WORDS_PER_ROW * OUTER)


@cocotb.test()
async def test_evict_2d(dut):
    """2D EVICT: fill with MEMSET-per-iteration patterns, then evict and check the
    egress stream matches the AGU walk order."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)

    BASE, LEN, OUTER, STRIDE = 200, 1, 2, 3
    total = LEN * WORDS_PER_ROW * OUTER

    # Seed L2 through a 2D FILL (which we have just proven correct).
    words = [0x5EED0000 + i for i in range(total)]
    cocotb.start_soon(noc_producer(dut, words))
    await issue(dut, OP_DMA_FILL, BASE, LEN, outer_count=OUTER, stride_rows=STRIDE)
    await wait_done(dut, "seed FILL")
    for _ in range(5):
        await RisingEdge(dut.clk_i)

    # Now evict the same region and capture the egress stream.
    got = []

    async def egress_sink():
        while len(got) < total:
            await RisingEdge(dut.clk_i)
            if dut.noc_egr_valid_o.value == 1 and dut.noc_egr_ready_i.value == 1:
                got.append(int(dut.noc_egr_data_o.value))

    sink = cocotb.start_soon(egress_sink())
    await issue(dut, OP_DMA_EVICT, BASE, LEN, outer_count=OUTER, stride_rows=STRIDE)
    await wait_done(dut, "2D EVICT")
    await sink

    assert got == words, (
        f"2D EVICT stream mismatch:\n  got      {[hex(g) for g in got[:8]]}...\n"
        f"  expected {[hex(w) for w in words[:8]]}...")
    dut._log.info("2D EVICT: %d words streamed out in exact AGU order.", total)

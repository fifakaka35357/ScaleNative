"""
cocotb: DMA EVICT under 2-cycle L2 read + egress back-pressure — the [C2
vec-l2-port-reg] correctness regression.

When the L2 read is registered (sram_1rw1r_wrapper OUT_REG=1 → 2-cycle read),
TWO evict reads are in flight at once. dma_engine's evict holding register is
single-entry, and its req-suppression (gated on !hold_valid) only stops a
FURTHER rvalid at 1-cycle latency. At 2-cycle latency the second already-issued
rvalid arrives while (egr_full && hold_valid) → the capture condition
(evict_rvalid && egr_full && !hold_valid) is false → the word is DROPPED.
evict_received_q counts egr_push (not raw rvalid), so it stays one short of
total_words forever → ST_EVICT_DRAIN never exits → done_o never asserts.

tb_dma_evict_bp models the 2-cycle RW port and mem[idx]=idx (so evicted word k
must equal k). Two tests:
  - test_evict_2cyc_nobp        : NEGATIVE CONTROL. 2-cycle L2, egress always
                                  ready → FIFO never fills → no hold capture →
                                  no drop. PASSES on buggy RTL (proves the
                                  2-cycle model itself is sound).
  - test_evict_2cyc_backpressure: REGRESSION. 2-cycle L2 + egress back-pressure
                                  forces egr_full with 2 reads in flight → the
                                  single-entry hold drops one → deadlock. FAILS
                                  (timeout) on buggy RTL; PASSES with the 2-entry
                                  hold fix.

Run: cd tb && make MODULE=test_dma_evict_bp TOPLEVEL=tb_dma_evict_bp \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/dma_engine.sv \
                         ./tb_dma_evict_bp.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

OP_DMA_EVICT = 0x21
WORDS_PER_ROW = 16
TIMEOUT_CYCLES = 20000     # a deadlock blows straight through this


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


async def issue(dut, opcode, l2_row, len_rows, outer_count=1, stride_rows=0):
    """Drive one command through the cmd_valid/cmd_ready handshake."""
    dut.cmd_opcode_i.value = opcode
    dut.cmd_l2_row_i.value = l2_row
    dut.cmd_len_rows_i.value = len_rows
    dut.cmd_stride_rows_i.value = stride_rows
    dut.cmd_outer_count_i.value = outer_count
    dut.cmd_memset_val_i.value = 0
    dut.cmd_valid_i.value = 1
    for _ in range(100):
        await RisingEdge(dut.clk_i)
        if dut.cmd_ready_o.value == 1:
            break
    else:
        raise AssertionError("DMA never asserted cmd_ready")
    await RisingEdge(dut.clk_i)
    dut.cmd_valid_i.value = 0


async def drain_collect(dut, total, what):
    """Hold egress ready=1 and collect one word per valid cycle (stream order).
    ready is held high, so every cycle noc_egr_valid_o=1 is exactly one egr pop,
    and noc_egr_data_o is that popped word — no off-by-one."""
    dut.noc_egr_ready_i.value = 1
    collected = []
    done = False
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk_i)
        if int(dut.noc_egr_valid_o.value) == 1:
            collected.append(int(dut.noc_egr_data_o.value))
        if int(dut.done_o.value) == 1:
            done = True
            break
    assert done, (
        f"{what}: done_o never asserted within {TIMEOUT_CYCLES} cycles — DEADLOCK. "
        f"Single-entry evict hold dropped an in-flight word at 2-cycle L2 "
        f"(evict_received_q stuck below total_words). Collected {len(collected)}/{total}. "
        f"Fix = 2-entry evict hold in dma_engine.")
    assert len(collected) == total, \
        f"{what}: expected {total} egress words, got {len(collected)}: {collected}"
    for k, v in enumerate(collected):
        assert v == k, f"{what}: egress word #{k} = {v}, expected {k} (dropped/reordered)"


@cocotb.test()
async def test_evict_2cyc_nobp(dut):
    """NEGATIVE CONTROL: 2-cycle L2, egress always ready. FIFO never fills, so no
    hold capture and no drop — passes even on the pre-fix single-entry hold.
    Proves the 2-cycle read model is sound and the bug is specific to back-pressure."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)
    LEN = 2
    total = LEN * WORDS_PER_ROW               # 32 words
    dut.noc_egr_ready_i.value = 1             # never back-pressure
    await issue(dut, OP_DMA_EVICT, 0, LEN, outer_count=1)
    await drain_collect(dut, total, "EVICT 2-cyc no-backpressure (control)")


@cocotb.test()
async def test_evict_2cyc_backpressure(dut):
    """REGRESSION: 2-cycle L2 + egress back-pressure. Holding ready=0 fills the
    8-deep egress FIFO while 2 reads are in flight; when it is full the 2nd
    in-flight rvalid hits (egr_full && hold_valid) and is dropped by the
    single-entry hold → deadlock (done_o never). The 2-entry hold fix keeps all
    words → passes."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)
    LEN = 2
    total = LEN * WORDS_PER_ROW               # 32 words
    # Back-pressure BEFORE and during the evict read phase so the FIFO fills to
    # DEPTH=8 with two evict reads in flight (the drop trigger).
    dut.noc_egr_ready_i.value = 0
    await issue(dut, OP_DMA_EVICT, 0, LEN, outer_count=1)
    for _ in range(25):                       # let egr fill + the in-flight drop occur
        await RisingEdge(dut.clk_i)
    # Release back-pressure and drain; buggy RTL has already lost a word.
    await drain_collect(dut, total, "EVICT 2-cyc + back-pressure (regression)")


@cocotb.test()
async def test_evict_2cyc_bp_toggle(dut):
    """COLLISION COVERAGE: back-pressure toggling every cycle creates egr full↔
    not-full transitions coincident with in-flight rvalids, so the depth-2 hold
    must drain its head to egr AND enqueue a new straggler the SAME cycle
    (independent read/write slots, FIFO order preserved). The sustained-back-
    pressure test never hits this (reads stop before the hold drains), so without
    this case that collision path would ship unexercised (RED-2 blind spot)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    await reset(dut)
    LEN = 4
    total = LEN * WORDS_PER_ROW               # 64 words
    dut.noc_egr_ready_i.value = 0
    await issue(dut, OP_DMA_EVICT, 0, LEN, outer_count=1)
    # Toggle egress ready every cycle throughout the drain. ready is set right
    # after the edge (applies to this cycle's combinational egr_pop); data/valid
    # are sampled for this same cycle → each popped head collected once, in order.
    collected = []
    done = False
    rdy = 1
    for _ in range(TIMEOUT_CYCLES):
        await RisingEdge(dut.clk_i)
        dut.noc_egr_ready_i.value = rdy
        if rdy == 1 and int(dut.noc_egr_valid_o.value) == 1:
            collected.append(int(dut.noc_egr_data_o.value))
        if int(dut.done_o.value) == 1:
            done = True
            break
        rdy ^= 1
    what = "EVICT 2-cyc + toggling back-pressure (collision coverage)"
    assert done, f"{what}: done_o never asserted; collected {len(collected)}/{total}"
    assert len(collected) == total, \
        f"{what}: expected {total} egress words, got {len(collected)}: {collected}"
    for k, v in enumerate(collected):
        assert v == k, f"{what}: egress word #{k} = {v}, expected {k} (reorder/drop)"

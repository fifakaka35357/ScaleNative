"""
cocotb regression for the cp_scheduler RR-arbiter head-of-line fix (HW-REVIEW T4).

Bug (confirmed 2026-06-20 HW review, high): the RR issue selector picks the first
can_issue ctx from rr_ptr, and rr_ptr advances ONLY on issue_ok. can_issue uses
credit availability, NOT downstream cmd_ready. Because the exec units are
single-op-in-flight but credits are over-provisioned (4/2/2), "credit>0 while
cmd_ready=0" is the NORMAL busy condition — so a ctx targeting a busy unit is
selected every cycle, rr_ptr freezes, and a different ctx with ready work on an
otherwise-idle unit never issues (head-of-line block, undercuts 4-ctx throughput).

Fix: mask the selector by per-ctx target-unit readiness (res_ready), so a ctx
whose unit is busy is skipped and a ctx that can actually issue is chosen.

Scenario A is the HOL test: ctx0=VEC (unit busy), ctx1=TENS (unit idle) — ctx1
must issue. Pre-fix it never does (red); post-fix it does (green). B/C are guards.

Run: cd tb && make MODULE=test_cp_arbiter TOPLEVEL=tb_cp_arbiter \
  VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/cp_scheduler.sv \
  ../tb/tb_cp_arbiter.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


async def run_scenario(dut, vec_ready, tens_ready, cycles=14):
    """Pulse reset, set unit readiness, collect the set of ctxs that ACTUALLY
    issue (issue_snap_valid == issue_ok) over a window."""
    dut.rst_ni.value = 0
    dut.enable_i.value = 0
    dut.vec_ready_i.value = vec_ready
    dut.tens_ready_i.value = tens_ready
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    dut.enable_i.value = 1
    issued = set()
    for _ in range(cycles):
        await RisingEdge(dut.clk_i)
        await Timer(1, "ns")
        if int(dut.issue_snap_valid_o.value):
            issued.add(int(dut.issue_snap_ctx_o.value))
    return issued


@cocotb.test()
async def test_arbiter_head_of_line(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    # Scenario A — HOL: vec unit BUSY, tensor unit IDLE.
    # ctx1 (tensor) must issue even though ctx0 (vec) is blocked.
    issued = await run_scenario(dut, vec_ready=0, tens_ready=1)
    dut._log.info(f"A vec_busy/tens_idle: issued ctxs = {sorted(issued)}")
    assert 1 in issued, \
        "HOL: tensor ctx1 never issued while vec unit busy (rr_ptr frozen on ctx0)"
    assert 0 not in issued, "vec ctx0 must not complete an issue while its unit is busy"

    # Scenario B — guard: both units idle. ctx0 (vec, first in RR) issues.
    issued = await run_scenario(dut, vec_ready=1, tens_ready=1)
    dut._log.info(f"B both idle: issued ctxs = {sorted(issued)}")
    assert 0 in issued, "both-idle: ctx0 (vec) should issue"

    # Scenario C — guard: both units busy. Nothing can issue.
    issued = await run_scenario(dut, vec_ready=0, tens_ready=0)
    dut._log.info(f"C both busy: issued ctxs = {sorted(issued)}")
    assert issued == set(), f"both-busy: nothing should issue, got {sorted(issued)}"

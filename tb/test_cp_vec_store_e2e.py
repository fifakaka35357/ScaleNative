"""
cocotb test (STEP4-E2E §10, D-E2E-BENCH): command-path behavioral E2E.

The REAL cp_scheduler issues a Vector STORE to vector_unit_top, the command is
released the cycle after issue, the op runs and makes its L2 write many cycles
later, and completion loops back through cp_completion. Headline = the D5-1
regression with teeth: with half_sel=1 the DEFERRED L2 write must still use
half_sel=1 even though the live cmd_i has gone to 0 (the latch holds). A
half_sel=0 case checks the complement. This is the command path the adversarial
review found UNTESTED (N25) — no ibex CPU; the tb mocks command_processor's slot
registers (plain inputs to cp_scheduler).

Run: cd tb && make MODULE=test_cp_vec_store_e2e TOPLEVEL=tb_cp_vec_store_e2e \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/cp_scheduler.sv ../rtl/IBEX_SRAM/cp_completion.sv \
        ../tb/tb_cp_vec_store_e2e.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

# enums (pe_pkg)
OP_VEC_STORE = 0x02
SLOT_EMPTY, SLOT_VALID = 0, 1
BLOCK_SIZE_32 = 1
SCALE_E8M0 = 0
OP_SRC0 = 0

# descriptor geometry
R_BASE = 0x040          # region 0 base row
R_NUM = 0x1000          # region 0 size (rows)
DST_OFF = 0x012         # dst row offset -> phys_dst = R_BASE + DST_OFF
SRC_OFF = 0x000


def build_slot(opcode, dst_off, half_sel, src_off=0):
    """Pack the 8x32b descriptor slot. word0=header, word2=dst l2_addr,
    word6=tile_contract (bit9=half_sel). rid=0 for src/dst."""
    w = [0] * 8
    w[0] = opcode & 0xFF                       # header: opcode in [7:0], ctx0, ext_len0
    w[1] = (src_off & 0xFFFF)                  # src l2_addr: rid0, row_off
    w[2] = (dst_off & 0xFFFF)                  # dst l2_addr: rid0, row_off
    w[6] = (1 << 9) if half_sel else 0         # contract: bit[9]=half_sel
    v = 0
    for i, word in enumerate(w):
        v |= (word & 0xFFFFFFFF) << (i * 32)
    return v


async def push_cap(dut, role, payload, fails):
    """Single-beat capsule push (block32/E8M0/epoch0/fwd). Canonical master:
    hold valid, sample ready each rising edge, first ready-high is the transfer,
    then drop valid (held valid would re-push)."""
    dut.cap_payload_i.value = payload
    dut.cap_role_i.value = role
    dut.cap_block_size_i.value = BLOCK_SIZE_32
    dut.cap_scale_format_i.value = SCALE_E8M0
    dut.cap_inline_scale_i.value = 127          # E8M0 byte -> exp 0
    dut.cap_scale_epoch_i.value = 0
    dut.cap_fwd_i.value = 1                      # capsule must be fwd_eligible (ingress check)
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("capsule role=%d MISS reason=%d" % (role, int(dut.miss_reason_o.value)))
            break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True
            break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("capsule role=%d never accepted (no cap_ready)" % role)
    await FallingEdge(dut.clk_i)


async def reset(dut):
    for s in ("enable_i", "slot0_i", "slot0_state_i", "doorbell0_i",
              "region0_base_i", "region0_num_i", "cap_valid_i", "cap_payload_i",
              "cap_role_i", "cap_block_size_i", "cap_scale_format_i",
              "cap_inline_scale_i", "cap_scale_epoch_i", "cap_fwd_i", "rw_gnt_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def run_store(dut, half_sel):
    """Drive ONE STORE(half_sel) through the real cp_scheduler and check the
    deferred L2 write uses the latched half_sel. Returns a dict of observations."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    obs = {"fails": []}

    dut.enable_i.value = 1
    dut.region0_base_i.value = R_BASE
    dut.region0_num_i.value = R_NUM
    dut.rw_gnt_i.value = 1                       # L2 model: always grant

    # 1) present the STORE descriptor in ctx0 slot; ctx auto-promotes.
    dut.slot0_i.value = build_slot(OP_VEC_STORE, DST_OFF, half_sel, SRC_OFF)
    dut.slot0_state_i.value = SLOT_VALID

    # 2) wait for the scheduler to ISSUE; capture the issued half_sel; then flip
    #    the slot to EMPTY. NOTE (A1): this is an issue-time RE-ISSUE GUARD, not a
    #    faithful model of command_processor (the real CP clears/promotes the slot
    #    only on comp_done, staying SLOT_VALID through CTX_WAIT_VEC). It is
    #    timing-equivalent here: once ctx0 enters CTX_WAIT_VEC at issue+1, can_issue
    #    is already gated false by the ctx-state term, so slot=EMPTY vs VALID yields
    #    identical scheduler outputs. The flip also lets the live cmd line return to
    #    its default ('0) — the D5-1 release condition we want to exercise.
    issued = False
    for _ in range(40):
        await RisingEdge(dut.clk_i)
        if int(dut.issue_snap_valid_o.value) == 1 and int(dut.issue_opcode_o.value) == OP_VEC_STORE:
            obs["issue_half_sel"] = int(dut.issue_half_sel_o.value)
            dut.slot0_state_i.value = SLOT_EMPTY
            issued = True
            break
    if not issued:
        obs["fails"].append("cp_scheduler never issued the STORE (issue_snap_valid)")
        return obs
    if obs["issue_half_sel"] != half_sel:
        obs["fails"].append("issued contract.half_sel=%d != %d" % (obs["issue_half_sel"], half_sel))

    # 3) the core is now in WAIT_OP0 — inject the SRC0 operand. block32 = 32
    #    elements = TWO 16-lane capsules (vector_unit.sv:233), so push both
    #    windows as role SRC0. (The non-RESADD STORE descriptor is hardwired
    #    block32 by vec_cmd_to_desc.)
    payload0 = 0
    payload1 = 0
    for i in range(16):
        payload0 |= ((100 + i) & 0xFFFF) << (i * 16)
        payload1 |= ((200 + i) & 0xFFFF) << (i * 16)
    await push_cap(dut, OP_SRC0, payload0, obs["fails"])
    if not obs["fails"]:
        await push_cap(dut, OP_SRC0, payload1, obs["fails"])
    if obs["fails"]:
        return obs

    # 4) capture the deferred L2 RW write (first window for block32) + the live
    #    issued half_sel at that moment (must have been released to 0), then run
    #    to completion. Error/scheduler-error/watchdog are transient 1-cycle
    #    pulses, so monitor them STICKILY across the whole window (B-1/B-4), and
    #    distinguish a clean DONE (VST_DONE=5) from an ERROR completion (VST_ERROR
    #    =6) since done_o pulses for both (B-1).
    obs.update(saw_vu_err=False, saw_sched_err=False, saw_wd=False, done=False, done_state=-1)
    await FallingEdge(dut.clk_i)
    for _ in range(160):
        await FallingEdge(dut.clk_i)
        if int(dut.vu_err_o.value):
            obs["saw_vu_err"] = True
            obs["vu_err_code"] = int(dut.vu_err_code_o.value)
        if int(dut.sched_error_o.value):
            obs["saw_sched_err"] = True
        if int(dut.wd_timeout0_o.value):
            obs["saw_wd"] = True
        if "rw_half_sel" not in obs and int(dut.rw_req_o.value) == 1:
            obs["rw_half_sel"] = int(dut.rw_half_sel_o.value)
            obs["rw_row"] = int(dut.rw_row_o.value)
            obs["rw_wdata"] = int(dut.rw_wdata_o.value)
            obs["live_half_sel_at_write"] = int(dut.issue_half_sel_o.value)
            obs["cmd_valid_at_write"] = int(dut.vec_cmd_valid_o.value)
        if int(dut.vec_done_o.value) == 1:
            obs["done"] = True
            obs["done_state"] = int(dut.vu_state_o.value)   # 5=VST_DONE (clean), 6=VST_ERROR
            break
    if "rw_half_sel" not in obs and not obs["fails"]:
        obs["fails"].append("no L2 RW write observed (rw_req never asserted)")
    return obs


@cocotb.test()
async def test_cp_vec_store_half1(dut):
    """half_sel=1: the deferred L2 write must land in the HIGH half."""
    obs = await run_store(dut, half_sel=1)
    fails = obs["fails"]
    if not fails:
        # D5-1 PREMISE (B-2): the scheduler must have RELEASED the cmd by write
        # time — assert it directly rather than rely on an implication.
        if obs.get("live_half_sel_at_write", 1) != 0 or obs.get("cmd_valid_at_write", 1) != 0:
            fails.append("cmd not released at write (live_half_sel=%d cmd_valid=%d) — D5-1 race premise unmet"
                         % (obs.get("live_half_sel_at_write", -1), obs.get("cmd_valid_at_write", -1)))
        # D5-1 CORE: the latch held half_sel=1 through the deferred write despite release.
        if obs["rw_half_sel"] != 1:
            fails.append("rw_half_sel=%d != 1 at the deferred write (D5-1: latch did NOT hold)"
                         % obs["rw_half_sel"])
        if obs["rw_row"] != (R_BASE + DST_OFF):
            fails.append("rw_row=0x%x != phys_dst 0x%x" % (obs["rw_row"], R_BASE + DST_OFF))
        if obs["rw_wdata"] == 0:
            fails.append("L2 wdata all-zero (STORE did not unpack a result)")
        # clean completion (B-1): done via VST_DONE (5), not VST_ERROR (6)
        if not obs["done"]:
            fails.append("vec done never pulsed")
        elif obs["done_state"] != 5:
            fails.append("completion via VST_ERROR (state=%d), not clean VST_DONE" % obs["done_state"])
        if obs["saw_vu_err"]:
            fails.append("vector_unit error pulsed (code=%d)" % obs.get("vu_err_code", -1))
        if obs["saw_sched_err"]:
            fails.append("cp_scheduler error pulsed during the run")
        if obs["saw_wd"]:
            fails.append("watchdog timeout pulsed")
    assert not fails, "half_sel=1 failures:\n  " + "\n  ".join(fails)
    dut._log.info(
        "D-E2E-BENCH half_sel=1: cp_scheduler issued STORE, released cmd "
        "(live=%d cmd_valid=%d at write), deferred L2 write half_sel=1 row=0x%x — latch held"
        % (obs.get("live_half_sel_at_write", -1), obs.get("cmd_valid_at_write", -1), obs["rw_row"]))


@cocotb.test()
async def test_cp_vec_store_half0(dut):
    """half_sel=0: the deferred L2 write must land in the LOW half (complement).

    NOTE (B-3): this case is a COMPLEMENT/sanity check only — it cannot catch
    D5-1, because half_sel_q resets to 0 (vector_unit_top.sv), so a dead/missing
    latch also yields rw_half_sel=0 here. The load-bearing D5-1 regression is
    test_cp_vec_store_half1 (+ the documented negative control). Assertions mirror
    half1 (minus the half_sel polarity) to avoid an undocumented coverage gap (C4).
    """
    obs = await run_store(dut, half_sel=0)
    fails = obs["fails"]
    if not fails:
        if obs["rw_half_sel"] != 0:
            fails.append("rw_half_sel=%d != 0" % obs["rw_half_sel"])
        if obs["rw_row"] != (R_BASE + DST_OFF):
            fails.append("rw_row=0x%x != phys_dst 0x%x" % (obs["rw_row"], R_BASE + DST_OFF))
        if obs["rw_wdata"] == 0:
            fails.append("L2 wdata all-zero (STORE did not unpack a result)")
        if not obs["done"]:
            fails.append("vec done never pulsed")
        elif obs["done_state"] != 5:
            fails.append("completion via VST_ERROR (state=%d), not clean VST_DONE" % obs["done_state"])
        if obs["saw_vu_err"]:
            fails.append("vector_unit error pulsed (code=%d)" % obs.get("vu_err_code", -1))
        if obs["saw_sched_err"]:
            fails.append("cp_scheduler error pulsed during the run")
    assert not fails, "half_sel=0 failures:\n  " + "\n  ".join(fails)
    dut._log.info("D-E2E-BENCH half_sel=0: deferred L2 write half_sel=0 row=0x%x (complement check)" % obs["rw_row"])

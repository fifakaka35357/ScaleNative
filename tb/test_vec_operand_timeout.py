"""
cocotb regression for the vector_unit operand-arrival timeout (HW-REVIEW T4).

Bug (confirmed 2026-06-20 HW review, major): VST_WAIT_OP0/WAIT_OP1 (and the
resident-SRC1 read) had NO timeout for an operand that never arrives. role_stall
only counts wrong-ORDER capsules present at the queue head; on genuine
NON-delivery the queue is empty so role_stall_cnt resets every cycle and never
fires, and watchdog_cnt_q only runs in VST_ACTIVE. So the unit stalls forever,
done_o never fires, and the CP scoreboard credit for that context is never
returned (a credit leak only a global soft-reset can reclaim → eventual deadlock).

Fix: a no-progress operand watchdog (op_wait_cnt_q) counts cycles in WAIT_OP0/OP1
with no accepted operand (reset on oq_pop_ready); at VEC_WATCHDOG_THRESHOLD it
forces VST_ERROR with VERR_OPERAND_TIMEOUT, which fires done_o (returns credit).

Test: issue a RESADD, inject ONLY SRC0, never SRC1 -> the unit must time out,
fire done_o with err_o=1 and err_code == VERR_OPERAND_TIMEOUT, instead of hanging.

Run: cd tb && make MODULE=test_vec_operand_timeout TOPLEVEL=tb_vec_consume_e2e \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../tb/tb_vec_consume_e2e.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

BS_16 = 0
BLOCK_SIZE_16 = 0
SCALE_E4M3 = 1
OP_SRC0 = 0
E4M3_EXP7 = 7 << 3
VERR_OPERAND_TIMEOUT = 12
VST_BLK_SETUP, VST_ERROR = 8, 6


def to2c(v, bits):
    return v & ((1 << bits) - 1)


def pack(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= to2c(m, 16) << (i * 16)
    return v


async def reset(dut):
    for s in ("cmd_valid_i", "block_size_log2_i", "scale_epoch_i", "dst_row_i",
              "src1_resident_i", "src1_row_i", "len_rows_i", "sidecar_base_i",
              "cap_valid_i", "cap_payload_i", "cap_role_i", "cap_block_size_i",
              "cap_scale_format_i", "cap_inline_scale_i", "cap_scale_epoch_i",
              "cap_fwd_i", "rw_gnt_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_operand_timeout(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1

    # 1) issue RESADD (block16)
    dut.block_size_log2_i.value = BS_16
    dut.scale_epoch_i.value = 0
    dut.dst_row_i.value = 0x21
    dut.cmd_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    # 2) inject ONLY SRC0 (single beat), then never inject SRC1
    dut.cap_payload_i.value = pack([100 + 10 * i for i in range(16)])
    dut.cap_role_i.value = OP_SRC0
    dut.cap_block_size_i.value = BLOCK_SIZE_16
    dut.cap_scale_format_i.value = SCALE_E4M3
    dut.cap_inline_scale_i.value = E4M3_EXP7
    dut.cap_scale_epoch_i.value = 0
    dut.cap_fwd_i.value = 1
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.cap_ready_o.value) == 1:
            accepted = True
            break
    dut.cap_valid_i.value = 0
    assert accepted, "SRC0 capsule was never accepted (setup error)"

    # 3) SRC1 never arrives -> the unit must TIME OUT (not hang). Watch for done.
    got_done = False
    err = 0
    code = -1
    for _ in range(1300):                       # > VEC_WATCHDOG_THRESHOLD (1023)
        await FallingEdge(dut.clk_i)
        if int(dut.done_o.value) == 1:
            got_done = True
            err = int(dut.err_o.value)
            code = int(dut.err_code_o.value)
            break

    dut._log.info(f"operand timeout: done={got_done} err={err} code={code} "
                  f"(expect done=1 err=1 code={VERR_OPERAND_TIMEOUT})")
    assert got_done, "HANG: no operand timeout — done_o never fired (credit leak)"
    assert err == 1, f"timeout should be an error (err_o={err})"
    assert code == VERR_OPERAND_TIMEOUT, \
        f"err_code={code}, expected VERR_OPERAND_TIMEOUT={VERR_OPERAND_TIMEOUT}"
    # the unit must also return to idle (op retired, credit freed)
    for _ in range(4):
        await RisingEdge(dut.clk_i)
    await FallingEdge(dut.clk_i)
    assert int(dut.idle_o.value) == 1, "unit did not return to idle after timeout"


@cocotb.test()
async def test_streaming_sidecar_read_timeout(dut):
    """[T3-FF/FF3b-c, FOLD-2] A streaming RESADD whose scale-sidecar read hangs (RO port
    tied off in this harness) must LOUD-FAIL via VST_ERROR/VERR_OPERAND_TIMEOUT, not
    deadlock. The op routes IDLE -> VST_BLK_SETUP (streaming, block_count>1), asserts ro_req
    for the sidecar row, and (ro_gnt never grants) the op_wait backstop in BLK_SETUP must
    trip the next-state ERROR exit. RED if FOLD-2 omitted (error_q set but state never moves
    -> hang). Proves the new BLK_SETUP state has a liveness backstop like WAIT_OP0/OP1."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1

    # streaming resident RESADD: block16/E4M3 (supported), block_count=3 -> enters BLK_SETUP
    dut.block_size_log2_i.value = BS_16
    dut.dst_row_i.value = 0x60
    dut.src1_row_i.value = 0x20
    dut.src1_resident_i.value = 1
    dut.len_rows_i.value = 3
    dut.sidecar_base_i.value = 0x08
    dut.cmd_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    saw_blk_setup, got_done, err, code = False, False, 0, -1
    for _ in range(1300):                       # > VEC_WATCHDOG_THRESHOLD (1023)
        await FallingEdge(dut.clk_i)
        if int(dut.vu_state_o.value) == VST_BLK_SETUP:
            saw_blk_setup = True
        if int(dut.done_o.value) == 1:
            got_done = True
            err = int(dut.err_o.value)
            code = int(dut.err_code_o.value)
            break

    dut._log.info(f"streaming sidecar-read timeout: saw_blk_setup={saw_blk_setup} done={got_done} "
                  f"err={err} code={code} (expect a loud VERR_OPERAND_TIMEOUT={VERR_OPERAND_TIMEOUT})")
    assert saw_blk_setup, "streaming op never entered VST_BLK_SETUP (setup error)"
    assert got_done, "HANG: streaming sidecar read never timed out — VST_BLK_SETUP has no backstop"
    assert err == 1 and code == VERR_OPERAND_TIMEOUT, \
        f"sidecar-read timeout must be VERR_OPERAND_TIMEOUT (err={err} code={code})"

"""
cocotb E2E (STEP4-E2E inc 5, stage 1): the Vector consumption chain. Drive the
real vector_unit_top with vec_cmd(OP_VEC_RESADD) + two fast-path operand capsules
(SRC0, SRC1), let the RESADD pipeline run, and check the 256b L2 write-back vs
resadd_fastpath_golden. Closes the elaborate-only 2b behaviorally.

Config: block16 -> scale_format E4M3 (vec_cmd_to_desc D12 policy) with the E4M3
mantissa bits = 0, so mant_corr = 128 (precise-mode correction is identity =
the golden's simple path). E4M3 byte = exp<<3; exp=7 -> exp_adj=0.

Run: cd tb && make MODULE=test_vec_consume_e2e TOPLEVEL=tb_vec_consume_e2e \
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
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

BS_16 = 0
BLOCK_SIZE_16 = 0
SCALE_E4M3 = 1
OP_SRC0, OP_SRC1 = 0, 1
E4M3_EXP7 = 7 << 3   # 0x38 -> exp_adj 0, mant_corr 128


def to2c(v, bits):
    return v & ((1 << bits) - 1)


def pack(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= to2c(m, 16) << (i * 16)
    return v


async def reset(dut):
    for s in ("cmd_valid_i", "block_size_log2_i", "scale_epoch_i", "dst_row_i",
              "cap_valid_i", "cap_payload_i", "cap_role_i", "cap_block_size_i",
              "cap_scale_format_i", "cap_inline_scale_i", "cap_scale_epoch_i",
              "cap_fwd_i", "rw_gnt_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def push_cap(dut, role, mants, epoch, fails):
    # drive fields with valid deasserted, wait until the ingress is ready, then
    # assert valid for EXACTLY ONE rising edge (single-beat) so the capsule is
    # pushed once — holding valid high would push it repeatedly (role-misorder).
    dut.cap_payload_i.value = pack(mants)
    dut.cap_role_i.value = role
    dut.cap_block_size_i.value = BLOCK_SIZE_16
    dut.cap_scale_format_i.value = SCALE_E4M3
    dut.cap_inline_scale_i.value = E4M3_EXP7
    dut.cap_scale_epoch_i.value = epoch
    dut.cap_fwd_i.value = 1
    # canonical master: hold valid, sample ready at each rising edge; the first
    # edge where ready is high IS the transfer — drop valid right after so the
    # capsule is pushed exactly once.
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("capsule role=%d MISS reason=%d" % (role, int(dut.miss_reason_o.value)))
            break
        if int(dut.cap_ready_o.value) == 1:   # transfer occurred at this edge
            accepted = True
            break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("capsule role=%d never accepted (no cap_ready)" % role)
    await FallingEdge(dut.clk_i)


@cocotb.test()
async def test_vec_consume_e2e(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    EPOCH, DST = 0x05, 0x21
    mant0 = [100 + 10 * i for i in range(16)]
    mant1 = [50 + 5 * i for i in range(16)]

    # golden: block16, E4M3 mant_corr=128 (precise identity), exp_adj=0 both
    gold = g.resadd_fastpath_golden(mant0, 0, mant1, 0, mant_corr0=128, mant_corr1=128, precise=True)
    exp_wdata = pack(gold["aligned"])

    # always grant L2 writes; capture the write-back
    dut.rw_gnt_i.value = 1

    # 1) issue the RESADD command (desc). cmd_ready is high in IDLE; the accept
    # is a single cycle (IDLE + cmd_valid -> WAIT_OP0), so sample it at the
    # falling edge BEFORE the accept posedge, then drive for one cycle.
    dut.block_size_log2_i.value = BS_16
    dut.scale_epoch_i.value = EPOCH
    dut.dst_row_i.value = DST
    dut.cmd_valid_i.value = 1
    if int(dut.cmd_ready_o.value) != 1:
        fails.append("cmd_ready not high in IDLE (got %d)" % int(dut.cmd_ready_o.value))
    await RisingEdge(dut.clk_i)        # accept
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    # 2) push SRC0 then SRC1 capsules
    if not fails:
        await push_cap(dut, OP_SRC0, mant0, EPOCH, fails)
    if not fails:
        await push_cap(dut, OP_SRC1, mant1, EPOCH, fails)

    # 3) capture the L2 write-back
    got_wdata, got_row, got_done, saw_err = None, None, False, False
    if not fails:
        for _ in range(400):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value) == 1:
                saw_err = True
            if int(dut.rw_req_o.value) == 1:
                got_wdata = int(dut.rw_wdata_o.value)
                got_row = int(dut.rw_row_o.value)
            if int(dut.done_o.value) == 1:
                got_done = True
            if got_wdata is not None and got_done:
                break
        if saw_err:
            fails.append("FSM ERROR path: err_code=%d (1=BAD_PRIM 2=BAD_BLK 3=BAD_FMT 4=EPOCH 6=OVF 10=ROLE_MISORDER 11=SCALE_DECODE)" % int(dut.err_code_o.value))

        if got_wdata is None:
            fails.append("no L2 write-back (rw_req never asserted)")
        else:
            if got_wdata != exp_wdata:
                # report first differing lane
                for i in range(16):
                    gw = (got_wdata >> (i * 16)) & 0xFFFF
                    ew = (exp_wdata >> (i * 16)) & 0xFFFF
                    if gw != ew:
                        fails.append("L2 wdata lane %d: rtl=0x%04x gold=0x%04x (shared_exp=%d)"
                                     % (i, gw, ew, gold["shared_exp"]))
                        break
            if got_row != DST:
                fails.append("L2 row: rtl=0x%x exp=0x%x" % (got_row, DST))
        if not got_done:
            fails.append("done never pulsed")

    assert not fails, "vec consume E2E failures (%d):\n  %s" % (len(fails), "\n  ".join(fails[:20]))
    dut._log.info("vec consume E2E: RESADD of two fast-path capsules -> L2 write matches golden")

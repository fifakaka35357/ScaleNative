"""
cocotb test (STEP4-E2E Phase D): the hybrid full chain — the culmination.

  tens_cmd(GEMM) -> tensor_domain_top -> packer -> tv_fast_fifo -\
                                                                  mux -> vector_unit_top (RESADD) -> L2 RW
                                          injected SRC1 capsule  -/

The real Tensor BF16 GEMM egresses SRC0-tagged block16 capsules into the FIFO.
The tb forwards the FIRST one (GEMM result row 0) through the FIFO into the Vector
(the real GEMM->packer->FIFO->RESADD path for SRC0), snoops its fields, then flips
the mux to inject the SRC1 (residual) capsule (the Tensor egress hardwires
operand_role=OP_SRC0, so it cannot supply SRC1 — §9.7). The Vector RESADD writes
the sum to L2; we check it BIT-EXACT vs resadd_fastpath_golden using the CAPTURED
real GEMM-output capsule as SRC0. SRC1 carries the same E4M3 scale byte as the
captured SRC0 (so e0==e1) and a chosen payload.

Run: cd tb && make MODULE=test_soc_e2e TOPLEVEL=tb_soc_e2e \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../rtl/IBEX_SRAM/tensor_cmd_mmio_seq.sv \
        ../rtl/IBEX_SRAM/tensor_operand_stream.sv ../rtl/IBEX_SRAM/tensor_domain_top.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/tv_fast_fifo.sv ../tb/tb_soc_e2e.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

BS_16 = 0


def signed(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if (x >> (bits - 1)) & 1 else x


def to2c(v, bits):
    return v & ((1 << bits) - 1)


def lanes16(payload):
    return [signed((payload >> (i * 16)) & 0xFFFF, 16) for i in range(16)]


def pack(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= to2c(m, 16) << (i * 16)
    return v


def e4m3_decode(byte):
    """E4M3 block scale byte (mant=0 from the packer): exp_adj, mant_corr."""
    e4 = (byte >> 3) & 0xF
    m3 = byte & 0x7
    return e4 - 7, (8 + m3) << 4


async def reset(dut):
    for s in ("tcmd_valid_i", "t_src_row_i", "t_dst_row_i", "t_param_K_i", "t_scale_epoch_i",
              "ro_gnt_i", "ro_rvalid_i", "ro_rdata_i", "vcmd_valid_i", "v_block_size_log2_i",
              "v_scale_epoch_i", "v_dst_row_i", "sel_inject_i", "src1_valid_i",
              "src1_payload_i", "src1_iscale_i", "src1_epoch_i", "rw_gnt_i",
              "src1_scale_ref_i", "src1_abs_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def l2_model(dut):
    one = g.bf16_bits(1.0)
    low = 0
    for i in range(16):
        low |= (one & 0xFFFF) << (i * 16)
    rdata = (0xDEAD << 256) | low
    dut.ro_gnt_i.value = 0
    dut.ro_rvalid_i.value = 0
    pend = False
    while True:
        await FallingEdge(dut.clk_i)
        if pend:
            dut.ro_rvalid_i.value = 1
            dut.ro_rdata_i.value = rdata
            pend = False
        else:
            dut.ro_rvalid_i.value = 0
        if int(dut.ro_req_o.value) == 1:
            dut.ro_gnt_i.value = 1
            pend = True
        else:
            dut.ro_gnt_i.value = 0


@cocotb.test()
async def test_soc_e2e(dut):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    cocotb.start_soon(l2_model(dut))
    fails = []

    K, EPOCH, T_SRC, T_DST, V_DST = 24, 0x07, 0x010, 0x0C0, 0x21
    dut.rw_gnt_i.value = 1

    # 1) issue the Vector RESADD command (block16 -> E4M3 desc). cmd_ready high in
    #    IDLE; single-cycle accept.
    dut.v_block_size_log2_i.value = BS_16
    dut.v_scale_epoch_i.value = EPOCH
    dut.v_dst_row_i.value = V_DST
    dut.vcmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.vcmd_ready_o.value) == 1:
            break
    dut.vcmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    # 2) sel=0 (forward FIFO). issue the Tensor GEMM command.
    dut.sel_inject_i.value = 0
    dut.t_src_row_i.value = T_SRC
    dut.t_dst_row_i.value = T_DST
    dut.t_param_K_i.value = K
    dut.t_scale_epoch_i.value = EPOCH
    dut.tcmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.tcmd_ready_o.value) == 1:
            break
    dut.tcmd_valid_i.value = 0

    # 3) wait for the SRC0 capsule (GEMM row 0) to transfer FIFO -> Vector. Snoop
    #    its fields at the transfer cycle (fifo head, stable through the edge).
    src0 = None
    for _ in range(1500):
        await FallingEdge(dut.clk_i)
        if int(dut.v_miss_o.value) == 1:
            fails.append("SRC0 ingress MISS reason=%d" % int(dut.v_miss_reason_o.value))
            break
        if int(dut.vec_t2v_valid_o.value) == 1 and int(dut.vec_t2v_ready_o.value) == 1:
            src0 = {
                "payload": int(dut.snoop_payload_o.value),
                "iscale":  int(dut.snoop_iscale_o.value) & 0xFF,
                "iscale_full": int(dut.snoop_iscale_o.value),     # [T3] incl. bit8
                "scale_ref":   int(dut.snoop_scale_ref_o.value),  # [T3] abs block exp
                "sfmt":    int(dut.snoop_sfmt_o.value),
                "bsize":   int(dut.snoop_bsize_o.value),
                "role":    int(dut.snoop_role_o.value),
                "epoch":   int(dut.snoop_epoch_o.value),
            }
            break
    if src0 is None and not fails:
        fails.append("SRC0 capsule never reached the Vector ingress through the FIFO")

    if not fails:
        # SRC0 sanity: block16 E4M3, role SRC0, epoch matches
        if src0["sfmt"] != 1:
            fails.append("SRC0 scale_format=%d (expected SCALE_E4M3=1)" % src0["sfmt"])
        if src0["bsize"] != 0:
            fails.append("SRC0 block_size=%d (expected BLOCK_SIZE_16=0)" % src0["bsize"])
        if src0["role"] != 0:
            fails.append("SRC0 role=%d (expected OP_SRC0=0)" % src0["role"])
        if src0["epoch"] != EPOCH:
            fails.append("SRC0 epoch=0x%x != 0x%x" % (src0["epoch"], EPOCH))
        if all(q == 0 for q in lanes16(src0["payload"])):
            fails.append("SRC0 payload all-zero — GEMM did not produce a result")

    # 4) let SRC0 finish transferring, then flip the mux to inject SRC1.
    if not fails:
        await RisingEdge(dut.clk_i)     # SRC0 transfer completes here
        dut.sel_inject_i.value = 1
        # [HW-REVIEW T3 RED-B] SRC1 at a DIFFERENT absolute block exponent than SRC0
        # (e1 = e0_true - 2), both via the absolute-scale path. This exercises the
        # RELATIVE alignment by the UNCLAMPED exponent: SRC0's true e0 is out of the
        # E4M3 [-6,8] window (small GEMM output), so pre-fix the clamped byte gives the
        # wrong relative shift (this is what made test_soc_e2e RED); the abs scale_ref
        # restores the correct shift. mant=0 byte -> mant_corr 128 (identity) on both.
        e0 = g.abs_scale_decode(src0["scale_ref"], src0["iscale_full"], g.SCALE_E4M3)
        e1 = e0 - 2
        src1_mants = [40 + 4 * i for i in range(16)]
        src1_payload = pack(src1_mants)
        src1_byte = 0x38                          # E4M3 exp0/mant0 -> mant_corr 128
        dut.src1_payload_i.value = src1_payload
        dut.src1_iscale_i.value = src1_byte
        dut.src1_scale_ref_i.value = e1 & 0xFFFF  # [T3] SRC1 absolute exp
        dut.src1_abs_i.value = 1                   # [T3] use the abs path for SRC1
        dut.src1_epoch_i.value = EPOCH
        dut.src1_valid_i.value = 1
        # hold valid until the SRC1 ingress handshake, then drop (single beat)
        accepted = False
        for _ in range(60):
            await RisingEdge(dut.clk_i)
            if int(dut.v_miss_o.value) == 1:
                fails.append("SRC1 ingress MISS reason=%d" % int(dut.v_miss_reason_o.value))
                break
            if int(dut.vec_t2v_ready_o.value) == 1:
                accepted = True
                break
        dut.src1_valid_i.value = 0
        if not accepted and not fails:
            fails.append("SRC1 capsule never accepted by the Vector ingress")
        await FallingEdge(dut.clk_i)

    # 5) capture the L2 write-back and check vs resadd_fastpath_golden.
    if not fails:
        # oracle uses the CAPTURED real GEMM SRC0 + the injected SRC1, both aligned by
        # their ABSOLUTE block exponents (e0 from scale_ref, e1 chosen above). mant_corr
        # from each E4M3 byte (mant=0 -> 128 identity on both).
        src0_mants = lanes16(src0["payload"])
        _, mc0 = e4m3_decode(src0["iscale"])
        _, mc1 = e4m3_decode(src1_byte)
        gold = g.resadd_fastpath_golden(src0_mants, e0, src1_mants, e1,
                                        mant_corr0=mc0, mant_corr1=mc1, precise=True)
        exp_wdata = pack(gold["aligned"])

        got_wdata, got_row, got_done, saw_err = None, None, False, False
        for _ in range(400):
            await FallingEdge(dut.clk_i)
            if int(dut.v_err_o.value) == 1:
                saw_err = True
            if int(dut.rw_req_o.value) == 1:
                got_wdata = int(dut.rw_wdata_o.value)
                got_row = int(dut.rw_row_o.value)
            if int(dut.v_done_o.value) == 1:
                got_done = True
            if got_wdata is not None and got_done:
                break
        if saw_err:
            fails.append("Vector FSM error: err_code=%d" % int(dut.v_err_code_o.value))
        if got_wdata is None:
            fails.append("no L2 write-back (rw_req never asserted)")
        else:
            if got_wdata != exp_wdata:
                for i in range(16):
                    gw = (got_wdata >> (i * 16)) & 0xFFFF
                    ew = (exp_wdata >> (i * 16)) & 0xFFFF
                    if gw != ew:
                        fails.append("L2 wdata lane %d: rtl=0x%04x gold=0x%04x (shared_exp=%d, e0=%d e1=%d)"
                                     % (i, gw, ew, gold["shared_exp"], e0, e1))
                        break
            if got_row != V_DST:
                fails.append("L2 row: rtl=0x%x exp=0x%x" % (got_row, V_DST))
        if not got_done:
            fails.append("Vector done never pulsed")

    assert not fails, "SoC E2E failures (%d):\n  %s" % (len(fails), "\n  ".join(fails[:20]))
    dut._log.info(
        "SoC E2E: real GEMM -> packer -> FIFO -> RESADD(+injected SRC1) -> L2_WB; the L2 "
        "write matches resadd_fastpath_golden(captured_real_SRC0, injected_SRC1) BIT-EXACT")

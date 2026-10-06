"""
cocotb test (STEP4-E2E §11, D-E2E-BENCH P2 integration): real vector_unit_top
STORE -> real l2_subsystem, verified by per-physical-bank readback.

A Vector STORE with half_sel=1 must physically land in banks 8-15. The test
captures the unit's OWN rw_wdata at the write, then reads back each physical bank
via dma_evict and asserts bank(8+j)==captured_wdata[j*32+:32], banks 0-7 untouched.
No recomputed datapath numerics — the comparison is captured-write vs readback.

Run: cd tb && make MODULE=test_l2_vec_store_readback TOPLEVEL=tb_l2_vec_store_readback \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_bank.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_ro_arbiter.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_rw_arbiter.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_subsystem.sv \
        ../tb/tb_l2_vec_store_readback.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

BLOCK_SIZE_32 = 1
SCALE_E8M0 = 0
OP_SRC0 = 0
DST_OFF = 0x33   # phys row for the write (region not used; vector_unit_top.rw_row = dst_row)


async def reset(dut):
    for s in ("cmd_valid_i", "half_sel_i", "dst_row_i", "cap_valid_i", "cap_payload_i",
              "cap_role_i", "cap_block_size_i", "cap_scale_format_i", "cap_inline_scale_i",
              "cap_scale_epoch_i", "cap_fwd_i", "dma_evict_req_i", "dma_evict_bank_i",
              "dma_evict_row_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def push_cap(dut, role, payload, fails):
    dut.cap_payload_i.value = payload
    dut.cap_role_i.value = role
    dut.cap_block_size_i.value = BLOCK_SIZE_32
    dut.cap_scale_format_i.value = SCALE_E8M0
    dut.cap_inline_scale_i.value = 127
    dut.cap_scale_epoch_i.value = 0
    dut.cap_fwd_i.value = 1
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
        fails.append("capsule role=%d never accepted" % role)
    await FallingEdge(dut.clk_i)


async def evict_read(dut, bank, row):
    dut.dma_evict_bank_i.value = bank
    dut.dma_evict_row_i.value = row
    dut.dma_evict_req_i.value = 1
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)        # [C2] 2-cycle L2 read (l2_bank OUT_REG=1): sample at E2
    val = int(dut.dma_evict_rdata_o.value)
    dut.dma_evict_req_i.value = 0
    await RisingEdge(dut.clk_i)
    return val


@cocotb.test()
async def test_l2_vec_store_high_half(dut):
    """Real vector_unit_top STORE(half_sel=1) -> banks 8-15 hold the unit's wdata."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    # 1) issue vec_cmd(STORE, half_sel=1) directly (single-cycle accept in IDLE)
    dut.half_sel_i.value = 1
    dut.dst_row_i.value = DST_OFF
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    # 2) STORE is block32 -> two SRC0 capsules
    p0 = 0
    p1 = 0
    for i in range(16):
        p0 |= ((0x1000 + i) & 0xFFFF) << (i * 16)
        p1 |= ((0x2000 + i) & 0xFFFF) << (i * 16)
    await push_cap(dut, OP_SRC0, p0, fails)
    if not fails:
        await push_cap(dut, OP_SRC0, p1, fails)

    # 3) capture the unit's own L2 write (first window)
    cap_row, cap_wdata, saw_err = None, None, False
    if not fails:
        for _ in range(120):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if cap_wdata is None and int(dut.rw_req_o.value) == 1:
                cap_row = int(dut.rw_row_o.value)
                cap_wdata = int(dut.rw_wdata_o.value)
                if int(dut.rw_half_sel_o.value) != 1:
                    fails.append("rw_half_sel != 1 at write")
            if int(dut.done_o.value) == 1:
                break
        if saw_err:
            fails.append("vector_unit error during STORE")
        if cap_wdata is None:
            fails.append("no L2 write captured")

    # 4) read back each physical bank at the written row; high half == captured wdata
    if not fails:
        for j in range(8):
            got = await evict_read(dut, 8 + j, cap_row)
            exp = (cap_wdata >> (j * 32)) & 0xFFFFFFFF
            if got != exp:
                fails.append("bank %d: readback 0x%08x != captured wdata lane 0x%08x" % (8 + j, got, exp))
        for b in (0, 7):
            got = await evict_read(dut, b, cap_row)
            if got != 0:
                fails.append("bank %d (low half) = 0x%08x, expected untouched (STORE half_sel=1 leaked!)" % (b, got))

    assert not fails, "vec STORE readback failures:\n  " + "\n  ".join(fails)
    dut._log.info("P2-integration: real vector_unit_top STORE(half_sel=1) physically landed in L2 banks 8-15 "
                  "(row=0x%x), low half untouched" % cap_row)

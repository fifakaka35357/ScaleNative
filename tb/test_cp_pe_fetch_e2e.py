"""
cocotb test (STEP4-E2E §11.2, D-E2E-BENCH pe_top-level fetch bench): the REAL
command_processor fetches + issues a descriptor from a behavioral L1D — the
layer P1 mocked. No ibex; command_processor's MMIO slave + L1D port are driven
directly. Two tests:
  1. fetch a valid OP_VEC_STORE -> issue -> vector_unit_top STORE -> L2 write;
     ctx0 runs IDLE->RUNNABLE->WAIT_VEC->(done)->CTX_DONE. half_sel preserved.
  2. NEGATIVE CONTROL: a descriptor with len_rows==0 is poisoned at fetch
     (ERR_INVALID_PARAM) -> ctx0 -> CTX_ERROR, NO vec_cmd issued. This exercises
     the fetch-engine validation P1 could never see.

Run: cd tb && make MODULE=test_cp_pe_fetch_e2e TOPLEVEL=tb_cp_pe_fetch_e2e \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/cp_csr.sv ../rtl/IBEX_SRAM/cp_desc_fetch.sv \
        ../rtl/IBEX_SRAM/cp_scheduler.sv ../rtl/IBEX_SRAM/cp_completion.sv ../rtl/IBEX_SRAM/event_trace_ring.sv \
        ../rtl/IBEX_SRAM/command_processor.sv ../tb/tb_cp_pe_fetch_e2e.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

OP_VEC_STORE = 0x02
OP_VEC_RESADD = 0x04
OP_VEC_RESADD_RESIDENT = 0x05   # [T3-FF/FF1] resident-RESADD variant (min_ext=4, loud-reject)
BLOCK_SIZE_16, BLOCK_SIZE_32 = 0, 1
SCALE_E8M0, SCALE_E4M3 = 0, 1
OP_TENS_GEMM = 0x10             # [C-1] Tensor-dispatched opcode
OP_DMA_MEMSET = 0x22            # [3a-7/P2] OP 门的负控用（word[5] 对它是 memset_val）
# pe_pkg elem_fmt_e encodings (word6[3:0])
ELEM_BF16, ELEM_FP8_E5M2, ELEM_INT8, ELEM_MXFP4 = 0x0, 0x2, 0x4, 0x7
ERR_INVALID_PARAM = 7           # pe_pkg err_class_e
OP_SRC0, OP_SRC1 = 0, 1
E4M3_EXP7 = 7 << 3        # 0x38 -> exp_adj 0, mant_corr 128 (precise identity)
CTX_DONE, CTX_ERROR = 6, 7
VST_DONE = 5
ERR_EXT_UNDERFLOW = 2     # err_class_e: ext_len < min_ext_for_opcode


def signed(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if (x >> (bits - 1)) & 1 else x


def pack(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= (m & 0xFFFF) << (i * 16)
    return v

RING_BASE = 0x040          # L1D byte addr of the descriptor
REGION0_BASE = 0x100       # L2 region base
REGION0_NUM = 0x1000
DST_OFF = 0x012            # phys_dst = REGION0_BASE + DST_OFF
SRC_OFF = 0x000

# cp_csr MMIO byte offsets
A_CTRL, A_RING_BASE, A_RING_CFG, A_DOORBELL = 0x00, 0x10, 0x14, 0x18
A_REGION0_BASE, A_REGION0_NUM = 0x80, 0x84


def build_desc(opcode, dst_off, half_sel, len_rows, src_off=0, ctx=0, ext_len=4,
               src1_resident=0, src1_scale_ref=0, scale_rid=0, scale_row_off=0,
               elem_fmt=0, word5=0):
    # ext_len=4 -> total_words=DESC_BASE(4)+4=8 -> 4 pairs fetched, so the
    # tile_contract at words 6:7 (carrying half_sel) is loaded into the slot.
    # (ext_len<4 -> words 6:7 zero-cleared -> half_sel lost; cp_desc_fetch.sv:61-66.)
    # [T3-FF/FF1] word6[28]=src1_resident, word7[31:16]=signed src1_scale_ref.
    w = [0] * 8
    w[0] = (opcode & 0xFF) | ((ext_len & 0xF) << 8) | ((ctx & 0x3) << 12)
    w[1] = (src_off & 0xFFFF)                         # src l2_addr rid0
    w[2] = (dst_off & 0xFFFF)                         # dst l2_addr rid0
    w[3] = (len_rows & 0xFFFF)                        # len_rows (>=1 or poisoned)
    # [3a-7/P2] word[5]: TENS_GEMM/CONV -> [15:0] param_K, [17:16] n_cfg,
    #                    [19:18] M (RESERVED), [31:20] RESERVED
    #                    DMA_MEMSET  -> [31:0] memset_val
    # Default 0 -> every pre-existing call site is bit-for-bit unchanged
    # (n_cfg=NCFG_DENSE, reserved bits all zero -> the wi==4 arm never fires).
    w[5] = (word5 & 0xFFFFFFFF)
    # word6[3:0] = tile_contract_t.elem_fmt (pe_pkg extract_tile_contract).
    # Default 0 = ELEM_BF16 -> every pre-existing call site is bit-for-bit unchanged.
    w[6] = ((1 << 9) if half_sel else 0) | ((1 << 28) if src1_resident else 0) \
         | ((scale_rid & 0xF) << 16) | (elem_fmt & 0xF)  # word6[19:16] scale rid, [3:0] elem_fmt
    w[7] = ((src1_scale_ref & 0xFFFF) << 16) \
         | (scale_row_off & 0xFFFF)                    # word7[31:16] abs exp, [15:0] scale_row_off
    v = 0
    for i, word in enumerate(w):
        v |= (word & 0xFFFFFFFF) << (i * 32)
    return v


async def reset(dut):
    for s in ("mmio_req_i", "mmio_addr_i", "mmio_we_i", "mmio_be_i", "mmio_wdata_i",
              "desc_i", "ring_base_i", "cap_valid_i", "cap_payload_i", "cap_role_i",
              "cap_block_size_i", "cap_scale_format_i", "cap_inline_scale_i",
              "cap_scale_epoch_i", "cap_fwd_i", "rw_gnt_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def mmio_wr(dut, addr, data):
    dut.mmio_addr_i.value = addr
    dut.mmio_wdata_i.value = data
    dut.mmio_be_i.value = 0xF
    dut.mmio_we_i.value = 1
    dut.mmio_req_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.mmio_req_i.value = 0
    dut.mmio_we_i.value = 0
    await FallingEdge(dut.clk_i)


async def program_cp(dut, half_sel, len_rows, opcode=OP_VEC_STORE, ext_len=4,
                     src1_resident=0, src1_scale_ref=0, scale_rid=0, scale_row_off=0,
                     elem_fmt=0, word5=0):
    """Place the descriptor + program ring/region; doorbell LAST."""
    dut.desc_i.value = build_desc(opcode, DST_OFF, half_sel, len_rows, SRC_OFF,
                                  ext_len=ext_len, src1_resident=src1_resident,
                                  src1_scale_ref=src1_scale_ref,
                                  scale_rid=scale_rid, scale_row_off=scale_row_off,
                                  elem_fmt=elem_fmt, word5=word5)
    dut.ring_base_i.value = RING_BASE
    await mmio_wr(dut, A_CTRL, 0x1)               # enable
    await mmio_wr(dut, A_RING_BASE, RING_BASE)
    await mmio_wr(dut, A_RING_CFG, 0x1)
    await mmio_wr(dut, A_REGION0_BASE, REGION0_BASE)
    await mmio_wr(dut, A_REGION0_NUM, REGION0_NUM)
    await mmio_wr(dut, A_DOORBELL, 0x1)           # ring_tail=1 + doorbell pulse (LAST)


async def push_cap(dut, role, payload, fails, block_size=BLOCK_SIZE_32,
                   scale_format=SCALE_E8M0, inline_scale=127):
    dut.cap_payload_i.value = payload
    dut.cap_role_i.value = role
    dut.cap_block_size_i.value = block_size
    dut.cap_scale_format_i.value = scale_format
    dut.cap_inline_scale_i.value = inline_scale
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


@cocotb.test()
async def test_cp_fetch_store(dut):
    """Real fetch->issue->STORE->L2; ctx0 reaches CTX_DONE; half_sel preserved."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1
    fails = []
    HALF = 1

    await program_cp(dut, half_sel=HALF, len_rows=1)

    # wait for the scheduler to ISSUE the STORE (fetched from L1D, not mocked)
    issued = False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.cp_err_valid_o.value) == 1:
            fails.append("unexpected CP error class=%d before issue" % int(dut.cp_err_class_o.value))
            break
        if int(dut.vec_cmd_valid_o.value) == 1 and int(dut.issue_opcode_o.value) == OP_VEC_STORE:
            issued = True
            if int(dut.issue_half_sel_o.value) != HALF:
                fails.append("issued half_sel=%d != %d" % (int(dut.issue_half_sel_o.value), HALF))
            break
    if not issued and not fails:
        fails.append("command_processor never fetched+issued the STORE")

    # inject the STORE operand (block32 = two SRC0 capsules)
    if not fails:
        p0 = sum(((0x1000 + i) & 0xFFFF) << (i * 16) for i in range(16))
        p1 = sum(((0x2000 + i) & 0xFFFF) << (i * 16) for i in range(16))
        await push_cap(dut, OP_SRC0, p0, fails)
    if not fails:
        await push_cap(dut, OP_SRC0, p1, fails)

    # capture the deferred L2 write + run to completion + ctx0 lifecycle
    rw_half, rw_row, rw_w, done, done_state, saw_err = None, None, None, False, -1, False
    if not fails:
        for _ in range(160):
            await FallingEdge(dut.clk_i)
            if int(dut.vu_err_o.value) or int(dut.cp_err_valid_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_half = int(dut.rw_half_sel_o.value)
                rw_row = int(dut.rw_row_o.value)
                rw_w = int(dut.rw_wdata_o.value)
            if int(dut.vec_done_o.value) == 1:
                done = True
                done_state = int(dut.vu_state_o.value)
                break
        if rw_w is None:
            fails.append("no L2 write observed")
        else:
            if rw_half != HALF:
                fails.append("rw_half_sel=%d != %d" % (rw_half, HALF))
            if rw_row != (REGION0_BASE + DST_OFF):
                fails.append("rw_row=0x%x != phys_dst 0x%x" % (rw_row, REGION0_BASE + DST_OFF))
            if rw_w == 0:
                fails.append("L2 wdata all-zero")
        if not done:
            fails.append("vec done never pulsed")
        elif done_state != VST_DONE:
            fails.append("completion via VST_ERROR (state=%d)" % done_state)
        if saw_err:
            fails.append("error pulsed during run")

    # ctx0 lifecycle: ring empty + slot empty -> CTX_DONE
    if not fails:
        reached_done = False
        for _ in range(40):
            await FallingEdge(dut.clk_i)
            if int(dut.ctx0_state_o.value) == CTX_DONE:
                reached_done = True
                break
        if not reached_done:
            fails.append("ctx0 never reached CTX_DONE (state=%d)" % int(dut.ctx0_state_o.value))

    assert not fails, "CP fetch->STORE failures:\n  " + "\n  ".join(fails)
    dut._log.info("PE-fetch E2E: REAL command_processor fetched a STORE from L1D, issued it, the Vector wrote "
                  "L2 (half_sel=%d, row=0x%x), and ctx0 ran the full lifecycle to CTX_DONE" % (HALF, rw_row))


@cocotb.test()
async def test_cp_fetch_poison_len0(dut):
    """NEGATIVE CONTROL: len_rows==0 -> fetch poison -> ctx0 CTX_ERROR, no issue."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1
    fails = []

    await program_cp(dut, half_sel=0, len_rows=0)   # len_rows=0 is illegal for STORE

    saw_err, saw_issue = False, False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.vec_cmd_valid_o.value) == 1 and int(dut.issue_opcode_o.value) == OP_VEC_STORE:
            saw_issue = True
        if int(dut.cp_err_valid_o.value) == 1:
            saw_err = True
        if int(dut.ctx0_state_o.value) == CTX_ERROR:
            break

    if saw_issue:
        fails.append("a poisoned (len_rows=0) STORE was ISSUED to the Vector — fetch validation failed")
    if not saw_err:
        fails.append("no CP error pulse for the poisoned descriptor")
    if int(dut.ctx0_state_o.value) != CTX_ERROR:
        fails.append("ctx0 not in CTX_ERROR (state=%d) after poisoned fetch" % int(dut.ctx0_state_o.value))

    assert not fails, "poison negative-control failures:\n  " + "\n  ".join(fails)
    dut._log.info("PE-fetch E2E negative control: len_rows=0 descriptor poisoned at fetch -> ctx0 CTX_ERROR, "
                  "never issued (fetch-engine validation is live)")


@cocotb.test()
async def test_cp_fetch_resadd(dut):
    """D5-2 graduation: a SOFTWARE OP_VEC_RESADD descriptor is no longer poisoned
    — it fetches + issues through the REAL cp_scheduler (credit/tag/completion),
    the Vector RESADDs two injected fast-path capsules, and the L2 write-back is
    bit-exact vs resadd_fastpath_golden. (SRC0/SRC1 are tb-injected here; the
    hardware SRC1 producer is §11.4.) Default contract (ext_len=0) => block16/E4M3."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1
    fails = []

    # RESADD with the default (zeroed) contract -> block16/E4M3 (NVFP4), epoch 0.
    await program_cp(dut, half_sel=0, len_rows=1, opcode=OP_VEC_RESADD, ext_len=0)

    # wait for the scheduler to ISSUE a RESADD (proves un-poisoned + dispatched)
    issued = False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.cp_err_valid_o.value) == 1:
            fails.append("CP error class=%d (RESADD wrongly poisoned/rejected)" % int(dut.cp_err_class_o.value))
            break
        if int(dut.vec_cmd_valid_o.value) == 1 and int(dut.issue_opcode_o.value) == OP_VEC_RESADD:
            issued = True
            break
    if not issued and not fails:
        fails.append("cp_scheduler never issued the software RESADD (D5-2 dispatch broken)")

    # inject SRC0 then SRC1 (block16/E4M3, mant=0 -> mant_corr=128 identity)
    mant0 = [100 + 10 * i for i in range(16)]
    mant1 = [50 + 5 * i for i in range(16)]
    if not fails:
        await push_cap(dut, OP_SRC0, pack(mant0), fails, BLOCK_SIZE_16, SCALE_E4M3, E4M3_EXP7)
    if not fails:
        await push_cap(dut, OP_SRC1, pack(mant1), fails, BLOCK_SIZE_16, SCALE_E4M3, E4M3_EXP7)

    # golden: same-exponent precise-identity RESADD
    gold = g.resadd_fastpath_golden(mant0, 0, mant1, 0, mant_corr0=128, mant_corr1=128, precise=True)
    exp_wdata = pack(gold["aligned"])

    rw_w, rw_row, done, done_state, saw_err = None, None, False, -1, False
    if not fails:
        for _ in range(200):
            await FallingEdge(dut.clk_i)
            if int(dut.vu_err_o.value) or int(dut.cp_err_valid_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_w = int(dut.rw_wdata_o.value)
                rw_row = int(dut.rw_row_o.value)
            if int(dut.vec_done_o.value) == 1:
                done = True
                done_state = int(dut.vu_state_o.value)
                break
        if rw_w is None:
            fails.append("no L2 write observed for RESADD")
        elif rw_w != exp_wdata:
            for i in range(16):
                gw = (rw_w >> (i * 16)) & 0xFFFF
                ew = (exp_wdata >> (i * 16)) & 0xFFFF
                if gw != ew:
                    fails.append("RESADD L2 lane %d: rtl=0x%04x gold=0x%04x" % (i, gw, ew))
                    break
        if rw_row is not None and rw_row != (REGION0_BASE + DST_OFF):
            fails.append("rw_row=0x%x != phys_dst 0x%x" % (rw_row, REGION0_BASE + DST_OFF))
        if not done:
            fails.append("RESADD done never pulsed")
        elif done_state != VST_DONE:
            fails.append("RESADD completion via VST_ERROR (state=%d)" % done_state)
        if saw_err:
            fails.append("error pulsed during RESADD run")

    assert not fails, "CP fetch->RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("PE-fetch E2E RESADD (D5-2): software OP_VEC_RESADD fetched + dispatched by the REAL "
                  "cp_scheduler, RESADD of two fast-path capsules -> L2 write bit-exact vs golden")


@cocotb.test()
async def test_cp_fetch_resident_scale_decode(dut):
    """[T3-FF/FF1] A resident RESADD issued as OP_VEC_RESADD_RESIDENT through the
    REAL command_processor: word7[31:16] (signed per-residual abs exp) survives to
    vec_cmd.contract.src1_scale_ref, residency is set, and the opcode is normalized
    to OP_VEC_RESADD for the downstream (frozen) Vector adapter. RED pre-fix: opcode
    0x05 is unknown -> poisoned at fetch (ERR_UNKNOWN_OPCODE), never issued."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1
    fails = []

    E = -5                                   # negative abs exp = sign-extension discriminator
    w7 = (E & 0xFFFF) << 16
    # independent oracle (authored from the ISA comment) decodes the same word7:
    if g.extract_tile_contract_golden(0x0, w7)["src1_scale_ref"] != E:
        fails.append("golden word-decode wrong (oracle bug, not a DUT failure)")

    # [T3-FF/FF3b-c] also pin the scale-sidecar address translation: cp_scheduler must
    # xlat scale_rid(=0)/scale_row_off through the SAME region table as src/dst, so
    # phys_sidecar = region_table[0].base_row + scale_row_off = REGION0_BASE + SCALE_OFF.
    SCALE_OFF = 0x023
    await program_cp(dut, half_sel=0, len_rows=1, opcode=OP_VEC_RESADD_RESIDENT,
                     ext_len=4, src1_resident=1, src1_scale_ref=(E & 0xFFFF),
                     scale_rid=0, scale_row_off=SCALE_OFF)

    issued = False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.cp_err_valid_o.value) == 1:
            fails.append("CP error class=%d (resident RESADD wrongly poisoned/rejected)"
                         % int(dut.cp_err_class_o.value))
            break
        if int(dut.vec_cmd_valid_o.value) == 1:
            op = int(dut.issue_opcode_o.value)
            if op != OP_VEC_RESADD:
                fails.append("issued opcode=0x%02x not normalized to OP_VEC_RESADD" % op)
            if int(dut.issue_src1_resident_o.value) != 1:
                fails.append("issued src1_resident=%d != 1" % int(dut.issue_src1_resident_o.value))
            got = signed(int(dut.issue_src1_scale_ref_o.value), 16)
            if got != E:
                fails.append("issued src1_scale_ref=%d != %d (word7 sign-decode lost)" % (got, E))
            sb = int(dut.issue_sidecar_base_o.value)
            if sb != (REGION0_BASE + SCALE_OFF):
                fails.append("issued sidecar_base=0x%x != xlat 0x%x (scale_rid/row_off not "
                             "translated)" % (sb, REGION0_BASE + SCALE_OFF))
            issued = True
            break
    if not issued and not fails:
        fails.append("cp_scheduler never issued the resident RESADD")

    assert not fails, "FF1 resident-scale-decode failures:\n  " + "\n  ".join(fails)
    dut._log.info("FF1: OP_VEC_RESADD_RESIDENT fetched by the REAL command_processor, word7 signed "
                  "abs-exp %d survived to vec_cmd.contract.src1_scale_ref, residency set, opcode "
                  "normalized to OP_VEC_RESADD" % E)


@cocotb.test()
async def test_cp_fetch_resident_underlength_reject(dut):
    """[T3-FF/FF1] An OP_VEC_RESADD_RESIDENT with ext_len < 4 (words 6/7 not fetched)
    is LOUD-REJECTED at fetch with ERR_EXT_UNDERFLOW -> ctx0 CTX_ERROR, never issued.
    This closes the silent-degrade the variant opcode was added for (under-length would
    otherwise zero BOTH residency + scale and run as a fast-path RESADD with no error).
    RED pre-fix: opcode 0x05 unknown -> ERR_UNKNOWN_OPCODE (class 3), not class 2."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1
    fails = []

    await program_cp(dut, half_sel=0, len_rows=1, opcode=OP_VEC_RESADD_RESIDENT,
                     ext_len=2, src1_resident=1, src1_scale_ref=0x000C)   # under-length

    saw_issue, err_class = False, None
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.vec_cmd_valid_o.value) == 1:
            saw_issue = True
        if int(dut.cp_err_valid_o.value) == 1 and err_class is None:
            err_class = int(dut.cp_err_class_o.value)
        if int(dut.ctx0_state_o.value) == CTX_ERROR:
            break

    if saw_issue:
        fails.append("an under-length resident RESADD was ISSUED (silent-degrade not closed)")
    if err_class != ERR_EXT_UNDERFLOW:
        fails.append("err_class=%s != ERR_EXT_UNDERFLOW(%d)" % (err_class, ERR_EXT_UNDERFLOW))
    if int(dut.ctx0_state_o.value) != CTX_ERROR:
        fails.append("ctx0 not CTX_ERROR (state=%d)" % int(dut.ctx0_state_o.value))

    assert not fails, "FF1 underlength-reject failures:\n  " + "\n  ".join(fails)
    dut._log.info("FF1: under-length OP_VEC_RESADD_RESIDENT (ext_len=2) loud-rejected at fetch "
                  "(ERR_EXT_UNDERFLOW) -> ctx0 CTX_ERROR, never issued")


@cocotb.test()
async def test_cp_fetch_resident_opcode_implies_residency(dut):
    """[T3-FF/FF1] Residency is IMPLIED by OP_VEC_RESADD_RESIDENT itself, not word6[28]:
    issue 0x05 with word6[28]=0 (src1_resident NOT set in the descriptor) and assert
    cp_scheduler FORCES vec_cmd.contract.src1_resident=1. ISOLATES the opcode-implied
    force (cp_scheduler emit): with that force removed this test REDs, whereas the
    word6[28]=1 decode-survival test cannot distinguish force-present from force-absent.
    (Closes the FF1 adversarial-review coverage gap.)"""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1
    fails = []

    # word6[28]=0 — the ONLY thing that can set issue_src1_resident_o=1 is the
    # cp_scheduler opcode-implied force (residency is the opcode's job here).
    await program_cp(dut, half_sel=0, len_rows=1, opcode=OP_VEC_RESADD_RESIDENT,
                     ext_len=4, src1_resident=0, src1_scale_ref=0x0007)

    issued = False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.cp_err_valid_o.value) == 1:
            fails.append("CP error class=%d (resident opcode wrongly rejected)"
                         % int(dut.cp_err_class_o.value))
            break
        if int(dut.vec_cmd_valid_o.value) == 1:
            if int(dut.issue_src1_resident_o.value) != 1:
                fails.append("opcode-implied residency NOT forced: src1_resident=%d with "
                             "word6[28]=0 (the cp_scheduler force regressed)"
                             % int(dut.issue_src1_resident_o.value))
            if int(dut.issue_opcode_o.value) != OP_VEC_RESADD:
                fails.append("opcode not normalized to OP_VEC_RESADD (0x%02x)"
                             % int(dut.issue_opcode_o.value))
            issued = True
            break
    if not issued and not fails:
        fails.append("cp_scheduler never issued the resident RESADD")

    assert not fails, "FF1 opcode-implied-residency failures:\n  " + "\n  ".join(fails)
    dut._log.info("FF1: OP_VEC_RESADD_RESIDENT with word6[28]=0 -> cp_scheduler FORCES "
                  "src1_resident=1 (residency implied by the opcode; isolates the force)")


# =============================================================================
# [C-1 2026-07-31] elem_fmt whitelist gate — RED/GREEN pair.
#
# Guards the cross-module fail-open registered as PROJECT_RULES §5.0d type 15:
# tensor_cmd_mmio_seq.sv delegated rejection of unexecutable elem_fmt values to
# the CP ("poison-on-issue -> ERR_INVALID_PARAM"), but no such check existed
# (MISS_UNSUPPORTED_FMT had zero consumers repo-wide), so ELEM_INT8/INT4 were
# accepted and produced a silently wrong capsule. Gate now lives at
# cp_desc_fetch.sv ST_FETCH_PAIR_N via pe_pkg::fmt_tensor_executable().
#
# 🔴 These two MUST stay paired: the red alone would also pass if the fetch
# engine poisoned *everything*; the green is what proves the gate is selective.
# =============================================================================


async def _run_tens_gemm_fetch(dut, elem_fmt):
    """Issue an otherwise-valid OP_TENS_GEMM carrying elem_fmt; observe ctx0."""
    await tbreset.preclock_reset(dut, rst="rst_ni")   # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1

    # len_rows=1 (legal) + ext_len=4 so words 6:7 are fetched — the gate reads
    # word 6 as it arrives (pair_idx==3). With ext_len<4 the contract words are
    # zero-cleared and elem_fmt would decode to ELEM_BF16.
    await program_cp(dut, half_sel=0, len_rows=1, opcode=OP_TENS_GEMM,
                     ext_len=4, elem_fmt=elem_fmt)

    saw_err, err_class, reached_error = False, None, False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.cp_err_valid_o.value) == 1:
            saw_err = True
            err_class = int(dut.cp_err_class_o.value)
        if int(dut.ctx0_state_o.value) == CTX_ERROR:
            reached_error = True
            break
    return saw_err, err_class, reached_error


@cocotb.test()
async def test_cp_fetch_poison_bad_elem_fmt(dut):
    """RED: OP_TENS_GEMM with ELEM_INT8 must be poisoned (ERR_INVALID_PARAM).

    ELEM_INT8 maps to MODE_UINT8, which the array computes — but the INT psum
    chain has no reader in tensor_unit_top and egress moves only the FP
    accumulator, so without this gate firmware gets a capsule that is neither an
    error nor the answer.
    """
    fails = []
    saw_err, err_class, reached_error = await _run_tens_gemm_fetch(dut, ELEM_INT8)

    if not reached_error:
        fails.append("ctx0 did NOT reach CTX_ERROR (state=%d) — an unexecutable "
                     "elem_fmt (ELEM_INT8) was accepted; the C-1 gate is not live"
                     % int(dut.ctx0_state_o.value))
    if not saw_err:
        fails.append("no CP error pulse for the ELEM_INT8 descriptor")
    elif err_class != ERR_INVALID_PARAM:
        fails.append("wrong err_class: got %s, expected ERR_INVALID_PARAM(%d)"
                     % (err_class, ERR_INVALID_PARAM))

    assert not fails, "C-1 red-sample failures:\n  " + "\n  ".join(fails)
    dut._log.info("C-1 RED: OP_TENS_GEMM(ELEM_INT8) poisoned at fetch with "
                  "ERR_INVALID_PARAM -> ctx0 CTX_ERROR (gate is live)")


@cocotb.test()
async def test_cp_fetch_poison_bad_elem_fmt_e5m2(dut):
    """RED #2: ELEM_FP8_E5M2 is equally unsafe and must also be poisoned.

    tensor_pkg.sv:114-117 — E5M2 is architecturally reserved but NOT supported;
    all FP8 datapaths assume E4M3FN. The $fatal guard in mac_lru.sv sits inside
    `synopsys translate_off`, i.e. it protects simulation only, never silicon.
    """
    fails = []
    saw_err, err_class, reached_error = await _run_tens_gemm_fetch(dut, ELEM_FP8_E5M2)

    if not reached_error:
        fails.append("ctx0 did NOT reach CTX_ERROR (state=%d) — ELEM_FP8_E5M2 was "
                     "accepted; it would compute E4M3FN on E5M2 bits in silicon"
                     % int(dut.ctx0_state_o.value))
    if saw_err and err_class != ERR_INVALID_PARAM:
        fails.append("wrong err_class: got %s, expected ERR_INVALID_PARAM(%d)"
                     % (err_class, ERR_INVALID_PARAM))

    assert not fails, "C-1 red-sample (E5M2) failures:\n  " + "\n  ".join(fails)
    dut._log.info("C-1 RED#2: OP_TENS_GEMM(ELEM_FP8_E5M2) poisoned at fetch")


@cocotb.test()
async def test_cp_fetch_good_elem_fmt(dut):
    """GREEN: OP_TENS_GEMM with ELEM_MXFP4 must NOT be poisoned.

    This is the half that proves the gate is SELECTIVE rather than a blanket
    reject. MXFP4 is one of the block-scaled formats this chip exists to
    demonstrate — poisoning it would be a functional regression.
    """
    fails = []
    saw_err, err_class, reached_error = await _run_tens_gemm_fetch(dut, ELEM_MXFP4)

    if reached_error:
        fails.append("ctx0 reached CTX_ERROR for ELEM_MXFP4 — the C-1 gate is "
                     "over-rejecting a format the array CAN execute")
    if saw_err and err_class == ERR_INVALID_PARAM:
        fails.append("ERR_INVALID_PARAM raised for a whitelisted format (ELEM_MXFP4)")

    assert not fails, "C-1 green-sample failures:\n  " + "\n  ".join(fails)
    dut._log.info("C-1 GREEN: OP_TENS_GEMM(ELEM_MXFP4) accepted (gate is selective, "
                  "not a blanket reject)")


# =============================================================================
# [3a-7/P2 2026-08-05] word[5] 守卫（`wi==4` 单臂）+ (elem_fmt × N) 交叉表
#
# 规范唯一定义处 = 规格 Tensor_Unit_Sparse_Doubling_Spec.md §5.3.1（四要件表）与 §1.3.2（交叉表）。
# 预登记（发数前落盘）= aichip_run_logs/s3a7_prereg_20260805.md §2 —— 本组恰 5 发，闸2 分母 185→190。
# 裁决 = aichip_run_logs/s3a7_workface_adversarial_verdict_20260805.md（wi==4 归 3a-7，四对一）。
#
# 守卫的两检（合并成一条臂，同 OP 门 / 同不叠毒谓词 / 同 err_class）：
#   检 1  n_cfg == 2'b11 (NCFG_RESERVED)   —— 不在批准集 {4,2,1} 内，不拒则 ncfg_survivors() 返 N=3、
#                                             压实行数与相位全错、**硅上静默**
#   检 2  word[5][31:18] reserved-must-be-zero —— 独立偏移字段是绕过 region/OOB 的裸地址通路
#
# 🔴 五发必须成对成组（现役 C-1 体例逐字：「the red alone would also pass if the fetch engine
#    poisoned *everything*」）：1 红 + 2 绿 + 2 条 DMA_MEMSET 负控。
# 🔴 两条 MEMSET 负控是 **OP 门存在的唯一正证**：在飞 3 条 MEMSET 的 word[5][31:18] 实算全非零
#    （0xA5A51234 / 0xDEAD0001 / 0x600D600D），漏掉 OP 门会当场把它们全毒掉、闸2 立红；
#    而 [17:16] 侧在飞全是 2'b01（≠2'b11）⇒ n_cfg 那半检即使漏门也一发不红（零覆盖）。
# =============================================================================

NCFG_DENSE, NCFG_1OF4, NCFG_2OF4, NCFG_RESERVED = 0b00, 0b01, 0b10, 0b11


def _w5_tens(param_k=24, n_cfg=NCFG_DENSE, rsvd_hi=0):
    """组装 TENS 的 word[5]：[15:0] param_K · [17:16] n_cfg · [31:18] RESERVED。"""
    return (param_k & 0xFFFF) | ((n_cfg & 0x3) << 16) | ((rsvd_hi & 0x3FFF) << 18)


async def _run_word5_fetch(dut, opcode, word5, elem_fmt=0):
    """发一条 word[5]=word5 的描述符并观察 ctx0（与 _run_tens_gemm_fetch 同结构）。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.rw_gnt_i.value = 1

    # ext_len=4 ⇒ total_words=8 ⇒ 4 对 ⇒ pair_idx==2 (wi==4) 与 pair_idx==3 (wi==6) 都到达。
    await program_cp(dut, half_sel=0, len_rows=1, opcode=opcode,
                     ext_len=4, elem_fmt=elem_fmt, word5=word5)

    saw_err, err_class, reached_error = False, None, False
    for _ in range(200):
        await RisingEdge(dut.clk_i)
        if int(dut.cp_err_valid_o.value) == 1:
            saw_err = True
            err_class = int(dut.cp_err_class_o.value)
        if int(dut.ctx0_state_o.value) == CTX_ERROR:
            reached_error = True
            break
    return saw_err, err_class, reached_error


@cocotb.test()
async def wi4_ncfg_reserved_poisons(dut):
    """RED：OP_TENS_GEMM + word[5][17:16]=2'b11 (NCFG_RESERVED) 必须被毒。

    这是 `wi==4` 臂检 1 的红样本。不拒的后果已在规格 §5.2 登记：
    `ncfg_survivors()` 返 N=3 ⇒ 压实行数与相位全错 ⇒ **硅上静默**。
    """
    fails = []
    saw_err, err_class, reached_error = await _run_word5_fetch(
        dut, OP_TENS_GEMM, _w5_tens(n_cfg=NCFG_RESERVED))
    if not reached_error:
        fails.append("ctx0 未进 CTX_ERROR (state=%d) —— n_cfg=2'b11 被接受，wi==4 臂没生效"
                     % int(dut.ctx0_state_o.value))
    if not saw_err:
        fails.append("n_cfg=2'b11 的描述符没有 CP error 脉冲")
    elif err_class != ERR_INVALID_PARAM:
        fails.append("err_class 错：got %s, 期望 ERR_INVALID_PARAM(%d)" % (err_class, ERR_INVALID_PARAM))
    assert not fails, "[3a-7/P2] wi==4 检1 红样本失败:\n  " + "\n  ".join(fails)
    dut._log.info("[3a-7/P2] RED: OP_TENS_GEMM(n_cfg=RESERVED) 在 fetch 被毒成 "
                  "ERR_INVALID_PARAM -> ctx0 CTX_ERROR（wi==4 臂检1 已生效）")


@cocotb.test()
async def wi4_ncfg_2of4_not_poisoned(dut):
    """GREEN：OP_TENS_GEMM + n_cfg=2'b10 (NCFG_2OF4) 必须**不**被毒。

    证明检 1 是**选择性**的而不是「非 dense 一律拒」——
    2:4 是批准集 {4,2,1} 里的合法档（规格 §5.1a 编码表）。
    """
    fails = []
    saw_err, err_class, reached_error = await _run_word5_fetch(
        dut, OP_TENS_GEMM, _w5_tens(n_cfg=NCFG_2OF4))
    if reached_error:
        fails.append("ctx0 进了 CTX_ERROR —— 合法的 n_cfg=2'b10 被误毒（检1 写宽了）")
    if saw_err and err_class == ERR_INVALID_PARAM:
        fails.append("对合法 n_cfg=2'b10 抛了 ERR_INVALID_PARAM")
    assert not fails, "[3a-7/P2] wi==4 检1 绿样本失败:\n  " + "\n  ".join(fails)
    dut._log.info("[3a-7/P2] GREEN: OP_TENS_GEMM(n_cfg=2OF4) 未被毒（检1 是选择性的）")


@cocotb.test()
async def wi6_bf16_x_ncfg2of4_not_poisoned(dut):
    """GREEN：(elem_fmt=ELEM_BF16 × n_cfg=NCFG_2OF4) 是交叉表里的合法格，必须**不**被毒。

    交叉表判据（规格 §1.3.1）：`N∈{1,2}` 合法 ⇔ `dense_pack_advance(mode)==1`。
    BF16 → MODE_BF16 → pack_advance=1 ⇒ 全档合法。
    🔴 本发同时守住「交叉表没把现役 C-1 白名单改坏」：BF16 是全仓每一发的默认格式。
    """
    fails = []
    saw_err, err_class, reached_error = await _run_word5_fetch(
        dut, OP_TENS_GEMM, _w5_tens(n_cfg=NCFG_2OF4), elem_fmt=ELEM_BF16)
    if reached_error:
        fails.append("ctx0 进了 CTX_ERROR —— (BF16 × 2:4) 是合法格却被毒，交叉表写宽了")
    if saw_err and err_class == ERR_INVALID_PARAM:
        fails.append("对合法格 (BF16 × 2:4) 抛了 ERR_INVALID_PARAM")
    assert not fails, "[3a-7/P2] wi==6 交叉表绿样本失败:\n  " + "\n  ".join(fails)
    dut._log.info("[3a-7/P2] GREEN: (ELEM_BF16 × NCFG_2OF4) 未被毒（交叉表合法格）")


@cocotb.test()
async def memset_ncfg_bits_not_poisoned(dut):
    """负控 1（OP 门）：DMA_MEMSET + memset_val 的 [17:16]=2'b11 必须**不**被毒。

    🔴 word[5] 对 DMA_MEMSET 是 **memset_val 数据**，不是 n_cfg。
    没有 OP 门 ⇒ 这一发会被检 1 误毒。
    """
    fails = []
    saw_err, err_class, reached_error = await _run_word5_fetch(
        dut, OP_DMA_MEMSET, 0x0003_0000)          # [17:16]=2'b11，其余全 0
    if reached_error:
        fails.append("ctx0 进了 CTX_ERROR —— DMA_MEMSET 的 memset_val 被当成 n_cfg 误毒（OP 门缺失）")
    if saw_err and err_class == ERR_INVALID_PARAM:
        fails.append("对 DMA_MEMSET 抛了 ERR_INVALID_PARAM（OP 门缺失）")
    assert not fails, "[3a-7/P2] OP 门负控1 失败:\n  " + "\n  ".join(fails)
    dut._log.info("[3a-7/P2] NEG-1: DMA_MEMSET(memset_val=0x00030000) 未被毒（OP 门在）")


@cocotb.test()
async def memset_reserved_high_not_poisoned(dut):
    """负控 2（OP 门）：DMA_MEMSET + memset_val 的 [31:18] 非零必须**不**被毒。

    🔴 取值 0xA5A5_1234 = 在飞用例 `test_pe_top.py` 的 PATTERN 逐字同值
    （其 [31:18]=0x2969 非零）⇒ **本发直接代表在飞回归会不会被检 2 打掉**。
    没有 OP 门 ⇒ 在飞 3 条 MEMSET 会当场全红。
    """
    fails = []
    saw_err, err_class, reached_error = await _run_word5_fetch(
        dut, OP_DMA_MEMSET, 0xA5A5_1234)
    if reached_error:
        fails.append("ctx0 进了 CTX_ERROR —— DMA_MEMSET 的 memset_val 高位被当成 RESERVED 误毒")
    if saw_err and err_class == ERR_INVALID_PARAM:
        fails.append("对 DMA_MEMSET(0xA5A51234) 抛了 ERR_INVALID_PARAM（OP 门缺失）")
    assert not fails, "[3a-7/P2] OP 门负控2 失败:\n  " + "\n  ".join(fails)
    dut._log.info("[3a-7/P2] NEG-2: DMA_MEMSET(memset_val=0xA5A51234，在飞 PATTERN 同值) "
                  "未被毒（OP 门在）")

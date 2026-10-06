"""
cocotb test (STEP4-E2E §11.4, D-E2E-BENCH SRC1 producer): hardware resident-L2
SRC1 for RESADD. No tb-injected SRC1 — the Vector reads the residual from L2
itself (activated vec_ingress_arb Source A), tags it OP_SRC1, and adds it to the
fast-path SRC0. DUT = vector_unit_top + REAL l2_subsystem.

Flow: preload the residual (16 lanes) in L2 at src1_row in the half_sel-selected
half (dma_fill); issue vec_cmd(RESADD, src1_resident=1, half_sel); inject SRC0 on
t2v; the resident reader fetches SRC1 in VST_WAIT_OP1; RESADD writes L2 bit-exact
vs resadd_fastpath_golden(SRC0, residual). Residual block scale = E4M3 exp0
identity (the §11.4 first-cut convention; mant_corr=128).

Run: cd tb && make MODULE=test_vec_resadd_resident_e2e TOPLEVEL=tb_vec_resadd_resident_e2e \
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
        ../tb/tb_vec_resadd_resident_e2e.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

E4M3_EXP7 = 7 << 3   # 0x38 -> exp_adj 0, mant_corr 128
# [C5 2026-07-24] 0x3B -> exp bits [6:3]=7 (exp_adj 0, SAME as 0x38) but mant
# bits [2:0]=3 -> mant_corr = {1'b1,3'b011,4'b0} = 176 = 1.375x (vec_scale_adapter.sv:112).
# Only the CORRECTION differs from E4M3_EXP7, so a failure is attributable to the
# mant_corr path alone.
E4M3_EXP7_M3 = (7 << 3) | 3
MANT_CORR_M3 = 176
VST_DONE = 5
SRC1_ROW = 0x020
DST_ROW = 0x041


def pack(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= (m & 0xFFFF) << (i * 16)
    return v


async def reset(dut):
    for s in ("cmd_valid_i", "half_sel_i", "block_log2_i", "dst_row_i", "src1_row_i", "resident_i",
              "src1_scale_ref_i",
              "cap_valid_i", "cap_payload_i", "cap_inline_scale_i",
              "dma_fill_req_i", "dma_fill_bank_i", "dma_fill_row_i", "dma_fill_wdata_i"):
        getattr(dut, s).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


async def dma_fill(dut, bank, row, wdata):
    dut.dma_fill_bank_i.value = bank
    dut.dma_fill_row_i.value = row
    dut.dma_fill_wdata_i.value = wdata
    dut.dma_fill_req_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.dma_fill_req_i.value = 0
    await RisingEdge(dut.clk_i)


async def preload_residual(dut, half_sel, row, mants):
    base = 8 if half_sel else 0
    for j in range(8):       # half = banks base..base+7, lanes packed 2x16b per 32b bank
        word = (mants[2 * j] & 0xFFFF) | ((mants[2 * j + 1] & 0xFFFF) << 16)
        await dma_fill(dut, base + j, row, word)


@cocotb.test()
async def test_resadd_resident_src1(dut):
    """RESADD with hardware resident-L2 SRC1 -> L2 write bit-exact vs golden."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    HALF = 0

    src0_mants = [100 + 10 * i for i in range(16)]   # SRC0 (fast path)
    res_mants = [40 + 6 * i for i in range(16)]      # SRC1 residual (resident in L2)

    # 1) preload the residual in L2 at SRC1_ROW (low half for HALF=0)
    await preload_residual(dut, HALF, SRC1_ROW, res_mants)

    # 2) issue RESADD with resident SRC1
    dut.half_sel_i.value = HALF
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.resident_i.value = 1
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    # 3) inject ONLY SRC0 on the fast path (block16/E4M3); SRC1 comes from L2
    dut.cap_payload_i.value = pack(src0_mants)
    dut.cap_inline_scale_i.value = E4M3_EXP7
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("SRC0 capsule MISS reason=%d" % int(dut.miss_reason_o.value))
            break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True
            break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("SRC0 capsule never accepted")

    # golden: SRC0 + residual, both E4M3 exp0 / mant_corr 128 (precise identity)
    gold = g.resadd_fastpath_golden(src0_mants, 0, res_mants, 0,
                                    mant_corr0=128, mant_corr1=128, precise=True)
    exp_wdata = pack(gold["aligned"])

    # 4) capture the RESADD L2 write-back + completion
    rw_w, rw_row, done, done_state, saw_err = None, None, False, -1, False
    if not fails:
        for _ in range(300):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_w = int(dut.rw_wdata_o.value)
                rw_row = int(dut.rw_row_o.value)
            if int(dut.done_o.value) == 1:
                done = True
                done_state = int(dut.vu_state_o.value)
                break
        if rw_w is None:
            fails.append("no RESADD L2 write observed (resident SRC1 may not have completed)")
        elif rw_w != exp_wdata:
            for i in range(16):
                gw = (rw_w >> (i * 16)) & 0xFFFF
                ew = (exp_wdata >> (i * 16)) & 0xFFFF
                if gw != ew:
                    fails.append("RESADD L2 lane %d: rtl=0x%04x gold=0x%04x" % (i, gw, ew))
                    break
        if rw_row is not None and rw_row != DST_ROW:
            fails.append("rw_row=0x%x != dst 0x%x" % (rw_row, DST_ROW))
        if not done:
            fails.append("RESADD done never pulsed")
        elif done_state != VST_DONE:
            fails.append("completion via VST_ERROR (state=%d)" % done_state)
        if saw_err:
            fails.append("vector error during resident RESADD")

    assert not fails, "resident-SRC1 RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("SRC1 producer (§11.4): RESADD read its SRC1 residual from L2 (resident reader, no tb "
                  "injection) + SRC0 from the fast path; L2 write-back bit-exact vs golden")


@cocotb.test()
async def test_resadd_resident_mant_corr_nonidentity(dut):
    """[C5 COVERAGE GAP] The FIRST vector_unit-level byte-exact guard for a
    NON-identity E4M3 mant_corr.

    WHY it did not exist: every pre-C5 vector_unit-level RESADD test injects the
    inline-scale byte 0x38 (or the abs-exp path), i.e. mant_corr == 128 — an EXACT
    identity — so the D10 precise-mode correction (mant_corr multiply + renorm17 +
    sign refresh) was only ever guarded at the vec_lane_array MODULE level
    (test_lane_resadd_precise / test_lane_renorm_precise). Deleting the whole
    correction from the vector_unit datapath left the full 140/50 suite GREEN.

    WHY C5 needs it: C5 moves that correction OUT of vec_lane_array and in front
    of it (vec_lane_prep instances in vector_unit, registered in PH_MC), so the
    deployed correction is now a vector_unit-level wiring — exactly the thing the
    module-level tests stopped covering. This test is its teeth.

    Reachability (the same filter §C4 used for reduce): e4m3_precise_lane=1 ⟺
    opcode ∈ {OP_VEC_RESADD, OP_VEC_RESADD_RESIDENT} ∧ block_size_log2 == BS_16
    (vec_cmd_to_desc.sv:117-119/150-151, vec_desc_decode.sv:217-224) — the NVFP4
    default, not a corner case.

    ASYMMETRIC on purpose: SRC0 (fast path, byte 0x3B) gets mant_corr 176 while
    the resident SRC1 (absolute-exp path) keeps 128 — so an s0/s1 swap in the
    prep wiring is caught too. Oracle = the SAME resadd_fastpath_golden already
    used by the sibling tests, just called with the correction ON; no new golden
    math (bfp_golden.py stays byte-identical)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    HALF = 0

    # Operands chosen so the 1.375x correction actually moves bits (odd values ->
    # non-trivial RNE rounding in the 17-bit corrected domain) and mixes signs.
    src0_mants = [(101 + 37 * i) * (-1 if i % 3 == 0 else 1) for i in range(16)]
    res_mants = [(43 + 29 * i) * (-1 if i % 4 == 1 else 1) for i in range(16)]

    await preload_residual(dut, HALF, SRC1_ROW, res_mants)

    dut.half_sel_i.value = HALF
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.resident_i.value = 1
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    dut.cap_payload_i.value = pack(src0_mants)
    dut.cap_inline_scale_i.value = E4M3_EXP7_M3      # <- the ONLY delta vs the sibling test
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("SRC0 capsule MISS reason=%d" % int(dut.miss_reason_o.value))
            break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True
            break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("SRC0 capsule never accepted")

    # golden: SRC0 corrected by 176/128 = 1.375, residual identity (abs-exp path)
    gold = g.resadd_fastpath_golden(src0_mants, 0, res_mants, 0,
                                    mant_corr0=MANT_CORR_M3, mant_corr1=128,
                                    precise=True)
    exp_wdata = pack(gold["aligned"])

    # Negative control: the identity-correction expectation MUST differ, else the
    # stimulus cannot tell "correction applied" from "correction skipped".
    gold_ident = g.resadd_fastpath_golden(src0_mants, 0, res_mants, 0,
                                          mant_corr0=128, mant_corr1=128, precise=True)
    if pack(gold_ident["aligned"]) == exp_wdata:
        fails.append("stimulus is blind: mant_corr=176 golden == mant_corr=128 golden")

    rw_w, rw_row, done, saw_err = None, None, False, False
    if not fails:
        for _ in range(300):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_w = int(dut.rw_wdata_o.value)
                rw_row = int(dut.rw_row_o.value)
            if int(dut.done_o.value) == 1:
                done = True
                break
        if rw_w is None:
            fails.append("no RESADD L2 write observed")
        elif rw_w != exp_wdata:
            for i in range(16):
                gw = (rw_w >> (i * 16)) & 0xFFFF
                ew = (exp_wdata >> (i * 16)) & 0xFFFF
                if gw != ew:
                    iw = (pack(gold_ident["aligned"]) >> (i * 16)) & 0xFFFF
                    fails.append("mant_corr=176 RESADD lane %d: rtl=0x%04x gold=0x%04x "
                                 "(identity-golden would be 0x%04x)" % (i, gw, ew, iw))
                    break
        if rw_row is not None and rw_row != DST_ROW:
            fails.append("rw_row=0x%x != dst 0x%x" % (rw_row, DST_ROW))
        if not done:
            fails.append("RESADD done never pulsed")
        if saw_err:
            fails.append("vector error during mant_corr RESADD")

    assert not fails, "non-identity mant_corr RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("[C5] deployed-path E4M3 mant_corr=176 RESADD byte-exact vs golden "
                  "(first vector_unit-level guard for the D10 correction)")


@cocotb.test()
async def test_resadd_resident_nonzero_scale(dut):
    """HW-REVIEW TIER-3 (RED-C): a resident residual at a NON-exp0 block scale.

    The old RTL hardcoded the resident SRC1 to inline_scale=0x38 (exp0), silently
    forcing EVERY residual to ref-exp 0 -> a residual at any other scale misaligned
    by powers of two. With the per-residual scale (software-provided src1_scale_ref
    threaded to resident_cap.scale_ref via the absolute-scale path), the residual
    aligns by its TRUE exponent. Here SRC0 is exp0 and the residual is at e1=-2;
    pre-fix the residual would be added unshifted (4x too heavy) -> wrong; post-fix
    it is aligned by 2. Bit-exact vs resadd_fastpath_golden(src0, 0, res, -2)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    HALF, E1 = 0, -2

    src0_mants = [100 + 10 * i for i in range(16)]
    res_mants = [40 + 6 * i for i in range(16)]

    await preload_residual(dut, HALF, SRC1_ROW, res_mants)

    dut.half_sel_i.value = HALF
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.resident_i.value = 1
    dut.src1_scale_ref_i.value = E1 & 0xFFFF        # [T3] residual absolute exp = -2
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    dut.cap_payload_i.value = pack(src0_mants)
    dut.cap_inline_scale_i.value = E4M3_EXP7        # SRC0 at exp0 (legacy byte path)
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("SRC0 capsule MISS reason=%d" % int(dut.miss_reason_o.value)); break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True; break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("SRC0 capsule never accepted")

    # golden: SRC0 at exp0, residual at e1=-2 (per-residual scale APPLIED)
    gold = g.resadd_fastpath_golden(src0_mants, 0, res_mants, E1,
                                    mant_corr0=128, mant_corr1=128, precise=True)
    exp_wdata = pack(gold["aligned"])

    rw_w, rw_sr, rw_isc, done, saw_err = None, None, None, False, False
    if not fails:
        for _ in range(300):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_w = int(dut.rw_wdata_o.value)
                rw_sr = g.signed(int(dut.result_scale_ref_o.value), 16)   # [T3] W1 teeth
                rw_isc = int(dut.result_inline_scale_o.value)
            if int(dut.done_o.value) == 1:
                done = True; break
        # [HW-REVIEW T3] writeback symmetry (W1): the RESADD result capsule must carry the
        # RESULT's absolute block exponent (= golden shared_exp) + inline_scale[8]=1, so a
        # chained RESADD aligns correctly one hop later (not re-clamped to the E4M3 byte).
        if rw_sr is not None and rw_sr != gold["shared_exp"]:
            fails.append("result scale_ref=%d != golden shared_exp=%d (W1 writeback re-clamp)"
                         % (rw_sr, gold["shared_exp"]))
        if rw_isc is not None and not ((rw_isc >> 8) & 1):
            fails.append("result inline_scale[8] (ABS_EXP_PRESENT) not set (0x%x) — chained "
                         "RESADD would read the clamped byte" % rw_isc)
        if rw_w is None:
            fails.append("no RESADD L2 write observed")
        elif rw_w != exp_wdata:
            for i in range(16):
                gw = (rw_w >> (i * 16)) & 0xFFFF
                ew = (exp_wdata >> (i * 16)) & 0xFFFF
                if gw != ew:
                    fails.append("RESADD lane %d: rtl=0x%04x gold=0x%04x (e1=%d applied; old bug "
                                 "forces residual to exp0 -> 4x too heavy)" % (i, gw, ew, E1))
                    break
        if not done:
            fails.append("RESADD done never pulsed")
        if saw_err:
            fails.append("vector error during non-exp0 resident RESADD")

    assert not fails, "resident non-exp0 residual scale failures:\n  " + "\n  ".join(fails)
    dut._log.info("TIER-3 RED-C: resident residual at e1=-2 aligned by its per-residual scale "
                  "(software src1_scale_ref), L2 write-back bit-exact vs golden")


@cocotb.test()
async def test_resadd_resident_src0_shifted_sticky(dut):
    """[LANE2 preflight mandatory #10, GK-4 降级替代] side=0 腿的非零移位 + sticky
    低位丢失激励：SRC0 块 exp = -2 (E4M3 byte 5<<3) < residual exp = 0 →
    vec_lane_shift_ctrl diff = e0-e1 = -2 < 0 → shift_src1_side=0 → SRC0 走
    shifter (aligned_a = shift_out + sticky 注入)，移位量 2 非零。奇数 mant 保证
    被移出的低 2 位携带信息 (sticky 必置)。

    WHY: 既有 e2e 谱系里 side=0 腿只有零移位直通用例 (第一类激励 exp_diff=0)；
    side=1 非零移位有 nonzero_scale (e1=-2)。本例补齐 side=0 非零移位 + sticky
    注入 aligned_a 的部署可达腿——PH_LANE2 拆缝手术中该腿的缝搬运错误
    (sticky 丢失/腿序错) 由本例咬。先于手术在现 RTL 跑绿入基线 (绿基线纪律)。

    Blindness control: 同 oracle 对 "低 2 位清零的 SRC0" 计算的 golden 必须与
    主 golden 分歧——否则激励对低位丢失盲，不许挂名。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    HALF, E0 = 0, -2
    E4M3_EXP5 = 5 << 3   # exp_adj = 5-7 = -2, mant bits 0 -> mant_corr 128 identity

    # 奇数低位 + 混号: 移位 2 丢的低位非零 (sticky 必置), tz 修正在负 lane 上激活
    src0_mants = [(101 + 37 * i) * (-1 if i % 3 == 0 else 1) for i in range(16)]
    res_mants = [(40 + 6 * i) for i in range(16)]

    await preload_residual(dut, HALF, SRC1_ROW, res_mants)

    dut.half_sel_i.value = HALF
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.resident_i.value = 1
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    dut.cap_payload_i.value = pack(src0_mants)
    dut.cap_inline_scale_i.value = E4M3_EXP5        # SRC0 at exp -2 (byte path)
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("SRC0 capsule MISS reason=%d" % int(dut.miss_reason_o.value)); break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True; break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("SRC0 capsule never accepted")

    # golden: SRC0 at e0=-2, residual at exp0 -> side=0, SRC0 shifted by 2
    gold = g.resadd_fastpath_golden(src0_mants, E0, res_mants, 0,
                                    mant_corr0=128, mant_corr1=128, precise=True)
    exp_wdata = pack(gold["aligned"])

    # Blindness control: clearing the (about-to-be-shifted-out) low 2 bits of SRC0
    # must change the golden, else this stimulus cannot see sticky/low-bit loss.
    gold_blind = g.resadd_fastpath_golden([m & ~3 for m in src0_mants], E0, res_mants, 0,
                                          mant_corr0=128, mant_corr1=128, precise=True)
    if pack(gold_blind["aligned"]) == exp_wdata:
        fails.append("stimulus is blind: low-2-bit-cleared golden == main golden")

    rw_w, rw_row, done, saw_err = None, None, False, False
    if not fails:
        for _ in range(300):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_w = int(dut.rw_wdata_o.value)
                rw_row = int(dut.rw_row_o.value)
            if int(dut.done_o.value) == 1:
                done = True; break
        if rw_w is None:
            fails.append("no RESADD L2 write observed")
        elif rw_w != exp_wdata:
            for i in range(16):
                gw = (rw_w >> (i * 16)) & 0xFFFF
                ew = (exp_wdata >> (i * 16)) & 0xFFFF
                if gw != ew:
                    fails.append("side0-shift RESADD lane %d: rtl=0x%04x gold=0x%04x "
                                 "(e0=%d, SRC0 shifted+sticky leg)" % (i, gw, ew, E0))
                    break
        if rw_row is not None and rw_row != DST_ROW:
            fails.append("rw_row=0x%x != dst 0x%x" % (rw_row, DST_ROW))
        if not done:
            fails.append("RESADD done never pulsed")
        if saw_err:
            fails.append("vector error during side0-shift RESADD")

    assert not fails, "side0 shifted+sticky RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("[LANE2 #10] side=0 nonzero-shift + sticky leg byte-exact vs golden "
                  "(SRC0 e0=-2 shifted by 2, low-bit info carried via sticky)")


BS_32 = 1


@cocotb.test()
async def test_resadd_resident_block32_e8m0(dut):
    """[HW-REVIEW T3-FF/FF2] block32 (E8M0) resident RESADD: the 2-capsule resident
    reader reads TWO 256b residual windows (src1_row, src1_row+1); the E8M0 abs-scale
    path aligns each by the shared src1_scale_ref; the dual-window result is written
    back to TWO L2 rows (dst, dst+1) bit-exact vs resadd_block32_golden. INVERTS the
    old block32-rejected guard. RED pre-fix: resident_unsupported rejects block32 ->
    VST_ERROR, no writes (and the E8M0 abs path would byte-decode 0x38 -> exp -71)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    HALF, E1 = 0, -3                                    # shared residual absolute exp
    E8M0_EXP0 = 127                                     # E8M0 byte for exp0 (SRC0 legacy byte)

    # block32 = 2 windows of 16 lanes each (distinct payloads so a window-1 alias shows)
    src0_w0 = [100 + 7 * i for i in range(16)]
    src0_w1 = [60 + 9 * i for i in range(16)]
    res_w0  = [40 + 6 * i for i in range(16)]
    res_w1  = [33 + 5 * i for i in range(16)]

    # residual: window0 @ SRC1_ROW, window1 @ SRC1_ROW+1 (consecutive rows, same half)
    await preload_residual(dut, HALF, SRC1_ROW, res_w0)
    await preload_residual(dut, HALF, SRC1_ROW + 1, res_w1)

    dut.half_sel_i.value = HALF
    dut.block_log2_i.value = BS_32                      # -> block32 / E8M0
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.resident_i.value = 1
    dut.src1_scale_ref_i.value = E1 & 0xFFFF           # shared residual abs exp (E8M0 abs path)
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    # inject 2 SRC0 capsules (block32/E8M0, byte 127 = exp0 via the legacy byte path)
    for win_payload in (src0_w0, src0_w1):
        dut.cap_payload_i.value = pack(win_payload)
        dut.cap_inline_scale_i.value = E8M0_EXP0
        dut.cap_valid_i.value = 1
        accepted = False
        for _ in range(60):
            await RisingEdge(dut.clk_i)
            if int(dut.miss_valid_o.value) == 1:
                fails.append("SRC0 capsule MISS reason=%d" % int(dut.miss_reason_o.value)); break
            if int(dut.cap_ready_o.value) == 1:
                accepted = True; break
        dut.cap_valid_i.value = 0
        await FallingEdge(dut.clk_i)
        if not accepted and not fails:
            fails.append("SRC0 capsule never accepted"); break

    # golden: per-window RESADD; SRC0 at exp0 (E8M0 byte), residual at shared E1 (abs)
    g0, g1 = g.resadd_block32_golden(src0_w0, src0_w1, 0, 0, res_w0, res_w1, E1, E1,
                                     mant_corr0=128, mant_corr1=128, precise=False)
    exp_w0, exp_w1 = pack(g0["aligned"]), pack(g1["aligned"])

    # capture TWO L2 writebacks (window0 @ DST_ROW, window1 @ DST_ROW+1)
    writes = {}
    done, done_state, saw_err = False, -1, False
    if not fails:
        for _ in range(400):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if int(dut.rw_req_o.value) == 1:
                writes[int(dut.rw_row_o.value)] = int(dut.rw_wdata_o.value)
            if int(dut.done_o.value) == 1:
                done = True; done_state = int(dut.vu_state_o.value); break
        for row, exp_w, wl in ((DST_ROW, exp_w0, "w0"), (DST_ROW + 1, exp_w1, "w1")):
            if row not in writes:
                fails.append("no L2 write for %s @ row 0x%x" % (wl, row)); continue
            if writes[row] == 0:
                fails.append("%s L2 write all-zero (residual annihilated? E8M0 abs path)" % wl)
            if writes[row] != exp_w:
                for i in range(16):
                    gw = (writes[row] >> (i * 16)) & 0xFFFF
                    ew = (exp_w >> (i * 16)) & 0xFFFF
                    if gw != ew:
                        fails.append("block32 %s lane %d: rtl=0x%04x gold=0x%04x" % (wl, i, gw, ew))
                        break
        if not done:
            fails.append("block32 RESADD done never pulsed")
        elif done_state != VST_DONE:
            fails.append("completion via VST_ERROR (state=%d)" % done_state)
        if saw_err:
            fails.append("vector error during block32 resident RESADD")

    assert not fails, "block32 E8M0 resident RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("FF2: block32/E8M0 resident RESADD — 2-capsule reader (rows 0x%x,0x%x), E8M0 abs "
                  "scale e1=%d, dual-window L2 write-back (rows 0x%x,0x%x) bit-exact vs golden"
                  % (SRC1_ROW, SRC1_ROW + 1, E1, DST_ROW, DST_ROW + 1))


@cocotb.test()
async def test_resadd_resident_unsupported_combo(dut):
    """[HW-REVIEW T3-FF/FF2] guard teeth: a resident RESADD whose (block_size,
    scale_format) is NOT one of the two supported pairs {block16+E4M3, block32+E8M0}
    must FAIL LOUD (VST_ERROR), not deadlock or silently mis-scale. A reserved
    block_log2 (2) maps via vec_cmd_to_desc to (block16, E8M0) -> not whitelisted."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    dut.block_log2_i.value = 2          # reserved -> (block16, E8M0): unsupported for resident
    dut.resident_i.value = 1
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0

    reached_error, saw_rw = False, False
    for _ in range(60):                 # bounded: a deadlock would NOT reach error
        await FallingEdge(dut.clk_i)
        if int(dut.vu_state_o.value) == 6:  # VST_ERROR
            reached_error = True
        if int(dut.rw_req_o.value) == 1:
            saw_rw = True
        if reached_error:
            break

    fails = []
    if not reached_error:
        fails.append("unsupported (block16,E8M0) resident did NOT reach VST_ERROR (deadlock risk)")
    if saw_rw:
        fails.append("unsupported resident RESADD wrote L2 (should error before any write)")
    assert not fails, "resident guard negative-control failures:\n  " + "\n  ".join(fails)
    dut._log.info("FF2 guard teeth: an unsupported (block16,E8M0) resident config rejected to "
                  "VST_ERROR (no deadlock, no write); the whitelist stays exact-match")


@cocotb.test()
async def test_resadd_resident_corr_align_cross(dut):
    """[C9 V3-2 guard, 2026-07-25] mant_corr != 128  ×  exp_diff != 0 — the
    combination NO test covered (the corr=176 sibling runs both scales at exp 0
    -> zero alignment; the nonzero-scale test runs corr=128).

    WHY it matters for C9: the renorm17 exp-bump (vec_lane_prep: corrected
    mantissa overflows 16 bits -> mant>>1, exp+1) CHANGES the per-lane alignment
    amount when the block exponents differ. C-minimal moves the abs_diff /
    shift_src1_side computation into PH_MC on speculatively-bumped exponents —
    if the ±1 speculation or its late-select is wrong, exactly this cross path
    breaks while all existing tests stay green.

    Stimulus: SRC0 byte 0x43 = exp bits 8 (exp_adj +1) + corr bits 3 (176 =
    1.375x); residual at abs exp 0. Lanes MIX magnitudes so SOME lanes bump
    (|m|*1.375 >= 2^15: per-lane exp_diff becomes +2) and some do not (+1) —
    the alignment amount now depends on the bump, which is the blind spot.

    RED protocol: mutate vec_lane_prep (drop the `es_o.exp = exp+1` bump line)
    -> bumped lanes align 1 short -> this test FAILS (existing suite: the
    corr=176 sibling has exp_diff=0 so its alignment is bump-invariant... but
    renorm_block re-normalizes per-lane exps, so the sibling MAY also redden —
    the red requirement is only that THIS test reddens).
    Oracle: the SAME resadd_fastpath_golden, called with e0=+1."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    HALF = 0
    SCALE_BYTE_E1_M3 = (8 << 3) | 3      # exp_adj +1, mant_corr 176

    # bump lanes: |m|*176 >= 32768*128  <=>  |m| >= 23832 ; no-bump: small odds
    src0_mants = [24001, -24007, 30001, -30011,
                  101, -137, 203, -251,
                  23833, -23911, 24555, -25007,
                  313, -419, 523, -601]
    res_mants = [(43 + 29 * i) * (-1 if i % 4 == 1 else 1) for i in range(16)]

    n_bump = sum(1 for m in src0_mants if abs(m) * 176 >= 32768 * 128)
    assert 0 < n_bump < 16, "stimulus must mix bump and no-bump lanes (got %d/16)" % n_bump

    await preload_residual(dut, HALF, SRC1_ROW, res_mants)

    dut.half_sel_i.value = HALF
    dut.dst_row_i.value = DST_ROW
    dut.src1_row_i.value = SRC1_ROW
    dut.resident_i.value = 1
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)

    dut.cap_payload_i.value = pack(src0_mants)
    dut.cap_inline_scale_i.value = SCALE_BYTE_E1_M3
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("SRC0 capsule MISS reason=%d" % int(dut.miss_reason_o.value))
            break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True
            break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("SRC0 capsule never accepted")

    # golden: SRC0 at exp_adj +1 corrected 1.375x, residual identity at exp 0
    gold = g.resadd_fastpath_golden(src0_mants, 1, res_mants, 0,
                                    mant_corr0=176, mant_corr1=128, precise=True)
    exp_wdata = pack(gold["aligned"])

    # Negative control 1: alignment must matter (e0=+1 golden != e0=0 golden)
    gold_e0z = g.resadd_fastpath_golden(src0_mants, 0, res_mants, 0,
                                        mant_corr0=176, mant_corr1=128, precise=True)
    if pack(gold_e0z["aligned"]) == exp_wdata and gold_e0z["shared_exp"] == gold["shared_exp"]:
        fails.append("stimulus blind to alignment: e0=+1 golden == e0=0 golden")
    # Negative control 2: the correction must matter under alignment
    gold_ident = g.resadd_fastpath_golden(src0_mants, 1, res_mants, 0,
                                          mant_corr0=128, mant_corr1=128, precise=True)
    if pack(gold_ident["aligned"]) == exp_wdata:
        fails.append("stimulus blind to corr: corr=176 golden == corr=128 golden (e0=+1)")

    rw_w, rw_row, done, saw_err = None, None, False, False
    if not fails:
        for _ in range(300):
            await FallingEdge(dut.clk_i)
            if int(dut.err_o.value):
                saw_err = True
            if rw_w is None and int(dut.rw_req_o.value) == 1:
                rw_w = int(dut.rw_wdata_o.value)
                rw_row = int(dut.rw_row_o.value)
            if int(dut.done_o.value) == 1:
                done = True
                break
        if rw_w is None:
            fails.append("no RESADD L2 write observed")
        elif rw_w != exp_wdata:
            for i in range(16):
                gw = (rw_w >> (i * 16)) & 0xFFFF
                ew = (exp_wdata >> (i * 16)) & 0xFFFF
                if gw != ew:
                    bumped = abs(src0_mants[i]) * 176 >= 32768 * 128
                    fails.append("corr×align lane %d (%s): rtl=0x%04x gold=0x%04x"
                                 % (i, "BUMPED" if bumped else "no-bump", gw, ew))
                    break
        if rw_row is not None and rw_row != DST_ROW:
            fails.append("rw_row=0x%x != dst 0x%x" % (rw_row, DST_ROW))
        if not done:
            fails.append("RESADD done never pulsed")
        if saw_err:
            fails.append("vector error during corr×align RESADD")

    assert not fails, "corr×align cross failures:\n  " + "\n  ".join(fails)
    dut._log.info("[C9 V3-2] corr=176 × exp_diff!=0 RESADD byte-exact vs golden "
                  "(%d/16 lanes exercised the renorm17 bump on an aligned add)" % n_bump)

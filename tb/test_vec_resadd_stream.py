"""
cocotb test (HW-REVIEW T3-FF / FF3b-c): MULTI-BLOCK STREAMING resident RESADD.

One streaming RESADD over a residual spanning N blocks, each block carrying its OWN
absolute block exponent read from an L2 scale-sidecar (16 signed-16b exps per 256b row,
pe_pkg::sidecar_scale_k). SRC0 streams as N ordered fast-path capsules (decision B); the
residual stays resident in L2. The Vector VST FSM loops the N blocks via VST_BLK_NEXT /
VST_BLK_SETUP, writing block k to dst_ref+k. Oracle = resadd_stream_golden (per-block
resadd_fastpath_golden with EXPLICIT distinct per-block e1[k] — the honesty rule: a single
shared residual scale would silently re-admit the power-of-two misalign on blocks k>=1).

RUNG 3 = N=2 micro-step (smallest integration RED). RUNG 4 = full N>=3 FF3d e2e.

DUT = vector_unit_top + REAL l2_subsystem (shared TOPLEVEL tb_vec_resadd_resident_e2e).

Run: cd tb && make MODULE=test_vec_resadd_stream TOPLEVEL=tb_vec_resadd_resident_e2e \
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

E4M3_EXP0 = 7 << 3   # 0x38 -> E4M3 byte, exp_adj 0, mant_corr 128 (SRC0 at exp0)
VST_DONE, VST_ERROR = 5, 6
VERR_OPERAND_TIMEOUT, VERR_ROLE_MISORDER = 12, 10
BS_16 = 0

SIDECAR_ROW = 0x008      # scale-sidecar base (same half as residual)
SRC1_BASE   = 0x020      # residual block k -> row SRC1_BASE + k
DST_BASE    = 0x060      # writeback block k -> row DST_BASE + k


def pack(mants):
    v = 0
    for i, m in enumerate(mants):
        v |= (m & 0xFFFF) << (i * 16)
    return v


async def reset(dut):
    for s in ("cmd_valid_i", "half_sel_i", "block_log2_i", "dst_row_i", "src1_row_i",
              "resident_i", "src1_scale_ref_i", "len_rows_i", "sidecar_base_i", "rw_stall_i",
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


async def preload_row256(dut, half_sel, row, val256):
    """DMA-fill a full 256b row (8 banks x 32b) in the half_sel-selected half."""
    base = 8 if half_sel else 0
    for j in range(8):
        word = (val256 >> (32 * j)) & 0xFFFFFFFF
        await dma_fill(dut, base + j, row, word)


async def preload_residual(dut, half_sel, row, mants):
    await preload_row256(dut, half_sel, row, pack(mants))


async def feed_src0(dut, blocks, inline_byte):
    """Stream N ordered SRC0 fast-path capsules. Each is HELD (canonical single-beat
    master) until cap_ready_o, so the FOLD-3 accept-limiter releases exactly one per
    block at that block's WAIT_OP0 — an eager k+1 cannot jump ahead of block k's SRC1."""
    for payload in blocks:
        dut.cap_payload_i.value = pack(payload)
        dut.cap_inline_scale_i.value = inline_byte
        dut.cap_valid_i.value = 1
        for _ in range(2000):
            await RisingEdge(dut.clk_i)
            if int(dut.cap_ready_o.value) == 1:
                break
        dut.cap_valid_i.value = 0
        await RisingEdge(dut.clk_i)   # one idle beat between capsules
    dut.cap_valid_i.value = 0


async def feed_src0_eager(dut, blocks, inline_byte):
    """[FOLD-3 adversarial] Eager producer: holds cap_valid=1 CONTINUOUSLY, advancing to the
    next SRC0 the cycle after each accept WITHOUT dropping valid. This makes a 2nd SRC0 valid
    within a single block's WAIT_OP0 (and across block boundaries), stressing the WAIT_OP0
    accept-cap arm — block k+1's SRC0 must NOT be queued ahead of block k's resident SRC1
    (else VERR_ROLE_MISORDER)."""
    dut.cap_payload_i.value = pack(blocks[0])
    dut.cap_inline_scale_i.value = inline_byte
    dut.cap_valid_i.value = 1
    idx = 0
    for _ in range(20000):
        await RisingEdge(dut.clk_i)
        if int(dut.cap_ready_o.value) == 1:
            idx += 1
            if idx >= len(blocks):
                break
            dut.cap_payload_i.value = pack(blocks[idx])   # advance, keep valid HIGH (eager)
    dut.cap_valid_i.value = 0


async def issue_cmd(dut, half, block_log2, dst, src1, n, sidecar_base, src1_scale_ref=0):
    dut.half_sel_i.value = half
    dut.block_log2_i.value = block_log2
    dut.dst_row_i.value = dst
    dut.src1_row_i.value = src1
    dut.resident_i.value = 1
    dut.len_rows_i.value = n
    dut.sidecar_base_i.value = sidecar_base
    # scale-source split: N>1 uses the sidecar; N<=1 (single-block) uses src1_scale_ref.
    dut.src1_scale_ref_i.value = src1_scale_ref & 0xFFFF
    dut.cmd_valid_i.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            break
    dut.cmd_valid_i.value = 0
    await FallingEdge(dut.clk_i)


async def run_block16_stream(dut, n, e1_list, half=0, feeder=feed_src0):
    """Drive an N-block (block16/E4M3) streaming RESADD; return (writes, done, state, saw_err).
    SRC0 at exp0 (e0=0); residual block k has DISTINCT abs exp e1_list[k] via the sidecar.
    `feeder` selects the SRC0 producer model (canonical held-per-block vs eager continuous)."""
    assert len(e1_list) == n
    src0_blocks = [[100 + 10 * i + 3 * k for i in range(16)] for k in range(n)]
    res_blocks  = [[40 + 6 * i + 5 * k for i in range(16)] for k in range(n)]

    # 1) preload N residual rows + the packed scale-sidecar row (one row holds <=16 exps)
    for k in range(n):
        await preload_residual(dut, half, SRC1_BASE + k, res_blocks[k])
    for r, row256 in enumerate(g.scale_stream_pack(e1_list)):
        await preload_row256(dut, half, SIDECAR_ROW + r, row256)

    # 2) issue the streaming RESADD
    await issue_cmd(dut, half, BS_16, DST_BASE, SRC1_BASE, n, SIDECAR_ROW)

    # 3) stream the N SRC0 capsules in the background (held until accepted per block)
    cocotb.start_soon(feeder(dut, src0_blocks, E4M3_EXP0))

    # 4) capture the N writebacks + completion
    writes, done, state, saw_err = {}, False, -1, False
    for _ in range(400 * max(n, 1)):
        await FallingEdge(dut.clk_i)
        if int(dut.err_o.value):
            saw_err = True
        if int(dut.rw_req_o.value) == 1:
            writes[int(dut.rw_row_o.value)] = int(dut.rw_wdata_o.value)
        if int(dut.done_o.value) == 1:
            done = True
            state = int(dut.vu_state_o.value)
            break

    gold = g.resadd_stream_golden(src0_blocks, [0] * n, res_blocks, e1_list,
                                  mant_corr0=128, mant_corr1=128, precise=True)
    return writes, done, state, saw_err, gold


def check_stream(fails, n, writes, done, state, saw_err, gold):
    # meta: the oracle must be honest — distinct per-block aligned payloads
    if len({pack(gb["aligned"]) for gb in gold}) < min(n, 2):
        fails.append("oracle not honest: per-block goldens are not distinct (shared-scale shortcut)")
    for k in range(n):
        row = DST_BASE + k
        exp_w = pack(gold[k]["aligned"])
        if row not in writes:
            fails.append("block %d: no L2 write at row 0x%x" % (k, row))
            continue
        if writes[row] != exp_w:
            for i in range(16):
                gw = (writes[row] >> (i * 16)) & 0xFFFF
                ew = (exp_w >> (i * 16)) & 0xFFFF
                if gw != ew:
                    fails.append("block %d lane %d: rtl=0x%04x gold=0x%04x (per-block scale "
                                 "e1[%d] mis-applied?)" % (k, i, gw, ew, k))
                    break
    # off-by-one ROW guard: a write at dst+N (one past the last block) means over-run
    if (DST_BASE + n) in writes:
        fails.append("over-run: a write landed at dst+N=0x%x (block index ran past N)"
                     % (DST_BASE + n))
    if not done:
        fails.append("stream done never pulsed (N-block loop hung / watchdog?)")
    elif state != VST_DONE:
        fails.append("stream completed via VST_ERROR (state=%d)" % state)
    if saw_err:
        fails.append("vector error during clean streaming RESADD (no degrade expected)")


@cocotb.test()
async def test_stream_2block_microstep(dut):
    """RUNG 3: N=2 block16 streaming, DISTINCT e1[0]!=e1[1]. Smallest integration that
    exercises the outer loop + per-block sidecar scale + per-block writeback address.
    RED pre-re-time: only block 0 writes (FSM retires to IDLE after one block), or block
    1 reuses block-0's scale (writeback mismatches the golden's e1[1])."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    writes, done, state, saw_err, gold = await run_block16_stream(dut, 2, e1_list=[-1, -3])
    check_stream(fails, 2, writes, done, state, saw_err, gold)
    assert not fails, "2-block streaming RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 3: N=2 streaming RESADD — per-block sidecar scale e1=[-1,-3], "
                  "writebacks at dst+0/dst+1 bit-exact vs resadd_stream_golden")


BS_32 = 1
E8M0_EXP0 = 127          # E8M0 byte for exp0 (SRC0 legacy byte)


async def run_block32_stream(dut, n, e1_list, half=0):
    """Drive an N-block (block32/E8M0) streaming RESADD: each block = 2 windows (2 residual
    rows, 2 SRC0 capsules, 2 writebacks at dst+2k/dst+2k+1) SHARING the block's exp[k].
    Returns (writes, done, state, saw_err, gold[N pairs])."""
    assert len(e1_list) == n
    src0_w0 = [[100 + 7 * i + 4 * k for i in range(16)] for k in range(n)]
    src0_w1 = [[60 + 9 * i + 4 * k for i in range(16)] for k in range(n)]
    res_w0  = [[40 + 6 * i + 5 * k for i in range(16)] for k in range(n)]
    res_w1  = [[33 + 5 * i + 5 * k for i in range(16)] for k in range(n)]

    # preload 2N residual rows (block k: win0 @ src1+2k, win1 @ src1+2k+1) + the sidecar
    for k in range(n):
        await preload_residual(dut, half, SRC1_BASE + 2 * k,     res_w0[k])
        await preload_residual(dut, half, SRC1_BASE + 2 * k + 1, res_w1[k])
    for r, row256 in enumerate(g.scale_stream_pack(e1_list)):
        await preload_row256(dut, half, SIDECAR_ROW + r, row256)

    await issue_cmd(dut, half, BS_32, DST_BASE, SRC1_BASE, n, SIDECAR_ROW)

    # 2N ordered SRC0 capsules: block k window0 then window1, in block order
    flat_src0 = []
    for k in range(n):
        flat_src0.append(src0_w0[k])
        flat_src0.append(src0_w1[k])
    cocotb.start_soon(feed_src0(dut, flat_src0, E8M0_EXP0))

    writes, done, state, saw_err = {}, False, -1, False
    for _ in range(500 * max(n, 1)):
        await FallingEdge(dut.clk_i)
        if int(dut.err_o.value):
            saw_err = True
        if int(dut.rw_req_o.value) == 1:
            writes[int(dut.rw_row_o.value)] = int(dut.rw_wdata_o.value)
        if int(dut.done_o.value) == 1:
            done = True
            state = int(dut.vu_state_o.value)
            break

    gold = g.resadd_stream_block32(src0_w0, src0_w1, res_w0, res_w1, e1_list,
                                   e0=0, mant_corr0=128, mant_corr1=128, precise=False)
    return writes, done, state, saw_err, gold


@cocotb.test()
async def test_stream_block32(dut):
    """RUNG 5: N=3 block32/E8M0 streaming. The OUTER loop runs over the existing 1-bit
    inner block32 window machinery: block k writes TWO rows dst+2k / dst+2k+1 sharing
    exp[k] (stride-2 addressing), with payloads differing per window. RED pre-re-time:
    egress_window_q / rsd_cap_idx_q not reset per block -> window mis-pairing across
    blocks, or wrong stride (blk_row_off must be 2k not k)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    n, e1_list = 3, [-1, 2, -5]
    writes, done, state, saw_err, gold = await run_block32_stream(dut, n, e1_list)

    if len({pack(p[0]["aligned"]) for p in gold}) < min(n, 2):
        fails.append("oracle not honest: per-block block32 goldens not distinct")
    for k in range(n):
        for w, (row, gb) in enumerate(((DST_BASE + 2 * k, gold[k][0]),
                                       (DST_BASE + 2 * k + 1, gold[k][1]))):
            exp_w = pack(gb["aligned"])
            if row not in writes:
                fails.append("block %d win%d: no L2 write at row 0x%x" % (k, w, row))
                continue
            if writes[row] == 0:
                fails.append("block %d win%d: all-zero write (residual annihilated?)" % (k, w))
            if writes[row] != exp_w:
                for i in range(16):
                    gw = (writes[row] >> (i * 16)) & 0xFFFF
                    ew = (exp_w >> (i * 16)) & 0xFFFF
                    if gw != ew:
                        fails.append("block %d win%d lane %d: rtl=0x%04x gold=0x%04x"
                                     % (k, w, i, gw, ew))
                        break
    if (DST_BASE + 2 * n) in writes:
        fails.append("over-run: write at dst+2N=0x%x" % (DST_BASE + 2 * n))
    if not done:
        fails.append("block32 stream done never pulsed")
    elif state != VST_DONE:
        fails.append("block32 stream completed via VST_ERROR (state=%d)" % state)
    if saw_err:
        fails.append("vector error during clean block32 streaming RESADD")

    assert not fails, "block32 streaming RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 5: N=3 block32/E8M0 streaming — per-block exp=[-1,2,-5], 2 windows/block "
                  "at dst+2k/dst+2k+1 (stride-2) bit-exact vs resadd_stream_block32")


async def drive_single_block(dut, e1, half=0, dst=DST_BASE, src1=SRC1_BASE):
    """One block16 resident RESADD with block_count=1 (streaming_mode OFF — uses
    src1_scale_ref, NOT the sidecar). Returns (write, row, done, state, saw_err, gold)."""
    src0 = [100 + 10 * i for i in range(16)]
    res  = [40 + 6 * i for i in range(16)]
    await preload_residual(dut, half, src1, res)
    # len_rows=1 -> block_count_eff=1 -> streaming_mode FALSE; scale rides src1_scale_ref.
    await issue_cmd(dut, half, BS_16, dst, src1, 1, SIDECAR_ROW, src1_scale_ref=e1)
    cocotb.start_soon(feed_src0(dut, [src0], E4M3_EXP0))
    write, row, done, state, saw_err = None, None, False, -1, False
    for _ in range(400):
        await FallingEdge(dut.clk_i)
        if int(dut.err_o.value):
            saw_err = True
        if write is None and int(dut.rw_req_o.value) == 1:
            write = int(dut.rw_wdata_o.value)
            row = int(dut.rw_row_o.value)
        if int(dut.done_o.value) == 1:
            done = True
            state = int(dut.vu_state_o.value)
            break
    gold = g.resadd_fastpath_golden(src0, 0, res, e1, mant_corr0=128, mant_corr1=128, precise=True)
    return write, row, done, state, saw_err, gold


@cocotb.test()
async def test_stream_l2wb_write_stall_fold5(dut):
    """RUNG 7 (FOLD-5): a streaming RESADD whose L2 write-back hangs (rw_gnt masked low) must
    LOUD-FAIL via VST_ERROR/VERR_OPERAND_TIMEOUT, not deadlock. The sidecar+residual reads
    complete (RO grants); block 0 computes and reaches VST_L2_WB where the streaming
    l2wb_wait_cnt watchdog trips. RED if FOLD-5 omitted (L2_WB advances only on rw_gnt -> hang)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    n, e1_list = 2, [-1, -3]
    src0_blocks = [[100 + 10 * i + 3 * k for i in range(16)] for k in range(n)]
    res_blocks  = [[40 + 6 * i + 5 * k for i in range(16)] for k in range(n)]
    for k in range(n):
        await preload_residual(dut, 0, SRC1_BASE + k, res_blocks[k])
    for r, row256 in enumerate(g.scale_stream_pack(e1_list)):
        await preload_row256(dut, 0, SIDECAR_ROW + r, row256)
    dut.rw_stall_i.value = 1                        # <-- mask the Vector's RW grant
    await issue_cmd(dut, 0, BS_16, DST_BASE, SRC1_BASE, n, SIDECAR_ROW)
    cocotb.start_soon(feed_src0(dut, src0_blocks, E4M3_EXP0))

    got_done, err, code, reached_err = False, 0, -1, False
    for _ in range(1400):                          # > VEC_WATCHDOG_THRESHOLD (1023)
        await FallingEdge(dut.clk_i)
        if int(dut.vu_state_o.value) == VST_ERROR:
            reached_err = True
        if int(dut.done_o.value) == 1:
            got_done = True
            err = int(dut.err_o.value)
            code = int(dut.err_code_o.value)
            break
    if not reached_err:
        fails.append("L2_WB write-stall never reached VST_ERROR (hang? FOLD-5 missing)")
    if not got_done:
        fails.append("HANG: streaming L2_WB write-stall never fired done_o (credit leak)")
    if not (err == 1 and code == VERR_OPERAND_TIMEOUT):
        fails.append("write-stall must be VERR_OPERAND_TIMEOUT (err=%d code=%d)" % (err, code))
    dut.rw_stall_i.value = 0
    assert not fails, "FOLD-5 L2_WB write-stall failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 7 (FOLD-5): streaming L2_WB write-stall -> loud VST_ERROR/"
                  "VERR_OPERAND_TIMEOUT (credit returned), not a hang")


@cocotb.test()
async def test_stream_eager_producer_fold3(dut):
    """RUNG 7 (FOLD-3 adversarial): an EAGER fast-path producer holding cap_valid=1 continuously
    across block boundaries (back-to-back distinct SRC0) must NOT let block k+1's SRC0 jump
    ahead of block k's resident SRC1. The WAIT_OP0 accept-cap (fp_blk_accept_cnt>=caps_per_block)
    + WAIT_OP1 closure hold it back. Assert clean DONE, correct per-block golden rows, and NO
    VERR_ROLE_MISORDER. RED if the limiter regressed ('>' vs '>=' or wrong caps_per_block)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    n = 4
    writes, done, state, saw_err, gold = await run_block16_stream(
        dut, n, e1_list=[-1, 2, -4, 1], feeder=feed_src0_eager)
    if int(dut.err_code_o.value) == VERR_ROLE_MISORDER:
        fails.append("VERR_ROLE_MISORDER: eager block k+1 SRC0 jumped ahead of block k SRC1")
    check_stream(fails, n, writes, done, state, saw_err, gold)
    assert not fails, "FOLD-3 eager-producer failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 7 (FOLD-3): eager continuous-valid producer — accept-limiter held block "
                  "k+1 SRC0 behind block k's resident SRC1, %d writebacks bit-exact, no misorder" % n)


@cocotb.test()
async def test_stream_sidecar_row_boundary(dut):
    """RUNG 7(a): N=18 spans a 16-block sidecar-row boundary (k=16 -> sidecar row k>>4=1).
    Exercises the VST_BLK_SETUP cache-MISS reload (FOLD-1: sc_state_q must reset to SC_CHECK
    per block so a group crossing REFETCHES). If FOLD-1 regressed, blocks 16,17 reuse the
    cached row-0 (and the wrong in-row lane) -> their writebacks mismatch the distinct e1[k]."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    # 18 distinct exponents (k=16,17 live in sidecar row 1, lanes 0,1)
    e1_list = [((-1) ** k) * (k % 9 + 1) for k in range(18)]
    writes, done, state, saw_err, gold = await run_block16_stream(dut, 18, e1_list)
    check_stream(fails, 18, writes, done, state, saw_err, gold)
    assert not fails, "N=18 sidecar-boundary streaming failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 7(a): N=18 stream crosses the 16-block sidecar-row boundary; blocks 16,17 "
                  "refetch sidecar row 1 (FOLD-1 cache reload), 18 writebacks bit-exact")


@cocotb.test()
async def test_stream_block_count_1_superset(dut):
    """RUNG 6: explicit block_count=1 strict-superset. A streaming-capable resident RESADD
    with N=1 must be byte-identical to today's single-block path: streaming_mode OFF, no
    VST_BLK_SETUP/sidecar read, scale from src1_scale_ref. The single writeback must match
    BOTH resadd_fastpath_golden AND resadd_stream_golden([s0],[0],[r0],[e1])[0]."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    E1 = -2
    write, row, done, state, saw_err, gold = await drive_single_block(dut, E1)
    # both oracles agree at N=1 (resadd_stream_golden reduces to the single-block golden)
    src0 = [100 + 10 * i for i in range(16)]
    res  = [40 + 6 * i for i in range(16)]
    gold_stream = g.resadd_stream_golden([src0], [0], [res], [E1],
                                         mant_corr0=128, mant_corr1=128, precise=True)[0]
    if pack(gold["aligned"]) != pack(gold_stream["aligned"]):
        fails.append("oracle disagreement: fastpath vs stream golden differ at N=1 (model bug)")
    exp_w = pack(gold["aligned"])
    if write is None:
        fails.append("no writeback for block_count=1")
    elif write != exp_w:
        fails.append("block_count=1 writeback mismatch vs single-block golden")
    if row is not None and row != DST_BASE:
        fails.append("block_count=1 wrote row 0x%x != dst 0x%x" % (row, DST_BASE))
    if not done or state != VST_DONE:
        fails.append("block_count=1 did not complete cleanly via VST_DONE (state=%d)" % state)
    if saw_err:
        fails.append("block_count=1 raised an error (streaming machinery leaked into single-block)")
    assert not fails, "block_count=1 superset failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 6: block_count=1 byte-identical to single-block (streaming_mode off, "
                  "src1_scale_ref path), writeback matches both oracles")


@cocotb.test()
async def test_stream_then_single_no_reset(dut):
    """RUNG 6 (FOLD-4): a large-N stream IMMEDIATELY followed by a block_count=1 resident
    RESADD with NO reset between them. streaming_mode_q must derive from desc_i (not the
    registered block_count_q=4 left over from the stream); otherwise the 2nd op wrongly
    engages streaming (reads the sidecar instead of src1_scale_ref) and mis-scales."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    # op 1: a 4-block stream (leaves block_count_q=4 registered)
    w, d, st, se, _ = await run_block16_stream(dut, 4, e1_list=[-1, 2, -3, 1])
    if not d or st != VST_DONE:
        fails.append("priming stream did not complete (state=%d)" % st)

    # op 2: WITHOUT reset, a single-block resident RESADD at a different dst/residual
    E1 = -4
    write, row, done, state, saw_err, gold = await drive_single_block(
        dut, E1, dst=DST_BASE + 0x20, src1=SRC1_BASE + 0x20)
    exp_w = pack(gold["aligned"])
    if write is None:
        fails.append("no writeback for the back-to-back single-block op")
    elif write != exp_w:
        fails.append("FOLD-4: single-block after stream mis-scaled (streaming_mode latched "
                     "from stale block_count_q, not desc_i)")
    if not done or state != VST_DONE:
        fails.append("back-to-back single-block did not complete via VST_DONE (state=%d)" % state)
    if saw_err:
        fails.append("FOLD-4: back-to-back single-block raised an error")
    assert not fails, "stream->single (FOLD-4) failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 6 (FOLD-4): single-block RESADD right after a 4-block stream (no reset) "
                  "stays single-block (streaming_mode from desc_i), writeback bit-exact")


@cocotb.test()
async def test_stream_5block_ff3d(dut):
    """RUNG 4 (FF3d): full N=5 block16 stream, all-distinct e1[k]. N writebacks at
    dst+0..dst+4 vs resadd_stream_golden; per-block ROW assertion catches an off-by-one
    that aliases block k's mantissa with block k-1's scale; DONE not ERROR proves the
    per-block watchdog reset (else cumulative latency trips VERR_OPERAND_TIMEOUT)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []
    writes, done, state, saw_err, gold = await run_block16_stream(dut, 5, e1_list=[0, -1, -4, 2, -7])
    check_stream(fails, 5, writes, done, state, saw_err, gold)
    assert not fails, "5-block FF3d streaming RESADD failures:\n  " + "\n  ".join(fails)
    dut._log.info("RUNG 4 (FF3d): N=5 streaming RESADD — distinct per-block scales, 5 writebacks "
                  "bit-exact vs resadd_stream_golden, completed via VST_DONE")

"""
cocotb test (⑦ compact-MX L2-store, CompactMX_Store_Impl_Spec_2026-07-11): a
block-scaled OP_VEC_STORE through the REAL vector_unit_top + REAL l2_subsystem
writes the COMPACT encoding — requantized narrow payload (MXFP4 64b / MXFP8
128b per 16-element window, narrow bank mask) plus a per-window block scale
into an L2 scale-sidecar row via read-modify-write — and a default-contract
STORE stays bit-identical to the legacy full-mask 256b write (no sidecar
traffic). Numeric oracle = Model/bfp_golden.py requantize_block_golden(cells,
4/8, 'FP', OUT_ROUND_RNE, scale_format) with cell value = lane16 x 2^scale_ref.
L2 rows are PRESET via dma_fill so the narrow payload mask and the sidecar RMW
are proven to preserve every untouched byte; results are read back per physical
bank via dma_evict.

Run: cd tb && make MODULE=test_vec_compact_mx_store TOPLEVEL=tb_vec_compact_mx_store \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv \
        ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_bank.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_ro_arbiter.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_rw_arbiter.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_subsystem.sv \
        ../tb/tb_vec_compact_mx_store.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

ELEM_MXFP8 = 6
ELEM_MXFP4 = 7
BS16, BS32 = 0, 1
HALF = 0                    # low half: banks 0-7

DST_ROW = 0x040
SC_ROW = 0x060


# ---------------------------------------------------------------------------
# golden helpers
# ---------------------------------------------------------------------------
def mk_cells(lanes, blk_exp):
    """Block-float cells matching the RTL adaptation: |mant| (17b-safe), the
    capsule's DECODED block exponent as the shared cell exponent —
    value = lane16 x 2^blk_exp."""
    cells = []
    for v in lanes:
        cells.append({"mant48": abs(v), "exp10": blk_exp,
                      "sign": 1 if v < 0 else 0, "is_nan": 0, "is_inf": 0})
    return cells


def golden_window(lanes, blk_exp, w, scale_format):
    """requantize_block_golden over one 16-lane window. blk_exp = the capsule's
    DECODED block exponent (abs codec: signed scale_ref; byte-carried E8M0:
    byte-127 — review F2 sanctioned decode). Returns (payload_int, scale16):
    FP4 -> 64b payload; FP8 -> 128b. scale16 = E8M0 byte (low 8b) or NVFP4 16b
    signed unclamped ref_exp; 0 for an all-zero window (golden)."""
    r = g.requantize_block_golden(mk_cells(lanes, blk_exp), w, 'FP',
                                  g.OUT_ROUND_RNE, scale_format)
    payload = 0
    for i, e in enumerate(r["elems"]):
        payload |= (e & ((1 << w) - 1)) << (i * w)
    if r["all_zero"]:
        scale16 = 0
    elif scale_format == g.SCALE_E4M3:
        scale16 = r["ref_exp"] & 0xFFFF          # signed unclamped, 2's complement
    else:
        scale16 = r["scale_byte"] & 0xFF
    return payload, scale16


def pack_lanes(lanes):
    v = 0
    for i, m in enumerate(lanes):
        v |= (m & 0xFFFF) << (i * 16)
    return v


# ---------------------------------------------------------------------------
# dut helpers
# ---------------------------------------------------------------------------
async def reset(dut):
    for s in ("cmd_valid_i", "half_sel_i", "elem_fmt_i", "block_log2_i", "dst_row_i",
              "sidecar_base_i", "cap_valid_i", "cap_payload_i", "cap_scale_ref_i",
              "cap_abs_i", "cap_inline_scale_i", "dma_fill_req_i", "dma_fill_bank_i",
              "dma_fill_row_i", "dma_fill_wdata_i", "dma_evict_req_i",
              "dma_evict_bank_i", "dma_evict_row_i"):
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


async def preset_row(dut, row, words):
    """Preset all 8 banks of the HALF-selected half at `row` (words[0..7])."""
    base = 8 if HALF else 0
    for j in range(8):
        await dma_fill(dut, base + j, row, words[j])


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


async def issue_cmd(dut, fmt, bs_log2, dst_row, sidecar_base, fails):
    dut.half_sel_i.value = HALF
    dut.elem_fmt_i.value = fmt
    dut.block_log2_i.value = bs_log2
    dut.dst_row_i.value = dst_row
    dut.sidecar_base_i.value = sidecar_base
    dut.cmd_valid_i.value = 1
    ok = False
    for _ in range(20):
        await RisingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            ok = True
            break
    dut.cmd_valid_i.value = 0
    if not ok:
        fails.append("cmd never accepted")
    await FallingEdge(dut.clk_i)


async def push_cap(dut, payload, scale_ref, inline_byte, abs_bit, fails):
    dut.cap_payload_i.value = payload
    dut.cap_scale_ref_i.value = scale_ref & 0xFFFF
    dut.cap_inline_scale_i.value = inline_byte
    dut.cap_abs_i.value = abs_bit
    dut.cap_valid_i.value = 1
    accepted = False
    for _ in range(60):
        await RisingEdge(dut.clk_i)
        if int(dut.miss_valid_o.value) == 1:
            fails.append("capsule MISS reason=%d" % int(dut.miss_reason_o.value))
            break
        if int(dut.cap_ready_o.value) == 1:
            accepted = True
            break
    dut.cap_valid_i.value = 0
    if not accepted and not fails:
        fails.append("capsule never accepted")
    await FallingEdge(dut.clk_i)


async def collect_writes(dut, fails, max_cycles=400):
    """Sample every granted vec RW write until done_o; returns [(row, mask, wdata)].

    Cycle-count agnostic (FallingEdge polling), so the F8 VST_CMX_PREP
    pipeline stage (+1 cycle per compact store, requantize cone registered
    off result_cap_q) is invisible here, and so is the [VEC-PIPE ⑥]
    LANE|REDUCE phase split (+1 LANE cycle per compute pass) for the same
    reason. One F8 regression tooth IS checked:
    every L2 write must land strictly BEFORE done_o (the registered-path
    payload is written from compact_payload_q on an earlier cycle than
    retire — done in the same falling edge as a write would mean the write
    ordering collapsed)."""
    writes = []
    for _ in range(max_cycles):
        await FallingEdge(dut.clk_i)
        if int(dut.err_o.value):
            fails.append("vector_unit error during STORE")
            return writes
        wrote_now = False
        if int(dut.rw_req_o.value) and int(dut.rw_gnt_o.value):
            if int(dut.rw_half_sel_o.value) != HALF:
                fails.append("rw_half_sel != %d at write" % HALF)
            writes.append((int(dut.rw_row_o.value), int(dut.rw_bank_mask_o.value),
                           int(dut.rw_wdata_o.value)))
            wrote_now = True
        if int(dut.done_o.value) == 1:
            if wrote_now:
                fails.append("done_o asserted in the SAME cycle as an L2 write "
                             "(F8: writes must strictly precede retire)")
            return writes
    fails.append("no done_o within %d cycles" % max_cycles)
    return writes


async def check_row(dut, row, exp_words, fails, tag):
    base = 8 if HALF else 0
    for j in range(8):
        got = await evict_read(dut, base + j, row)
        if got != (exp_words[j] & 0xFFFFFFFF):
            fails.append("%s: row 0x%x bank %d: readback 0x%08x != expected 0x%08x"
                         % (tag, row, base + j, got, exp_words[j] & 0xFFFFFFFF))


def row_words(pattern_words, low_bits, nbits):
    """Expected row: pattern with the low `nbits` replaced by low_bits."""
    words = list(pattern_words)
    for j in range(8):
        w = words[j]
        for b in range(32):
            bit = j * 32 + b
            if bit < nbits:
                w = (w & ~(1 << b)) | (((low_bits >> bit) & 1) << b)
        words[j] = w
    return words


PAT_PAY = [0xA5A50000 + i for i in range(8)]     # payload-row preset pattern
PAT_SC = [0xC3C30000 + i for i in range(8)]      # sidecar-row preset pattern


# ---------------------------------------------------------------------------
# 1. MXFP4 + BS_32 (per-16-element E8M0 scale, 4.5b/result; not an OCP MX 32-element block): 2 x 64b narrow-mask payload writes +
#    one 8b-dense sidecar RMW (byte lanes 0/1); untouched banks/bytes preserved.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_mxfp4_block32(dut):
    """MXFP4+BS_32: two 64b compact windows + E8M0 sidecar RMW, golden-exact."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    SREF = -2   # shared absolute block exponent (both windows: one scale/contract)
    lanes0 = [1000, -2000, 3000, -4000, 5000, -6000, 7000, -8000,
              900, -1500, 2500, -3500, 4500, -5500, 6500, -7500]
    lanes1 = [-125, 250, -375, 500, -625, 750, -875, 1000,
              1125, -1250, 1375, -1500, 1625, -1750, 1875, -2000]

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP4, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), SREF, 127, 1, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), SREF, 127, 1, fails)

    writes = await collect_writes(dut, fails)

    p64_0, sc0 = golden_window(lanes0, SREF, 4, g.SCALE_E8M0)
    p64_1, sc1 = golden_window(lanes1, SREF, 4, g.SCALE_E8M0)

    if not fails:
        if len(writes) != 3:
            fails.append("expected 3 granted writes (2 payload + 1 sidecar), got %d: %s"
                         % (len(writes), [(hex(r), hex(m)) for r, m, _ in writes]))
    if not fails:
        for w, (exp_row, exp_p64) in enumerate([(DST_ROW, p64_0), (DST_ROW + 1, p64_1)]):
            row, mask, wdata = writes[w]
            if row != exp_row:
                fails.append("payload write %d row 0x%x != 0x%x" % (w, row, exp_row))
            if mask != 0x03:
                fails.append("payload write %d mask 0x%02x != 0x03 (FP4 narrow)" % (w, mask))
            if (wdata & ((1 << 64) - 1)) != exp_p64:
                fails.append("payload write %d low64 0x%016x != golden 0x%016x"
                             % (w, wdata & ((1 << 64) - 1), exp_p64))
        row, mask, wdata = writes[2]
        if row != SC_ROW:
            fails.append("sidecar write row 0x%x != 0x%x" % (row, SC_ROW))
        if mask != 0xFF:
            fails.append("sidecar write mask 0x%02x != 0xFF (full-row RMW)" % mask)

    # persistent-state readback: payload rows (low 64b compact, banks 2-7 preset)
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, p64_0, 64), fails, "FP4 win0")
        await check_row(dut, DST_ROW + 1, row_words(PAT_PAY, p64_1, 64), fails, "FP4 win1")
        # sidecar row: byte0/1 = per-window E8M0 scale bytes, other 30 bytes preset
        exp_sc = list(PAT_SC)
        exp_sc[0] = (PAT_SC[0] & 0xFFFF0000) | (sc1 << 8) | sc0
        await check_row(dut, SC_ROW, exp_sc, fails, "FP4 sidecar")

    assert not fails, "compact-MX FP4/BS32 failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXFP4+BS_32: 2x64b narrow payload + E8M0 sidecar RMW golden-exact "
                  "(bytes 0x%02x/0x%02x, 30 preset bytes preserved)" % (sc0, sc1))


# ---------------------------------------------------------------------------
# 2. MXFP4 + BS_16 (NVFP4 5.0b/result): single 64b window + 16b signed
#    UNCLAMPED ref_exp sidecar lane (abs codec) — incl. negative ref_exp and
#    an all-zero window (golden all_zero: payload 0, sidecar lane 0).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_nvfp4_block16(dut):
    """MXFP4+BS_16 (NVFP4): 64b window + 16b signed sidecar ref_exp; all-zero case."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    SREF = -5
    lanes = [3, -5, 7, -9, 11, -13, 15, -17, 2, -4, 6, -8, 10, -12, 14, -16]

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP4, BS16, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes), SREF, 0x38, 1, fails)
    writes = await collect_writes(dut, fails)

    p64, sc16 = golden_window(lanes, SREF, 4, g.SCALE_E4M3)
    if sc16 < 0x8000:
        fails.append("test vector defect: expected a NEGATIVE ref_exp (got 0x%04x)" % sc16)

    if not fails:
        if len(writes) != 2:
            fails.append("expected 2 granted writes (payload + sidecar), got %d" % len(writes))
    if not fails:
        row, mask, wdata = writes[0]
        if (row, mask) != (DST_ROW, 0x03):
            fails.append("payload write (row 0x%x, mask 0x%02x) != (0x%x, 0x03)"
                         % (row, mask, DST_ROW))
        if (wdata & ((1 << 64) - 1)) != p64:
            fails.append("payload low64 0x%016x != golden 0x%016x"
                         % (wdata & ((1 << 64) - 1), p64))
        row, mask, wdata = writes[1]
        if (row, mask) != (SC_ROW, 0xFF):
            fails.append("sidecar write (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                         % (row, mask, SC_ROW))
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, p64, 64), fails, "NVFP4 payload")
        exp_sc = list(PAT_SC)
        exp_sc[0] = (PAT_SC[0] & 0xFFFF0000) | sc16      # 16b lane 0 (FF3a layout)
        await check_row(dut, SC_ROW, exp_sc, fails, "NVFP4 sidecar")

    # second command on the same rows: ALL-ZERO window -> payload 0 + sidecar 0
    if not fails:
        await issue_cmd(dut, ELEM_MXFP4, BS16, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, 0, SREF, 0x38, 1, fails)
    if not fails:
        writes = await collect_writes(dut, fails)
        if len(writes) != 2:
            fails.append("all-zero: expected 2 writes, got %d" % len(writes))
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, 0, 64), fails, "all-zero payload")
        exp_sc = list(PAT_SC)
        exp_sc[0] = PAT_SC[0] & 0xFFFF0000               # golden all_zero -> lane 0x0000
        await check_row(dut, SC_ROW, exp_sc, fails, "all-zero sidecar")

    assert not fails, "compact-MX NVFP4/BS16 failures:\n  " + "\n  ".join(fails)
    dut._log.info("NVFP4+BS_16: 64b window + signed 16b sidecar ref_exp 0x%04x "
                  "+ all-zero window golden-exact" % sc16)


# ---------------------------------------------------------------------------
# 3. MXFP8 + BS_32 (8.5b/result): 2 x 128b payload writes (mask 8'h0F) + two
#    8b sidecar scale lanes. Window 0 includes -32768 (17b |mant| adaptation).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_mxfp8_block32(dut):
    """MXFP8+BS_32: two 128b compact windows + E8M0 sidecar RMW; -32768 lane."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    SREF = 3
    lanes0 = [-32768, 32767, 16384, -16384, 8192, -8192, 4096, -4096,
              2048, -2048, 1024, -1024, 512, -512, 300, -300]
    lanes1 = [17, -34, 51, -68, 85, -102, 119, -136,
              153, -170, 187, -204, 221, -238, 255, -272]

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP8, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), SREF, 127, 1, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), SREF, 127, 1, fails)
    writes = await collect_writes(dut, fails)

    p128_0, sc0 = golden_window(lanes0, SREF, 8, g.SCALE_E8M0)
    p128_1, sc1 = golden_window(lanes1, SREF, 8, g.SCALE_E8M0)

    if not fails:
        if len(writes) != 3:
            fails.append("expected 3 granted writes, got %d" % len(writes))
    if not fails:
        for w, (exp_row, exp_p) in enumerate([(DST_ROW, p128_0), (DST_ROW + 1, p128_1)]):
            row, mask, wdata = writes[w]
            if row != exp_row:
                fails.append("payload write %d row 0x%x != 0x%x" % (w, row, exp_row))
            if mask != 0x0F:
                fails.append("payload write %d mask 0x%02x != 0x0F (FP8 narrow)" % (w, mask))
            if (wdata & ((1 << 128) - 1)) != exp_p:
                fails.append("payload write %d low128 0x%032x != golden 0x%032x"
                             % (w, wdata & ((1 << 128) - 1), exp_p))
        row, mask, _ = writes[2]
        if (row, mask) != (SC_ROW, 0xFF):
            fails.append("sidecar write (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                         % (row, mask, SC_ROW))
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, p128_0, 128), fails, "FP8 win0")
        await check_row(dut, DST_ROW + 1, row_words(PAT_PAY, p128_1, 128), fails, "FP8 win1")
        exp_sc = list(PAT_SC)
        exp_sc[0] = (PAT_SC[0] & 0xFFFF0000) | (sc1 << 8) | sc0
        await check_row(dut, SC_ROW, exp_sc, fails, "FP8 sidecar")

    assert not fails, "compact-MX FP8/BS32 failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXFP8+BS_32: 2x128b narrow payload + E8M0 sidecar RMW golden-exact "
                  "(incl. -32768 lane)")


# ---------------------------------------------------------------------------
# 4. Default-path regression (pure-additive tooth): contract='0 STORE keeps the
#    legacy semantics — full 8'hFF mask, 256b captured wdata == readback, NO
#    sidecar write (preset sidecar row byte-identical after the op).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_default_store_regression(dut):
    """Default STORE (contract='0): full-mask 256b writes, no sidecar traffic."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    lanes0 = [0x1000 + i for i in range(16)]
    lanes1 = [0x2000 + i for i in range(16)]

    await preset_row(dut, SC_ROW, PAT_SC)     # must stay untouched

    await issue_cmd(dut, 0, BS32, DST_ROW, SC_ROW, fails)   # elem_fmt=0 -> legacy
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), 0, 127, 0, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), 0, 127, 0, fails)
    writes = await collect_writes(dut, fails)

    if not fails:
        if len(writes) != 2:
            fails.append("legacy STORE: expected exactly 2 writes (block32 dual window, "
                         "no sidecar), got %d: %s"
                         % (len(writes), [(hex(r), hex(m)) for r, m, _ in writes]))
    if not fails:
        for w, exp_row in enumerate([DST_ROW, DST_ROW + 1]):
            row, mask, wdata = writes[w]
            if row != exp_row:
                fails.append("legacy write %d row 0x%x != 0x%x" % (w, row, exp_row))
            if mask != 0xFF:
                fails.append("legacy write %d mask 0x%02x != 0xFF (full)" % (w, mask))
            # captured-write vs readback (pre-⑦ semantics anchor)
            words = [(wdata >> (32 * j)) & 0xFFFFFFFF for j in range(8)]
            await check_row(dut, exp_row, words, fails, "legacy win%d" % w)
        await check_row(dut, SC_ROW, PAT_SC, fails, "legacy sidecar-untouched")

    assert not fails, "default-path STORE regression failures:\n  " + "\n  ".join(fails)
    dut._log.info("default STORE: 2x full-mask 256b writes, sidecar row untouched "
                  "(pure-additive proven)")

# ---------------------------------------------------------------------------
# 5. (review F2a) byte-carried E8M0 scale: real-producer flavor (bit8=0,
#    exponent in the inline BYTE, scale_ref = don't-care garbage) — the
#    sanctioned decode must use byte-127, and differing raw scale_ref values
#    must NOT trip the fragment-mismatch fallback (decoded scales are equal).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_mxfp4_block32_byte_scale(dut):
    """MXFP4+BS_32 with bit8=0 byte-carried E8M0 scale (tensor-producer flavor)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    BYTE = 120                      # exp = 120 - 127 = -7
    BLK_EXP = BYTE - 127
    lanes0 = [64, -128, 192, -256, 320, -384, 448, -512,
              96, -160, 224, -288, 352, -416, 480, -500]
    lanes1 = [33, -66, 99, -132, 165, -198, 231, -264,
              41, -82, 123, -164, 205, -246, 287, -328]

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP4, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        # scale_ref = GARBAGE (and different per fragment): must be ignored when
        # bit8=0, and must not false-trip the F3 fragment-mismatch fallback.
        await push_cap(dut, pack_lanes(lanes0), 0x1111, BYTE, 0, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), 0x2222, BYTE, 0, fails)
    writes = await collect_writes(dut, fails)

    p64_0, sc0 = golden_window(lanes0, BLK_EXP, 4, g.SCALE_E8M0)
    p64_1, sc1 = golden_window(lanes1, BLK_EXP, 4, g.SCALE_E8M0)

    if not fails and len(writes) != 3:
        fails.append("expected 3 granted writes (2 payload + 1 sidecar RMW), got %d: %s"
                     % (len(writes), [(hex(r), hex(m)) for r, m, _ in writes]))
    if not fails:
        for w, (exp_row, exp_p64) in enumerate([(DST_ROW, p64_0), (DST_ROW + 1, p64_1)]):
            row, mask, wdata = writes[w]
            if (row, mask) != (exp_row, 0x03):
                fails.append("payload write %d (row 0x%x, mask 0x%02x) != (0x%x, 0x03)"
                             % (w, row, mask, exp_row))
            if (wdata & ((1 << 64) - 1)) != exp_p64:
                fails.append("payload write %d low64 0x%016x != golden 0x%016x "
                             "(byte-127 decode!)" % (w, wdata & ((1 << 64) - 1), exp_p64))
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, p64_0, 64), fails, "byte-scale win0")
        await check_row(dut, DST_ROW + 1, row_words(PAT_PAY, p64_1, 64), fails, "byte-scale win1")
        exp_sc = list(PAT_SC)
        exp_sc[0] = (PAT_SC[0] & 0xFFFF0000) | (sc1 << 8) | sc0
        await check_row(dut, SC_ROW, exp_sc, fails, "byte-scale sidecar")

    assert not fails, "byte-carried E8M0 scale failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXFP4+BS_32 byte-carried E8M0 (bit8=0, byte=%d -> exp %d): "
                  "payload+sidecar golden-exact, garbage scale_ref ignored" % (BYTE, BLK_EXP))


# ---------------------------------------------------------------------------
# 6. (review F2b) non-power-of-2 / non-decodable scale -> LOSSLESS full-payload
#    fallback: (i) E4M3 abs codec with nonzero mantissa bits in the byte,
#    (ii) byte-carried E4M3 (bit8=0). Both: single full-mask 256b write of the
#    UNTOUCHED internal payload, NO sidecar write.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_nvfp4_nonpow2_fallback(dut):
    """Non-pow2 / byte-carried E4M3 scale -> lossless full-payload fallback."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    lanes = [3, -5, 7, -9, 11, -13, 15, -17, 2, -4, 6, -8, 10, -12, 14, -16]

    for tag, byte, abs_bit in (("abs+mant(0x3C)", 0x3C, 1),   # mant bits != 0 -> 1.5x2^e
                               ("byte-carried(0x38)", 0x38, 0)):  # bit8=0 E4M3 flavor
        await preset_row(dut, DST_ROW, PAT_PAY)
        await preset_row(dut, SC_ROW, PAT_SC)

        await issue_cmd(dut, ELEM_MXFP4, BS16, DST_ROW, SC_ROW, fails)
        if not fails:
            await push_cap(dut, pack_lanes(lanes), -5, byte, abs_bit, fails)
        if fails:
            break
        writes = await collect_writes(dut, fails)
        if not fails and len(writes) != 1:
            fails.append("%s: expected 1 full-payload write (NO sidecar), got %d: %s"
                         % (tag, len(writes), [(hex(r), hex(m)) for r, m, _ in writes]))
        if not fails:
            row, mask, wdata = writes[0]
            if (row, mask) != (DST_ROW, 0xFF):
                fails.append("%s: fallback write (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                             % (tag, row, mask, DST_ROW))
            if wdata != pack_lanes(lanes):
                fails.append("%s: fallback wdata != internal payload (LOSSLESS violated)" % tag)
        if not fails:
            words = [(pack_lanes(lanes) >> (32 * j)) & 0xFFFFFFFF for j in range(8)]
            await check_row(dut, DST_ROW, words, fails, "%s payload" % tag)
            await check_row(dut, SC_ROW, PAT_SC, fails, "%s sidecar-untouched" % tag)
        if fails:
            break

    assert not fails, "non-pow2 fallback failures:\n  " + "\n  ".join(fails)
    dut._log.info("E4M3 non-pow2/byte-carried scales fall back losslessly "
                  "(full-mask 256b, no sidecar write)")


# ---------------------------------------------------------------------------
# 7. (review F3) block32 fragment block-scale mismatch -> whole-store lossless
#    fallback (one block = one exponent invariant).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_block32_frag_scale_mismatch(dut):
    """block32 SRC0 fragments with different scale_ref -> full-payload fallback."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    lanes0 = [100 + 3 * i for i in range(16)]
    lanes1 = [-50 - 7 * i for i in range(16)]

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP4, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), -2, 127, 1, fails)   # exp -2
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), -3, 127, 1, fails)   # exp -3 (mismatch!)
    writes = await collect_writes(dut, fails)

    if not fails and len(writes) != 2:
        fails.append("expected 2 full-payload writes (NO sidecar), got %d: %s"
                     % (len(writes), [(hex(r), hex(m)) for r, m, _ in writes]))
    if not fails:
        for w, (exp_row, lanes) in enumerate([(DST_ROW, lanes0), (DST_ROW + 1, lanes1)]):
            row, mask, wdata = writes[w]
            if (row, mask) != (exp_row, 0xFF):
                fails.append("fallback write %d (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                             % (w, row, mask, exp_row))
            if wdata != pack_lanes(lanes):
                fails.append("fallback write %d wdata != internal payload" % w)
        await check_row(dut, SC_ROW, PAT_SC, fails, "mismatch sidecar-untouched")

    assert not fails, "fragment scale-mismatch fallback failures:\n  " + "\n  ".join(fails)
    dut._log.info("block32 fragment scale mismatch (-2 vs -3): whole store fell back "
                  "losslessly, sidecar untouched")


# ---------------------------------------------------------------------------
# 8. (review F6a) E8M0 all-zero windows: scale byte 0x00 special path — both
#    windows zero -> 64b zero payloads + sidecar bytes 0x00/0x00 (golden
#    all_zero branch), RMW still preserves the other 30 bytes.
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_mxfp4_block32_all_zero(dut):
    """MXFP4+BS_32 all-zero windows: payload 0 + E8M0 sidecar bytes 0x00."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP4, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, 0, -2, 127, 1, fails)
    if not fails:
        await push_cap(dut, 0, -2, 127, 1, fails)
    writes = await collect_writes(dut, fails)

    if not fails and len(writes) != 3:
        fails.append("expected 3 granted writes, got %d" % len(writes))
    if not fails:
        for w, exp_row in enumerate([DST_ROW, DST_ROW + 1]):
            row, mask, wdata = writes[w]
            if (row, mask) != (exp_row, 0x03):
                fails.append("zero write %d (row 0x%x, mask 0x%02x) != (0x%x, 0x03)"
                             % (w, row, mask, exp_row))
            if (wdata & ((1 << 64) - 1)) != 0:
                fails.append("zero write %d low64 != 0" % w)
        await check_row(dut, DST_ROW, row_words(PAT_PAY, 0, 64), fails, "zero win0")
        await check_row(dut, DST_ROW + 1, row_words(PAT_PAY, 0, 64), fails, "zero win1")
        exp_sc = list(PAT_SC)
        exp_sc[0] = PAT_SC[0] & 0xFFFF0000        # bytes 0/1 = 0x00 (golden all_zero)
        await check_row(dut, SC_ROW, exp_sc, fails, "zero sidecar")

    assert not fails, "all-zero E8M0 failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXFP4+BS_32 all-zero: 64b zero payloads + sidecar bytes 0x00/0x00 "
                  "(golden all_zero), RMW preserved 30 preset bytes")


# ---------------------------------------------------------------------------
# 9. (review F6b) MXINT8 store: fmt_is_block_scaled includes it (the adapter
#    passes the contract through) but compact_fmt_ok excludes it — behavior
#    must be BITWISE identical to the default store (full mask, no sidecar).
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_mxint8_fallback_like_default(dut):
    """MXINT8 store behaves bit-identically to the default (legacy) store."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    ELEM_MXINT8 = 8
    DST_B = DST_ROW + 8
    lanes0 = [0x1000 + i for i in range(16)]
    lanes1 = [0x2000 + i for i in range(16)]

    await preset_row(dut, SC_ROW, PAT_SC)     # must stay untouched by BOTH runs

    # run A: default store (elem_fmt=0)
    await issue_cmd(dut, 0, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), 0, 127, 0, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), 0, 127, 0, fails)
    writes_a = await collect_writes(dut, fails)

    # run B: MXINT8 store (block-scaled contract, excluded from compact)
    if not fails:
        await issue_cmd(dut, ELEM_MXINT8, BS32, DST_B, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), 0, 127, 0, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), 0, 127, 0, fails)
    writes_b = await collect_writes(dut, fails)

    if not fails:
        if len(writes_a) != 2 or len(writes_b) != 2:
            fails.append("expected 2 writes each: default=%d mxint8=%d"
                         % (len(writes_a), len(writes_b)))
    if not fails:
        for w in range(2):
            ra, ma, da = writes_a[w]
            rb, mb, db = writes_b[w]
            if (ma, mb) != (0xFF, 0xFF):
                fails.append("write %d masks (0x%02x, 0x%02x) != full 0xFF" % (w, ma, mb))
            if da != db:
                fails.append("write %d wdata differs between default and MXINT8 "
                             "(NOT bitwise-identical)" % w)
            if (ra, rb) != (DST_ROW + w, DST_B + w):
                fails.append("write %d rows (0x%x, 0x%x) unexpected" % (w, ra, rb))
        await check_row(dut, SC_ROW, PAT_SC, fails, "mxint8 sidecar-untouched")

    assert not fails, "MXINT8-vs-default failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXINT8 store == default store bit-for-bit (full mask, no sidecar)")

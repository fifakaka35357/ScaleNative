"""
cocotb: the REAL SoC test — IBEX boots firmware and drives the chip.

WHY THIS EXISTS
---------------
Before this, nothing in the repo instantiated pe_top. Seven files had ZERO
simulation coverage (pe_top, addr_decoder, l1_subsystem, l1i_mem, l1d_mem,
pe_ibex_wrapper, tech_icg_wrapper), and the pre-tapeout audit found a chip-killer
— the DMA 2D FILL deadlock — sitting in exactly that blind spot. Code inspection
found that one. Only execution finds the next one.

This test runs the chip the way silicon will be run:

    bench --boot port--> firmware into L1I
    bench --fetch_enable--> IBEX starts executing at 0x80
    IBEX  --sw--> descriptors into L1D
    IBEX  --sw--> CP CSRs (region table, ring, enable, doorbell)
    CP    --fetch--> descriptor from L1D port 1
    CP    --issue--> DMA
    DMA   --> L2, and L2 --> NoC egress
    bench --captures NoC egress--> checks the data

The only pins the bench touches are ones a real board would touch.

HARDWARE FACTS THE FIRMWARE MUST RESPECT (all confirmed against RTL)
-------------------------------------------------------------------
* Reset PC = {BOOT_ADDR[31:8], 8'h80} = 0x0000_0080  (ibex_if_stage.sv:169).
  NOT 0x0. Vectors live at 0x00-0x7C (mtvec = vectored, base 0).
* Data port map (addr_decoder.sv): L1D = 0x0001_0000..0x0001_0FFF (4KB),
  MMIO/CP-CSR = 0x0002_0000..0x0002_01FF. EVERYTHING ELSE, including the L1I
  range, is UNMAPPED -> bus error. So the firmware may not have .rodata: every
  constant is materialised with lui/addi.
* L2 is NOT addressable by the CPU, and L1D port 1 is read-only -> there is no
  path for results to reach the CPU. Firmware polls STATUS; the bench reads the
  data off the NoC.
* CP CSR traps that will silently kill you (cp_csr.sv / cp_scheduler.sv):
    - Region table resets to ALL ZERO (num_rows = 0) => every bounds-checked
      descriptor fails region_oob => CTX_ERROR. It MUST be programmed.
    - WD_THRESHOLD resets to 0xFFFF: the watchdog is ARMED at reset. Ringing the
      doorbell before CP_CTRL.enable=1 leaves the ctx RUNNABLE with the fetch
      engine gated off -> watchdog kills it. ENABLE FIRST, DOORBELL LAST.
    - RING_CFG resets to 1 (a 2-entry ring, mask=0x1). Write it before the
      doorbell, or the tail gets masked to 0 and nothing runs.
    - The doorbell takes the NEW ABSOLUTE TAIL, not an increment.
    - Ring slot stride is 32 bytes (8 words), and tail==head means EMPTY.
    - Do NOT poll head==tail for completion: head advances at FETCH time. Poll
      CP_STATUS nibble == 6 (CTX_DONE).

Run: cd tb && make MODULE=test_pe_top TOPLEVEL=tb_pe_top VERILOG_SOURCES="../designs/src/aichip_sv/ibex/ibex_pkg.sv ../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv ../rtl/Vector/vec_pkg.sv ../designs/src/aichip_sv/ibex/ibex_alu.sv ../designs/src/aichip_sv/ibex/ibex_compressed_decoder.sv ../designs/src/aichip_sv/ibex/ibex_controller.sv ../designs/src/aichip_sv/ibex/ibex_counter.sv ../designs/src/aichip_sv/ibex/ibex_cs_registers.sv ../designs/src/aichip_sv/ibex/ibex_csr.sv ../designs/src/aichip_sv/ibex/ibex_decoder.sv ../designs/src/aichip_sv/ibex/ibex_ex_block.sv ../designs/src/aichip_sv/ibex/ibex_fetch_fifo.sv ../designs/src/aichip_sv/ibex/ibex_id_stage.sv ../designs/src/aichip_sv/ibex/ibex_if_stage.sv ../designs/src/aichip_sv/ibex/ibex_load_store_unit.sv ../designs/src/aichip_sv/ibex/ibex_multdiv_fast.sv ../designs/src/aichip_sv/ibex/ibex_multdiv_slow.sv ../designs/src/aichip_sv/ibex/ibex_pmp.sv ../designs/src/aichip_sv/ibex/ibex_prefetch_buffer.sv ../designs/src/aichip_sv/ibex/ibex_register_file_ff.sv ../designs/src/aichip_sv/ibex/ibex_wb_stage.sv ../designs/src/aichip_sv/ibex/ibex_core.sv ../designs/src/aichip_sv/ibex/syn/rtl/prim_clock_gating.v ../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv ../rtl/IBEX_SRAM/tech_icg_wrapper.sv ../rtl/IBEX_SRAM/pe_ibex_wrapper.sv ../rtl/IBEX_SRAM/addr_decoder.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l1i_mem.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l1d_mem.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l1d_mirror_bank.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l1_subsystem.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_bank.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_ro_arbiter.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_rw_arbiter.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_subsystem.sv ../rtl/IBEX_SRAM/event_trace_ring.sv ../rtl/IBEX_SRAM/cp_csr.sv ../rtl/IBEX_SRAM/cp_desc_fetch.sv ../rtl/IBEX_SRAM/cp_scheduler.sv ../rtl/IBEX_SRAM/cp_completion.sv ../rtl/IBEX_SRAM/command_processor.sv ../rtl/IBEX_SRAM/dma_engine.sv ../rtl/IBEX_SRAM/tv_fast_fifo.sv ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv ../rtl/Tensor/tensor_external_modules.sv ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv ../rtl/Tensor/tensor_unit_top.sv ../rtl/IBEX_SRAM/tensor_cmd_mmio_seq.sv ../rtl/IBEX_SRAM/tensor_operand_stream.sv ../rtl/IBEX_SRAM/tensor_domain_top.sv ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Vector/vector_unit.sv ../rtl/Vector/vec_assertions.sv ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/pe_top.sv ../rtl/IBEX_SRAM/pe_assertions.sv ./tb_pe_top.sv"
"""
import os
import sys

import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32_asm import assemble

# ── Address map (addr_decoder.sv / pe_pkg.sv) ──
L1D_BASE  = 0x0001_0000
MMIO_BASE = 0x0002_0000

# ── CP CSR offsets (cp_csr.sv) ──
CP_CTRL       = 0x00      # [0]=enable, [1]=soft_reset
CP_STATUS     = 0x04      # 4-bit state nibble per ctx
CP_IRQ        = 0x08
CTX0_RING_BASE = 0x10     # [11:0] byte offset inside L1D
CTX0_RING_CFG  = 0x14     # [3:0] log2(entries), clamped to 1..4
CTX0_DOORBELL  = 0x18     # new ABSOLUTE tail
REGION0_BASE   = 0x80     # base_row
REGION0_NUM    = 0x84     # num_rows

CTX_DONE  = 6
CTX_ERROR = 7

# ── Descriptor opcodes (pe_pkg.sv) ──
OP_TENS_GEMM  = 0x10
OP_DMA_FILL   = 0x20
OP_DMA_EVICT  = 0x21
OP_DMA_MEMSET = 0x22

ELEM_BF16  = 0
ELEM_MXFP4 = 7

# ── Ring geometry ──
RING_OFF   = 0x000        # ring base = L1D offset 0 (32B aligned)
SLOT_BYTES = 32           # 8 words per descriptor slot

WORDS_PER_ROW = 16        # an L2 row = 16 banks x 32b = 64B


def build_desc(opcode, src_off=0, dst_off=0, len_rows=1, outer_count=0,
               stride_rows=0, memset_val=0, ctx=0, ext_len=4,
               src_rid=0, dst_rid=0, elem_fmt=0, param_m=0, param_n=0, param_k=0):
    """One 8-word descriptor (pe_pkg.sv word layout).

        w0 [7:0]=opcode [11:8]=ext_len [13:12]=ctx [23:16]=flags
        w1 src l2_addr : [15:0]=row_off [27:24]=rid   (also NoC addr for FILL)
        w2 dst l2_addr : [15:0]=row_off [27:24]=rid   (also NoC addr for EVICT)
        w3 [15:0]=len_rows [31:16]=stride_rows
        w4 DMA: [15:0]=outer_count   |  TENS: [15:0]=param_M [31:16]=param_N
        w5 DMA: memset_val           |  TENS: [15:0]=param_K
        w6 tile_contract lo : [3:0]=elem_fmt [9]=half_sel [19:16]=scale_rid
        w7 tile_contract hi

    Word 4/5 are opcode-dependent (cp_scheduler.sv:607-609 vs :632/:644) — the
    same two words carry the DMA 2D params for a DMA opcode and M/N/K for a TENS
    opcode. Callers pass whichever pair applies.

    ext_len=4 -> total_words = 4+4 = 8 -> all 4 pairs fetched, so words 6:7
    (the tile contract) actually reach the slot. With ext_len<4 the contract is
    zero-cleared (cp_desc_fetch.sv:61-66) and elem_fmt would be lost.
    """
    w = [0] * 8
    w[0] = (opcode & 0xFF) | ((ext_len & 0xF) << 8) | ((ctx & 0x3) << 12)
    w[1] = (src_off & 0xFFFF) | ((src_rid & 0xF) << 24)
    w[2] = (dst_off & 0xFFFF) | ((dst_rid & 0xF) << 24)
    w[3] = (len_rows & 0xFFFF) | ((stride_rows & 0xFFFF) << 16)
    if opcode in (OP_TENS_GEMM,):
        w[4] = (param_m & 0xFFFF) | ((param_n & 0xFFFF) << 16)
        w[5] = param_k & 0xFFFF
    else:
        w[4] = outer_count & 0xFFFF
        w[5] = memset_val & 0xFFFFFFFF
    w[6] = elem_fmt & 0xF
    w[7] = 0
    return w


def firmware(descs, n_desc, ring_off=RING_OFF, region_rows=64, skip_region=False):
    """Assemble the firmware (see firmware_src for the program itself)."""
    return assemble(firmware_src(descs, n_desc, ring_off, region_rows, skip_region),
                    base=0x80)


def firmware_src(descs, n_desc, ring_off=RING_OFF, region_rows=64, skip_region=False):
    """Assemble the firmware.

    It must fit between the reset PC (0x80) and the top of L1I (2KB), and it may
    not touch any address outside L1D / MMIO — there is no .rodata on this chip.

    Flow (order matters — see the CSR traps in the module docstring):
        1. store the descriptor words into L1D
        2. program region0  (else region_oob -> CTX_ERROR)
        3. program ring base + cfg
        4. CP_CTRL.enable = 1        <-- BEFORE the doorbell (watchdog!)
        5. doorbell = absolute tail  <-- LAST
        6. poll CP_STATUS until ctx0 == DONE, park on ERROR
    """
    src = []
    src.append(f"    li   s0, {hex(L1D_BASE)}")     # s0 = L1D base
    src.append(f"    li   s1, {hex(MMIO_BASE)}")    # s1 = CP CSR base

    # 1. descriptors -> L1D (slot k at ring_off + k*32)
    for k in range(n_desc):
        for i, word in enumerate(descs[k]):
            off = ring_off + k * SLOT_BYTES + i * 4
            if word == 0:
                src.append(f"    sw   zero, {off}(s0)")
            else:
                src.append(f"    li   t0, {hex(word)}")
                src.append(f"    sw   t0, {off}(s0)")

    # 2. region0: base_row=0, num_rows=region_rows  (MUST be set)
    #    skip_region=True is the NEGATIVE CONTROL: it proves the passing tests are
    #    not vacuous — with num_rows still 0, every descriptor fails region_oob and
    #    NOTHING must come out of the NoC.
    if not skip_region:
        src.append(f"    sw   zero, {REGION0_BASE}(s1)")
        src.append(f"    li   t0, {region_rows}")
        src.append(f"    sw   t0, {REGION0_NUM}(s1)")

    # 3. ring base + cfg (cfg BEFORE doorbell, else tail is masked away)
    src.append(f"    li   t0, {hex(ring_off)}")
    src.append(f"    sw   t0, {CTX0_RING_BASE}(s1)")
    src.append(f"    li   t0, 3")                    # log2(8 entries)
    src.append(f"    sw   t0, {CTX0_RING_CFG}(s1)")

    # 4. enable the CP  (BEFORE the doorbell — the watchdog is armed at reset)
    src.append(f"    li   t0, 1")
    src.append(f"    sw   t0, {CP_CTRL}(s1)")

    # 5. doorbell = new absolute tail = number of descriptors queued
    src.append(f"    li   t0, {n_desc}")
    src.append(f"    sw   t0, {CTX0_DOORBELL}(s1)")

    # 6. poll CP_STATUS[3:0] (ctx0) for DONE(6) / ERROR(7)
    src.append("poll:")
    src.append(f"    lw   t1, {CP_STATUS}(s1)")
    src.append( "    andi t1, t1, 0xF")
    src.append(f"    li   t2, {CTX_ERROR}")
    src.append( "    beq  t1, t2, err")
    src.append(f"    li   t2, {CTX_DONE}")
    src.append( "    bne  t1, t2, poll")
    src.append("done:")
    src.append( "    j    done")          # success: park here
    src.append("err:")
    src.append( "    j    err")           # failure: park here (distinct PC)

    return "\n".join(src)


async def boot_and_run(dut, words):
    """Write the firmware into L1I through the boot port, then release fetch."""
    dut.rst_ni.value = 0
    dut.boot_req_i.value = 0
    dut.boot_we_i.value = 0
    dut.boot_addr_i.value = 0
    dut.boot_wdata_i.value = 0
    dut.boot_be_i.value = 0
    dut.fetch_enable_i.value = 0
    dut.noc_ing_valid_i.value = 0
    dut.noc_ing_data_i.value = 0
    dut.noc_ing_last_i.value = 0
    dut.noc_egr_ready_i.value = 1
    for _ in range(8):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk_i)

    # Firmware is linked at 0x80 (the IBEX reset PC).
    for i, w in enumerate(words):
        dut.boot_req_i.value = 1
        dut.boot_we_i.value = 1
        dut.boot_be_i.value = 0xF
        dut.boot_addr_i.value = 0x80 + 4 * i
        dut.boot_wdata_i.value = w
        await RisingEdge(dut.clk_i)
    dut.boot_req_i.value = 0
    dut.boot_we_i.value = 0
    dut.boot_be_i.value = 0
    await RisingEdge(dut.clk_i)

    dut.fetch_enable_i.value = 1
    dut._log.info("firmware loaded (%d words @0x80), fetch released", len(words))


async def egress_sink(dut, out, want):
    """Capture the DMA EVICT stream off the NoC — this is how results leave a
    real chip, and the only way the bench can see them."""
    while len(out) < want:
        await RisingEdge(dut.clk_i)
        if dut.noc_egr_valid_o.value == 1 and dut.noc_egr_ready_i.value == 1:
            out.append(int(dut.noc_egr_data_o.value))


async def ingress_source(dut, words):
    """Feed DMA FILL data in as one continuous NoC burst (real traffic shape)."""
    i = 0
    while i < len(words):
        dut.noc_ing_valid_i.value = 1
        dut.noc_ing_data_i.value = words[i]
        dut.noc_ing_last_i.value = 1 if i == len(words) - 1 else 0
        await RisingEdge(dut.clk_i)
        if dut.noc_ing_ready_o.value == 1:
            i += 1
    dut.noc_ing_valid_i.value = 0
    dut.noc_ing_last_i.value = 0


async def watch_health(dut, cycles):
    """A bus error or an alert means the firmware went off the rails — fail loudly
    instead of silently timing out."""
    for _ in range(cycles):
        await RisingEdge(dut.clk_i)
        if dut.alert_major_o.value == 1:
            raise AssertionError("pe_top raised alert_major — CPU fault")


@cocotb.test()
async def test_soc_memset_evict(dut):
    """Software-driven DMA round trip: the CPU tells the chip to fill an L2 row
    with a constant and then evict it to the NoC. The bench checks the bytes that
    come out.

    Exercises, in ONE test, every file that had zero coverage: pe_top,
    pe_ibex_wrapper (+ the real IBEX), l1i_mem (boot + fetch), addr_decoder
    (L1D stores AND MMIO loads/stores), l1d_mem (CPU port write + CP port read),
    tech_icg_wrapper (the DMA runs on a gated clock), plus cp_csr / cp_desc_fetch
    / cp_scheduler / cp_completion / dma_engine / l2_subsystem.
    """
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    PATTERN = 0xA5A5_1234
    ROW = 0

    descs = [
        build_desc(OP_DMA_MEMSET, dst_off=ROW, len_rows=1, memset_val=PATTERN),
        build_desc(OP_DMA_EVICT,  src_off=ROW, len_rows=1),
    ]
    fw = firmware(descs, n_desc=2)
    assert len(fw) * 4 + 0x80 < 2048, f"firmware too big for 2KB L1I: {len(fw)} words"

    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, 60000))

    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))

    for _ in range(60000):
        await RisingEdge(dut.clk_i)
        if len(got) >= WORDS_PER_ROW:
            break
    else:
        raise AssertionError(
            f"timeout: only {len(got)}/{WORDS_PER_ROW} words came out of the NoC. "
            "The CPU never got the chip to evict — check CP programming order "
            "(enable before doorbell), region table, or a hang in the DMA.")
    await sink

    bad = [(i, hex(g)) for i, g in enumerate(got) if g != PATTERN]
    assert not bad, f"evicted data wrong (expected 0x{PATTERN:08x}): {bad[:4]}"
    dut._log.info(
        "SoC round trip OK: IBEX booted, programmed the CP, and %d words of "
        "0x%08x came back out of the NoC.", len(got), PATTERN)


@cocotb.test()
async def test_soc_fill_evict(dut):
    """The real data path: NoC -> DMA FILL -> L2 -> DMA EVICT -> NoC, all
    orchestrated by firmware. This is how weights and activations will actually
    reach the chip (L2 is not CPU-addressable), so if this works, the chip is
    loadable."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    ROW = 2
    payload = [0xC0DE_0000 + i for i in range(WORDS_PER_ROW)]

    descs = [
        build_desc(OP_DMA_FILL,  dst_off=ROW, len_rows=1),
        build_desc(OP_DMA_EVICT, src_off=ROW, len_rows=1),
    ]
    fw = firmware(descs, n_desc=2)
    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, 60000))

    cocotb.start_soon(ingress_source(dut, payload))
    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))

    for _ in range(60000):
        await RisingEdge(dut.clk_i)
        if len(got) >= WORDS_PER_ROW:
            break
    else:
        raise AssertionError(
            f"timeout: {len(got)}/{WORDS_PER_ROW} words evicted. FILL or EVICT hung.")
    await sink

    assert got == payload, (
        f"round-tripped data mismatch:\n  got      {[hex(g) for g in got[:6]]}\n"
        f"  expected {[hex(w) for w in payload[:6]]}")
    dut._log.info("NoC->L2->NoC round trip OK under firmware control (%d words).",
                  len(got))


@cocotb.test()
async def test_soc_dma_2d_fill(dut):
    """The chip-killer, now driven by real software: a 2D strided FILL issued from
    a descriptor the CPU wrote. On the pre-fix RTL the DMA locks up and nothing
    ever comes back out."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    BASE, OUTER, STRIDE = 4, 3, 2      # 3 iterations x 1 row, rows 4, 6, 8
    total = WORDS_PER_ROW * OUTER
    payload = [0xBEEF_0000 + i for i in range(total)]

    descs = [
        build_desc(OP_DMA_FILL, dst_off=BASE, len_rows=1,
                   outer_count=OUTER, stride_rows=STRIDE),
    ]
    # evict each of the three rows back out (1D evicts, so the check is independent
    # of the 2D evict path)
    for k in range(OUTER):
        descs.append(build_desc(OP_DMA_EVICT, src_off=BASE + k * STRIDE, len_rows=1))

    fw = firmware(descs, n_desc=len(descs))
    assert len(fw) * 4 + 0x80 < 2048, f"firmware too big: {len(fw)} words"

    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, 120000))

    cocotb.start_soon(ingress_source(dut, payload))
    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, total))

    for _ in range(120000):
        await RisingEdge(dut.clk_i)
        if len(got) >= total:
            break
    else:
        raise AssertionError(
            f"timeout: {len(got)}/{total} words. A software-issued 2D FILL hung — "
            "this is the pre-fix dma_engine deadlock, reached through the full "
            "CPU -> CP -> DMA path.")
    await sink

    assert got == payload, (
        f"2D FILL round trip mismatch:\n  got      {[hex(g) for g in got[:6]]}\n"
        f"  expected {[hex(w) for w in payload[:6]]}")
    dut._log.info("Software-issued 2D strided FILL round-tripped %d words across "
                  "%d outer iterations.", total, OUTER)


@cocotb.test()
async def test_soc_negative_control_no_region(dut):
    """NEGATIVE CONTROL — proves the tests above are not vacuous.

    Identical firmware, except it does NOT program the region table. The table
    resets to num_rows=0, so every bounds-checked descriptor fails region_oob and
    the context goes to CTX_ERROR (cp_scheduler region_oob path). If the passing
    tests were somehow succeeding by accident — data leaking out regardless of what
    the CPU does — this would still produce NoC traffic. It must not."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    descs = [
        build_desc(OP_DMA_MEMSET, dst_off=0, len_rows=1, memset_val=0xDEAD_0001),
        build_desc(OP_DMA_EVICT,  src_off=0, len_rows=1),
    ]
    fw = firmware(descs, n_desc=2, skip_region=True)
    await boot_and_run(dut, fw)

    got = []
    cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))
    for _ in range(20000):
        await RisingEdge(dut.clk_i)

    assert not got, (
        f"NEGATIVE CONTROL FAILED: {len(got)} words came out of the NoC even though "
        "the region table was never programmed. The chip is executing descriptors "
        "that should have been rejected as region_oob — which also means the "
        "positive tests prove nothing.")
    dut._log.info("negative control OK: no region table -> region_oob -> CTX_ERROR "
                  "-> zero NoC traffic. The positive tests are causally real.")


@cocotb.test()
async def test_soc_gemm_dispatch(dut):
    """Software-issued GEMM through the full CPU -> CP -> Tensor path.

    This is the first time a TENSOR command is dispatched from a descriptor the
    CPU wrote — it covers cp_scheduler's tensor issue path, tensor_domain_top's
    operand streamer, and tensor_cmd_mmio_seq (the file the elem_fmt->tensor_mode
    fix touched).

    Observability trick: a Tensor GEMM's result leaves via the fast-path capsule
    FIFO, not via L2, so the bench cannot see it directly. Instead the firmware
    queues THREE descriptors:

        1. TENS_GEMM
        2. DMA_MEMSET  <- writes a success token to an L2 row
        3. DMA_EVICT   <- streams that row out of the NoC

    The CP runs a context's descriptors in order and STOPS on error (ctx ->
    CTX_ERROR). So the token can only reach the NoC if the GEMM actually issued,
    ran, and completed. Seeing the token = the Tensor path works end to end under
    software control.
    """
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    TOKEN = 0x600D_600D
    TOKEN_ROW = 40
    K = 4                       # tiny tile: operands occupy rows 0..2K

    descs = [
        # operands are whatever L2 already holds — this test checks the command
        # path and completion, not the arithmetic (that is cell-exact-checked at
        # unit level by test_tensor_gemm_core).
        build_desc(OP_TENS_GEMM, src_off=0, dst_off=20, len_rows=1,
                   param_m=16, param_n=16, param_k=K, elem_fmt=ELEM_BF16),
        build_desc(OP_DMA_MEMSET, dst_off=TOKEN_ROW, len_rows=1, memset_val=TOKEN),
        build_desc(OP_DMA_EVICT,  src_off=TOKEN_ROW, len_rows=1),
    ]
    fw = firmware(descs, n_desc=len(descs))
    assert len(fw) * 4 + 0x80 < 2048, f"firmware too big: {len(fw)} words"

    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, 200000))

    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))
    for _ in range(200000):
        await RisingEdge(dut.clk_i)
        if len(got) >= WORDS_PER_ROW:
            break
    else:
        raise AssertionError(
            f"timeout: the success token never reached the NoC ({len(got)}/16 words). "
            "The GEMM did not complete — the context is stuck or went to CTX_ERROR, "
            "so the CP never ran the MEMSET/EVICT behind it. This is the CPU -> CP -> "
            "Tensor dispatch path failing.")
    await sink

    bad = [(i, hex(g)) for i, g in enumerate(got) if g != TOKEN]
    assert not bad, f"token corrupted (expected 0x{TOKEN:08x}): {bad[:4]}"
    dut._log.info("GEMM dispatched by firmware COMPLETED (token 0x%08x reached the "
                  "NoC) — CPU -> CP -> Tensor -> completion path is live.", TOKEN)

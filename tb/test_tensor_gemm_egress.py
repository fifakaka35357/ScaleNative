"""
cocotb test (STEP4-E2E Phase B): bring up a single dense BF16 GEMM tile on the
REAL Tensor/tensor_unit_top and prove it egresses block16 fast-path capsules.

This is the from-scratch bring-up of the frozen Tensor core (no reference TB
exists — see §9.7/§9.8). It drives the MMIO start sequence + DMA operand load
derived in §9.8 and checks the Class-A egress.

Operands are uniform w = a = +1.0 (BF16). After the HW-REVIEW TIER-1 OS-GEMM
re-wire (stream weights + weight column-skew + accumulate-through-tail), each cell
computes the CORRECT general GEMM C[r][c] = sum_{k=0}^{K-1} A[r][k]*B[k][c] = K
(every cell equals K, w=a=+1.0 over K loaded contraction rows). The old buggy
OS-skew count model (K-1-(r+c)) is GONE — that defect is exactly what TIER-1
fixed; cell-exact GEMM correctness is now proven by test_tensor_gemm_core. This
remains a PLUMBING test (a real GEMM result forms a block16 capsule + egresses).

issue_count is now K (compute) + ROWS+COLS (the accumulate-drain window that
flushes and sums the skewed wavefront tail) = K + 32.
(A1 fix 2026-07-06: was K + 31 = K + ROWS+COLS-1; the OS operand recapture stage
adds +1 operand latency, so DRAIN_CYCLES_OS grew 31 -> 32.)

NOTE on numeric strength (adversarial-review D3 / D2-1): the EXACT-integer-count
decode below (every egress lane == K, in [0,K]) is gated on a full-exponent E8M0
block scale and ONLY runs when the packer emits E8M0. The shipped tensor_unit_top
packer emits E4M3 (the block16 NVFP4 default, §9.8 F3), whose 4-bit exponent
clamps to a [-6,8] window, so that strong branch SKIPS in the committed config —
which then asserts the PLAUSIBILITY set only: tile_done, issue_count == K+31,
16 capsules, no escape, non-negative lanes, >=1 nonzero, full-INT16-scale
normalization, role==SRC0. The packer's E8M0 numeric path is itself covered
bit-exact by the leaf test test_tensor_result_packer (vs capsule_form_golden);
cell-exact GEMM by test_tensor_gemm_core. To re-arm the strong integer-count
check here, drive an egress configured for E8M0.

Run: cd tb && make MODULE=test_tensor_gemm_egress TOPLEVEL=tb_tensor_gemm_egress \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_egress.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

# MMIO register addresses (tensor_cmd_decoder)
A_CTRL, A_KTOTAL, A_OUTCTRL, A_EPOCH = 0x00, 0x04, 0x0C, 0x10
A_WGT, A_ACT, A_SCL, A_RES = 0x14, 0x18, 0x1C, 0x20
A_STATUS, A_ISSUE = 0x00, 0x0C   # status CSR read offsets

MODE_BF16 = 4
SCALE_E8M0, SCALE_E4M3 = 0, 1   # pe_pkg scale_format_e low bits


def signed(x, bits):
    x &= (1 << bits) - 1
    return x - (1 << bits) if (x >> (bits - 1)) & 1 else x


def lanes16(payload):
    return [signed((payload >> (i * 16)) & 0xFFFF, 16) for i in range(16)]


async def reset(dut):
    for s in ("mmio_wr_valid", "mmio_wr_addr", "mmio_wr_data", "mmio_rd_addr",
              "dma_wgt_en", "dma_act_en", "dma_scale_en", "dma_addr",
              "dma_data", "dma_scl_wgt", "dma_scl_act", "egress_ready"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await FallingEdge(dut.clk)


async def mmio(dut, seq):
    for addr, data in seq:
        dut.mmio_wr_valid.value = 1
        dut.mmio_wr_addr.value = addr
        dut.mmio_wr_data.value = data
        await RisingEdge(dut.clk)
    dut.mmio_wr_valid.value = 0
    await FallingEdge(dut.clk)


async def dma_row(dut, kind, addr, data256):
    dut.dma_wgt_en.value = 1 if kind == "wgt" else 0
    dut.dma_act_en.value = 1 if kind == "act" else 0
    dut.dma_scale_en.value = 1 if kind == "scl" else 0
    dut.dma_addr.value = addr
    dut.dma_data.value = data256
    await RisingEdge(dut.clk)
    dut.dma_wgt_en.value = 0
    dut.dma_act_en.value = 0
    dut.dma_scale_en.value = 0


async def csr_rd(dut, addr):
    dut.mmio_rd_addr.value = addr
    await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    return int(dut.mmio_rd_data.value)


@cocotb.test()
async def test_tensor_gemm_egress(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)
    fails = []

    # Nonzero WGT/ACT bases exercise the operand-base-latch (§9.8 bring-up fix:
    # the bases must survive the desc-queue pop on start). weight/act are
    # separate SRAM banks, so distinct nonzero bases are fine.
    K, EPOCH, WGT_BASE, ACT_BASE, RES_BASE = 24, 0x07, 0x020, 0x100, 0x200

    # uniform BF16 +1.0 operand row (16 lanes)
    one = g.bf16_bits(1.0)              # 0x3F80
    row = 0
    for i in range(16):
        row |= (one & 0xFFFF) << (i * 16)

    # 1) load operands. Post-TIER-1 OS-GEMM: BOTH weights and activations STREAM
    #    during COMPUTE (wgt/act_base+0..K-1), so load K rows of each. The drain
    #    window reads past K but those indices are zero-padded by operand_fetch.
    for r in range(K):
        await dma_row(dut, "wgt", WGT_BASE + r, row)
    for r in range(K + 2):
        await dma_row(dut, "act", ACT_BASE + r, row)
    await FallingEdge(dut.clk)

    # 2) MMIO drive sequence (§9.8). Mode BF16 programmed BEFORE the start write
    #    (decoder latches reg_mode registered; start pushes the PRIOR mode).
    await mmio(dut, [
        (A_CTRL,    MODE_BF16 << 4),    # 0x40: mode=BF16, dataflow_sel=0 (OS), no start
        (A_KTOTAL,  K),
        (A_OUTCTRL, 0x00),              # exec_class=EXEC_NONE, out_class=OUT_FWD_VEC_NATIVE
        (A_EPOCH,   EPOCH),
        (A_WGT,     WGT_BASE),
        (A_ACT,     ACT_BASE),
        (A_SCL,     0),
        (A_RES,     RES_BASE),
        (A_CTRL,    (MODE_BF16 << 4) | 1),  # 0x41: start pulse, LAST
    ])

    # 3) drain the egress; capture one capsule per output row.
    dut.egress_ready.value = 1
    dut.mmio_rd_addr.value = A_STATUS
    caps = {}              # row_idx -> capsule field dict
    saw_tile_done = False
    saw_last_row = False
    modes_seen = set()
    for _ in range(600):
        await FallingEdge(dut.clk)
        modes_seen.add((int(dut.mmio_rd_data.value) >> 3) & 0xF)
        if int(dut.tu_tile_done.value) == 1:
            saw_tile_done = True
        if int(dut.egress_valid.value) == 1:
            ridx = int(dut.egress_row_idx.value)
            caps[ridx] = {
                "payload":      int(dut.egress_payload.value),
                "escape":       int(dut.egress_escape.value),
                "scale_format": int(dut.egress_scale_format.value),
                "block_size":   int(dut.egress_block_size.value),
                "inline_scale": int(dut.egress_inline_scale.value),
                "role":         int(dut.egress_role.value),
                "status":       int(dut.egress_status.value),
            }
            if int(dut.egress_last_row.value) == 1:
                saw_last_row = True
        if saw_last_row and saw_tile_done:
            break

    issue_cnt = await csr_rd(dut, A_ISSUE)

    # ---- checks ----
    if not saw_tile_done:
        fails.append("tu_tile_done never pulsed (GEMM tile did not complete)")
    if 4 not in modes_seen:
        fails.append("live mode never observed as BF16 (modes_seen=%s)" % sorted(modes_seen))
    # TIER-1: issue_en is high for COMPUTE (K) + the accumulate-drain window
    # (ROWS+COLS+1 = 33) that sums the skewed wavefront tail.
    # A1 fix (2026-07-06): was ROWS+COLS-1 = 31; the OS operand recapture stage
    # (tensor_mac_array.sv, removes the negedge-SRAM half-cycle path) adds +1
    # operand latency, so DRAIN_CYCLES_OS grew 31->32 (tensor_tile_controller.sv)
    # and issue_count = K + DRAIN_CYCLES_OS grew correspondingly.
    # §C6 (M3, 2026-07-24): the mac_cell FP feedforward stage adds +1 product
    # latency -> DRAIN_CYCLES_OS 32->33; mirror kept in lockstep (red proof:
    # with the stage but drain at 32, gemm_core fails on exactly cell(15,15),
    # aichip_run_logs/m3_c6_drain_red_20260724.log).
    # [3a-6/P2 2026-08-04] 稀疏臂 drain 已在 RTL 分叉为 35
    # (tensor_tile_controller.sv 的 DRAIN_CYCLES_OS_SPARSE = DRAIN_CYCLES_OS + 1)。
    #   🔴 **本用例是 dense 臂（n_cfg = NCFG_DENSE）⇒ 常数保持 34，一位不动。**
    #      分臂谓词是 **n_cfg**（`D-SPARSE-3A6-PREREQ-2026-08-04` Q2），不是 exec
    #      ⇒ 只有 n_cfg != NCFG_DENSE 的 tile 才走 35。
    #   稀疏臂的对应公式 = `issue_cnt == 发行拍数 + 35`（规格 §6.3；发行拍数在 N=1 上
    #      按同节裁决取 `2⌈K/4⌉−1`）。**本文件不实现它** —— 今天 run_all 里唯一的稀疏
    #      节拍观测点是 `tb/test_tensor_sparse_cadence.py`（读 CSR 0x0c，期望的唯一定义处
    #      = `aichip_run_logs/s3a45_prereg_20260806.md` §4）。
    #   ⇒ 本行既是 dense 判据，也是「drain 分臂没有误伤 dense」的镜像哨兵：
    #      若谓词被写成 exec 或漏了 dense 例外，本行与 R1 八形状会同时红。
    # 🔴 [K1b 2026-08-08] +2 → +3：mac_cell 新增 c6g 缝（lru_out 处流水切分），
    #    DRAIN_CYCLES_OS 34→35（tensor_tile_controller.sv:557）。判据 =
    #    aichip_run_logs/b58k1b_prereg_20260808.md
    DRAIN_ACC = 16 + 16 + 3
    if issue_cnt != K + DRAIN_ACC:
        fails.append("issue_count=%d != K+%d=%d (COMPUTE+accumulate-drain window)"
                     % (issue_cnt, DRAIN_ACC, K + DRAIN_ACC))
    if len(caps) != 16:
        fails.append("egressed %d capsules, expected 16 output rows" % len(caps))

    all_lanes = []
    max_abs = 0
    n_nonzero_lanes = 0
    for ridx in sorted(caps):
        c = caps[ridx]
        if c["escape"] != 0:
            fails.append("row %d: escape asserted (spread/underflow/special)" % ridx)
        if c["status"] & 0x3:       # status_flags[1:0] = {block_inf, block_nan}
            fails.append("row %d: block nan/inf status=0x%02x" % (ridx, c["status"]))
        if c["role"] != 0:          # OP_SRC0
            fails.append("row %d: operand_role=%d (expected OP_SRC0=0)" % (ridx, c["role"]))
        for li, q in enumerate(lanes16(c["payload"])):
            if q < 0:
                fails.append("row %d lane %d: q=%d negative (w*a=+1.0 sum must be >=0)" % (ridx, li, q))
            if q != 0:
                n_nonzero_lanes += 1
            max_abs = max(max_abs, abs(q))
            all_lanes.append((ridx, li, q, c))

    if n_nonzero_lanes == 0:
        fails.append("all egress lanes are zero — the GEMM accumulated nothing")

    # full-scale normalization: the packer puts each row's max magnitude near bit
    # W-2, so the global max |q| should be near full INT16 scale.
    if max_abs and not (2**13 <= max_abs < 2**15):
        fails.append("max |q|=%d not near full INT16 scale [2^13,2^15)" % max_abs)

    # strong numeric check when the scale is E8M0 (full exponent range): every lane
    # decodes to its EXACT integer accumulation count, which must lie in [0,K].
    e8m0_rows = [c for c in caps.values() if c["scale_format"] == SCALE_E8M0]
    if e8m0_rows:
        for (ridx, li, q, c) in all_lanes:
            if c["scale_format"] != SCALE_E8M0:
                continue
            ref_exp = (c["inline_scale"] & 0xFF) - 127     # E8M0 byte -> E_block
            val = q * (2.0 ** ref_exp)
            if abs(val - round(val)) > 1e-6:
                fails.append("row %d lane %d: decoded value %.6f not an integer count" % (ridx, li, val))
                break
            if not (0 <= round(val) <= K):
                fails.append("row %d lane %d: count %d out of [0,%d]" % (ridx, li, round(val), K))
                break
        # OS-skew sanity: row 0 lane 0 (least skew) is the largest count in row 0.
        r0 = caps.get(0)
        if r0 is not None:
            l0 = lanes16(r0["payload"])
            if l0[0] != max(l0):
                fails.append("row0: lane0 (least skew) is not the max count: %s" % l0)

    assert not fails, "tensor GEMM egress failures (%d):\n  %s" % (
        len(fails), "\n  ".join(fails[:20]))

    fmt = "E8M0" if e8m0_rows else "E4M3"
    dut._log.info(
        "tensor GEMM egress: real BF16 GEMM ran (tile_done, issue=%d), egressed %d block16 "
        "capsules (%s), max|q|=%d, %d nonzero lanes; E8M0 lanes decode to exact "
        "integer accumulation counts in [0,K]" % (issue_cnt, len(caps), fmt, max_abs, n_nonzero_lanes))

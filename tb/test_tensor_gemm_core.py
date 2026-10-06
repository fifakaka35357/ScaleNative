"""
cocotb test (HW-REVIEW TIER-1): prove the 16x16 OS array computes a GENERAL GEMM
C[r][c] = sum_k A[r][k]*B[k][c], using NON-UNIFORM operands and the exact
fp_acc-snapshot oracle (Review/Tensor_GEMM_Rewire_Plan.md §4).

Unlike test_tensor_gemm_egress (uniform w=a=+1.0, which BAKES the buggy K-(r+c)
skew count as "expected" and so cannot see the defect), this test drives DISTINCT
A[r][k], B[k][c] so the two confirmed defects are observable per cell:
  (1) weights frozen during COMPUTE  -> cells multiply A by a CONSTANT weight row
  (2) skewed accumulation tail dropped -> each cell sums only K-(r+c) terms.

It taps the PRE-REQUANT fp_acc snapshot bank (all 256 cells, via tb_tensor_gemm_core's
snap_flat) and decodes each with bfp_golden.decode_fp_acc_out, comparing to an
independent Python GEMM golden (bfp_golden.gemm_bf16_golden).

Operand SRAM layout (must match the array boundary + the golden):
  act SRAM row k, lane r = A[r][k]      wgt SRAM row k, lane c = B[k][c]

Expected: RED pre-fix (most cells mismatch), GREEN post-fix (all 256 == golden).
Garbage is loaded into operand rows K..K+PAD-1 so the post-fix tail/zero-pad path
is genuinely exercised (a correct engine must IGNORE indices >= K).

🔴 [3a 步骤 0 / 2026-08-02] 本文件同时是规格 §8.2 R1「dense 逐位不变」的位样本载体。
判据与口径 = Review/R1_Baseline_Criteria_2026-08-02.md（发数前预登记）。三处改动：
  · 形状补齐：K=23/25/26 + 奇 K b2b —— 全仓原有 K 值 {4,8,20,24,64} 全部 %4==0，
    对规格 §6.1/§2.2 的「半切片边界 / per-leg 越界窗口 / b2b 半选相位」三条机理是零覆盖；
  · 自包含：每个 tile 各写自己的 PAD 垃圾行（原 b2b 尾窗吃的是上一个 test 留在
    act_mem/wgt_mem 里的残值 —— 两个 mem 不在任何复位分支里），b2b tileB 基址从
    0x300/0x400（越 SRAM_DEPTH=512 界，靠 Verilator 索引截断才能跑）改到界内；
  · 垃圾值域排除 0（0 会被 mac_zero_detect 的 skip_accumulation 吃掉，使越界窗口
    在数值上不可见）。三条都带「改前=改后逐位相同」的红绿自证，见判据文件 §4。

Run: cd tb && make MODULE=test_tensor_gemm_core TOPLEVEL=tb_tensor_gemm_core \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_core.sv"
"""
import os
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge
from cocotb.utils import get_sim_time
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g
import gemm_operands as go   # 批 4a: 去混叠激励 + 硬闸（见该模块头注）
import snap_baseline as sb   # 3a 步骤 0: R1 位样本 dump/check（默认全关 = no-op）

# MMIO register addresses (tensor_cmd_decoder)
A_CTRL, A_KTOTAL, A_OUTCTRL, A_EPOCH = 0x00, 0x04, 0x0C, 0x10
A_WGT, A_ACT, A_SCL, A_RES = 0x14, 0x18, 0x1C, 0x20
A_STATUS = 0x00

MODE_BF16 = 4
ROWS = COLS = 16
CLK_NS = 10
PAD = 36            # garbage rows beyond K to exercise the zero-pad / tail window
CSR_ADDRS = (0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C)


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


def pack_row(vals):
    """Pack 16 BF16-exact floats into a 256-bit row (lane i in bits [i*16 +: 16])."""
    w = 0
    for i, v in enumerate(vals):
        w |= (g.bf16_bits(float(v)) & 0xFFFF) << (i * 16)
    return w


def snap_cell(snap_int, r, c):
    """Extract the 61-bit fp_acc_output_t snapshot for cell (r,c) from snap_flat."""
    return (snap_int >> ((r * COLS + c) * 61)) & ((1 << 61) - 1)


# ── 垃圾行（越界 dense-k 的 SRAM 内容）—— dense-k 的纯函数，禁按 SRAM 行号定义 ──
# 🔴 值域 [-5,-1] ∪ [1,5]：**排除 0**。mac_zero_detect.sv:49 对 BF16 任一操作数
#    exp==0 会 skip_accumulation ⇒ 垃圾里出现 0 时，"越界窗口被误当有效"这类缺陷
#    在数值上不可见。规格 §6.1/§2.2 落地后越界窗口宽度会从 0 变成 1-3 拍，
#    这些行是那三条机理唯一的可观测载体（判据文件 §4.3 的载体义务）。
def garb_val(x):
    v = (x % 10) - 5            # [-5, 4]
    return v if v < 0 else v + 1  # [-5,-1] ∪ [1,5]


def garb_wgt_row(k):
    """越界 dense-k = k 的权重行：lane c 的值。"""
    return pack_row([garb_val(k * 2 + c) for c in range(COLS)])


def garb_act_row(k):
    """越界 dense-k = k 的激活行：lane r 的值。"""
    return pack_row([garb_val(k * 3 + r) for r in range(ROWS)])


async def load_operands(dut, A, B, K, wgt_base, act_base, pad=PAD):
    """把一个 tile 的操作数 + 它自己的越界垃圾装进 SRAM。

    🔴 每个 tile 必须写**自己的** PAD：act_mem/wgt_mem 不在任何复位分支里
    （tensor_external_modules.sv:361-391），且 cocotb 把同一 MODULE 的多个 test 跑在
    同一仿真进程 ⇒ 不写自 PAD 的 tile，其 drain 尾窗读到的是前序用例的残值，
    基线因此不自包含（新增/重排用例会让已采基线静默作废）。
    """
    for k in range(K):
        await dma_row(dut, "wgt", wgt_base + k, pack_row([B[k][c] for c in range(COLS)]))
    for k in range(K):
        await dma_row(dut, "act", act_base + k, pack_row([A[r][k] for r in range(ROWS)]))
    for k in range(K, K + pad):
        await dma_row(dut, "wgt", wgt_base + k, garb_wgt_row(k))
        await dma_row(dut, "act", act_base + k, garb_act_row(k))
    await FallingEdge(dut.clk)


async def _capture(dut, t0_ns, timeout=700):
    """统一采样锚（判据文件 §3.2）：
    tu_capture_done 高 → **当拍断言 tu_tile_done 同值** → +1 FallingEdge 采样
    → 窗内 +2 拍二次采样（稳定窗恒定的每跑必验实证）。
    返回 (snap, snap_recheck, cycles_start_to_capture)。
    """
    for _ in range(timeout):
        await FallingEdge(dut.clk)
        cd = int(dut.tu_capture_done.value)
        if cd == 1:
            td = int(dut.tu_tile_done.value)
            # tu_capture_done 与 tu_tile_done 今天是同一个布尔式的两个名字
            # (tensor_tile_controller.sv:662/:683 → tensor_unit_top.sv:983-984 纯 assign)。
            # 原代码把两者 OR 起来是【假冗余】；这里改成显式断言，让相对时序一旦被改动就当场红。
            assert td == cd, ("采样锚失效：tu_capture_done=%d 而 tu_tile_done=%d —— "
                              "两者应恒同值" % (cd, td))
            t1 = get_sim_time("ns")
            await FallingEdge(dut.clk)
            snap = int(dut.snap_flat.value)
            for _ in range(2):
                await FallingEdge(dut.clk)
            snap2 = int(dut.snap_flat.value)
            return snap, snap2, int(round((t1 - t0_ns) / float(CLK_NS)))
    return None, None, None


async def _program_and_run(dut, K, EPOCH, WGT, ACT, RES):
    """Program + start one OS BF16 tile (operands pre-loaded), wait for capture."""
    await mmio(dut, [
        (A_CTRL,    MODE_BF16 << 4),            # mode=BF16, dataflow_sel=0 (OS), no start
        (A_KTOTAL,  K),
        (A_OUTCTRL, 0x00),                      # exec_class=NONE, out_class=OUT_FWD_VEC_NATIVE
        (A_EPOCH,   EPOCH),
        (A_WGT,     WGT),
        (A_ACT,     ACT),
        (A_SCL,     0),
        (A_RES,     RES),
        (A_CTRL,    (MODE_BF16 << 4) | 1),      # start pulse, LAST
    ])
    t0 = get_sim_time("ns")
    return await _capture(dut, t0)


async def read_csrs(dut):
    """tile 结束后统一时点读 8 个 status_csr 读口（6 个全仓零读者，而规格 §5.2 要
    重定义 0x08、3a-3/3a-4/3a-6 直接改这些计数器的驱动源 —— 不采就无法把
    「该变的」与「不该变的」分开记账）。读 MUX 是纯组合且带 default，安全。"""
    out = []
    for a in CSR_ADDRS:
        dut.mmio_rd_addr.value = a
        await FallingEdge(dut.clk)
        out.append("0x%02x=0x%08x" % (a, int(dut.mmio_rd_data.value)))
    dut.mmio_rd_addr.value = 0
    return " ".join(out)


def _check_snapshot(snap_int, C_golden):
    bad = []
    for r in range(ROWS):
        for c in range(COLS):
            d = g.decode_fp_acc_out(snap_cell(snap_int, r, c), MODE_BF16)
            if d["is_nan"] or d["is_inf"] or abs(d["value"] - C_golden[r][c]) > 1e-6:
                bad.append((r, c, d["value"], C_golden[r][c]))
    return bad


def _meta(tb, deforder, cycles, K, sa, sb_, EPOCH, WGT, ACT, RES, C_golden, csr=None):
    span = "wgt=0x%03x..0x%03x act=0x%03x..0x%03x" % (
        WGT, WGT + K + PAD - 1, ACT, ACT + K + PAD - 1)
    m = {
        "tb": "test_tensor_gemm_core.py::" + tb,
        "deforder": deforder,
        "anchor": "tu_capture_done_high+1FallingEdge(recheck+2)",
        "cycles": cycles,
        "param": "K=%d saltA=%d saltB=%d PAD=%d EPOCH=0x%02x WGT=0x%03x ACT=0x%03x RES=0x%03x"
                 % (K, sa, sb_, PAD, EPOCH, WGT, ACT, RES),
        "sramspan": span,
        "distinct_golden": len({v for row in C_golden for v in row}),
    }
    if csr is not None:
        m["csr"] = csr
    return m


# ============================================================================
# 1) 主判据（现役）—— K=24
# ============================================================================
@cocotb.test()
async def test_tensor_gemm_core(dut):
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    await reset(dut)

    K = 24
    EPOCH, WGT_BASE, ACT_BASE, RES_BASE = 0x05, 0x020, 0x100, 0x200

    # Non-uniform, BF16-exact small integers. 🔴 批 4a: 改无周期散列构造 —— 旧的
    # ((r+2k)%7) / ((3k+c)%5) 让 A 行重复 11 对、B 列重复 18 对（r±7/±14、c±5/±10/±15），
    # 整类 D 错接对金标不可见（fail-open 第 5 员）。值域不变: A∈[-3,3], B∈[-2,2]。
    # salt 对 (24,50) 由 64x64 搜索得出: 唯一同时满足「金标零 cell = 0」与
    # 「C 行/列两两互异」的解之一（K=24 共 5 组）。零 cell = 0 是变异灵敏度
    # 达 64/64 的充要条件（见 go.assert_no_zero_cells 头注）；两条闸在下面守着它。
    # ── 🔴 批 5 红样本钩（默认全关，门禁路径逐字不变）─────────────────────
    # GEMM_LEGACY_OPERANDS=1 : 用旧的【周期性】构造（A 行以 7、B 列以 5 为周期）
    # GEMM_D_MISWIRE=row|col : 只对【喂给 DUT 的操作数】做一次成对互换
    #                          （行 0<->7 / 列 0<->5），金标仍用未错接的操作数
    #                          ⇒ 精确等价于阵列把两条线接反。
    # 用途 = 补「真 D 错接」的四格红样本：旧激励必绿(fail-open 实证)、新激励必红。
    #        驱动脚本 aichip_run_logs/d_miswire_redsample_20260730.sh
    # 🔴 两个钩任一开启即视为【取证模式】：跳过去混叠/零 cell 两闸（旧激励本就
    #    过不了它们，那正是被取证的对象），并在日志打横幅，防止误当门禁结果。
    #    位样本 dump/check 在取证模式下会硬报错（snap_baseline._forensic_guard）。
    _legacy  = os.environ.get("GEMM_LEGACY_OPERANDS", "0") == "1"
    _miswire = os.environ.get("GEMM_D_MISWIRE", "")
    _forensic = _legacy or bool(_miswire)

    if _legacy:
        A = go.make_A_legacy(K, ROWS)
        B = go.make_B_legacy(K, COLS)
    else:
        A = go.make_A(K, ROWS, salt=24)    # A[r][k] in [-3,3]
        B = go.make_B(K, COLS, salt=50)    # B[k][c] in [-2,2]

    C_golden = g.gemm_bf16_golden(A, B)   # exact ROWS x COLS  (金标 = 未错接的 A,B)

    if _forensic:
        dut._log.warning(
            "=== FORENSIC MODE (非门禁结果) legacy=%s miswire=%r —— 去混叠/零 cell 两闸已跳过 ==="
            % (_legacy, _miswire))
    else:
        go.assert_dealiased(A, B, C_golden, tag="gemm_core")
        go.assert_no_zero_cells(C_golden, tag="gemm_core")

    # 错接只作用在喂 DUT 的副本上
    A_dut, B_dut = A, B
    if _miswire == "row":
        A_dut = go.miswire_swap_rows(A, 0, 7)
    elif _miswire == "col":
        B_dut = go.miswire_swap_cols(B, 0, 5)
    elif _miswire:
        raise AssertionError("GEMM_D_MISWIRE 只接受 row|col，收到 %r" % _miswire)

    # 1) DMA-load operands (+ 本 tile 自己的越界垃圾行).
    #    wgt SRAM row k, lane c = B[k][c]   ;   act SRAM row k, lane r = A[r][k]
    await load_operands(dut, A_dut, B_dut, K, WGT_BASE, ACT_BASE)

    # 2) MMIO start sequence (mode BF16 OS programmed BEFORE the start write) + 3) run.
    dut.egress_ready.value = 1
    snap_int, snap_re, cyc = await _program_and_run(dut, K, EPOCH, WGT_BASE, ACT_BASE, RES_BASE)
    assert snap_int is not None, "tu_capture_done never pulsed (tile did not complete)"

    # 4) decode every cell and compare to the exact golden.
    mismatches = []
    for r in range(ROWS):
        for c in range(COLS):
            d = g.decode_fp_acc_out(snap_cell(snap_int, r, c), MODE_BF16)
            got = d["value"]
            exp = C_golden[r][c]
            if d["is_nan"] or d["is_inf"] or abs(got - exp) > 1e-6:
                mismatches.append((r, c, got, exp))

    if mismatches:
        # 🔴 批 5: 原为 mismatches[:24] 截断打印 —— 于是"61 个失配全落 SE 象限"
        # 这类判断只能靠预测+计数封闭，拿不到穷举实证（审查裁决尾巴②）。改全量。
        msg = "\n  ".join("cell(%2d,%2d): got %.4f  expected %.4f (diff %.4f)"
                          % (r, c, got, exp, got - exp) for (r, c, got, exp) in mismatches)
        raise AssertionError(
            "OS-GEMM snapshot != golden in %d/256 cells (general GEMM not computed):\n  %s"
            % (len(mismatches), msg))

    dut._log.info("OS-GEMM core: all 256 fp_acc snapshots == exact GEMM golden "
                  "(K=%d, non-uniform A/B, garbage-padded tail ignored)" % K)

    # 5) [3a 步骤 0] R1 位样本 —— 只在金标全绿之后记录
    csr = await read_csrs(dut)
    sb.record("r1_dense", "gemm_core_k24", snap_int,
              _meta("test_tensor_gemm_core", 1, cyc, K, 24, 50,
                    EPOCH, WGT_BASE, ACT_BASE, RES_BASE, C_golden, csr),
              snap_int_recheck=snap_re, log=dut._log)


# ============================================================================
# 2) b2b（现役）—— K=20，两块无复位背靠背
# ============================================================================
@cocotb.test()
async def test_tensor_gemm_core_back_to_back(dut):
    """Two consecutive OS-GEMM tiles, NO reset between, DISTINCT non-uniform operands.

    Proves the OS zero-pad tail (32 zero cycles) FLUSHES the depth-31 operand pipeline
    (1 OS recapture stage + depth-30 skew/hop chains) so the second tile is NOT corrupted
    by the first tile's wavefront remnants — the stated back-to-back purpose of the
    zero-pad + accumulate-drain, and the +1-margin (32 zeros vs 31 max depth) concern
    (A1 fix 2026-07-06: was 31 zeros vs 30 depth), neither of which the single-tile test
    exercises
    (HW-REVIEW review finding [9]). egress_ready=1 so each tile's snapshot scans out and
    the bank re-arms for the next tile.

    🔴 [3a 步骤 0] 两处自包含性修复（判据文件 §4）：
      · 两块各写自己的 PAD 垃圾（原来一行 PAD 都不写，tileA 的尾窗读的是
        test_tensor_gemm_core 留在 act_mem/wgt_mem 里的残值）；
      · tileB 基址 0x300/0x400 → 0x0C8：SRAM_DEPTH=512，原值双双越界，
        今天只是靠 Verilator 对 2 的幂维度的索引截断（768→256、1024→0）才「能跑」。
    """
    await tbreset.preclock_reset(dut, rst="rst_n")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    K = 20
    EPOCH, RES = 0x05, 0x200
    WA, AA = 0x020, 0x100          # tile A：0x020..0x057 / 0x100..0x137
    WB, AB = 0x0C8, 0x0C8          # tile B：0x0C8..0x0FF（与 A 不相交、界内）

    # distinct operands per tile (different salt => 两块的激励互不相同)
    # 🔴 批 4a: 同上改无周期构造（旧 A2/B2 的 (2r+k)%7 / (k+2c)%5 同样周期 7/5）。
    # 🔴 批 5: salt 由 tb/salt_search.py 搜出（K=20 在 [0,64)² 内只有 1 组解，
    # 故两块的 salt 取自 224² 搜索的前两组金标互异解）。旧值 1/1 与 2/2 各有
    # 5 / 9 个零 cell（tileB 的 3 个在 SE 象限）—— 零 cell 无法区分"算对了"与
    # "该 cell 卡零"，是 fail-open 第 5 员在 b2b 上的复活。现两块均零 cell = 0，
    # 并各自补挂 assert_no_zero_cells（此前全仓只有 gemm_core 一处挂闸）。
    A1 = go.make_A(K, ROWS, salt=5)
    B1 = go.make_B(K, COLS, salt=41)
    A2 = go.make_A(K, ROWS, salt=19)
    B2 = go.make_B(K, COLS, salt=127)
    G1 = g.gemm_bf16_golden(A1, B1)
    G2 = g.gemm_bf16_golden(A2, B2)
    go.assert_dealiased(A1, B1, G1, tag="gemm_core_b2b/tileA")
    go.assert_dealiased(A2, B2, G2, tag="gemm_core_b2b/tileB")
    go.assert_no_zero_cells(G1, tag="gemm_core_b2b/tileA")
    go.assert_no_zero_cells(G2, tag="gemm_core_b2b/tileB")
    assert G1 != G2, "两块金标相同 → 块间串扰不可观测"

    await load_operands(dut, A1, B1, K, WA, AA)
    await load_operands(dut, A2, B2, K, WB, AB)

    snapA, snapA_re, cycA = await _program_and_run(dut, K, EPOCH, WA, AA, RES)
    snapB, snapB_re, cycB = await _program_and_run(dut, K, EPOCH, WB, AB, RES)
    assert snapA is not None, "tile A did not capture"
    assert snapB is not None, "tile B did not capture (bank may not have re-armed)"

    badA = _check_snapshot(snapA, G1)
    badB = _check_snapshot(snapB, G2)
    assert not badA, "tile A (first) wrong in %d/256 cells: %s" % (len(badA), badA[:8])
    assert not badB, ("tile B (second, back-to-back) wrong in %d/256 cells — the OS "
                      "zero-pad tail did NOT flush the skew/hop chains from tile A: %s"
                      % (len(badB), badB[:8]))
    dut._log.info("OS-GEMM back-to-back: tile A and tile B (no reset, distinct operands) "
                  "BOTH == golden — zero-pad tail flushed the depth-31 pipeline (K=%d)" % K)

    sb.record("r1_dense", "gemm_core_b2b_k20_tileA", snapA,
              _meta("test_tensor_gemm_core_back_to_back", 2, cycA, K, 5, 41,
                    EPOCH, WA, AA, RES, G1),
              snap_int_recheck=snapA_re, log=dut._log)
    sb.record("r1_dense", "gemm_core_b2b_k20_tileB", snapB,
              _meta("test_tensor_gemm_core_back_to_back", 2, cycB, K, 19, 127,
                    EPOCH, WB, AB, RES, G2),
              snap_int_recheck=snapB_re, log=dut._log)


# ============================================================================
# 3) [3a 步骤 0 新增] dense 形状补齐 —— 见判据文件 §2.1/§2.2
#    K=25(%4=1，越界窗口 3 拍) / K=23(%4=3，1 拍) / K=26(%4=2，2 拍) + 奇 K b2b。
#    salt 全部经 assert_dealiased + assert_no_zero_cells 双闸，8 份金标两两互异。
# ============================================================================
async def _dense_shape_case(dut, case, deforder, K, salt_a, salt_b, WGT, ACT):
    """单块 dense tile 的形状用例：装操作数 → 跑 → 逐 cell 对金标 → 记位样本。"""
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    EPOCH, RES = 0x05, 0x200
    A = go.make_A(K, ROWS, salt=salt_a)
    B = go.make_B(K, COLS, salt=salt_b)
    C = g.gemm_bf16_golden(A, B)
    go.assert_dealiased(A, B, C, tag=case)
    go.assert_no_zero_cells(C, tag=case)

    await load_operands(dut, A, B, K, WGT, ACT)
    snap, snap_re, cyc = await _program_and_run(dut, K, EPOCH, WGT, ACT, RES)
    assert snap is not None, "%s: tile did not complete" % case

    bad = _check_snapshot(snap, C)
    assert not bad, ("%s (K=%d, K%%4=%d): %d/256 cell != golden: %s"
                     % (case, K, K % 4, len(bad), bad[:8]))
    dut._log.info("%s: 256/256 == golden (K=%d, K%%4=%d, 越界窗口 %d 拍)"
                  % (case, K, K % 4, (4 - K % 4) % 4))

    csr = await read_csrs(dut)
    sb.record("r1_dense", case, snap,
              _meta(case.replace("gemm_core_", "test_gemm_core_"), deforder, cyc,
                    K, salt_a, salt_b, EPOCH, WGT, ACT, RES, C, csr),
              snap_int_recheck=snap_re, log=dut._log)


@cocotb.test()
async def test_gemm_core_k25(dut):
    """K=25（奇 K，K%4=1 ⇒ §6.1 半切片边界落行内、§4.2 越界窗口 3 拍 = 最宽）。"""
    await _dense_shape_case(dut, "gemm_core_k25", 3, 25, 39, 50, 0x080, 0x080)


@cocotb.test()
async def test_gemm_core_k23(dut):
    """K=23（奇 K，K%4=3 ⇒ 越界窗口 1 拍）。与 k25 组成「同奇 K、窗口 3 vs 1」分因对照。"""
    await _dense_shape_case(dut, "gemm_core_k23", 4, 23, 18, 34, 0x0C0, 0x0C0)


@cocotb.test()
async def test_gemm_core_k26(dut):
    """K=26（偶 K，K%4=2 ⇒ 越界窗口 2 拍）；同时是规格 §8.2 R5「尾窗双真实存活
    N=2, K%4=2」的形状载体。"""
    await _dense_shape_case(dut, "gemm_core_k26", 5, 26, 34, 51, 0x140, 0x140)


@cocotb.test()
async def test_gemm_core_b2b_odd(dut):
    """奇 K 的背靠背（K=25）—— §6.2 act 半选相位的奇偶性唯一载体：
    tile 的 issue 总拍数 = K + DRAIN_CYCLES_OS(35)  # [K1b] 34→35，c6g 缝，其奇偶跟着 K 的奇偶走，
    ⇒ 只有奇 K 的 b2b 才会让第二块从「相反相位」起步。
    同时兑现规格 §8.2 R8 残留状态表里 (J+34) mod N != 0 的那一格。
    """
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, CLK_NS, "ns").start())
    await reset(dut)
    dut.egress_ready.value = 1

    K = 25
    EPOCH, RES = 0x05, 0x200
    WA, AA = 0x180, 0x180          # 0x180..0x1BC
    WB, AB = 0x1C0, 0x1C0          # 0x1C0..0x1FC（与 A 不相交、均 < SRAM_DEPTH=512）

    A1 = go.make_A(K, ROWS, salt=47)
    B1 = go.make_B(K, COLS, salt=28)
    A2 = go.make_A(K, ROWS, salt=55)
    B2 = go.make_B(K, COLS, salt=17)
    G1 = g.gemm_bf16_golden(A1, B1)
    G2 = g.gemm_bf16_golden(A2, B2)
    for (A_, B_, C_, t) in ((A1, B1, G1, "b2b_odd/tileA"), (A2, B2, G2, "b2b_odd/tileB")):
        go.assert_dealiased(A_, B_, C_, tag=t)
        go.assert_no_zero_cells(C_, tag=t)
    assert G1 != G2, "两块金标相同 → 块间串扰不可观测"

    await load_operands(dut, A1, B1, K, WA, AA)
    await load_operands(dut, A2, B2, K, WB, AB)

    snapA, snapA_re, cycA = await _program_and_run(dut, K, EPOCH, WA, AA, RES)
    snapB, snapB_re, cycB = await _program_and_run(dut, K, EPOCH, WB, AB, RES)
    assert snapA is not None, "b2b_odd tile A did not capture"
    assert snapB is not None, "b2b_odd tile B did not capture"

    badA = _check_snapshot(snapA, G1)
    badB = _check_snapshot(snapB, G2)
    assert not badA, "b2b_odd tile A wrong in %d/256 cells: %s" % (len(badA), badA[:8])
    assert not badB, ("b2b_odd tile B (奇 K 背靠背) wrong in %d/256 cells: %s"
                      % (len(badB), badB[:8]))
    dut._log.info("OS-GEMM b2b odd-K: tileA/tileB 均 256/256 == golden (K=%d)" % K)

    sb.record("r1_dense", "gemm_core_b2b_k25_tileA", snapA,
              _meta("test_gemm_core_b2b_odd", 6, cycA, K, 47, 28, EPOCH, WA, AA, RES, G1),
              snap_int_recheck=snapA_re, log=dut._log)
    sb.record("r1_dense", "gemm_core_b2b_k25_tileB", snapB,
              _meta("test_gemm_core_b2b_odd", 6, cycB, K, 55, 17, EPOCH, WB, AB, RES, G2),
              snap_int_recheck=snapB_re, log=dut._log)

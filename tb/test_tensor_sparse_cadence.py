"""test_tensor_sparse_cadence.py —— N=2（2:4）合法 cadence 载体（戊案 v2 · M5′ 入册，M6′ 翻值）。

🔴 **本载体只验节拍（cadence），不验数值。** 见下方「为什么数值必错」。

===========================================================================
## 这个载体是干什么的（读之前先看懂这一段，否则会误用它的绿）

它是本片**第一个走合法 N:M 配置**（`n_cfg = NCFG_2OF4`，N=2）的**正式**用例
（`test_` 前缀 ⇒ 进 `run_all.py:20` 的 glob，分母 179+3 = **182**、文件 56+1 = **57**）。

    发              | K  | ⌈K/4⌉ | Kp | M5′（已取代） | M6′（已取代） | **3a-6（现役）**
    sparse_n2_k23   | 23 |   6   | 24 | 0x3a / 78     | 0x2e / 66     | **0x2f / 67**
    sparse_n2_k24   | 24 |   6   | 24 | 0x3a / 78     | 0x2e / 66     | **0x2f / 67**
    sparse_n2_k25   | 25 |   7   | 28 | 0x3e / 82     | 0x30 / 68     | **0x31 / 69**

    三级的机构各不相同，别混为一谈：
      M5′  = C2 白名单臂放宽（n_cfg 抵达 controller）        ⇒ 读 `Kp + 34`
      M6′  = `k_step` 重写为 `4/N`（n_cfg 进入节拍数据通路） ⇒ 读 `⌈K/4⌉×2 + 34`
      3a-6 = **drain 稀疏臂 34 → 35**（分臂谓词 = n_cfg）    ⇒ 读 `⌈K/4⌉×2 + 35`

**M5′ 侧算术**：`k_step` 尚未重写（`tensor_tile_controller.sv` 两臂逐字均为
`k_step = {8'd0, pack_advance_q}`，BF16 走 `dense_pack_advance` 的 `default: 8'd1`）
⇒ COMPUTE 拍数 = `k_total_pad = Kp`（M4 已落）⇒ 读 `Kp + DRAIN_CYCLES_OS(35)  # [K1b] 34→35，c6g 缝`。
**M6′ 侧算术**：规格 §6.3「发行拍数 = ⌈K/4⌉ × N × (N==1 ? 2 : 1)」，N=2 ⇒ `⌈K/4⌉×2`。
**3a-6 侧算术**：同上，只是 drain 由 34 换成稀疏臂的 **35**（规格 §6.3 `issue_cnt == 发行拍数 + 35`）。

### M5′ 那一级的绿【不承载「n_cfg 已被消费」】（历史，保留以免后人误引）
~~M5′ 列的三个数与 M4 的 N=4 探针在同样的 K 上逐字相同 —— 因为 `k_step` 还没重写，
COMPUTE 拍数与 N 无关 ⇒ 与「n_cfg 恒 0 死链」在数值上不可区分。~~
M5′ 的正证是**红→绿样本对**（放宽前三发 `%Fatal ... n_cfg=NCFG_2OF4 unsupported`，
报文逐字点名该编码 ⇒ n_cfg 确实抵达 controller）+ **P3/P4 三锚仍红**（守备面是收窄不是拆除）。
红证 = `aichip_run_logs/s3a45_m5p_carrier_red_k{23,24,25}_20260806.log`。

### ▲**[M6′ 现役]** n_cfg 已进入数据通路 —— 但**只到节拍层**
M6′ 把 `k_step` 重写为 `4/N` 之后，本载体三发**当场翻值** `0x3a/0x3a/0x3e → 0x2e/0x2e/0x30`
（`s3a45_m6p_carrier_20260806.log`），而 **N=4 探针期望逐字不变**（`s3a45_m6p_padprobe_20260806.log`）
—— 两条方向相反 ⇒ 「`n_cfg` 被数据通路消费」在**节拍层**成立。
▲**[3a-6/P2 2026-08-04] 同款双守门再来一次**：drain 稀疏臂 34→35 让本载体三发**再翻 +1**
（`0x2e/0x2e/0x30 → 0x2f/0x2f/0x31`），而 N=4 探针期望**仍然逐字不变** —— 因为 drain 分臂谓词
取 `n_cfg`（Q2 拍板），探针那一发是 `exec=SPARSE ∧ n_cfg=DENSE` ⇒ 走 dense 的 34。
🔴 **两条方向相反、且这次是【同一个常数】同时决定的** ⇒ 谓词若被写成 exec，探针当场红。
🔴 **仍然不许说的话**：这**不**证明 `4/N` 这个值对应正确的压实布局，也**不**证明任何数值 ——
数值 oracle 归 **3c R5**（本载体连 cell-exact 断言都没有）。

## 🔴 为什么本载体「数值必错」（设计内的、已登记的真空，不是缺陷）

N=2 下权重腿上界 = `⌈K/4⌉ × N`（`tensor_external_modules.sv`，M4 落）：
K=23 ⇒ `6×2 = 12`，**远小于 K** ⇒ 权重行 12..22 被 `wgt_zero_pad` 强零
⇒ 结果与 dense 金标不等。真 N:M 数值 oracle 归 **3c 的 R5**。
⇒ **本文件不得含任何 cell-exact 数值断言，也不调 `_check_snapshot`。**
（这不是"懒得写"：写一个对不上的金标比对，只会逼后人把闸改松。）

## 配置逐字钉死（预登记 `aichip_run_logs/s3a45_prereg_20260806.md` §4）

    0x08 = 0x09        ⇒ [1:0]=01 = EXEC_SPARSE_STRUCT（M2 已放宽 C1 白名单）
                         [3:2]=10 = NCFG_2OF4（M5′ 放宽 C2 白名单；此前撞臂 $fatal）
    dataflow_sel = 0   ⇒ A_CTRL bit8 = 0（OS）。**判据里 assert**，不靠自觉
    MODE_BF16          ⇒ CSR 0x00 读回 0x00000022。**判据级 assert**
    pad = 40           ⇒ 垃圾行需求 = Kp−K+34，K∈{23,24,25} 上取 {35,34,37}，最大 37 ≤ 40
                         🔴 **传形参，不动 `T.PAD`**（T.PAD 是 R1 的冻结口径）

## 四条禁令（预登记 §4）

1. **禁进** `tb/snap_baseline.py` 的 `EXPECTED_CASES["r1_dense"]`（会动 `CONSUMED × 8/8` 这个判据数）
2. **禁调** `snap_baseline`
3. **禁写** `tb/baseline/`
4. **禁写进** `tb/test_tensor_gemm_core.py` 本体（其 sha256 是 R1 的口径锚）

## M6′ 的纪律

🔴 **M6′ 的 commit 只许改常数不许改口径** —— 上表两侧期望在 M0 就已双侧落盘。
跑完再改任何一侧，就退回「期望值跟着实现一起改」的自指（戊案 §3-2 批评旧规划的正是这件事）。
M6′ 那天要改的只有 `EXPECT` 这一个 dict 的三个值，判据代码一行不动。

Run: cd tb && make MODULE=test_tensor_sparse_cadence TOPLEVEL=tb_tensor_gemm_core \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_core.sv"

判读（🔴 判读串必须**行首锚定**，否则会被本 docstring 的 cocotb 回显命中 —— M2 实付一次）:
    grep -cE '^\[[0-9]+\] %(Fatal|Error):' <log>   # 绿样本 == 0
    grep -oE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' <log>   # TESTS=3 PASS=3 FAIL=0
===========================================================================
"""
import sys, os
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.utils import get_sim_time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gemm_operands as go
import test_tensor_gemm_core as T

ROWS = COLS = 16
A_SPARSE = 0x08
SPARSE_N2 = 0x09               # [1:0]=01 EXEC_SPARSE_STRUCT, [3:2]=10 NCFG_2OF4
CARRIER_PAD = 40               # 见头注；🔴 传形参，不动 T.PAD
MODE_BF16_CSR = 0x00000022     # CSR 0x00 读回值（mode=BF16 的判据级 assert）

# K -> (salt_a, salt_b, WGT_base, ACT_base)。与 R1 用例同源，但本载体**不比数值**，
# salt 只用来避免全零激励（全零会让「跑完了」和「什么都没算」不可区分）。
SHAPES = {
    23: (18, 34, 0x0C0, 0x0C0),
    24: (24, 50, 0x020, 0x100),
    25: (39, 50, 0x080, 0x080),
}

# ~~现役期望 = 预登记 §4 的 M5′ 列：{23: (0x3a, 78), 24: (0x3a, 78), 25: (0x3e, 82)}~~
#   ▲**[3a-5/M6′ 2026-08-03] 已翻值**（原值划掉保留，M5′ 实测在
#   `aichip_run_logs/s3a45_m5p_carrier_green_20260806.log`）。
# ~~现役期望 = 预登记 §4 的 **M6′ 列**：{23: (0x2e, 66), 24: (0x2e, 66), 25: (0x30, 68)}~~
#   ▲**[3a-6/P2 2026-08-04] 第二次翻值**（原值划掉保留，M6′ 实测在
#   `aichip_run_logs/s3a45_m6p_carrier_20260806.log`）。
#
# 现役期望 = 预登记 §4 的 **3a-6 列**（drain 稀疏臂 34 → **35**）。
#   🔴 **翻值量恰 +1，三发同向**：`0x2e→0x2f` ×2、`0x30→0x31`，`start_to_capture` 同 +1。
#   🔴 **这三个数在 M0 就已预登记**（`s3a45_prereg_20260806.md` §8 的翻写义务，逐字写死
#      「0x2e→0x2f、0x2e→0x2f、0x30→0x31，start_to_capture 同 +1」）
#      ⇒ 不是「跑完照着实测填」。**本次仍然只改下面这三个常数，判据代码一行未动。**
#   🔴 **反方向的守门 = N=4 恒等点探针期望【逐字不变】**（`tb/scratch_pad_probe.py`）：
#      drain 分臂谓词取 n_cfg（`D-SPARSE-3A6-PREREQ-2026-08-04` Q2）⇒ 探针那一发
#      （`exec=SPARSE ∧ n_cfg=DENSE`）仍走 34。**两条方向相反，缺一条另一条就是空集绿。**
# ~~3a-6 现役期望 {23:(0x2f,67), 24:(0x2f,67), 25:(0x31,69)}~~
#   ▲🔴**[K1b 2026-08-08] 第三次翻值**（原值划掉保留）：mac_cell 在 lru_out 新增 c6g 缝
#     ⇒ `DRAIN_CYCLES_OS` 34→35，稀疏臂 `= OS+1` 自动 35→36。判据 =
#     `aichip_run_logs/b58k1b_prereg_20260808.md`（R-6 预登记为回归项）。
#   🔴 新值是**按公式推导**得到、再拿实测印证的（不是「跑完照着实测填」）：
#     N=2: ⌈K/4⌉×2+36 ⇒ 48/48/50 = 0x30/0x30/0x32；N=1: (2⌈K/4⌉−1)+36 ⇒ 47/47/49。
#     `start_to_capture` 同 +1（沿用 3a-6 那次「drain +1 ⇒ 三级同向 +1」的先例）。
#   🔴 **反方向守门同样要跟**：`tb/scratch_pad_probe.py` 的 N=4 探针走 **dense** 臂，
#     本刀把 dense 也 34→35 ⇒ 那条期望**必须一起改**，否则两条方向相反的守门缺一条。
EXPECT = {23: (0x30, 68), 24: (0x30, 68), 25: (0x32, 70)}


def _csr(csr_str, addr):
    """从 T.read_csrs 的返回串里取某个读口的整数值。找不到 ⇒ 抛错，不返回默认值。"""
    key = "0x%02x=" % addr
    for tok in csr_str.split():
        if tok.startswith(key):
            return int(tok[len(key):], 16)
    raise AssertionError("CSR 读口 %s 不在返回串里: %s" % (key, csr_str))


async def _cadence_shot(dut, K):
    """跑一个 N=2 tile，只判 cadence。🔴 不做任何 cell-exact 数值断言（见头注）。"""
    tag = "sparse_n2_k%d" % K
    exp_csr, exp_cyc = EXPECT[K]
    sa, sb_, WGT, ACT = SHAPES[K]

    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)
    dut.egress_ready.value = 1

    EPOCH, RES = 0x05, 0x200
    A = go.make_A(K, ROWS, salt=sa)
    B = go.make_B(K, COLS, salt=sb_)
    # 🔴 pad=CARRIER_PAD 走形参；T.PAD 一个字不动
    await T.load_operands(dut, A, B, K, WGT, ACT, pad=CARRIER_PAD)

    # ---- 钉死 OS（dataflow_sel = A_CTRL bit8 = 0）----
    #   ① 构造侧 assert：本发写出去的 A_CTRL 字，bit8 必须是 0；
    #   ② 机器级兜底 = M2 落的 C1-b WS 绊线（tensor_mac_array 的
    #      `!(dataflow_sel && (sparse_exec_mode != EXEC_DENSE))`，$fatal 级）——
    #      本发只要 dataflow_sel 是 1 就当场 %Fatal(WS-GUARD)
    #      ⇒ **本发能跑完这件事本身，就是 dataflow_sel==0 的机器证据**。
    ctrl = T.MODE_BF16 << 4
    assert ((ctrl >> 8) & 1) == 0, (
        "%s: A_CTRL bit8 != 0 —— 必须钉死 OS（WS 下两条 *_zero_pad 都被 dataflow_sel==0 门掉）" % tag)

    seq = [(T.A_CTRL, ctrl), (T.A_KTOTAL, K), (A_SPARSE, SPARSE_N2),
           (T.A_OUTCTRL, 0x00), (T.A_EPOCH, EPOCH), (T.A_WGT, WGT),
           (T.A_ACT, ACT), (T.A_SCL, 0), (T.A_RES, RES),
           (T.A_CTRL, ctrl | 1)]
    await T.mmio(dut, seq)

    t0 = get_sim_time("ns")
    snap, snap_re, cyc = await T._capture(dut, t0)
    assert snap is not None, "%s: tile 未收官（超时）" % tag
    assert snap == snap_re, "%s: 采样窗内二次采样不稳（snap != snap_recheck）" % tag

    csr = await T.read_csrs(dut)
    assert _csr(csr, 0x00) == MODE_BF16_CSR, (
        "%s: CSR 0x00 读回 0x%08x ≠ 0x%08x（MODE_BF16 未钉住）"
        % (tag, _csr(csr, 0x00), MODE_BF16_CSR))

    c0c, c10 = _csr(csr, 0x0C), _csr(csr, 0x10)
    dut._log.info("PAD-CADENCE %s: 0x0c=0x%08x expect=0x%02x" % (tag, c0c, exp_csr))
    assert c0c == exp_csr, (
        "PAD-CADENCE %s: 0x0c=0x%08x expect=0x%02x —— 3a-6 现役期望 ⌈K/4⌉×2+36"
        "（k_step 已重写为 4/N，且 drain 稀疏臂已分叉到 36（K1b 后 = dense 35 + 权重滞后 1），分臂谓词 = n_cfg）。"
        "🔴 红因路由（按读到的值查，别乱猜）："
        "读到 ⌈K/4⌉×2+35（0x2f/0x2f/0x31）⇒ **drain 稀疏臂没生效** —— 首查 controller 的"
        "  drain_limit 与 drain_limit_d_v 两处是否都分叉、谓词是不是被写成了 exec；"
        "读到 Kp+35 或 Kp+34（0x3b/0x3b/0x3f 或 0x3a/0x3a/0x3e）⇒ k_step 重写【被回退】"
        "  （首查 cursor 推进的两处是否还在消费 k_step）；"
        "读到 K+34 / K+35 ⇒ M4 的 pad 臂被回改了"
        % (tag, c0c, exp_csr))
    assert c10 == exp_csr, "PAD-CADENCE %s: 0x10=0x%08x expect=0x%02x" % (tag, c10, exp_csr)
    assert cyc == exp_cyc, "PAD-CADENCE %s: start_to_capture=%d expect=%d" % (tag, cyc, exp_cyc)
    dut._log.info("PAD-CADENCE %s: ✅ cadence=0x%02x/%d（🔴 只证节拍，不证 n_cfg 已被消费）"
                  % (tag, exp_csr, exp_cyc))


@cocotb.test()
async def sparse_n2_k23(dut):
    """K=23, N=2。**3a-6 现役期望 0x0c=0x10=0x2f、start_to_capture=67**（⌈K/4⌉×2 = 12 ⇒ 12+35）。

    ~~M5′ 期望 0x3a / 78（Kp+34）~~ → ~~M6′ 期望 0x2e / 66（⌈K/4⌉×2+34）~~ —— 两次翻值均已被取代。
    实测留档：M5′ `aichip_run_logs/s3a45_m5p_carrier_green_20260806.log`、
    M6′ `aichip_run_logs/s3a45_m6p_carrier_20260806.log`。
    """
    await _cadence_shot(dut, 23)


@cocotb.test()
async def sparse_n2_k24(dut):
    """K=24, N=2。**3a-6 现役期望 0x2f/67**（~~M6′ 0x2e/66~~、~~M5′ 0x3a/78~~）。
    K%4==0 一发（裁决 §5 的 L2-5 残值）。

    🔴 K=24 与 K=23 三级都同值（⌈23/4⌉ = ⌈24/4⌉ = 6，且 Kp 相同）—— 是同一个原因，不是新简并。
    """
    await _cadence_shot(dut, 24)


@cocotb.test()
async def sparse_n2_k25(dut):
    """K=25, N=2。**3a-6 现役期望 0x31/69**（⌈25/4⌉×2 = 14 ⇒ 14+35；~~M6′ 0x30/68~~、~~M5′ 0x3e/82~~）。

    ⌈K/4⌉ 由 6 跳到 7 的唯一一发 ⇒ 它是三发里唯一能把「⌈K/4⌉ 算错」与「步长算错」分开的格。
    """
    await _cadence_shot(dut, 25)

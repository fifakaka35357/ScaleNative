"""retired_scratch_pad_probe.py —— N=4 恒等点探针【已于 M7 退役归档，非现役】。

===========================================================================
# 🔴🔴 退役声明（戊案 v2 · M7，2026-08-03）—— 读这段再决定要不要复活它

**它不再是任何一条闸的一部分。** 退役是预登记动作（`s3a45_prereg_20260806.md` §3
逐字「退役 = M7 的唯一动作」），不是因为它坏了或过时了。

## 🔴 本次是【真的失去一条守门】，不是「从来就没有」

退役先例（`Review/R1_Baseline_Criteria_2026-08-02.md` §2.3a）立过一条纪律：
**退役时必须写清自己属于哪一种**，否则「读起来像是从有守门退化成无守门」。
那一次是「**从来就没有**」（该 case 自入库起从未被任何执行件消费过）。
**本次相反 —— 它在四级里都是活守门**：

| 级 | 它守的是什么 | 实测落盘 |
|---|---|---|
| M3 | 活体基线：pad 未落 ⇒ 四发必读 dense 值 `0x39/0x3a/0x3b/0x3c` | `aichip_run_logs/s3a45_m3_probe_20260806.log` |
| M4 | **当场翻值** `0x3a/0x3a/0x3e/0x3e`，翻值量恰 `Kp−K`；k24 半格恒等正控不许翻 | `s3a45_m4_probe_20260806.log` |
| M5′ | C2 放宽后的回归：期望**逐字不变** | `s3a45_m5p_padprobe_regress_20260806.log` |
| M6′ | **相位不变量**（双守门之一，与载体方向相反）：N=4 零气泡行 ⇒ 期望逐字不变 | `s3a45_m6p_padprobe_20260806.log` |

⇒ **退役之后，N=4 恒等点没有任何常设回归守门。** 这是退役的**代价**，不是它没价值。
🔴 代价的归属已排进 `Review/Stage3a45_Fusion_BuildSheet_2026-08-06.md` §3 的「3a-6 剩」清单
（**复活义务**）：3a-6 一旦触碰 DRAIN 常数 / 相位 / `k_step` 的任何一处，**必须先复活它**
再改，否则「N=4 没被顺手改动」这件事在那一片将无人守。

## 复活命令（一行，改回名字即可 —— 内容一个字都不用动）

    git mv tb/retired_scratch_pad_probe.py tb/scratch_pad_probe.py
    cd tb && VS=$(python3 -c "import re;print(' '.join(re.search(r'VERILOG_SOURCES=\"(.*?)\"',
         open('test_tensor_gemm_core.py').read(), re.S).group(1).replace(chr(92),' ').split()))")
    make -s clean && make -s MODULE=scratch_pad_probe TOPLEVEL=tb_tensor_gemm_core VERILOG_SOURCES="$VS"

## 退役对三闸分母的影响 = **零**

`scratch_` 与 `retired_` 两个前缀**都**出 `run_all.py:20` 的 `glob("test_*.py")`，
也不在 `elaborate_smoke.sh` 的靶里 ⇒ 分母恒为 `39 / 57 / 182`，改名前后一致（M7 已实测复核）。

## 🔴 复活时必须一并读的两条账（M6′ 后审挖出，见 BuildSheet §3 第 5/6 条）

1. **CURSOR MONOTONICITY SVA 的气泡口** —— N=1 的 `{4,0}` 气泡拍会让它每拍 `$error`；
   放宽 C2 到含 `NCFG_1OF4` 的同一次改动里必须一并处理。
2. **N=1 发行拍数三方对账** —— 实现给 `2⌈K/4⌉−1`、规格 §6.3 给 `2⌈K/4⌉`，差 1 拍。
   **必须在预登记 N=1 期望数之前裁决。**

===========================================================================
（以下为退役前原文，一个字未改，供复活时直接用）
===========================================================================

scratch_pad_probe.py —— N=4 恒等点探针（戊案 v2 · M3 上，M4 翻值，M7 退役）。

`scratch_` 前缀 ⇒ **不落 `run_all.py:20` 的 `glob("test_*.py")`**，三闸分母 ±0。

===========================================================================
## 这个探针是干什么的（读之前先看懂这一段，否则会误用它的绿）

戊案 v2 的**活体基线**增强：同一个探针、同一份配置，在**两个相邻的 M 级**读到**两组不同的数**。

| 级 | 稀疏臂的状态 | 探针应读到 |
|---|---|---|
| **M3**（已收口，log `s3a45_m3_probe_20260806.log`） | A 组 pad 臂**尚未落**，稀疏臂是 3a-1 S3 的**逐字 dense 占位** | **dense 值** `K+34` |
| **M4（本级，现役判据）** | pad 算术落地（`k_total_pad = ⌈K/4⌉×4`） | **翻值** `Kp+34` |

🔴 **载具名冻结在 M3**（`m3_dense_k*` / `m3_sparse_k*`，不随级改名）——
两级的 log 必须逐行可比，改名会当场废掉「同一探针、同一配置、两级两组数」这条证据链。

    K   | M3 期望（已收口）  | **M4 期望（现役，翻值）** | Kp−K
    23  | 0x39 / 77          | 0x3a / 78                 | +1
    24  | 0x3a / 78          | 0x3a / 78  🔴 **不许翻**   |  0   ← 半格恒等正控
    25  | 0x3b / 79          | 0x3e / 82                 | +3
    26  | 0x3c / 80          | 0x3e / 82                 | +2

**k24 那一格是正控**：`Kp(24)=24` ⇒ 两级同值。它是唯一能抓住
`((K+4)>>2)<<2` / `(K&~3)+4` 两类 pad 公式手滑的格（这两个错式只在 `K%4==0` 上与正确式分叉）。

~~🔴🔴 **本级（M3）的绿【不承载证明力】，别误用**：「读到 dense 值」与「探针根本没进
稀疏臂」在数值上不可区分 …… 本级不含载体在场证。~~
▲**[M4] 上段已兑现**（原文划掉保留）：本级三格**当场翻值**（23/25/26 各 +Kp−K，
k24 恒同），且判据 C 是**相对同一次运行里的活体 dense 发**判的 ⇒ 「探针没进稀疏臂」
这个假设在本级会被 23/25/26 三格当场证伪。载体在场证的另一半 = M4 的 mutation 3a/3b/3c
（只 mutate 稀疏臂，载体没进去则一发都红不起来）。

🔴 **仍然不许说的话（本级的绿【不】包含这些）**：
「稀疏执行数值已验证」（N=4 恒等点 ≡ dense，真 N:M 数值 oracle 归 3c R5）·
「权重腿上界已验证」（N=4 下 `⌈K/4⌉×4 = Kp`，act 腿已强零 ⇒ 落地未通电，真消费者是 M5′ 的 N=2）·
「相位已验证」（`{4,0}` 归 M6′）。

## 配置逐字钉死（预登记 `aichip_run_logs/s3a45_prereg_20260806.md` §3）

    0x08 = 0x01        ⇒ exec = EXEC_SPARSE_STRUCT, n_cfg = NCFG_DENSE
                         （M2 已放宽 C1 白名单 ⇒ 该组合可达、不再 $fatal；
                           n_cfg 必须是 DENSE，否则撞 tensor_tile_controller 的 C2 臂）
    dataflow_sel = 0   ⇒ A_CTRL bit8 = 0（OS）。**判据里 assert**，不靠自觉
                         （WS 下两条 *_zero_pad 都被 dataflow_sel==0 门掉，D3 敞口）
    MODE_BF16          ⇒ CSR 0x00 读回 0x00000022。**判据级 assert**
    pad = 40           ⇒ 稀疏垃圾行需求 = Kp−K+34，K∈{23,24,25,26} 上取 {35,34,37,36}，最大 37 ≤ 40
                         🔴 **传形参，不动 `T.PAD`**（T.PAD=36 是 R1 的冻结口径）

## 判据（三类，缺一类其余就是空集绿）

**A · cadence 查表**：`0x0c == 0x10 ==` 预登记值 **且** `start_to_capture ==` 预登记值。
   报文规格（可 grep）：`PAD-CADENCE <case>: 0x0c=<got> expect=<hex>`
**B · 数值双通道**：
   ① 对 `Model/bfp_golden.py` 的 **dense** 金标 256 cell 比对（`T._check_snapshot`，1e-6 容差）
   ② **同 K 的 sparse 发与 dense 发的 `snap_flat` 整数逐位相等** —— 后者才配「逐位」二字
   （容差通道会掩盖低位差异；整数相等不会）
   🔴 M4 起本类同时是 **pad 拍数值惰性**的判据（多跑的 Kp−K 拍 act 被强零 ⇒ 结果必须不变）
**C · 相对活体基线的翻值**（**M4 新增**）：`(0x0c, 0x10, cycles)` 相对**同一次运行里**同 K 的
   dense 发，必须恰好各 +（Kp−K）；k24 的 Kp−K=0 ⇒ 必须**三元组恒同**。
   比 A 强一级：不依赖 R1 基线文件，且抓得住「sparse 与 dense 一起漂」这种 A 看不见的失效。

## 三条禁令（预登记 §3）

1. **禁进** `tb/snap_baseline.py` 的 `EXPECTED_CASES["r1_dense"]`（会动 `CONSUMED × 8/8` 这个判据数）
2. **禁调** `snap_baseline`、**禁写** `tb/baseline/`
3. **禁写进** `tb/test_tensor_gemm_core.py` 本体（其 sha256 是 R1 的口径锚）

## 退役

🔴 **退役归档 = M7 的唯一动作**，不得随 M5′ 的合法载体入册一并退役 ——
M6′（`{4,0}` 相位 + k_step 重写）仍需本探针当 **N=4 相位不变量**：
N=4 零气泡行 ⇒ `⌈K/4⌉×4 = Kp`、drain 34 不动 ⇒ 期望**逐字不变**。

Run（一次 make 即可：本级无 `$fatal` 期望，8 发可同跑）:
    cd tb
    VS=$(python3 -c "import re;print(' '.join(re.search(r'VERILOG_SOURCES=\"(.*?)\"',
         open('test_tensor_gemm_core.py').read(), re.S).group(1).replace(chr(92),' ').split()))")
    make -s clean
    make -s MODULE=scratch_pad_probe TOPLEVEL=tb_tensor_gemm_core VERILOG_SOURCES="$VS" \
         > ../../aichip_run_logs/s3a45_m4_probe_<date>.log 2>&1

判读（🔴 判读串必须**行首锚定**，否则会被本 docstring 的 cocotb 回显命中 —— M2 实付一次）:
    grep -cE '^\[[0-9]+\] %(Fatal|Error):' <log>   # == 0
    grep -oE 'TESTS=[0-9]+ PASS=[0-9]+ FAIL=[0-9]+ SKIP=[0-9]+' <log>   # TESTS=8 PASS=8 FAIL=0
===========================================================================
"""
import sys, os
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
from cocotb.utils import get_sim_time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g
import gemm_operands as go
import test_tensor_gemm_core as T

ROWS = COLS = 16
A_SPARSE = 0x08
EXEC_SPARSE_STRUCT = 0x01      # 0x08[1:0]=01, [3:2]=00(NCFG_DENSE)
PROBE_PAD = 40                 # 见头注；🔴 传形参，不动 T.PAD
MODE_BF16_CSR = 0x00000022     # CSR 0x00 读回值（mode=BF16 的判据级 assert）

# K -> (salt_a, salt_b, WGT_base, ACT_base)  —— 与 R1 现役用例逐字相同
SHAPES = {
    23: (18, 34, 0x0C0, 0x0C0),
    24: (24, 50, 0x020, 0x100),
    25: (39, 50, 0x080, 0x080),
    26: (34, 51, 0x140, 0x140),
}

# ~~M3 期望（= 预登记 §3 的 M3 列；dense 活体基线，pad 未落）~~
#   ▲**已被 M4_EXPECT 取代**（2026-08-03，M4 落 pad 算术）。**保留不删**：它是活体基线的
#   历史记录，也是「同一探针两级读两组数」这条证据链的另一半。M3 实测 8/8 在
#   aichip_run_logs/s3a45_m3_probe_20260806.log。
M3_EXPECT = {23: (0x39, 77), 24: (0x3a, 78), 25: (0x3b, 79), 26: (0x3c, 80)}

# M4 期望（= 预登记 §3 的 **M4 列**；pad 落地 ⇒ 翻值）。🔴 现役判据是本表。
# ~~M4 期望（Kp+34）{23:(0x3a,78), 24:(0x3a,78), 25:(0x3e,82), 26:(0x3e,82)}~~
#   ▲🔴**[K1b 2026-08-08] 翻值**：mac_cell 在 lru_out 新增 c6g 缝 ⇒ `DRAIN_CYCLES_OS`
#     **34→35**（tensor_tile_controller.sv:557）。本探针这 4 发是 `exec=SPARSE ∧ n_cfg=DENSE`
#     ⇒ 走 **dense** 臂 ⇒ 期望 = **Kp+35**。判据 = `aichip_run_logs/b58k1b_prereg_20260808.md`。
#   🔴 这正是本探针存在的理由（M6′ 注册的「两条方向相反的守门」）：载体那条查稀疏臂
#     36、本条查 dense 臂 35 —— **只改一条会被另一条当场抓住**。本次两条同向 +1 = 两臂
#     都吃到 K1b 的 +1，臂间差（权重滞后 L(n_cfg)=1）保持不变，符合设计。
#   🔴 新值按公式推导（Kp+35），再由实测印证，不是照着实测填：
#     K=23/24 ⇒ Kp=24 ⇒ 59=0x3b；K=25/26 ⇒ Kp=28 ⇒ 63=0x3f；start_to_capture 同 +1。
M4_EXPECT = {23: (0x3b, 79), 24: (0x3b, 79), 25: (0x3f, 83), 26: (0x3f, 83)}

EXPECT = M4_EXPECT          # 现役级 = M4
KP = {K: ((K + 3) // 4) * 4 for K in SHAPES}     # Kp = ⌈K/4⌉×4（判据侧独立算，不读 RTL）

# dense 发的结果暂存，供同 K 的 sparse 发做通道② 逐位比对。
# 🔴 缺伙伴时判 INVALID 而不是跳过（§5.0d 型 3：空集不得冒充通过）。
_DENSE = {}


def _csr(csr_str, addr):
    """从 T.read_csrs 的返回串里取某个读口的整数值。找不到 ⇒ 抛错，不返回默认值。"""
    key = "0x%02x=" % addr
    for tok in csr_str.split():
        if tok.startswith(key):
            return int(tok[len(key):], 16)
    raise AssertionError("CSR 读口 %s 不在返回串里: %s" % (key, csr_str))


async def _one_tile(dut, K, sparse, tag):
    """跑一个 tile，返回 (snap, cycles, csr_str, C_golden)。sparse=True 时注入 0x08=0x01。"""
    sa, sb_, WGT, ACT = SHAPES[K]
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)
    dut.egress_ready.value = 1

    EPOCH, RES = 0x05, 0x200
    A = go.make_A(K, ROWS, salt=sa)
    B = go.make_B(K, COLS, salt=sb_)
    C = g.gemm_bf16_golden(A, B)
    go.assert_dealiased(A, B, C, tag=tag)
    go.assert_no_zero_cells(C, tag=tag)

    # 🔴 pad=PROBE_PAD 走形参；T.PAD 一个字不动
    await T.load_operands(dut, A, B, K, WGT, ACT, pad=PROBE_PAD)

    # ---- 钉死 OS（dataflow_sel = A_CTRL bit8 = 0）----
    # 🔴 判据侧不做层次探针：cocotb 从 tb 顶层探不进 u_tile_controller 的 packed struct
    #    （tb 只暴露 snap_flat / tu_* / mmio_* 等顶层信号）。改用两条都不依赖层次的守法：
    #    ① 构造侧 assert：本发写出去的 A_CTRL 字，bit8 必须是 0；
    #    ② **机器级兜底 = M2 落的 C1-b WS 绊线**（`tensor_mac_array` 的
    #       `!(dataflow_sel && (sparse_exec_mode != EXEC_DENSE))`，$fatal 级）——
    #       sparse 发只要 dataflow_sel 是 1 就当场 %Fatal(WS-GUARD)。
    #       ⇒ **sparse 发能跑完这件事本身，就是 dataflow_sel==0 的机器证据**，不是假设。
    #       （dense 发不受该绊线保护，只有 ① 守；但 dense 发不是本级的判据主体。）
    ctrl = T.MODE_BF16 << 4
    assert ((ctrl >> 8) & 1) == 0, (
        "%s: A_CTRL bit8 != 0 —— 必须钉死 OS（WS 下两条 *_zero_pad 都被 dataflow_sel==0 门掉，D3 敞口）" % tag)
    seq = [(T.A_CTRL, ctrl), (T.A_KTOTAL, K)]
    if sparse:
        seq.append((A_SPARSE, EXEC_SPARSE_STRUCT))
    seq += [(T.A_OUTCTRL, 0x00), (T.A_EPOCH, EPOCH), (T.A_WGT, WGT),
            (T.A_ACT, ACT), (T.A_SCL, 0), (T.A_RES, RES),
            (T.A_CTRL, ctrl | 1)]
    await T.mmio(dut, seq)

    t0 = get_sim_time("ns")
    snap, snap_re, cyc = await T._capture(dut, t0)
    assert snap is not None, "%s: tile 未收官（超时）" % tag
    assert snap == snap_re, "%s: 采样窗内二次采样不稳（snap != snap_recheck）" % tag

    csr = await T.read_csrs(dut)
    # 判据级 assert：模式与数据流必须是钉死的那一档，不靠自觉
    # CSR 0x00 = {24'd0, current_mode[3:0], wb_busy, done_latch_q, ctrl_busy}
    # ⇒ 0x22 = mode(4=BF16) 在 [6:3] + done_latch。**它不含 dataflow_sel**（见上方 OS 段）。
    assert _csr(csr, 0x00) == MODE_BF16_CSR, (
        "%s: CSR 0x00 读回 0x%08x ≠ 0x%08x（MODE_BF16 未钉住）" % (tag, _csr(csr, 0x00), MODE_BF16_CSR))
    return snap, cyc, csr, C


async def _dense_shot(dut, K):
    tag = "m3_dense_k%d" % K
    snap, cyc, csr, C = await _one_tile(dut, K, sparse=False, tag=tag)
    bad = T._check_snapshot(snap, C)
    assert not bad, "%s: %d/256 cell != golden: %s" % (tag, len(bad), bad[:8])
    _DENSE[K] = (snap, cyc, _csr(csr, 0x0C), _csr(csr, 0x10))
    dut._log.info("PAD-CADENCE %s: 0x0c=0x%08x 0x10=0x%08x cycles=%d （dense 对照发）"
                  % (tag, _csr(csr, 0x0C), _csr(csr, 0x10), cyc))


async def _sparse_shot(dut, K):
    tag = "m3_sparse_k%d" % K       # 🔴 载具名【冻结在 M3】：改名会让 M3 与 M4 两份 log
                                    #    不再逐行可比，「同一探针两级读两组数」的证据链就断了。
    exp_csr, exp_cyc = EXPECT[K]
    delta = KP[K] - K               # Kp−K，即本级应翻的量（k24 = 0）
    snap, cyc, csr, C = await _one_tile(dut, K, sparse=True, tag=tag)
    c0c, c10 = _csr(csr, 0x0C), _csr(csr, 0x10)

    # ---- 判据 A · cadence（报文规格可 grep）----
    dut._log.info("PAD-CADENCE %s: 0x0c=0x%08x expect=0x%02x" % (tag, c0c, exp_csr))
    assert c0c == exp_csr, ("PAD-CADENCE %s: 0x0c=0x%08x expect=0x%02x —— "
                           "M4 期望【Kp+35】（K1b 后；原 Kp+34）。读到 K+34 说明 pad 没进稀疏臂（查 A2/A3 选择子极性）；"
                           "读到别的值说明 pad 公式不是 ⌈K/4⌉×4"
                           % (tag, c0c, exp_csr))
    assert c10 == exp_csr, "PAD-CADENCE %s: 0x10=0x%08x expect=0x%02x" % (tag, c10, exp_csr)
    assert cyc == exp_cyc, ("PAD-CADENCE %s: start_to_capture=%d expect=%d" % (tag, cyc, exp_cyc))

    # ---- 判据 B① · 对 dense 金标（1e-6 容差）----
    #      🔴 M4 起本条同时是「pad 拍数值惰性」的判据：稀疏臂多跑 Kp−K 拍，
    #      那些拍的 act 被 act_in_range_d 强零 ⇒ 乘积 0 ⇒ 结果必须与 dense 金标不变。
    bad = T._check_snapshot(snap, C)
    assert not bad, ("%s: %d/256 cell != dense golden: %s —— pad 拍不惰性（首查 act 腿越界判据）"
                     % (tag, len(bad), bad[:8]))

    # ---- 判据 B② · 与同 K 的 dense 发【整数逐位相等】----
    #      🔴 伙伴缺失判 INVALID，不静默放过（§5.0d 型 3）
    assert K in _DENSE, ("INVALID-PAIRING %s: 同 K 的 dense 对照发没跑过 ⇒ 通道② 无法判读。"
                         "本发既不判绿也不判红。" % tag)
    d_snap, d_cyc, d_c0c, d_c10 = _DENSE[K]
    assert snap == d_snap, ("%s: sparse/dense 的 snap_flat 整数【不逐位相等】 —— "
                            "通道① 的 1e-6 容差掩盖了真差异，停机" % tag)

    # ---- 判据 C · 🔴 **对活体 dense 发的相对翻值**（M4 新增，比查表强一级）----
    #      表比对只证「等于我预登记的数」；本条证「相对同一次运行里的 dense 基线，
    #      恰好翻了 Kp−K」—— 它不依赖 R1 基线文件、也抓得住「两发一起漂」。
    if delta == 0:
        assert (cyc, c0c, c10) == (d_cyc, d_c0c, d_c10), (
            "PAD-CADENCE %s: 🔴 **半格恒等正控破了** —— K%%4==0 时 Kp==K，sparse 必须与 dense "
            "三元组恒同，实测 (%s) vs (%s)。这正是 ((K+4)>>2)<<2 / (K&~3)+4 两类 pad "
            "公式手滑的签名（它们只在 K%%4==0 上与正确式分叉）"
            % (tag, (cyc, c0c, c10), (d_cyc, d_c0c, d_c10)))
        dut._log.info("PAD-CADENCE %s: ✅ 半格恒等正控成立（Kp=K=%d，与 dense 发三元组恒同）"
                      % (tag, K))
    else:
        assert (c0c - d_c0c, c10 - d_c10, cyc - d_cyc) == (delta, delta, delta), (
            "PAD-CADENCE %s: 翻值量不等于 Kp−K=%d —— 实测 0x0c +%d / 0x10 +%d / cycles +%d "
            "(dense 基线 0x%02x/0x%02x/%d)。+0 = pad 没落地；其它值 = pad 公式错"
            % (tag, delta, c0c - d_c0c, c10 - d_c10, cyc - d_cyc, d_c0c, d_c10, d_cyc))
        dut._log.info("PAD-CADENCE %s: ✅ 相对活体 dense 基线恰好翻 +%d（0x%02x→0x%02x, %d→%d）"
                      % (tag, delta, d_c0c, c0c, d_cyc, cyc))


# ============================================================================
# 8 发：逐 K「dense 对照发 → sparse 发」成对。cocotb 按定义序执行。
# ============================================================================

@cocotb.test()
async def m3_dense_k23(dut):
    """K=23 dense 对照发（通道② 的比对基准）。"""
    await _dense_shot(dut, 23)


@cocotb.test()
async def m3_sparse_k23(dut):
    """K=23 sparse 发（0x08=0x01）。**M4 期望 0x0c=0x10=0x3a、start_to_capture=78**（Kp=24）。

    Kp−K=1，相对同跑的 dense 发（0x39/77）必须恰好 +1。
    该格对 A3 类 CSR 简并（+1 也可能来自别的手滑），靠 K1A 影子 %Fatal 与 k24 正控一起守。
    """
    await _sparse_shot(dut, 23)


@cocotb.test()
async def m3_dense_k24(dut):
    """K=24 dense 对照发。"""
    await _dense_shot(dut, 24)


@cocotb.test()
async def m3_sparse_k24(dut):
    """K=24 sparse 发。**M4 期望 0x3a/78 —— 与 M3 同值。**

    🔴 **半格恒等正控**：Kp(24)=24 ⇒ 本格**不许翻**，且必须与同跑的 dense 发三元组恒同。
    它是唯一能抓住 ((K+4)>>2)<<2 / (K&~3)+4 两类 pad 公式手滑的格
    （两者只在 K%4==0 上与正确式 ((K+3)>>2)<<2 分叉）。本格翻了 = pad 公式错，不是别的。
    """
    await _sparse_shot(dut, 24)


@cocotb.test()
async def m3_dense_k25(dut):
    """K=25 dense 对照发。"""
    await _dense_shot(dut, 25)


@cocotb.test()
async def m3_sparse_k25(dut):
    """K=25 sparse 发。**M4 期望 0x3e/82**（Kp=28，Kp−K=3 ⇒ 相对 dense 发的 0x3b/79 恰好 +3）。

    Kp−K=3 是四格里最大的一格 ⇒ CSR 鉴别力最强。
    """
    await _sparse_shot(dut, 25)


@cocotb.test()
async def m3_dense_k26(dut):
    """K=26 dense 对照发。"""
    await _dense_shot(dut, 26)


@cocotb.test()
async def m3_sparse_k26(dut):
    """K=26 sparse 发。**M4 期望 0x3e/82**（Kp=28，Kp−K=2 ⇒ 相对 dense 发的 0x3c/80 恰好 +2）。

    与 k25 在 M4 同落 0x3e/82，但两者的**翻值量**不同（+2 vs +3）⇒ 判据 C 仍能区分它们。
    """
    await _sparse_shot(dut, 26)

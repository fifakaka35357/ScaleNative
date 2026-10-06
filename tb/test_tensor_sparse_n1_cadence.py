"""test_tensor_sparse_n1_cadence.py —— N=1（1:4）cadence 载体（3a-6/P4 入册）。

🔴 **本载体只验节拍（cadence），不验数值。** 见下方「为什么数值必错」。
🔴🔴 **它落地当天【恒绿】—— 引用它的绿之前，先读「它证明什么 / 不证明什么」那两段。**

===========================================================================
## 期望（唯一定义处 = `aichip_run_logs/s3a45_prereg_20260806.md` §9，本处是副本）

    发              | K  | ⌈K/4⌉ | Kp | 发行拍数 2⌈K/4⌉−1 | **P4 期望**
    sparse_n1_k23   | 23 |   6   | 24 |        11         | **0x2e / 66**
    sparse_n1_k24   | 24 |   6   | 24 |        11         | **0x2e / 66**
    sparse_n1_k25   | 25 |   7   | 28 |        13         | **0x30 / 68**

**算术三步，每步都指到已落盘的裁决（不是纸面推的，也不是跑完填的）**：
 1. **发行拍数 = `2⌈K/4⌉ − 1`** —— `D-SPARSE-3A6-PREREQ-2026-08-04` **Q3** 取规格
    `Tensor/Idea/Tensor_Unit_Sparse_Doubling_Spec.md:314` 的 drain 起点规则为权威
    （「drain 计数起点 = 最后一次**真实权重行**的 issue 拍，§4.3 的气泡零行**不作起点**」）
    ⇒ N=1 的末尾气泡拍被 `k_will_be_done` 前瞻吞掉，故 −1。
 2. **drain = 35**（稀疏臂）—— 分臂谓词 = `n_cfg != NCFG_DENSE`（**Q2**），
    `NCFG_1OF4 ≠ dense` ⇒ 走 `DRAIN_CYCLES_OS_SPARSE`。
 3. `start_to_capture = 0x0c + 20`（R1 四形状 4/4 实测的恒等式）。

## 🔴 它【不】证明什么（收口报告必须逐字带走这一段）

**本载体落地当天恒绿** —— 因为 Q3 选的正是「认可今日 RTL 行为」的那一支：
期望数由**规范性规则**推出，而该规则与现行为一致 ⇒ 它当天不可能红。
⇒ **该载体仅作回归锚，禁报为 N=1 节拍正证；正证责任片 = 3c R3**
（气泡节拍 oracle + 末窗积入账 + 「后半真实权重行未被提前清零」红样本）。

## 🔴 它【确实】守得住什么（别把"恒绿"读成"零价值"）

三发一旦读到别的数，机构逐一可分：

    读到 ⌈K/4⌉+35   (0x29/0x29/0x2a) ⇒ 气泡没插（k_step 恒 4，{4,0} 相位没接上）
    读到 2⌈K/4⌉+35  (0x2f/0x2f/0x31) ⇒ 相位起反了，**或** n_cfg 被当成 N=2
    读到 Kp+35      (0x3b/0x3b/0x3f) ⇒ k_step 重写被回退
    读到 K+35 / K+34                 ⇒ M4 的 pad 臂被回改了

🔴 **第二格与 N=2 载体的现役值撞码 ⇒ 单靠本载体不可分**。分它的是
**P3 落的独立影子**（`tensor_tile_controller.sv` 的 `[3a-6/P3]` 块）：
它的闭式 N=1 臂 = `Kp/2 − 1`，相位起反会当场
`K1A-REF: COMPUTE beats 12 != independent form 11`。
**这是 P3 与 P4 的交叉守门 —— 缺任一条都会留下一个不可分的格。**

## 🔴 为什么本载体「数值必错」（设计内的、已登记的真空，不是缺陷）

两条独立原因，缺一都够：
 ① 权重腿上界 = `⌈K/4⌉ × N`（N=1 ⇒ `⌈K/4⌉`）远小于 K ⇒ 后半权重行被 `wgt_zero_pad` 强零；
 ② 规格 §4.3 的**权重流逐拍零行交织**按 `D-SPARSE-3A6-PREREQ-2026-08-04` **Q5**
    已转出 3b/3c ⇒ 今天 `wgt_advance ≡ issue_en`（`tensor_external_modules.sv`），
    **气泡拍照样推权重行** ⇒ 权重与激活的配对本来就不对。
⇒ **本文件不得含任何 cell-exact 数值断言，也不调 `_check_snapshot`。**
（写一个对不上的金标比对，只会逼后人把闸改松。）

## 配置逐字钉死（预登记 §9）

    0x08 = 0x05        ⇒ [1:0]=01 = EXEC_SPARSE_STRUCT
                         [3:2]=01 = NCFG_1OF4（P4 放宽 C2 —— 🔴 **合取式**：
                         只在 exec=EXEC_SPARSE_STRUCT 下放行，`scratch_guard_probe`
                         的 P3 发 exec=EXEC_DENSE ⇒ **仍红**，P5 mutation 锚不退化）
    dataflow_sel = 0   ⇒ A_CTRL bit8 = 0（OS）。**判据里 assert**，不靠自觉
    MODE_BF16          ⇒ CSR 0x00 读回 0x00000022。**判据级 assert**
    pad = 40           ⇒ 垃圾行需求 = Kp−K+35，K∈{23,24,25} 上取 {36,35,38}，最大 38 ≤ 40
                         🔴 **传形参，不动 `T.PAD`**（T.PAD 是 R1 的冻结口径）

## 四条禁令（与 N=2 载体同款）

1. **禁进** `tb/snap_baseline.py` 的 `EXPECTED_CASES["r1_dense"]`（会动 `CONSUMED × 8/8`）
2. **禁调** `snap_baseline`   3. **禁写** `tb/baseline/`
4. **禁写进** `tb/test_tensor_gemm_core.py` 本体（其 sha256 是 R1 的口径锚）

🔴🔴 **下面那段 `Run:` 是【机器解析字段】，不是给人读的说明。**
`run_all.py:29-31` 用**非贪婪正则**从本 docstring 里抓 TOPLEVEL 与源清单
（模式见该文件，此处**刻意不复写那两个字面量**，理由就在下一段）。

**本文件在这一处连吃两次学费，两次都是同一个机理「说明文字被当成数据解析」**：
 ① 首版把源清单写成散文占位符「<同 …的清单>」⇒ **单跑（命令行显式传清单）通过、
    run_all 里 `make Error 2`**，闸2 判 `PASS=182 FAIL=1 across 58 files`。
 ② 为①写的这段警告里，**原样敲了那个字面量并跟着一对引号**⇒ 非贪婪正则**先命中警告文字**、
    把源清单解析成一个省略号 token ⇒ 与①同样的红，而且更难查（清单明明写在下面）。
⇒ **通用规则（比"禁写占位符"更强）：凡机器解析字段所在的文件，说明文字里【不得出现该字段的
   可被同一正则命中的形态】** —— 要提它就换写法（去掉引号 / 只写字段名 / 指向定义处）。
   这是「判据文本自指」在本战役的第 7、8 次实付。

Run: cd tb && make MODULE=test_tensor_sparse_n1_cadence TOPLEVEL=tb_tensor_gemm_core \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/Tensor/mac_tz_shifter.sv ../rtl/Tensor/mac_zero_detect.sv ../rtl/Tensor/mac_lru.sv \
        ../rtl/Tensor/mac_fp_acc_align.sv ../rtl/Tensor/mac_fp_accumulator.sv ../rtl/Tensor/mac_input_mux.sv \
        ../rtl/Tensor/mac_cell.sv ../rtl/Tensor/output_format_unit.sv \
        ../rtl/Tensor/tensor_mac_array.sv ../rtl/Tensor/tensor_egress_fragmentizer.sv \
        ../rtl/Tensor/tensor_external_modules.sv \
        ../rtl/Tensor/tensor_tile_controller.sv ../rtl/Tensor/requantizer.sv ../rtl/Tensor/tensor_result_packer.sv \
        ../rtl/Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_core.sv"

判读（🔴 判读串必须**行首锚定**，否则会被本 docstring 的 cocotb 回显命中）:
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
SPARSE_N1 = 0x05               # [1:0]=01 EXEC_SPARSE_STRUCT, [3:2]=01 NCFG_1OF4
CARRIER_PAD = 40               # 见头注；🔴 传形参，不动 T.PAD
MODE_BF16_CSR = 0x00000022     # CSR 0x00 读回值（mode=BF16 的判据级 assert）

# K -> (salt_a, salt_b, WGT_base, ACT_base)。与 N=2 载体同源；本载体**不比数值**，
# salt 只用来避免全零激励（全零会让「跑完了」和「什么都没算」不可区分）。
SHAPES = {
    23: (18, 34, 0x0C0, 0x0C0),
    24: (24, 50, 0x020, 0x100),
    25: (39, 50, 0x080, 0x080),
}

# 现役期望 = 预登记 §9 的 P4 列。🔴 **在 RTL 与本文件均未落之前就已 commit**
#   （`535e3a7`，§5.0b-5 的发数前预登记）⇒ 不是跑完照实测填的。
# ~~P4 期望 {23:(0x2e,66), 24:(0x2e,66), 25:(0x30,68)}~~
#   ▲🔴**[K1b 2026-08-08] 第三次翻值**（原值划掉保留）：mac_cell 在 lru_out 新增 c6g 缝
#     ⇒ `DRAIN_CYCLES_OS` 34→35，稀疏臂 `= OS+1` 自动 35→36。判据 =
#     `aichip_run_logs/b58k1b_prereg_20260808.md`（R-6 预登记为回归项）。
#   🔴 新值是**按公式推导**得到、再拿实测印证的（不是「跑完照着实测填」）：
#     N=2: ⌈K/4⌉×2+36 ⇒ 48/48/50 = 0x30/0x30/0x32；N=1: (2⌈K/4⌉−1)+36 ⇒ 47/47/49。
#     `start_to_capture` 同 +1（沿用 3a-6 那次「drain +1 ⇒ 三级同向 +1」的先例）。
#   🔴 **反方向守门同样要跟**：`tb/scratch_pad_probe.py` 的 N=4 探针走 **dense** 臂，
#     本刀把 dense 也 34→35 ⇒ 那条期望**必须一起改**，否则两条方向相反的守门缺一条。
EXPECT = {23: (0x2f, 67), 24: (0x2f, 67), 25: (0x31, 69)}


def _csr(csr_str, addr):
    """从 T.read_csrs 的返回串里取某个读口的整数值。找不到 ⇒ 抛错，不返回默认值。"""
    key = "0x%02x=" % addr
    for tok in csr_str.split():
        if tok.startswith(key):
            return int(tok[len(key):], 16)
    raise AssertionError("CSR 读口 %s 不在返回串里: %s" % (key, csr_str))


async def _cadence_shot(dut, K):
    """跑一个 N=1 tile，只判 cadence。🔴 不做任何 cell-exact 数值断言（见头注）。"""
    tag = "sparse_n1_k%d" % K
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
    #   机器级兜底 = M2 落的 C1-b WS 绊线（tensor_mac_array 的 $fatal 级 WS-GUARD）
    #   ⇒ 本发能跑完这件事本身，就是 dataflow_sel==0 的机器证据。
    ctrl = T.MODE_BF16 << 4
    assert ((ctrl >> 8) & 1) == 0, (
        "%s: A_CTRL bit8 != 0 —— 必须钉死 OS（WS 下两条 *_zero_pad 都被 dataflow_sel==0 门掉）" % tag)

    seq = [(T.A_CTRL, ctrl), (T.A_KTOTAL, K), (A_SPARSE, SPARSE_N1),
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
        "PAD-CADENCE %s: 0x0c=0x%08x expect=0x%02x —— P4 期望 (2⌈K/4⌉−1)+36。"
        "🔴 红因路由（按读到的值查，别乱猜）："
        "读到 ⌈K/4⌉+35 ⇒ 气泡没插（k_step 恒 4，{4,0} 相位没接上）；"
        "读到 2⌈K/4⌉+35 ⇒ 相位起反了 **或** n_cfg 被当成 N=2 —— 🔴 该格与 N=2 载体现役值撞码，"
        "  单靠本载体不可分，去看 P3 独立影子的 'K1A-REF: COMPUTE beats'；"
        "读到 Kp+35 ⇒ k_step 重写被回退；读到 K+35/K+34 ⇒ M4 的 pad 臂被回改了"
        % (tag, c0c, exp_csr))
    assert c10 == exp_csr, "PAD-CADENCE %s: 0x10=0x%08x expect=0x%02x" % (tag, c10, exp_csr)
    assert cyc == exp_cyc, "PAD-CADENCE %s: start_to_capture=%d expect=%d" % (tag, cyc, exp_cyc)
    dut._log.info("PAD-CADENCE %s: ✅ cadence=0x%02x/%d（🔴 恒绿的回归锚，不是 N=1 节拍正证）"
                  % (tag, exp_csr, exp_cyc))


@cocotb.test()
async def sparse_n1_k23(dut):
    """K=23, N=1。期望 0x0c=0x10=0x2e、start_to_capture=66（2⌈23/4⌉−1 = 11 ⇒ 11+35）。"""
    await _cadence_shot(dut, 23)


@cocotb.test()
async def sparse_n1_k24(dut):
    """K=24, N=1。期望 0x2e/66。K%4==0 一发 —— 它是唯一「无 pad 拍」的形状，
    与 k23 同值（⌈23/4⌉ = ⌈24/4⌉ = 6），故它单独证明的是「pad 拍不存在时相位仍对」。"""
    await _cadence_shot(dut, 24)


@cocotb.test()
async def sparse_n1_k25(dut):
    """K=25, N=1。期望 0x30/68（2⌈25/4⌉−1 = 13 ⇒ 13+35）。
    ⌈K/4⌉ 由 6 跳到 7 的唯一一发 ⇒ 三发里唯一能把「⌈K/4⌉ 算错」与「步长/相位算错」分开的格。"""
    await _cadence_shot(dut, 25)

"""3a-7 / P1 —— `is_valid_descriptor` 观测通道【点亮】探针（零 RTL 改动）

---------------------------------------------------------------------------
## 为什么要有本探针（3a-7/R0 对抗审查 blocker B2）

`Tensor/tensor_pkg.sv` 的 `is_valid_descriptor()` 今天的四条规则**只看**
`exec_class` / `out_class`，而这两个字段的唯一驱动源是 MMIO `0x0C`；
**全仓每一处 `0x0C` 写值都是 `0x00`**（实测十处，含 SoC 路径 `tensor_cmd_mmio_seq` 的 step 3）
⇒ `exec_class ≡ EXEC_NONE(2'b00)`、`out_class ≡ OUT_FWD_VEC_NATIVE(2'b00)`
⇒ 四条规则**一条都不成立** ⇒ **该函数在全仓每一发激励下恒返回 `1'b1`**，
它的两个消费者（`tensor_tile_controller` 的 R5-6、`tensor_unit_top` 的 G2）**从未通电过**。

3a-7 要往这个函数**加三条臂**（sparse_mode 保留值 / `n_cfg==NCFG_RESERVED` / `dataflow_sel && sparse`）
并在 P5 把它接到 `desc_push_valid` 上。**把核心可交付挂在一条从未见过红的通道上是不允许的**
（`PROJECT_RULES §5.0b`「一个从未见过红的测试证明不了任何东西」）。
⇒ **本探针在任何 RTL 落笔之前跑，证明这条通道真的会响。**

## 注入口与它的唯一性

`A_OUTCTRL = 0x0C` ⇒ `mmio_wr_data[3:2] = 2'b11` ⇒ `reg_out_class <= OUT_CLASS_RESERVED`
（`tensor_external_modules.sv` 的 `8'h0C` 分支；`out_class_e` 里 `OUT_CLASS_RESERVED = 2'b11`）
⇒ 命中 `is_valid_descriptor` 的第一条规则 `if (d.out_class == OUT_CLASS_RESERVED) return 1'b0;`

🔴 **为什么必须用 `out_class` 这个口，不用别的**：它与三条现役 `$fatal` 绊线的触发集合
（`sparse_mode` / `n_cfg` / `dataflow_sel`）**不相交** ⇒ 是全仓唯一能**单独**点亮
`$error` 通道、且**不会被别的绊线抢先 abort** 的注入口（裁决 blocker B3 的直接对策）。

## 判读

🔴🔴 **[3a-7/P5 2026-08-06] 红发的期望【已整体改判】—— 从「响 R5-6」改为「start 被丢」。**

P5 把 `is_valid_descriptor` 接到了 `desc_push_valid` 上
（`tensor_external_modules.sv`：`assign desc_push_valid = start_pulse && !desc_reject;`）。
本探针的注入 `A_OUTCTRL=0x0C` ⇒ `out_class=OUT_CLASS_RESERVED` ⇒ **命中该函数第 2 条臂**
⇒ 描述符**根本不入队** ⇒ controller **永不启动** ⇒ **R5-6 结构性不可达、不再响**。
🔴 不同批改判就是 `PROJECT_RULES §5.0d` **型 9**（判据还挂着、但对该发永远不可能成立）。
🔴 **本条是 3a-7 交接 §0.9 没点名的**（那里只写了 `scratch_guard_probe` 的矩阵重挂），
是 P5 开工前测绘补出来的 —— 预登记 `s3a7_prereg_20260805.md` §10.3(b)。
（旧判据保留在 git 历史里；**禁原地改数**。）

本项目 Verilator 的 runtime 输出带时间戳前缀，真形态 = `[<ts>] %Error: <file>:<line>: Assertion failed ...`。

**红发**（`probe_ivd_out_class_reserved`）—— **P5 后的期望，四条同时成立**：

    grep -cE 'IVD-CSR\[OUT_CLASS_RESERVED\] 0x1c=0x[0-9a-f]+ bit2=1' <log>   # == 1  ← 拒收留痕
    grep -cE '^\[[0-9]+\] %(Error|Fatal):'                           <log>   # == 0  ← 零真签名
    grep -c 'TESTS='                                                  <log>   # >= 1  （不再被 abort）
    make 退出码                                                                # == 0

**绿发**（`probe_ivd_control_green`，反向自证）—— **逐字不变**：

    grep -cE 'IVD-CSR\[CONTROL_GREEN\] 0x1c=0x[0-9a-f]+ bit2=0'      <log>   # == 1
    grep -cE '^\[[0-9]+\] %(Error|Fatal):'                           <log>   # == 0
    grep -c 'TESTS='                                                  <log>   # >= 1
    make 退出码                                                                # == 0

🔴 **判读锚必须带方括号 tag**（`IVD-CSR[<tag>]`）—— 裸串会被本 docstring 自身命中
（`§5.0d` 型 16，本片已实付两次）。
🔴 **两发的区分变量只剩 `bit2`**（1 vs 0）：P5 之后两发都跑完、都零真签名、都 rc=0
⇒ **`bit2` 是唯一的红绿判据**，它同时是 P4 那个 sticky 位的又一个正控。

🔴 **两发必须成对**：只有红发会「即使 R5-6 根本没在观测 out_class 也可能因别的原因红」；
只有绿发会「即使注入压根没落到 `reg_out_class` 也一样绿」。**成对才排除这两种解释。**

## 隔离纪律（`$error` 在本工具链下会 abort，见下）

`assert property (...) else $error(...)` 失败 ⇒ Verilator 走
`VL_STOP_MT → vl_stop → gotError(true)/gotFinish(true) → fatalOnError()(默认 true) → vl_fatal → abort`
⇒ **中止整个仿真**，后续 test 不会执行。**必须用 `TESTCASE=` 逐发 run，各留一份日志。**
（这条机理正是 3a-7/R0 审查里推翻候选 L6-1「三闸对 $error 全盲」的依据，本探针同时是它的实证。）

Run（逐发换 TESTCASE 与 log 名；每发前过 `PROJECT_RULES §5.0b` 的排他哨兵）:
    cd tb
    VS=$(python3 -c "import re;print(' '.join(re.search(r'VERILOG_SOURCES=\\"(.*?)\\"',
         open('test_tensor_gemm_core.py').read(), re.S).group(1).replace(chr(92),' ').split()))")
    make -s clean
    make -s MODULE=scratch_ivd_probe TOPLEVEL=tb_tensor_gemm_core \\
         TESTCASE=<发名> VERILOG_SOURCES="$VS" > ../../aichip_run_logs/<log> 2>&1; echo rc=$?

🔴 本文件 `scratch_` 前缀 ⇒ **不进 `run_all.py` 的 `glob("test_*.py")`、不在 elaborate 靶里**
⇒ 三闸对它结构性全盲，分母 ±0（预登记 `s3a7_prereg_20260805.md` §1 的 P1 行）。
🔴 本探针是**一次性**的（裁决 P1 批逐字「不建常驻载体」）；它的结论落 `s3a7_p1_*` 日志与判决件。
"""
import sys, os
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gemm_operands as go
import test_tensor_gemm_core as T

ROWS = COLS = 16

# 0x0C 位域（tensor_external_modules.sv 的 8'h0C 分支）：
#   [1:0] exec_class · [3:2] out_class · [5:4] out_fmt · [6] ofu_round
OUTCTRL_RESERVED = 0x0C   # [3:2]=2'b11 = OUT_CLASS_RESERVED  → is_valid_descriptor 规则 1 命中
OUTCTRL_LEGAL    = 0x00   # [3:2]=2'b00 = OUT_FWD_VEC_NATIVE  → 全仓现役值（对照）


async def _probe(dut, outctrl, tag):
    """写 A_OUTCTRL=outctrl 后跑一个 dense tile，其余 MMIO 逐字沿用现役序列。"""
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)
    dut.egress_ready.value = 1

    K = 24
    EPOCH, WGT, ACT, RES = 0x05, 0x020, 0x100, 0x200
    A = go.make_A(K, ROWS, salt=24)
    B = go.make_B(K, COLS, salt=50)
    await T.load_operands(dut, A, B, K, WGT, ACT)

    ctrl = (T.MODE_BF16 << 4)
    # 🔴 [3a-7/P5] 读地址必须在写 start 之前预置（读 MUX 纯组合；禁在采样点当场写 addr —— 
    #    cocotb 的写要到本时间步写相位才生效，会读回 0x00(STATUS) 旧值 ⇒ 假的 bit2=0）。
    dut.mmio_rd_addr.value = 0x1C
    # 🔴 注入点：只有 A_OUTCTRL 这一项与现役序列不同，其余逐字相同
    #    ⇒ 红/绿两发的唯一变量就是 out_class，无第二解释。
    await T.mmio(dut, [
        (T.A_CTRL,    ctrl),
        (T.A_KTOTAL,  K),
        (T.A_OUTCTRL, outctrl),
        (T.A_EPOCH,   EPOCH),
        (T.A_WGT,     WGT),
        (T.A_ACT,     ACT),
        (T.A_SCL,     0),
        (T.A_RES,     RES),
        (T.A_CTRL,    ctrl | 1),
    ])
    dut._log.info("=== IVD-PROBE[%s] 已写 A_OUTCTRL=0x%02x（out_class=0x%x），开始跑 tile ==="
                  % (tag, outctrl, (outctrl >> 2) & 0x3))
    for _ in range(900):
        await FallingEdge(dut.clk)
        if int(dut.tu_capture_done.value) == 1:
            v = int(dut.mmio_rd_data.value)
            dut._log.info("=== IVD-PROBE[%s] tile 跑完且【未触发 is_valid_descriptor 的消费者】"
                          " IVD-CSR[%s] 0x1c=0x%08x bit2=%d ===" % (tag, tag, v, (v >> 2) & 1))
            return
    # 🔴 [3a-7/P5] 900 拍超时是【正常 return】：被门拒的描述符不入队、controller 永不启动。
    v = int(dut.mmio_rd_data.value)
    dut._log.info("=== IVD-PROBE[%s] 超时（tile 未收官）IVD-CSR[%s] 0x1c=0x%08x bit2=%d ==="
                  % (tag, tag, v, (v >> 2) & 1))


@cocotb.test()
async def probe_ivd_out_class_reserved(dut):
    """P1-RED：A_OUTCTRL=0x0C ⇒ out_class=OUT_CLASS_RESERVED。期望**红**。

    期望报文含 R5-6（tensor_tile_controller 的
    「illegal descriptor at start (exec_class/out_class combination)」）。
    这是 is_valid_descriptor 这条观测通道**有史以来第一次通电**。
    """
    await _probe(dut, OUTCTRL_RESERVED, "OUT_CLASS_RESERVED")


@cocotb.test()
async def probe_ivd_control_green(dut):
    """P1-GREEN（反向自证）：A_OUTCTRL=0x00，与全仓现役值相同。期望**绿**。

    它排除的解释 = 「红发之所以红是因为探针本身/激励本身有问题，与 out_class 无关」。
    """
    await _probe(dut, OUTCTRL_LEGAL, "CONTROL_GREEN")

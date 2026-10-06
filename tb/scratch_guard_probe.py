"""scratch_guard_probe.py —— `tensor_mac_array` / `tensor_tile_controller` 白名单臂的红臂探针。

`scratch_` 前缀 ⇒ **不落 `run_all.py:20` 的 `glob("test_*.py")`**，两个门禁都看不见它
⇒ 它可以放心地 `$fatal`，不会污染闸2 的 `PASS=… across N files` 分母。

---------------------------------------------------------------------------
▲ **[3a-4/M2 2026-08-06] 本文件全文重写。为什么必须重写（不是可选的润色）**

M2 把 `tensor_mac_array` 的 exec 白名单从 `{EXEC_DENSE}` 放宽为
`{EXEC_DENSE, EXEC_SPARSE_STRUCT}` ⇒ **本文件旧版的两条验收判据在 P1 那一发上
结构性恒假**：
    · `grep -c 'TESTS=' <log>   # 必须 0`      —— P1 转绿后 sim 跑完，必然有 cocotb 汇总行
    · `make 退出码 = 2`                          —— P1 转绿后 rc=0
不改就是 `PROJECT_RULES §5.0d 型 9`（闸/自证与可执行性脱节）的新实例：
判据还挂在那里、但对该发永远不可能成立，读的人会以为有保护。
⇒ 判据按**每发**分列（见下方矩阵），不再写成全局三条。

**同批新增两发**（都是本片新绊线的当天自证，`§5.0d 型 9` 强制）：
    · `probe_exec_dense_reserved`（C1-c）：把白名单负控从 1/2 补齐到 **2/2**
    · `probe_ws_times_sparse`（C1-b）：WS × 非 dense 的仿真绊线，**当期零覆盖**
---------------------------------------------------------------------------

## 红臂矩阵（M2 之后的真值；🔴 期望**逐发不同**，别再套用全局判据）

🔴🔴 **[3a-7/P3 2026-08-05] 本矩阵已整体重挂为【双锚】（模块 tag + 报文关键字）。**
原因：P3 给 `is_valid_descriptor` 加了三条臂并把 **R5-6 升 `$fatal`**，而 R5-6 采的是
**未锁存**的 `tile_desc`（controller 输入端口），比 `tensor_mac_array` 侧的 latch 观测者
（`ctrl_tile_desc_active` ← `tile_desc_q`）**早一拍** ⇒ 凡三条新臂命中的发次，
**R5-6 先响并 abort**，原来的 `TENSOR_MAC_ARRAY` tag **不再出现**。
而 R5-6 与下方 `[3a-3]` 白名单臂**同模块同 tag**，**只有报文关键字能区分**：
  · R5-6 报文含 **`illegal descriptor`**   · `[3a-3]` 白名单臂报文含 **`unsupported`**
关键字取自**现役报文正文**（语义描述，不是版本号）⇒ 不违下方「禁钉版本号」纪律。
（原矩阵保留在 git 历史里；**禁原地改数**、禁靠删发次凑绿。）

🔴🔴 **[3a-7/P5 2026-08-06] 本矩阵【第二次整体重挂】—— 四发由「响 `$fatal`」改判为「start 被丢」。**
P5 把 `is_valid_descriptor` 接到了 `desc_push_valid` 上
（`tensor_external_modules.sv` 的 `assign desc_push_valid = start_pulse && !desc_reject;`）
⇒ 非法描述符**根本不入队**、controller **永不启动** ⇒ 队列之后的每一条断言（R5-6 / G2 /
`tensor_mac_array` 的 C1 白名单臂 / WS-GUARD）对它们**结构性不可达**。
被拒的痕迹改由 **P4 的 `0x1C bit[2]` sticky** 承载（规格 §5.4「丢 start + 位可读回，禁静默丢」）。
（P3/P4 两版矩阵保留在 git 历史里；**禁原地改数**、**禁靠删发次凑绿** —— 发次守恒判据见下。）

| 发 | TESTCASE | 注入 | 命中臂 | **P5 后的判读（三锚）** |
|---|---|---|---|---|
| P1 | `probe_exec_sparse_struct`   | `0x08=0x01` exec=SPARSE_STRUCT | 无（**合法**）| 🔴 **仍绿，逐字不变**：`tile 跑完且【未触发守卫】` + 零真签名 + 有 `TESTS=` 行 + rc=0；`GP-CSR` **bit2=0** |
| **P2** | `probe_exec_sparse_reserved` | `0x08=0x03` EXEC_SPARSE_RESERVED | **臂 A** | **start 被丢**：`超时（tile 未收官）` + `GP-CSR[…] 0x1c=0x…4 bit2=1` + 🔴 **零真签名 `%Fatal`/`%Error`** + rc=0 |
| **C1-c** | `probe_exec_dense_reserved` | `0x08=0x02` EXEC_DENSE_RESERVED | **臂 A** | 同上 |
| **P4** | `probe_ncfg_reserved`        | `0x08=0x0C` n_cfg=NCFG_RESERVED | **臂 B** | 同上 |
| **C1-b** | `probe_ws_times_sparse`     | `A_CTRL bit8=1`（WS）+ `0x08=0x01` | **臂 C** | 同上 |
| **P3** | `probe_ncfg_1of4`            | `0x08=0x04` (exec=DENSE, n_cfg=NCFG_1OF4) | 🔴 **一条都不命中** | 🔴 **仍红，且关键字仍是 `unsupported`**（`TENSOR_TILE_CTRL` + `[3a-3]` 白名单臂）—— 见下 |

🔴 **P3 那一发是本片的【窄谓词自证】，两批都靠它**：它的两个字段**都不是保留值**、`dataflow_sel=0`
⇒ `is_valid_descriptor` 返回 **1** ⇒ **门放行、照样入队** ⇒ 由 `[3a-3]` 合取白名单臂承载红证。
它拒的是「**合法但本实现不支持**」的组合，与 `is_valid_descriptor` 拒的「**非法**」是两件事。
**P3 转绿、或关键字变成 `illegal descriptor` ⇒ 谓词写宽了（多半是顺手实现了规格 §5.2 的矛盾组合拒），
当场停机** —— 那会让 3a-3 的 B6「n_cfg 链是通的、不是恒 0 死链」**唯一的正向证明蒸发**。

🔴 **900 拍超时是【正常 return】不是失败**：被门拒的描述符不入队 ⇒ `tu_capture_done` 永不拉高。
判据看 `GP-CSR` 行的 `bit2`，**不看有没有超时行**。

🔴 **发次守恒判据**（裁决 B5 逐字「绝不允许靠删探针发次凑绿」）：
本文件的 cocotb 测试装饰行数**必须恒为 6**，判据 = **行首锚** `grep -cE '^@cocotb' <本文件>`。
🔴 **本条自己就踩过一次型 16**（3a-7/P5 落笔当场）：说明文字里原样敲了那个装饰器全名
⇒ 无锚 `grep -c` 由 6 变 **7**、判据被自己的说明句污染。
两处同时修才算数：**判据加行首锚** + **说明文字里不写它的可命中形态**
（`PROJECT_RULES §5.0d` 型 16 末条：凡机器解析字段所在的文件，说明文字里不得出现该字段
可被同一正则命中的形态）。

🔴 **P3 那一发是 3a-7/P3 的【窄谓词自证】**：它的两个字段**都不是保留值**、`dataflow_sel=0`
⇒ 三条新臂**全不命中** ⇒ 仍由 `[3a-3]` 合取臂响、关键字仍是 `unsupported`。
**P3 若转绿、或关键字变成 `illegal descriptor` ⇒ 谓词写宽了（多半是顺手实现了 §5.2 的矛盾组合拒），
当场停机** —— 那会让 P5 mutation 锚退化为恒真、3a-3 的 B6 唯一正向证明蒸发。

🔴🔴 **上游遮蔽登记（[3a-7/P5] 更新为【极端形态】）**：
~~P2 / C1-c / P4 / C1-b 四发自 3a-7/P3 起由 R5-6 承载红证~~ ——
**P5 之后连 R5-6 也不再承载它们**：门把非法描述符拦在队列外，队列之后的断言对非法描述符
**全部结构性不可达**。现役真值：

| 守卫 | 现在还有没有红样本 |
|---|---|
| `tensor_tile_controller` **R5-6** | 🔴 **零**（结构性不可达）|
| `tensor_unit_top` **G2**（同谓词 `$error`）| 🔴 **零** |
| `tensor_mac_array` **C1 白名单臂** / **WS-GUARD** | 🔴 **零** |
| `tensor_tile_controller` **`[3a-3]` 白名单臂** | ✅ **有** —— 本文件 P3 那一发（唯一）|

⇒ **`is_valid_descriptor` 的正确性此后只由 MMIO 层的红样本守**：
本文件被拒四发的 `GP-CSR bit2=1` + `tb/scratch_sticky_probe.py` 的三点自证。
**禁继续把 R5-6 / G2 / C1 白名单臂 / WS-GUARD 记为「有红样本的守门」。**
**这不是缺陷，是「真拒收」的必然代价** —— 但必须写下来，否则下一片会以为那些断言还在守。

🔴 **P1 转绿是 M2 最承重的正证**：它证明 C1 真放宽了，且放宽后 `EXEC_SPARSE_STRUCT`
在阵列里能跑完（阵列内 `sparse_exec_mode` 零数据通路消费者 ⇒ 与 dense 逐位同构）。
🔴 **但「跑完」≠「算对」**：本片对稀疏臂**没有数值 oracle**（真 N:M 金标归 3c R5，
本片到 3c 之间是**显式登记的真空**）。**禁把 P1 转绿写成「稀疏执行已验证」。**
🔴 **P3/P4 仍红同时守住「C2 没被顺手放宽」** —— C2 归 M5′，且只到 `{NCFG_DENSE, NCFG_2OF4}`。

## 🔴 隔离纪律（2026-08-03 RED-1 实付，必须照做）

`$fatal` 会中止整个仿真 ⇒ **各发不能同跑**：第一发红掉后后续 test 根本不会执行
（RED-1 首次实测停在 `running probe_exec_sparse_struct (1/2)` → `Aborting...`，负控为空）。
**必须用 `TESTCASE=` 逐发 run，各留一份日志。**

Run（逐发换 `TESTCASE` 与 log 名；每发前过 `PROJECT_RULES §5.0b` 的排他哨兵）:
    cd tb
    VS=$(python3 -c "import re;print(' '.join(re.search(r'VERILOG_SOURCES=\"(.*?)\"',
         open('test_tensor_gemm_core.py').read(), re.S).group(1).replace(chr(92),' ').split()))")
    make -s clean
    make -s MODULE=scratch_guard_probe TOPLEVEL=tb_tensor_gemm_core \
         TESTCASE=<发名> VERILOG_SOURCES="$VS" > ../../aichip_run_logs/<log> 2>&1; echo rc=$?

## 判读（🔴 逐发用下面对应的一组，不要套全局）

🔴🔴 **判读串必须锚到【本项目 Verilator 的真签名】`^\[<时间戳>\] %Fatal:`。**
这一条同时解决两个方向的失效，缺一不可：

**方向 A（假红 / 判据文本自指，型 16）**：cocotb 会把 **test 函数的 docstring** 打进日志
（缩进若干空格），⇒ 在函数 docstring 里写过的判读串会在日志里出现一次。
M2 实测：P1 那一发用未锚定的 `grep -c '%Fatal'` 得到 **1** —— 命中的正是
`probe_exec_sparse_struct` 自己 docstring 里那句「…本发应跑完且零 %Fatal。」
（🔴 **2026-08-05 复核实测**：全仓六个 test 函数里**只有 P1 这一个** docstring 含 `%Fatal`；
模块级 docstring（即本段）**不被 cocotb 回显** —— 四份真红日志里 `红臂矩阵|判读锚` 命中皆为 0。）
这是「判据文本自指」陷阱在本战役的第四次实付（前三次：M0 检查器 ×2、M2 的 C1-d 计数）。

**方向 B（恒 0 死闸，型 9 恒假自证）—— 🔴 2026-08-05（3a-7/R0 对抗审查 blocker B1）发现**：
~~原判读串写成 `^%Fatal:`~~ **结构性恒 0** —— Verilator 的 runtime fatal 输出带时间戳前缀，
真形态是 `[1341000] %Fatal: tensor_mac_array.sv:1123: Assertion failed in …`。
**当场实测（仓根）**：
    grep -rlE '^%Fatal:'            aichip_run_logs/ | wc -l   ->   0    ← 旧锚，一份都不命中
    grep -rlE '^\[[0-9]+\] %Fatal:' aichip_run_logs/ | wc -l   ->  36    ← 真签名
⇒ 旧写法下「红发」的前两条**永远为 0**，其中 tag 那半条正是下文自称
「真正识破『两臂被合并成一条』」的那半条 ⇒ 该矩阵此前只靠 `TESTS=`/rc 两条支撑。
同型教训已在 `HANDOFF_2026-08-07_Sparse_3a6_Closeout.md §0.5` 第 8 条登记过，**当时未回灌本文件**。

🔴 **为什么不采用「简单去掉行首锚」**：去锚会把方向 A 放回来。锚到**真签名**是唯一同时闭合
两个方向的写法（时间戳前缀在行首、docstring 回显必带缩进 ⇒ 结构性互斥）。

**红发**（P2 / C1-c / P3 / P4 / C1-b）**四条**同时成立（🔴 第 2 条自 3a-7/P3 起是**双锚**）：
    grep -cE '^\[[0-9]+\] %Fatal:.*Assertion failed' <log>   # >=1  （真签名锚 + 是 %Fatal 不是 %Error）
    grep -cE '^\[[0-9]+\] %Fatal:.*<tag>' <log>              # >=1  （tag = TENSOR_MAC_ARRAY / TENSOR_TILE_CTRL）
    grep -cE '^\[[0-9]+\] %Fatal:.*<keyword>' <log>          # >=1  🔴 **本发期望的关键字**，逐发不同：
                                                             #       P2/C1-c/P4/C1-b -> illegal descriptor
                                                             #       P3              -> unsupported
    grep -c 'TESTS=' <log>                                   # == 0 （sim 被 abort，无 cocotb 汇总行）
    make 退出码                                               # != 0
    🔴 **反向自证 —— 必须【两条都跑】，缺一不可**（本片 §2.9c 实付）：
    (a) 负控：grep -cE '^\[[0-9]+\] %Fatal:.*TENSOR_NOSUCHTAG' <log>   # == 0
    (b) 🔴 **正控**：grep -cE '^\[[0-9]+\] %Fatal:' <log>              # >=1
        —— 「必须 >=1」型判据**只配负控是零信息量的**：负控在 grep 完全失效时也成立。
        3a-7/P2 实付过一次（收口闸去 run_all 日志 grep 单个 test 名，而 run_all 只按文件记账
        ⇒ 五条判据结构性恒 0、负控照样过）。见 `PROJECT_RULES §5.0d` 型 3 的 2026-08-05 扩条。
**绿发**（P1）三条同时成立：
    grep -cE '^\[[0-9]+\] %(Fatal|Error):' <log>             # == 0 （真签名锚；docstring 回显带缩进 ⇒ 不命中）
    grep -c 'TESTS=' <log>                                   # >= 1
    make 退出码                                               # == 0

行号无关：Verilator 报的行号 = **动作语句（`$fatal`）起始行**，会随注释增删漂移
⇒ 判据一律用 `tensor_mac_array\.sv:[0-9]+:` 这类行号无关正则，**禁钉具体行号**。
判读锚取 **tag 字符串**（`TENSOR_MAC_ARRAY` / `TENSOR_TILE_CTRL` / `WS-GUARD`），
不取 `[3a-1]`/`[3a-3]` 版本号 —— 钉版本号的判据会自己腐烂。

🔴 「另一模块 tag 计数 = 0」近乎恒真、**不承载证明力**（首发 abort 就停了）。
真正识破「两臂被合并成一条」的是「**本模块 tag >= 1**」那半条。

## P5（mutation 锚，不在本文件内实现）

注释掉 `tensor_external_modules.sv` 的 `assign desc_out.n_cfg`，重跑 **P3** ⇒ **必须由红转绿**。
仍红 ⇒ 守卫没在观测被 plumb 的那个值，P3/P4 全部作废（这才是 3a-3 的 B6 真正要证的：
**链是通的，不是恒 0 死链**）。
🔴 **P5 的有效性依赖 P3 保持红** ⇒ 这是 M5′ 放宽 C2 时**必须收窄到 `{NCFG_DENSE, NCFG_2OF4}`**
的直接理由（放宽 `2'b01` 会让 P3 转绿、P5 退化为恒绿）。见审查裁决 §4 的 §8-1/§8-2。
"""
import sys, os
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bfp_golden as g
import gemm_operands as go
import test_tensor_gemm_core as T

ROWS = COLS = 16
A_SPARSE = 0x08
DATAFLOW_WS = 1 << 8      # A_CTRL bit8 -> reg_dataflow_sel（tensor_external_modules.sv 的 8'h00 分支）


async def _probe(dut, exec_bits, tag, ctrl_extra=0):
    """注入 0x08=exec_bits（可选地在 A_CTRL 上或 ctrl_extra）后跑一个 tile。

    ctrl_extra 的唯一用途 = C1-b 的人造 WS 注入（DATAFLOW_WS）。全仓无 tile 级
    WS 用例（`tensor_cmd_mmio_seq` 的 A_CTRL 写值 bit8 恒落在 24'd0 内、
    tb/test_*.py 无一处写 bit8）⇒ 这条路径只有本探针能走到。
    """
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)
    dut.egress_ready.value = 1

    K = 24
    EPOCH, WGT, ACT, RES = 0x05, 0x020, 0x100, 0x200
    A = go.make_A(K, ROWS, salt=24)
    B = go.make_B(K, COLS, salt=50)
    await T.load_operands(dut, A, B, K, WGT, ACT)

    ctrl = (T.MODE_BF16 << 4) | ctrl_extra
    # 🔴 [3a-7/P5] 读地址必须在写 start 【之前】预置（读 MUX 是 always_comb + default，
    #    test_tensor_gemm_core.py:199 已逐字背书）。禁在采样点当场写 addr —— cocotb 的写
    #    要到本时间步写相位才生效，会读回 0x00(STATUS) 那一路的旧值（其 bit[2]=done_latch_q）
    #    ⇒ 得到一个【假的 bit2=0】，比读不到更坏。（3a-7/P4 实付）
    dut.mmio_rd_addr.value = 0x1C
    # 🔴 注入：在 start 之前写 0x08 —— 这是全仓唯一能把 sparse_exec_mode 推离 EXEC_DENSE 的口
    await T.mmio(dut, [
        (T.A_CTRL,    ctrl),
        (T.A_KTOTAL,  K),
        (A_SPARSE,    exec_bits),
        (T.A_OUTCTRL, 0x00),
        (T.A_EPOCH,   EPOCH),
        (T.A_WGT,     WGT),
        (T.A_ACT,     ACT),
        (T.A_SCL,     0),
        (T.A_RES,     RES),
        (T.A_CTRL,    ctrl | 1),
    ])
    dut._log.info("=== GUARD-PROBE[%s] 已写 0x08=0x%02x A_CTRL=0x%03x，开始跑 tile ==="
                  % (tag, exec_bits, ctrl))
    for _ in range(900):
        await FallingEdge(dut.clk)
        if int(dut.tu_capture_done.value) == 1:
            v = int(dut.mmio_rd_data.value)
            dut._log.info("=== GUARD-PROBE[%s] tile 跑完且【未触发守卫】 GP-CSR[%s] 0x1c=0x%08x bit2=%d ==="
                          % (tag, tag, v, (v >> 2) & 1))
            return
    # 🔴 [3a-7/P5] 900 拍超时是【正常 return】，不是失败 —— 被门拒的描述符根本不入队、
    #    controller 永不启动、`tu_capture_done` 永不拉高。判据看 GP-CSR 行的 bit2。
    v = int(dut.mmio_rd_data.value)
    dut._log.info("=== GUARD-PROBE[%s] 超时（tile 未收官）GP-CSR[%s] 0x1c=0x%08x bit2=%d ==="
                  % (tag, tag, v, (v >> 2) & 1))


# ============================================================================
# exec 侧（tensor_mac_array 白名单臂）
# ============================================================================

@cocotb.test()
async def probe_exec_sparse_struct(dut):
    """P1：0x08[1:0]=01 → EXEC_SPARSE_STRUCT。

    🔴 **[3a-4/M2 起期望 = 绿]**（历史：RED-0 不红 / RED-1、RED-2 必红）。
    M2 把白名单放宽为 {EXEC_DENSE, EXEC_SPARSE_STRUCT} ⇒ 本发应跑完且零 %Fatal。
    这是 M2「可达性已打开」的正证。**不得据此声称稀疏执行已验证**（无数值 oracle）。
    """
    await _probe(dut, 0x01, "EXEC_SPARSE_STRUCT")


@cocotb.test()
async def probe_exec_sparse_reserved(dut):
    """P2：0x08[1:0]=11 → EXEC_SPARSE_RESERVED。期望**红**。

    白名单形态的负控之一：黑名单写法（`!= EXEC_SPARSE_STRUCT`）会放保留编码过闸。
    """
    await _probe(dut, 0x03, "EXEC_SPARSE_RESERVED")


@cocotb.test()
async def probe_exec_dense_reserved(dut):
    """C1-c【M2 新增】：0x08[1:0]=10 → EXEC_DENSE_RESERVED。期望**红**。

    把 exec 白名单的负控从 1/2（只有 2'b11 在案）补齐到 **2/2**。
    放宽 C1 之后这一发尤其必要：白名单里多了一个成员，「多放行了别的没有」这件事
    需要两个保留编码同时作证。
    """
    await _probe(dut, 0x02, "EXEC_DENSE_RESERVED")


@cocotb.test()
async def probe_ws_times_sparse(dut):
    """C1-b【M2 新增】：dataflow_sel=1（WS）× exec=EXEC_SPARSE_STRUCT。期望**红**。

    🔴 本发是 C1-b 这条新绊线的**当天自证**（`§5.0d 型 9` 强制：新绊线当期零覆盖
    ⇒ 落笔当天必须当场跑一发人造注入并贴输出）。

    机理：`tensor_operand_fetch` 的两条 zero_pad 都带 `dataflow_sel == 1'b0` 门（OS-only），
    而 3a-1 S2 删掉的 P1-3(b) SVA 是「稀疏 fragment 泄漏进 dense tile」的唯一守门
    ⇒ 放宽 C1 之后若跑 WS × sparse，pad 拍不被强零、垃圾权重真的进阵列，
    而且**算得出看起来合理的结果**。C1-b 把这个敞口从「载体自觉钉 OS」变成结构性堵死。

    措辞（§5.0d C7）：C1-b 是**仿真绊线**，不是硬闸；描述符层面的真拒收归 3a-7（规格 §5.4）。
    """
    await _probe(dut, 0x01, "WS_x_SPARSE", ctrl_extra=DATAFLOW_WS)


# ============================================================================
# n_cfg 侧（tensor_tile_controller 白名单臂）—— 🔴 本片不动，期望【仍红】
# ============================================================================

@cocotb.test()
async def probe_ncfg_1of4(dut):
    """P3：0x08=0x04 ⇒ (exec=EXEC_DENSE, n_cfg=NCFG_1OF4)。期望**仍红**。

    exec 臂放行（`0x08[1:0]==2'b00` 在白名单内），必须由 `tensor_tile_controller` 的
    n_cfg 臂拦下。这一发同时是 3a-3 的 B6 通电正向证明：
    它要求 word 从 MMIO 0x08[3:2] 一路到达 `tile_desc_q.n_cfg`。
    🔴 **P5 mutation 锚押在本发保持红上** —— 见文件头 P5 段。
    """
    await _probe(dut, 0x04, "NCFG_1OF4")


@cocotb.test()
async def probe_ncfg_reserved(dut):
    """P4：0x08=0x0C ⇒ (exec=EXEC_DENSE, n_cfg=NCFG_RESERVED)。期望**仍红**。

    n_cfg 白名单形态的负控 —— 黑名单写法会放保留值过闸。
    与 P3 合起来覆盖 n_cfg 的整个非 dense 编码空间。
    """
    await _probe(dut, 0x0C, "NCFG_RESERVED")

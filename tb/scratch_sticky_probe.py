"""scratch_sticky_probe.py —— `0x1C bit[2]` sticky 拒收位的红绿样本（3a-7/P4）。

`scratch_` 前缀 ⇒ **不落 `run_all.py:20` 的 `glob("test_*.py")`**，三闸对它结构性全盲
⇒ 它可以放心地读 CSR / 触发 `$fatal`，不污染闸2 的 `PASS=… across N files` 分母。

预登记（判据数字唯一定义处）= `aichip_run_logs/s3a7_prereg_20260805.md` **§9.3**。
审查裁决 = `aichip_run_logs/s3a7_p4_plan_verdict_20260806.md` **§2 / D-P4-3**。

---------------------------------------------------------------------------
## 🔴 读窗只有半拍 —— 这个文件的全部难点在这里

盘上四份 `s3a7_p3_guard_*.log` **逐字实测**（非推演）：

    T.mmio() 返回瞬间（探针 info 行）        = 1326.00 ns
    R5-6 $fatal（0x08=0x0c ⇒ 臂 B 命中）    = [1331000] = 1331 ns
    对照：锁存侧 [3a-3] 臂（0x08=0x04）      = 1341 ns   ← 晚整一拍

⇒ 1331/1341 是 posedge、1326/1336 是下降沿（`CLK_NS=10`）。
链路全组合：`tensor_external_modules.sv:783 assign rd_valid = !empty;`
→ `tensor_unit_top.sv:415 assign ctrl_start = dq_rd_valid && !ctrl_busy;`
⇒ 队列在 start posedge 写入、**下一个 posedge 就 R5-6**。

**故：全片只有 `T.mmio()` 返回那一瞬（1326 ns）这一个采样点，余量半拍。**
~~方案草案原文「controller 最快要再 1-2 拍才 pop ⇒ 余量 ≥1 拍」~~ —— **已被上述实测证伪**。

## 🔴 四条执行纪律（缺一判 INVALID，出自裁决 D-P4-3）

1. **`mmio_rd_addr` 必须在写 start 之前预置**（读 MUX 是 `always_comb` + `default`，
   `test_tensor_gemm_core.py:199` 已逐字背书这样安全）。
   **禁在采样点当场写 addr** —— cocotb 的写要到本时间步的写相位才生效，
   会读回 `0x00`(STATUS) 那一路的**旧值**，其 `bit[2]` = `done_latch_q` = 0
   ⇒ 得到一个**假的 `bit2==0`**。这比读不到更坏：它看起来像「位没牙」而不是「没读到」。
2. **前后两读**：start 之前一次（`STICKY-PRE`）、`await T.mmio([...start...])` 返回
   **那一刻直接采**（`STICKY-POST`），**不再 await 任何边沿**。
3. **INVALID 逃生口收紧**：只有「日志有真签名 `%Fatal` **且** `STICKY-POST` 行**从未出现**」
   才许判 INVALID；**`STICKY-POST` 出现了但 `bit2=0` ⇒ 一律判红**，禁走 INVALID。
   `STICKY-PRE` 行的存在本身 = **读点活着的正控**。
4. **两发必须 `TESTCASE=` 逐发隔离**、各留一份日志 —— `$fatal` 会中止整个仿真
   （2026-08-03 RED-1 实付：第一发红掉后负控根本不执行 ⇒ 空集冒充通过，`§5.0d` 型 3）。

## 期望矩阵（副本树完成态实测，见 prereg §9.3 贴的输出）

| 发 | TESTCASE | 注入 | STICKY-PRE | STICKY-POST |
|---|---|---|---|---|
| 正发 | `probe_sticky_set`   | `0x08=0x0C`（`n_cfg=NCFG_RESERVED`，臂 B）| `bit2=0` | 🔴 **`bit2=1`** |
| 负控 | `probe_sticky_clear` | `0x08=0x00`（全合法 dense）| `bit2=0` | 🔴 **`bit2=0`** |

**唯一变量 = `0x08` 的写值**；两发其余激励逐字相同（实测连时戳都相同：1316 / 1326）。

🔴 **正发实测【不会】被 R5-6 abort**：探针读完 `STICKY-POST` 即 `return`，
cocotb 结束该 test，仿真走不到 1331 ns 那个 posedge ⇒ `TESTS=1 PASS=1`、零 `%Fatal`。
纪律 3 的 INVALID 分支因此**实测不触发**，但**仍须保留**（它是防线，不是预期路径）。

🔴 **红臂（证明本探针真有牙）**：把 `tensor_status_csr` 的
`if (err_desc_reject) err_desc_q <= 1'b1;` 那一行删掉（= 型 14「守卫恒读 0」最直接的形态）
⇒ 正发的 `STICKY-POST` 必须翻成 `bit2=0`。实测见 prereg §9.3。

Run（🔴 逐发换 `TESTCASE` 与 log 名；每发前过 `PROJECT_RULES §5.0b` 的排他哨兵）:
    cd tb
    VS=$(python3 -c "import re;print(' '.join(re.search(r'VERILOG_SOURCES=\"(.*?)\"',
         open('test_tensor_gemm_core.py').read(), re.S).group(1).replace(chr(92),' ').split()))")
    make -s clean
    make -s MODULE=scratch_sticky_probe TOPLEVEL=tb_tensor_gemm_core \
         TESTCASE=<发名> VERILOG_SOURCES="$VS" > ../../aichip_run_logs/<log> 2>&1; echo rc=$?

🔴 **措辞纪律**（裁决 B7 / prereg §9.4）：本探针证明的是「**MMIO 拒在 TB 层可观测**」。
**禁**据此写「拒收已可观测 / 固件可读回」（集成层无读通路：`tensor_domain_top.sv:242/:306/:244`），
**更禁**写「已拒收」—— P5 之前 `desc_push_valid` 未加门、非法描述符**照样入队**。
"""

import os
import sys

import cocotb
from cocotb.clock import Clock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gemm_operands as go
import tbreset
import test_tensor_gemm_core as T

A_SPARSE = 0x08      # tensor_cmd_decoder 的 8'h08 写口（[1:0] exec, [3:2] n_cfg）
A_ERRFLAGS = 0x1C    # 🔴 tensor_status_csr 的【读】口 ERROR_FLAGS。
#                      注意 0x1C 在【写】口是 SCL_BASE（同 decoder 的 8'h1C 分支）——
#                      读写地址空间在本芯片不对称，别把两者混为一谈。
ROWS = COLS = 16


async def _run(dut, sparse_bits, tag):
    """注入 0x08=sparse_bits，在 start 前后各读一次 0x1C。"""
    await tbreset.preclock_reset(dut, rst="rst_n")
    cocotb.start_soon(Clock(dut.clk, T.CLK_NS, "ns").start())
    await T.reset(dut)
    dut.egress_ready.value = 1

    K = 24
    EPOCH, WGT, ACT, RES = 0x05, 0x020, 0x100, 0x200
    A = go.make_A(K, ROWS, salt=24)
    B = go.make_B(K, COLS, salt=50)
    await T.load_operands(dut, A, B, K, WGT, ACT)

    ctrl = T.MODE_BF16 << 4

    # 🔴 纪律 1：读地址必须在写 start 之前预置（读 MUX 纯组合且带 default）。
    dut.mmio_rd_addr.value = A_ERRFLAGS

    # 参数写入（不含 start）
    await T.mmio(dut, [
        (T.A_CTRL,    ctrl),
        (T.A_KTOTAL,  K),
        (A_SPARSE,    sparse_bits),
        (T.A_OUTCTRL, 0x00),
        (T.A_EPOCH,   EPOCH),
        (T.A_WGT,     WGT),
        (T.A_ACT,     ACT),
        (T.A_SCL,     0),
        (T.A_RES,     RES),
    ])
    pre = int(dut.mmio_rd_data.value)
    dut._log.info("STICKY-PRE[%s]  0x1c=0x%08x bit2=%d" % (tag, pre, (pre >> 2) & 1))

    # 🔴 纪律 2：只写 start，返回那一刻【直接采】，不再 await 任何边沿。
    await T.mmio(dut, [(T.A_CTRL, ctrl | 1)])
    post = int(dut.mmio_rd_data.value)
    dut._log.info("STICKY-POST[%s] 0x1c=0x%08x bit2=%d" % (tag, post, (post >> 2) & 1))


@cocotb.test()
async def probe_sticky_set(dut):
    """正发：0x08[3:2]=11 → n_cfg=NCFG_RESERVED（is_valid_descriptor 臂 B）。

    期望 STICKY-PRE bit2=0 → STICKY-POST bit2=1。
    读回 0 而 STICKY-POST 行存在 ⇒ 判红（sticky 没牙），禁走 INVALID。
    """
    await _run(dut, 0x0C, "NCFG_RESERVED")


@cocotb.test()
async def probe_sticky_clear(dut):
    """负控：0x08=0x00 → 全合法 dense 描述符（is_valid_descriptor 恒真）。

    期望 STICKY-PRE bit2=0 → STICKY-POST bit2=0，且不 abort。
    翻成 1 ⇒ 置位条件写宽了（把合法描述符也判成拒），当场停机 ——
    该态会同时让闸3 的 R1-CSR-DRIFT 响，且【禁走「基线作废重采」】。
    """
    await _run(dut, 0x00, "LEGAL_DENSE")

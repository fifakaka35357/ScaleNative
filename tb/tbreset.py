"""复位序辅助 —— X-prop 通道的前置修复（批 5，2026-07-30）。

## 🔴 为什么手册的处方不足

手册（`HANDOFF_2026-07-29B_600_Batch5.md:92-93`）写的是
「`reset()` 先驱 `rst_n=0` 再 `start_soon(Clock)`」。**只调换这两行不够**：
两行之间没有任何 `await`，仿真时间没有推进，cocotb 的写值也还没落地。

真正的暴露面是 **Verilator 的 time-0 初值随机化发生在任何 cocotb 写值落地之前**：
`XPROP=1` 打开 `--x-initial unique --x-assign unique` +
`+verilator+rand+reset+2`，它会把顶层 `rst_n` **以及 Verilator 为 `|=>`
自建的 `_Vpast_*` 影子寄存器**一起随机化。若第一个时钟沿落在 t=0，
`disable iff (!rst_n)` 的守卫就在垃圾值上求值 ⇒ 断言在垃圾上触发。

实证：`aichip_run_logs/p1_xprop_diag_20260729.log:13` 的断言时间戳是 **`[0]`**，
紧接 "running test (1/2)"，仿真时间尚未推进。而被触发的那条断言
（`mac_cell.sv:1093-1095` 的 `clear_acc |=> !c6_valid_q`）在 Verilator 的
**2 态语义下恒真**（RTL 里 `clear_acc` 分支就是 `c6_valid_q <= 1'b0` 且优先级最高）
⇒ 任何寄存器初值都无法证伪它 ⇒ 那次红是**通道伪红**，不是设计缺陷。
（审查裁决 §3.4 尾巴①：该断言在本通道**永久无牙**，四格重做的红签名不得选它。）

## 修法

    驱复位 → **await 一次推进仿真时间**（让写值落地）→ 才起时钟

这样第一个时钟沿之前 `rst_n` 已经是确定的 0，`disable iff` 守卫必然生效，
`_Vpast_*` 影子寄存器也在守卫覆盖之下。

## 用法（已机械插入全部 97 个起时钟点）

    import tbreset
    ...
    await tbreset.preclock_reset(dut)              # rst_n 低有效（默认）
    cocotb.start_soon(Clock(dut.clk, 10, "ns").start())
    await reset(dut)                               # 原有 reset 逻辑照旧

`reset()` 里再驱一次 `rst_n=0` 是**无害的**（同值重写），故各 bench 的原有
复位逻辑逐字不动 —— 本修改只在**它之前**加一层"时钟启动前复位已确定"的保证。

🔴 本模块不碰时钟周期、不碰复位保持拍数、不碰任何数据激励 ⇒ 对 XPROP=0 的
门禁行为的唯一影响是仿真时间平移 `settle_ns`（时钟起点之后的一切时序不变）。
"""
from cocotb.triggers import Timer


async def preclock_reset(dut, rst="rst_n", active_low=True, settle_ns=1):
    """在【起时钟之前】把复位驱到有效电平，并推进仿真时间让写值落地。

    Args:
        dut:        cocotb 顶层句柄（或任何有该复位属性的句柄）
        rst:        复位信号名（本仓两种：`rst_n` / `rst_ni`）
        active_low: True = 低有效（本仓全部如此）
        settle_ns:  推进多少 ns。只需 >0 让写值落地；取 1 ns。
    """
    getattr(dut, rst).value = 0 if active_low else 1
    await Timer(settle_ns, "ns")

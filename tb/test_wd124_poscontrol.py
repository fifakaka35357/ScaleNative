"""欠账 #124 的正控 —— `a_wd_no_timeout_inactive`（`pe_assertions.sv §10.18`）能不能被打红

🔴 本件【不进 run_all】：它有一条**故意判红**的臂（SVA 触发 ⇒ verilator `$stop` ⇒ Aborting）。
   run_all.py:26-30 要同时正则命中两个机器字段才会构建，本文件刻意不含它们的可匹配形态
   ⇒ 落到 NO-META、被跳过。**跑法唯一** = aichip_run_logs/launch_wd124_poscontrol_20260906.sh。

🔴🔴 欠账 #124 的【原处置文本按字面做打不响】—— 本件同时是那条处置的订正。
   原文：「加一个微臂，把 WD_THRESHOLD(0xB8) 写成 1，该断言必须立即红」。
   源码机理（cp_scheduler.sv 现读）说明它不会红：
     · wd_cnt_q 只在**活态**自增，进 inactive 无条件清零（:890-901）；
     · wd_timeout = (wd_cnt_q == threshold) && threshold != 0（:739-740），是**等于**不是大于等于
       ⇒ 阈值 1 时 wd_timeout 只是 cnt==1 那**一拍的脉冲**；
     · :1013-1015 的 `wd_timeout → CTX_ERROR` 不看状态（除 CTX_ERROR 本身）。
   ⇒ 在**常规负载**下（GEMM 要在 WAIT_TENS 里等几百拍、期间没有 wd_progress），
     阈值=1 会在**活态第 1~2 拍**就把 ctx 打成 CTX_ERROR，而本断言的前件是
     `ctx_state inside {CTX_IDLE, CTX_DONE}` —— **CTX_ERROR 被刻意排除** ⇒ **断言永远轮不到**。
   这正是本项目 my-criteria-fail-one-sided 那一族：**修法犯了被修对象的同一个错**。

✅ 能打响的构造（本件用的）：让 ctx 在**一拍之内** RUNNABLE → DONE，
   使得那个「入口拍残值 1」出现时 wd_cnt 还没来得及在活态里撞上阈值。
   做法 = **给一个空环的 ctx 敲门铃**（tail == head == 0）：
     cp_csr.sv:614 `doorbell_pulse_o = doorbell_wr` —— 写**任何值**都出脉冲（写 0 也算）；
     cp_scheduler.sv:917 doorbell + CTX_IDLE ⇒ CTX_RUNNABLE；
     下一拍 :944-951 的 DONE 检测（slot 空 + tail==head）⇒ CTX_DONE，
     而同一个 always_ff 里 :890-901 用**旧**状态（RUNNABLE=活态、无 progress）⇒ wd_cnt 0→1。
   ⇒ 再下一拍：state=CTX_DONE 且 wd_cnt=1；阈值=1 ⇒ wd_timeout=1 ⇒ **断言前件成立、后件为假**。

🔴 两条失效模式不相关的检测器（双保险，PROJECT_RULES 要求）：
   A（负控臂，Python 回读）：阈值留默认 0xFFFF 时，直接从 DUT 层次读
     ctx_state_q[1] / wd_cnt_q[1]，**实测**到「进 CTX_DONE 的那一拍 wd_cnt==1、下一拍归 0」
     ⇒ 证明**刺激确实到达了目标状态**，与 SVA 无关。
   B（正控臂，日志文本）：同一刺激 + 阈值=1 ⇒ 日志必须出现
     `a_wd_no_timeout_inactive` 的失败行。
   A 绿 + B 红 = 正控成立。只有 B 的话，「红」也可能来自别的原因。
"""
import os
import sys

import cocotb
import tbreset
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32_asm import assemble
from test_pe_top import boot_and_run, MMIO_BASE, CP_CTRL

WD_THRESHOLD   = 0xB8    # cp_csr.sv:46 / :533-538（🔴 :538 不 clamp）
CTX1_DOORBELL  = 0x28    # cp_csr.sv:606 独立译码 doorbell_wr[1]
CTX_IDLE_CODE  = 0
CTX_RUNNABLE   = 1
CTX_DONE_CODE  = 6
CTX_ERROR_CODE = 7

WD_DEFAULT = 0xFFFF      # cp_csr.sv:315 复位默认


def firmware_wd(threshold):
    """三条 CSR 写 + 自旋。**顺序照 test_pe_top 的陷阱注释：enable 在敲门铃之前。**"""
    s = [f"    li   s1, {hex(MMIO_BASE)}"]
    s.append(f"    li   t0, {threshold}")
    s.append(f"    sw   t0, {WD_THRESHOLD}(s1)")      # 1. 阈值（必须在敲门铃之前）
    s.append("    li   t0, 1")
    s.append(f"    sw   t0, {CP_CTRL}(s1)")           # 2. CP enable
    s.append(f"    sw   zero, {CTX1_DOORBELL}(s1)")   # 3. ctx1 门铃，tail=0=head ⇒ 空环
    s.append("spin:")
    s.append("    j    spin")
    return assemble("\n".join(s), base=0x80)


class WdProbe:
    """只读逐拍采样 ctx1 的状态与看门狗计数。**取不到信号就 fail-closed。**"""

    def __init__(self, dut):
        self.sched = dut.dut.i_cp.i_scheduler
        self.missing = []
        for n in ("ctx_state_q", "wd_cnt_q", "wd_timeout"):
            if not hasattr(self.sched, n):
                self.missing.append(f"i_cp.i_scheduler.{n}")
        self.trace = []          # (cyc, state, cnt, timeout)

    def sample(self, cyc):
        try:
            st = int(self.sched.ctx_state_q[1].value)
        except Exception:                                   # noqa: BLE001
            st = -1
        try:
            cnt = int(self.sched.wd_cnt_q[1].value)
        except Exception:                                   # noqa: BLE001
            cnt = -1
        try:
            to = (int(self.sched.wd_timeout.value) >> 1) & 1
        except Exception:                                   # noqa: BLE001
            to = -1
        self.trace.append((cyc, st, cnt, to))
        return st, cnt, to


async def _run(dut, threshold, tag, ncyc=400):
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    probe = WdProbe(dut)
    assert not probe.missing, (
        "WD124-INVALID 取不到信号（层次路径问题，不是「没触发」）: " + ";".join(probe.missing))
    await boot_and_run(dut, firmware_wd(threshold))
    L = dut._log.info
    L("### WD124-BEGIN %s threshold=%d ###", tag, threshold)
    for c in range(ncyc):
        await RisingEdge(dut.clk_i)
        probe.sample(c)
    # 机器可读：只打印状态发生变化的拍，外加所有 wd_cnt != 0 的拍
    prev = None
    for cyc, st, cnt, to in probe.trace:
        if (st, cnt, to) != prev:
            L("WD124-TRACE %s cyc=%d ctx1_state=%d wd_cnt=%d wd_timeout=%d", tag, cyc, st, cnt, to)
            prev = (st, cnt, to)
    seen_done_with_residue = any(st == CTX_DONE_CODE and cnt == 1 for _, st, cnt, _ in probe.trace)
    seen_done = any(st == CTX_DONE_CODE for _, st, _, _ in probe.trace)
    seen_err = any(st == CTX_ERROR_CODE for _, st, _, _ in probe.trace)
    L("WD124-SUM %s reached_done=%d done_with_residue1=%d reached_error=%d",
      tag, int(seen_done), int(seen_done_with_residue), int(seen_err))
    L("### WD124-END %s ###", tag)
    return seen_done, seen_done_with_residue, seen_err


@cocotb.test()
async def test_wd124_negctl(dut):
    """检测器 A —— 阈值留默认 0xFFFF：刺激必须到达【CTX_DONE 且 wd_cnt==1】那一拍，且断言不红。

    🔴 这条臂是正控成立的前提：它证明「断言没红」不是因为刺激根本没走到那个状态。
    """
    done, residue, err = await _run(dut, WD_DEFAULT, "NEGCTL")
    assert done, "WD124-INVALID ctx1 从未进入 CTX_DONE ⇒ 刺激没造出目标状态，正控无意义"
    assert residue, "WD124-INVALID 没观测到【CTX_DONE 且 wd_cnt==1】的入口拍 ⇒ 残值机理与源码推导不符"
    assert not err, "WD124-INVALID 阈值默认时 ctx1 不该进 CTX_ERROR"


@cocotb.test()
async def test_wd124_posctl(dut):
    """检测器 B —— 阈值=1：`a_wd_no_timeout_inactive` 必须红（verilator $stop ⇒ Aborting）。

    🔴 **本臂【期望仿真中止】**。判据在 launch 脚本 / 日志里，不在这里：
       本臂里任何 Python 断言都跑不到（$stop 先发生）。
       若本臂**跑完了**而日志里没有那条失败行 ⇒ **正控没成立**（判决在发射脚本）。
    """
    await _run(dut, 1, "POSCTL")
    # 走到这里说明断言【没有】红 —— 那就是正控失败。
    raise AssertionError(
        "WD124-POSCTL-NOT-FIRED 阈值=1 跑完了 400 拍而断言没触发 ⇒ "
        "a_wd_no_timeout_inactive 的正控【不成立】，#124 不能关")

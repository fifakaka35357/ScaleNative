"""
WP0-a 的**绑定彩排** —— 只回答一个问题：cocotb 到底能不能绑到六段分解要用的层次根。

🔴 本件【不进 run_all】：文件名不带 `test_` 前缀 ⇒ `run_all.py` 的 glob("test_*.py")
   **结构上看不见它** ⇒ 欠账 #143 的【四个面】一个不动（先例：scratch_pad_probe.py / snap_baseline.py）。
🔴 本件【只读】：不驱动任何 DUT 内部信号、不改 RTL、不改任何在盘 test_*。
🔴 本件用**独立 SIM_BUILD**（见发射件），**不碰既有 sim_build** ——
   test_fastlane_duty.py:13 的纪律是「跑前必须 rm -rf sim_build（Vtop.mk 不依赖顶层名 ⇒
   会静默跑在错模型上）」；换一个全新的构建目录是**更强**的同一保证，且不删任何数据（不触 S-1）。

为什么要彩排（不是「读源码确认存在」就够）：
  本项目实付过 ——「源码证明命令存在**不够**：all_registers -clock_pins 源码完好却 SIGSEGV」。
  在盘对这件事有**两条互相矛盾**的先例：
    · 反面 scratch_pad_probe.py:218 逐字「判据侧不做层次探针：cocotb 从 tb 顶层
      探不进 u_tile_controller 的 **packed struct**」
    · 正面 test_wd124_poscontrol.py:75 `self.sched = dut.dut.i_cp.i_scheduler`，
      且 wd124_poscontrol_20260906.log:26 实测读出 `ctx1_state=1`
  ⇒ 我的读法是「**packed struct 不行、普通 enum/计数器行**」，但那是**推测**。本件去证。
"""
import os
import sys

import cocotb
import tbreset
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# (标签, 相对 dut.dut(=pe_top) 的路径, RTL 出处)
TARGETS = [
    ("CP.sched",   "i_cp.i_scheduler.ctx_state_q",                  "正控·已有先例 test_wd124_poscontrol.py:75"),
    ("TENS.ws",    "i_tens.ws_q",                                   "tensor_domain_top.sv:82 wstate_e ws_q"),
    ("TENS.stream","i_tens.u_stream.state_q",                       "tensor_operand_stream.sv:74 state_e state_q"),
    ("TENS.mmio",  "i_tens.u_mmio.state_q",                         "tensor_cmd_mmio_seq.sv:166 state_e state_q"),
    ("TENS.tile",  "i_tens.u_tensor.u_tile_controller.state_q",     "tensor_tile_controller.sv:263 state_e state_q"),
    ("TENS.egr",   "i_tens.u_tensor.u_egress_fragmentizer.state_q", "tensor_egress_fragmentizer.sv:215 egress_state_e"),
    ("TENS.egrow", "i_tens.u_tensor.u_egress_fragmentizer.row_cnt_q","tensor_egress_fragmentizer.sv:229 row_cnt_q"),
    # 🔴 反控：一条**必然不存在**的路径必须判 MISSING。命中 ⇒ 说明解析器恒真、本彩排全篇无效。
    ("NEGCTL",     "i_tens.u_NOSUCH_WP0_ZZZ.state_q",               "反控·不存在的实例名"),
]


def _resolve(root, path):
    obj = root
    for part in path.split("."):
        if not hasattr(obj, part):
            return None, part
        obj = getattr(obj, part)
    return obj, None


@cocotb.test()
async def wp0_bind_rehearse(dut):
    """只做三件事：复位、走几拍、逐个试绑。绑不到就明说，不静默跳过。"""
    # 🔴 顺序照抄在盘可用先例（test_fastlane_duty.py:599-600 / test_wd124_poscontrol.py:100）：
    #   **先 preclock_reset、后起时钟**，且复位脚名是 `rst_ni` 不是 `rst_n`。
    #   我第一稿写 `tbreset.reset(dut)` —— 该函数**不存在**（tbreset.py 只有 preclock_reset），
    #   彩排第一枪就打掉了。⇒ 「源码证明函数存在」这一步我都没做就写了，记一笔。
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())
    for _ in range(20):
        await RisingEdge(dut.clk_i)

    core = dut.dut
    ok, miss = [], []
    for tag, path, src in TARGETS:
        obj, failed_at = _resolve(core, path)
        if obj is None:
            miss.append((tag, path, failed_at))
            dut._log.info("WP0BIND MISSING %-12s %-50s 断在 '%s'   (%s)" % (tag, path, failed_at, src))
            continue
        # 🔴 彩排第三枪（本轮实测）：`ctx_state_q` **绑得到**，但 `int(obj.value)` 当场抛
        #   `int() argument must be ... not 'list'` —— 它是**数组**，`.value` 返回 list。
        #   在盘先例读的是 `ctx_state_q[1]` 这个**元素**（test_wd124_poscontrol.py:75 起）。
        #   ⇒ 标量与数组要分开读；**把「是数组」误判成「读不出」会把一个可用的根判死**。
        try:
            raw = obj.value
            if isinstance(raw, list):
                v = "[array len=%d] elem0=%s" % (len(raw), int(raw[0]))
                w = "array"
            else:
                v = int(raw)
                w = len(obj)
            dut._log.info("WP0BIND FOUND   %-12s %-50s width=%-6s value=%s   (%s)" % (tag, path, w, v, src))
        except Exception as e:  # 能绑到但读不出值，也算没到手
            miss.append((tag, path, "读值失败: %s" % e))
            dut._log.info("WP0BIND UNREADABLE %-9s %-50s %s" % (tag, path, e))
            continue
        ok.append(tag)

    neg_ok = any(t == "NEGCTL" for t, _, _ in miss)
    dut._log.info("WP0BIND-SUMMARY found=%d missing=%d negctl_missing=%s" % (len(ok), len(miss), neg_ok))
    dut._log.info("WP0BIND-FOUND-LIST %s" % ",".join(ok))
    dut._log.info("WP0BIND-MISS-LIST %s" % ",".join(t for t, _, _ in miss))

    # 🔴 fail-closed 判据：
    #   ① 反控必须 MISSING —— 否则解析器恒真，FOUND 全都不可信
    assert neg_ok, "WP0BIND-C3-RED 反控命中了一条不存在的路径 ⇒ 解析器恒真，本彩排无效"
    #   ② 正控（已有先例的那条）必须 FOUND —— 否则是环境/顶层错了，不是「层次探针不行」
    assert "CP.sched" in ok, "WP0BIND-POS-RED 已有在盘先例的 CP.sched 都绑不到 ⇒ 是本件的调用面错了，不是结论"
    # 🔴 其余六个绑不到【不判 fail】—— 本件是【探路】不是守门：
    #    它要交付的是「哪些能绑、哪些不能」这份事实，而不是一个红绿灯。

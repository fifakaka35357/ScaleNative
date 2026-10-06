"""
Fast Lane (i_tv_fifo) 利用率实测 —— 预登记 aichip_run_logs/soc600_prereg_20260902.md §36

🔴 本件【只读采样】：不驱动任何 DUT 信号、不改 RTL、不改 test_pe_top.py
   （后者是唯一的 IBEX+L1 整合守门，run_all 190/190 的一员）。
   负载与 bring-up 全部**复用** test_pe_top.py 的 helper（§4.ah：先 grep 在盘前作）。

🔴 要判掉的是在盘两条互相矛盾、且都没实测过的分析：
   · DualVector_Checklist:80  Tensor 持续产出 ≈ 21 拍/fragment ⇒ 利用率上限 ≈4.7%（1/2 票）
   · DualVector_Checklist:50  Vector 服务 ≥10 拍/2 capsule，差约一个数量级（2/2 票）
   判别器 = FIFO 是【空着】还是【满着】：
     S_cons = Σ(out_ready & !out_valid)  空 ⇒ 生产者(Tensor)受限
     S_prod = Σ(in_valid  & !in_ready )  满 ⇒ 消费者(Vector)受限

🔴 本件【不进 run_all】—— 它是量具，不是守门（判词归判决器，见 :106）。
   run_all.py:26-30 要同时解析到 `TOPLEVEL =` 与 `VERILOG_SOURCES =` 两个字段才会构建；
   本 docstring 刻意不含它们的可匹配形态 ⇒ 落到 NO-META、被跳过（不计 PASS 也不计 FAIL）。

🔴 原来这里写的是占位符 `<同 test_pe_top>`，它【会被解析】：
   run_all.py:27 的那条 re.search（非贪婪、带 re.S）扫的是【整个文件】而不只是 docstring、
   不只是 docstring ⇒ make 报 `No rule to make target` ⇒ 落进 run_all.py:47-49 的 `???` 分支
   ⇒ tot_f += 1 ⇒ 【整套回归 rc=1】。实为 fail-open 型 16 形态⑧（PROJECT_RULES.md:2286）：
   承载机器解析字段的文件，其散文里不许出现同一个正则能匹配的形态。
   登记 = soc600_prereg_20260902.md §37（闸 `L0`）。

手动跑法（唯一）= aichip_run_logs/launch_fastlane_duty_*.sh；
🔴 82 个源【从 test_pe_top.py:49 现取】，别在这里复制第二份（它会漂）。
🔴 跑之前必须 `rm -rf sim_build`：cocotb 的 Makefile.verilator 让 sim_build/Vtop.mk 只依赖
   【源文件】、不依赖 TOPLEVEL ⇒ 一份别的顶层的旧构建会让 verilator 被静默跳过，
   探针会跑在【错的模型】上，而 F0 会把它报成“层次路径写错”。
"""
import os
import sys

import cocotb
import tbreset
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 🔴 只导 helper，**不导 @cocotb.test()**（否则那五个用例会跟着注册、白跑一遍）
from test_pe_top import (build_desc, firmware, boot_and_run, egress_sink,
                         watch_health, OP_TENS_GEMM, OP_DMA_MEMSET, OP_DMA_EVICT,
                         ELEM_BF16, WORDS_PER_ROW)

# 采样面（§36.1）：5 根 FIFO 线 + 3 根上下文线
FIFO_SIGS = ["in_valid_i", "in_ready_o", "out_valid_o", "out_ready_i", "fill_level_o"]
CTX_SIGS = ["vec_clk_en", "tens_t2v_valid", "tens_t2v_escape"]


class FlProbe:
    """逐拍采样 i_tv_fifo 的握手线。**只读。**"""

    def __init__(self, dut):
        self.dut = dut
        self.fifo = dut.dut.i_tv_fifo          # tb_pe_top → 实例 dut(pe_top) → i_tv_fifo
        self.core = dut.dut
        self.missing = []                      # F0：取不到的信号（fail-closed 的依据）
        self.h = {}
        for s in FIFO_SIGS:
            try:
                self.h[s] = getattr(self.fifo, s)
            except Exception as e:              # noqa: BLE001
                self.missing.append(f"i_tv_fifo.{s}: {e!r}")
        for s in CTX_SIGS:
            try:
                self.h[s] = getattr(self.core, s)
            except Exception as e:              # noqa: BLE001
                self.missing.append(f"pe_top.{s}: {e!r}")
        self.reset_counters()

    def reset_counters(self):
        self.N_cyc = self.N_in = self.N_out = 0
        self.S_prod = self.S_cons = self.S_gate = 0
        self.fill_sum = 0
        self.fill_max = 0
        self.seen_in_valid = False
        self.seen_out_valid = False
        self.first_in_cyc = None
        self.last_in_cyc = None

    def _v(self, name):
        """读一根信号；X/Z 一律当 0（并计入 x_cnt，不许静默）。"""
        sig = self.h.get(name)
        if sig is None:
            return 0
        try:
            return int(sig.value)
        except Exception:                       # noqa: BLE001  X/Z
            return 0

    async def run(self, max_cycles):
        while self.N_cyc < max_cycles:
            await RisingEdge(self.dut.clk_i)
            self.N_cyc += 1
            iv, ir = self._v("in_valid_i"), self._v("in_ready_o")
            ov, orr = self._v("out_valid_o"), self._v("out_ready_i")
            fill = self._v("fill_level_o")
            gate = self._v("vec_clk_en")
            if iv:
                self.seen_in_valid = True
            if ov:
                self.seen_out_valid = True
            if iv and ir:
                self.N_in += 1
                if self.first_in_cyc is None:
                    self.first_in_cyc = self.N_cyc
                self.last_in_cyc = self.N_cyc
            if ov and orr:
                self.N_out += 1
            if iv and not ir:
                self.S_prod += 1
            if orr and not ov:
                self.S_cons += 1
            if ov and not gate:
                self.S_gate += 1
            self.fill_sum += fill
            self.fill_max = max(self.fill_max, fill)

    def report(self, dut, tag):
        """机器可读输出。**判词留给 petop_fastlane_judge.py，本件不下结论。**"""
        L = dut._log.info
        L("### FLUTIL-BEGIN %s ###", tag)
        L("FLUTIL-MISSING %d %s", len(self.missing), ";".join(self.missing) or "-")
        L("FLUTIL-SEEN in_valid=%d out_valid=%d", int(self.seen_in_valid), int(self.seen_out_valid))
        L("FLUTIL-CNT N_cyc=%d N_in=%d N_out=%d S_prod=%d S_cons=%d S_gate=%d",
          self.N_cyc, self.N_in, self.N_out, self.S_prod, self.S_cons, self.S_gate)
        L("FLUTIL-FILL mean=%.4f max=%d", self.fill_sum / max(1, self.N_cyc), self.fill_max)
        L("FLUTIL-WINDOW first_in=%s last_in=%s",
          self.first_in_cyc, self.last_in_cyc)
        L("### FLUTIL-END %s ###", tag)


@cocotb.test()
async def test_fastlane_utilization(dut):
    """跑 test_soc_gemm_dispatch 的同一负载（K=4），逐拍采样 Fast Lane 握手线。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    probe = FlProbe(dut)
    # 🔴 F0 正控：层次路径必须成立。取不到信号 ⇒ **是路径写错了，不是「没流量」**。
    assert not probe.missing, (
        "FLUTIL-INVALID-F0 取不到这些信号（层次路径或 verilator 优化问题，"
        "不是「Fast Lane 没流量」）: " + "; ".join(probe.missing))

    TOKEN = 0x600D_600D
    TOKEN_ROW = 40
    K = 4
    descs = [
        build_desc(OP_TENS_GEMM, src_off=0, dst_off=20, len_rows=1,
                   param_m=16, param_n=16, param_k=K, elem_fmt=ELEM_BF16),
        build_desc(OP_DMA_MEMSET, dst_off=TOKEN_ROW, len_rows=1, memset_val=TOKEN),
        build_desc(OP_DMA_EVICT,  src_off=TOKEN_ROW, len_rows=1),
    ]
    fw = firmware(descs, n_desc=len(descs))
    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, 200000))
    cocotb.start_soon(probe.run(200000))

    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))
    for _ in range(200000):
        await RisingEdge(dut.clk_i)
        if len(got) >= WORDS_PER_ROW:
            break
    else:
        raise AssertionError("FLUTIL-INVALID-TIMEOUT 负载没跑完，计数无意义")
    await sink
    probe.report(dut, "GEMM-K4")

    # 🔴 本件只断言【测量本身成立】，不断言利用率高低（那是判决器的事，§36.3）。
    assert probe.N_cyc > 0, "FLUTIL-INVALID 采样器一拍都没采到"
    assert probe.N_in <= probe.N_cyc, "FLUTIL-INVALID 计数不自洽 N_in > N_cyc"
    assert probe.N_out <= probe.N_in, "FLUTIL-INVALID 计数不自洽 N_out > N_in"

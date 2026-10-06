"""
Fast Lane 消费侧服务速率实测 —— 预登记 soc600_prereg_20260902.md §36（第二臂）

🔴 pe_top 那一臂（test_fastlane_util）已测出**生产侧**：Tensor 以 **1 capsule/拍** 满速产出
   （5 个 beat 落在 5 个连续拍里），然后 FIFO 灌满被堵 36 拍，**消费侧成交 0**
   —— 因为那个负载**从没命令 Vector 去消费**（`S_cons=0` 且 `N_out=0` ⇒ `out_ready` 从未拉高）。
   ⇒ 该臂**判不了消费速率**，这一臂补上。

本臂复用在盘的 `tb_vec_consume_e2e`（**直接驱动真 `vector_unit_top`**，无 FIFO），
只读采样 `cap_valid_i` / `cap_ready_o`，量：
  · `R_cyc` = Σ(cap_ready_o)          —— 消费者【就绪】的拍数（决定性判别器）
  · `A_cyc` = Σ(cap_valid & cap_ready) —— 实际成交
  · `first_ready` / `last_accept`      —— 服务窗口
🔴 `R_cyc` 正是 pe_top 那一臂缺的那个计数器：`S_cons=0` 有两个成因
   （消费者忙 / 消费者从没就绪），**没有 `R_cyc` 逐字分不出来**（`#105` 形状）。

🔴 本件【只读采样】，不驱动任何信号；负载与检查全部复用 test_vec_consume_e2e。
"""
import os
import sys

import cocotb
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_vec_consume_e2e as base


class RateProbe:
    def __init__(self, dut):
        self.dut = dut
        self.missing = []
        self.h = {}
        for s in ("cap_valid_i", "cap_ready_o"):
            try:
                self.h[s] = getattr(dut, s)
            except Exception as e:                     # noqa: BLE001
                self.missing.append(f"{s}: {e!r}")
        self.N_cyc = self.R_cyc = self.A_cyc = 0
        self.V_cyc = 0
        self.first_ready = None
        self.last_accept = None
        self.stall = 0                                 # valid 但 !ready

    def _v(self, n):
        s = self.h.get(n)
        if s is None:
            return 0
        try:
            return int(s.value)
        except Exception:                              # noqa: BLE001
            return 0

    async def run(self, n):
        while self.N_cyc < n:
            await RisingEdge(self.dut.clk_i)
            self.N_cyc += 1
            v, r = self._v("cap_valid_i"), self._v("cap_ready_o")
            if r:
                self.R_cyc += 1
                if self.first_ready is None:
                    self.first_ready = self.N_cyc
            if v:
                self.V_cyc += 1
            if v and r:
                self.A_cyc += 1
                self.last_accept = self.N_cyc
            if v and not r:
                self.stall += 1

    def report(self, tag):
        L = self.dut._log.info
        L("### FLRATE-BEGIN %s ###", tag)
        L("FLRATE-MISSING %d %s", len(self.missing), ";".join(self.missing) or "-")
        L("FLRATE-CNT N_cyc=%d R_cyc=%d V_cyc=%d A_cyc=%d stall=%d",
          self.N_cyc, self.R_cyc, self.V_cyc, self.A_cyc, self.stall)
        L("FLRATE-WINDOW first_ready=%s last_accept=%s", self.first_ready, self.last_accept)
        L("### FLRATE-END %s ###", tag)


@cocotb.test()
async def test_fastlane_consume_rate(dut):
    """跑 test_vec_consume_e2e 的同一负载，逐拍采样消费侧就绪/成交。"""
    probe = RateProbe(dut)
    assert not probe.missing, ("FLRATE-INVALID-F0 取不到信号（层次路径问题，"
                              "不是「没流量」）: " + "; ".join(probe.missing))
    cocotb.start_soon(probe.run(200000))
    # 🔴 直接调用在盘用例体：负载、检查、断言一律复用，本件只多挂一个采样器。
    await base.test_vec_consume_e2e(dut)
    probe.report("VEC-RESADD")
    assert probe.N_cyc > 0, "FLRATE-INVALID 采样器一拍都没采到"

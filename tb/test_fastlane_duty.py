"""
Fast Lane 占空比 —— **8 个臂的包装**（预登记 aichip_run_logs/soc600_prereg_20260902.md §37/§38）

🔴🔴 2026-09-11：构造器 + FlProbe2 + `_run_arm` 已**提取到 `duty_arm.py`**
   （`§8 D-WP0A-RUN-2026-09-11 ②`，用户拍板）。本文件只剩 8 个 `@cocotb.test` 包装。
   **为什么这么拆**：`duty_arm.py` 不带 `test_` 前缀 ⇒ `run_all.py` 的 glob 看不见它；
   而本文件仍然是那 8 个 `@cocotb.test` 的家 ⇒ **回归的四个面一个不动**。

🔴 本件【不进 run_all】—— 量具不是守门。
   run_all.py:26-30 要同时解析到两个字段才会构建；本 docstring 刻意不含它们的可匹配形态。
   手动跑法 = aichip_run_logs/launch_duty_gextract.sh（🔴 **不要用 09-05 那个发射件** ——
   它开跑第一件事就把基准日志清空，而那是 C=19 / K*=21 那批在盘数字的唯一原始证据）。
   🔴 跑之前必须换一个**全新的构建目录**（`SIM_BUILD=...`），不是 `rm -rf` 既有的那个：
   `Vtop.mk` 不依赖顶层名 ⇒ 复用别的顶层的构建目录会**静默跑在错的模型上**；
   换新目录是同一保证的更强形式，且**不删任何数据**（不触停机清单 S-1）。

消费者为什么必须是 OP_VEC_RESADD_RESIDENT(0x05) 而不是 OP_VEC_RESADD(0x04)：§37.1-③/④，
全文见 duty_arm.py 的模块 docstring（那一段随构造器一起搬过去了）。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cocotb
from duty_arm import _run_arm

@cocotb.test()
async def test_fastlane_duty_c1_k4(dut):
    """臂 C1：K=4, T=3 —— 测消费者周期 C（实测 C_med=19，与逐态推导逐拍吻合）。

    🔴 「消费受限」在串行单环臂里不是判出来的（欠账 #123）：S_cons 结构恒 0、
       E_hungry 在本臂形下也恒 0 ⇒ 判词带 (DEGENERATE)。
    """
    await _run_arm(dut, "C1-K4-T3", K=4, T=3)


@cocotb.test()
async def test_fastlane_duty_c2_k24(dut):
    """臂 C2：K=24, T=3 —— 测 P_tile（与 C1 的差给出口径无关的斜率）。

    🔴 2026-09-05 实测后订正：本 docstring 原写「事前推导落在【生产受限】域」并说两臂互为
       正控。**那条推导是【流水化】口径 P = max(P_prod, 16C) 下的**，而本文件跑的是
       【串行】单环臂 P = P_prod + 16C + 5 ⇒ **两臂必然同域**（实测三臂全 FL-CONSBOUND）。
       E-D1 已证伪，M3 已按 soc600_prereg §37.11.3-4 降级为「两臂方向一致」。
       要落进 FL-PRODBOUND 需要双 ctx 重叠臂（§37.2.2-①，未做；欠账 #123）。
    🔴 两臂真正的正控价值在【斜率】：ΔP_tile/ΔK 必须 = 11，它把 C 与 CP 开销全消掉（闸 M1b）。
    """
    await _run_arm(dut, "C2-K24-T3", K=24, T=3)


@cocotb.test()
async def test_fastlane_duty_pc_halfsel1(dut):
    """🔴 正控臂：与 C1 同形，但 half_sel=1（L2 高半区）。**它不产出占空比数**。

    它证的是 `pe_assertions §10.5-RO` 那条【新加的 bind】是真接上的：
    · `tb/Makefile` 带全局 `-Wno-PINMISSING` ⇒ 一个没接的 input 会**恒读 0 且无诊断**；
    · 若 `vec_ro_half_sel` 没接上（恒 0），而描述符要的是高半区，
      则新加的臂 (b)「非选中半区必须灭」会**当场炸 bank 8**，
      报文里印出的 `half_sel=0` 与描述符的 1 自相矛盾 ⇒ 自诊断。
    · 若接上了，两条臂只是**交换角色**（8-15 查活、0-7 查灭），本臂应当全绿。
    ⇒ **这一趟同时证明「新端口真连上了」与「两条臂仍然会红」。**
    """
    await _run_arm(dut, "PC-HALFSEL1", K=4, T=1, half_sel=1)


# ═══════════════ ARM D 与它的负控（预登记 soc600_prereg §38）═══════════════

@cocotb.test()
async def test_fld_s_k4(dut):
    """S-K4：单 ctx、K=4、T=6 —— 🔴 **负控**：重叠检测器必须给 0（OVL_cmd / n_interleave）。"""
    await _run_arm(dut, "S-K4", K=4, T=6, budget=120000)


@cocotb.test()
async def test_fld_s_k48(dut):
    """S-K48：单 ctx、K=48、T=6 —— 负控 + 串行/流水化的直接对照（E-E5）。"""
    await _run_arm(dut, "S-K48", K=48, T=6, budget=120000)


@cocotb.test()
async def test_fld_d_k4(dut):
    """D-K4：双 ctx、K=4、T=6 —— **判别臂**，事前推导落在【消费者绑定】侧（比值 0.41–0.44）。"""
    await _run_arm(dut, "D-K4", K=4, T=6, budget=120000, dual=True)


@cocotb.test()
async def test_fld_d_k24(dut):
    """D-K24：双 ctx、K=24、T=6 —— 🔴 crossover 探针，**不产判词**。

    比值 (P_prod+d)/(Q−d) ∈ [1.12, 1.18]，落在 d 的不确定度里 ⇒ §38.6 明令它不当判别臂。
    """
    await _run_arm(dut, "D-K24", K=24, T=6, budget=120000, dual=True)


@cocotb.test()
async def test_fld_d_k48(dut):
    """D-K48：双 ctx、K=48、T=6 —— **判别臂**，事前推导落在【生产者绑定】侧（比值 1.98–2.06）。

    🔴 它是关掉欠账 #123 的那一趟：E_hungry 在这里必须显著 > 0（预测 ≈313/tile）。
    """
    await _run_arm(dut, "D-K48", K=48, T=6, budget=120000, dual=True)

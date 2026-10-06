"""
DRAFT_vec_pipe6_regression.py — 草稿：门禁跑通后合入 test_vec_compact_mx_store.py
或独立注册进 run_all.py。文件名以 DRAFT_ 开头，run_all.py:20 的
glob("test_*.py") 不会收集它——合入前它不参与门禁。

覆盖对象 = [VEC-PIPE ⑥]（VST_ACTIVE 拆 LANE/REDUCE 两拍，lane_results_q /
lane_valid_q / active_phase_q 新寄存链）叠加 v6.0 R3b Bug#4/#6 的
block32 双窗寄存源选择（partial_lane_results_q=pass0 快照 → 窗0，
lane_results_q=pass1 → 窗1）与背靠背命令间的状态清理
（partial_lane_valid_q / compact_* / active_phase_q，vector_unit.sv:2270-2281、2287-2299）。

── 合入清单（二选一）───────────────────────────────────────────────────────
 A)（推荐）把本文件的 3 个 @cocotb.test 函数体复制进
    test_vec_compact_mx_store.py 末尾，并删除本文件的
    "from test_vec_compact_mx_store import ..." 行（合入后同模块直接可见）。
    run_all.py：零改动（run_all.py:20 已 glob 到 test_vec_compact_mx_store.py，
    其 docstring 第 14-26 行已带 TOPLEVEL/VERILOG_SOURCES 元数据；cocotb 自动
    跑模块内全部 @cocotb.test）。
    Makefile：零改动（tb/Makefile:10-12 的 TOPLEVEL/MODULE/VERILOG_SOURCES
    全是 ?= 可覆盖变量，run_all.py:34-36 按文件逐个传参）。
 B)（独立注册）git mv DRAFT_vec_pipe6_regression.py test_vec_pipe6_regression.py
    即可——本 docstring 已内嵌与 test_vec_compact_mx_store.py 完全相同的
    Run: 元数据块（见下），run_all.py:26-32 会解析出 TOPLEVEL/VERILOG_SOURCES；
    "from test_vec_compact_mx_store import ..." 保留（同目录 import，cocotb
    只收集 MODULE 指定文件里的 test，不会重复跑被 import 模块的 test）。
    Makefile 同样零改动。

Run: cd tb && make MODULE=test_vec_pipe6_regression TOPLEVEL=tb_vec_compact_mx_store \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Vector/vec_pkg.sv \
        ../rtl/Vector/Unchanged/Vector/vec_tz_shifter.sv ../rtl/Vector/vec_mant_corr_mul.sv \
        ../rtl/Vector/Unchanged/Vector/vec_lane_array.sv ../rtl/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
        ../rtl/Vector/Unchanged/Vector/vec_renorm_quant.sv ../rtl/Vector/Unchanged/Vector/vec_result_packer.sv \
        ../rtl/Vector/Unchanged/Vector/vec_desc_decode.sv ../rtl/Vector/Unchanged/Vector/vec_fastpath_if.sv \
        ../rtl/Vector/Unchanged/Vector/vec_ingress_arb.sv ../rtl/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
        ../rtl/Vector/vec_operand_queue.sv ../rtl/Vector/vec_scale_adapter.sv ../rtl/Vector/vec_renorm_xpass.sv \
        ../rtl/Vector/vec_reduce_max_combine.sv ../rtl/Tensor/requantizer.sv ../rtl/Vector/vector_unit.sv \
        ../rtl/Vector/vec_assertions.sv \
        ../rtl/IBEX_SRAM/vector_unit_top.sv ../rtl/IBEX_SRAM/sram_1rw1r_wrapper.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_bank.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_ro_arbiter.sv \
        ../rtl/IBEX_SRAM/Memory_Subsystem/l2_rw_arbiter.sv ../rtl/IBEX_SRAM/Memory_Subsystem/l2_subsystem.sv \
        ../tb/tb_vec_compact_mx_store.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "Model"))
import bfp_golden as g

# 复用主测试的 fixture / 采集器 / 黄金封装（合入方式 A 时删除本行）
from test_vec_compact_mx_store import (
    reset, issue_cmd, push_cap, collect_writes, check_row, preset_row,
    row_words, pack_lanes, golden_window,
    PAT_PAY, PAT_SC, ELEM_MXFP4, ELEM_MXFP8, BS16, BS32, DST_ROW, SC_ROW,
)


# ---------------------------------------------------------------------------
# 1. [VEC-PIPE ⑥ / R3b Bug#4+#6] block32 双窗 = 双源（legacy 全 payload 口味）。
#
#    覆盖缺口：test_default_store_regression 只做 "捕获写 vs 读回" 自洽比对，
#    从不比对输入 lanes —— 若窗0/窗1 都错拿 pass-1 数据（Bug#4 回归）或窗序
#    写反（Bug#6 回归），它照样绿。本测试把两窗写数据逐字节钉到各自的
#    pass-0 / pass-1 输入上，并 **显式断言两窗数据不同**。
#
#    寄存链被检路径（vector_unit.sv）：
#      LANE 拍捕获 lane_results_q(:2297-2299) → REDUCE 拍 pass0 快照
#      partial_lane_results_q(:2124-2129) → effective_lane_results 选择器
#      (:1146-1157, 窗0=快照 窗1=lane_results_q) → result_cap_q → L2 写。
#
#    红绿纪律（故意注错 → 怎么红）：
#      · 删掉 partial_lane_results_q 锁存（:2127-2128）或让 effective_lane_results
#        恒取 lane_results_q（:1153）→ 窗0 写出 pass-1 数据 →
#        "win0 wdata != pack_lanes(lanes0)" 逐字节红，且 "两窗必须不同" 断言红。
#      · 把 egress_window_q 提前到进 L2_WB 就步进（Bug#6 回归）→ 窗0 数据落
#        DST+1 → 行号断言 + 读回比对红。
#      · 去掉 pass 步进的 REDUCE 拍门（:2089 的 active_phase_q &&）→ LANE 拍
#        双步进污染 pass0 快照 → 窗0 数据红（或 FSM 早退 → 写数≠2 红）。
#      · lane_valid_q 捕获谓词坏掉（:2297 改错）→ result_valid 不再置位 →
#        watchdog 兜底或超时 → collect_writes 的 done/写数断言红。
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_block32_dualwin_pass0_snapshot_legacy(dut):
    """legacy block32 双窗：窗0=pass0 快照、窗1=pass1，逐字节钉输入+显式两窗不同。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    lanes0 = [0x1100 + 7 * i for i in range(16)]     # pass-0（窗0 应写出的数据）
    lanes1 = [0x2200 + 13 * i for i in range(16)]    # pass-1（窗1 应写出的数据）

    # oracle 诚实性：两窗数据必须不同源可辨（否则别名 bug 不可见）
    if pack_lanes(lanes0) == pack_lanes(lanes1):
        fails.append("test vector defect: lanes0 == lanes1 (aliasing invisible)")

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)            # legacy 不许碰 sidecar

    await issue_cmd(dut, 0, BS32, DST_ROW, SC_ROW, fails)      # elem_fmt=0 -> legacy
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), 0, 127, 0, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), 0, 127, 0, fails)
    writes = await collect_writes(dut, fails)

    if not fails and len(writes) != 2:
        fails.append("expected 2 full-mask writes, got %d: %s"
                     % (len(writes), [(hex(r), hex(m)) for r, m, _ in writes]))
    if not fails:
        # 数据级：窗0 必须逐字节等于 pass-0 输入（identity 通路：E8M0 byte127
        # -> exp0 / mant_corr 128，lane mant 原样透传进 result_cap payload）
        for w, (exp_row, lanes) in enumerate([(DST_ROW, lanes0), (DST_ROW + 1, lanes1)]):
            row, mask, wdata = writes[w]
            if (row, mask) != (exp_row, 0xFF):
                fails.append("win%d (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                             % (w, row, mask, exp_row))
            if wdata != pack_lanes(lanes):
                for i in range(16):
                    got = (wdata >> (16 * i)) & 0xFFFF
                    exp = (pack_lanes(lanes) >> (16 * i)) & 0xFFFF
                    if got != exp:
                        fails.append("win%d lane %d: wdata 0x%04x != input 0x%04x "
                                     "(pass%d source lost)" % (w, i, got, exp, w))
                        break
        # 显式断言：两窗写数据不同（别名/同源即红，独立于黄金模型簿记）
        if writes[0][2] == writes[1][2]:
            fails.append("window 0 and window 1 wrote IDENTICAL data "
                         "(pass0-snapshot/pass1 dual-source collapsed)")
    if not fails:
        w0 = [(pack_lanes(lanes0) >> (32 * j)) & 0xFFFFFFFF for j in range(8)]
        w1 = [(pack_lanes(lanes1) >> (32 * j)) & 0xFFFFFFFF for j in range(8)]
        await check_row(dut, DST_ROW, w0, fails, "dualwin legacy win0")
        await check_row(dut, DST_ROW + 1, w1, fails, "dualwin legacy win1")
        await check_row(dut, SC_ROW, PAT_SC, fails, "dualwin legacy sidecar-untouched")

    assert not fails, "block32 dual-window pass0-snapshot failures:\n  " + "\n  ".join(fails)
    dut._log.info("block32 legacy dual-window: win0==pass0 input, win1==pass1 input, "
                  "windows explicitly distinct")


# ---------------------------------------------------------------------------
# 2. 同缺口的 compact 口味（MXFP8+BS_32）：两窗按各自黄金 requant 比对，且构造
#    两窗幅值量级悬殊 → E8M0 scale byte 也必须不同。窗别名不但打红 payload，
#    还打红 sidecar 字节（双证据）。含 oracle 诚实性断言（p0!=p1 且 sc0!=sc1）。
#
#    红绿纪律：注错方式同测试 1；额外地，若 VST_CMX_PREP 的 per-window
#    requant 从错误窗口的 result_cap_q 取数（F8 寄存链回归），payload 黄金
#    比对红且 sidecar 字节 (sc1<<8|sc0) 顺序比对红。
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_block32_dualwin_distinct_compact_scales(dut):
    """MXFP8+BS_32 双窗：窗间幅值悬殊 -> payload 与 E8M0 scale byte 双双必须不同。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    SREF = 0
    lanes0 = [31000 - 1900 * i if i % 2 == 0 else -(30000 - 1800 * i)
              for i in range(16)]                       # 大幅值窗
    lanes1 = [60 + 9 * i if i % 2 == 0 else -(50 + 7 * i)
              for i in range(16)]                       # 小幅值窗

    p0, sc0 = golden_window(lanes0, SREF, 8, g.SCALE_E8M0)
    p1, sc1 = golden_window(lanes1, SREF, 8, g.SCALE_E8M0)
    if p0 == p1:
        fails.append("test vector defect: golden payloads identical (aliasing invisible)")
    if sc0 == sc1:
        fails.append("test vector defect: golden scale bytes identical (0x%02x) — "
                     "window aliasing would not show in the sidecar" % sc0)

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP8, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), SREF, 127, 1, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), SREF, 127, 1, fails)
    writes = await collect_writes(dut, fails)

    if not fails and len(writes) != 3:
        fails.append("expected 3 granted writes (2 payload + 1 sidecar), got %d" % len(writes))
    if not fails:
        for w, (exp_row, exp_p) in enumerate([(DST_ROW, p0), (DST_ROW + 1, p1)]):
            row, mask, wdata = writes[w]
            if (row, mask) != (exp_row, 0x0F):
                fails.append("payload write %d (row 0x%x, mask 0x%02x) != (0x%x, 0x0F)"
                             % (w, row, mask, exp_row))
            if (wdata & ((1 << 128) - 1)) != exp_p:
                fails.append("payload write %d low128 0x%032x != golden 0x%032x"
                             % (w, wdata & ((1 << 128) - 1), exp_p))
        if (writes[0][2] & ((1 << 128) - 1)) == (writes[1][2] & ((1 << 128) - 1)):
            fails.append("compact windows wrote IDENTICAL payloads (dual-source collapsed)")
        row, mask, _ = writes[2]
        if (row, mask) != (SC_ROW, 0xFF):
            fails.append("sidecar write (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                         % (row, mask, SC_ROW))
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, p0, 128), fails, "cmpx win0")
        await check_row(dut, DST_ROW + 1, row_words(PAT_PAY, p1, 128), fails, "cmpx win1")
        exp_sc = list(PAT_SC)
        exp_sc[0] = (PAT_SC[0] & 0xFFFF0000) | (sc1 << 8) | sc0
        await check_row(dut, SC_ROW, exp_sc, fails, "cmpx sidecar")

    assert not fails, "compact dual-window distinct-scale failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXFP8+BS_32 dual-window: distinct payloads AND distinct E8M0 scale "
                  "bytes 0x%02x/0x%02x golden-exact" % (sc0, sc1))


# ---------------------------------------------------------------------------
# 3. 背靠背连发 store（同 DUT、无复位、4 条命令、fmt 交替）：
#      cmd1 MXFP4+BS_32 compact → cmd2 legacy(fmt=0)+BS_32 →
#      cmd3 MXFP8+BS_32 compact → cmd4 MXFP4+BS_16 (NVFP4)
#    检查每条命令自身数据级黄金比对，外加跨命令隔离：
#      · cmd2 不许产生任何 sidecar 写（写数=2、SC_B 行终检原封）
#      · cmd4 结束后回读 SC_A 行仍持 cmd1 的 scale 字节（无跨命令覆写）
#      · num_passes 2→2→2→1 交替（cmd4 单 pass，检查 pass 计数器重装）
#
#    [VEC-PIPE ⑥] 针对性：每条命令重入 VST_ACTIVE 都必须从 LANE 拍重启
#    （vector_unit.sv:2287-2296 case 外的相位翻转/复位），且 VST_DONE 臂
#    (:2270-2281) 必须清 partial_lane_valid_q / compact_wb_q / compact_scale_q /
#    compact_payload_q —— 任何残留都会把上一条命令的数据/行为漏进下一条。
#
#    红绿纪律（故意注错 → 怎么红）：
#      · 注掉 VST_DONE 臂的 compact_wb_q 清零（:2277）→ cmd2（legacy）带着
#        cmd1 的 compact_wb_q 绕进 VST_CMX_PREP → cmd2 写掩码变 0x03 或多出
#        sidecar 写 → "cmd2 恰好 2 写 / mask 0xFF / SC_B 原封" 三重红。
#      · 注掉 partial_lane_valid_q 清零（:2274）→ cmd3 窗0 错选 cmd1 的
#        pass-0 快照 → cmd3 win0 payload 黄金比对逐字节红。
#      · 破坏相位重启（:2295-2296 else 臂删掉）→ 新命令首 pass 跳过 LANE
#        捕获、消费上一条命令的陈旧 lane_results_q → 对应命令 payload 红。
#      · 注掉 compact_scale_q/compact_payload_q 清零（:2278-2280）且窗数据
#        全 0 时 → sidecar 字节残留上一条命令的 scale → sidecar 比对红。
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_back_to_back_stores_fmt_alternating(dut):
    """同 DUT 连续 4 条 store，fmt compact4/legacy/compact8/nvfp4 交替，全数据级比对。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    DST_A, DST_B, DST_C, DST_D = 0x040, 0x048, 0x050, 0x058
    SC_A, SC_B, SC_D = 0x060, 0x061, 0x063

    a0 = [900 - 110 * i if i % 3 else -(800 - 90 * i) for i in range(16)]
    a1 = [-77 - 31 * i if i % 2 else 66 + 29 * i for i in range(16)]
    b0 = [0x3300 + 5 * i for i in range(16)]
    b1 = [0x4400 + 11 * i for i in range(16)]
    c0 = [21000 - 1300 * i if i % 2 else -(20000 - 1200 * i) for i in range(16)]
    c1 = [45 + 17 * i if i % 2 else -(40 + 13 * i) for i in range(16)]
    d0 = [7, -9, 11, -13, 15, -17, 19, -21, 6, -8, 10, -12, 14, -16, 18, -20]

    for row in (DST_A, DST_A + 1, DST_B, DST_B + 1, DST_C, DST_C + 1, DST_D):
        await preset_row(dut, row, PAT_PAY)
    for row in (SC_A, SC_B, SC_D):
        await preset_row(dut, row, PAT_SC)

    # ── cmd1: MXFP4 + BS_32 compact ──
    SREF_A = -1
    await issue_cmd(dut, ELEM_MXFP4, BS32, DST_A, SC_A, fails)
    if not fails:
        await push_cap(dut, pack_lanes(a0), SREF_A, 127, 1, fails)
    if not fails:
        await push_cap(dut, pack_lanes(a1), SREF_A, 127, 1, fails)
    wr1 = await collect_writes(dut, fails)
    pa0, sa0 = golden_window(a0, SREF_A, 4, g.SCALE_E8M0)
    pa1, sa1 = golden_window(a1, SREF_A, 4, g.SCALE_E8M0)
    if not fails and len(wr1) != 3:
        fails.append("cmd1: expected 3 writes, got %d" % len(wr1))
    if not fails:
        for w, (er, ep) in enumerate([(DST_A, pa0), (DST_A + 1, pa1)]):
            row, mask, wdata = wr1[w]
            if (row, mask) != (er, 0x03):
                fails.append("cmd1 win%d (row 0x%x, mask 0x%02x) != (0x%x, 0x03)"
                             % (w, row, mask, er))
            if (wdata & ((1 << 64) - 1)) != ep:
                fails.append("cmd1 win%d low64 0x%016x != golden 0x%016x"
                             % (w, wdata & ((1 << 64) - 1), ep))

    # ── cmd2: legacy (fmt=0) + BS_32，不许碰任何 sidecar ──
    if not fails:
        await issue_cmd(dut, 0, BS32, DST_B, SC_B, fails)
    if not fails:
        await push_cap(dut, pack_lanes(b0), 0, 127, 0, fails)
    if not fails:
        await push_cap(dut, pack_lanes(b1), 0, 127, 0, fails)
    wr2 = await collect_writes(dut, fails)
    if not fails and len(wr2) != 2:
        fails.append("cmd2 (legacy after compact): expected exactly 2 writes "
                     "(NO sidecar; stale compact_wb_q?), got %d: %s"
                     % (len(wr2), [(hex(r), hex(m)) for r, m, _ in wr2]))
    if not fails:
        for w, (er, lanes) in enumerate([(DST_B, b0), (DST_B + 1, b1)]):
            row, mask, wdata = wr2[w]
            if (row, mask) != (er, 0xFF):
                fails.append("cmd2 win%d (row 0x%x, mask 0x%02x) != (0x%x, 0xFF) "
                             "(compact state leaked into legacy?)" % (w, row, mask, er))
            if wdata != pack_lanes(lanes):
                fails.append("cmd2 win%d wdata != its OWN input lanes "
                             "(cross-command data leak)" % w)

    # ── cmd3: MXFP8 + BS_32 compact（sidecar 复用 SC_A：RMW 必须保住 cmd1 字节外的 30B）──
    SREF_C = 2
    if not fails:
        await issue_cmd(dut, ELEM_MXFP8, BS32, DST_C, SC_A, fails)
    if not fails:
        await push_cap(dut, pack_lanes(c0), SREF_C, 127, 1, fails)
    if not fails:
        await push_cap(dut, pack_lanes(c1), SREF_C, 127, 1, fails)
    wr3 = await collect_writes(dut, fails)
    pc0, sc_c0 = golden_window(c0, SREF_C, 8, g.SCALE_E8M0)
    pc1, sc_c1 = golden_window(c1, SREF_C, 8, g.SCALE_E8M0)
    if not fails and len(wr3) != 3:
        fails.append("cmd3: expected 3 writes, got %d" % len(wr3))
    if not fails:
        for w, (er, ep) in enumerate([(DST_C, pc0), (DST_C + 1, pc1)]):
            row, mask, wdata = wr3[w]
            if (row, mask) != (er, 0x0F):
                fails.append("cmd3 win%d (row 0x%x, mask 0x%02x) != (0x%x, 0x0F)"
                             % (w, row, mask, er))
            if (wdata & ((1 << 128) - 1)) != ep:
                fails.append("cmd3 win%d low128 != golden (stale pass-0 snapshot "
                             "from cmd1?)" % w)

    # ── cmd4: MXFP4 + BS_16 (NVFP4, num_passes=1) ──
    SREF_D = -5
    if not fails:
        await issue_cmd(dut, ELEM_MXFP4, BS16, DST_D, SC_D, fails)
    if not fails:
        await push_cap(dut, pack_lanes(d0), SREF_D, 0x38, 1, fails)
    wr4 = await collect_writes(dut, fails)
    pd0, sd0 = golden_window(d0, SREF_D, 4, g.SCALE_E4M3)
    if not fails and len(wr4) != 2:
        fails.append("cmd4: expected 2 writes (payload + sidecar; pass counter "
                     "not reloaded to 1?), got %d" % len(wr4))
    if not fails:
        row, mask, wdata = wr4[0]
        if (row, mask) != (DST_D, 0x03):
            fails.append("cmd4 payload (row 0x%x, mask 0x%02x) != (0x%x, 0x03)"
                         % (row, mask, DST_D))
        if (wdata & ((1 << 64) - 1)) != pd0:
            fails.append("cmd4 payload low64 0x%016x != golden 0x%016x"
                         % (wdata & ((1 << 64) - 1), pd0))

    # ── 终检：持久状态 + 跨命令隔离 ──
    if not fails:
        await check_row(dut, DST_A, row_words(PAT_PAY, pa0, 64), fails, "b2b cmd1 win0")
        await check_row(dut, DST_A + 1, row_words(PAT_PAY, pa1, 64), fails, "b2b cmd1 win1")
        for w, (er, lanes) in enumerate([(DST_B, b0), (DST_B + 1, b1)]):
            words = [(pack_lanes(lanes) >> (32 * j)) & 0xFFFFFFFF for j in range(8)]
            await check_row(dut, er, words, fails, "b2b cmd2 win%d" % w)
        await check_row(dut, DST_C, row_words(PAT_PAY, pc0, 128), fails, "b2b cmd3 win0")
        await check_row(dut, DST_C + 1, row_words(PAT_PAY, pc1, 128), fails, "b2b cmd3 win1")
        await check_row(dut, DST_D, row_words(PAT_PAY, pd0, 64), fails, "b2b cmd4 payload")
        # SC_A：cmd1 写 byte0/1（FP4/E8M0），cmd3 复用同一行 RMW 覆写 byte0/1
        # （FP8/E8M0，同 lane 布局）→ 终态 = cmd3 字节，其余 30B 仍是 preset。
        exp_sca = list(PAT_SC)
        exp_sca[0] = (PAT_SC[0] & 0xFFFF0000) | (sc_c1 << 8) | sc_c0
        await check_row(dut, SC_A, exp_sca, fails, "b2b SC_A (cmd3 RMW over cmd1)")
        # SC_B：legacy cmd2 全程不许碰
        await check_row(dut, SC_B, PAT_SC, fails, "b2b SC_B legacy-untouched")
        # SC_D：NVFP4 16b lane0
        exp_scd = list(PAT_SC)
        exp_scd[0] = (PAT_SC[0] & 0xFFFF0000) | sd0
        await check_row(dut, SC_D, exp_scd, fails, "b2b SC_D nvfp4 lane")

    assert not fails, "back-to-back fmt-alternating failures:\n  " + "\n  ".join(fails)
    dut._log.info("4 back-to-back stores (compact4/legacy/compact8/nvfp4) all golden-exact; "
                  "no cross-command state leakage")


# ---------------------------------------------------------------------------
# 4. [⑦ C3 re-scope] Compact-store writeback LATENCY anchor.
#
#    交接 C3 已重定为「劈 ⑦ requant STORE 锥」（实测绑定路径 =
#    result_cap_q -> compact_payload_q ≈ 6262ps；在 cmx_shared_exp（16 路 max
#    输出）处插一前导 VST_CMX_PREP1 级把 bank 劈两半：stage1 = abs->lzc->eff->max
#    ->register cmx_shared_exp_q/cmx_any_nz_q；stage2(PREP) = held result_cap_q +
#    registered shared -> shift->round->clamp->pack）。value-preserving（eff_o 不依
#    赖 shared_exp，无环；金标/requantizer.sv 不动）——所以逐字节黄金比对（本文件
#    测 1-3 + test_vec_compact_mx_store 全套）保住数值正确性；本测试补上唯一未覆盖
#    的一面 = 流水**深度**（每个 compact egress 窗 +1 拍）。
#
#    红绿（证有牙）：手术后把路由 E5/E6（VST_ACTIVE 的 compact 臂 ->VST_CMX_PREP1）
#    改回直接 ->VST_CMX_PREP（绕过前导级）→ 测得 cyc 退回基线 → 下面的 == anchor
#    断言红。反向：忘了寄存 cmx_shared_exp_q（喂 live）→ 数值仍对但 timing 未切，
#    本测试照绿，靠 re-synth period_min 兜底（分工明确：本测试守深度，golden 守数值，
#    re-synth 守时序）。
#
#    锚定：None = 只测量打印（先跑一次读基线 N0），随后钉成 N0；手术 commit 再
#    +1(block16)/+2(block32)。绝不手推——grant 时序由真实 l2_subsystem 决定。
# ---------------------------------------------------------------------------
COMPACT_B16_DONE_CYC = 18   # 9 -> 10 (C3 PREP1 split) -> 11 ([C5] PH_MC) -> 12 ([C8-b] PH_RENORM,
                            # 1 ACTIVE visit) -> 13 ([C8-c] VST_CMX_PREP0 front stage x 1 window)
                            # -> 14 ([C9-b] PH_RENORM2 x 1 ACTIVE visit)
                            # -> 15 ([T1 requant-back split] VST_CMX_PREP2 align stage x 1 window)
                            # -> 16 ([MC2] PH_MC2 x 1 ACTIVE visit)
                            # -> 17 ([LANE2] PH_LANE2 x 1 ACTIVE visit)
                            # -> 18 ([MC2F] PH_SEL x 1 ACTIVE visit)
COMPACT_B32_DONE_CYC = 39   # 15 -> 17 (C3, one PREP1 per egress window) -> 20 ([C5] PH_MC x 3 ACTIVE
                            # visits: pass 0, pass 1, and the window-1 re-entry from VST_L2_WB)
                            # -> 23 ([C8-b] PH_RENORM x the same 3 ACTIVE visits)
                            # -> 25 ([C8-c] VST_CMX_PREP0 x 2 egress windows)
                            # -> 28 ([C9-b] PH_RENORM2 x 3 ACTIVE visits)
                            # -> 30 ([T1 requant-back split] VST_CMX_PREP2 x 2 egress windows)
                            # -> 33 ([MC2] PH_MC2 x 3 ACTIVE visits)
                            # -> 36 ([LANE2] PH_LANE2 x 3 ACTIVE visits)
                            # -> 39 ([MC2F] PH_SEL x the same 3 ACTIVE visits)


async def collect_writes_counted(dut, fails, max_cycles=400):
    """collect_writes + a FallingEdge counter from call-site to done_o. Deterministic
    for a fixed command sequence; ONLY compare across builds with THIS same collector."""
    writes, cyc = [], 0
    for _ in range(max_cycles):
        await FallingEdge(dut.clk_i)
        cyc += 1
        if int(dut.err_o.value):
            fails.append("vector_unit error during STORE (latency probe)")
            return writes, cyc
        wrote_now = False
        if int(dut.rw_req_o.value) and int(dut.rw_gnt_o.value):
            writes.append((int(dut.rw_row_o.value), int(dut.rw_bank_mask_o.value),
                           int(dut.rw_wdata_o.value)))
            wrote_now = True
        if int(dut.done_o.value) == 1:
            if wrote_now:
                fails.append("done_o same cycle as write (latency probe / F8 ordering)")
            return writes, cyc
    fails.append("no done_o within %d cycles (latency probe)" % max_cycles)
    return writes, cyc


@cocotb.test()
async def test_compact_store_writeback_latency(dut):
    """[⑦ C3] cap-accept->done_o cycle count per compact window — anchors the
    VST_CMX_PREP1 requant-cone split (+1 clock/compact egress window)."""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())

    # ── block16 NVFP4 (single window) → baseline COMPACT_B16_DONE_CYC (+1 after split) ──
    await reset(dut)
    fails = []
    d0 = [7, -9, 11, -13, 15, -17, 19, -21, 6, -8, 10, -12, 14, -16, 18, -20]
    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)
    await issue_cmd(dut, ELEM_MXFP4, BS16, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(d0), -5, 0x38, 1, fails)
    wr16, cyc16 = await collect_writes_counted(dut, fails)
    if not fails and len(wr16) != 2:
        fails.append("block16 compact: expected 2 writes (payload+sidecar), got %d" % len(wr16))
    dut._log.info("[⑦-latency] block16 NVFP4 cap-accept->done = %d cycles "
                  "(anchor COMPACT_B16_DONE_CYC=%s)" % (cyc16, COMPACT_B16_DONE_CYC))
    if not fails and COMPACT_B16_DONE_CYC is not None and cyc16 != COMPACT_B16_DONE_CYC:
        fails.append("block16 latency %d != anchor %d (VST_CMX_PREP1 stage missing/extra?)"
                     % (cyc16, COMPACT_B16_DONE_CYC))

    # ── block32 MXFP8 (dual window) → baseline COMPACT_B32_DONE_CYC (+2 after split) ──
    await reset(dut)
    lanes0 = [31000 - 1900 * i if i % 2 == 0 else -(30000 - 1800 * i) for i in range(16)]
    lanes1 = [60 + 9 * i if i % 2 == 0 else -(50 + 7 * i) for i in range(16)]
    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, DST_ROW + 1, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)
    await issue_cmd(dut, ELEM_MXFP8, BS32, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes0), 0, 127, 1, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes1), 0, 127, 1, fails)
    wr32, cyc32 = await collect_writes_counted(dut, fails)
    if not fails and len(wr32) != 3:
        fails.append("block32 compact: expected 3 writes (2 payload+1 sidecar), got %d" % len(wr32))
    dut._log.info("[⑦-latency] block32 MXFP8 cap-accept->done = %d cycles "
                  "(anchor COMPACT_B32_DONE_CYC=%s)" % (cyc32, COMPACT_B32_DONE_CYC))
    if not fails and COMPACT_B32_DONE_CYC is not None and cyc32 != COMPACT_B32_DONE_CYC:
        fails.append("block32 latency %d != anchor %d" % (cyc32, COMPACT_B32_DONE_CYC))

    assert not fails, "⑦ store-cone latency-anchor failures:\n  " + "\n  ".join(fails)


# ---------------------------------------------------------------------------
# 5. [⑦ 覆盖缺口关闭 GAP-1] MXFP8 + BS_16 + E4M3（FP8 单窗 128b + 16b signed sidecar）。
#    对抗审计发现：这是唯一「可达但先前无逐字节黄金锚」的 compact 组合
#    （compact_fmt_fp8 && compact_scale_e4m3，:1270/:1291-1298 都真）。与本刀
#    ⑦-split 改的 requant 锥同机制（VST_CMX_PREP1 前导级 + registered shared_exp）
#    → 补上后本刀触及的每条 compact 路径都有逐字节 golden 兜底。golden_window 是全
#    格式通用 oracle（requantize_block_golden(cells, w, 'FP', RNE, scale_format)），
#    (w=8, E4M3) 与其余组合同源可信。单变量归因：本刀 value-preserving，若破坏
#    compact 通路则同机制的既有测（block16-FP4 / block32-FP8）先红；若仅本测红 =
#    该未测组合上的既有 golden/DUT 差异（pre-existing，值得上报）。
# ---------------------------------------------------------------------------
@cocotb.test()
async def test_compact_mxfp8_block16_e4m3(dut):
    """MXFP8+BS_16+E4M3: 128b window (mask 0x0F) + 16b signed sidecar ref_exp。"""
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    SREF = -5
    lanes = [130, -260, 400, -520, 610, -730, 850, -970,
             90, -140, 210, -280, 350, -420, 500, -600]
    p128, sc16 = golden_window(lanes, SREF, 8, g.SCALE_E4M3)
    if p128 == 0:
        fails.append("test vector defect: all-zero payload (requant path not exercised)")

    await preset_row(dut, DST_ROW, PAT_PAY)
    await preset_row(dut, SC_ROW, PAT_SC)

    await issue_cmd(dut, ELEM_MXFP8, BS16, DST_ROW, SC_ROW, fails)
    if not fails:
        await push_cap(dut, pack_lanes(lanes), SREF, 0x38, 1, fails)
    writes = await collect_writes(dut, fails)

    if not fails and len(writes) != 2:
        fails.append("expected 2 writes (payload + sidecar), got %d" % len(writes))
    if not fails:
        row, mask, wdata = writes[0]
        if (row, mask) != (DST_ROW, 0x0F):
            fails.append("payload write (row 0x%x, mask 0x%02x) != (0x%x, 0x0F)"
                         % (row, mask, DST_ROW))
        if (wdata & ((1 << 128) - 1)) != p128:
            fails.append("payload low128 0x%032x != golden 0x%032x"
                         % (wdata & ((1 << 128) - 1), p128))
        row, mask, wdata = writes[1]
        if (row, mask) != (SC_ROW, 0xFF):
            fails.append("sidecar write (row 0x%x, mask 0x%02x) != (0x%x, 0xFF)"
                         % (row, mask, SC_ROW))
    if not fails:
        await check_row(dut, DST_ROW, row_words(PAT_PAY, p128, 128), fails, "MXFP8/BS16 payload")
        exp_sc = list(PAT_SC)
        exp_sc[0] = (PAT_SC[0] & 0xFFFF0000) | sc16       # 16b signed lane 0 (FF3a layout)
        await check_row(dut, SC_ROW, exp_sc, fails, "MXFP8/BS16 sidecar")

    assert not fails, "compact MXFP8/BS16/E4M3 failures:\n  " + "\n  ".join(fails)
    dut._log.info("MXFP8+BS_16+E4M3: 128b window (mask 0x0F) + signed 16b sidecar "
                  "ref_exp 0x%04x golden-exact (⑦ GAP-1 closed)" % sc16)

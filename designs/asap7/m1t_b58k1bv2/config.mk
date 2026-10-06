# =============================================================================
# m1t_b58k1bv2 —— **测量臂**：A1 的 RTL 态（post-SCU + K1b）+ 平配方 + 已修的 SDC（v2）
#                （2026-08-14）
#
# 判据（发数前预登记）= aichip_run_logs/b58_k1bv2_prereg_20260814.md
# 全案                = AI_Chip/Review/BATCH58_A7VT_VTAxis_Result_2026-08-11.md §21.10
#
# ---- 要回答的那一问 ----
# 「**当前产品 RTL 在正确口径下站在哪**」。
# 在盘的坑：SSOT 现役行 `m1t_b56v2` 是 **pre-SCU 且 pre-K1b**（比产品 HEAD 落后两代）；
#   post-SCU 的 `m1t_b58base`(A0) 与 `m1t_b58a7vt` 都是 **MCP-v1**（含被证伪的 1024 条放宽）；
#   唯一 post-SCU + MCP-v2 的是 `m1t_b58vr1`，但它是**混阈值 VT 配方**。
# ⇒ **「平配方 + post-SCU + K1b + 正确口径」这一格在盘是空白。** 本臂就是去填它。
#
# 🔴 **本臂不设计任何刀** —— K1b 已经在产品 RTL 里了
#   （`AI_Chip/Tensor/mac_cell.sv` md5 `5ffe9ad5db57590e6353f5073dec3008` = A1 态，
#    `DRAIN_CYCLES_OS = ROWS+COLS+16'd3`，`c6g` 出现 40 处）。
#   ⇒ 发射件里声明 `IS_KNIFE_ARM=0` + `NO_TARGET_REASON`，
#     `G-RANGE-2`（禁无靶发射）对它**结构性不适用**（漏声明会被 fail-closed 拦下）。
#
# 🔴 **为什么另起 cell 而不是跑 ARM=A1**：A1 的语义是「K1b 的刀实验」，要靶要基线；
#   而 post-SCU + MCP-v2 + **无 K1b** 的**平配方**基线在盘不存在
#   ⇒ 那个实验现在做不了。**把 A1 留给将来真正的两臂实验**，本臂只出绝对值。
#   （同一形态的先例 = `m1t_b58vr1`：另起 cell、不覆写他人产物、只出绝对值。）
#
# 🔴 **本臂与 A0（m1t_b58base）的差异有两处，不是一处**：
#   ① RTL：含 K1b 的 c6g 缝（DRAIN 34 → 35）
#   ② SDC：口径 **v2**（A0 的冻结件实测是 **v1**，1059 条含 1024 个 `c6_mode_q`）
#   ⇒ 🔴 **不得与 A0 相减**（跨 SDC 口径，判决器的 `G-SDCVER-HARD` 会 fail-closed 拦）。
#     本臂**只出绝对值**。
#
# 🔴 **全新 synth，禁 copy-start**（RTL 与在盘任何网表都不同）。
#
# 物理配方 = 与 A0 逐字相同（继承 m1t_pnr + 同四个 TCL 钩子 + 同 margin），
#   唯一变量在 RTL 与 SDC ⇒ 本臂不引入任何新的物理旋钮。
# _K1BV2DIR 独名立即展开（F6-celldir：_CELLDIR 会被 include 链复写）。
# =============================================================================
_K1BV2DIR := $(dir $(lastword $(MAKEFILE_LIST)))
$(info [m1t_b58k1bv2] _K1BV2DIR=$(_K1BV2DIR) 测量臂 = post-SCU + K1b + SDC v2，平配方)
include $(_K1BV2DIR)../m1t_pnr/config.mk
export DESIGN_NICKNAME  = m1t_b58k1bv2
export PRE_RESIZE_TCL  := $(_K1BV2DIR)../m1t_k1b/k1b_fanout.tcl
# 🔴 2026-08-16：改指 v2 fork —— 原件在 sq==0 时无条件 exit 91，而 3a 退役了该队列
#   ⇒ 新基座臂的 sq 必然 0（甲跑到 CTS 段第 1.9 h 才撞上）。v2 只改这一处，改法与测量侧同构。
#   🔴 老臂（A0 / A0V2 丙）仍用原件，行为逐字不变。乙 include 本件 ⇒ 自动继承 v2。
export PRE_CTS_TCL     := $(_K1BV2DIR)b58_caliber_align_v2.tcl
export POST_RESIZE_TCL := $(_K1BV2DIR)../m1t_b5/p1_unpin_repair.tcl
export SLEW_MARGIN = 15
export CAP_MARGIN  = 10
export TNS_END_PERCENT = 100

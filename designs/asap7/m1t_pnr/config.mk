# =============================================================================
# m1t_pnr — 施压口径 buffering 实验（2026-07-24）。
# 与 m1t_adder 完全同一份综合结果（DESIGN_NICKNAME 继承 = m1t_adder，results 目录
# 复用 1_synth.odb，不重跑 4.6h 综合），只多挂一件事：真 srambank 宏的 FIRM on-grid
# 预置，绕过 MPL-0005（Snapper 多层 bbox 硬约束；memory asap7-real-sram-integration）。
# 复用波1 已验证的通用脚本（按 master 名迭代 + 越界后检查），不新写几何。
#
# 目的：post-synth 零负载把跨阵列控制广播记成"一个 x1 胖门 2728ps"（扇出 1795），
# 而布线后实测它是 46 级 buffer / ~2007ps 的真实物理代价。本实验在 1670ps 压力下
# 跑 GP + repair_design，取"广播树建起来之后"的 Tensor 真值。
# =============================================================================
_CELLDIR := $(dir $(lastword $(MAKEFILE_LIST)))
include $(_CELLDIR)../m1t_adder/config.mk
export MACRO_PLACEMENT_TCL = $(DESIGN_HOME)/asap7/aichip_pe_top/manual_macro_place.tcl
# ▲ 2026-10-02 #286 P-Y（宏 Y −9 nm，白名单 {-9, 0}，只对原件 srambank LEF 成立）并入共用脚本 —— prereg soc600 §71；彩排 MERGE-PROOF-OK
export AICHIP_MACRO_Y_DY = -9

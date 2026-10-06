# =============================================================================
# m1v_mc2f — MC2F (第 8 相 select|multiply 切分) 后的 Vector 标准链重测 cell
# (2026-07-27 批 1 第五役)。m1v_lane2 同款口径 (SDC=1670ps 全链,
# SKIP_FLOORPLAN_REPAIR), 独立 NICKNAME: 不覆盖 m1v_lane2/m1v_t1c/m1v_c9s 产物。
# RTL 增量 = MC2F 单 commit (PH_SEL 第 8 相 + src*_sel_q/mc2f_corr_*/precise 缝
# 寄存 + prep 改线 + SVA, MC2F_Preflight_SelMulSplit_2026-07-27 v2 裁决版)。
# SYNTH_KEEP_MODULES 不变 (无新模块边界 — 缝是父级寄存器, prep 叶未迁移)。
# =============================================================================
_CELLDIR := $(dir $(lastword $(MAKEFILE_LIST)))
include $(_CELLDIR)../aichip_vector/config.mk
export DESIGN_NICKNAME = m1v_mc2f
export SDC_FILE = $(_CELLDIR)../m1_vector_1670.sdc
export SKIP_FLOORPLAN_REPAIR = 1

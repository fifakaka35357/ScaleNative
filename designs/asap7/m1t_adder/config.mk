# =============================================================================
# m1t_adder — M1 tensor A/B pair, ADDER_MAP main effect (2026-07-23). §C3.
# ONLY difference vs m1t_base: ADDER_MAP_FILE blanked. Measures whether blanking
# the adder map (aligning tensor_signoff with pe_top/sky130, which already blank
# it) changes the tensor block's post-synth logic depth / area. Expected: the
# 108,772 HAxp5 + 47,033 FAx1 dont_use'd half/full-adders change; direction on
# period_min TBD (do NOT assume faster synth — pe_top v2 was slower, §A6).
# =============================================================================
_CELLDIR := $(dir $(lastword $(MAKEFILE_LIST)))
include $(_CELLDIR)../aichip_tensor_signoff/config.mk

export DESIGN_NICKNAME = m1t_adder
export SDC_FILE = $(_CELLDIR)../m1_tensor_1670.sdc

# blank => synth.tcl skips extract_fa + techmap -map $ADDER_MAP_FILE. := for a
# definite empty string.
export ADDER_MAP_FILE :=

# real srambank blackbox (Memory 波1, same as m1t_base — see there).
REAL_SRAM = $(FLOW_HOME)/../../../third_party/asap7_sram_0p0/generated
export ADDITIONAL_LEFS += $(REAL_SRAM)/LEF/srambank_128x4x64_6t122.lef
export ADDITIONAL_LIBS += $(REAL_SRAM)/LIB/srambank_128x4x64_6t122.lib

# [B+1 2026-07-26] 真 srambank 宏无 GDS (third_party 只有 LEF/LIB/verilog) ——
# def2stream 缺 GDS cell 默认硬错。同 pe_top:70 口径: 允许空洞 + 注 P-d 披露。
# [T3 补芯 2026-07-26] 上游 GDS 实为在库: srambank_64b.gds 几何三重铁证 =
# 128x4x64_6t122 (宽 16.524/9 位地址/子单元 x128x4b; "Nb"文件名与 words 错位一档,
# 128b.gds 其实是 256x 变体且原点平移, 勿用)。klayout 顶层改名副本挂载如下;
# srambank 移出 ALLOW_EMPTY —— 补芯后找不到 GDS 必须炸响。披露: LEF SIZE 16.0 为
# snap 值(真实 16.524); dataout/wd[0:31] 64 pin LEF↔GDS 失配为供应商包级缺陷
# (三变体同病, merge 后为几何 open, 属真宏 pin-access 平台披露项)。
export ADDITIONAL_GDS += $(FLOW_HOME)/../../../third_party/asap7_sram_0p0/gds/srambank_128x4x64_6t122_renamed.gds
export GDS_ALLOW_EMPTY = fakeram.*

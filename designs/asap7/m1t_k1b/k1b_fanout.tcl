# K1b 物理刀 (2026-07-26): 全链首次引入 max_fanout DRV 约束。
# 根因 (K1b 勘察 §3): asap7 liberty 无 default_max_fanout + SDC 无 set_max_fanout
# → RepairDesign.cc:1059 的 fanout 分支 (makeRegionRepeaters 平衡树) 从未进入,
# ctrl_array_step_en (fanout 2752) 只被 slew 修复串成 14 级 BUFx16f 线性链。
# 挂载: PRE_RESIZE_TCL (3_4 repair_design) + PRE_CTS_TCL (post-CTS repair_timing)。
set_max_fanout 32 [current_design]
puts "\[K1b\] set_max_fanout 32 applied (hook alive)"

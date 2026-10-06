# =============================================================================
# P1 毒网根修钩子 (批 4a, 2026-07-29) —— 挂 POST_RESIZE_TCL
#   = resize.tcl 主 repair_design(_helper) / repair_timing 之后、
#     orfs_write_db 3_4_place_resized.odb 之前 (scripts/resize.tcl 末段)。
#
# 【靶】ctrl_tile_desc_active[16] (dataflow_sel 模式位) 等 case 常量网:
#   单 INVx1 驱 752 sink, slew 64460ps(限 320)。RepairDesign.cc 的
#   `!sta_->isConstant(drvr_pin, ...)` 守卫把 case 常量网整体排除出修复集合
#   —— DRC 类修复(slew/cap/fanout)对它【结构性无效】, 与裕量无关。
#
# 【毒化机理·批3 实证逐行】(k1cbt_sta_postcts_20260728.log FULLPATH):
#     2 6847.08  53.60 ..._5081_/Y (NOR2x1)   <- 死弧 A→Y(入 slew 64460) 的
#                                                输出 slew 被 vertex 级 max 合并
#     3  749.02 590.93 ..._5083_/Y (AOI21x1)  <- 用 6847ps 入 slew 算出 590.93ps
#     4  125.21  75.58 ..._5761_/Y (AOI21x1)  <- 余波 +55
#   即"死弧算 slew、活路径吃 slew"。超额 ~640ps。
#   case_analysis 豁免的是【路径约束】, 豁免不了【设计规则】与延迟计算。
#
# 【修法】解禁 -> 重算寄生 -> 同参 repair_design -> 逐 pin 重钉。
#   零 RTL / 零金标 / 零口径改动 (SDC 文件不落盘改动; 3_place.sdc 是
#   2_floorplan.sdc 的逐字节拷贝, 4_cts.sdc 由 CTS 阶段 orfs_write_sdc 重写)。
#
# 【三道 fail-closed 闸】(任一不过 -> utl::error 中止整链)
#   A  : 钩首枚举必须【恰 2 条】set_case_analysis
#   A2 : unset 后必须【0 条】(证明解禁真生效, 非静默 no-op)
#   B  : 重钉后 case 集合必须与钩首【逐字符一致】(防忘重钉→口径静默漂移)
#   D  : 第二次 repair 的 leaf 实例增量必须 >0 (证明确实修了东西)
#   (闸 C = 4_cts.sdc 落盘后 grep 两行数据行, 在发射脚本里)
#
# 【自带 A/B】钩内在"额外 repair"前后各出一次 CH1 全量 max_slew violators。
#   前者 == 批 3 的 3_4 同态 (copy-start 同网表同布局同主 repair, 确定性),
#   故 P1-CH1-BEFORE/AFTER 就是同一次 run 内的严格 A/B, 无需另跑基线。
# =============================================================================

set _p1_rdir $::env(RESULTS_DIR)

# 只认【数据行】: 行首 set_case_analysis + 至少一个空格 (解析器自匹配第五犯)
proc _p1_case_lines { f } {
    set out {}
    set fh [open $f r]
    while { [gets $fh line] >= 0 } {
        if { [regexp {^set_case_analysis[ \t]} $line] } { lappend out $line }
    }
    close $fh
    return [lsort $out]
}

puts "\[P1\] hook alive (POST_RESIZE) results=$_p1_rdir"

# ---------------- 闸 A: 枚举 + 恰 2 条 ----------------
# write_sdc 是唯一可用的"当前生效 case 集合"取数口 —— OpenSTA 无
# report_case_analysis 命令 (已 grep 全树确认), 且 Sdc 无 Tcl 侧枚举 API。
write_sdc -no_timestamp $_p1_rdir/p1_case_before.sdc
set _p1_lines [_p1_case_lines $_p1_rdir/p1_case_before.sdc]
puts "\[P1\] GATE-A case_lines=[llength $_p1_lines]"
foreach _l $_p1_lines { puts "\[P1\] CASE-BEFORE $_l" }
if { [llength $_p1_lines] != 2 } {
    utl::error FLW 901 "P1 GATE-A FAIL: 期望恰 2 条 set_case_analysis, 实得 [llength $_p1_lines]"
}

# ---------------- A/B 前照: 解禁前的 CH1 (= 批3 3_4 同态) ----------------
log_cmd estimate_parasitics -placement
puts "P1-CH1-BEFORE-BEGIN"
report_check_types -max_slew -violators -digits 2
puts "P1-CH1-BEFORE-END"

# ---------------- 解禁 ----------------
# 把 "set_case_analysis <val> <objspec>" 变成 "unset_case_analysis <objspec>"
# 再 eval —— objspec 原样来自 write_sdc, 与 read_sdc 走同一条求值路径,
# 故 get_pins 的 glob/转义行为与流程本身完全一致 (不自造名字, 无 [] 陷阱)。
set _p1_n 0
foreach _l $_p1_lines {
    if { ![regexp {^set_case_analysis[ \t]+(\S+)[ \t]+(.+)$} $_l -> _v _obj] } {
        utl::error FLW 902 "P1: case 行无法解析: $_l"
    }
    eval "unset_case_analysis $_obj"
    incr _p1_n
}
puts "\[P1\] unset_case_analysis applied n=$_p1_n"

# ---------------- 闸 A2: 解禁真生效 ----------------
write_sdc -no_timestamp $_p1_rdir/p1_case_mid.sdc
set _p1_mid [_p1_case_lines $_p1_rdir/p1_case_mid.sdc]
if { [llength $_p1_mid] != 0 } {
    utl::error FLW 903 "P1 GATE-A2 FAIL: unset 未生效, 残 [llength $_p1_mid] 条"
}
puts "\[P1\] GATE-A2 PASS (0 case lines after unset)"

# ---------------- 同参 repair_design ----------------
# removeCaseAnalysis 已 constantsInvalid()+delaysInvalid() (Sta.cc:1924-1935);
# isConstant 内部 ensureConstantsPropagated() (Sta.cc:1733-1739) —— 无需手工重算 sim。
log_cmd estimate_parasitics -placement
set _p1_inst0 [sta::network_leaf_instance_count]
set _p1_pin0 [sta::network_leaf_pin_count]
repair_design_helper
set _p1_inst1 [sta::network_leaf_instance_count]
set _p1_pin1 [sta::network_leaf_pin_count]
set _p1_dinst [expr { $_p1_inst1 - $_p1_inst0 }]
puts "\[P1\] delta_inst=$_p1_dinst delta_pin=[expr { $_p1_pin1 - $_p1_pin0 }] (inst $_p1_inst0 -> $_p1_inst1)"

# ---------------- 重钉 ----------------
# 🔴 重钉必须【先于】闸 D —— 闸 D 触发时设计状态已回到钉住口径, 且干跑可以
#    在 repair 被打桩的情况下把 A/A2/B 全部走完再由 D 收口 (先红后判纪律)。
foreach _l $_p1_lines { eval $_l }
puts "\[P1\] set_case_analysis re-applied n=[llength $_p1_lines]"

# ---------------- 闸 B: 重钉后集合逐字符一致 ----------------
write_sdc -no_timestamp $_p1_rdir/p1_case_after.sdc
set _p1_lines2 [_p1_case_lines $_p1_rdir/p1_case_after.sdc]
foreach _l $_p1_lines2 { puts "\[P1\] CASE-AFTER $_l" }
if { $_p1_lines2 ne $_p1_lines } {
    utl::error FLW 905 "P1 GATE-B FAIL: 重钉后 case 集合与钩首不一致\n  before: $_p1_lines\n  after : $_p1_lines2"
}
puts "\[P1\] GATE-B PASS (repin identical, [llength $_p1_lines2] lines)"

# ---------------- 闸 D: 确实修了东西 ----------------
if { $_p1_dinst <= 0 } {
    utl::error FLW 904 "P1 GATE-D FAIL: 解禁后 repair_design 零实例增量 (delta_inst=$_p1_dinst) — 修复未发生"
}
puts "\[P1\] GATE-D PASS (delta_inst=$_p1_dinst)"

# ---------------- A/B 后照: 部署口径 (case 已重钉) 的 CH1 ----------------
log_cmd estimate_parasitics -placement
puts "P1-CH1-AFTER-BEGIN"
report_check_types -max_slew -violators -digits 2
puts "P1-CH1-AFTER-END"

puts "\[P1\] unpin-repair-repin done, delta_inst=$_p1_dinst"

# =============================================================================
# [2026-07-21] R4a 探针 A：GP 后 cs_registers_i 团块几何判决。
# 挂载点：POST_GLOBAL_PLACE_TCL（3_3 内、写 odb 之前）。分钟级，纯只读。
# 死刑判据（B3 配方 + 加严）：
#   FAIL ⇔ 质心落在西缘口袋（x<50µm 且 y∈[250,660]µm）
#        或 口袋内 CSR cell 占比 >25%（质心逃逸但主力仍在口袋的情形）。
# 参考位：绿基线 R2 的 CSR 落点 = 南缘 x p10-p90 782.8-814.8 / y 21-41µm，
#   x<35µm 的 cell = 0 个（6_final.def 全量解析）。
# 判决写入 verdict 文件，发射脚本据此 fail-fast（不进 CTS/GRT）。
# =============================================================================
set block [ord::get_db_block]
set dbu [expr {double([$block getDbUnitsPerMicron])}]
set n 0
set sx 0.0 ; set sy 0.0
set minx 1e30 ; set miny 1e30 ; set maxx -1e30 ; set maxy -1e30
set n_west 0 ; set n_zone 0
foreach inst [$block getInsts] {
  if { [string first "cs_registers_i" [$inst getName]] < 0 } { continue }
  lassign [$inst getLocation] ix iy
  set x [expr {$ix / $dbu}] ; set y [expr {$iy / $dbu}]
  incr n
  set sx [expr {$sx + $x}] ; set sy [expr {$sy + $y}]
  if { $x < $minx } { set minx $x }
  if { $x > $maxx } { set maxx $x }
  if { $y < $miny } { set miny $y }
  if { $y > $maxy } { set maxy $y }
  if { $x < 50.0 } {
    incr n_west
    if { $y > 250.0 && $y < 660.0 } { incr n_zone }
  }
}
set verdict "ERROR"
if { $n == 0 } {
  puts "R4A-PROBE-ERROR: no cs_registers_i instances found -> hierarchy naming drifted, audit netlist"
} else {
  set cx [expr {$sx / $n}] ; set cy [expr {$sy / $n}]
  puts [format "R4A-PROBE: cs_registers_i n=%d centroid=(%.1f,%.1f)um bbox=(%.1f,%.1f)-(%.1f,%.1f)um west(x<50)=%d zone(x<50,y250-660)=%d" \
        $n $cx $cy $minx $miny $maxx $maxy $n_west $n_zone]
  if { ($cx < 50.0 && $cy > 250.0 && $cy < 660.0) || ($n_zone * 4 > $n) } {
    set verdict "FAIL"
  } else {
    set verdict "PASS"
  }
}
set f [open [file normalize [file join $::env(FLOW_HOME) .. .. .. aichip_run_logs probe_verdict_a7r4a.txt]] w]
puts $f "PROBE_VERDICT=$verdict"
if { $n > 0 } {
  puts $f [format "n=%d centroid=(%.1f,%.1f) west=%d zone=%d bbox=(%.1f,%.1f)-(%.1f,%.1f)" \
           $n $cx $cy $n_west $n_zone $minx $miny $maxx $maxy]
}
close $f
puts "R4A-PROBE: verdict=$verdict"

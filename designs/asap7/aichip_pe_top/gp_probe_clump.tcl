# =============================================================================
# gp_probe_clump.tcl — geometry-AGNOSTIC IBEX CSR clump probe (2026-07-23).
#
# Replaces gp_probe_csr.tcl, whose absolute thresholds (x<50um, y[250,660]um)
# were hardcoded to the OLD 952um / 86-fakeram floorplan. On the memory-wave1
# floorplan (die 1350.244um, util 20, 17 srambank + 32 fakeram) those numbers
# are meaningless, and its FAIL check let UNPLACED instances (getLocation (0,0),
# cy~0 which fails cy>250) score PASS -> fail-OPEN (a credible false green).
#
# This probe is diagnostic + geometry-agnostic:
#   * every threshold is a RATIO of core width/height (works on any die),
#   * it reports where the cs_registers clump landed (centroid + bbox as core
#     fractions, edge margins, and overlap with the macro+halo envelope),
#   * it distinguishes the two known failure modes as ratios, not absolutes:
#       - EDGE POCKET  : centroid within EDGE_FRAC of any die edge (the R3a/b
#                        west-pocket death: clump pinned against a die wall).
#       - MACRO CHANNEL: >CH_FRAC of clump cells sit inside a macro+halo
#                        envelope (PROJECT_RULES §3.4 dead-end channel mode).
#   * n==0 -> ERROR (hierarchy naming drifted), AND
#   * >UNPLACED_FRAC of the clump UNPLACED -> ERROR (probe ran before GP
#     finished; refuse to judge — this is the (0,0) fail-open fix).
#
# Verdict is DIAGNOSTIC (WARN, not FAIL) because on this new floorplan we do NOT
# yet know that the clump re-forms or where a blockage should go — the blockage
# rectangle must be DERIVED from this probe's output, never guessed. Mount at
# POST_GLOBAL_PLACE_TCL (read-only, minutes).
# =============================================================================
set EDGE_FRAC      0.05   ;# centroid within 5% of a die edge = edge-pocket risk
set CH_FRAC        0.50   ;# >50% of clump cells inside macro+halo = channel risk
set UNPLACED_FRAC  0.10   ;# >10% of clump unplaced = GP not done, refuse to judge
set HALO_UM        15.0   ;# MACRO_PLACE_HALO (config.mk) — match for envelope test
set MATCH          "cs_registers_i"
set OUTDIR         [file normalize [file join $::env(FLOW_HOME) .. .. .. aichip_run_logs]]

set block [ord::get_db_block]
set dbu [expr {double([$block getDbUnitsPerMicron])}]
set core [$block getCoreArea]
set cx0 [expr {[$core xMin]/$dbu}] ; set cy0 [expr {[$core yMin]/$dbu}]
set cx1 [expr {[$core xMax]/$dbu}] ; set cy1 [expr {[$core yMax]/$dbu}]
set cw [expr {$cx1 - $cx0}] ; set ch [expr {$cy1 - $cy0}]

# --- macro+halo envelopes (union of every block/macro bbox, grown by HALO) ---
set macros {}
foreach inst [$block getInsts] {
  if { [[$inst getMaster] isBlock] } {
    set b [$inst getBBox]
    lappend macros [list [expr {[$b xMin]/$dbu - $HALO_UM}] [expr {[$b yMin]/$dbu - $HALO_UM}] \
                         [expr {[$b xMax]/$dbu + $HALO_UM}] [expr {[$b yMax]/$dbu + $HALO_UM}]]
  }
}
proc _in_macro {x y macros} {
  foreach m $macros {
    lassign $m mx0 my0 mx1 my1
    if { $x >= $mx0 && $x <= $mx1 && $y >= $my0 && $y <= $my1 } { return 1 }
  }
  return 0
}

# --- gather the clump (placed vs unplaced) ---
set n 0 ; set n_unpl 0
set sx 0.0 ; set sy 0.0
set minx 1e30 ; set miny 1e30 ; set maxx -1e30 ; set maxy -1e30
set n_inmac 0 ; set n_edge 0
foreach inst [$block getInsts] {
  if { [string first $MATCH [$inst getName]] < 0 } { continue }
  set st [$inst getPlacementStatus]
  if { $st eq "NONE" || $st eq "UNPLACED" } { incr n_unpl ; continue }
  lassign [$inst getLocation] ix iy
  set x [expr {$ix/$dbu}] ; set y [expr {$iy/$dbu}]
  incr n ; set sx [expr {$sx+$x}] ; set sy [expr {$sy+$y}]
  if { $x < $minx } { set minx $x } ; if { $x > $maxx } { set maxx $x }
  if { $y < $miny } { set miny $y } ; if { $y > $maxy } { set maxy $y }
  if { [_in_macro $x $y $macros] } { incr n_inmac }
  set fex [expr {min(($x-$cx0)/$cw, ($cx1-$x)/$cw)}]
  set fey [expr {min(($y-$cy0)/$ch, ($cy1-$y)/$ch)}]
  if { $fex < $EDGE_FRAC || $fey < $EDGE_FRAC } { incr n_edge }
}

set ntot [expr {$n + $n_unpl}]
set verdict "PASS"
if { $ntot == 0 } {
  set verdict "ERROR"
  puts "GP-PROBE-ERROR: no '$MATCH' instances found -> hierarchy naming drifted, audit netlist"
} elseif { $n_unpl > $UNPLACED_FRAC * $ntot } {
  set verdict "ERROR"
  puts [format "GP-PROBE-ERROR: %d/%d '%s' cells UNPLACED (>%.0f%%) -> GP not finished, refusing to judge" \
        $n_unpl $ntot $MATCH [expr {$UNPLACED_FRAC*100}]]
} else {
  set cx [expr {$sx/$n}] ; set cy [expr {$sy/$n}]
  set fcx [expr {($cx-$cx0)/$cw}] ; set fcy [expr {($cy-$cy0)/$ch}]
  set edge_margin [expr {min($fcx, 1.0-$fcx, $fcy, 1.0-$fcy)}]
  set f_inmac [expr {double($n_inmac)/$n}]
  set risks {}
  if { $edge_margin < $EDGE_FRAC } { lappend risks "EDGE_POCKET(margin=[format %.3f $edge_margin])" }
  if { $f_inmac > $CH_FRAC }       { lappend risks "MACRO_CHANNEL(in_macro=[format %.2f $f_inmac])" }
  if { [llength $risks] > 0 } { set verdict "WARN" }
  puts [format "GP-PROBE: %s n=%d unpl=%d core=(%.1f,%.1f)-(%.1f,%.1f)um centroid_frac=(%.3f,%.3f) edge_margin=%.3f in_macro=%.2f bbox_frac=(%.3f,%.3f)-(%.3f,%.3f)" \
        $MATCH $n $n_unpl $cx0 $cy0 $cx1 $cy1 $fcx $fcy $edge_margin $f_inmac \
        [expr {($minx-$cx0)/$cw}] [expr {($miny-$cy0)/$ch}] [expr {($maxx-$cx0)/$cw}] [expr {($maxy-$cy0)/$ch}]]
  if { [llength $risks] > 0 } { puts "GP-PROBE-RISK: [join $risks { }]" }
}

# per-run verdict file (tagged; never reuse a stale name)
set tag [expr {[info exists ::env(GP_PROBE_TAG)] ? $::env(GP_PROBE_TAG) : "unstamped"}]
set f [open "$OUTDIR/gp_probe_clump_$tag.txt" w]
puts $f "PROBE_VERDICT=$verdict"
puts $f "match=$MATCH n_placed=$n n_unplaced=$n_unpl"
if { $verdict eq "PASS" || $verdict eq "WARN" } {
  puts $f [format "centroid_frac=(%.4f,%.4f) edge_margin=%.4f in_macro_frac=%.4f" $fcx $fcy $edge_margin $f_inmac]
  puts $f [format "core_um=(%.2f,%.2f)-(%.2f,%.2f) clump_bbox_um=(%.2f,%.2f)-(%.2f,%.2f)" $cx0 $cy0 $cx1 $cy1 $minx $miny $maxx $maxy]
}
close $f
puts "GP-PROBE: verdict=$verdict (file: $OUTDIR/gp_probe_clump_$tag.txt)"

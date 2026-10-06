# manual_macro_place.tcl — Memory 波1 D5 (2026-07-22)
# Pre-place the ~~17~~ **33** real srambank_128x4x64 macros FIRM on-grid to bypass the MPL Snapper
# hard-error MPL-0005 (it aligns the pin's multi-layer union bbox center vs the
# RightWayOnGridOnly M3 track; srambank's asymmetric M4/M5 access pads scatter those
# centers off-grid). Setting the macros FIRM makes rtl_macro_placer's snapper skip them
# (it only snaps !isFixed macros)~~; it then places the 32 fakeram normally~~.
# 🔴 [D-SRAM-REAL-B 2026-09-03] L2 also bound to the real macro (route B: 512x64 with the
#    upper 32 data bits tied to 0) => 33 macros, ZERO fakeram. MPL therefore has nothing left
#    to place and returns early (PROJECT_RULES section 3, corollary 2). This script is
#    count-agnostic (it iterates instances by master name), so no constant here needed changing
#    -- the 17/32 above were comments only. Envelope at per_row=9: 4 rows, 796 x 898 um;
#    core was 1407.9 x 1407.8 um before the swap and only grows (macro area +27%).
#
# We iterate the actual instances (getName has escaped brackets \[0\] from generate loops,
# so hardcoding names is fragile) and set each origin directly. X snapped to the M3 grid
# (9 + 36k nm) so the M3 access stubs land on M3 tracks; Y to the M4 grid (12 + 48k nm).
# ▲ [2026-10-01] ... then shifted by AICHIP_MACRO_Y_DY (P-Y block below): origin-on-track was the wrong target.
#
# 🔴 Routing pin-access (M4/M5 shapes cannot all be on-grid) is UNPROVEN — a do-grt/do-drt
#    smoke test must confirm 0 SRAM pin-access DRC before trusting this end-to-end.
#    ▲ [2026-10-01] with P-Y: pe_top py arm route DRC 4 total, target pins 0, new PSM pass (prereg §68.5);
#      the 4 are collateral (1 external net + 3 data pins, phase group ≡23) => still not 0, keep this warning.
#
# 🔴 [P-Y, backlog #286 — PROJECT_RULES §8 D-PY-FOLLOWUP-2026-10-01 ② + D-RTL-PY-ANSWERS-2026-10-01 ④; prereg §71]
#    Y = snap(y0 + r*ypitch, 12, 48) + AICHIP_MACRO_Y_DY, default -9 => origin Y = 3 (mod 48).
#    read / banksel / ADDRESS[5] M4 pads: macro-local y 35.421-35.445 (centre 35.433; LEF :1718/:1782/:1830);
#    M4 tracks = die yMin + 12 + 48k (make_tracks.tcl:7, InitFloorplan.cc:1106). Origin 12 (mod 48) => pad centres
#    9 nm off track; the pe_top C2 final DRC had 57 M4 shorts signal <-> VDD on the macro's own VDD M4 rect (LEF:53)
#    and the new PSM died on them (prereg §66.7). Origin 3: sram_cut286 a1 PSM-FIXED (§67.6) + PSM pass (§67.8);
#    pe_top PY-CLEAN (§68.5).
#    🔴 Keep "snap to 12, then add DY": _snap(...,3,48) differs on row 2 (680000 -> 680019 vs validated 679971).
#    🔴 -9 holds ONLY for the original LEF (md5 2b5c8285...). A derived LEF moving the CTRL pads (B-geo v3 +6 nm =>
#       origin 45 mod 48, DY -15/+33) needs its own prereg; the guards below stop the flow.
#    Whitelist {-9 0}, anything else fails closed, an empty value included (unset = default -9; prereg §71 ▲: a
#    `make ... AICHIP_MACRO_Y_DY=$DY` with DY unset must not silently become P-Y). 0 = legacy Y = 12 (mod 48), only to reproduce pre-merge runs, via
#    `make ... AICHIP_MACRO_Y_DY=0` on the command line (the configs set it with `=`, so a stale shell value cannot leak in).
#    Guards (active only when dy = -9; prereg §71.1, review MAJOR-1):
#      G-PHYS (primary)  after each setOrigin, read back from the db the M4 box of read / banksel / ADDRESS[5] (exactly
#                        one per pin), the block's M4 y track pattern (exactly one) and the orientation; assert
#                        (Y + yc - track origin) % step == 0 and orient == R0. Prints PY_PHYS_OK <macros> pins=<3 x macros>.
#      G-LEF (second)    exactly one srambank* LEF in ADDITIONAL_LEFS, md5 = the original. It checks the env var (a proxy):
#                        2_2 reads the 2_1 odb and no LEF (scripts/load.tcl), so alone it misses an odb built from another LEF.
#      G-DIE (cheap)     die lower-left = (0,0): track origin = die yMin + offset. A MAKE_TRACKS override is caught by G-PHYS.
#      Formula self-check (NOT a guard): x%36 == 9 and y%48 == (12+DY)%48, true by construction; only catches an edited formula.
#    Output contract parsed by judges: PREPLACE / PREPLACED / MANUAL-MACRO-PLACE fingerprint unchanged;
#    PY_PREPLACED <N> dy=<D> y48=<r> lef=<orig|n/a> (petop_py_judge.py re.match ignores the tail); PY_PHYS_OK <N> pins=<3N>.

set block [ord::get_db_block]

proc _snap {v base pitch} { return [expr {$base + $pitch * round(double($v - $base) / $pitch)}] }

# --- P-Y (prereg §71.1): DY + whitelist; the guards are set up only when dy = -9 ---
set MACRO_Y_DY -9
if { [info exists ::env(AICHIP_MACRO_Y_DY)] } { set MACRO_Y_DY $::env(AICHIP_MACRO_Y_DY) }   ;# "" is not in the whitelist => error below
if { $MACRO_Y_DY ni {-9 0} } {
  error "MANUAL-MACRO-PLACE: AICHIP_MACRO_Y_DY='$MACRO_Y_DY' not in the validated set {-9 0} (#286, prereg §71) -- a new phase needs its own prereg"
}
set EXP_Y48 [expr {(12 + $MACRO_Y_DY) % 48}]   ;# -9 -> 3 (P-Y), 0 -> 12 (legacy)
set LEF_TAG n/a
set PY_PHYS_PINS {read banksel {ADDRESS[5]}}
set py_phys_macros 0
set py_phys_pins 0
if { $MACRO_Y_DY == -9 } {
  # G-DIE
  set die [$block getDieArea]
  if { [$die xMin] != 0 || [$die yMin] != 0 } {
    error "MANUAL-MACRO-PLACE: G-DIE die lower-left ([$die xMin] [$die yMin]) != (0 0) -- track origins follow the die, re-derive the phase"
  }
  # G-LEF (second guard; checks the env var, a proxy -- see header)
  set py_srl {}
  if { [info exists ::env(ADDITIONAL_LEFS)] } {
    foreach py_f $::env(ADDITIONAL_LEFS) {
      if { [string match "srambank*" [file tail $py_f]] } { lappend py_srl [file normalize $py_f] }
    }
  }
  if { [llength $py_srl] != 1 } {
    error "MANUAL-MACRO-PLACE: G-LEF dy=-9 needs exactly one srambank* LEF in ADDITIONAL_LEFS, got [llength $py_srl]: $py_srl"
  }
  set py_lmd5 [lindex [exec md5sum [lindex $py_srl 0]] 0]
  if { $py_lmd5 ne "2b5c8285c4b48675ee01e8579bbc16d3" } {
    error "MANUAL-MACRO-PLACE: G-LEF dy=-9 is validated only for the original srambank LEF (md5 2b5c8285c4b48675ee01e8579bbc16d3); configured [lindex $py_srl 0] has md5 $py_lmd5 -- re-derive the phase under a new prereg"
  }
  set LEF_TAG orig
  # G-PHYS set-up: the M4 y track pattern as built in this block
  set py_m4 [[ord::get_db_tech] findLayer M4]
  if { $py_m4 eq "NULL" } { error "MANUAL-MACRO-PLACE: G-PHYS tech has no layer M4" }
  set py_tg [$block findTrackGrid $py_m4]
  if { $py_tg eq "NULL" } { error "MANUAL-MACRO-PLACE: G-PHYS block has no M4 track grid" }
  if { [$py_tg getNumGridPatternsY] != 1 } {
    error "MANUAL-MACRO-PLACE: G-PHYS M4 has [$py_tg getNumGridPatternsY] y track patterns, need exactly 1"
  }
  set py_pat [$py_tg getGridPatternY 0]   ;# origin, line_count, step (, first_mask, samemask)
  set PY_TRK_Y0 [lindex $py_pat 0]
  set PY_TRK_STEP [lindex $py_pat 2]
  if { [llength $py_pat] < 3 || ![string is integer -strict $PY_TRK_Y0] || ![string is integer -strict $PY_TRK_STEP] || $PY_TRK_STEP <= 0 } {
    error "MANUAL-MACRO-PLACE: G-PHYS M4 y track pattern unreadable: '$py_pat'"
  }
}

# G-PHYS (primary guard): the physical quantity in the db, no proxy. Returns the number of pins checked.
proc py_phys_check { inst pins trk_y0 trk_step } {
  set orient [$inst getOrient]
  if { $orient ne "R0" } {
    error "MANUAL-MACRO-PLACE: G-PHYS orient: [$inst getName] is $orient, not R0 -- the macro-local pad offsets assume R0"
  }
  set oy [lindex [$inst getOrigin] 1]
  set master [$inst getMaster]
  set n 0
  foreach p $pins {
    set mt [$master findMTerm $p]
    if { $mt eq "NULL" } { error "MANUAL-MACRO-PLACE: G-PHYS mterm: master [$master getName] has no pin $p" }
    set m4 {}
    foreach mp [$mt getMPins] {
      foreach bx [$mp getGeometry] {
        set ly [$bx getTechLayer]
        if { $ly ne "NULL" && [$ly getName] eq "M4" } { lappend m4 [list [$bx yMin] [$bx yMax]] }
      }
    }
    if { [llength $m4] != 1 } {
      error "MANUAL-MACRO-PLACE: G-PHYS m4-box: [$inst getName] pin $p has [llength $m4] M4 boxes in the db, need exactly 1"
    }
    lassign [lindex $m4 0] by0 by1
    # centre on a track <=> (2*Y + by0 + by1 - 2*origin) % (2*step) == 0 (integer dbu; a half-dbu centre is off track)
    set rem2 [expr {(2 * $oy + $by0 + $by1 - 2 * $trk_y0) % (2 * $trk_step)}]
    if { $rem2 != 0 } {
      error "MANUAL-MACRO-PLACE: G-PHYS off-track: [$inst getName] pin $p M4 pad centre y = $oy + [expr {($by0 + $by1) / 2.0}] dbu sits [expr {$rem2 / 2.0}] dbu above an M4 track (origin $trk_y0, step $trk_step) -- the macro geometry in the db is not the validated one"
    }
    incr n
  }
  return $n
}

set per_row 9
set x0     300000 ; # nm
set xpitch  60000 ; # >> macro width 16000 nm, room for halo + pin access
set y0     400000
set ypitch 140000 ; # >> macro height 77760 nm

set i 0
foreach inst [$block getInsts] {
  if { [string match "srambank_128x4x64*" [[$inst getMaster] getName]] } {
    set r [expr {$i / $per_row}]
    set c [expr {$i % $per_row}]
    set x [_snap [expr {$x0 + $c * $xpitch}] 9  36]   ;# M3 vertical grid: 9 + 36k nm
    set y [expr {[_snap [expr {$y0 + $r * $ypitch}] 12 48] + $MACRO_Y_DY}]   ;# M4 horizontal grid: 12 + 48k nm, then P-Y DY (header)
    if { $x % 36 != 9 || $y % 48 != $EXP_Y48 } {   ;# formula self-check -- NOT a guard (true by construction)
      error "MANUAL-MACRO-PLACE: formula self-check (not a guard): [$inst getName] ($x $y) not on x%36=9 / y%48=$EXP_Y48 -- the placement formula was edited"
    }
    $inst setOrigin $x $y
    $inst setPlacementStatus FIRM
    if { $MACRO_Y_DY == -9 } {   ;# G-PHYS, after setOrigin (prereg §71.1)
      incr py_phys_pins [py_phys_check $inst $PY_PHYS_PINS $PY_TRK_Y0 $PY_TRK_STEP]
      incr py_phys_macros
    }
    puts "PREPLACE [$inst getName] @ ($x $y) nm  (x%36=[expr {$x%36}] y%48=[expr {$y%48}])"
    incr i
  }
}
puts "PREPLACED $i real srambank macros (FIRM, on-grid) — MPL snapper will skip these"
puts "PY_PREPLACED $i dy=$MACRO_Y_DY y48=$EXP_Y48 lef=$LEF_TAG"
if { $MACRO_Y_DY == -9 } {
  if { $py_phys_macros != $i || $py_phys_pins != 3 * $i } {
    error "MANUAL-MACRO-PLACE: G-PHYS checked $py_phys_macros macros / $py_phys_pins pins but placed $i macros"
  }
  puts "PY_PHYS_OK $py_phys_macros pins=$py_phys_pins"
}

# --- bounds + fingerprint post-check (PROJECT_RULES §3.3: absolute coords above
#     are a hardcoded-geometry landmine — CORE_UTILIZATION / cell-area changes
#     (e.g. M1 mixed VT) move the core edge; assert every macro is inside core). ---
set core [$block getCoreArea]
set cx0 [$core xMin] ; set cy0 [$core yMin]
set cx1 [$core xMax] ; set cy1 [$core yMax]
set nchk 0
foreach inst [$block getInsts] {
  if { ![string match "srambank_128x4x64*" [[$inst getMaster] getName]] } { continue }
  set b [$inst getBBox]
  if { [$b xMin] < $cx0 || [$b yMin] < $cy0 || [$b xMax] > $cx1 || [$b yMax] > $cy1 } {
    error "MANUAL-MACRO-PLACE: [$inst getName] outside core: ([$b xMin],[$b yMin])-([$b xMax],[$b yMax]) vs core ($cx0,$cy0)-($cx1,$cy1) — grid params (x0/y0/pitch) stale vs current core, retune"
  }
  incr nchk
}
puts "MANUAL-MACRO-PLACE: fingerprint core=($cx0,$cy0)-($cx1,$cy1) dbu, srambank_placed=$nchk — all inside core"

# =============================================================================
# AI_Chip Vector Unit on ASAP7 — canary for the ASAP7 headline track.
#
# Purpose (2026-07-02): cheapest end-to-end validation of slang + ASAP7 libs +
# ps-unit SDC + STA before the Tensor converter-delta trio is ported. Vector is
# flop-only (no SRAM macro, no PDK define), so this config differs from the
# sky130hd one ONLY in PLATFORM + SDC. Synth-only first; GDS is a stretch goal.
# =============================================================================
export PLATFORM           = asap7
export DESIGN_NAME        = vector_unit
export DESIGN_NICKNAME    = aichip_vector

export SYNTH_HDL_FRONTEND = slang

# Per-module coarse synth before flatten (SAT-share insurance) — same rationale
# as the sky130hd config.
export SYNTH_HIERARCHICAL  = 1

# [T1d 2026-07-26] vec_lane_addsub is a DESIGNED synthesis boundary (like C5
# PRECISE_INTERNAL): keeps ABC from weaving topological false paths across
# mutually-exclusive lane-op arms (T1c_Preflight_LaneUngate_MC2Split §1.3).
# In the BASE config so measurement cells == deployment config (review T1d-3);
# pattern-miss on pre-T1d RTL degrades to a warning (synth.tcl:86-88).
# [LANE2 2026-07-26] vec_lane_align joins the designed-boundary list (the
# PH_LANE align front — 16 parent instances; review #7: base config so
# measurement cells == deployment config).
export SYNTH_KEEP_MODULES = vec_lane_addsub vec_lane_align

export VERILOG_FILES = \
  $(DESIGN_HOME)/src/aichip_sv/IBEX_SRAM/pe_pkg.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vec_pkg.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_tz_shifter.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vec_mant_corr_mul.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_lane_array.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_reduce_cluster.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_renorm_quant.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_result_packer.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_desc_decode.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_fastpath_if.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_ingress_arb.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vec_operand_queue.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vec_scale_adapter.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vec_renorm_xpass.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vec_reduce_max_combine.sv \
  $(DESIGN_HOME)/src/aichip_sv/Tensor/requantizer.sv \
  $(DESIGN_HOME)/src/aichip_sv/Vector/vector_unit.sv

export SDC_FILE = $(DESIGN_HOME)/$(PLATFORM)/$(DESIGN_NICKNAME)/constraint.sdc

# --- Floorplan (only consumed if the GDS stretch goal is run) ---
export CORE_UTILIZATION   = 25
export CORE_ASPECT_RATIO  = 1
export CORE_MARGIN        = 2
export PLACE_DENSITY      = 0.40
export GPL_ROUTABILITY_DRIVEN = 1
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT = 2
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT = 1

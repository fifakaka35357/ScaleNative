#!/usr/bin/env bash
# =============================================================================
# elaborate_smoke.sh — Step-2 type-unification elaboration gate.
#
# Step 2 (pe_pkg SSOT merge + three-layer contract) has NO behavioral cocotb
# test of its own; its completion criterion (Decisions Log §4) is:
#   "三工程切统一 pe_pkg 后 pyslang/verilator 全量联编 0 error."
# This script is that gate — a reproducible `verilator --lint-only` sweep over
# the package SSOT and the representative consumers, so the red→green of the
# merge is observable the same way the Step-3 cocotb tests were.
#
# Usage:  bash tb/elaborate_smoke.sh            # run all targets
#         bash tb/elaborate_smoke.sh -v         # show full verilator output
#
# Each target prints PASS/FAIL. A target may be marked EXPECT-FAIL for a given
# stage (e.g. Vector-vs-unified-pe_pkg before the merge commit lands).
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/rtl"   # public layout: RTL sources live under rtl/
VERBOSE=0; [ "${1:-}" = "-v" ] && VERBOSE=1

# Lint flags: match tb/Makefile project-style waivers (these are style lints,
# not correctness — the gate is "0 elaboration errors", i.e. types resolve).
LFLAGS="--lint-only -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
        -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-SIDEEFFECT -Wno-LATCH -Wno-UNUSEDPARAM \
        -Wno-VARHIDDEN -Wno-UNDRIVEN -Wno-IMPLICIT -Wno-SELRANGE -Wno-MULTIDRIVEN \
        -Wno-BLKANDNBLK -Wno-PINMISSING"
# vec_lane_array's tz_shifter feed-through UNOPTFLAT is now waived in-RTL with a
# SCOPED /* verilator lint_off UNOPTFLAT */ (SV-2), so no project-wide flag is
# needed — a genuine combinational loop elsewhere will still be reported.

pass=0; fail=0; xfail=0
run() {            # run <name> <expect: ok|xfail> <verilator args...>
  local name="$1" expect="$2"; shift 2
  local out rc
  out="$(verilator $LFLAGS "$@" 2>&1)"; rc=$?
  # verilator --lint-only returns 0 even with %Error sometimes; check text too.
  if echo "$out" | grep -q "%Error"; then rc=1; fi
  if [ $rc -eq 0 ]; then
    printf "  \033[32mPASS\033[0m  %s\n" "$name"; pass=$((pass+1))
  else
    if [ "$expect" = "xfail" ]; then
      printf "  \033[33mXFAIL\033[0m %s (expected to fail until merge lands)\n" "$name"; xfail=$((xfail+1))
    else
      printf "  \033[31mFAIL\033[0m  %s\n" "$name"; fail=$((fail+1))
      echo "$out" | grep "%Error" | head -6 | sed 's/^/        /'
    fi
  fi
  [ $VERBOSE -eq 1 ] && echo "$out" | sed 's/^/      | /'
  return 0
}

echo "== Step-2 elaboration gate =="

# --- T1: PE package SSOT lints clean on its own ---
run "T1 pe_pkg (v5 SSOT)"            ok    --top-module pe_pkg IBEX_SRAM/pe_pkg.sv

# --- T2: IBEX consumer of tile_contract_t elaborates (contract still flows) ---
run "T2 cp_scheduler (tile_contract)" ok   --top-module cp_scheduler \
      IBEX_SRAM/pe_pkg.sv IBEX_SRAM/cp_scheduler.sv

# --- T3: Tensor package (independent of pe_pkg) lints clean ---
run "T3 tensor_pkg"                  ok    --top-module tensor_pkg Tensor/tensor_pkg.sv

# --- T4: Vector package against the UNIFIED v5 pe_pkg (the merge gate) ---
#     GREEN since the §9 BFP contract types were merged into v5 pe_pkg.
run "T4 vec_pkg vs unified pe_pkg"   "${T4_EXPECT:-ok}" --top-module vec_pkg \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv

# --- T5..T8: clean Vector datapath modules vs unified pe_pkg ---
#     (the SV-clean subset; vec_lane_array et al. remain blocked by the separate
#      decl-after-statement cleanup — Design_Notes N16 — not by the type merge.)
run "T5 vec_scale_adapter vs unified" "${T5_EXPECT:-ok}" --top-module vec_scale_adapter \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/vec_scale_adapter.sv
run "T6 vec_reduce_cluster vs unified" ok --top-module vec_reduce_cluster \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv Vector/Unchanged/Vector/vec_reduce_cluster.sv
run "T7 vec_renorm_quant vs unified"  ok --top-module vec_renorm_quant \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv Vector/Unchanged/Vector/vec_renorm_quant.sv
run "T8 vec_operand_queue vs unified" ok --top-module vec_operand_queue \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/vec_operand_queue.sv

# --- T9..T11: Step-4 fast-path RTL + contract join ---
run "T9 requantizer (D9 leaf)"       ok --top-module requantizer Tensor/requantizer.sv
run "T10 tensor_result_packer (D2)"  ok --top-module tensor_result_packer \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv
run "T11 packer->vec_ingress join"   ok --top-module tb_packer_ingress \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv Vector/vec_pkg.sv Tensor/requantizer.sv \
      Tensor/tensor_result_packer.sv Vector/Unchanged/Vector/vec_ingress_arb.sv ../tb/tb_packer_ingress.sv

# --- T12: real Tensor top with the packer wired into egress (emits bs_capsule_t) ---
run "T12 tensor_unit_top + packer"   ok --top-module tensor_unit_top \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv \
      Tensor/mac_tz_shifter.sv Tensor/mac_zero_detect.sv Tensor/mac_lru.sv \
      Tensor/mac_fp_acc_align.sv Tensor/mac_fp_accumulator.sv Tensor/mac_input_mux.sv \
      Tensor/mac_cell.sv Tensor/output_format_unit.sv \
      Tensor/tensor_mac_array.sv Tensor/tensor_egress_fragmentizer.sv \
      Tensor/tensor_external_modules.sv \
      Tensor/tensor_tile_controller.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv \
      Tensor/tensor_unit_top.sv

# --- T13: full fast-path link (packer -> tv_fast_fifo[bs_capsule_t] -> vec_ingress) ---
run "T13 fast-path link (capstone)"  ok --top-module tb_fastpath_link \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv Vector/vec_pkg.sv Tensor/requantizer.sv \
      Tensor/tensor_result_packer.sv Vector/Unchanged/Vector/vec_ingress_arb.sv \
      IBEX_SRAM/tv_fast_fifo.sv ../tb/tb_fastpath_link.sv

# --- T14: full Vector datapath vector_unit elaborates (N16 unblocked) ---
#     The whole 16-lane Vector engine (vec_lane_array + reduce + renorm + packer +
#     scale adapter + operand queue + ingress + fastpath) against the unified pe_pkg.
#     (vec_assertions bind has a separate Verilator-SVA tail — `inside`->`==?` ×15 —
#      tracked as a follow-up; not load-bearing for D10 / functional sim.)
#     (D10: vec_lane_array now instantiates vec_mant_corr_mul — added to sources.)
#     ([C-MX ⑦] vector_unit now instantiates the D9 requantizer leaf for the
#      compact-MX store — Tensor/requantizer.sv joins every vector_unit build.)
run "T14 vector_unit datapath (N16)" ok --top-module vector_unit \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Tensor/requantizer.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv \
      Vector/vec_mant_corr_mul.sv \
      Vector/Unchanged/Vector/vec_lane_array.sv Vector/Unchanged/Vector/vec_reduce_cluster.sv \
      Vector/Unchanged/Vector/vec_renorm_quant.sv Vector/Unchanged/Vector/vec_result_packer.sv \
      Vector/Unchanged/Vector/vec_desc_decode.sv Vector/Unchanged/Vector/vec_fastpath_if.sv \
      Vector/Unchanged/Vector/vec_ingress_arb.sv Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
      Vector/vec_operand_queue.sv Vector/vec_scale_adapter.sv Vector/vec_renorm_xpass.sv Vector/vec_reduce_max_combine.sv Vector/vector_unit.sv

# --- T15: D10 E4M3 precise-mode mantissa correction leaf ---
run "T15 vec_mant_corr_mul (D10)"    ok --top-module vec_mant_corr_mul Vector/vec_mant_corr_mul.sv

# --- T16: D10 lane integration — vec_lane_array with mant_corr leaves wired ---
run "T16 lane RESADD precise (D10)"  ok --top-module tb_lane_resadd_precise \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/Unchanged/Vector/vec_tz_shifter.sv \
      Vector/vec_mant_corr_mul.sv Vector/Unchanged/Vector/vec_lane_array.sv \
      ../tb/tb_lane_resadd_precise.sv

# --- T17: D10 propagation — lane bump -> vec_renorm_quant raises shared exp ---
run "T17 lane->renorm precise (D10)" ok --top-module tb_lane_renorm_precise \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/Unchanged/Vector/vec_tz_shifter.sv \
      Vector/vec_mant_corr_mul.sv Vector/Unchanged/Vector/vec_lane_array.sv \
      Vector/Unchanged/Vector/vec_renorm_quant.sv ../tb/tb_lane_renorm_precise.sv

# --- T18: STEP4-E2E — vec_cmd_to_desc OP_VEC_RESADD mapping ---
run "T18 vec_cmd_to_desc RESADD"     ok --top-module tb_vec_cmd_to_desc \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
      ../tb/tb_vec_cmd_to_desc.sv

# --- T19: STEP4-E2E (inc 2b) — IBEX vector_unit_top wraps the REAL vector_unit ---
#     (cmd_to_desc + 512<->256 L2 bridge + bs_capsule_t fast path + half_sel).
#     Full pe_top elaborates up to the un-vendored external IBEX core (ibex_pkg).
run "T19 vector_unit_top (real core)" ok --top-module vector_unit_top \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Tensor/requantizer.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv \
      Vector/vec_mant_corr_mul.sv Vector/Unchanged/Vector/vec_lane_array.sv \
      Vector/Unchanged/Vector/vec_reduce_cluster.sv Vector/Unchanged/Vector/vec_renorm_quant.sv \
      Vector/Unchanged/Vector/vec_result_packer.sv Vector/Unchanged/Vector/vec_desc_decode.sv \
      Vector/Unchanged/Vector/vec_fastpath_if.sv Vector/Unchanged/Vector/vec_ingress_arb.sv \
      Vector/Unchanged/Vector/vec_cmd_to_desc.sv Vector/vec_operand_queue.sv Vector/vec_scale_adapter.sv \
      Vector/vec_renorm_xpass.sv Vector/vec_reduce_max_combine.sv Vector/vector_unit.sv IBEX_SRAM/vector_unit_top.sv

# --- T20: STEP4-E2E (inc 3a) — tens_cmd -> MMIO start-sequence FSM ---
run "T20 tensor_cmd_mmio_seq"        ok --top-module tb_tensor_cmd_mmio_seq \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv IBEX_SRAM/tensor_cmd_mmio_seq.sv \
      ../tb/tb_tensor_cmd_mmio_seq.sv

# --- T21: STEP4-E2E (inc 3b) — L2 -> Tensor-SRAM operand streamer ---
run "T21 tensor_operand_stream"      ok --top-module tb_tensor_operand_stream \
      IBEX_SRAM/pe_pkg.sv IBEX_SRAM/tensor_operand_stream.sv ../tb/tb_tensor_operand_stream.sv

# --- T22: STEP4-E2E (inc 3c) — tensor_domain_top wraps the REAL Tensor core ---
#     (real Tensor/tensor_unit_top + tensor_cmd_mmio_seq + tensor_operand_stream;
#     sequencing cmd->stream->load_done->mmio->tile_done->done; egress capsule).
#     Full pe_top elaborates up to the un-vendored external IBEX core (ibex_pkg).
run "T22 tensor_domain_top (real)"   ok --top-module tensor_domain_top \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv \
      Tensor/mac_tz_shifter.sv Tensor/mac_zero_detect.sv Tensor/mac_lru.sv \
      Tensor/mac_fp_acc_align.sv Tensor/mac_fp_accumulator.sv Tensor/mac_input_mux.sv \
      Tensor/mac_cell.sv Tensor/output_format_unit.sv \
      Tensor/tensor_mac_array.sv Tensor/tensor_egress_fragmentizer.sv \
      Tensor/tensor_external_modules.sv \
      Tensor/tensor_tile_controller.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv \
      Tensor/tensor_unit_top.sv IBEX_SRAM/tensor_cmd_mmio_seq.sv \
      IBEX_SRAM/tensor_operand_stream.sv IBEX_SRAM/tensor_domain_top.sv

# --- T23: STEP4-E2E (inc 5) — Vector consumption E2E (fast-path RESADD -> L2_WB) ---
run "T23 vec consume E2E"            ok --top-module tb_vec_consume_e2e \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Tensor/requantizer.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv \
      Vector/vec_mant_corr_mul.sv Vector/Unchanged/Vector/vec_lane_array.sv \
      Vector/Unchanged/Vector/vec_reduce_cluster.sv Vector/Unchanged/Vector/vec_renorm_quant.sv \
      Vector/Unchanged/Vector/vec_result_packer.sv Vector/Unchanged/Vector/vec_desc_decode.sv \
      Vector/Unchanged/Vector/vec_fastpath_if.sv Vector/Unchanged/Vector/vec_ingress_arb.sv \
      Vector/Unchanged/Vector/vec_cmd_to_desc.sv Vector/vec_operand_queue.sv Vector/vec_scale_adapter.sv \
      Vector/vec_renorm_xpass.sv Vector/vec_reduce_max_combine.sv Vector/vector_unit.sv IBEX_SRAM/vector_unit_top.sv ../tb/tb_vec_consume_e2e.sv

# --- T24: STEP4-E2E Phase B — real Tensor BF16 GEMM tile -> Class-A capsule egress ---
#     Drives Tensor/tensor_unit_top directly (MMIO + DMA) and proves a dense BF16
#     GEMM tile egresses block16 fast-path capsules (the from-scratch core bring-up).
run "T24 tensor GEMM egress (Phase B)" ok --top-module tb_tensor_gemm_egress \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv \
      Tensor/mac_tz_shifter.sv Tensor/mac_zero_detect.sv Tensor/mac_lru.sv \
      Tensor/mac_fp_acc_align.sv Tensor/mac_fp_accumulator.sv Tensor/mac_input_mux.sv \
      Tensor/mac_cell.sv Tensor/output_format_unit.sv \
      Tensor/tensor_mac_array.sv Tensor/tensor_egress_fragmentizer.sv \
      Tensor/tensor_external_modules.sv \
      Tensor/tensor_tile_controller.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv \
      Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_egress.sv

# --- T25: STEP4-E2E Phase C — GEMM through tensor_domain_top (streamer + MMIO) ---
#     tens_cmd(GEMM) -> L2->SRAM streamer -> real Tensor BF16 GEMM -> t2v capsules.
run "T25 tensor GEMM chain (Phase C)" ok --top-module tb_tensor_gemm_chain \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv \
      Tensor/mac_tz_shifter.sv Tensor/mac_zero_detect.sv Tensor/mac_lru.sv \
      Tensor/mac_fp_acc_align.sv Tensor/mac_fp_accumulator.sv Tensor/mac_input_mux.sv \
      Tensor/mac_cell.sv Tensor/output_format_unit.sv \
      Tensor/tensor_mac_array.sv Tensor/tensor_egress_fragmentizer.sv \
      Tensor/tensor_external_modules.sv \
      Tensor/tensor_tile_controller.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv \
      Tensor/tensor_unit_top.sv IBEX_SRAM/tensor_cmd_mmio_seq.sv \
      IBEX_SRAM/tensor_operand_stream.sv IBEX_SRAM/tensor_domain_top.sv ../tb/tb_tensor_gemm_chain.sv

# --- T26: STEP4-E2E Phase D — hybrid full chain (GEMM->FIFO->RESADD->L2_WB) ---
#     tensor_domain_top + tv_fast_fifo + vector_unit_top: real GEMM SRC0 capsule
#     flows the FIFO into the Vector RESADD (+ injected SRC1) -> L2 write-back.
run "T26 SoC E2E hybrid chain (Phase D)" ok --top-module tb_soc_e2e \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv Vector/vec_pkg.sv \
      Tensor/mac_tz_shifter.sv Tensor/mac_zero_detect.sv Tensor/mac_lru.sv \
      Tensor/mac_fp_acc_align.sv Tensor/mac_fp_accumulator.sv Tensor/mac_input_mux.sv \
      Tensor/mac_cell.sv Tensor/output_format_unit.sv \
      Tensor/tensor_mac_array.sv Tensor/tensor_egress_fragmentizer.sv \
      Tensor/tensor_external_modules.sv \
      Tensor/tensor_tile_controller.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv \
      Tensor/tensor_unit_top.sv IBEX_SRAM/tensor_cmd_mmio_seq.sv \
      IBEX_SRAM/tensor_operand_stream.sv IBEX_SRAM/tensor_domain_top.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv Vector/vec_mant_corr_mul.sv \
      Vector/Unchanged/Vector/vec_lane_array.sv Vector/Unchanged/Vector/vec_reduce_cluster.sv \
      Vector/Unchanged/Vector/vec_renorm_quant.sv Vector/Unchanged/Vector/vec_result_packer.sv \
      Vector/Unchanged/Vector/vec_desc_decode.sv Vector/Unchanged/Vector/vec_fastpath_if.sv \
      Vector/Unchanged/Vector/vec_ingress_arb.sv Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
      Vector/vec_operand_queue.sv Vector/vec_scale_adapter.sv Vector/vec_renorm_xpass.sv Vector/vec_reduce_max_combine.sv Vector/vector_unit.sv \
      IBEX_SRAM/vector_unit_top.sv IBEX_SRAM/tv_fast_fifo.sv ../tb/tb_soc_e2e.sv

# --- T27: STEP4-E2E §10 D-E2E-BENCH — command path through the REAL cp_scheduler ---
#     cp_scheduler + cp_completion + vector_unit_top: a real STORE issue (half_sel)
#     -> cmd release -> deferred L2 write uses the latched half_sel (D5-1 regression).
run "T27 CP cmd-path E2E (D-E2E-BENCH)" ok --top-module tb_cp_vec_store_e2e \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Tensor/requantizer.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv Vector/vec_mant_corr_mul.sv \
      Vector/Unchanged/Vector/vec_lane_array.sv Vector/Unchanged/Vector/vec_reduce_cluster.sv \
      Vector/Unchanged/Vector/vec_renorm_quant.sv Vector/Unchanged/Vector/vec_result_packer.sv \
      Vector/Unchanged/Vector/vec_desc_decode.sv Vector/Unchanged/Vector/vec_fastpath_if.sv \
      Vector/Unchanged/Vector/vec_ingress_arb.sv Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
      Vector/vec_operand_queue.sv Vector/vec_scale_adapter.sv Vector/vec_renorm_xpass.sv Vector/vec_reduce_max_combine.sv Vector/vector_unit.sv \
      IBEX_SRAM/vector_unit_top.sv IBEX_SRAM/cp_scheduler.sv IBEX_SRAM/cp_completion.sv \
      ../tb/tb_cp_vec_store_e2e.sv

VEC_SRCS="Tensor/requantizer.sv \
      Vector/Unchanged/Vector/vec_tz_shifter.sv Vector/vec_mant_corr_mul.sv \
      Vector/Unchanged/Vector/vec_lane_array.sv Vector/Unchanged/Vector/vec_reduce_cluster.sv \
      Vector/Unchanged/Vector/vec_renorm_quant.sv Vector/Unchanged/Vector/vec_result_packer.sv \
      Vector/Unchanged/Vector/vec_desc_decode.sv Vector/Unchanged/Vector/vec_fastpath_if.sv \
      Vector/Unchanged/Vector/vec_ingress_arb.sv Vector/Unchanged/Vector/vec_cmd_to_desc.sv \
      Vector/vec_operand_queue.sv Vector/vec_scale_adapter.sv Vector/vec_renorm_xpass.sv Vector/vec_reduce_max_combine.sv Vector/vector_unit.sv \
      IBEX_SRAM/vector_unit_top.sv"
L2_SRCS="IBEX_SRAM/sram_1rw1r_wrapper.sv IBEX_SRAM/Memory_Subsystem/l2_bank.sv \
      IBEX_SRAM/Memory_Subsystem/l2_ro_arbiter.sv IBEX_SRAM/Memory_Subsystem/l2_rw_arbiter.sv \
      IBEX_SRAM/Memory_Subsystem/l2_subsystem.sv"

# --- T28: D-E2E-BENCH P2 — l2_subsystem bank-half routing (synthetic) ---
run "T28 L2 vec half readback (P2)"  ok --top-module tb_l2_vec_half_readback \
      IBEX_SRAM/pe_pkg.sv $L2_SRCS ../tb/tb_l2_vec_half_readback.sv

# --- T29: D-E2E-BENCH P2 — vector_unit_top STORE -> real l2_subsystem ---
run "T29 L2 vec store readback (P2)"  ok --top-module tb_l2_vec_store_readback \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv $VEC_SRCS $L2_SRCS ../tb/tb_l2_vec_store_readback.sv

# --- T30: D-E2E-BENCH pe_top fetch bench — REAL command_processor (no ibex) ---
run "T30 CP pe_top fetch E2E"  ok --top-module tb_cp_pe_fetch_e2e \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv $VEC_SRCS IBEX_SRAM/cp_csr.sv \
      IBEX_SRAM/cp_desc_fetch.sv IBEX_SRAM/cp_scheduler.sv IBEX_SRAM/cp_completion.sv \
      IBEX_SRAM/event_trace_ring.sv IBEX_SRAM/command_processor.sv ../tb/tb_cp_pe_fetch_e2e.sv

# --- T31: D-E2E-BENCH §13 — RESADD hardware resident-L2 SRC1 producer ---
run "T31 RESADD resident SRC1 (§13)"  ok --top-module tb_vec_resadd_resident_e2e \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv $VEC_SRCS $L2_SRCS ../tb/tb_vec_resadd_resident_e2e.sv

run "T32 REDUCE_MAX path (TIER-2)"   ok --top-module tb_vec_reduce_max \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/Unchanged/Vector/vec_tz_shifter.sv \
      Vector/vec_mant_corr_mul.sv Vector/Unchanged/Vector/vec_lane_array.sv \
      Vector/Unchanged/Vector/vec_reduce_cluster.sv ../tb/tb_vec_reduce_max.sv

run "T33 block32 xpass realign (T2)" ok --top-module vec_renorm_xpass \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/vec_renorm_xpass.sv

run "T34 CP arbiter HOL (T4)"        ok --top-module tb_cp_arbiter \
      IBEX_SRAM/pe_pkg.sv IBEX_SRAM/cp_scheduler.sv ../tb/tb_cp_arbiter.sv

run "T35 reduce_max combine (T2)"    ok --top-module vec_reduce_max_combine \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv Vector/vec_reduce_max_combine.sv

# --- T36: HW-REVIEW TIER-1 — OS-GEMM core correctness harness (fp_acc snapshot tap) ---
#     Drives Tensor/tensor_unit_top (MMIO + DMA) for a NON-UNIFORM dense BF16 GEMM and
#     taps all 256 cells' pre-requant fp_acc snapshots for a cell-exact GEMM check vs
#     the Python golden (the real oracle the egress E4M3 path is too lossy for).
run "T36 OS-GEMM core (TIER-1)"      ok --top-module tb_tensor_gemm_core \
      IBEX_SRAM/pe_pkg.sv Tensor/tensor_pkg.sv \
      Tensor/mac_tz_shifter.sv Tensor/mac_zero_detect.sv Tensor/mac_lru.sv \
      Tensor/mac_fp_acc_align.sv Tensor/mac_fp_accumulator.sv Tensor/mac_input_mux.sv \
      Tensor/mac_cell.sv Tensor/output_format_unit.sv \
      Tensor/tensor_mac_array.sv Tensor/tensor_egress_fragmentizer.sv \
      Tensor/tensor_external_modules.sv \
      Tensor/tensor_tile_controller.sv Tensor/requantizer.sv Tensor/tensor_result_packer.sv \
      Tensor/tensor_unit_top.sv ../tb/tb_tensor_gemm_core.sv

# --- T37: HW-REVIEW TIER-3 FF3a — scale-sidecar decode primitive (multi-block streaming) ---
#     Leaf wrapper for pe_pkg::sidecar_scale_k, which pins the multi-block residual-scale
#     wire format (16 signed-16b exps per 256b row). Pure-combinational.
run "T37 sidecar scale (T3-FF/FF3a)" ok --top-module tb_sidecar_scale \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv ../tb/tb_sidecar_scale.sv

# --- T38: ⑦ compact-MX L2-store — vector_unit_top requantizing STORE + sidecar RMW ---
#     vec_cmd(STORE, block-scaled contract) -> narrow-mask compact payload write(s)
#     (FP4 64b / FP8 128b) + scale-sidecar read-modify-write, against the real
#     l2_subsystem with dma fill/evict readback.
run "T38 compact-MX store (⑦)"       ok --top-module tb_vec_compact_mx_store \
      IBEX_SRAM/pe_pkg.sv Vector/vec_pkg.sv $VEC_SRCS $L2_SRCS ../tb/tb_vec_compact_mx_store.sv

# --- T39 [M-SRAM-A7 2026-08-04]: ASAP7 真 SRAM 宏行为模型（供应商件，第三方树）---
#     被测件 = third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v
#     它在 2026-08-04 之前【从未被任何仿真或 lint 跑过】（决策条目
#     D-A7-REALSRAM-GDS-2026-08-03 的必交付③）。本靶把它纳入闸 1 的常规覆盖。
#     🔴 路径跨出 AI_Chip 仓 —— 这是本脚本唯一一个第三方靶；文件缺失会当场红（非静默）。
run "T39 ASAP7 real SRAM macro"      ok --top-module srambank_128x4x64_6t122 \
      ../third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v

echo "-- $pass passed, $fail failed, $xfail xfail --"
[ $fail -eq 0 ]

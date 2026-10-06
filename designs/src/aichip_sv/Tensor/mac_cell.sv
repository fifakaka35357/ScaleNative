// ============================================================================
// MAC Cell v4.3 (Round E1 / R3) — Single MAC Unit Top-Level
// ============================================================================
//
// Single MAC (Multiply-Accumulate) cell — the leaf element of the Tensor
// Unit's 16×16 array. Receives 16-bit packed weight + activation, performs
// mixed-precision MAC, and outputs partial sums (INT path) or block-float
// accumulator state (FP path). The Tensor Unit instantiates 256 of these
// cells as a systolic array (tensor_mac_array in R6).
//
// Previously named upe_core_sparse. Renamed as part of the Round E naming
// cleanup — "UPE" was ambiguous between "a single MAC cell" and "the wider
// Tensor Unit tile". The new naming convention is:
//
//   tensor_*  → scoped to the Tensor Unit as a whole
//   mac_*     → scoped to a single MAC cell (this file and its leaves)
//
// ----------------------------------------------------------------------------
// Round E1 / R3 changes (THIS ROUND — multiple functional changes):
// ----------------------------------------------------------------------------
//
//   (1) RENAMES
//       - File:      upe_core_sparse.sv → mac_cell.sv
//       - Module:    upe_core_sparse → mac_cell
//       - Import:    upe_pkg → tensor_pkg
//       - Type:      upe_mode_e → tensor_mode_e
//       - Submodule instances:
//           upe_input_mux      → mac_input_mux      (u_input_mux)
//           upe_lru            → mac_lru            (u_lru)
//           upe_zero_detect    → mac_zero_detect    (u_zero_detect)
//           upe_fp_accumulator → mac_fp_accumulator (u_fp_acc)
//       - Assertion tag: "UPE_CORE" → "MAC_CELL"
//       - Helper usage: 2 sites of the `(mode == MXFP4 || MXFP8 || MXINT8)`
//                       pattern now call `mode_is_mx(mode)` from tensor_pkg
//                       (improves readability + centralizes the check)
//
//   (2) NEW: Snapshot register (Phase E1 core architectural addition)
//       - New input port:  capture_fire
//       - New output port: fp_acc_snapshot
//       - New internal register: fp_acc_snapshot_q
//       - New Section 11: Snapshot Register
//
//       Purpose: decouple egress lifetime from accumulator lifetime.
//       When the tile controller asserts capture_fire (1-cycle pulse during
//       ST_CAPTURE), the current fp_acc_out is atomically latched into
//       fp_acc_snapshot_q. The tensor_egress_fragmentizer then reads the
//       snapshot via a row-mux in the array top-level, while the accumulator
//       itself can be cleared and reused by the next tile.
//
//       See: Vector_Unit_OFU_Sidecar_Design_Plan.md §5.2
//            Tensor_Unit_Design_Rationale.md D25
//
//   (3) BUG FIX: BF16 product sticky preservation (code opt #3)
//       Location: Section 8, BF16 product normalization path.
//
//       The v4.2 code unconditionally did `bf16_mant_prod >> 1` when the
//       16-bit mantissa product had bit[15] set (indicating product ≥ 2.0).
//       This silently dropped bit[0] of the product, causing a systematic
//       LSB truncation in BF16 dot-products when the product overflowed.
//
//       Fix: OR the dropped bit[0] into the new LSB to preserve sticky
//       semantics. Downstream rounding (in the FP accumulator and eventually
//       OFU) then correctly sees "there was residue below the shift point".
//
//       Example:
//         bf16_mant_prod = 16'b1000_0000_0000_0001  (= 32769)
//         v4.2 (buggy): >> 1        = 16'b0100_0000_0000_0000 (= 16384)
//         R3 (sticky):  >> 1 | bit0 = 16'b0100_0000_0000_0001 (= 16385)
//
//       Over K=256 accumulations this error can accumulate to ~256 ulp —
//       small in absolute terms but measurable on reference models.
//
//   (4) DEADCODE REMOVAL: result_valid / mac_en_d1 (code opt #1)
//       The v4.2 module exposed a `result_valid` output that was driven by
//       a 1-cycle falling-edge detector on mac_en. Nothing in the tensor
//       array or external wrappers consumed this signal — it was a leftover
//       stub from the v3.0 "dumb PE" era before the tile controller existed.
//
//       Removed:
//         - result_valid output port
//         - mac_en_d1 register and its always_ff block
//         - Section 11 header ("Output Valid Pipeline")
//
//       The tile controller (tensor_tile_controller) now owns all tile-level
//       valid signaling via descriptor state and the ST_DONE handshake.
//
// ----------------------------------------------------------------------------
// v4.2a Round A features retained (unchanged):
//   P3-3:  combined_scale port removed (was zero-stub since v4.2)
//   P3-1:  BF16 subnormal FTZ documented in Section 8
//
// v4.2 features retained (unchanged):
//   A7:    special_force_valid = mx_scale_nan | any prod NaN/Inf
//          (bypasses skip_accumulation for special values)
//   A2/ARCH: sparse_2_4_en / sparse_meta ports removed
//   A4:    lane_valid[3:0] propagated to mac_input_mux + mac_zero_detect
//
// v4.0/4.1 features retained:
//   - FP4/MXFP4 4× throughput via LRU
//   - FP8/MXFP8 2× throughput via LRU
//   - Block-float accumulator: 49-bit internal with toward-zero correction
//   - True per-lane zero detection for all FP/MX modes
//   - MX scale offset folded into prod_exp (Section 7B + 8)
//   - NaN/Inf state machine in FP accumulator (P7)
//
// Submodule instantiation summary:
//   u_input_mux    → mac_input_mux       (input demux + lane gating)
//   u_lru          → mac_lru             (FP local reduction)
//   u_zero_detect  → mac_zero_detect     (per-lane zero flags)
//   u_fp_acc       → mac_fp_accumulator  (block-float accumulator)
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R3 — rename + snapshot + BF16 sticky + deadcode)
// ============================================================================

module mac_cell
  import tensor_pkg::*;
#(
  parameter int ACC_WIDTH     = ACC_WIDTH_DEFAULT,  // 48 (was 32 in v3.0)
  parameter bit WEIGHT_REG_EN = 1'b1,              // Enable weight register
  parameter bit ZEROSKIP_EN   = 1'b1               // [C1] per-cell 零门控（原 SPARSE_EN）
) (
  // ---- Clock / Reset ----
  input  logic               clk,
  input  logic               rst_n,

  // ---- Control ----
  input  tensor_mode_e       mode,
  input  logic               mac_en,         // Valid product this cycle (= issue_en from controller)
  // §C6 (M3, 2026-07-24): systolic step enable, clocks the feedforward stage
  // between the product cone and the FP accumulator (Section 9A). Same signal
  // that clocks the array-level skew SRs / recapture regs, so the stage stays
  // coherent through EXEC_SPARSE_STRUCT frag stalls (issue_en==array_step_en
  // in OS COMPUTE; see tensor_tile_controller.sv split-control table).
  input  logic               array_step_en,
  input  logic               clear_acc,      // New dot-product: clear accumulators

  // ---- NEW in R3: Snapshot capture pulse ----
  //
  // 1-cycle pulse from the tile controller during ST_CAPTURE.
  // On the posedge with capture_fire=1, fp_acc_snapshot_q latches the
  // current fp_acc_out as the finalized tile result. See Section 11.
  //
  // Invariant: capture_fire must never overlap with clear_acc
  // (enforced by tile controller FSM, checked by defense-in-depth assertion).
  input  logic               capture_fire,

  // ---- Lane Valid Mask (v4.2 — from controller tail mask) ----
  //
  // Per-lane active mask. Propagated to input_mux and zero_detect.
  //   lane_valid[i]=1: lane i carries valid data
  //   lane_valid[i]=0: lane i is tail-masked (forced to zero in input_mux)
  //
  // In non-tail compute cycles: lane_valid = mode_full_lane_mask(mode)
  // In last K group (partial):  some bits cleared per K remainder
  // Outside compute:            lane_valid = 4'b0000
  input  logic [3:0]         lane_valid,

  // ---- Weight Input ----
  input  logic [15:0]        weight_in,      // Weight data (from north / host)
  input  logic               weight_load,    // Latch weight into local register
  input  logic               weight_stream_en, // Stream weight to south neighbor

  // ---- OS-GEMM dataflow select (HW-REVIEW T1) ----
  //
  // 0 = Output-Stationary: the MULTIPLY taps the PRE-register weight (weight_in),
  //     mirroring the activation (which is multiplied from its pre-register
  //     systolic wire). With the array's weight column-skew this makes B[k][c] and
  //     A[r][k] of the same contraction index k meet at cell(r,c) on the same
  //     cycle. The south stream output still uses the registered weight, so the
  //     north->south systolic pipeline (row hop = 1 cycle) is unchanged.
  // 1 = Weight-Stationary: the multiply taps the registered, stationary weight
  //     (weight_reg) as before.
  // The `= 1'b1` default applies ONLY to UNCONNECTED INSTANTIATION ports (e.g. the
  // tb_mac_ofu harness, which instantiates mac_cell without driving this → WS, its
  // intended mode). The real array (tensor_mac_array) drives it explicitly for all
  // 256 cells, so the default is never used in the synthesizable path. NOTE: it does
  // NOT apply to a Verilator cocotb TOPLEVEL's primary input (undriven there = 0);
  // those standalone mac_cell tests are dataflow-AGNOSTIC (they never change
  // weight_in between weight_load and the multiply, so weight_reg == weight_in).
  // The dedicated WS/OS proof is tb/test_mac_cell_dataflow (drives both values).
  input  logic               dataflow_sel = 1'b1,

  // ---- Activation Input ----
  input  logic [15:0]        act_in,         // Activation data (from west)

  // ---- MX Block Scale (from array-level sideband pass) ----
  // Per-cycle aligned values from systolic scale pass.
  // Cell does NOT hold scale internally; hold + block boundary logic
  // is managed by the array boundary and controller.
  input  logic [7:0]         mx_scale_a_cur, // Activation block scale (E8M0 or E4M3)
  input  logic [7:0]         mx_scale_b_cur, // Weight block scale (E8M0 or E4M3)

  // ---- E1: Block-Scale Format ----
  //
  // Selects how mx_scale_a/b_cur are interpreted (E8M0 pure-exponent for OCP MX,
  // or E4M3 exponent+significand for NVFP4). Defaults to SCALE_E8M0 so existing
  // array instantiations (which do not yet drive it) retain OCP-MX behavior;
  // the descriptor→controller→scale_buffer→array threading is a follow-up.
  input  scale_fmt_e         scale_format = SCALE_E8M0,

  // ---- INT Partial Sum Chain (systolic) ----
  input  logic signed [ACC_WIDTH-1:0] psum_in,   // Partial sum from north
  output logic signed [ACC_WIDTH-1:0] psum_out,  // Partial sum to south

  // ---- FP Accumulator Outputs ----
  output fp_acc_output_t     fp_acc_out,      // Live block-float state (current cycle)
  output fp_acc_output_t     fp_acc_snapshot, // NEW R3: Latched snapshot of finalized tile

  // ---- Streaming Weight Output ----
  output logic [15:0]        weight_stream_out,

  // ---- Sparsity Interface (adaptive, not structured) ----
  input  logic [3:0]         sparsity_map_in,  // From SCU: per-lane sparsity
  output logic [3:0]         sparsity_map_out, // To downstream (passthrough)
  output logic               skip_accumulation // This cell skips (all zero)

  // ---- REMOVED in R3: result_valid ----
  // Was: 1-cycle falling-edge detector on mac_en (leftover v3.0 stub).
  // The tile controller now owns all tile-level valid signaling.
);

  // ==========================================================================
  // Section 1: Weight Register
  // ==========================================================================

  logic [15:0] weight_reg;
  logic [15:0] weight_active;

  generate
    if (WEIGHT_REG_EN) begin : gen_weight_reg
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
          weight_reg <= '0;
        else if (weight_load)
          weight_reg <= weight_in;
      end
      assign weight_active = weight_reg;
    end else begin : gen_weight_bypass
      assign weight_active = weight_in;
    end
  endgenerate

  // Weight streaming passthrough — south pipeline ALWAYS uses the registered
  // weight (weight_active = weight_reg), so the north->south row hop stays a
  // clean 1-cycle systolic stage in both OS and WS. (Unchanged from v4.3.)
  assign weight_stream_out = weight_stream_en ? weight_active : '0;

  // OS-GEMM compensation (HW-REVIEW T1): the operand fed to the MULTIPLY.
  //   WS (dataflow_sel=1): weight_active (= weight_reg, the stationary value).
  //   OS (dataflow_sel=0): weight_in (the pre-register systolic wire), so the
  //     weight is consumed one cycle earlier — symmetric with the activation,
  //     which is multiplied from act_pass[r][c] BEFORE its own column register.
  // This removes the +1 weight-vs-act offset caused by weight_reg, so cell(r,c)
  // computes A[r][k]*B[k][c] (not A[r][k]*B[k-1][c]). When WEIGHT_REG_EN=0,
  // weight_active is already weight_in, so both branches coincide.
  logic [15:0] weight_mul;
  assign weight_mul = dataflow_sel ? weight_active : weight_in;

  // ==========================================================================
  // Section 2: Submodule Interconnect Wires
  // ==========================================================================

  // Input MUX outputs
  logic [3:0]  mul_a [4];
  logic [3:0]  mul_b [4];
  logic [3:0]  fp4_a [4];
  logic [3:0]  fp4_b [4];
  logic [7:0]  fp8_a [2];
  logic [7:0]  fp8_b [2];
  logic        fp_sign_a, fp_sign_b;
  logic [7:0]  fp_exp_a,  fp_exp_b;
  logic [7:0]  fp_mant_a, fp_mant_b;

  // LRU outputs ([C6-c/b] lru_out is now the BACK-half output, computed one
  // stage later from the c6f-registered seam; lru_lane_zero stays a live
  // FRONT product feeding mac_zero_detect)
  lru_result_t lru_out;
  logic [3:0]  lru_lane_zero;

  // [C6-b] LRU front seam (live outputs of u_lru_front → c6f registers)
  logic              lruf_sign [4];
  logic signed [9:0] lruf_expP [4];
  logic              lruf_zero [4];
  logic              lruf_nan  [4];
  logic              lruf_inf  [4];
  logic [11:0]       lruf_mant [4];

  // Zero detect outputs
  zero_detect_result_t zd_result;

  // BF16 product (assembled in this module, fed to FP accumulator)
  fp_product_t bf16_prod;

  // ==========================================================================
  // Section 3: Input Multiplexer
  // ==========================================================================
  //
  // v4.2: lane_valid propagated for tail mask gating.
  //        sparse_2_4_en / sparse_meta removed (Vector does selection).

  mac_input_mux u_input_mux (
    .weight_active (weight_mul),        // OS-GEMM T1: pre-register weight in OS
    .act_in        (act_in),
    .mode          (mode),
    .lane_valid    (lane_valid),        // v4.2: tail mask lane gating
    .mul_a         (mul_a),
    .mul_b         (mul_b),
    .fp4_a         (fp4_a),
    .fp4_b         (fp4_b),
    .fp8_a         (fp8_a),
    .fp8_b         (fp8_b),
    .fp_sign_a     (fp_sign_a),
    .fp_sign_b     (fp_sign_b),
    .fp_exp_a      (fp_exp_a),
    .fp_exp_b      (fp_exp_b),
    .fp_mant_a     (fp_mant_a),
    .fp_mant_b     (fp_mant_b)
  );

  // ==========================================================================
  // Section 4: Local Reduction Unit — [C6-b] FRONT half only
  // ==========================================================================
  //
  // The Phase A cone (unpack → multiply → normalize → NaN detect) runs here;
  // its outputs land in the c6f seam registers below. The BACK half
  // (u_lru_back, Section 8C) consumes the REGISTERED seam one array_step_en
  // beat later. lane_zero stays a live front product (mac_zero_detect and
  // the fp_acc_valid_in decision belong to the SAME operand as the front —
  // review V3 contract, now anchored at the c6f rank).

  mac_lru_front u_lru_front (
    .mode         (mode),
    .fp4_a        (fp4_a),
    .fp4_b        (fp4_b),
    .fp8_a        (fp8_a),
    .fp8_b        (fp8_b),
    .lane_sign    (lruf_sign),
    .lane_expP    (lruf_expP),
    .lane_is_zero (lruf_zero),
    .lane_is_nan  (lruf_nan),
    .lane_is_inf  (lruf_inf),
    .mant_ext     (lruf_mant),
    .lane_zero    (lru_lane_zero)
  );

  // ==========================================================================
  // Section 5: Zero Detection
  // ==========================================================================
  //
  // v4.2: lane_valid propagated for tail-mask-aware skip logic (R5).

  mac_zero_detect u_zero_detect (
    .mode          (mode),
    .lru_lane_zero (lru_lane_zero),
    .weight_in     (weight_mul),        // OS-GEMM T1: pre-register weight in OS
    .act_in        (act_in),
    .lane_valid    (lane_valid),        // v4.2: tail mask awareness
    .result        (zd_result)
  );

  // Sparsity output
  assign sparsity_map_out  = zd_result.mul_zero;
  assign skip_accumulation = zd_result.skip_accumulation;

  // ==========================================================================
  // Section 6: 4× UINT4 Fracturable Multipliers + Gating
  // ==========================================================================
  //
  // Each multiplier: 4-bit × 4-bit = 8-bit unsigned product.
  // Gated by zero detection: if a lane's inputs are zero, the multiplier
  // output is forced to 0 for power saving (gate prevents switching).
  //
  // Used by: UINT4_SIMD (direct), UINT8/MXINT8/BF16 (fracturable tree).
  // Not used by: FP4/FP8/MXFP4/MXFP8 (LRU handles multiply internally,
  //              mul_a/b driven to 0 by input_mux for power gating).

  logic [7:0] mul_prod [4];
  logic [7:0] mul_prod_gated [4];

  always_comb begin
    for (int i = 0; i < 4; i++) begin
      mul_prod[i] = mul_a[i] * mul_b[i];
      mul_prod_gated[i] = (ZEROSKIP_EN && zd_result.mul_zero[i])
                        ? 8'd0 : mul_prod[i];
    end
  end

  // ==========================================================================
  // Section 7: Fracturable Adder Tree (UINT8/BF16 recombination)
  // ==========================================================================
  //
  // Recombines 4 partial products into a single 16-bit product:
  //   result = prod[0] + (prod[1] + prod[2]) << 4 + prod[3] << 8
  //
  // This implements 8-bit × 8-bit multiplication using 4× 4-bit multipliers.
  // Used by: MODE_UINT8, MODE_MXINT8, MODE_BF16

  logic [15:0] adder_tree_result;

  always_comb begin
    adder_tree_result = {8'd0, mul_prod_gated[0]}                      // LL
                      + {4'd0, mul_prod_gated[1], 4'd0}               // HL << 4
                      + {4'd0, mul_prod_gated[2], 4'd0}               // LH << 4
                      + {mul_prod_gated[3], 8'd0};                    // HH << 8
  end

  // ==========================================================================
  // Section 7B: MX Block Scale Offset (v4.1 Round 4 + C06 + E1)
  // ==========================================================================
  //
  // Computes the combined MX block scale exponent offset for all MX modes.
  // This offset is folded into prod_exp before the FP accumulator, enabling
  // correct cross-cycle and cross-block accumulation.
  //
  //   E8M0 (SCALE_E8M0, OCP MX):
  //     mx_offset_base = scale_a + scale_b - 254   (TWO E8M0 biases — C06 fix)
  //   E4M3 (SCALE_E4M3, NVFP4):
  //     mx_offset_base = exp4_a + exp4_b - 20       (TWO E4M3 biases + sig4 norm)
  //                    = (exp4_a-7)+(exp4_b-7) - 6  (E4M3_DOUBLE_OFFSET, E1)
  //   then MXFP4/MXFP8: mx_offset = mx_offset_base
  //        MXINT8:       mx_offset = mx_offset_base - 12 (implicit 2^-6 per elem)
  //        Other modes:  mx_offset = 0
  //
  //   C06: each E8M0 scale byte s encodes 2^(s-127); both activation and weight
  //   scales carry bias 127, so the offset subtracts 254 (MX_E8M0_DOUBLE_BIAS).
  //
  //   E1: an E4M3 block scale (NVFP4) is value = (1+m3/8)*2^(exp-7). Only its
  //   EXPONENT is folded here; its significand product is applied to the LRU
  //   mantissa in Section 8B (mant_corr). The -6 in E4M3_DOUBLE_OFFSET normalizes
  //   the integer significand product sig4_a*sig4_b (each {1,m3} carries x2^3).
  //   Assumes normal E4M3 scales (exp != 0) — see tensor_pkg scale_fmt_e.

  logic signed [9:0] mx_offset;

  // E1: E4M3 significand product (mant_corr). Each sig4 = {1, m3} ∈ [8,15];
  // product ∈ [64,225]. Applied to the product mantissa in Section 8B for MXFP.
  logic [7:0] e4m3_mant_corr;

  always_comb begin
    e4m3_mant_corr = 8'd0;
    if (mode_is_mx(mode)) begin
      automatic logic signed [9:0] mx_offset_base;
      if (scale_format == SCALE_E4M3) begin
        // E4M3: exponent part only (significand → Section 8B mant_corr)
        automatic logic signed [9:0] e4m3_exp_a =
            10'(signed'({6'b0, mx_scale_a_cur[6:3]}));
        automatic logic signed [9:0] e4m3_exp_b =
            10'(signed'({6'b0, mx_scale_b_cur[6:3]}));
        mx_offset_base = e4m3_exp_a + e4m3_exp_b - 10'(E4M3_DOUBLE_OFFSET);
        e4m3_mant_corr = {1'b1, mx_scale_a_cur[2:0]} * {1'b1, mx_scale_b_cur[2:0]};
      end else begin
        // E8M0 (C06): two E8M0 biases
        mx_offset_base = 10'(signed'({2'b0, mx_scale_a_cur}))
                       + 10'(signed'({2'b0, mx_scale_b_cur}))
                       - 10'(MX_E8M0_DOUBLE_BIAS);
      end

      if (mode == MODE_MXINT8)
        mx_offset = mx_offset_base + 10'(MXINT8_IMPLICIT_EXP);  // -12
      else
        mx_offset = mx_offset_base;
    end else begin
      mx_offset = 10'sd0;
    end
  end

  // ==========================================================================
  // Section 7C: [C6-b/c 2026-07-27] front flags + c6f shared front rank
  // ==========================================================================
  //
  // The single shared front rank for BOTH FP cones (C6B preflight §1.1): the
  // LRU Phase-A seam and the product-cone seam land in ONE array_step_en-
  // gated bundle, so the two back halves and the c6 rank stay depth-aligned
  // (a per-cone split would load c6_lru_q/c6_prod_q with products of
  // DIFFERENT steps — the V3 tearing temptation). All special-value
  // PRODUCERS are front-side (LRU NaN in mac_lru_front; BF16 flags and
  // mx_scale_nan below); the seam carries flag bits only, and the back
  // halves assemble from the SEAM exclusively (review F7-valid single
  // source; F2-SEAM: Section 8/8B must never touch live scale/operand nets).

  // v4.1 (P7): BF16 per-operand special value flags — FRONT side (from the
  // live input-mux fields; moved out of Section 8, which now consumes the
  // registered copies).
  logic bf16_a_is_inf, bf16_a_is_nan;
  logic bf16_b_is_inf, bf16_b_is_nan;
  always_comb begin
    bf16_a_is_inf = (fp_exp_a == 8'hFF) && (weight_mul[6:0] == 7'd0);
    bf16_a_is_nan = (fp_exp_a == 8'hFF) && (weight_mul[6:0] != 7'd0);
    bf16_b_is_inf = (fp_exp_b == 8'hFF) && (act_in[6:0] == 7'd0);
    bf16_b_is_nan = (fp_exp_b == 8'hFF) && (act_in[6:0] != 7'd0);
  end

  // MX scale NaN — FRONT side (moved from Section 8B; live scale ports are
  // consumed HERE only, the back reads c6f_mx_nan_q / c6f_corr_q).
  logic mx_scale_nan;
  always_comb begin
    if (scale_format == SCALE_E4M3)
      mx_scale_nan = mode_is_mx(mode)
                  && ((mx_scale_a_cur[6:0] == 7'b1111_111)
                   || (mx_scale_b_cur[6:0] == 7'b1111_111));
    else
      mx_scale_nan = mode_is_mx(mode)
                  && ((mx_scale_a_cur == 8'hFF) || (mx_scale_b_cur == 8'hFF));
  end

  // [C6] valid decision — FRONT side (belongs to the SAME operand as the
  // front products, V3 contract re-anchored at the c6f rank). Algebraic
  // identity with the pre-split form (which ORed the BACK aggregates):
  //   lru_to_acc.is_nan|is_inf  == (|lruf_nan) | (|lruf_inf) | mx_scale_nan
  //     (the !nan qualifier on is_inf is absorbed under OR)
  //   bf16_prod_to_acc.is_nan|is_inf == mode==BF16 && (a_nan|b_nan|a_inf|b_inf)
  //     (the Inf×0→NaN terms are absorbed by a_inf|b_inf under OR;
  //      MXINT8/default arms contribute only mx_scale_nan, already present)
  logic special_force_valid;
  logic fp_acc_skip;
  logic fp_acc_valid_in;

  assign special_force_valid =
      mx_scale_nan
    | lruf_nan[0] | lruf_nan[1] | lruf_nan[2] | lruf_nan[3]
    | lruf_inf[0] | lruf_inf[1] | lruf_inf[2] | lruf_inf[3]
    | ((mode == MODE_BF16)
       && (bf16_a_is_nan | bf16_b_is_nan | bf16_a_is_inf | bf16_b_is_inf));

  assign fp_acc_skip = ZEROSKIP_EN && zd_result.skip_accumulation
                     && !special_force_valid;

  always_comb begin
    unique case (mode)
      MODE_FP4, MODE_FP8, MODE_BF16,
      MODE_MXFP4, MODE_MXFP8, MODE_MXINT8:
                  fp_acc_valid_in = mac_en & ~fp_acc_skip;
      default:    fp_acc_valid_in = 1'b0;
    endcase
  end

  // ---- c6f shared front rank (the seam registers; consumer-held per the
  //      C8-a template). Advances ONLY on array_step_en; clear_acc clears
  //      the VALID (V2 contract, both ranks); data regs may hold stale
  //      values — with valid low they are never consumed before overwrite.
  logic              c6f_lruf_sign [4];
  logic signed [9:0] c6f_lruf_expP [4];
  logic              c6f_lruf_zero [4];
  logic              c6f_lruf_nan  [4];
  logic              c6f_lruf_inf  [4];
  logic [11:0]       c6f_lruf_mant [4];
  logic [15:0]       c6f_adder_tree;
  logic [7:0]        c6f_fp_exp_a, c6f_fp_exp_b;
  logic              c6f_fp_sign_a, c6f_fp_sign_b;
  logic              c6f_bf16_a_inf, c6f_bf16_a_nan;
  logic              c6f_bf16_b_inf, c6f_bf16_b_nan;
  logic signed [9:0] c6f_mx_offset;
  logic              c6f_mx_nan;
  logic [7:0]        c6f_corr;
  tensor_mode_e      c6f_mode;
  logic              c6f_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) begin
        c6f_lruf_sign[i] <= 1'b0;
        c6f_lruf_expP[i] <= 10'sd0;
        c6f_lruf_zero[i] <= 1'b1;
        c6f_lruf_nan[i]  <= 1'b0;
        c6f_lruf_inf[i]  <= 1'b0;
        c6f_lruf_mant[i] <= '0;
      end
      c6f_adder_tree <= '0;
      c6f_fp_exp_a   <= '0;
      c6f_fp_exp_b   <= '0;
      c6f_fp_sign_a  <= 1'b0;
      c6f_fp_sign_b  <= 1'b0;
      c6f_bf16_a_inf <= 1'b0;
      c6f_bf16_a_nan <= 1'b0;
      c6f_bf16_b_inf <= 1'b0;
      c6f_bf16_b_nan <= 1'b0;
      c6f_mx_offset  <= 10'sd0;
      c6f_mx_nan     <= 1'b0;
      c6f_corr       <= 8'd0;
      c6f_mode       <= tensor_mode_e'('0);
      c6f_valid      <= 1'b0;
    end else if (clear_acc) begin
      // V2 (both ranks): kill the stale drain-tail valid.
      c6f_valid <= 1'b0;
    end else if (array_step_en) begin
      c6f_lruf_sign  <= lruf_sign;
      c6f_lruf_expP  <= lruf_expP;
      c6f_lruf_zero  <= lruf_zero;
      c6f_lruf_nan   <= lruf_nan;
      c6f_lruf_inf   <= lruf_inf;
      c6f_lruf_mant  <= lruf_mant;
      c6f_adder_tree <= adder_tree_result;
      c6f_fp_exp_a   <= fp_exp_a;
      c6f_fp_exp_b   <= fp_exp_b;
      c6f_fp_sign_a  <= fp_sign_a;
      c6f_fp_sign_b  <= fp_sign_b;
      c6f_bf16_a_inf <= bf16_a_is_inf;
      c6f_bf16_a_nan <= bf16_a_is_nan;
      c6f_bf16_b_inf <= bf16_b_is_inf;
      c6f_bf16_b_nan <= bf16_b_is_nan;
      c6f_mx_offset  <= mx_offset;
      c6f_mx_nan     <= mx_scale_nan;
      c6f_corr       <= e4m3_mant_corr;
      c6f_mode       <= mode;
      c6f_valid      <= fp_acc_valid_in;
    end
  end

  // ==========================================================================
  // Section 8: Direct Product Assembly → fp_product_t
  //            [C6-c] BACK half — consumes the c6f-REGISTERED seam ONLY
  // ==========================================================================
  //
  // v4.0: MODE_BF16 only.
  // v4.1 R1: MODE_BF16 + MODE_MXINT8 (path migration).
  // v4.1 R2: BF16 NaN/Inf detection (P7) — flag PRODUCERS moved to Section
  //          7C (front); this block assembles from c6f_bf16_* (single source).
  // v4.1 R4: MXINT8 sign separation + mx_offset. Full MX semantic closure.
  // R3:      BF16 sticky fix in product overflow path (code opt #3).

  logic signed [9:0] bf16_exp_sum;
  logic [15:0]       bf16_mant_prod;
  logic              bf16_prod_overflow;

  always_comb begin
    // Defaults
    bf16_exp_sum       = 10'sd0;
    bf16_mant_prod     = 16'd0;
    bf16_prod_overflow = 1'b0;
    bf16_prod          = '0;

    unique case (c6f_mode)

      // -----------------------------------------------------------------
      // BF16 — with NaN/Inf detection (v4.1 P7; [C6-c] flags from the
      // REGISTERED c6f copies — single source, no re-derivation)
      // -----------------------------------------------------------------
      MODE_BF16: begin
        // NaN propagation: input NaN, or Inf × 0 → NaN
        bf16_prod.is_nan = c6f_bf16_a_nan || c6f_bf16_b_nan
                        || (c6f_bf16_a_inf && (c6f_fp_exp_b == 8'd0))
                        || (c6f_bf16_b_inf && (c6f_fp_exp_a == 8'd0));

        // Inf propagation: Inf input and no NaN
        bf16_prod.is_inf = (c6f_bf16_a_inf || c6f_bf16_b_inf) && !bf16_prod.is_nan;
        bf16_prod.inf_sign = c6f_fp_sign_a ^ c6f_fp_sign_b;

        // If special value, mantissa/exp don't matter (accumulator uses flags)
        if (bf16_prod.is_nan || bf16_prod.is_inf) begin
          bf16_prod.mant = '0;
          bf16_prod.exp  = 10'sd0;
          bf16_prod.zero = 1'b0;  // Not zero — it's a special value
        end else begin
          // Normal BF16 product (existing logic)
          //
          // C07 source rebias: the product mantissa {1,m7}×{1,m7} carries ×2^14.
          // Subtract BF16_MANT_F (=14) here, in addition to the double exponent
          // bias (254), so bf16_prod obeys value = mant * 2^exp (integer mant).
          // This flows into both the normal and the >>1-overflow exp below.
          bf16_exp_sum = 10'(signed'({2'b0, c6f_fp_exp_a}))
                       + 10'(signed'({2'b0, c6f_fp_exp_b}))
                       - 10'(BF16_DOUBLE_BIAS) - 10'(BF16_MANT_F);

          bf16_mant_prod = c6f_adder_tree;
          bf16_prod_overflow = bf16_mant_prod[15];

          // v4.2a (P3-1): BF16 Flush-To-Zero (FTZ) for subnormals.
          //
          // DELIBERATE SCOPE DECISION: When either BF16 operand has exponent=0,
          // the product is treated as zero regardless of the fraction field.
          //
          // In IEEE 754, exp=0 with frac≠0 is a subnormal (denormalized) number.
          // Supporting subnormals would require:
          //   - Removing the implicit '1' hidden bit (subnormals have implicit '0')
          //   - Adjusting the exponent computation (subnormal exp is always -126)
          //   - Additional mux logic in the mantissa path
          //
          // For edge AI inference, subnormal inputs are exceedingly rare and
          // their contribution to dot-product accuracy is negligible. FTZ is
          // a common simplification in inference datapaths, and it is the
          // choice made for the BF16 path here.
          //
          // This is NOT a bug. If subnormal support is ever needed (e.g., for
          // training use cases), it should be implemented as a separate mode
          // with explicit opt-in via the compute mode or descriptor.
          bf16_prod.zero = (c6f_fp_exp_a == 8'd0) || (c6f_fp_exp_b == 8'd0);

          if (bf16_prod.zero) begin
            bf16_prod.mant = '0;
            bf16_prod.exp  = 10'sd0;
          end else if (bf16_prod_overflow) begin
            // =====================================================
            // R3 FIX (code opt #3): BF16 product sticky preservation
            // =====================================================
            //
            // When bit[15] of the 16-bit mantissa product is set, the
            // product value is ≥ 2.0 in the normalized representation,
            // and we must right-shift by 1 and add 1 to the exponent.
            //
            // BUG (v4.2): unconditional `>> 1` drops bit[0] silently.
            // FIX  (R3):   OR bit[0] into the new LSB as sticky so that
            //              downstream rounding sees the residue.
            //
            // Example:
            //   bf16_mant_prod = 16'b1000_0000_0000_0001  (32769)
            //   v4.2 (buggy):     >> 1 = 16'b0100_0000_0000_0000  (16384)
            //   R3 (sticky):      >> 1 | bit[0]
            //                          = 16'b0100_0000_0000_0001  (16385)
            //
            // The injected sticky then propagates through the FP
            // accumulator's alignment shifter (which already honors
            // stale sticky bits in the LSB correctly, see mac_fp_acc_align).
            automatic logic [15:0] shifted_with_sticky;
            shifted_with_sticky = (bf16_mant_prod >> 1)
                                | {15'd0, bf16_mant_prod[0]};
            bf16_prod.mant = (c6f_fp_sign_a ^ c6f_fp_sign_b)
                           ? -16'(shifted_with_sticky)
                           :  16'(shifted_with_sticky);
            bf16_prod.exp  = bf16_exp_sum + 10'sd1;
          end else begin
            bf16_prod.mant = (c6f_fp_sign_a ^ c6f_fp_sign_b)
                           ? -16'(bf16_mant_prod)
                           :  16'(bf16_mant_prod);
            bf16_prod.exp  = bf16_exp_sum;
          end
        end
      end

      // -----------------------------------------------------------------
      // MXINT8 — full MX semantic closure (v4.1 R4)
      // -----------------------------------------------------------------
      MODE_MXINT8: begin
        bf16_prod.exp  = c6f_mx_offset;
        bf16_prod.zero = (c6f_adder_tree == 16'd0);

        if (bf16_prod.zero) begin
          bf16_prod.mant = '0;
        end else if (c6f_fp_sign_a ^ c6f_fp_sign_b) begin
          bf16_prod.mant = -16'(c6f_adder_tree);     // Negative product
        end else begin
          bf16_prod.mant =  16'(c6f_adder_tree);     // Positive product
        end
        // is_nan/is_inf: handled below via MX scale NaN injection
      end

      default: begin
        bf16_prod = '0;
      end

    endcase
  end

  // ==========================================================================
  // Section 8B: MX Scale Processing — NaN + Offset (v4.1 R2+R4)
  // ==========================================================================
  //
  // Two MX-specific transformations applied to intermediary signals before
  // the FP accumulator:
  //
  //   1. NaN detection (R2/P7): E8M0 scale == 0xFF → force NaN
  //   2. Exponent offset (R4/P4): fold mx_offset into LRU exponent for MXFP,
  //      enabling correct cross-cycle and cross-MX-block accumulation.
  //      MXINT8 offset is already set in Section 8 (bf16_prod.exp = mx_offset).
  //
  // R3: `(mode == MXFP4 || MXFP8 || MXINT8)` replaced by mode_is_mx(mode).
  //     Note: the MXFP-only check below stays as-is (mode_is_mx includes
  //     MXINT8, which has its own offset path in Section 8 and must NOT
  //     have its LRU exponent adjusted here).

  // [C6-b/c] mx_scale_nan PRODUCER moved to Section 7C (front); this block
  // consumes the REGISTERED c6f copies exclusively (review F2-SEAM: the
  // scale_pass sidebands advance on array_step_en, so a live read here
  // would pair a t+1 scale with t-step products — single-beat NaN blocks
  // would be silently swallowed). scale_format alone stays live: it is a
  // per-tile constant. 🔴 [2026-07-31 CORRECTION] "descriptor-latched" is NOT true today:
  // tile_descriptor_t has no scale_format field and tensor_mac_array does not drive
  // this port -> all 256 cells fall back to SCALE_E8M0. The descriptor->array
  // threading is a follow-up (see the port comment at :196-200 and E1).

  // ==========================================================================
  // Section 8C: [C6-b] LRU BACK half — consumes the c6f-registered seam
  // ==========================================================================
  mac_lru_back u_lru_back (
    .mode         (c6f_mode),
    .lane_sign    (c6f_lruf_sign),
    .lane_expP    (c6f_lruf_expP),
    .lane_is_zero (c6f_lruf_zero),
    .lane_is_nan  (c6f_lruf_nan),
    .lane_is_inf  (c6f_lruf_inf),
    .mant_ext     (c6f_lruf_mant),
    .lru_out      (lru_out)
  );

  // ==========================================================================
  // [K1b] c6g seam — SECOND shared rank, inserted at `lru_out`
  // ==========================================================================
  // 判据 = aichip_run_logs/b58k1b_prereg_20260808.md（发数前预登记）
  // 靶   = aichip_run_logs/b58k1_grange_verdict_20260808.md（G-RANGE 判「有靶」）
  //
  // 为什么：签核临界路径 = c6f_lruf_nan[2] → u_lru_back(868.31 ps/66 级)
  //   → corr_sh 段(691.77 ps/57 级) → c6_lru_q，合计 1628.11 ps / 126 级。
  //   在此切一刀 ⇒ 两半 936.34 / 691.77 ps，**都远低于可用预算 1606.63 ps**。
  //
  // 🔴🔴 为什么必须是【整缝】而不是只延 lru 侧（G-RANGE §4.1，发数前读 RTL 亲验）：
  //   `c6_lru_q <= lru_to_acc` 与 `c6_prod_q <= bf16_prod_to_acc` 在**同一级**
  //   always_ff（下方 Section 8D），并**一起**喂 u_fp_acc（.lru_in / .bf16_prod_in）。
  //   只在 lru 侧插一级 ⇒ lru 比 prod 晚一拍 ⇒ 累加器把**错拍的两个操作数**配在一起
  //   ⇒ **产品序列改变 = 不是 value-preserving = 越出 DP-10 授权（M4/金标重写领域）**。
  //   ⇒ 本缝必须同时携带：数据(lru_out / bf16_prod) + valid + **corr_sh 段消费的
  //     全部控制位(mode / corr / mx_offset / mx_nan)**。该清单由穷举下游得到：
  //     `lru_out` ×5 · `bf16_prod` ×1 · `c6f_mode` ×2 · `c6f_corr` ×2 ·
  //     `c6f_mx_offset` ×2 · `c6f_mx_nan` ×1（mac_cell.sv:798-895 段内）。
  //     **漏任何一个都会让控制位与数据错拍。**
  //
  // 形状照抄 [C6-b]/[C6-c] 的 c6f 缝（声明 :542-556 / 写块 :559-610）——
  //   本次是同一手法第三次应用。V2 契约同样：clear_acc 只杀 valid，数据寄存器可留旧值。
  // Latency: DRAIN_CYCLES_OS 34 → 35（tensor_tile_controller.sv）+ TB 四处镜像。
  //   🔴 注意撞车：DRAIN_CYCLES_OS_SPARSE 原本就是 35（= OS+1），本刀后 OS 也变 35、
  //     SPARSE 变 36；且本文件 Section 8D 的注释把 35 预留给 M4 顺序版 —— **本次的
  //     35 是 K1b 的前馈切分，不是 M4 的环手术**。
  // ==========================================================================
  lru_result_t  c6g_lru;
  fp_product_t  c6g_prod;
  logic signed [9:0] c6g_mx_offset;
  logic         c6g_mx_nan;
  logic [7:0]   c6g_corr;
  tensor_mode_e c6g_mode;
  logic         c6g_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c6g_lru       <= '0;
      c6g_prod      <= '0;
      c6g_mx_offset <= 10'sd0;
      c6g_mx_nan    <= 1'b0;
      c6g_corr      <= 8'd0;
      c6g_mode      <= tensor_mode_e'('0);
      c6g_valid     <= 1'b0;
    end else if (clear_acc) begin
      // V2 (all ranks): kill the stale drain-tail valid; data regs may hold.
      c6g_valid <= 1'b0;
    end else if (array_step_en) begin
      c6g_lru       <= lru_out;
      c6g_prod      <= bf16_prod;
      c6g_mx_offset <= c6f_mx_offset;
      c6g_mx_nan    <= c6f_mx_nan;
      c6g_corr      <= c6f_corr;
      c6g_mode      <= c6f_mode;
      c6g_valid     <= c6f_valid;
    end
  end

  // Intermediaries: MX NaN injection + MXFP exponent offset
  // [K1b] 本段现在**只消费 c6g 缝**（禁再引用 lru_out / bf16_prod / c6f_*，
  //       那会把本级的组合逻辑重新接回切分点之前，等于这一刀白切）。
  lru_result_t lru_to_acc;
  fp_product_t bf16_prod_to_acc;

  always_comb begin
    lru_to_acc       = c6g_lru;
    bf16_prod_to_acc = c6g_prod;

    // (1) MX scale NaN injection ([C6] from the c6g-registered copy)
    if (c6g_mx_nan) begin
      lru_to_acc.is_nan       = 1'b1;
      bf16_prod_to_acc.is_nan = 1'b1;
    end

    // (2) MXFP exponent offset: lru_exp += mx_offset
    //   This folds the block scale into the per-cycle product exponent
    //   so the FP accumulator's cross-cycle alignment automatically handles
    //   scale changes at MX block boundaries.
    //   (Non-MX modes: mx_offset == 0, no effect.)
    //   (MXINT8: goes through bf16_prod path, not LRU, so excluded here.)
    //
    //   E1: for an E4M3 block scale, ALSO multiply the LRU mantissa by the
    //   significand product (e4m3_mant_corr) and renormalize back into the
    //   15-bit lru_result_t.mant field with a sticky bit, folding the renorm
    //   shift into the exponent. This keeps the accumulator critical path
    //   unchanged (the multiply + renorm live here, at the LRU output).
    //
    //   [C6-e 2026-07-29] 本块做了两处零 DFF 组合重构，**输出逐位不变**：
    //     E4′ |m·c| -> |m|·c —— c6g_corr 无符号，故绝对值可在乘法【前】取；
    //         24 位取负（乘法后）变成 15 位取负（乘法前），且符号选择信号
    //         从"乘法之后"提前到"乘法之前"整整一个乘法器。
    //         corr==0 的边角：两侧同为 0（取负 0 仍是 0），已在穷举里覆盖。
    //     E1c sticky 掩码 `(24'd1 << sh) - 24'd1` 的【借位链】-> 后缀 OR 预算
    //         + 索引选择。sh∈[0,10]、24 位无回绕 ⇒ 掩码恒等于 2^sh−1 ⇒
    //         |(corr_abs & mask) == |corr_abs[sh-1:0] == so24[sh]；
    //         sh==0 时 so24[0]==0，与原式的 (corr_sh != 0) 守卫同值 ⇒ 守卫可消。
    //   证明：**穷举**全输入空间 2^23 = 8,388,608 组（lru_mant 15b × corr 8b），
    //         0 失配（`EXHAUSTIVE-CORR vectors=8388608 mismatches=0 RESULT=PASS`）。
    //         判据与论证 = Review/BATCH5_Preflight_C6e_DepthGate_Criteria §5。
    if (c6g_mode == MODE_MXFP4 || c6g_mode == MODE_MXFP8) begin
      if (scale_format == SCALE_E4M3) begin
        automatic logic               corr_neg;     // = 符号，E4′ 提前取
        automatic logic        [14:0] corr_mabs;    // |c6g_lru.mant|
        automatic logic        [23:0] corr_abs;     // |m|·c（无符号）
        automatic logic        [16:0] corr_so;      // 后缀 OR：so[k]=|corr_abs[k-1:0]
        automatic logic        [4:0]  corr_sh;      // renorm right-shift (0..10)
        automatic logic               corr_sticky;
        automatic logic        [23:0] corr_shifted;
        automatic logic        [14:0] corr_mag;

        // E4′：符号与幅值在乘法前分离
        corr_neg  = c6g_lru.mant[14];
        corr_mabs = corr_neg ? (15'd0 - c6g_lru.mant) : c6g_lru.mant;
        corr_abs  = 24'({8'd0, corr_mabs} * 23'({15'd0, c6g_corr}));

        // E1c：后缀 OR（只依赖 corr_abs，与优先编码器并行）
        // 🔴 显式展开而非递推 `corr_so[k] = corr_so[k-1] | ...`：后者在同一
        //    always_comb 内自引用，Verilator 报 ALWCOMBORDER「driven after use」
        //    并把 6 个 elaborate 目标判红（2026-07-30 实测）。展开后无序依赖，
        //    综合侧由 CSE 还原成同一棵前缀网，逻辑逐位不变。
        corr_so[0]  = 1'b0;
        corr_so[1]  = corr_abs[0];
        corr_so[2]  = |corr_abs[1:0];
        corr_so[3]  = |corr_abs[2:0];
        corr_so[4]  = |corr_abs[3:0];
        corr_so[5]  = |corr_abs[4:0];
        corr_so[6]  = |corr_abs[5:0];
        corr_so[7]  = |corr_abs[6:0];
        corr_so[8]  = |corr_abs[7:0];
        corr_so[9]  = |corr_abs[8:0];
        corr_so[10] = |corr_abs[9:0];
        corr_so[11] = |corr_abs[10:0];
        corr_so[12] = |corr_abs[11:0];
        corr_so[13] = |corr_abs[12:0];
        corr_so[14] = |corr_abs[13:0];
        corr_so[15] = |corr_abs[14:0];
        corr_so[16] = |corr_abs[15:0];

        // Renorm: right-shift so |corrected| fits in 14 magnitude bits (msb≤13).
        corr_sh = 5'd0;
        for (int b = 23; b >= 14; b--)
          if (corr_abs[b]) begin
            corr_sh = 5'(b - 13);
            break;
          end

        corr_sticky  = corr_so[corr_sh[3:0]];
        corr_shifted = corr_abs >> corr_sh;
        corr_mag     = corr_shifted[14:0];
        corr_mag[0]  = corr_mag[0] | corr_sticky;   // sticky → LSB

        lru_to_acc.mant = corr_neg ? -15'(corr_mag) : 15'(corr_mag);
        lru_to_acc.exp  = c6g_lru.exp + c6g_mx_offset + 10'(signed'({5'b0, corr_sh}));
      end else begin
        lru_to_acc.exp = c6g_lru.exp + c6g_mx_offset;
      end
    end
  end

  // ==========================================================================
  // Section 9: FP Accumulator
  // ==========================================================================
  //
  // v4.1 (P1 fix): ALL FP and MX modes now use the FP accumulator.
  //   MODE_FP4/FP8:         lru_out (lru_result_t)  → FP accumulation
  //   MODE_MXFP4/MXFP8:    lru_out (lru_result_t)  → FP accumulation
  //   MODE_BF16:            bf16_prod (fp_product_t) → FP accumulation
  //   MODE_MXINT8:          bf16_prod (fp_product_t) → FP accumulation
  //   INT modes (UINT4/8):  FP acc not used
  //
  // v4.2 (A7 fix): special_force_valid bypasses skip_accumulation.
  //   When a special value (NaN/Inf from data or MX scale) is detected,
  //   the accumulator MUST update even if all data lanes are zero.
  //   Without this fix, mx_scale_nan with zero data would be swallowed
  //   by the power-gating skip logic, and NaN would never latch.

  // [C6-b/c] the A7 special_force_valid / fp_acc_skip / fp_acc_valid_in
  // decision MOVED to Section 7C (front side): the flags it needs are all
  // FRONT products now (lruf_nan/inf, bf16_a/b flags, mx_scale_nan), and
  // the decision must be registered WITH the front bundle it belongs to
  // (V3 contract re-anchored at the c6f rank; algebraic identity with the
  // pre-split OR-of-back-aggregates form is documented there).

  // ==========================================================================
  // Section 9A: §C6 feedforward stage (M3, 2026-07-24)
  // ==========================================================================
  //
  // One array_step_en-gated pipeline stage between the product/LRU cone and
  // the FP accumulator, splitting the mul→LRU/align→add reg2reg cone (77.4% of
  // the pressured Tensor binding path lived inside one u_mac; M2M3_AnchorPlan
  // §M3-0.3). Design review that gated this construction:
  // Review/C6_Preflight_ValidQual_SparseStall_2026-07-24.md.
  //
  //   - Advances ONLY on array_step_en (the skew-SR idiom) → frozen through
  //     EXEC_SPARSE_STRUCT frag stalls, in lockstep with the operand pipeline.
  //   - c6_valid_q registers the COMPLETE fp_acc_valid_in — the zero-skip and
  //     special_force_valid decisions belong to the SAME product as the
  //     registered bundle (review V3; registering bare mac_en would apply a
  //     NEW operand's skip decision to the OLD product on stall resume).
  //   - clear_acc CLEARS c6_valid_q (review V2): the OS drain tail pins the
  //     registered valid at 1, and without this clear the stale bundle —
  //     worst case carrying is_nan from an MX-scale-NaN tile (the
  //     special_force_valid path defeats the zero-skip) — would be consumed
  //     on the NEXT tile's first COMPUTE step, poisoning the fresh
  //     accumulator. clear_acc/array_step_en never overlap (controller A1
  //     assertion), so the priority below is unambiguous.
  //   - Consumption is qualified with array_step_en: on a stall cycle the
  //     ungated accumulator sees valid_in=0 → no re-add. (The naive
  //     valid-held form re-adds the pre-stall product S+1 times — refuted in
  //     §A2, demonstrated red by tb/test_tensor_sparse_stall.py.)
  //     🔴 [3a-1 S1 2026-08-02 连坐，S2 补记] 原文写「which now stands guard」——
  //        **该守门自 S1 起已不存在**：文件改名 `tb/pending_test_tensor_sparse_stall.py`
  //        退出 run_all glob。注释声称有守门而实际没有 = fail-open 型 15 形态，
  //        故就地订正。红证仍在案；复活条件 = 3c 金标重写 + 新 harness。
  //   - Latency mirror: DRAIN_CYCLES_OS 32→33 (§C6) →34 ([C6-b/c] the c6f
  //     shared front rank adds ONE more FP-side stage;
  //     tensor_tile_controller.sv:381) + DRAIN_ACC (test_tensor_gemm_egress
  //     .py). The cut is entirely on the FP side: the INT psum path
  //     (Section 10) keeps the UNdelayed mode/mac_en, and
  //     DRAIN_CYCLES_WS=15 stays frozen (WS core untouched — C6 preflight
  //     :84 rationale inherited; WS×FP-acc is an architectural exclusion,
  //     K1c WS-guard $warning in the controller).
  //     🔴 [3a-6/P2 2026-08-04] 本链新增**第二条腿**：稀疏臂 drain = **35**
  //       (`DRAIN_CYCLES_OS_SPARSE = DRAIN_CYCLES_OS + 1`)，分臂谓词 = **n_cfg**
  //       (`n_cfg != NCFG_DENSE`)，**不是 exec**（`D-SPARSE-3A6-PREREQ-2026-08-04` Q2：
  //       exec 谓词会把 `exec=SPARSE ∧ n_cfg=DENSE` 的 N=4 恒等点探针拖进 35 而当场破)。
  //       **本 cell 的 FP 流水级数没有因此改变** —— 35 对应的是规格 §6.3 给稀疏臂配的
  //       +1 拍**权重滞后 L(n_cfg)**（落点在 operand 侧，按同一裁决 Q5 转出 3b/3c），
  //       不是 mac_cell 又加了一级。⇒ 本注释链的口径 = 「dense 34 / 稀疏 35，
  //       两者的差来自 operand 侧滞后，不来自本文件」。今天 L 还没落 ⇒ 稀疏 drain
  //       暂时比物理需要多一拍（已登记的过渡态，见 controller 那处长注释）。
  //       WS 臂不受影响：稀疏×WS 在 `tensor_mac_array` 的 C1-b 绊线上先被 $fatal 拦下。

  lru_result_t  c6_lru_q;
  fp_product_t  c6_prod_q;
  tensor_mode_e c6_mode_q;
  logic         c6_valid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      c6_lru_q   <= '0;
      c6_prod_q  <= '0;
      c6_mode_q  <= tensor_mode_e'('0);
      c6_valid_q <= 1'b0;
    end else if (clear_acc) begin
      // V2: kill the stale drain-tail valid. Data regs may hold their value —
      // with valid low they are never consumed before being overwritten.
      c6_valid_q <= 1'b0;
    end else if (array_step_en) begin
      // [C6-b/c] the c6 rank advances the BACK-half products and the PIPED
      // mode/valid. [K1b] 现在是**三级**捆绑（原为两级）：
      //   c6f(t) = front(operands@t) · c6g(t+1) = back(c6f@t) · c6(t+2) = corr(c6g@t+1)
      // 🔴 mode/valid 必须跟到 **c6g**，不能停在 c6f —— 否则控制位比数据早一拍，
      //    与 §K1b 缝注释里说的「错拍」是同一个错，只是发生在控制侧。
      c6_lru_q   <= lru_to_acc;
      c6_prod_q  <= bf16_prod_to_acc;
      c6_mode_q  <= c6g_mode;
      c6_valid_q <= c6g_valid;
    end
  end

  logic c6_valid_to_acc;
  assign c6_valid_to_acc = c6_valid_q & array_step_en;

  mac_fp_accumulator #(
    .ACC_W     (ACC_WIDTH),
    .SHIFT_MAX (40)
  ) u_fp_acc (
    .clk          (clk),
    .rst_n        (rst_n),
    .clear        (clear_acc),
    .valid_in     (c6_valid_to_acc),   // §C6: array_step_en-qualified delayed valid
    .mode         (c6_mode_q),         // §C6: delayed with the bundle
    .lru_in       (c6_lru_q),          // §C6 delayed (MX NaN injected upstream)
    .bf16_prod_in (c6_prod_q),         // §C6 delayed (MX NaN injected upstream)
    .fp_acc_out   (fp_acc_out)
  );

  // ==========================================================================
  // Section 10: INT Accumulator Path — Product Extension + psum
  // ==========================================================================
  //
  // Mode-dependent product routing into the INT partial-sum chain:
  //
  //   UINT4_SIMD:   sum of 4 independent gated 8-bit products
  //   UINT8:        single 16-bit fracturable tree result
  //   All other modes: INT path unused (product_extended = 0)

  logic signed [ACC_WIDTH-1:0] product_extended;
  logic                        int_acc_en;

  always_comb begin
    product_extended = '0;
    int_acc_en       = 1'b0;

    unique case (mode)

      MODE_UINT4_SIMD: begin
        // Sum of 4 independent 4×4 products (each zero-extended to ACC_WIDTH)
        product_extended = ACC_WIDTH'({1'b0, mul_prod_gated[0]})
                         + ACC_WIDTH'({1'b0, mul_prod_gated[1]})
                         + ACC_WIDTH'({1'b0, mul_prod_gated[2]})
                         + ACC_WIDTH'({1'b0, mul_prod_gated[3]});
        int_acc_en = mac_en;
      end

      MODE_UINT8: begin
        // Single 8×8 product from fracturable adder tree (unsigned)
        product_extended = ACC_WIDTH'({1'b0, adder_tree_result});
        int_acc_en = mac_en;
      end

      default: begin
        product_extended = '0;
        int_acc_en       = 1'b0;
      end

    endcase
  end

  // ---- INT Partial Sum Accumulator (sequential) ----

  logic signed [ACC_WIDTH-1:0] int_acc_reg;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      int_acc_reg <= '0;
    else if (clear_acc)
      int_acc_reg <= '0;
    else if (int_acc_en && !(ZEROSKIP_EN && zd_result.skip_accumulation))
      int_acc_reg <= int_acc_reg + product_extended;
  end

  // psum chain: current accumulator + incoming partial sum from north
  assign psum_out = int_acc_reg + psum_in;

  // ==========================================================================
  // Section 11: Snapshot Register (NEW in Round E1 / R3)
  // ==========================================================================
  //
  // Per-MAC block-float snapshot latch for tile-level atomic capture.
  //
  // Purpose:
  //   Decouple egress lifetime from accumulator lifetime. When the tile
  //   controller asserts capture_fire (1 cycle, during ST_CAPTURE), the
  //   current fp_acc_out is atomically latched into fp_acc_snapshot_q.
  //
  //   After capture, the tensor_egress_fragmentizer (R4) reads the snapshot
  //   via a row-mux exposed by tensor_mac_array (R6), while the accumulator
  //   itself can be cleared and reused by the next tile.
  //
  // Architectural notes (see Vector_Unit_OFU_Sidecar_Design_Plan.md §5.2):
  //
  //   - DISTRIBUTED STORAGE: each MAC cell owns its own snapshot register
  //     locally. Physical proximity to the accumulator minimizes write-path
  //     wire length and simplifies place-and-route.
  //
  //   - CENTRALIZED CONTROL: capture_fire is a single control signal
  //     broadcast from tensor_tile_controller (R5) to all 256 cells via
  //     tensor_mac_array (R6). All snapshots latch on the same clock edge,
  //     producing a consistent tile-wide atomic capture. No per-cell edge
  //     detection or wavefront-aware latching is required.
  //
  //   - ROW-STRUCTURED READOUT: the array top-level provides a 16:1 row
  //     mux that selects one row of 16 snapshots per cycle for the
  //     fragmentizer. This cell unconditionally exposes fp_acc_snapshot;
  //     row selection happens one level up.
  //
  // Reset behavior:
  //   On rst_n=0, snapshot_q is cleared to all-zero. Note that clear_acc
  //   does NOT reset the snapshot — the snapshot belongs to the PREVIOUS
  //   tile (whose egress row-scan may still be in progress), and clearing
  //   it on clear_acc would corrupt ongoing row-scan operations.
  //
  // Timing invariant (enforced by tile controller FSM, not this module):
  //   capture_fire and clear_acc must NEVER be asserted in the same cycle.
  //   The overlap assertion in Section 12 provides defense-in-depth.

  fp_acc_output_t fp_acc_snapshot_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      fp_acc_snapshot_q <= '0;
    else if (capture_fire)
      fp_acc_snapshot_q <= fp_acc_out;
  end

  assign fp_acc_snapshot = fp_acc_snapshot_q;

  // ==========================================================================
  // Section 12: Assertions
  // ==========================================================================
  // synopsys translate_off

  // A7 CRITICAL: special values always reach the accumulator
  assert property (@(posedge clk) disable iff (!rst_n)
      (special_force_valid && mac_en) |-> fp_acc_valid_in
  ) else $error("MAC_CELL [A7]: special value blocked by skip_accumulation");

  // A7 specific: MX scale NaN with all-zero data must still fire valid_in
  assert property (@(posedge clk) disable iff (!rst_n)
      (mx_scale_nan && mac_en) |-> fp_acc_valid_in
  ) else $error("MAC_CELL [A7]: mx_scale_nan swallowed by zero-skip");

  // R3 NEW: capture_fire and clear_acc must not overlap.
  // Tile controller FSM invariant; checked here as defense-in-depth.
  // If this fires, the previous tile's snapshot is corrupted because
  // the accumulator is being cleared in the same cycle it's being latched.
  assert property (@(posedge clk) disable iff (!rst_n)
      !(capture_fire && clear_acc)
  ) else $error("MAC_CELL [R3]: capture_fire and clear_acc asserted simultaneously");

  // §C6 (review V2): clear_acc must flush the feedforward stage's valid — a
  // stale drain-tail valid consumed on the next tile's first step would
  // re-add last tile's bundle (NaN-poisoning in the MX-scale-NaN case).
  assert property (@(posedge clk) disable iff (!rst_n)
      clear_acc |=> !c6_valid_q
  ) else $error("MAC_CELL [C6]: c6_valid_q survived clear_acc — stale-bundle hazard");

  // §C6: the accumulator must never take a product on the same cycle the
  // accumulator is being cleared (would silently drop or resurrect a product).
  assert property (@(posedge clk) disable iff (!rst_n)
      !(clear_acc && c6_valid_to_acc)
  ) else $error("MAC_CELL [C6]: clear_acc and c6_valid_to_acc overlap");

  // synopsys translate_on

endmodule

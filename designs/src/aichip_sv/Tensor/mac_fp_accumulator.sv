// ============================================================================
// MAC Block-Float Accumulator v4.3 (Round E1 / R2.2)
// ============================================================================
//
// Sequential top-level that maintains a block-float accumulator state
// {acc_exp, acc_mant} and updates it each cycle with an incoming product
// from the LRU (FP4/FP8/MX) or BF16/MXINT8 direct path.
//
// Previously named upe_fp_accumulator. Renamed as part of the Round E
// naming cleanup (UPE → MAC cell distinction). No functional changes.
//
// ----------------------------------------------------------------------------
// Round E1 / R2.2 changes:
//   - File  rename:      upe_fp_accumulator.sv → mac_fp_accumulator.sv
//   - Module rename:     upe_fp_accumulator  → mac_fp_accumulator
//   - Package import:    upe_pkg → tensor_pkg
//   - Type rename:       upe_mode_e → tensor_mode_e
//   - Submodule renames: upe_fp_acc_align → mac_fp_acc_align (u_align)
//                        upe_tz_shifter   → mac_tz_shifter   (u_renorm_shifter)
//   - Assertion tag:     "UPE_FP_ACC" → "MAC_FP_ACC"
//   - No functional logic changes
//
// ----------------------------------------------------------------------------
// v4.1 Round 2 features retained:
//   P6: Internal width = ACC_W+1 (49-bit). Eliminates MIN_INT abs overflow.
//   P7: NaN/Inf state machine with 3-bit state {nan, inf, inf_sign}.
//       Once NaN latched, mant/exp registers stop updating (power saving).
//
// v4.2 Round 6 additions (retained):
//   - Assertion: clear and valid_in never simultaneous (A1 defense-in-depth)
//   - Assertion: Inf state persists until clear (symmetric with NaN P7)
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R2.2 — tensor_pkg migration + submodule rename)
// ============================================================================

module mac_fp_accumulator
  import tensor_pkg::*;
#(
  parameter int ACC_W     = ACC_WIDTH_DEFAULT,  // 48 (external output width)
  parameter int SHIFT_MAX = 40                  // Alignment clamp threshold
) (
  // ---- Clock / Reset ----
  input  logic           clk,
  input  logic           rst_n,

  // ---- Control ----
  input  logic           clear,       // Synchronous clear: new dot-product
  input  logic           valid_in,    // Valid product this cycle

  // ---- Mode ----
  input  tensor_mode_e   mode,

  // ---- Product Inputs ----
  input  lru_result_t    lru_in,
  input  fp_product_t    bf16_prod_in,

  // ---- Accumulator Output ----
  output fp_acc_output_t fp_acc_out
);

  // ==========================================================================
  // Internal Width (P6)
  // ==========================================================================
  localparam int INTERNAL_W = ACC_W + 1;  // 49

  // ==========================================================================
  // State Registers
  // ==========================================================================
  logic signed [INTERNAL_W-1:0] acc_mant_reg;
  logic signed [9:0]            acc_exp_reg;
  logic                         acc_is_zero_reg;

  // v4.1 (P7): NaN/Inf state
  logic                         acc_nan_reg;
  logic                         acc_inf_reg;
  logic                         acc_inf_sign_reg;

  // ==========================================================================
  // Product Special-Value Extraction (P7)
  // ==========================================================================
  logic prod_is_nan, prod_is_inf, prod_inf_sign;

  always_comb begin
    prod_is_nan   = 1'b0;
    prod_is_inf   = 1'b0;
    prod_inf_sign = 1'b0;

    unique case (mode)
      MODE_FP4, MODE_FP8, MODE_MXFP4, MODE_MXFP8: begin
        prod_is_nan   = lru_in.is_nan;
        prod_is_inf   = lru_in.is_inf;
        prod_inf_sign = lru_in.inf_sign;
      end
      MODE_BF16, MODE_MXINT8: begin
        prod_is_nan   = bf16_prod_in.is_nan;
        prod_is_inf   = bf16_prod_in.is_inf;
        prod_inf_sign = bf16_prod_in.inf_sign;
      end
      default: ;
    endcase
  end

  // ==========================================================================
  // Alignment Unit (INTERNAL_W-bit) — [GR-A 2026-07-28] three-addend contract
  // ==========================================================================
  logic signed [INTERNAL_W-1:0] add_other;
  logic signed [INTERNAL_W-1:0] add_shifted;
  logic [1:0]                   add_k;
  logic signed [9:0]            align_exp;
  logic                         align_skip;

  mac_fp_acc_align #(
    .ACC_W     (INTERNAL_W),   // P6: ACC_W+1
    .SHIFT_MAX (SHIFT_MAX)
  ) u_align (
    .lru_in       (lru_in),
    .bf16_prod_in (bf16_prod_in),
    .mode         (mode),
    .acc_mant_in  (acc_mant_reg),
    .acc_exp_in   (acc_exp_reg),
    .acc_is_zero  (acc_is_zero_reg),
    .add_other    (add_other),
    .add_shifted  (add_shifted),
    .add_k        (add_k),
    .new_exp      (align_exp),
    .skip         (align_skip)
  );

  // ==========================================================================
  // Addition — [GR-A] explicit CSA row (other, shifted_raw, K) + compound
  // carry-propagate pair (S, S+2). All widths parameterized on INTERNAL_W
  // (review B2-F2: no hard-coded 49; the ACC_W=20/SHIFT_MAX=4 shrink
  // harnesses are normative simulation calibers).
  // ==========================================================================
  logic [INTERNAL_W-1:0] csa_a, csa_b, csa_k;
  logic [INTERNAL_W-1:0] csa_ps, csa_cs, csa_cs2;
  assign csa_a  = $unsigned(add_other);
  assign csa_b  = $unsigned(add_shifted);
  assign csa_k  = {{(INTERNAL_W-2){1'b0}}, add_k};
  assign csa_ps = csa_a ^ csa_b ^ csa_k;
  assign csa_cs = (csa_a & csa_b) | (csa_a & csa_k) | (csa_b & csa_k);
  assign csa_cs2 = {csa_cs[INTERNAL_W-2:0], 1'b0};

  logic signed [INTERNAL_W-1:0] sum_mant;
  logic signed [INTERNAL_W-1:0] sum_mant_p2;   // compound: S+2, for the renorm arm
  assign sum_mant    = $signed(csa_ps + csa_cs2);
  assign sum_mant_p2 = $signed(csa_ps + csa_cs2 + INTERNAL_W'(2));

  // [GR-A] M35 zero flag in PARALLEL with the adder (identity 3, exhaustively
  // proven): a + b == 0 (mod 2^W)  <=>  (a ^ b) == ((a | b) << 1).
  logic [INTERNAL_W-1:0] zdet_or2;
  logic                  sum_is_zero;
  assign zdet_or2    = {(csa_ps[INTERNAL_W-2:0] | csa_cs2[INTERNAL_W-2:0]), 1'b0};
  assign sum_is_zero = ((csa_ps ^ csa_cs2) == zdet_or2);

  // ==========================================================================
  // Overflow Detection + Renormalization — [GR-A] compound select replaces
  // the u_renorm_shifter instance (a second full-width increment carry
  // chain, ~240ps on the batch-2 postcts acc arc):
  //   tz(sum,1) = (sum>>>1) + (neg & sum[0]) == (neg&sum[0] ? sum+2 : sum) >>> 1
  // (identity 1). renorm sticky = sum[0] (the 1-bit shift residue), OR-ed
  // into the LSB in the M36 arm below — semantics unchanged.
  // ==========================================================================
  logic overflow;
  assign overflow = (sum_mant[INTERNAL_W-2:INTERNAL_W-3] != {2{sum_mant[INTERNAL_W-1]}});

  logic signed [INTERNAL_W-1:0] renorm_base;
  logic signed [INTERNAL_W-1:0] renorm_mant;
  logic                         renorm_sticky;
  assign renorm_base   = (sum_mant[INTERNAL_W-1] & sum_mant[0]) ? sum_mant_p2 : sum_mant;
  assign renorm_mant   = renorm_base >>> 1;
  assign renorm_sticky = sum_mant[0];

  // ==========================================================================
  // Next-State Selection (P6 + P7)
  // ==========================================================================
  logic signed [INTERNAL_W-1:0] next_mant;
  logic signed [9:0]            next_exp;
  logic                         next_is_zero;
  logic                         next_nan, next_inf, next_inf_sign;

  always_comb begin
    // Default: hold
    next_mant     = acc_mant_reg;
    next_exp      = acc_exp_reg;
    next_is_zero  = acc_is_zero_reg;
    next_nan      = acc_nan_reg;
    next_inf      = acc_inf_reg;
    next_inf_sign = acc_inf_sign_reg;

    if (clear) begin
      // ---- Synchronous clear ----
      next_mant     = '0;
      next_exp      = 10'sd0;
      next_is_zero  = 1'b1;
      next_nan      = 1'b0;
      next_inf      = 1'b0;
      next_inf_sign = 1'b0;

    end else if (valid_in) begin

      // ---- P7: NaN/Inf state machine (priority-ordered) ----

      if (acc_nan_reg) begin
        // (1) Latched NaN → freeze all state

      end else if (prod_is_nan) begin
        // (2) New NaN → latch
        next_nan = 1'b1;

      end else if (acc_inf_reg) begin
        if (prod_is_inf && (prod_inf_sign != acc_inf_sign_reg)) begin
          // (3) Inf + (−Inf) → NaN
          next_nan = 1'b1;
        end

      end else if (prod_is_inf) begin
        // (4) First Inf → latch
        next_inf      = 1'b1;
        next_inf_sign = prod_inf_sign;

      end else if (!align_skip) begin
        // (5) Normal block-float accumulation

        if (sum_is_zero) begin   // [GR-A] parallel zero flag (identity 3)
          // M35: exact cancellation → reset to a CLEAN zero (re-anchor exponent).
          //
          // acc_exp is a running-max that is never lowered. If a catastrophic
          // cancellation drives the mantissa to 0 while acc_exp stays at the
          // historical maximum E, every subsequent small product lands
          // (E - prod_exp) > SHIFT_MAX away and is flushed to a 1-LSB sticky at
          // 2^E — so K small products read as ~K*2^E instead of their true sum.
          // Resetting to zero-state lets the next product be freshly adopted at
          // its own exponent. (Partial cancellation leaves a nonzero mantissa
          // whose value is still ~2^E, so it is correctly comparable to same-
          // magnitude products and needs no re-anchor; only the exact-zero case
          // is catastrophic. Deep same-magnitude accumulation is unaffected —
          // it never hits sum==0.)
          next_mant    = '0;
          next_exp     = 10'sd0;
          next_is_zero = 1'b1;
        end else begin
          next_is_zero = 1'b0;

          if (overflow) begin
            // M36: the overflow renorm (sum_mant >> 1) produced renorm_sticky,
            // which was previously dropped (dangling signal). OR it into the LSB
            // so the shifted-out bit is preserved — consistent with the align
            // path and LRU sticky injection (OR-into-LSB strategy).
            next_mant    = renorm_mant;
            next_mant[0] = next_mant[0] | renorm_sticky;
            next_exp     = align_exp + 10'sd1;
          end else begin
            next_mant = sum_mant;
            next_exp  = align_exp;
          end
        end
      end
    end
  end

  // ==========================================================================
  // State Register Update
  // ==========================================================================
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_mant_reg     <= '0;
      acc_exp_reg      <= 10'sd0;
      acc_is_zero_reg  <= 1'b1;
      acc_nan_reg      <= 1'b0;
      acc_inf_reg      <= 1'b0;
      acc_inf_sign_reg <= 1'b0;
    end else begin
      acc_mant_reg     <= next_mant;
      acc_exp_reg      <= next_exp;
      acc_is_zero_reg  <= next_is_zero;
      acc_nan_reg      <= next_nan;
      acc_inf_reg      <= next_inf;
      acc_inf_sign_reg <= next_inf_sign;
    end
  end

  // ==========================================================================
  // Output Packaging (P6 + P7)
  // ==========================================================================
  logic [INTERNAL_W-1:0] abs_mant_internal;

  always_comb begin
    // P6: 49-bit absolute value (never overflows)
    abs_mant_internal = acc_mant_reg[INTERNAL_W-1]
                      ? INTERNAL_W'(-acc_mant_reg)
                      : INTERNAL_W'(acc_mant_reg);

    fp_acc_out.mant = abs_mant_internal[ACC_W-1:0];  // [47:0]
    fp_acc_out.exp  = acc_exp_reg[9:0];

    // Sign: Inf sign overrides mantissa sign
    fp_acc_out.sign = (acc_inf_reg && !acc_nan_reg)
                    ? acc_inf_sign_reg
                    : acc_mant_reg[INTERNAL_W-1];

    // P7: Special-value flags
    fp_acc_out.is_nan = acc_nan_reg;
    fp_acc_out.is_inf = acc_inf_reg && !acc_nan_reg;
  end

  // ==========================================================================
  // Assertions
  // ==========================================================================
  // synopsys translate_off

  // P6: bit[48] of abs must be 0 during normal operation
  assert property (@(posedge clk) disable iff (!rst_n)
      !(valid_in && !clear && !acc_nan_reg && !acc_inf_reg)
      || (abs_mant_internal[INTERNAL_W-1] == 1'b0)
  ) else $error("MAC_FP_ACC: 49-bit abs overflow — renorm missed (mant=0x%0h)", acc_mant_reg);

  // P7: NaN once latched must persist until clear
  // `ifndef VERILATOR: Verilator 5.032 does not support the `##1` cycle-delay
  // sequence operator. This is a sim-only persistence check; VCS/Xcelium and
  // synthesis (which ignores translate_off) are unaffected by the guard.
`ifndef VERILATOR
  assert property (@(posedge clk) disable iff (!rst_n)
      acc_nan_reg |-> ##1 (acc_nan_reg || $past(clear))
  ) else $error("MAC_FP_ACC: NaN state de-asserted without clear");
`endif

  // ---- v4.2 additions (retained) ----

  // A1 defense-in-depth: clear and valid_in must never be simultaneous.
  // The tile controller (R2) guarantees this via ST_CLEAR_ACC separation,
  // but we verify it here as a second line of defense. If this fires,
  // the first product of every dot-product would be silently dropped.
  assert property (@(posedge clk) disable iff (!rst_n)
      !(clear && valid_in)
  ) else $error("MAC_FP_ACC [A1]: clear and valid_in simultaneous — first product lost");

  // P7 symmetric: Inf once latched must persist until clear (or NaN override).
  // The NaN persistence assertion exists since v4.1. This adds the Inf case:
  // once acc_inf_reg=1, it stays 1 unless cleared or overridden by NaN
  // (Inf + (-Inf) → NaN transition, which is the only valid Inf→NaN path).
  // `ifndef VERILATOR: same `##1` limitation as the NaN-persistence check above.
`ifndef VERILATOR
  assert property (@(posedge clk) disable iff (!rst_n)
      (acc_inf_reg && !acc_nan_reg)
      |-> ##1 (acc_inf_reg || acc_nan_reg || $past(clear))
  ) else $error("MAC_FP_ACC: Inf state de-asserted without clear or NaN override");
`endif

  // synopsys translate_on

endmodule

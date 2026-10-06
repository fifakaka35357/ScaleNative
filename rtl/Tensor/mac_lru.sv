// ============================================================================
// MAC Local Reduction Unit (LRU) v4.4 (§C6-b front/back split, 2026-07-27)
// ============================================================================
//
// Pure combinational block that reduces 2–4 independent floating-point
// products into a single block-float {exponent, mantissa} pair compatible
// with the downstream FP or INT accumulator.
//
// [C6-b 2026-07-27] Split into mac_lru_front | mac_lru_back on the
// Phase A | Phase B boundary (C8-a requantizer three-piece template):
//   - mac_lru_front: per-lane unpack → multiply → normalize → guard extend
//     (Phase A) + lane_zero. ALL special-value producers (FP8 NaN detect)
//     live here — the seam carries only flag bits.
//   - mac_lru_back:  max-exp tree (Phase B) + align/sticky/sign (Phase C)
//     + 4-input compressor + output pack + flag aggregation.
//   - mac_lru (wrapper): original ports VERBATIM, pure-wire seam — direct
//     unit TBs (test_mac_lru / test_m36_sticky) and any legacy consumer see
//     bit-identical single-cycle behavior. mac_cell instantiates front and
//     back SEPARATELY with the c6f seam registers between (seam registers
//     held by the CONSUMER — template rule).
// Seam encoding: unified 12-bit mant_ext slots (FP4 value in [7:0], top 4
// bits structurally 0 — disclosed in the C6B preflight GATE-0 account).
//
// v4.2 NOTE — Tail Mask Handling: unchanged (input_mux zeroes masked lanes;
// lane_is_zero excludes them — no control dependency in either half).
// v4.1 Round 2: P7 NaN detection, P14 FP8 parameterization
// ============================================================================

// ----------------------------------------------------------------------------
// [C6-b] FRONT — Phase A: per-lane unpack → multiply → normalize → guard ext
// ----------------------------------------------------------------------------
module mac_lru_front
  import tensor_pkg::*;
#(
  parameter int NUM_LANES  = 4,
  parameter int G          = tensor_pkg::GUARD_BITS
) (
  input  tensor_mode_e mode,
  input  logic [3:0]  fp4_a [NUM_LANES],
  input  logic [3:0]  fp4_b [NUM_LANES],
  input  logic [7:0]  fp8_a [2],
  input  logic [7:0]  fp8_b [2],

  // ---- Seam (→ mac_lru_back / c6f registers) ----
  output logic              lane_sign    [NUM_LANES],
  output logic signed [9:0] lane_expP    [NUM_LANES],
  output logic              lane_is_zero [NUM_LANES],
  output logic              lane_is_nan  [NUM_LANES],
  output logic              lane_is_inf  [NUM_LANES],
  output logic [11:0]       mant_ext     [NUM_LANES],  // unified 12b slot

  // ---- Per-Lane Zero Flags → mac_zero_detect (front product, stays live) ----
  output logic [3:0]  lane_zero
);

  localparam int FP4_PROD_W = 4;
  localparam int FP8_PROD_W = 8;
  localparam int FP4_EXT_W  = FP4_PROD_W + G + 1;  // 8
  localparam int FP8_EXT_W  = FP8_PROD_W + G + 1;  // 12

  // v4.1 (P14): Compile-time guard for unsupported FP8 variants
  // synopsys translate_off
  initial begin
    if (tensor_pkg::FP8_FMT != tensor_pkg::FP8_E4M3FN)
      $fatal(1, "mac_lru_front: FP8 variant %s not yet supported",
             tensor_pkg::FP8_FMT.name());
  end
  // synopsys translate_on

  always_comb begin
    for (int i = 0; i < NUM_LANES; i++) begin
      lane_sign[i]    = 1'b0;
      lane_expP[i]    = 10'sd0;
      lane_is_zero[i] = 1'b1;
      lane_is_nan[i]  = 1'b0;
      lane_is_inf[i]  = 1'b0;
      mant_ext[i]     = '0;
    end

    unique case (mode)

      MODE_FP4, MODE_MXFP4: begin
        for (int i = 0; i < NUM_LANES; i++) begin
          // Step 1: Unpack FP4 E2M1 (D4 subnormal handling verbatim)
          automatic logic fp4_sub_a = (fp4_a[i][2:1] == 2'b0) & fp4_a[i][0];
          automatic logic fp4_sub_b = (fp4_b[i][2:1] == 2'b0) & fp4_b[i][0];
          lane_sign[i]    = fp4_a[i][3] ^ fp4_b[i][3];
          lane_is_zero[i] = (fp4_a[i][2:0] == 3'b0) || (fp4_b[i][2:0] == 3'b0);

          if (!lane_is_zero[i]) begin
            // Step 2: Product exponent (unbiased)
            lane_expP[i] = 10'(signed'({1'b0, fp4_a[i][2:1]}))
                         + 10'(signed'({1'b0, fp4_b[i][2:1]}))
                         - 10'sd2;

            // Step 3: Mantissa multiply {1,fracA}×{1,fracB} → [7:4] of the
            // 8-bit FP4 subfield (guard [G:1] + sticky [0] zero from default;
            // slot bits [11:8] structurally 0 — unified-slot encoding).
            mant_ext[i][FP4_EXT_W-1:G+1] =
                ({1'b1, (fp4_sub_a ? 1'b0 : fp4_a[i][0])}
               * {1'b1, (fp4_sub_b ? 1'b0 : fp4_b[i][0])});

            // Step 4: Product normalize (full-subfield shift, v4.1 P2 fix;
            // top slot bits are 0 so a full 12b shift is bit-identical)
            if (mant_ext[i][FP4_EXT_W-1]) begin
              mant_ext[i] = mant_ext[i] >> 1;
              lane_expP[i] = lane_expP[i] + 10'sd1;
            end
          end
        end
      end

      MODE_FP8, MODE_MXFP8: begin
        for (int i = 0; i < 2; i++) begin
          // Step 1: Unpack FP8 E4M3FN (D4 subnormal normalize verbatim)
          automatic logic [2:0] fa  = fp8_a[i][2:0];
          automatic logic [2:0] fb  = fp8_b[i][2:0];
          automatic logic       za  = (fp8_a[i][6:3] == 4'b0) && (fa == 3'b0);
          automatic logic       zb  = (fp8_b[i][6:3] == 4'b0) && (fb == 3'b0);
          automatic logic       sba = (fp8_a[i][6:3] == 4'b0) && (fa != 3'b0);
          automatic logic       sbb = (fp8_b[i][6:3] == 4'b0) && (fb != 3'b0);
          automatic logic [2:0] sha = fa[2] ? 3'd1 : (fa[1] ? 3'd2 : 3'd3);
          automatic logic [2:0] shb = fb[2] ? 3'd1 : (fb[1] ? 3'd2 : 3'd3);
          automatic logic [3:0] m4a = sba ? (4'(fa) << sha) : {1'b1, fa};
          automatic logic [3:0] m4b = sbb ? (4'(fb) << shb) : {1'b1, fb};
          automatic logic signed [9:0] eea =
              sba ? (-10'sd6 - 10'(signed'({7'b0, sha})))
                  : (10'(signed'({6'b0, fp8_a[i][6:3]})) - 10'sd7);
          automatic logic signed [9:0] eeb =
              sbb ? (-10'sd6 - 10'(signed'({7'b0, shb})))
                  : (10'(signed'({6'b0, fp8_b[i][6:3]})) - 10'sd7);

          // Step 0 (v4.1 P7): NaN detection — the ONLY special-value
          // producer in the LRU; front side by construction (C6-b).
          lane_is_nan[i] = (fp8_a[i][6:0] == 7'b1111_111)
                        || (fp8_b[i][6:0] == 7'b1111_111);
          // lane_is_inf[i] stays 0 (E4M3FN has no Inf; E5M2 deferred)

          lane_sign[i]    = fp8_a[i][7] ^ fp8_b[i][7];
          lane_is_zero[i] = za || zb;

          if (!lane_is_zero[i] && !lane_is_nan[i]) begin
            // Step 2: Product exponent (unbiased)
            lane_expP[i] = eea + eeb;

            // Step 3: Mantissa multiply m4×m4 → [11:4]
            mant_ext[i][FP8_EXT_W-1:G+1] = (m4a * m4b);

            // Step 4: Product normalize (full-width shift, v4.1 P2 fix)
            if (mant_ext[i][FP8_EXT_W-1]) begin
              mant_ext[i] = mant_ext[i] >> 1;
              lane_expP[i] = lane_expP[i] + 10'sd1;
            end
          end
        end

        lane_is_zero[2] = 1'b1;
        lane_is_zero[3] = 1'b1;
      end

      default: ;  // LRU unused — defaults apply
    endcase

    // Lane zero output (front product; consumed live by mac_zero_detect)
    lane_zero = {lane_is_zero[3], lane_is_zero[2],
                 lane_is_zero[1], lane_is_zero[0]};
  end

endmodule

// ----------------------------------------------------------------------------
// [C6-b] BACK — Phase B (max-exp) + Phase C (align/sign) + compress + pack
// ----------------------------------------------------------------------------
module mac_lru_back
  import tensor_pkg::*;
#(
  parameter int NUM_LANES  = 4,
  parameter int G          = tensor_pkg::GUARD_BITS
) (
  input  tensor_mode_e mode,

  // ---- Seam (from mac_lru_front / c6f registers) ----
  input  logic              lane_sign    [NUM_LANES],
  input  logic signed [9:0] lane_expP    [NUM_LANES],
  input  logic              lane_is_zero [NUM_LANES],
  input  logic              lane_is_nan  [NUM_LANES],
  input  logic              lane_is_inf  [NUM_LANES],
  input  logic [11:0]       mant_ext     [NUM_LANES],

  output lru_result_t lru_out
);

  // ==========================================================================
  // [C6-e 2026-07-29] 零 DFF 组合重构 —— 端口/语义/位宽全部不变。
  //   本体与改前【全输入空间形式等价】（yosys miter + minisat SAT proof，
  //   2^104 输入空间，31 s，`equiv_lru_back.log` "SAT proof finished - no model
  //   found: SUCCESS"）。判据与论证 = Review/BATCH5_Preflight_C6e_DepthGate_
  //   Criteria_2026-07-29.md §5。三项改动：
  //
  //   E1 sticky：`(W'(1) << s) - W'(1)` 的【掩码借位链】-> 后缀 OR 预算 + 饱和
  //      索引选择。后缀 OR 只依赖 mant_ext（= c6f 寄存器输出）=> 与 max 树并行，
  //      整条掩码生成从关键路径上消失，只剩一个选择器。
  //      顺带证明：clamp 臂与非 clamp 臂【恒等】——s >= W 时 W'(1)<<s == 0 =>
  //      掩码 == 全 1，且 mant >> s == 0，与 clamp 臂同值 => 整个 if 分支可消
  //      （少一个比较器 + 一个 mux）。
  //   E2 取符号：逐 lane 的 15 位二补数取负 -> 按位取反 + 把 4 个 "+1" 归并成
  //      一个 3 位加数折进加法树（-x = ~x + 1）。不活跃 lane 令 sgn=0 且 vec=0
  //      => 贡献 0，与改前 lane_val 默认 '0 同值。
  //   E3 shift_dist：`6'(max_exp - lane_expP[i])` 只取低 6 位，而低位与高位
  //      无关 => 直接做 6 位减法（借位链 10 位 -> 6 位）。
  // ==========================================================================
  localparam int FP4_PROD_W = 4;
  localparam int FP8_PROD_W = 8;
  localparam int FP4_EXT_W  = FP4_PROD_W + G + 1;  // 8
  localparam int FP8_EXT_W  = FP8_PROD_W + G + 1;  // 12
  localparam int RESULT_W   = 15;
  // FP4_DMAX/FP8_DMAX 已随 E1 的分支恒等性证明退休（clamp 臂 == 非 clamp 臂）。

  localparam logic signed [9:0] EXP_NEG_INF = -10'sd512;

  logic signed [9:0] eff_expP [NUM_LANES];
  logic signed [9:0] max_01, max_23;
  logic signed [9:0] max_exp;

  // E1: 后缀 OR。so8[k] = |mant_ext[k-1:0]（FP4 子域 [7:0]），so12 同理 12 位。
  //     只依赖 mant_ext => 与 Phase B 并行，不在关键路径上。
  logic [8:0]  so8  [NUM_LANES];
  logic [12:0] so12 [NUM_LANES];

  logic [5:0]           shift_dist [NUM_LANES];
  logic [3:0]           sat8_idx   [NUM_LANES];   // min(shift_dist, 8)
  logic [3:0]           sat12_idx  [NUM_LANES];   // min(shift_dist, 12)
  logic                 sticky     [NUM_LANES];
  logic [FP8_EXT_W-1:0] algn       [NUM_LANES];   // 统一 12 位槽（FP4 只用 [7:0]）

  logic                       active [NUM_LANES];  // 该 lane 是否参与归约
  logic                       sgn    [NUM_LANES];  // 生效符号 = lane_sign & active
  logic [RESULT_W-1:0]        vec    [NUM_LANES];  // 取反/原值（+1 已折出）
  logic [2:0]                 sgn_cnt;
  logic signed [RESULT_W-1:0] reduced_mant;
  logic                       all_zero;

  // E1: 后缀 OR（纯组合，独立于 max 树 / shift_dist）
  always_comb begin
    for (int i = 0; i < NUM_LANES; i++) begin
      so8[i][0]  = 1'b0;
      so12[i][0] = 1'b0;
      for (int k = 1; k <= 8;  k++) so8[i][k]  = so8[i][k-1]  | mant_ext[i][k-1];
      for (int k = 1; k <= 12; k++) so12[i][k] = so12[i][k-1] | mant_ext[i][k-1];
    end
  end

  always_comb begin
    for (int i = 0; i < NUM_LANES; i++) begin
      eff_expP[i]   = EXP_NEG_INF;
      shift_dist[i] = 6'd0;
      sat8_idx[i]   = 4'd0;
      sat12_idx[i]  = 4'd0;
      sticky[i]     = 1'b0;
      algn[i]       = '0;
      active[i]     = 1'b0;
      sgn[i]        = 1'b0;
      vec[i]        = '0;
    end
    max_01       = EXP_NEG_INF;
    max_23       = EXP_NEG_INF;
    max_exp      = EXP_NEG_INF;
    sgn_cnt      = 3'd0;
    reduced_mant = '0;
    all_zero     = 1'b1;
    lru_out      = '0;

    // =====================================================================
    // PHASE B: Max Exponent (Step 6) — zero/NaN lanes excluded（未改动）
    // =====================================================================
    for (int i = 0; i < NUM_LANES; i++)
      eff_expP[i] = (lane_is_zero[i] || lane_is_nan[i]) ? EXP_NEG_INF : lane_expP[i];

    max_01  = (eff_expP[0] >= eff_expP[1]) ? eff_expP[0] : eff_expP[1];
    max_23  = (eff_expP[2] >= eff_expP[3]) ? eff_expP[2] : eff_expP[3];
    max_exp = (max_01 >= max_23) ? max_01 : max_23;

    all_zero = lane_is_zero[0] & lane_is_zero[1]
             & lane_is_zero[2] & lane_is_zero[3];

    // =====================================================================
    // PHASE C: Alignment + Sticky + Sign + Reduction (Steps 7–11)
    // =====================================================================
    // active 判定 —— 与改前两个 if 条件逐字对应
    unique case (mode)
      MODE_FP4, MODE_MXFP4:
        for (int i = 0; i < NUM_LANES; i++) active[i] = !lane_is_zero[i];
      MODE_FP8, MODE_MXFP8:
        for (int i = 0; i < 2; i++) active[i] = !lane_is_zero[i] && !lane_is_nan[i];
      default: ;
    endcase

    // -------------------------------------------------------------------
    //   🔴 两条【实测否决】的同型想法（负结果留痕，勿重复付费）：
    //     E6「把 active 门控从输出侧搬到输入侧」（mant_g = active ? mant : 0）：
    //        直觉是"把 mux 移到路径起点"，实测 84 -> 88 级、延迟比 17.53% -> 9.69%。
    //        原因推断：输出侧门控本来被 ABC 与既有的 mode case mux 合并了，
    //        显式插入输入侧 mux 反而是净增逻辑。
    //     E7「按 ge8/ge12 把桶形移位器从 6 级窄到 3-4 级」：那两个 mux 的选择信号
    //        派生自 shift_dist（= max 树之后的晚到信号），mux 落在移位器【之后】
    //        ⇒ 净 84 -> 90 级。
    //     教训：手工判断"mux 放哪一侧更便宜"过不了 ABC；同型改动一律先 A/B 实测。
    //     证据 = aichip_run_logs/c6e_depthgate_20260730r{2,3}.txt。
    // -------------------------------------------------------------------
    // Step 7 (E3): 6 位减法；饱和索引供 E1 的后缀 OR 选择
    for (int i = 0; i < NUM_LANES; i++) begin
      if (active[i]) begin
        shift_dist[i] = max_exp[5:0] - lane_expP[i][5:0];
        sat8_idx[i]   = (shift_dist[i] >= 6'd8)  ? 4'd8  : 4'(shift_dist[i][3:0]);
        sat12_idx[i]  = (shift_dist[i] >= 6'd12) ? 4'd12 : 4'(shift_dist[i][3:0]);
      end
    end

    // Step 8 (E1): sticky = 后缀 OR 选择；对齐移位；sticky → bit[0]
    unique case (mode)
      MODE_FP4, MODE_MXFP4: begin
        for (int i = 0; i < NUM_LANES; i++) begin
          if (active[i]) begin
            sticky[i]  = so8[i][sat8_idx[i]];
            algn[i]    = FP8_EXT_W'(mant_ext[i][FP4_EXT_W-1:0] >> shift_dist[i]);
            algn[i][0] = sticky[i];
          end
        end
      end
      MODE_FP8, MODE_MXFP8: begin
        for (int i = 0; i < 2; i++) begin
          if (active[i]) begin
            sticky[i]  = so12[i][sat12_idx[i]];
            algn[i]    = mant_ext[i] >> shift_dist[i];
            algn[i][0] = sticky[i];
          end
        end
      end
      default: ;
    endcase

    // Step 9 (E2): 取反 + 符号计数（+1 折进下面的加法树）
    for (int i = 0; i < NUM_LANES; i++) begin
      sgn[i] = lane_sign[i] & active[i];
      if (active[i])
        vec[i] = sgn[i] ? ~RESULT_W'({3'b0, algn[i]}) : RESULT_W'({3'b0, algn[i]});
    end

    sgn_cnt = 3'(sgn[0]) + 3'(sgn[1]) + 3'(sgn[2]) + 3'(sgn[3]);

    // Step 10+11: Reduction + output packaging (C07 source rebias verbatim)
    reduced_mant = signed'(vec[0]) + signed'(vec[1])
                 + signed'(vec[2]) + signed'(vec[3])
                 + signed'(RESULT_W'({12'b0, sgn_cnt}));

    lru_out.mant = reduced_mant[RESULT_W-1:0];
    lru_out.exp  = max_exp
                 - ((mode == MODE_FP4 || mode == MODE_MXFP4) ? 10'(FP4_MANT_F) :
                    (mode == MODE_FP8 || mode == MODE_MXFP8) ? 10'(FP8_MANT_F) : 10'sd0);
    lru_out.zero = all_zero;

    // v4.1 (P7): flag AGGREGATION from the seam flag bits — single source
    // (the producers live in mac_lru_front; review F7-valid single-source
    // clause: back never re-derives from raw operand bits).
    lru_out.is_nan  = lane_is_nan[0] | lane_is_nan[1]
                    | lane_is_nan[2] | lane_is_nan[3];
    lru_out.is_inf  = !lru_out.is_nan
                    & (lane_is_inf[0] | lane_is_inf[1]
                    |  lane_is_inf[2] | lane_is_inf[3]);
    lru_out.inf_sign = (lane_is_inf[0] ? lane_sign[0] :
                        lane_is_inf[1] ? lane_sign[1] :
                        lane_is_inf[2] ? lane_sign[2] :
                                         lane_sign[3])
                     & lru_out.is_inf;
  end

endmodule

// ----------------------------------------------------------------------------
// [C6-b] WRAPPER — original ports verbatim, pure-wire seam (bit-identical
// single-cycle behavior for direct unit TBs and legacy consumers)
// ----------------------------------------------------------------------------
module mac_lru
  import tensor_pkg::*;
#(
  parameter int NUM_LANES  = 4,
  parameter int G          = tensor_pkg::GUARD_BITS
) (
  input  tensor_mode_e mode,
  input  logic [3:0]  fp4_a [NUM_LANES],
  input  logic [3:0]  fp4_b [NUM_LANES],
  input  logic [7:0]  fp8_a [2],
  input  logic [7:0]  fp8_b [2],
  output lru_result_t lru_out,
  output logic [3:0]  lane_zero
);

  logic              w_sign [NUM_LANES];
  logic signed [9:0] w_expP [NUM_LANES];
  logic              w_zero [NUM_LANES];
  logic              w_nan  [NUM_LANES];
  logic              w_inf  [NUM_LANES];
  logic [11:0]       w_mant [NUM_LANES];

  mac_lru_front #(.NUM_LANES(NUM_LANES), .G(G)) u_front (
    .mode         (mode),
    .fp4_a        (fp4_a),
    .fp4_b        (fp4_b),
    .fp8_a        (fp8_a),
    .fp8_b        (fp8_b),
    .lane_sign    (w_sign),
    .lane_expP    (w_expP),
    .lane_is_zero (w_zero),
    .lane_is_nan  (w_nan),
    .lane_is_inf  (w_inf),
    .mant_ext     (w_mant),
    .lane_zero    (lane_zero)
  );

  mac_lru_back #(.NUM_LANES(NUM_LANES), .G(G)) u_back (
    .mode         (mode),
    .lane_sign    (w_sign),
    .lane_expP    (w_expP),
    .lane_is_zero (w_zero),
    .lane_is_nan  (w_nan),
    .lane_is_inf  (w_inf),
    .mant_ext     (w_mant),
    .lru_out      (lru_out)
  );

endmodule

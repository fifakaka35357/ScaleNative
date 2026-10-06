// ============================================================================
// Tensor Package v4.3 (Round E1 / R1) — Type Definitions for Tensor Unit
// ============================================================================
//
// Previously named upe_pkg. Renamed to tensor_pkg as part of the Round E
// naming cleanup — "UPE" was ambiguous between the single MAC cell and the
// wider Tensor Unit tile. The new convention is:
//
//   tensor_*   → types/constants scoped to the Tensor Unit as a whole
//                (tile_descriptor_t, tensor_mode_e, tensor_native_capsule_t, ...)
//   mac_*      → types/constants scoped to a single MAC cell (none yet; the
//                MAC-level modules use shared tensor_pkg types directly)
//
// See: Vector_Unit_OFU_Sidecar_Design_Plan.md (Phase E1 deliverable)
//      Tensor_Unit_Design_Rationale.md D23–D26 (rationale for this cleanup)
//
// ----------------------------------------------------------------------------
// Round E1 / R1 changes (this file):
// ----------------------------------------------------------------------------
//
//   RENAMES
//     upe_pkg      → tensor_pkg
//     upe_mode_e   → tensor_mode_e
//     ofu_fmt_e    → out_fmt_e       (narrowed from 3-bit to 2-bit)
//     ofu_round_e  → out_round_e
//     OFU_FMT_*    → OUT_FMT_*
//     OFU_ROUND_*  → OUT_ROUND_*
//
//   NEW TYPES
//     exec_class_e              — 2b: who completes the semantic
//     out_class_e               — 2b: where the result goes (Class A/B/C)
//     tensor_native_capsule_t   — 64b: PE-native architectural storage format
//
//   UPDATED TYPE
//     tile_descriptor_t         — 37b → 39b → **41b**（[3a-3] 加 n_cfg 2b）
//       removed: forward_eligible (subsumed by out_class)
//       renamed: ofu_fmt → out_fmt (3b → 2b), ofu_round_mode → ofu_round
//       added:   exec_class (2b), out_class (2b)
//
//   NEW HELPERS
//     mode_is_mx(tensor_mode_e)          — MX mode detection
//     is_valid_descriptor(tile_descriptor_t) — descriptor legality check
//
//   PRESERVED (unchanged)
//     exec_sparse_mode_e, fp8_fmt_e   [3a-2: sparse_mode_e / sparse_group_e 已除名]
//     lru_result_t, fp_product_t, fp_acc_output_t, zero_detect_result_t
//     All MODE_*, EXEC_* constants   [3a-2: SMODE_* / SP_GROUP_* 已除名]
//     All localparams (ACC_WIDTH_DEFAULT, ACC_INTERNAL_W, MX_BLOCK_SIZE, etc.)
//     mode_full_lane_mask(), dense_pack_advance()   [3a-2: sparse_expected_k_advance() 已除名]
//
// ----------------------------------------------------------------------------
// Prior version history (inherited from upe_pkg):
// ----------------------------------------------------------------------------
//
//   v4.2c (Round D): tile_descriptor_t first-class type, MX_BLOCK_SIZE param
//   v4.2  (Round 1): sparse execution types, exec_sparse_mode_e, tile_ctrl phase
//   v4.1  (Round 2): FP8 variant parameterization, ACC_INTERNAL_W=49,
//                    NaN/Inf flags in interface structs
//
// Follows lowRISC/IBEX naming conventions:
//   - _e suffix for enum types
//   - _t suffix for typedef structs
//   - import tensor_pkg::*; at module scope
//
// Author: H-Tensor Project
// Version: 4.3 (Round E1 / R1 — tensor_pkg migration)
// ============================================================================

package tensor_pkg;

  // ==========================================================================
  // Compute Mode Enumeration (was upe_mode_e)
  // ==========================================================================
  //
  // Tile-wide precision mode. Applies uniformly to all 256 MAC cells in a
  // given tile. The tile controller latches this from tile_descriptor_t.mode
  // at ST_IDLE and it remains constant for the entire tile lifetime.
  typedef enum logic [3:0] {
    MODE_UINT4_SIMD = 4'd0,   // 4× UINT4 dot-product: K-dim 4-element pack, sum to single acc
    MODE_UINT8      = 4'd1,   // 1× UINT8 MAC (fracturable adder tree)
    MODE_FP4        = 4'd2,   // FP4 E2M1, 4× via LRU → FP accumulator
    MODE_FP8        = 4'd3,   // FP8 (variant per FP8_FMT), 2× via LRU → FP accumulator
    MODE_BF16       = 4'd4,   // BF16, 1× via fracturable tree → FP accumulator
    MODE_MXFP4      = 4'd5,   // MXFP4: FP4 elements + block scale → LRU → FP acc
    MODE_MXFP8      = 4'd6,   // MXFP8: FP8 elements + block scale → LRU → FP acc
    MODE_MXINT8     = 4'd7    // MXINT8: INT8 (2's comp) + block scale → FP acc
  } tensor_mode_e;

  // ==========================================================================
  // [3a-2 2026-08-03] Sparsity Compression Mode Enumeration —— 已除名
  // ==========================================================================
  //   sparse_mode_e + SMODE_ADAPTIVE / SMODE_2_4 / SMODE_4_8 / SMODE_BYPASS
  // 宿主 SCU 已随 [C1 2026-07-31] D-SPARSE-NM 删除（恒等变换死硅）；本枚举自那时起
  // 全仓零引用。🔴 勿与下方**仍活着**的 exec_sparse_mode_e 混淆 —— 后者是 3a-1 新守卫
  // 的唯一观测量，且是 tile_descriptor_t 的字段。（文本陷阱：grep sparse_mode_e 会
  // 同时命中 exec_sparse_mode_e，因为后者含前者子串。）

  // ==========================================================================
  // FP8 Variant Selection
  // ==========================================================================
  //
  // Determines the FP8 element format used by MODE_FP8 and MODE_MXFP8.
  // E4M3FN: 4-bit exp, 3-bit mant, bias=7. No Inf. NaN = {exp=1111,frac=111}.
  // E5M2:   5-bit exp, 2-bit mant, bias=15. Inf = {exp=11111,frac=00}.
  //
  // SCOPE BOUNDARY:
  //   E5M2 is architecturally reserved but NOT supported in current RTL.
  //   All FP8 data paths assume E4M3FN bit-field layout.
  //   Compile-time $fatal guard in mac_lru.sv enforces this.
  typedef enum logic [1:0] {
    FP8_E4M3FN = 2'd0,   // Default: OCP MX / NVIDIA H100 primary format
    FP8_E5M2   = 2'd1    // IEEE 754 compliant, wider dynamic range (RESERVED)
  } fp8_fmt_e;

  localparam fp8_fmt_e FP8_FMT = FP8_E4M3FN;  // ★ Change here to switch variant

  // --- FP8 Derived Constants (auto-select based on FP8_FMT) ---
  localparam int FP8_EXP_W   = (FP8_FMT == FP8_E4M3FN) ? 4  : 5;
  localparam int FP8_MANT_W  = (FP8_FMT == FP8_E4M3FN) ? 3  : 2;
  localparam bit FP8_HAS_INF = (FP8_FMT == FP8_E4M3FN) ? 1'b0 : 1'b1;
  localparam logic [7:0] FP8_EXP_ALL_ONES = (FP8_FMT == FP8_E4M3FN)
                                            ? 8'b0000_1111   // 4-bit exp all 1s
                                            : 8'b0001_1111;  // 5-bit exp all 1s

  // ==========================================================================
  // Floating-Point Bias Constants
  // ==========================================================================
  localparam int FP4_BIAS  = 1;                                    // FP4 E2M1
  localparam int FP8_BIAS  = (FP8_FMT == FP8_E4M3FN) ? 7 : 15;   // FP8 (variant)
  localparam int BF16_BIAS = 127;                                  // BF16 E8M7

  // E8M0 block-scale bias (OCP MX): a scale byte s encodes 2^(s-127).
  // An MX MAC combines TWO E8M0 scales (activation + weight), so the offset
  // folded into the product exponent subtracts the bias TWICE (C06 fix):
  //   mx_offset_base = scale_a + scale_b - MX_E8M0_DOUBLE_BIAS
  localparam int MX_E8M0_BIAS        = 127;       // single E8M0 bias
  localparam int MX_E8M0_DOUBLE_BIAS = 2 * 127;   // 254: two E8M0 scales summed

  // ==========================================================================
  // C07 — Frozen Block-Float Scaling Convention
  // ==========================================================================
  //
  // Every block-float value in this datapath (lru_result_t, fp_product_t,
  // fp_acc_output_t, tensor_native_capsule_t) obeys ONE convention:
  //
  //     value = (signed mantissa) * 2^exp        with the mantissa an INTEGER.
  //
  // Each product source emits a mantissa that is packed with extra fractional
  // bits F (from the {1,frac}×{1,frac} significand product and its bit
  // placement). To honor the convention, each source SUBTRACTS its F from the
  // emitted exponent so the integer-mantissa interpretation is exact:
  //
  //     FP4 / MXFP4 : {1,f1}×{1,f1}=×2^2, packed into [7:4]=×2^4   → F = 6
  //     FP8 / MXFP8 : {1,f3}×{1,f3}=×2^6, packed into [11:4]=×2^4  → F = 10
  //     BF16        : {1,m7}×{1,m7}                                → F = 14
  //     MXINT8      : integer product                              → F = 0
  //
  // The Output Format Unit consumes the accumulator's 48-bit integer mantissa
  // (leading 1 at bit ACC_MANT_MSB-lzc) and reconstructs the IEEE unbiased
  // exponent as exp + (ACC_MANT_MSB - lzc). The source rebias (mac_lru,
  // mac_cell) and the OFU formula are a SINGLE coordinated contract — changing
  // one without the other corrupts every Class-C escape result.
  localparam int FP4_MANT_F   = 6;    // FP4 product mantissa fractional bits
  localparam int FP8_MANT_F   = 10;   // FP8 product mantissa fractional bits
  localparam int BF16_MANT_F  = 14;   // BF16 product mantissa fractional bits
  localparam int BF16_DOUBLE_BIAS = 2 * BF16_BIAS;  // 254: two BF16 exponent biases
  localparam int ACC_MANT_MSB = 47;   // OFU normalization reference (mant is [47:0])

  // ==========================================================================
  // E1 — Block-Scale Format (OCP MX E8M0 vs NVFP4 E4M3)
  // ==========================================================================
  //
  // The 8-bit per-block scale sideband (mx_scale_a/b_cur) can carry two formats:
  //
  //   SCALE_E8M0 (OCP MX): pure 8-bit exponent, bias 127. value = 2^(s-127).
  //                        Folded entirely into the product exponent (mx_offset).
  //
  //   SCALE_E4M3 (NVFP4):  FP8-like {sign,exp[3:0],mant[2:0]}, bias 7. The scale
  //                        has a MANTISSA, so it cannot be a pure exponent add:
  //                        value = (1 + m3/8) * 2^(exp-7)  (normal scales only).
  //                        E1 decomposes it at the MAC cell — exponent → mx_offset,
  //                        significand product → a correction multiplied into the
  //                        LRU product mantissa (renormalized to fit, sticky-
  //                        preserved), keeping the accumulator critical path clean.
  //
  // E1 assumes NORMAL E4M3 block scales (exp != 0), matching the vec_scale_adapter
  // v2 convention (mant_corr = {1'b1, mant[2:0], ...}); subnormal block scales are
  // out of scope (a scale near 2^-9 is pathological).
  typedef enum logic [0:0] {
    SCALE_E8M0 = 1'd0,   // OCP MX  : E8M0 pure-exponent block scale (default)
    SCALE_E4M3 = 1'd1    // NVFP4   : E4M3 block scale (exp + significand)
  } scale_fmt_e;

  localparam int E4M3_SCALE_BIAS = 7;   // E4M3 exponent bias
  // Combined E4M3 exponent offset folded into mx_offset for a two-scale MAC:
  //   (exp_a - 7) + (exp_b - 7) - 6
  // The trailing -6 normalizes the significand product sig4_a*sig4_b, where each
  // sig4 = {1,m3} (∈[8,15]) carries x2^3 over the true 1.m3 significand.
  localparam int E4M3_DOUBLE_OFFSET = 2 * E4M3_SCALE_BIAS + 6;  // 20

  // ==========================================================================
  // Global Design Parameters
  // ==========================================================================
  localparam int ACC_WIDTH_DEFAULT = 48;  // Block-float accumulator OUTPUT width
  localparam int ACC_INTERNAL_W    = 49;  // Internal accumulator width (+1 for abs safety)
  localparam int GUARD_BITS        = 3;   // Guard bits for LRU alignment precision

  // MX Block Size Parameterization
  //
  // Controls the element grouping boundary for MX scale updates.
  // OCP MX v1.0 specifies 32-element blocks as the standard grouping.
  //
  // Current RTL constraint: MX_BLOCK_SIZE must be a power of 2.
  // MX_BLOCK_LOG2 is derived automatically for shift-based boundary detection.
  //
  // Paper strategy:
  //   - Baseline: MX_BLOCK_SIZE = 32 (OCP MX v1.0 standard)
  //   - Sensitivity point: MX_BLOCK_SIZE = 16 (higher metadata overhead)
  //
  // Runtime per-tile selection requires future descriptor extension.
  localparam int MX_BLOCK_SIZE = 32;                          // ★ Change here for block-size sweep
  localparam int MX_BLOCK_LOG2 = $clog2(MX_BLOCK_SIZE);      // 5 for 32, 4 for 16

  // MXINT8 implicit scale (OCP MX v1.0, Table 6):
  //   INT8 elements have implicit 2^-6 scaling. Two elements multiplied
  //   produce a 2^-12 factor that must be folded into prod_exp.
  localparam int MXINT8_IMPLICIT_EXP = -12;  // 2 × (-6)

  // ==========================================================================
  // Structured Interface Types
  // ==========================================================================

  // --- LRU Output Bundle ---
  // Produced by mac_lru, consumed by mac_fp_accumulator.
  typedef struct packed {
    logic [14:0] mant;      // Reduced mantissa (two's complement signed, 15-bit)
    logic [9:0]  exp;       // Shared exponent = maxE (two's complement signed, 10-bit)
    logic        zero;      // All active lanes zero → skip accumulation
    logic        is_nan;    // Any lane input is NaN (or NaN-producing, e.g. Inf×0)
    logic        is_inf;    // Any lane input is Inf (and no NaN)
    logic        inf_sign;  // Inf sign (valid only when is_inf=1): XOR of operand signs
  } lru_result_t;           // Total: 29 bits

  // --- FP Product Bundle (BF16 / MXINT8 direct path) ---
  // Produced by mac_cell Section 8, consumed by FP accumulator.
  typedef struct packed {
    logic [15:0] mant;      // Product mantissa (two's complement signed, 16-bit)
    logic [9:0]  exp;       // Product exponent (two's complement signed, 10-bit)
    logic        zero;      // Product is zero
    logic        is_nan;    // Product is NaN (input NaN or Inf×0)
    logic        is_inf;    // Product is Inf (and not NaN)
    logic        inf_sign;  // Inf sign (valid only when is_inf=1)
  } fp_product_t;           // Total: 30 bits

  // --- FP Accumulator Output Bundle ---
  // Produced by mac_fp_accumulator. This is the INTERNAL implementation type
  // for block-float accumulator state. It is NOT the same as the architectural
  // storage format (tensor_native_capsule_t) — they happen to have the same
  // fields in Round E1, but they are conceptually distinct contracts.
  //
  //   mant   is [47:0] from internal 49-bit abs (bit[48] asserted = 0).
  //
  //   When is_nan=1: mant/exp are stale (last finite value), sign undefined.
  //   When is_inf=1: mant/exp are stale, sign = Inf sign.
  //   Downstream OFU (or native_store packer) interprets these flags.
  typedef struct packed {
    logic [47:0] mant;      // |mantissa| (absolute value, unsigned)
    logic [9:0]  exp;       // Accumulator exponent (two's complement signed)
    logic        sign;      // Sign bit (1=negative); carries Inf sign when is_inf
    logic        is_nan;    // Accumulator locked to NaN state
    logic        is_inf;    // Accumulator locked to Inf state (valid only if !is_nan)
  } fp_acc_output_t;        // Total: 61 bits

  // --- Zero Detection Result Bundle ---
  // Produced by mac_zero_detect, consumed by mac_cell top-level.
  typedef struct packed {
    logic [3:0]  mul_zero;          // Per-multiplier/lane zero flags
    logic [3:0]  mul_gate;          // Per-multiplier gating signals
    logic        all_zero;          // All multipliers/lanes zero
    logic        skip_accumulation; // Entire MAC operation should be skipped
    logic        fp_input_zero;     // FP input-level zero (exponent == 0)
  } zero_detect_result_t;           // Total: 11 bits

  // ==========================================================================
  // Output Format / Rounding Enumerations
  // ==========================================================================
  //
  // R1 RENAME: ofu_fmt_e → out_fmt_e, narrowed from 3 bit to 2 bit.
  // R1 RENAME: ofu_round_e → out_round_e.
  //
  // These enums describe the target format for results leaving the
  // block-float domain (Class C: Escape-Formatted). In Round E1 they are NOT
  // consumed by any module inside the Tensor Unit — the OFU has been moved
  // to the Vector Unit sidecar (see design plan). They ARE still defined here
  // because:
  //   1. tile_descriptor_t carries out_fmt as routing metadata
  //   2. output_format_unit.sv (future Vector sidecar) still consumes them
  //   3. Testbench golden models reference them
  typedef enum logic [1:0] {
    OUT_FMT_BF16 = 2'd0,    // BF16 E8M7  (16-bit)
    OUT_FMT_FP16 = 2'd1,    // FP16 E5M10 (16-bit, IEEE 754)
    OUT_FMT_FP8  = 2'd2,    // FP8 (variant per FP8_FMT param)
    OUT_FMT_FP32 = 2'd3     // FP32 E8M23 (32-bit, IEEE 754)
  } out_fmt_e;

  // Rounding mode
  typedef enum logic [0:0] {
    OUT_ROUND_RTZ = 1'd0,   // Round-toward-zero (truncate) — default
    OUT_ROUND_RNE = 1'd1    // Round-to-nearest-even (IEEE 754 default)
  } out_round_e;

  // Output format parameters reference table (informational):
  //
  //   | Format | Total | Sign | Exp | Mant | Bias | Max biased exp |
  //   |--------|-------|------|-----|------|------|----------------|
  //   | BF16   |  16   |  1   |  8  |   7  | 127  |     254        |
  //   | FP16   |  16   |  1   |  5  |  10  |  15  |      30        |
  //   | FP8 E4M3FN | 8 |  1   |  4  |   3  |   7  |      14        |
  //   | FP8 E5M2   | 8 |  1   |  5  |   2  |  15  |      30        |
  //   | FP32   |  32   |  1   |  8  |  23  | 127  |     254        |

  // ==========================================================================
  // 2:4 Structured Sparsity Constants
  // ==========================================================================
  //
  // Retained for SCU adaptive mode and backward compatibility. PE-internal
  // 2:4 activation selection has been REMOVED. Structured sparse element
  // selection is now performed by the Vector Unit prior to fragment
  // formation; the Tensor Unit receives native-format fragments identical
  // to dense fragments.
  // [3a-2 2026-08-03] localparam int SPARSE_META_W = 4 已除名（全仓唯一出现处就是它自己）

  // ==========================================================================
  // Sparse Execution Mode (Tensor-Unit-level)
  // ==========================================================================
  //
  // Controls how the tile controller and MAC cells interpret each compute
  // cycle. （[3a-2] 原「勿与 sparse_mode_e 混淆」一句随该枚举除名而删。）
  //
  // EXEC_DENSE:         Normal dense K-step. Fragment comes from SRAM/weight reg.
  // EXEC_SPARSE_STRUCT: ~~Fragment comes from Vector Unit via fast path.
  //                     K-step is driven by desc.dense_k_advance instead of
  //                     fixed pack_factor. The fragment is already selected
  //                     by Vector — Tensor does NOT do candidate selection.~~
  //   🔴 [3a-2 2026-08-03] **整段推翻**（规格 §4.1「K 令牌通路退役」+ HANDOFF §5.1）：
  //     Vector 不再递送 fragment，desc.dense_k_advance 所属的 tensor_sparse_desc_t
  //     已在本片除名。~~**本编码当前语义 = 保留值**：3a-1 起任何 EXEC_SPARSE_STRUCT~~
  //     ~~请求都会被 tensor_mac_array 的 [3a-1] 守卫 $fatal 拦下（白名单 inside {EXEC_DENSE}）。~~
  //     真实语义由 3a-3 的 n_cfg 描述符链重新定义。
  //   ▲**[3a-4/M2 2026-08-06 订正]（原文划掉保留）**：`EXEC_SPARSE_STRUCT` **已不再被拦下** ——
  //     `tensor_mac_array` 的白名单臂本片放宽为 `inside {EXEC_DENSE, EXEC_SPARSE_STRUCT}`
  //     ⇒ 该编码在仿真里**可达**（阵列内零数据通路消费者 ⇒ 与 dense 逐位同构）。
  //     🔴 **可达 ≠ 已验证**：pad 算术归 M4、`{4,0}` 相位与 k_step 归 M6′、
  //     真 N:M 数值 oracle 归 3c R5（本片到 3c 之间稀疏数值是**显式登记的真空**）。
  //     仍被该臂拦下的只剩**保留编码** `EXEC_DENSE_RESERVED`/`EXEC_SPARSE_RESERVED`；
  //     另有 WS × 非 dense 的仿真绊线（同模块 C1-b）。~~真拒收仍归 3a-7/3a-8。~~
  //     ▲**[3a-7/P5 2026-08-06 订正]：前半已落地，后半仍未落。**
  //     · **保留编码的拒收 = 已落地**（3a-7/P5）：`tensor_external_modules.sv` 的
  //       `assign desc_push_valid = start_pulse && !desc_reject;` 让它们在 **MMIO 写入时**
  //       就被丢弃、不入队，`0x1C bit[2]` 留痕（判决 `s3a7_p5_gate_verdict_20260806.txt`）。
  //     · **3a-8 的临时闸仍未落**：「`n_cfg != NCFG_DENSE` 即拒」（触发集 {01,10,11}，
  //       蓝图项 8 逐字「3b/3c 落地后拆闸」）—— 它与上面那条**寿命相反**，
  //       🔴 **禁并进同一个谓词**（D-SPARSE-3A7-SCOPE-2026-08-05）。
  //     🔴 **同批登记的代价**：P5 之后 C1 白名单臂对**非法**描述符结构性不可达
  //       （门把它们拦在队列外）⇒ 本臂现役红样本只剩「**合法但不支持**」那一类。
  typedef enum logic [1:0] {
    EXEC_DENSE          = 2'b00,  // Normal dense K-step
    EXEC_SPARSE_STRUCT  = 2'b01,  // Vector-prepared structured sparse fragment
    EXEC_DENSE_RESERVED = 2'b10,
    EXEC_SPARSE_RESERVED = 2'b11
  } exec_sparse_mode_e;

  // ==========================================================================
  // [3a-3 2026-08-04] ncfg_e —— per-tile 结构化稀疏配置 N:M（M=4）
  // ==========================================================================
  //
  // 唯一权威的 n_cfg↔N 映射。规格订正框 §5.1a（用户 2026-08-04 批准）。
  // 传输链：word[5][17:16] -> cp_scheduler 切片 -> tens_cmd_t.n_cfg
  //         -> tensor_cmd_mmio_seq (MMIO 0x08 [3:2]) -> tensor_cmd_decoder
  //         -> tile_descriptor_t.n_cfg -> tensor_desc_queue -> tile controller
  //
  // 编码读法：n_cfg = N[1:0]（N 的低两位）。dense 的 N=4 低两位恰是 2'b00，
  //           而 2'b00 正是 reg_n_cfg 复位值与 tile_desc_q <= '0 的落点
  //           ⇒ R1_Baseline_Criteria §4.6 的一票否决硬前提「不写 0x08 也走 dense」成立。
  //
  // 🔴 NCFG_DENSE 必须是 2'b00，不可改。改它当天 8 个 r1_dense case 全破。
  // 🔴 NCFG_RESERVED = 2'b11 解码为 N=3，不在批准集 {4,2,1} 内。
  //    本片（3a-3）**不实现拒收** —— 写入时拒收归 3a-7（is_valid_descriptor 保留值）
  //    ~~与 3a-8（CP poison / cp_desc_fetch 的 wi==4 分支，今天该分支不存在）~~。
  //    3a-3 落的是 tensor_tile_controller 断言区的 $fatal 级仿真绊线，不是硬闸。
  //
  //  ▲订正（2026-08-05，3a-7 开工前对抗审查裁决 §1.3，四对一；规格 §5.1a 已同批加框）：
  //    划掉那半句把两件【触发集不同、寿命相反】的守卫并成了一条。正确拆分 =
  //      · `is_valid_descriptor` 保留值拒 + cp_desc_fetch 的 `wi==4` **编码拒**
  //        触发集 {2'b11}，**永久**条款，🔴 **不随 3a-8 的临时闸拆除** ⇒ 归 **3a-7**；
  //      · CP poison **临时硬闸**：触发集 {2'b01,2'b10,2'b11}（即 n_cfg≠0），
  //        蓝图项 8 逐字「3b/3c 落地后拆闸」⇒ 归 **3a-8**。
  //    按原文执行的后果是结构性的：3b/3c 拆临时闸那天会把永久的 2'b11 拒**一起拆掉**，
  //    硅上恢复静默（后果本身已登记在规格 §5.2 的残留静默点一段）。
  //    全案 = aichip_run_logs/s3a7_workface_adversarial_verdict_20260805.md §1.3。
  // 🔴 已知代价：本编码在 2 bit 内不向 M=8 延伸（N=8 与 N=4 的低两位撞码）。
  //    ~~可改窗口 = 3a-5 之前（此后 16 象限相位与压实行数都消费该数值）。~~
  //    ▲**[3a-4/M2 2026-08-06 订正]（原文划掉保留）：该句已被规格 §5.1a-bis 逐字作废。**
  //      两条理由：① **M=8 的拦路者不是码位分配**，是元数据宽度（16 列 × 2b = 32b
  //      装不下 3b/列）与 2b×392 旁带 —— 全是导线和 mux，重编码补不上；
  //      ② 窗口判断方向错了：`ncfg_survivors()` 是 SV 侧唯一 N 来源（用户 08-04 拍板的
  //      纪律），只要每个消费者都过它，改编码**永远**只是「改一个函数 + 重跑稀疏金标」。
  //      真正让编码变贵的是离线 `nm_pack` 的数据格式、固件、以及 RTL 交付合作方那一刻。
  //      🔴 规格 §5.1a-bis 是本议题的**权威表述**，**别再重开讨论**。
  typedef enum logic [1:0] {
    NCFG_DENSE    = 2'b00,  // N=4：dense（M=4 全存活）。R1 基线全落此格
    NCFG_1OF4     = 2'b01,  // N=1：1:4，权重流 {4,0} 气泡节拍（规格 §4.3）
    NCFG_2OF4     = 2'b10,  // N=2：2:4，k_step=2/拍（规格 §3）
    NCFG_RESERVED = 2'b11   // N=3：不在批准集 {4,2,1}；处置归 3a-7/3a-8
  } ncfg_e;

  // n_cfg -> 每 M=4 窗口的存活元素数 N。
  //
  // 🔴 这是 SV 侧【唯一】的 N 取值来源（用户 2026-08-04 拍板）。凡需要 N 数值的
  //    SV 代码一律调本函数，禁 open-code —— 规格 §6.2 的 mod-N 计数器要在 16 象限
  //    克隆、§6.3 的三镜像要同改，散落的 open-code 是 PROJECT_RULES §5.0d 型 15 的温床。
  //    与 dense_pack_advance() 同范式同文件，便于一处对照。
  // 🔴 诚实限定：Python 侧另立一处（nm_pack 全仓无实体；发行拍数校验在
  //    tb/test_tensor_gemm_egress.py 的 python 里，SV function 调不到）⇒ 两处必须互相指名。
  // NCFG_RESERVED 返回 3：它不是合法配置，返回值只用于让越界/合法性检查看到一个
  //    确定的数（禁把它当"可执行的 3:4"用）。
  function automatic logic [2:0] ncfg_survivors(input ncfg_e n);
    return (n == NCFG_DENSE) ? 3'd4 : {1'b0, n};
  endfunction

  // ==========================================================================
  // [3a-2 2026-08-03] Sparse Group Kind / Tensor Sparse Descriptor /
  //                   Sparse Fragment Bundle —— 三型连体除名
  // ==========================================================================
  //   sparse_group_e + SP_GROUP_1OF2/2OF4/4OF8/RSV  (2b)
  //   tensor_sparse_desc_t                          (25b)
  //   sparse_tensor_frag_t                          (73b)
  //
  // 三者构成一条传递封闭的依赖链 sparse_group_e → tensor_sparse_desc_t →
  // sparse_tensor_frag_t，**必须整体一起删**：实测只删 sparse_group_e 会立刻
  // `%Error: Can't find typedef/interface: 'sparse_group_e'`。
  // 🔴 中间节点 tensor_sparse_desc_t 不在施工清单点名的六个对象里，是本片实测补出的。
  //
  // 除名依据：它们描述的 Vector→Tensor fragment 快通路已随规格 §4.1「K 令牌通路退役」
  // 在 3a-1 全部拆除（队列文件删除 = S2，controller 端口 = S3，外部端口 = S4）；
  // sparse_tensor_frag_t 的最后一个 RTL 引用者在 S4 消失。

  // ==========================================================================
  // Lane Mask Constants
  // ==========================================================================
  //
  // Default per-lane active masks when no tail truncation applies.
  //
  //   LANE_MASK_4: FP4/MXFP4/UINT4 — all 4 LRU lanes active
  //   LANE_MASK_2: FP8/MXFP8       — 2 LRU lanes active, lanes 2-3 inactive
  //   LANE_MASK_1: BF16/UINT8/MXINT8 — 1 fracturable multiply, lane 0 only
  localparam logic [3:0] LANE_MASK_4 = 4'b1111;  // 4-lane modes
  localparam logic [3:0] LANE_MASK_2 = 4'b0011;  // 2-lane modes
  localparam logic [3:0] LANE_MASK_1 = 4'b0001;  // 1-element modes

  // ==========================================================================
  // ============================================================
  //   ROUND E1 / R1 NEW TYPES: exec_class / out_class / capsule
  // ============================================================
  // ==========================================================================

  // ==========================================================================
  // Execution Class Enumeration (NEW in R1)
  // ==========================================================================
  //
  // Describes "who completes the semantic" for a tile result. This is the
  // first of a three-field orthogonal routing specification:
  //
  //    exec_class  → who completes the semantic
  //    out_class   → where the result goes (class, not specific format)
  //    out_fmt     → specific FP format (valid only for OUT_ESCAPE_FMT)
  //
  // Combined with out_class and out_fmt, this describes the complete result
  // routing contract for a tile. See Vector_Unit_OFU_Sidecar_Design_Plan.md
  // §3 for the full rationale.
  //
  // Values:
  //   EXEC_NONE:            Result bypasses Vector entirely. Either stored in
  //                         SRAM native region (Class B) or forwarded as
  //                         block-float to next consumer (Class A).
  //
  //   EXEC_FORMAT_ONLY:     Result only needs terminal format conversion via
  //                         OFU sidecar. No Vector main compute. Implies
  //                         Class C. Used for "tensor-only escape" workloads.
  //
  //   EXEC_VECTOR_COMPUTE:  Result requires Vector main compute (norm,
  //                         residual, reduce, etc). After Vector main, the
  //                         result may or may not go through OFU sidecar
  //                         depending on out_class.
  typedef enum logic [1:0] {
    EXEC_NONE           = 2'b00,
    EXEC_FORMAT_ONLY    = 2'b01,
    EXEC_VECTOR_COMPUTE = 2'b10,
    EXEC_CLASS_RESERVED = 2'b11
  } exec_class_e;

  // ==========================================================================
  // Output Class Enumeration (NEW in R1)
  // ==========================================================================
  //
  // Describes "where the result goes" — the result flow class. This is the
  // second of the three orthogonal routing fields. The three non-reserved
  // values correspond to the three paper-level result flow classes:
  //
  //   OUT_FWD_VEC_NATIVE: Class A (Forward-Native)
  //     Result is forwarded to Vector Unit as block-float fragment.
  //     NO OFU involvement. The downstream Vector may consume it as-is
  //     (EXEC_VECTOR_COMPUTE input) or just pass it further.
  //     Typical use: chained compute, residual forward, scale-aware pipeline.
  //
  //   OUT_STORE_NATIVE: Class B (Store-Native)
  //     Result is stored to SRAM native region as tensor_native_capsule_t.
  //     NO OFU involvement. NO Vector involvement required.
  //     Handled by tensor_native_store_unit directly (converter-free store).
  //     Typical use: KV cache, inter-layer resident state, MoE expert cache.
  //
  //   OUT_ESCAPE_FMT: Class C (Escape-Formatted)
  //     Result is converted to a standard FP format (out_fmt) via OFU
  //     sidecar, then written to SRAM formatted region or sent to external
  //     interface. This is the ONLY class that crosses the block-float /
  //     format boundary.
  //     Typical use: final layer output, host writeback, debug snapshot.
  //
  // KEY CLAIM:
  //   Only Class C (OUT_ESCAPE_FMT) involves the OFU. Class A and Class B
  //   are fully converter-free. This is the structural invariant that
  //   backs the paper's "scale-native converter-free dataflow" thesis.
  typedef enum logic [1:0] {
    OUT_FWD_VEC_NATIVE  = 2'b00,   // Class A: forward to Vector as block-float
    OUT_STORE_NATIVE    = 2'b01,   // Class B: store to SRAM native region
    OUT_ESCAPE_FMT      = 2'b10,   // Class C: via OFU sidecar → formatted output
    OUT_CLASS_RESERVED  = 2'b11
  } out_class_e;

  // ==========================================================================
  // Tile Descriptor Type (UPDATED in R1: 37b → 39b)
  // ==========================================================================
  //
  // Complete descriptor for a single tile GEMM operation. Used by
  // tensor_desc_queue (buffered tile commands) and tensor_cmd_decoder
  // (MMIO decode output). Captures all parameters needed to fully configure
  // a tile execution without additional CPU interaction.
  //
  // R1 Changes:
  //   REMOVED: forward_eligible (1b)     — subsumed by out_class
  //   RENAMED: ofu_fmt (3b) → out_fmt (2b) [narrowed, uses new out_fmt_e]
  //   RENAMED: ofu_round_mode → ofu_round [uses renamed out_round_e]
  //   ADDED:   exec_class (2b)            — who completes the semantic
  //   ADDED:   out_class  (2b)            — where the result goes (class)
  //
  //   Field count: 37 bit → 39 bit (net +2 bit)
  //
  // [3a-3 2026-08-04] ADDED: n_cfg (2b, ncfg_e) —— per-tile N:M 配置，MMIO 0x08 [3:2]。
  //   **39 bit → 41 bit（净加 2 位，不是替换）**。sparse_compress_en 原样保留
  //   （D-SCU-RESERVED 打死位；删它 R1 破）。三处位宽注释已同步：本行 / 结构体尾
  //   / 本文件顶部 :35 的类型索引 / tensor_external_modules.sv 的 desc_queue 头注。
  //
  // Routing field interaction rules (enforced by is_valid_descriptor()):
  //
  //   Legal combinations:
  //     EXEC_NONE           + OUT_FWD_VEC_NATIVE + (out_fmt: ignored)
  //     EXEC_NONE           + OUT_STORE_NATIVE   + (out_fmt: ignored)
  //     EXEC_FORMAT_ONLY    + OUT_ESCAPE_FMT     + (out_fmt: any valid)
  //     EXEC_VECTOR_COMPUTE + OUT_FWD_VEC_NATIVE + (out_fmt: ignored)
  //     EXEC_VECTOR_COMPUTE + OUT_STORE_NATIVE   + (out_fmt: ignored)
  //     EXEC_VECTOR_COMPUTE + OUT_ESCAPE_FMT     + (out_fmt: any valid)
  //
  //   Illegal combinations (~~rejected by cmd_decoder assertion~~ —— 见下方 is_valid_descriptor
  //   头注的 [3a-2] 订正框：**cmd_decoder 实际不调用它，无任何拒收**)：
  //     EXEC_NONE           + OUT_ESCAPE_FMT        (no OFU to produce format)
  //     EXEC_FORMAT_ONLY    + OUT_FWD_VEC_NATIVE    (degenerate: format path for native output)
  //     EXEC_FORMAT_ONLY    + OUT_STORE_NATIVE      (degenerate: same as above)
  //
  // SRAM base addresses are NOT included here — they are managed by
  // tensor_operand_fetch and tensor_scale_buffer, which receive them from
  // the command processor alongside (but separate from) this descriptor.
  typedef struct packed {
    tensor_mode_e       mode;               // 4b: Precision mode
    logic [15:0]        k_total;            // 16b: K dimension (dense element count)
    exec_sparse_mode_e  sparse_mode;        // 2b: Dense or structured sparse
    ncfg_e              n_cfg;              // 2b: [3a-3] per-tile N:M 配置（M=4），MMIO 0x08 [3:2]
    logic               dataflow_sel;       // 1b: 0=OS, 1=WS
    exec_class_e        exec_class;         // 2b: who completes the semantic (NEW)
    out_class_e         out_class;          // 2b: where the result goes (NEW)
    out_fmt_e           out_fmt;            // 2b: FP format (valid iff OUT_ESCAPE_FMT)
    out_round_e         ofu_round;          // 1b: Rounding mode (RTZ/RNE)
    logic [7:0]         epoch;              // 8b: Epoch tag for descriptor alignment
    logic               sparse_compress_en; // 1b: SCU adaptive zero-skip enable
  } tile_descriptor_t;                      // Total: 41 bits  [3a-3: 39 -> 41, 净加 2 位]

  // ==========================================================================
  // Tensor Native Storage Capsule (NEW in R1)
  // ==========================================================================
  //
  // Architectural storage format for block-scaled results in the SRAM native
  // region. This is a CONTRACT type — it defines the on-SRAM layout that
  // both the Tensor Unit and future Vector Unit / CPU loaders will honor.
  //
  // IMPORTANT: this is NOT the same as fp_acc_output_t. The latter is an
  //            IMPLEMENTATION type describing the internal block-float
  //            accumulator state. The capsule is an ARCHITECTURAL type
  //            describing the storage contract. They happen to have the
  //            same mantissa/exponent/flag fields in Round E1, but they
  //            are conceptually distinct:
  //              - fp_acc_output_t may change when accumulator internals evolve
  //              - tensor_native_capsule_t is a stable storage contract
  //
  // Phase E1 layout (64 bit total):
  //   [63:16]  mant      — 48-bit absolute mantissa
  //   [15:6]   exp       — 10-bit signed exponent
  //   [5]      sign      — 1-bit sign
  //   [4]      is_nan    — 1-bit NaN flag
  //   [3]      is_inf    — 1-bit Inf flag
  //   [2:0]    reserved  — 3-bit future extension:
  //              [2] block_size hint
  //              [1] context_id hint
  //              [0] epoch hint
  //
  // In Phase E1, reserved = 3'b000 (unused). Phase E4 PE integration will
  // decide how to populate these fields based on the PE memory subsystem
  // architecture decisions.
  //
  // See: Paper §6.1 for the architectural rationale behind treating
  //      storage format as first-class contract.
  typedef struct packed {
    logic [47:0] mant;      // 48b: |mantissa| absolute value
    logic [9:0]  exp;       // 10b: signed exponent
    logic        sign;      // 1b:  sign bit
    logic        is_nan;    // 1b:  NaN flag
    logic        is_inf;    // 1b:  Inf flag
    logic [2:0]  reserved;  // 3b:  future extension (see comment above)
  } tensor_native_capsule_t;  // Total: 64 bits

  // ==========================================================================
  // Helper Functions
  // ==========================================================================
  //
  // Pure functions for use in RTL combinational logic and assertions.
  // Deliberately simple — no state, no side effects.

  // --- Compute mode → full lane mask (all lanes active, no tail) ---
  //
  // Returns the default lane mask for a given compute mode.
  // In non-tail cycles, active_tail_mask = mode_full_lane_mask(mode).
  // In the last K cycle with partial elements, the controller overrides
  // specific bits to zero based on K % pack_factor.
  function automatic logic [3:0] mode_full_lane_mask(tensor_mode_e m);
    unique case (m)
      MODE_FP4, MODE_MXFP4, MODE_UINT4_SIMD: return LANE_MASK_4;
      MODE_FP8, MODE_MXFP8:                   return LANE_MASK_2;
      default:                                 return LANE_MASK_1;
    endcase
  endfunction

  // --- Compute mode → dense K-advance per cycle (pack_factor) ---
  //
  // Returns the number of K-dimension elements consumed per MAC per cycle
  // in dense mode. ~~In sparse mode, the actual advance is given by the
  // fragment descriptor's dense_k_advance field instead.~~
  //   [3a-2] 后半句作废：fragment descriptor 已除名。3a-1 起稀疏臂逐字等于 dense 臂，
  //   确定性稀疏 K 步长由 3a-5 落成 controller 内部纯函数。
  function automatic logic [7:0] dense_pack_advance(tensor_mode_e m);
    unique case (m)
      MODE_FP4, MODE_MXFP4, MODE_UINT4_SIMD: return 8'd4;
      MODE_FP8, MODE_MXFP8:                   return 8'd2;
      default:                                 return 8'd1;
    endcase
  endfunction

  // --- [3a-2 2026-08-03] sparse_expected_k_advance() 已除名 ---
  //   它的唯一调用点是 controller 的 SPARSE K ADVANCE SVA（$warning 级），
  //   已随 3a-1 S3 删除。旧语义（稀疏每拍覆盖 2× dense pack_factor）建立在
  //   「Vector 递送 fragment、K 步长由 desc 给出」之上，该前提已不成立 ——
  //   N:M 下 K 步长是 controller 内部纯函数。3a-5 若需要新的期望值函数，
  //   应按 per-tile 常数 N 重新推导，**不要复活本函数**。

  // --- MX mode detection (NEW in R1) ---
  //
  // Returns 1 if the given compute mode uses MX block scale sideband.
  // Centralizes a check that was previously inlined in tile_controller
  // and mac_array as (m == MXFP4) || (m == MXFP8) || (m == MXINT8).
  function automatic logic mode_is_mx(tensor_mode_e m);
    return (m == MODE_MXFP4) || (m == MODE_MXFP8) || (m == MODE_MXINT8);
  endfunction

  // --- Descriptor legality check (NEW in R1) ---
  //
  // Returns 1 if the combination of exec_class / out_class / out_fmt is
  // architecturally legal. Returns 0 for the illegal combinations:
  //
  //   1. EXEC_NONE + OUT_ESCAPE_FMT
  //      (no execution path produces the format)
  //
  //   2. EXEC_FORMAT_ONLY + OUT_FWD_VEC_NATIVE
  //      (degenerate: format path with native output is contradictory)
  //
  //   3. EXEC_FORMAT_ONLY + OUT_STORE_NATIVE
  //      (degenerate: equivalent to EXEC_NONE + OUT_STORE_NATIVE)
  //
  //   4. Any reserved enum value
  //
  // Note: This function does NOT check out_fmt when out_class != OUT_ESCAPE_FMT,
  //       because out_fmt is don't-care in that case.
  //
  // ~~Used by tensor_cmd_decoder to reject illegal descriptors at MMIO write time.~~
  //
  // 🔴🔴 [3a-2 2026-08-03] **本句是假声明，且是 `PROJECT_RULES §5.0d` 型 15
  //   （跨模块 fail-open：两边都以为对方把关）的实例。** 实测：
  //     grep -n 'is_valid_descriptor' Tensor/tensor_external_modules.sv  → 零命中
  //     tensor_cmd_decoder 的推送是无条件的：assign desc_push_valid = start_pulse;
  //     0x08 / 0x0C 写口全是裸类型转换（exec_sparse_mode_e'(...) 等），无任何合法性校验。
  //   本函数的真实消费者只有两条 $error 级 SVA（tensor_tile_controller.sv 与
  //   tensor_unit_top.sv 各一），即**只在仿真里事后告警，不在 MMIO 写入时拒收**。
  //   同族假声明另有三处（本文件上方 Illegal combinations 一句、
  //   tensor_external_modules.sv 的「R8: illegal descriptor combination assertion」
  //   悬空注释、tensor_unit_top.sv 的「cmd_decoder is expected to reject…」），
  //   已同批就地订正。
  //   ⇒ **真正的拒收实现归 3a-7**（is_valid_descriptor 补 sparse_mode 保留值拒
  //     + WS×sparse + 可观测 sticky）。在那之前不得声称「非法描述符会被拒收」。
  //
  // ▲进度回填（2026-08-05，3a-7/P3）—— 🔴 **本框的定性尚未失效，别提前改口**：
  //   P3 已落**三条判据臂**（sparse_mode 保留值 / n_cfg 保留值 / WS×非dense，见函数体内）。
  //   但 **`assign desc_push_valid = start_pulse;` 一个字都没改** ⇒ 非法描述符**照样入队**，
  //   本函数的消费者仍然只有两条 translate_off 内的 SVA。
  //   🔴 **「加了 arm」≠「会拒收」** —— 此刻把本框改写成「已拒收」就是
  //      `PROJECT_RULES §5.0d` **型 15 的第 3 次实付**（本片 R0 审查 major M15 点名预警过）。
  //   本框的改写条件 = **3a-7/P5 把本函数接到 `desc_push_valid` 上并跑出红绿**，
  //   届时改写为「已由 3a-7/P5 落地，实现点 = tensor_external_modules.sv 的 desc_push_valid 门」。
  //   P3 这一刻唯一变化的是：R5-6 由 `$error` 升为 `$fatal`（仿真告警的响度，不是拒收）。
  //
  // ══════════════════════════════════════════════════════════════════════════
  // ▲▲ **[3a-7/P5 2026-08-06] 本框的型 15 定性【正式失效】** —— 上面预登记的改写条件
  //    已满足（P5 接门 **且** 跑出红绿），本段是那条条件的兑现记录。
  //
  //   **实现点** = `tensor_external_modules.sv` 的
  //       `assign desc_push_valid = start_pulse && !desc_reject;`
  //       其中 `desc_reject = start_pulse && !is_valid_descriptor(desc_out);`（**纯组合**）
  //   ⇒ 本函数返回 0 的描述符**在 MMIO 写入时就被丢弃、不入队**，
  //     并由 `0x1C bit[2]`（3a-7/P4）留下**可读回的 sticky 痕迹**
  //     ⇒ 规格 §5.4「丢 start + sticky 位可读回，**禁静默丢**」两半同时成立。
  //
  //   **红绿证据（盘上，非转述）**：
  //     · `s3a7_p5_probes_verdict_20260806.txt` = `P5-PROBES-VERDICT=PASS`
  //       五个非法发（保留 exec ×2 / 保留 n_cfg / WS×稀疏 / 保留 out_class）start 全被丢、
  //       `bit[2]` 全 1；两个合法发照样跑完、`bit[2]`=0（**谓词没写宽**）。
  //     · `s3a7_p5_redarms_rejudge_verdict_20260806.txt` = `P5-REDARMS-REJUDGE-VERDICT=PASS`
  //       拆门 / 架空谓词两条 mutation 都让 R5-6 重新响 `illegal descriptor`
  //       ⇒ **拦住它们的是【谓词】，不是【门的存在】**。
  //     · 全闸 `s3a7_p5_gate_verdict_20260806.txt` = `VERDICT=PASS`，其中
  //       `R1-CADENCE-DRIFT=0`（门是纯组合、零新增拍的机器证明）与 `R1-CSR-DRIFT=0`。
  //
  //   🔴 **同批必须带走的三条限定（别只记住"已拒收"三个字）**：
  //   ① **层级**：只许写「**MMIO 拒在 TB 层可观测**」。**禁写「固件可读回」** ——
  //      `tensor_domain_top.sv:242` 读地址硬接 `8'd0`、`:306` 读数据进 `_unused`、
  //      `:244` `counter_clear` tie 0 ⇒ 集成层及以上**无读通路**。
  //   ② 🔴 **上游遮蔽的极端形态**：门把非法描述符拦在队列外 ⇒ **队列之后的每一条断言
  //      对非法描述符全部结构性不可达** —— R5-6 / unit_top G2 / mac_array 的 C1 白名单臂 /
  //      WS-GUARD **现在全部零红样本**。只有 `tensor_tile_controller` 的 `[3a-3]` 白名单臂
  //      仍可达（它拒的是「**合法但本实现不支持**」，门放行）。
  //      ⇒ **本函数的正确性此后只由 MMIO 层探针守**，而那两个探针带 `scratch_` 前缀、
  //      **三闸对它们结构性全盲** —— 改本函数的人**必须手动重跑它们**。
  //      （补法已决：3a-8 的**第一批**给收口发射脚本加「闸5 = 拒收探针」，见 D-P6-1。）
  //   ③ **队列满仍是静默丢**：`desc_push_ready` 是 decoder 的 input 但**全文无消费者**
  //      ⇒ 队列满时 start 丢失且 `bit[2]` **不置位**（它只反映「非法」不反映「满」）。
  //      当前深度下全仓无用例能填满 ⇒ 零覆盖，非 3a-7 工作面，已登记。
  // ══════════════════════════════════════════════════════════════════════════
  function automatic logic is_valid_descriptor(tile_descriptor_t d);
    // Reserved enum values
    if (d.exec_class == EXEC_CLASS_RESERVED) return 1'b0;
    if (d.out_class  == OUT_CLASS_RESERVED)  return 1'b0;

    // Illegal combination 1: EXEC_NONE cannot produce formatted output
    if (d.exec_class == EXEC_NONE && d.out_class == OUT_ESCAPE_FMT)
      return 1'b0;

    // Degenerate combinations 2 and 3: EXEC_FORMAT_ONLY with native output
    if (d.exec_class == EXEC_FORMAT_ONLY &&
        (d.out_class == OUT_FWD_VEC_NATIVE || d.out_class == OUT_STORE_NATIVE))
      return 1'b0;

    // ======================================================================
    // [3a-7/P3 2026-08-05] 三条新臂（规格 §5.4；预登记 s3a7_prereg_20260805.md §8.1）
    //
    // ~~🔴 措辞纪律：本函数在 P3 这一刻仍然只是判据；非法描述符照样入队；禁称「已拒收」。~~
    //    ▲**[3a-7/P5 2026-08-06 订正]：上面这条【已解除】。**
    //    本函数已被接到 `desc_push_valid` 上（`tensor_external_modules.sv` 的
    //    `assign desc_push_valid = start_pulse && !desc_reject;`，纯组合）
    //    ⇒ 返回 0 的描述符**在 MMIO 写入时就被丢弃、不入队**。
    //    🔴 **消费者结构因此翻面**：R5-6 / G2 现在对非法描述符**结构性不可达**
    //    （门把它们拦在队列外了）⇒ 本函数的红绿证据**只能来自 MMIO 层探针**
    //    （`tb/scratch_guard_probe.py` 五发的 `GP-CSR bit2=1` + `tb/scratch_sticky_probe.py`）。
    //    改本函数的人**必须重跑那两个探针** —— 三闸对它们结构性全盲（`scratch_` 前缀）。
    //
    // 🔴 恰三条，不多：规格 §5.2 的「矛盾组合按 n_cfg=11 同路径拒」**不在本片实现**
    //    （裁决 D2 / blocker B6）—— 落它会让 tb/scratch_guard_probe.py 的 P3 发
    //    （0x08=0x04 ⇒ exec=EXEC_DENSE ∧ n_cfg=NCFG_1OF4，两个字段**都不是保留值**）
    //    由红转绿 ⇒ P5 mutation 锚退化为恒真 ⇒ 3a-3 的 B6「n_cfg 链是通的、不是恒 0
    //    死链」**唯一的正向证明当场蒸发**，而本片给不出代偿。责任片待定（候选 3a-8/3c），
    //    落地当天须同批给出不依赖 P3/P5 的替代正向证明。规格 §5.2 已加订正框。
    // ======================================================================

    // 臂 A：sparse_mode 保留值（批准集只有 {EXEC_DENSE, EXEC_SPARSE_STRUCT}）
    if (d.sparse_mode == EXEC_DENSE_RESERVED ||
        d.sparse_mode == EXEC_SPARSE_RESERVED)
      return 1'b0;

    // 臂 B：n_cfg 保留值。2'b11 解码为 N=3，不在批准集 {4,2,1} 内 ——
    //   不拒则 ncfg_survivors() 返 3，压实行数与相位全错，**硅上静默**（规格 §5.2）。
    if (d.n_cfg == NCFG_RESERVED)
      return 1'b0;

    // 臂 C：WS × 非 dense。
    // 🔴 **必须是析取式，不是单字段**（3a-7/R0 审查 major M7）：规格 §5.4 只写
    //   「(dataflow_sel && sparse) → 0」，而 sparse 到底指哪个字段是空的；实测
    //   `sparse_mode` 与 `n_cfg` 是 tensor_cmd_decoder 里**两条互不校验的裸锁存**
    //   （0x08 的 [1:0] 与 [3:2] 各自赋值）⇒ 只绑一个字段就留洞：
    //   直写 0x08=0x04 得到 (exec=EXEC_DENSE, n_cfg=NCFG_1OF4)，绑 sparse_mode 的写法放它过。
    // 机理（为什么 WS×非dense 非法）：tensor_operand_fetch 的两条 zero_pad 都带
    //   `dataflow_sel == 1'b0` 门（OS-only）⇒ WS 下 pad 拍不被强零、垃圾权重真的进阵列，
    //   而且**算得出看起来合理的结果**（tensor_mac_array 的 WS-GUARD 头注同款陈述）。
    if (d.dataflow_sel && ((d.sparse_mode != EXEC_DENSE) ||
                           (d.n_cfg       != NCFG_DENSE)))
      return 1'b0;

    return 1'b1;
  endfunction

endpackage

// ============================================================================
// tb_fp_acc_ovf.sv — [C2 anchor ①, 2026-07-25] parameter-shrunk overflow
// harness for mac_fp_accumulator.
//
// WHY ACC_W=20: at the production ACC_W=48 the overflow branch
// (mac_fp_accumulator.sv:138, |sum_mant| crossing bit 46) needs ~2^31 valid
// cycles to reach (alignment only ever shifts RIGHT; max |prod_mant| = 2^15),
// i.e. it is unreachable in ANY simulatable stimulus — which is exactly why
// it has been verified-blind dead code (M2M3_AnchorPlan §A1: mutating
// next_exp=align_exp+1 → +2 leaves the whole suite green). Shrinking ACC_W
// to 20 (INTERNAL_W=21, overflow at |sum| >= 2^18) makes the SAME RTL branch
// reachable in 16 cycles. ACC_W propagates cleanly (accumulator :65/:113/:145;
// align sign-extends operands into ACC_W; fp_acc_out zero-fills its u48 field).
// ============================================================================
module tb_fp_acc_ovf
    import tensor_pkg::*;
(
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        valid_in,
    input  logic [3:0]  mode,
    input  logic [28:0] lru_in,
    input  logic [29:0] bf16_prod_in,
    output logic [60:0] fp_acc_out
);
    mac_fp_accumulator #(
        .ACC_W ( 20 )
    ) u_acc (
        .clk          ( clk                          ),
        .rst_n        ( rst_n                        ),
        .clear        ( clear                        ),
        .valid_in     ( valid_in                     ),
        .mode         ( tensor_mode_e'(mode)         ),
        .lru_in       ( lru_result_t'(lru_in)        ),
        .bf16_prod_in ( fp_product_t'(bf16_prod_in)  ),
        .fp_acc_out   ( fp_acc_out                   )
    );
endmodule

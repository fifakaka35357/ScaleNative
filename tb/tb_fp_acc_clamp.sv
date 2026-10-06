// ============================================================================
// tb_fp_acc_clamp.sv — [GR-A 2026-07-28] SHIFT_MAX-shrunk clamp harness for
// mac_fp_accumulator (review B2-F4/B3-4 reachability resolution).
//
// WHY SHIFT_MAX=4: the val_raw clamp-arm contract ('0, not a bare >>>) only
// becomes value-visible when |shifter_in| >= 2^shift_amt with shift_amt >
// SHIFT_MAX. At the production SHIFT_MAX=40 that needs |mant| >= 2^41 —
// unreachable in ANY simulatable stimulus (same argument as the ACC_W=20
// overflow harness, tb_fp_acc_ovf.sv). Shrinking SHIFT_MAX to 4 makes the
// SAME RTL clamp arm value-visible with |mant| = 128 in two pushes.
// ACC_W stays 48 (production width). δ mutant (clamp arm as bare shift)
// gives 4 where the contract gives 2 — see test_fp_acc_clamp.py.
// ============================================================================
module tb_fp_acc_clamp
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
        .ACC_W     ( 48 ),
        .SHIFT_MAX ( 4  )
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

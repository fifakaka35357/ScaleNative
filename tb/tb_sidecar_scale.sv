// ============================================================================
// tb_sidecar_scale.sv — [HW-REVIEW T3-FF/FF3a] leaf wrapper for the scale-sidecar
// decode primitive pe_pkg::sidecar_scale_k. Pure-combinational: drive a fetched
// 256b sidecar row + an in-row lane (k mod 16), observe the extracted signed-16b
// per-block absolute exponent. Pins the multi-block-streaming scale wire format.
// ============================================================================
module tb_sidecar_scale
    import pe_pkg::*;
(
    input  logic [HALF_STRIPE_W-1:0] row_i,    // a fetched 256b sidecar row (16 exps)
    input  logic [3:0]               lane_i,   // k mod 16
    output logic signed [15:0]       exp_o     // extracted signed block exponent
);
    assign exp_o = sidecar_scale_k(row_i, lane_i);
endmodule

// Trivial DUT shell for test_rv32_asm_xcheck — that test compares two assemblers
// against each other and needs no hardware, but cocotb requires a toplevel.
module tb_asm_host (
    input logic clk_i,
    input logic rst_ni
);
    logic unused;
    always_comb unused = clk_i & rst_ni;
endmodule

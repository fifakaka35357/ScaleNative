// =============================================================================
// l1_subsystem.sv — L1 Memory Subsystem Wrapper (PE v4)
//
// Instantiates:
//   l1i_mem — 1×2KB, boot write (Port 0) + IBEX fetch (Port 1)
//   l1d_mem — 2×2KB word-interleaved, IBEX data (Port 0) + CP 64b read (Port 1)
//
// This module is a thin structural wrapper presenting clean interfaces
// to pe_top. No logic besides instantiation and wiring.
// =============================================================================

module l1_subsystem
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        soft_reset_i,   // 波1: L1D CP-pipe flush (from cp_soft_reset)

    // =========================================================================
    // L1I: Boot Interface (write program before fetch_enable)
    // =========================================================================
    input  logic        boot_req_i,
    input  logic        boot_we_i,
    input  logic [31:0] boot_addr_i,
    input  logic [31:0] boot_wdata_i,
    input  logic [3:0]  boot_be_i,

    // =========================================================================
    // L1I: IBEX Instruction Fetch (OBI slave)
    // =========================================================================
    input  logic        instr_req_i,
    output logic        instr_gnt_o,
    output logic        instr_rvalid_o,
    input  logic [31:0] instr_addr_i,
    output logic [31:0] instr_rdata_o,
    output logic        instr_err_o,

    // =========================================================================
    // L1D: IBEX Data Access (OBI slave, Port 0 RW, 32b)
    // =========================================================================
    input  logic        cpu_req_i,
    output logic        cpu_gnt_o,
    output logic        cpu_rvalid_o,
    input  logic [11:0] cpu_addr_i,      // byte address within 4KB
    input  logic        cpu_we_i,
    input  logic [3:0]  cpu_be_i,
    input  logic [31:0] cpu_wdata_i,
    output logic [31:0] cpu_rdata_o,
    output logic        cpu_err_o,

    // =========================================================================
    // L1D: CP Descriptor Fetch (Port 1 R, 64b parallel)
    // =========================================================================
    input  logic                    cp_req_i,
    input  logic [L1D_BANK_AW-1:0] cp_addr_i,     // word address (same for both banks)
    output logic [63:0]             cp_rdata_o,     // {bank1.dout1, bank0.dout1}
    output logic                    cp_rvalid_o
);

    // =========================================================================
    // L1I Instance
    // =========================================================================
    l1i_mem i_l1i (
        .clk_i,
        .rst_ni,

        // Boot
        .boot_req_i,
        .boot_we_i,
        .boot_addr_i,
        .boot_wdata_i,
        .boot_be_i,

        // IBEX fetch
        .fetch_req_i    ( instr_req_i    ),
        .fetch_gnt_o    ( instr_gnt_o    ),
        .fetch_rvalid_o ( instr_rvalid_o ),
        .fetch_addr_i   ( instr_addr_i   ),
        .fetch_rdata_o  ( instr_rdata_o  ),
        .fetch_err_o    ( instr_err_o    )
    );

    // =========================================================================
    // L1D Instance
    // =========================================================================
    l1d_mem i_l1d (
        .clk_i,
        .rst_ni,
        .soft_reset_i,

        // IBEX data (Port 0)
        .cpu_req_i,
        .cpu_gnt_o,
        .cpu_rvalid_o,
        .cpu_addr_i,
        .cpu_we_i,
        .cpu_be_i,
        .cpu_wdata_i,
        .cpu_rdata_o,
        .cpu_err_o,

        // CP descriptor fetch (Port 1)
        .cp_req_i,
        .cp_addr_i,
        .cp_rdata_o,
        .cp_rvalid_o
    );

endmodule

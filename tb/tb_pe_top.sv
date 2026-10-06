// =============================================================================
// tb_pe_top.sv — the REAL SoC bench: IBEX boots firmware and drives the chip.
//
// Until now nothing instantiated pe_top. Seven files had ZERO simulation
// coverage — pe_top.sv itself, addr_decoder, l1_subsystem/l1i_mem/l1d_mem,
// pe_ibex_wrapper, tech_icg_wrapper — and the pre-tapeout audit found a
// chip-killer (the DMA 2D FILL deadlock) in exactly that blind spot.
//
// This bench closes it the only way that really counts: it loads real machine
// code into L1I through the boot port, releases fetch, and lets the IBEX run the
// chip the way silicon will be run — MMIO writes to the CP, descriptors in L1D,
// doorbell, poll for completion. The only things the testbench touches are the
// pins a real board would touch: boot, fetch_enable, and the NoC.
//
// Observability contract (a deliberate consequence of the architecture):
//   * L2 is NOT in the IBEX address space (pe_pkg.sv:219) and L1D port 1 is
//     read-only, so there is NO L2 -> CPU path. Firmware can therefore only read
//     STATUS, never results.
//   * Results leave the chip the way they will on silicon: DMA EVICT -> NoC
//     egress. The bench captures that stream and checks it.
//   * "The program got there" is proven by data appearing on the NoC, not by
//     poking at internal state.
//
// Run: cd tb && make MODULE=test_pe_top TOPLEVEL=tb_pe_top VERILOG_SOURCES="..."
//      (see test_pe_top.py — the source list is long: ibex + all of IBEX_SRAM +
//       Tensor + Vector.)
// =============================================================================
module tb_pe_top
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Boot port: the bench writes the firmware into L1I ──
    input  logic        boot_req_i,
    input  logic        boot_we_i,
    input  logic [31:0] boot_addr_i,
    input  logic [31:0] boot_wdata_i,
    input  logic [3:0]  boot_be_i,

    // ── Release the CPU ──
    input  logic        fetch_enable_i,

    // ── NoC ingress (bench feeds DMA FILL data) ──
    input  logic        noc_ing_valid_i,
    input  logic [31:0] noc_ing_data_i,
    input  logic        noc_ing_last_i,
    output logic        noc_ing_ready_o,

    // ── NoC egress (bench captures DMA EVICT results) ──
    output logic        noc_egr_valid_o,
    output logic [31:0] noc_egr_data_o,
    output logic        noc_egr_last_o,
    input  logic        noc_egr_ready_i,

    // ── Health ──
    output logic        alert_minor_o,
    output logic        alert_major_o,
    output logic        core_sleep_o
);

    pe_top #(
        .BOOT_ADDR ( 32'h0000_0000 )   // => reset PC = {BOOT_ADDR[31:8], 8'h80} = 0x80
    ) dut (
        .clk_i  ( clk_i  ),
        .rst_ni ( rst_ni ),

        .boot_req_i   ( boot_req_i   ),
        .boot_we_i    ( boot_we_i    ),
        .boot_addr_i  ( boot_addr_i  ),
        .boot_wdata_i ( boot_wdata_i ),
        .boot_be_i    ( boot_be_i    ),

        .test_en_i      ( 1'b0           ),
        .hart_id_i      ( 32'd0          ),
        .fetch_enable_i ( fetch_enable_i ),

        .irq_software_i ( 1'b0   ),
        .irq_timer_i    ( 1'b0   ),
        .irq_external_i ( 1'b0   ),
        .irq_fast_i     ( 15'd0  ),   // CP irq is OR'd into fast[0] inside the wrapper
        .irq_nm_i       ( 1'b0   ),

        .debug_req_i ( 1'b0 ),

        .alert_minor_o ( alert_minor_o ),
        .alert_major_o ( alert_major_o ),
        .core_sleep_o  ( core_sleep_o  ),

        .noc_ing_valid_i ( noc_ing_valid_i ),
        .noc_ing_data_i  ( noc_ing_data_i  ),
        .noc_ing_last_i  ( noc_ing_last_i  ),
        .noc_ing_ready_o ( noc_ing_ready_o ),

        .noc_egr_valid_o ( noc_egr_valid_o ),
        .noc_egr_data_o  ( noc_egr_data_o  ),
        .noc_egr_last_o  ( noc_egr_last_o  ),
        .noc_egr_ready_i ( noc_egr_ready_i )
    );

endmodule

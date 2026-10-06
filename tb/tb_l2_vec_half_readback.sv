// ============================================================================
// tb_l2_vec_half_readback.sv — STEP4-E2E §11 (D-E2E-BENCH P2) L2 bank-half proof.
//
// Drives the REAL l2_subsystem's Vector RW master and proves that a write with
// half_sel=1 physically lands in banks 8-15 (and half_sel=0 in banks 0-7), read
// back per-physical-bank via the dma_evict single-bank port. This is the
// load-bearing, hand-computable proof of the half_sel->bank routing through the
// real l2_rw_arbiter + behavioral bank SRAM (no Vector datapath numerics).
//
// Tie off every other master (Tensor RO/RW, Vector RO, DMA fill); a lone Vector
// write grants combinationally. dma_evict: gnt combinational, rvalid+rdata one
// cycle later (l2_rw_arbiter.sv:423-430, l2_subsystem.sv:316-323).
// ============================================================================
module tb_l2_vec_half_readback
    import pe_pkg::*;
(
    input  logic                         clk_i,
    input  logic                         rst_ni,

    // ── Vector RW master (the write under test) ──
    input  logic                         vec_rw_req_i,
    input  logic [L2_BANK_AW-1:0]        vec_rw_row_i,
    input  logic                         vec_rw_half_sel_i,
    input  logic [(L2_NUM_BANKS/2)-1:0]  vec_rw_bank_mask_i,   // 8-bit within half
    input  logic [HALF_STRIPE_W-1:0]     vec_rw_wdata_i,
    output logic                         vec_rw_gnt_o,

    // ── DMA evict (single-bank readback) ──
    input  logic                         dma_evict_req_i,
    input  logic [L2_BANK_SEL_W-1:0]     dma_evict_bank_i,
    input  logic [L2_BANK_AW-1:0]        dma_evict_row_i,
    output logic                         dma_evict_gnt_o,
    output logic                         dma_evict_rvalid_o,
    output logic [31:0]                  dma_evict_rdata_o
);

    l2_subsystem #(.NUM_BANKS(L2_NUM_BANKS), .BANK_AW(L2_BANK_AW)) i_l2 (
        .clk_i, .rst_ni,

        // Tensor RO/RW — tied off
        .tens_ro_req_i      ( 1'b0 ),
        .tens_ro_row_i      ( '0   ),
        .tens_ro_gnt_o      (      ),
        .tens_ro_rvalid_o   (      ),
        .tens_ro_rdata_o    (      ),
        .tens_rw_req_i      ( 1'b0 ),
        .tens_rw_row_i      ( '0   ),
        .tens_rw_bank_mask_i( '0   ),
        .tens_rw_wdata_i    ( '0   ),
        .tens_rw_gnt_o      (      ),

        // Vector RO — tied off (only RW is exercised)
        .vec_ro_req_i       ( 1'b0 ),
        .vec_ro_row_i       ( '0   ),
        .vec_ro_half_sel_i  ( 1'b0 ),
        .vec_ro_gnt_o       (      ),
        .vec_ro_rvalid_o    (      ),
        .vec_ro_rdata_o     (      ),

        // Vector RW — the write under test
        .vec_rw_req_i       ( vec_rw_req_i       ),
        .vec_rw_row_i       ( vec_rw_row_i       ),
        .vec_rw_half_sel_i  ( vec_rw_half_sel_i  ),
        .vec_rw_bank_mask_i ( vec_rw_bank_mask_i ),
        .vec_rw_wdata_i     ( vec_rw_wdata_i     ),
        .vec_rw_gnt_o       ( vec_rw_gnt_o       ),

        // DMA fill — tied off
        .dma_fill_req_i     ( 1'b0 ),
        .dma_fill_bank_i    ( '0   ),
        .dma_fill_row_i     ( '0   ),
        .dma_fill_wdata_i   ( '0   ),
        .dma_fill_be_i      ( '0   ),
        .dma_fill_gnt_o     (      ),

        // DMA evict — single-bank readback
        .dma_evict_req_i    ( dma_evict_req_i    ),
        .dma_evict_bank_i   ( dma_evict_bank_i   ),
        .dma_evict_row_i    ( dma_evict_row_i    ),
        .dma_evict_gnt_o    ( dma_evict_gnt_o    ),
        .dma_evict_rvalid_o ( dma_evict_rvalid_o ),
        .dma_evict_rdata_o  ( dma_evict_rdata_o  ),

        // arbiter controls — lone-master, watchdog/yield off
        .soft_reset_i       ( 1'b0 ),
        .tens_yield_mode_i  ( 2'd0 ),
        .tens_quota_n_i     ( 4'd0 ),
        .perf_cnt_en_i      ( 1'b0 ),
        .perf_l2_conflict_o (      ),
        .perf_l2_vec_stall_o(      ),
        .perf_l2_tens_stall_o(     ),
        .perf_l2_dma_stall_o(      )
    );

endmodule

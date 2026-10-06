// ============================================================================
// tb_tensor_gemm_core.sv — HW-REVIEW TIER-1: OS-GEMM core correctness harness.
//
// Drives the REAL Tensor/tensor_unit_top (MMIO + DMA, same bring-up sequence as
// tb_tensor_gemm_egress) for a single dense BF16 GEMM tile, but instead of the
// lossy E4M3-clamped egress capsule it taps the PRE-REQUANT fp_acc SNAPSHOT bank
// directly: all 256 cells' fp_acc_output_t (latched on capture_fire) are exposed
// flattened on snap_flat so cocotb can decode each C[r][c] with bfp_golden and
// compare against an exact Python GEMM golden (the real oracle, §4 of
// Review/Tensor_GEMM_Rewire_Plan.md). The egress E4M3 path is too lossy for an
// exact GEMM check, hence the snapshot tap (same hierarchical-ref technique as
// tb_cp_vec_store_e2e's vu_state_o).
//
// snap_flat layout: cell (r,c) occupies bits [(r*COLS+c)*61 +: 61] = the 61-bit
// fp_acc_output_t snapshot. Read-only hierarchical tap into u_mac_array.
// ============================================================================
module tb_tensor_gemm_core
    import tensor_pkg::*;
    import pe_pkg::*;
#(
    parameter int ROWS = 16,
    parameter int COLS = 16
)(
    input  logic         clk,
    input  logic         rst_n,

    // ── MMIO write (fire-and-forget; no ready) ──
    input  logic         mmio_wr_valid,
    input  logic [7:0]   mmio_wr_addr,
    input  logic [31:0]  mmio_wr_data,

    // ── MMIO read (status CSR) ──
    input  logic [7:0]   mmio_rd_addr,
    output logic [31:0]  mmio_rd_data,

    // ── DMA operand load (flattened 16-lane rows) ──
    input  logic         dma_wgt_en,
    input  logic         dma_act_en,
    input  logic         dma_scale_en,
    input  logic [11:0]  dma_addr,
    input  logic [255:0] dma_data,       // 16 x 16b lanes (weight or act)
    input  logic [127:0] dma_scl_wgt,    // 16 x 8b
    input  logic [127:0] dma_scl_act,    // 16 x 8b

    // ── Egress fast-path capsule (Class A) — drained but unchecked here ──
    input  logic         egress_ready,

    // ── Status ──
    output logic         tu_tile_done,
    output logic         tu_capture_done,
    output logic         tu_busy,

    // ── Pre-requant snapshot bank: 256 x fp_acc_output_t (61b), flattened ──
    output logic [ROWS*COLS*61-1:0] snap_flat
);
    // ── fan the flat DMA buses into the unpacked array ports ──
    logic [15:0] wgt_arr [16];
    logic [15:0] act_arr [16];
    logic [7:0]  scl_wgt_arr [16];
    logic [7:0]  scl_act_arr [16];
    always_comb begin
        for (int i = 0; i < 16; i++) begin
            wgt_arr[i]     = dma_data[i*16 +: 16];
            act_arr[i]     = dma_data[i*16 +: 16];
            scl_wgt_arr[i] = dma_scl_wgt[i*8 +: 8];
            scl_act_arr[i] = dma_scl_act[i*8 +: 8];
        end
    end

    // ── tensor egress capsule sink (unused — we read the snapshot bank) ──
    pe_pkg::bs_capsule_t cap_unused;

    tensor_unit_top u_tensor (
        .clk    ( clk   ),
        .rst_n  ( rst_n ),

        .mmio_wr_valid ( mmio_wr_valid ),
        .mmio_wr_addr  ( mmio_wr_addr  ),
        .mmio_wr_data  ( mmio_wr_data  ),
        .mmio_rd_addr  ( mmio_rd_addr  ),
        .mmio_rd_data  ( mmio_rd_data  ),
        .counter_clear ( 1'b0 ),

        .dma_wgt_wr_en   ( dma_wgt_en ),
        .dma_wgt_wr_addr ( dma_addr   ),
        .dma_wgt_wr_data ( wgt_arr    ),
        .dma_act_wr_en   ( dma_act_en ),
        .dma_act_wr_addr ( dma_addr   ),
        .dma_act_wr_data ( act_arr    ),
        .dma_scale_wr_en       ( dma_scale_en ),
        .dma_scale_wr_addr     ( dma_addr     ),
        .dma_scale_wr_data_wgt ( scl_wgt_arr  ),
        .dma_scale_wr_data_act ( scl_act_arr  ),

        // [3a-1 S4] sparse ingress 三条 tie 已删（端口已不存在）

        // egress capsule — drained, unchecked
        .egress_frag_capsule   ( cap_unused      ),
        .egress_frag_escape    (                 ),
        .egress_frag_valid     (                 ),
        .egress_frag_ready     ( egress_ready    ),
        .egress_frag_row_idx   (                 ),
        .egress_frag_last_row  (                 ),
        .egress_frag_out_class (                 ),
        .egress_frag_out_fmt   (                 ),
        .egress_frag_epoch     (                 ),

        // native store (Class B) — unused
        .native_wr_en   (  ),
        .native_wr_addr (  ),
        .native_wr_data (  ),

        // [P4/D-CONV-BASE] converter-based widened FP writeback — unused
        .ofu_wr_en      (  ),
        .ofu_wr_addr    (  ),
        .ofu_wr_data    (  ),
        .pmac_ofu_digest(  ),

        // status
        .tu_busy         ( tu_busy         ),
        .tu_tile_done    ( tu_tile_done    ),
        .tu_capture_done ( tu_capture_done ),
        .tu_scan_done    (  ),
        .tu_wb_done      (  )
    );

    // ── Pre-requant snapshot bank tap (read-only hierarchical refs) ──
    // pe_fp_acc_snapshot[r][c] is the per-cell fp_acc_snapshot_q (latched on
    // capture_fire). 61-bit fp_acc_output_t per cell, decoded by bfp_golden.
    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr++) begin : gen_snap_row
            for (gc = 0; gc < COLS; gc++) begin : gen_snap_col
                assign snap_flat[(gr*COLS+gc)*61 +: 61] =
                    u_tensor.u_mac_array.pe_fp_acc_snapshot[gr][gc];
            end
        end
    endgenerate
endmodule

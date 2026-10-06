// ============================================================================
// tb_tensor_gemm_egress.sv — STEP4-E2E Phase B: real Tensor GEMM egress harness.
//
// Drives the REAL Tensor/tensor_unit_top DIRECTLY (its MMIO mmio_wr_* + DMA
// dma_{wgt,act,scale}_wr_* ports) to bring up a single dense BF16 GEMM tile and
// prove it egresses block16 fast-path capsules (egress_frag_valid +
// egress_frag_capsule). The unpacked DMA-array ports and the bs_capsule_t egress
// are flattened to packed buses so cocotb can drive/observe them (same pattern
// as tb_vec_consume_e2e). NOTE: tensor_unit_top uses clk/rst_n (active-low async).
//
// One DMA "row write" carries a 256b bus = 16 lanes x 16b (or 128b = 16x8b for
// scales); the tb fans it into the dma_*_wr_data[16] arrays. The status CSR read
// port (architectural mmio_rd) is exposed for mode/perf observability. See §9.8
// for the drive spec this realizes.
// ============================================================================
module tb_tensor_gemm_egress
    import tensor_pkg::*;
    import pe_pkg::*;
(
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

    // ── Egress fast-path capsule (Class A) ──
    input  logic         egress_ready,
    output logic         egress_valid,
    output logic         egress_escape,
    output logic [255:0] egress_payload,
    output logic [2:0]   egress_scale_format,
    output logic [1:0]   egress_block_size,
    output logic [31:0]  egress_inline_scale,
    output logic [1:0]   egress_role,
    output logic [7:0]   egress_status,
    output logic [3:0]   egress_row_idx,
    output logic         egress_last_row,

    // ── Status ──
    output logic         tu_tile_done,
    output logic         tu_busy
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

    // ── egress capsule field taps ──
    bs_capsule_t cap;
    assign egress_payload      = cap.payload;
    assign egress_scale_format = cap.scale_format;
    assign egress_block_size   = cap.block_size;
    assign egress_inline_scale = cap.inline_scale;
    assign egress_role         = cap.operand_role;
    assign egress_status       = cap.status_flags;

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

        // egress capsule
        .egress_frag_capsule   ( cap             ),
        .egress_frag_escape    ( egress_escape   ),
        .egress_frag_valid     ( egress_valid    ),
        .egress_frag_ready     ( egress_ready    ),
        .egress_frag_row_idx   ( egress_row_idx  ),
        .egress_frag_last_row  ( egress_last_row ),
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
        .tu_busy         ( tu_busy      ),
        .tu_tile_done    ( tu_tile_done ),
        .tu_capture_done (  ),
        .tu_scan_done    (  ),
        .tu_wb_done      (  )
    );
endmodule

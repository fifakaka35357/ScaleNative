// ============================================================================
// tb_tensor_operand_stream.sv — STEP4-E2E (inc 3b) harness: flatten the
// L2->SRAM operand streamer's unpacked [16] DMA-data array ports into buses
// for cocotb.
// ============================================================================
module tb_tensor_operand_stream
    import pe_pkg::*;
#(
    parameter int ADDR_WIDTH = 12,
    parameter int DATA_WIDTH = 16,
    parameter int LANES      = 16
) (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     start_i,
    output logic                     busy_o,
    output logic                     load_done_o,

    input  logic [15:0]              n_wgt_i,
    input  logic [15:0]              n_act_i,
    input  logic [15:0]              n_scl_i,
    input  logic [L2_BANK_AW-1:0]    l2_wgt_base_i,
    input  logic [L2_BANK_AW-1:0]    l2_act_base_i,
    input  logic [L2_BANK_AW-1:0]    l2_scl_base_i,
    input  logic [ADDR_WIDTH-1:0]    sram_wgt_base_i,
    input  logic [ADDR_WIDTH-1:0]    sram_act_base_i,
    input  logic [ADDR_WIDTH-1:0]    sram_scl_base_i,

    output logic                     ro_req_o,
    input  logic                     ro_gnt_i,
    input  logic                     ro_rvalid_i,
    output logic [L2_BANK_AW-1:0]    ro_row_o,
    input  logic [FULL_STRIPE_W-1:0] ro_rdata_i,

    output logic                     dma_wgt_wr_en_o,
    output logic [ADDR_WIDTH-1:0]    dma_wgt_wr_addr_o,
    output logic [LANES*DATA_WIDTH-1:0] dma_wgt_wr_data_o,
    output logic                     dma_act_wr_en_o,
    output logic [ADDR_WIDTH-1:0]    dma_act_wr_addr_o,
    output logic [LANES*DATA_WIDTH-1:0] dma_act_wr_data_o,
    output logic                     dma_scale_wr_en_o,
    output logic [ADDR_WIDTH-1:0]    dma_scale_wr_addr_o,
    output logic [LANES*8-1:0]       dma_scale_wr_data_wgt_o,
    output logic [LANES*8-1:0]       dma_scale_wr_data_act_o
);
    logic [DATA_WIDTH-1:0] wgt_data [LANES];
    logic [DATA_WIDTH-1:0] act_data [LANES];
    logic [7:0]            scl_wgt  [LANES];
    logic [7:0]            scl_act  [LANES];

    tensor_operand_stream #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .LANES(LANES)) u_dut (
        .clk_i, .rst_ni, .start_i, .busy_o, .load_done_o,
        .n_wgt_i, .n_act_i, .n_scl_i,
        .l2_wgt_base_i, .l2_act_base_i, .l2_scl_base_i,
        .sram_wgt_base_i, .sram_act_base_i, .sram_scl_base_i,
        .ro_req_o, .ro_gnt_i, .ro_rvalid_i, .ro_row_o, .ro_rdata_i,
        .dma_wgt_wr_en_o, .dma_wgt_wr_addr_o, .dma_wgt_wr_data_o(wgt_data),
        .dma_act_wr_en_o, .dma_act_wr_addr_o, .dma_act_wr_data_o(act_data),
        .dma_scale_wr_en_o, .dma_scale_wr_addr_o,
        .dma_scale_wr_data_wgt_o(scl_wgt), .dma_scale_wr_data_act_o(scl_act)
    );

    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            dma_wgt_wr_data_o[i*DATA_WIDTH +: DATA_WIDTH] = wgt_data[i];
            dma_act_wr_data_o[i*DATA_WIDTH +: DATA_WIDTH] = act_data[i];
            dma_scale_wr_data_wgt_o[i*8 +: 8]             = scl_wgt[i];
            dma_scale_wr_data_act_o[i*8 +: 8]             = scl_act[i];
        end
    end
endmodule

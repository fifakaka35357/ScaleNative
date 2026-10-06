// =============================================================================
// tb_dma_2d.sv — DMA engine bench: 2D strided FILL / EVICT / MEMSET.
//
// Motivation (pre-tapeout audit, 2026-07-12): dma_engine had NO test of any kind,
// which is how a 2D FILL deadlock survived to the eve of SoC P&R:
//   ST_FILL_RUN gated ing_pop with !inner_done, but waited for (inner_done &&
//   ing_empty) before the outer advance. The NoC streams outer x len_rows x 16
//   words as ONE continuous burst, so at an inner boundary the FIFO legitimately
//   still holds words for the NEXT iteration — which can never drain. Any 2D
//   transfer (outer_count > 1) locked up forever. 1D happened to be safe, which is
//   exactly why nothing caught it.
//
// This bench models the L2 RW port (single-bank, word-interleaved) as a flat
// memory and a NoC that streams words back-to-back, then checks BOTH that the
// transfer terminates (deadlock regression) and that every word landed at the
// address the AGU promised (bank = wcount[3:0], row = base + wcount>>4, with
// base advancing by stride_rows per outer iteration).
//
// Run: cd tb && make MODULE=test_dma_2d TOPLEVEL=tb_dma_2d \
//        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/IBEX_SRAM/dma_engine.sv \
//                         ./tb_dma_2d.sv"
// =============================================================================
module tb_dma_2d
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        soft_reset_i,

    // ── Command (driven by the test) ──
    input  logic        cmd_valid_i,
    output logic        cmd_ready_o,
    input  logic [7:0]  cmd_opcode_i,      // raw encoding (OP_DMA_FILL=0x20, EVICT=0x21, MEMSET=0x22)
    input  logic [8:0]  cmd_l2_row_i,
    input  logic [15:0] cmd_len_rows_i,
    input  logic [15:0] cmd_stride_rows_i,
    input  logic [15:0] cmd_outer_count_i,
    input  logic [31:0] cmd_memset_val_i,

    // ── NoC ingress (driven by the test; free-running producer) ──
    input  logic        noc_ing_valid_i,
    input  logic [31:0] noc_ing_data_i,
    output logic        noc_ing_ready_o,

    // ── NoC egress (consumed by the test) ──
    output logic        noc_egr_valid_o,
    input  logic        noc_egr_ready_i,
    output logic [31:0] noc_egr_data_o,
    output logic        noc_egr_last_o,

    // ── Completion ──
    output logic        done_o,

    // ── L2 model observability: flat scoreboard readback ──
    input  logic [12:0] probe_idx_i,       // {row[8:0], bank[3:0]} flattened
    output logic [31:0] probe_data_o,
    output logic        probe_written_o
);

    // -------------------------------------------------------------------------
    // Command struct assembly
    // -------------------------------------------------------------------------
    dma_cmd_t cmd;
    always_comb begin
        cmd             = '0;
        cmd.opcode      = desc_opcode_e'(cmd_opcode_i);
        cmd.l2_row      = cmd_l2_row_i[L2_BANK_AW-1:0];
        cmd.len_rows    = cmd_len_rows_i;
        cmd.stride_rows = cmd_stride_rows_i;
        cmd.outer_count = cmd_outer_count_i;
        cmd.memset_val  = cmd_memset_val_i;
        cmd.contract    = default_tile_contract();
    end

    // -------------------------------------------------------------------------
    // DUT
    // -------------------------------------------------------------------------
    logic                    fill_req, fill_gnt;
    logic [L2_BANK_SEL_W-1:0] fill_bank;
    logic [L2_BANK_AW-1:0]   fill_row;
    logic [31:0]             fill_wdata;
    logic [3:0]              fill_be;

    logic                    evict_req, evict_gnt, evict_rvalid;
    logic [L2_BANK_SEL_W-1:0] evict_bank;
    logic [L2_BANK_AW-1:0]   evict_row;
    logic [31:0]             evict_rdata;

    dma_engine u_dma (
        .clk_i        ( clk_i        ),
        .rst_ni       ( rst_ni       ),
        .soft_reset_i ( soft_reset_i ),

        .cmd_valid_i  ( cmd_valid_i  ),
        .cmd_ready_o  ( cmd_ready_o  ),
        .cmd_i        ( cmd          ),

        .fill_req_o   ( fill_req     ),
        .fill_gnt_i   ( fill_gnt     ),
        .fill_bank_o  ( fill_bank    ),
        .fill_row_o   ( fill_row     ),
        .fill_wdata_o ( fill_wdata   ),
        .fill_be_o    ( fill_be      ),

        .evict_req_o    ( evict_req    ),
        .evict_gnt_i    ( evict_gnt    ),
        .evict_rvalid_i ( evict_rvalid ),
        .evict_bank_o   ( evict_bank   ),
        .evict_row_o    ( evict_row    ),
        .evict_rdata_i  ( evict_rdata  ),

        .noc_ing_valid_i ( noc_ing_valid_i ),
        .noc_ing_ready_o ( noc_ing_ready_o ),
        .noc_ing_data_i  ( noc_ing_data_i  ),
        .noc_ing_last_i  ( 1'b0            ),

        .noc_egr_valid_o ( noc_egr_valid_o ),
        .noc_egr_ready_i ( noc_egr_ready_i ),
        .noc_egr_data_o  ( noc_egr_data_o  ),
        .noc_egr_last_o  ( noc_egr_last_o  ),

        .done_o     ( done_o ),
        .done_ctx_o (        ),
        .done_tag_o (        )
    );

    // -------------------------------------------------------------------------
    // L2 model — flat {row, bank} memory, always grants.
    //
    // The DMA drives one 32b word per grant with a word-interleaved AGU:
    //   bank = wcount[3:0], row = cur_base_row + wcount[…:4]
    // We store into a flat array so the test can verify placement (which is what
    // proves the outer-loop base advance actually happened).
    // -------------------------------------------------------------------------
    localparam int MEM_ROWS = 1 << L2_BANK_AW;   // 512
    localparam int MEM_BANKS = 16;

    logic [31:0] mem      [MEM_ROWS*MEM_BANKS];
    logic        mem_wr   [MEM_ROWS*MEM_BANKS];

    // Always ready (worst case for the FIFO: it drains as fast as it fills).
    assign fill_gnt  = fill_req;
    assign evict_gnt = evict_req;

    logic [12:0] fill_idx;
    assign fill_idx = {fill_row[8:0], fill_bank};

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < MEM_ROWS*MEM_BANKS; i++) mem_wr[i] <= 1'b0;
        end else if (fill_req && fill_gnt) begin
            mem[fill_idx]    <= fill_wdata;
            mem_wr[fill_idx] <= 1'b1;
        end
    end

    // Evict read: 1-cycle latency (registered rvalid), mirrors a real SRAM.
    logic [12:0] evict_idx;
    assign evict_idx = {evict_row[8:0], evict_bank};

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            evict_rvalid <= 1'b0;
            evict_rdata  <= 32'd0;
        end else begin
            evict_rvalid <= evict_req && evict_gnt;
            evict_rdata  <= mem[evict_idx];
        end
    end

    // Scoreboard readback
    assign probe_data_o    = mem[probe_idx_i];
    assign probe_written_o = mem_wr[probe_idx_i];

    // synthesis translate_off
    initial begin
        for (int i = 0; i < MEM_ROWS*MEM_BANKS; i++) begin
            mem[i]    = 32'd0;
            mem_wr[i] = 1'b0;
        end
    end
    // synthesis translate_on

endmodule

// ============================================================================
// Tensor Unit External Interface Modules — Combined Code Review File
// ============================================================================
//
// This file contains 7 modules that connect the Tensor Unit compute core
// (upe_array_sparse + upe_tile_controller) to the rest of the PE system.
// For synthesis, split into individual files at the marked boundaries.
//
// Module index:
//   1. tensor_sram_wrapper       — Behavioral SRAM (3 banks: weight/act/scale)
//   2. tensor_cmd_decoder        — MMIO → tile descriptor decode
//   3. tensor_desc_queue         — Tile descriptor FIFO + auto-issue
//   4. tensor_status_csr         — CPU-visible status + performance counters
//   5. tensor_operand_fetch      — Descriptor-driven weight/act read
//   6. tensor_scale_buffer       — MX scale fetch + boundary alignment
//   7. tensor_native_store_unit  — Class B store (fragmentizer consumer)
//
// All modules import tensor_pkg::* and share the same clock/reset convention.
// Tensor-side interfaces match tensor_mac_array / tensor_tile_controller
// (Round E1 / R5-R8) and tensor_egress_fragmentizer (R4) port signatures.
//
// Author:  H-Tensor Project
// Version: 4.3  (Round E1 / R8 + Task A — native_store_unit refactor)
// ============================================================================


// ############################################################################
// MODULE 1: tensor_sram_wrapper
// ############################################################################
//
// Behavioral SRAM model for Tensor Unit development and verification.
// Provides array-width parallel read/write across 3 logical banks:
//   Bank 0: Weight data  (DEPTH × COLS × 16b)
//   Bank 1: Activation data (DEPTH × ROWS × 16b)
//   Bank 2: Scale metadata (DEPTH × max(COLS,ROWS) × 8b, split wgt/act)
//
// All reads have 1-cycle latency (registered output).
// Writes are single-cycle.
//
// This module will be replaced by a physical SRAM macro wrapper during
// backend implementation. The port interface is designed to be stable
// across that transition.
// ============================================================================

module tensor_sram_wrapper
  import tensor_pkg::*;
#(
  parameter int ROWS       = 16,
  parameter int COLS       = 16,
  parameter int DATA_WIDTH = 16,
  parameter int SRAM_DEPTH = 512,   // [STEP5/D-ORFS-SRAM] 4096->512 (见 tensor_unit_top + OpenROAD_Integration_Plan §11)
  parameter int ADDR_WIDTH = 12,    // 地址口宽(实际用 [8:0])
  // Memory 波1 (2026-07-22): PDK_ASAP7 real-macro axis. REAL_MACRO=1 binds the
  // real asap7_sram_0p0 srambank_128x4x64_6t122 (single-port 64b, tape-out-ready
  // with GDS) width-banked; =0 keeps the fakeram7_256x32 analytical model. No
  // effect on the behavioral sim path (which never defines PDK_ASAP7). OUT_REG /
  // ping-pong deferred to M3 (D-TENSOR-RETIME-ONCE): they re-time systolic
  // operand injection, done once with the M3 front-feed pipelining.
  parameter bit REAL_MACRO = 1'b1
) (
  input  logic               clk,
  input  logic               rst_n,

  // ---- Weight Read Port ----
  input  logic               wgt_rd_en,
  input  logic [ADDR_WIDTH-1:0] wgt_rd_addr,
  output logic [DATA_WIDTH-1:0] wgt_rd_data [COLS],
  output logic               wgt_rd_valid,

  // ---- Activation Read Port ----
  input  logic               act_rd_en,
  input  logic [ADDR_WIDTH-1:0] act_rd_addr,
  output logic [DATA_WIDTH-1:0] act_rd_data [ROWS],
  output logic               act_rd_valid,

  // ---- Scale Read Port ----
  input  logic               scale_rd_en,
  input  logic [ADDR_WIDTH-1:0] scale_rd_addr,
  output logic [7:0]         scale_rd_data_wgt [COLS],
  output logic [7:0]         scale_rd_data_act [ROWS],
  output logic               scale_rd_valid,

  // ---- Write Port (from writeback unit or DMA) ----
  input  logic               wr_en,
  input  logic [ADDR_WIDTH-1:0] wr_addr,
  input  logic [DATA_WIDTH-1:0] wr_data [COLS],

  // ---- DMA Write Port (for test data loading) ----
  input  logic               dma_wgt_wr_en,
  input  logic [ADDR_WIDTH-1:0] dma_wgt_wr_addr,
  input  logic [DATA_WIDTH-1:0] dma_wgt_wr_data [COLS],

  input  logic               dma_act_wr_en,
  input  logic [ADDR_WIDTH-1:0] dma_act_wr_addr,
  input  logic [DATA_WIDTH-1:0] dma_act_wr_data [ROWS],

  input  logic               dma_scale_wr_en,
  input  logic [ADDR_WIDTH-1:0] dma_scale_wr_addr,
  input  logic [7:0]         dma_scale_wr_data_wgt [COLS],
  input  logic [7:0]         dma_scale_wr_data_act [ROWS]
);

`ifdef PDK_SKY130
  // ===========================================================================
  // [STEP5/D3] Real sky130 OpenRAM macro banking (SYNTHESIS path).
  //
  // Banks the EXISTING stock macro sky130_sram_2kbyte_1rw1r_32x512_8 (512x32,
  // 1RW1R — the same macro my_ibex_sram placed) by WIDTH to realize the four
  // full-row operand buffers. Each macro: Port0 (RW)=write, Port1 (RO)=read.
  //   wgt/act = COLS*DATA_WIDTH/32 = 8 macros each;  scale = COLS*8/32 = 4 each.
  //   Total = 8 + 8 + 4 + 4 = 24 macros @ SRAM_DEPTH<=512 (one macro deep).
  //
  // COMPROMISE (see Review/OpenROAD_Integration_Plan.md §11 + Decisions Log
  // D-ORFS-SRAM): the SYNTHESIZED operand-buffer depth is 512 (set via config
  // VERILOG_TOP_PARAMS=SRAM_DEPTH=512), vs the 4096 behavioral default — the
  // stock macro is 512 deep; deeper would need depth-banking (->~190 macros) or
  // a custom OpenRAM geometry (deferred). Functionally equivalent for per-load
  // K<=512 (prototype 16x16 tiles use <<512). The behavioral model (`else
  // branch below) is retained VERBATIM for simulation / cocotb.
  // ===========================================================================
  // synthesis translate_off
  initial if (SRAM_DEPTH > 512)
    $fatal(1, "tensor_sram_wrapper[PDK_SKY130]: width-bank path needs SRAM_DEPTH<=512 (got %0d); set VERILOG_TOP_PARAMS=SRAM_DEPTH=512", SRAM_DEPTH);
  // synthesis translate_on

  localparam int MACRO_DW = 32;
  localparam int MACRO_AW = 9;                          // 512-deep stock macro
  localparam int WB_DATA  = (COLS*DATA_WIDTH)/MACRO_DW; // 8 width-banks (wgt/act, 256b)
  localparam int WB_SCL   = (COLS*8)/MACRO_DW;          // 4 width-banks (scale, 128b)

  genvar gb;

  // -------- WGT buffer: Port0 = write (wr_en | dma_wgt), Port1 = read --------
  logic                        wgt_we;
  logic [MACRO_AW-1:0]         wgt_wa;
  logic [COLS*DATA_WIDTH-1:0]  wgt_din_p, wgt_dout_p;
  assign wgt_we = wr_en | dma_wgt_wr_en;
  assign wgt_wa = wr_en ? wr_addr[MACRO_AW-1:0] : dma_wgt_wr_addr[MACRO_AW-1:0];
  always_comb for (int c = 0; c < COLS; c++)
    wgt_din_p[DATA_WIDTH*c +: DATA_WIDTH] = wr_en ? wr_data[c] : dma_wgt_wr_data[c];
  generate for (gb = 0; gb < WB_DATA; gb++) begin : g_wgt
    sky130_sram_2kbyte_1rw1r_32x512_8 u_wgt (
      .clk0(clk), .csb0(~wgt_we), .web0(1'b0), .wmask0(4'hF),
      .addr0(wgt_wa), .din0(wgt_din_p[MACRO_DW*gb +: MACRO_DW]), .dout0(),
      .clk1(clk), .csb1(~wgt_rd_en), .addr1(wgt_rd_addr[MACRO_AW-1:0]),
      .dout1(wgt_dout_p[MACRO_DW*gb +: MACRO_DW]));
  end endgenerate
  always_comb for (int c = 0; c < COLS; c++)
    wgt_rd_data[c] = wgt_dout_p[DATA_WIDTH*c +: DATA_WIDTH];

  // -------- ACT buffer: Port0 = write (dma_act), Port1 = read --------
  logic [COLS*DATA_WIDTH-1:0]  act_din_p, act_dout_p;
  always_comb for (int r = 0; r < ROWS; r++)
    act_din_p[DATA_WIDTH*r +: DATA_WIDTH] = dma_act_wr_data[r];
  generate for (gb = 0; gb < WB_DATA; gb++) begin : g_act
    sky130_sram_2kbyte_1rw1r_32x512_8 u_act (
      .clk0(clk), .csb0(~dma_act_wr_en), .web0(1'b0), .wmask0(4'hF),
      .addr0(dma_act_wr_addr[MACRO_AW-1:0]), .din0(act_din_p[MACRO_DW*gb +: MACRO_DW]), .dout0(),
      .clk1(clk), .csb1(~act_rd_en), .addr1(act_rd_addr[MACRO_AW-1:0]),
      .dout1(act_dout_p[MACRO_DW*gb +: MACRO_DW]));
  end endgenerate
  always_comb for (int r = 0; r < ROWS; r++)
    act_rd_data[r] = act_dout_p[DATA_WIDTH*r +: DATA_WIDTH];

  // -------- SCALE-WGT buffer (8b x COLS = 128b): write dma_scale, read scale_rd --------
  logic [COLS*8-1:0] sclw_din_p, sclw_dout_p;
  always_comb for (int c = 0; c < COLS; c++)
    sclw_din_p[8*c +: 8] = dma_scale_wr_data_wgt[c];
  generate for (gb = 0; gb < WB_SCL; gb++) begin : g_sclw
    sky130_sram_2kbyte_1rw1r_32x512_8 u_sclw (
      .clk0(clk), .csb0(~dma_scale_wr_en), .web0(1'b0), .wmask0(4'hF),
      .addr0(dma_scale_wr_addr[MACRO_AW-1:0]), .din0(sclw_din_p[MACRO_DW*gb +: MACRO_DW]), .dout0(),
      .clk1(clk), .csb1(~scale_rd_en), .addr1(scale_rd_addr[MACRO_AW-1:0]),
      .dout1(sclw_dout_p[MACRO_DW*gb +: MACRO_DW]));
  end endgenerate
  always_comb for (int c = 0; c < COLS; c++)
    scale_rd_data_wgt[c] = sclw_dout_p[8*c +: 8];

  // -------- SCALE-ACT buffer (8b x ROWS = 128b) --------
  logic [ROWS*8-1:0] scla_din_p, scla_dout_p;
  always_comb for (int r = 0; r < ROWS; r++)
    scla_din_p[8*r +: 8] = dma_scale_wr_data_act[r];
  generate for (gb = 0; gb < WB_SCL; gb++) begin : g_scla
    sky130_sram_2kbyte_1rw1r_32x512_8 u_scla (
      .clk0(clk), .csb0(~dma_scale_wr_en), .web0(1'b0), .wmask0(4'hF),
      .addr0(dma_scale_wr_addr[MACRO_AW-1:0]), .din0(scla_din_p[MACRO_DW*gb +: MACRO_DW]), .dout0(),
      .clk1(clk), .csb1(~scale_rd_en), .addr1(scale_rd_addr[MACRO_AW-1:0]),
      .dout1(scla_dout_p[MACRO_DW*gb +: MACRO_DW]));
  end endgenerate
  always_comb for (int r = 0; r < ROWS; r++)
    scale_rd_data_act[r] = scla_dout_p[8*r +: 8];

  // -------- Read-valid flops (the macros themselves provide 1-cycle read data) --------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wgt_rd_valid   <= 1'b0;
      act_rd_valid   <= 1'b0;
      scale_rd_valid <= 1'b0;
    end else begin
      wgt_rd_valid   <= wgt_rd_en;
      act_rd_valid   <= act_rd_en;
      scale_rd_valid <= scale_rd_en;
    end
  end

`elsif PDK_ASAP7
  // ===========================================================================
  // [ASAP7 headline track, 2026-07-02] fakeram7_256x32 depth-banked ANALYTICAL
  // SRAM binding (SYNTHESIS-ONLY path; simulation always takes the behavioral
  // `else` branch — this branch is never simulated).
  //
  // The stock ASAP7 fakeram7_256x32 is a single-port 1RW macro (no second read
  // port, no write mask), so this is an analytical area/timing model, not a
  // functional dual-port memory:
  //   - 512-deep bank = 2 x 256-deep halves selected by addr bit 8
  //     (tensor_asap7_sram_512x32 helper module at end of file);
  //   - the 1W+1R usage binds to the single port with WRITE PRIORITY (a read
  //     colliding with a write is dropped — irrelevant for synthesis PPA);
  //   - lanes mirror the PDK_SKY130 branch: wgt/act = 8 x 32b, scale = 4 x 32b
  //     -> (8+8+4+4) banks x 2 halves = 48 macros.
  // Both converter-free and converter-based variants share this wrapper, so
  // the headline delta is unaffected; absolute ASAP7 SRAM numbers must be
  // footnoted as FakeRAM analytical models (Paper/PPA_Tables_SSOT.md).
  // ===========================================================================
  // synthesis translate_off
  initial if (SRAM_DEPTH > 512)
    $fatal(1, "tensor_sram_wrapper[PDK_ASAP7]: depth-bank path needs SRAM_DEPTH<=512 (got %0d); set VERILOG_TOP_PARAMS=SRAM_DEPTH=512", SRAM_DEPTH);
  // synthesis translate_on

  localparam int MACRO_DW = 32;
  localparam int BANK_AW  = 9;                          // 512-deep logical bank
  localparam int WB_DATA  = (COLS*DATA_WIDTH)/MACRO_DW; // 8 fakeram width-banks (wgt/act, 256b)
  localparam int WB_SCL   = (COLS*8)/MACRO_DW;          // 4 fakeram width-banks (scale, 128b)
  // Memory 波1: real srambank is 64b wide → half the bank count of the 32b fakeram.
  localparam int REAL_DW  = 64;
  localparam int RB_DATA  = (COLS*DATA_WIDTH)/REAL_DW;  // 4 real macros (wgt/act, 256b)
  localparam int RB_SCL   = (COLS*8)/REAL_DW;           // 2 real macros (scale, 128b)

  // synthesis translate_off
  initial if (REAL_MACRO && (((COLS*DATA_WIDTH) % REAL_DW != 0) || ((COLS*8) % REAL_DW != 0)))
    $fatal(1, "tensor_sram_wrapper[PDK_ASAP7,REAL_MACRO]: operand (%0d) and scale (%0d) widths must be multiples of %0d",
           COLS*DATA_WIDTH, COLS*8, REAL_DW);
  // synthesis translate_on

  genvar gb;

  // -------- WGT buffer: write (wr_en | dma_wgt) with priority, read --------
  logic                        wgt_we;
  logic [BANK_AW-1:0]          wgt_wa;
  logic [COLS*DATA_WIDTH-1:0]  wgt_din_p, wgt_dout_p;
  assign wgt_we = wr_en | dma_wgt_wr_en;
  assign wgt_wa = wr_en ? wr_addr[BANK_AW-1:0] : dma_wgt_wr_addr[BANK_AW-1:0];
  always_comb for (int c = 0; c < COLS; c++)
    wgt_din_p[DATA_WIDTH*c +: DATA_WIDTH] = wr_en ? wr_data[c] : dma_wgt_wr_data[c];
  generate if (REAL_MACRO) begin : g_wgt_real
    for (gb = 0; gb < RB_DATA; gb++) begin : g_wgt
      tensor_real_sram_512x64 u_wgt (
        .clk(clk), .we(wgt_we), .wa(wgt_wa),
        .din(wgt_din_p[REAL_DW*gb +: REAL_DW]),
        .re(wgt_rd_en), .ra(wgt_rd_addr[BANK_AW-1:0]),
        .dout(wgt_dout_p[REAL_DW*gb +: REAL_DW]));
    end
  end else begin : g_wgt_fake
    for (gb = 0; gb < WB_DATA; gb++) begin : g_wgt
      tensor_asap7_sram_512x32 u_wgt (
        .clk(clk), .we(wgt_we), .wa(wgt_wa),
        .din(wgt_din_p[MACRO_DW*gb +: MACRO_DW]),
        .re(wgt_rd_en), .ra(wgt_rd_addr[BANK_AW-1:0]),
        .dout(wgt_dout_p[MACRO_DW*gb +: MACRO_DW]));
    end
  end endgenerate
  always_comb for (int c = 0; c < COLS; c++)
    wgt_rd_data[c] = wgt_dout_p[DATA_WIDTH*c +: DATA_WIDTH];

  // -------- ACT buffer: write dma_act, read act_rd --------
  logic [COLS*DATA_WIDTH-1:0]  act_din_p, act_dout_p;
  always_comb for (int r = 0; r < ROWS; r++)
    act_din_p[DATA_WIDTH*r +: DATA_WIDTH] = dma_act_wr_data[r];
  generate if (REAL_MACRO) begin : g_act_real
    for (gb = 0; gb < RB_DATA; gb++) begin : g_act
      tensor_real_sram_512x64 u_act (
        .clk(clk), .we(dma_act_wr_en), .wa(dma_act_wr_addr[BANK_AW-1:0]),
        .din(act_din_p[REAL_DW*gb +: REAL_DW]),
        .re(act_rd_en), .ra(act_rd_addr[BANK_AW-1:0]),
        .dout(act_dout_p[REAL_DW*gb +: REAL_DW]));
    end
  end else begin : g_act_fake
    for (gb = 0; gb < WB_DATA; gb++) begin : g_act
      tensor_asap7_sram_512x32 u_act (
        .clk(clk), .we(dma_act_wr_en), .wa(dma_act_wr_addr[BANK_AW-1:0]),
        .din(act_din_p[MACRO_DW*gb +: MACRO_DW]),
        .re(act_rd_en), .ra(act_rd_addr[BANK_AW-1:0]),
        .dout(act_dout_p[MACRO_DW*gb +: MACRO_DW]));
    end
  end endgenerate
  always_comb for (int r = 0; r < ROWS; r++)
    act_rd_data[r] = act_dout_p[DATA_WIDTH*r +: DATA_WIDTH];

  // -------- SCALE-WGT buffer (8b x COLS = 128b) --------
  logic [COLS*8-1:0] sclw_din_p, sclw_dout_p;
  always_comb for (int c = 0; c < COLS; c++)
    sclw_din_p[8*c +: 8] = dma_scale_wr_data_wgt[c];
  generate if (REAL_MACRO) begin : g_sclw_real
    for (gb = 0; gb < RB_SCL; gb++) begin : g_sclw
      tensor_real_sram_512x64 u_sclw (
        .clk(clk), .we(dma_scale_wr_en), .wa(dma_scale_wr_addr[BANK_AW-1:0]),
        .din(sclw_din_p[REAL_DW*gb +: REAL_DW]),
        .re(scale_rd_en), .ra(scale_rd_addr[BANK_AW-1:0]),
        .dout(sclw_dout_p[REAL_DW*gb +: REAL_DW]));
    end
  end else begin : g_sclw_fake
    for (gb = 0; gb < WB_SCL; gb++) begin : g_sclw
      tensor_asap7_sram_512x32 u_sclw (
        .clk(clk), .we(dma_scale_wr_en), .wa(dma_scale_wr_addr[BANK_AW-1:0]),
        .din(sclw_din_p[MACRO_DW*gb +: MACRO_DW]),
        .re(scale_rd_en), .ra(scale_rd_addr[BANK_AW-1:0]),
        .dout(sclw_dout_p[MACRO_DW*gb +: MACRO_DW]));
    end
  end endgenerate
  always_comb for (int c = 0; c < COLS; c++)
    scale_rd_data_wgt[c] = sclw_dout_p[8*c +: 8];

  // -------- SCALE-ACT buffer (8b x ROWS = 128b) --------
  logic [ROWS*8-1:0] scla_din_p, scla_dout_p;
  always_comb for (int r = 0; r < ROWS; r++)
    scla_din_p[8*r +: 8] = dma_scale_wr_data_act[r];
  generate if (REAL_MACRO) begin : g_scla_real
    for (gb = 0; gb < RB_SCL; gb++) begin : g_scla
      tensor_real_sram_512x64 u_scla (
        .clk(clk), .we(dma_scale_wr_en), .wa(dma_scale_wr_addr[BANK_AW-1:0]),
        .din(scla_din_p[REAL_DW*gb +: REAL_DW]),
        .re(scale_rd_en), .ra(scale_rd_addr[BANK_AW-1:0]),
        .dout(scla_dout_p[REAL_DW*gb +: REAL_DW]));
    end
  end else begin : g_scla_fake
    for (gb = 0; gb < WB_SCL; gb++) begin : g_scla
      tensor_asap7_sram_512x32 u_scla (
        .clk(clk), .we(dma_scale_wr_en), .wa(dma_scale_wr_addr[BANK_AW-1:0]),
        .din(scla_din_p[MACRO_DW*gb +: MACRO_DW]),
        .re(scale_rd_en), .ra(scale_rd_addr[BANK_AW-1:0]),
        .dout(scla_dout_p[MACRO_DW*gb +: MACRO_DW]));
    end
  end endgenerate
  always_comb for (int r = 0; r < ROWS; r++)
    scale_rd_data_act[r] = scla_dout_p[8*r +: 8];

  // -------- Read-valid flops (macros provide 1-cycle read data) --------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wgt_rd_valid   <= 1'b0;
      act_rd_valid   <= 1'b0;
      scale_rd_valid <= 1'b0;
    end else begin
      wgt_rd_valid   <= wgt_rd_en;
      act_rd_valid   <= act_rd_en;
      scale_rd_valid <= scale_rd_en;
    end
  end

`else
  // Storage arrays
  logic [DATA_WIDTH-1:0] wgt_mem  [SRAM_DEPTH][COLS];
  logic [DATA_WIDTH-1:0] act_mem  [SRAM_DEPTH][ROWS];
  logic [7:0]            scale_wgt_mem [SRAM_DEPTH][COLS];
  logic [7:0]            scale_act_mem [SRAM_DEPTH][ROWS];

  // ---- Weight Read (1-cycle latency) ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wgt_rd_valid <= 1'b0;
      for (int c = 0; c < COLS; c++) wgt_rd_data[c] <= '0;
    end else begin
      wgt_rd_valid <= wgt_rd_en;
      if (wgt_rd_en)
        for (int c = 0; c < COLS; c++)
          wgt_rd_data[c] <= wgt_mem[wgt_rd_addr][c];
    end
  end

  // ---- Activation Read (1-cycle latency) ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_rd_valid <= 1'b0;
      for (int r = 0; r < ROWS; r++) act_rd_data[r] <= '0;
    end else begin
      act_rd_valid <= act_rd_en;
      if (act_rd_en)
        for (int r = 0; r < ROWS; r++)
          act_rd_data[r] <= act_mem[act_rd_addr][r];
    end
  end

  // ---- Scale Read (1-cycle latency) ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scale_rd_valid <= 1'b0;
      for (int c = 0; c < COLS; c++) scale_rd_data_wgt[c] <= 8'd0;
      for (int r = 0; r < ROWS; r++) scale_rd_data_act[r] <= 8'd0;
    end else begin
      scale_rd_valid <= scale_rd_en;
      if (scale_rd_en) begin
        for (int c = 0; c < COLS; c++)
          scale_rd_data_wgt[c] <= scale_wgt_mem[scale_rd_addr][c];
        for (int r = 0; r < ROWS; r++)
          scale_rd_data_act[r] <= scale_act_mem[scale_rd_addr][r];
      end
    end
  end

  // ---- Result Writeback ----
  always_ff @(posedge clk) begin
    if (wr_en)
      for (int c = 0; c < COLS; c++)
        wgt_mem[wr_addr][c] <= wr_data[c];
  end

  // ---- DMA Writes (test data loading) ----
  always_ff @(posedge clk) begin
    if (dma_wgt_wr_en)
      for (int c = 0; c < COLS; c++)
        wgt_mem[dma_wgt_wr_addr][c] <= dma_wgt_wr_data[c];
    if (dma_act_wr_en)
      for (int r = 0; r < ROWS; r++)
        act_mem[dma_act_wr_addr][r] <= dma_act_wr_data[r];
    if (dma_scale_wr_en) begin
      for (int c = 0; c < COLS; c++)
        scale_wgt_mem[dma_scale_wr_addr][c] <= dma_scale_wr_data_wgt[c];
      for (int r = 0; r < ROWS; r++)
        scale_act_mem[dma_scale_wr_addr][r] <= dma_scale_wr_data_act[r];
    end
  end
`endif

endmodule


`ifdef PDK_ASAP7
// ############################################################################
// MODULE 1b: tensor_asap7_sram_512x32  (PDK_ASAP7 synthesis-only helper)
// ############################################################################
// One 512x32 logical operand bank = 2 x single-port fakeram7_256x32 halves,
// addr bit 8 selecting the half. Write has priority on the single 1RW port;
// read data is steered by the registered read-half select one cycle later
// (matches the macro's 1-cycle synchronous read). Analytical area/timing
// model only — never simulated (see the wrapper's PDK_ASAP7 note).
module tensor_asap7_sram_512x32 (
  input  logic        clk,
  input  logic        we,
  input  logic [8:0]  wa,
  input  logic [31:0] din,
  input  logic        re,
  input  logic [8:0]  ra,
  output logic [31:0] dout
);
  logic [8:0]  addr;              // write-priority single-port address
  logic        sel_q;             // registered read-half select
  logic [31:0] rd_half [2];

  assign addr = we ? wa : ra;

  always_ff @(posedge clk) if (re) sel_q <= ra[8];

  generate for (genvar gh = 0; gh < 2; gh++) begin : g_half
    fakeram7_256x32 u_half (
      .clk    (clk),
      .ce_in  ((we | re) & (addr[8] == 1'(gh))),
      .we_in  (we & (wa[8] == 1'(gh))),
      .addr_in(addr[7:0]),
      .wd_in  (din),
      .rd_out (rd_half[gh])
    );
  end endgenerate

  assign dout = rd_half[sel_q];

endmodule


// ############################################################################
// MODULE 1c: tensor_real_sram_512x64  (PDK_ASAP7 synthesis-only, Memory 波1)
// ############################################################################
// One 512x64 single-port operand/scale width-bank = the REAL asap7_sram_0p0
// macro srambank_128x4x64_6t122 (128x4=512 words, 64b, single-port 1RW, no byte
// mask, read/write mutually exclusive). Write has priority on the single port
// (a colliding read is dropped — analytical, irrelevant for synthesis PPA, and
// the tensor flow separates load/compute phases). Tape-out-ready: the x64 width
// family is the only one with GDS in asap7_sram_0p0. Never simulated (sim always
// takes the behavioral `else` branch of tensor_sram_wrapper).
module tensor_real_sram_512x64 (
  input  logic        clk,
  input  logic        we,
  input  logic [8:0]  wa,
  input  logic [63:0] din,
  input  logic        re,
  input  logic [8:0]  ra,
  output logic [63:0] dout
);
  logic [8:0] addr;
  assign addr = we ? wa : ra;   // write-priority single-port address

  srambank_128x4x64_6t122 u_macro (
    .clk     (clk),
    .ADDRESS (addr),
    .wd      (din),
    .banksel (we | re),
    .read    (re & ~we),
    .write   (we),
    .dataout (dout)
  );
endmodule
`endif


// ############################################################################
// MODULE 2: tensor_cmd_decoder
// ############################################################################
//
// Decodes MMIO register writes from the CPU into tile descriptor fields.
// On write to CTRL register with start=1, latches all parameter registers
// and pushes a complete tile_descriptor_t + SRAM base addresses to the
// descriptor queue.
//
// Register map (byte-addressed offsets from Tensor MMIO base):
//   0x00 CTRL      [0] start, [1] abort, [7:4] mode, [8] dataflow_sel
//   0x04 K_TOTAL   [15:0] k_total
//   0x08 SPARSE    [1:0] exec (exec_sparse_mode_e), [3:2] n_cfg (ncfg_e, [3a-3]),
//                  [4] scu_en (RESERVED/tied-0 — see 0x08 decode), [31:5] 未解码
//   0x0C OUT_CTRL  [1:0] exec_class, [3:2] out_class, [5:4] out_fmt, [6] ofu_round
//     ▲订正（[3a-3] 2026-08-04，PROJECT_RULES §5.0d 型 15 顺手清理）：本行原文写的是
//       「OFU_CFG [2:0] ofu_fmt, [4] ofu_round_mode, [8] forward_eligible」——
//       **字段名/位置/宽度与真实解码逐字段矛盾**，且 forward_eligible 在 R1 就已被
//       out_class 吸收除名（见 tensor_pkg.sv 的 tile_descriptor_t R1 Changes 段）。
//       真值以紧随其后的 8'h0C 解码分支为准（该分支自带同样的四行注释）。
//   0x10 EPOCH     [7:0] epoch
//   0x14 WGT_BASE  [ADDR_WIDTH-1:0] weight SRAM base address
//   0x18 ACT_BASE  [ADDR_WIDTH-1:0] activation SRAM base address
//   0x1C SCL_BASE  [ADDR_WIDTH-1:0] scale SRAM base address
//   0x20 RES_BASE  [ADDR_WIDTH-1:0] result writeback base address
// ============================================================================

module tensor_cmd_decoder
  import tensor_pkg::*;
#(
  parameter int ADDR_WIDTH = 12
) (
  input  logic               clk,
  input  logic               rst_n,

  // ---- MMIO Write Interface ----
  input  logic               mmio_wr_valid,
  input  logic [7:0]         mmio_wr_addr,
  input  logic [31:0]        mmio_wr_data,

  // ---- To desc_queue ----
  output logic               desc_push_valid,
  input  logic               desc_push_ready,
  output tile_descriptor_t   desc_out,
  output logic [ADDR_WIDTH-1:0] desc_wgt_base,
  output logic [ADDR_WIDTH-1:0] desc_act_base,
  output logic [ADDR_WIDTH-1:0] desc_scale_base,
  output logic [ADDR_WIDTH-1:0] desc_result_base,

  // ---- Reject observability (3a-7/P4) ----
  // 🔴 命名：叫 err_DESC_reject 不叫 err_sparse_reject（裁决 D-P4-4）。
  //    本位的触发集 = is_valid_descriptor 的【全部 7 条】return 1'b0 臂
  //    （exec_class/out_class 保留值 · EXEC_NONE×ESCAPE_FMT · FORMAT_ONLY×native ·
  //      3a-7/P3 新加的 sparse_mode 保留值 / n_cfg 保留值 / WS×非dense），
  //    只有后三条与稀疏有关。叫 sparse 会让下一个人以为「非稀疏的非法描述符不置位」，
  //    是 PROJECT_RULES §5.0d 型 15/型 16 的温床。
  output logic               err_desc_reject,

  // ---- Immediate Control ----
  output logic               force_abort,

  // ---- Status feedback (for MMIO read-back) ----
  input  logic               ctrl_busy
);

  // Parameter registers (latched on MMIO write)
  tensor_mode_e           reg_mode;
  logic [15:0]         reg_k_total;
  exec_sparse_mode_e   reg_sparse_mode;
  ncfg_e               reg_n_cfg;          // [3a-3] MMIO 0x08 [3:2] —— per-tile N:M 配置
  logic                reg_dataflow_sel;
  // R8: descriptor field registers updated for 3-field orthogonal routing
  exec_class_e         reg_exec_class;
  out_class_e          reg_out_class;
  out_fmt_e            reg_out_fmt;
  out_round_e          reg_ofu_round;
  logic [7:0]          reg_epoch;
  // reg_sparse_compress_en REMOVED (v4.2 M1, 2026-07-23) — bit reserved/tied 0.
  logic [ADDR_WIDTH-1:0] reg_wgt_base;
  logic [ADDR_WIDTH-1:0] reg_act_base;
  logic [ADDR_WIDTH-1:0] reg_scale_base;
  logic [ADDR_WIDTH-1:0] reg_result_base;

  // Push control
  logic start_pulse;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      reg_mode             <= MODE_UINT4_SIMD;
      reg_k_total          <= 16'd0;
      reg_sparse_mode      <= EXEC_DENSE;
      // 🔴 [3a-3] 硬前提双锚之①：复位必须是 NCFG_DENSE(2'b00)。
      //    R1_Baseline_Criteria §4.6 的一票否决硬前提「dense 激励不写 0x08 也走 dense 臂」
      //    完全押在这一行 + tensor_tile_controller 的 tile_desc_q <= '0 上。
      //    8 个 r1_dense case 全都不写 0x08 —— 改这行当天 R1 全破。
      reg_n_cfg            <= NCFG_DENSE;
      reg_dataflow_sel     <= 1'b0;
      reg_exec_class       <= EXEC_NONE;
      reg_out_class        <= OUT_STORE_NATIVE;
      reg_out_fmt          <= OUT_FMT_BF16;
      reg_ofu_round        <= OUT_ROUND_RTZ;
      reg_epoch            <= 8'd0;
      reg_wgt_base         <= '0;
      reg_act_base         <= '0;
      reg_scale_base       <= '0;
      reg_result_base      <= '0;
    end else if (mmio_wr_valid) begin
      unique case (mmio_wr_addr)
        8'h00: begin // CTRL — mode + dataflow_sel (start handled below)
          reg_mode         <= tensor_mode_e'(mmio_wr_data[7:4]);
          reg_dataflow_sel <= mmio_wr_data[8];
        end
        8'h04: reg_k_total <= mmio_wr_data[15:0];
        8'h08: begin
          reg_sparse_mode      <= exec_sparse_mode_e'(mmio_wr_data[1:0]);
          // [3a-3 2026-08-04] [3:2] n_cfg —— per-tile N:M 配置（规格 §5.2）。
          //
          // 🔴 位置钉死 [3:2]，不得上移到 bit4 及以上：bit4 是 scu_en(RESERVED)，
          //    落到那里会让 test_scu_tile_bit_reserved 的语义变成「写了稀疏配置却断言
          //    dense 结果」，而且 3a-3 当天两闸全绿、要到 3a-4 接上数据通路才炸
          //    （届时已叠两片，无法二分）。
          //
          // 🔴 这里【只做裸锁存，不做合法性校验】，与紧邻上一行的 exec 同型。
          //    规格 §5.2 说「exec 由 n_cfg 派生、n_cfg 为唯一权威」，但那条派生
          //    **必须落在 tensor_cmd_mmio_seq**（规格 §5.1 原文），不能搬进本 decoder：
          //    tb/scratch_guard_probe.py 的机理是直写 0x08[1:0]，一旦本模块用 [3:2]
          //    覆盖 [1:0]，该探针再也推不动 sparse_exec_mode ⇒ 白名单臂静默退回零覆盖。
          //    ▲[3a-4/M2 2026-08-06 订正] 原文这里写的是「~~3a-1 RED-1/RED-2 的唯一红臂~~」——
          //      **RED-1（`0x08=0x01`）已于 M2 按计划由红转绿**（C1 放宽）。
          //      今天靠这条注入口活着的红臂 = 保留编码两发（`0x08=0x03` / `0x08=0x02`）
          //      + WS 绊线一发 + n_cfg 侧的 P3/P4 两发。**注入口本身的重要性不变、只增不减。**
          //
          // 措辞纪律（PROJECT_RULES §5.0d C7）：本行**不是**拒收口。n_cfg 保留值
          //    (NCFG_RESERVED) 的写入时拒收归 3a-7/3a-8；3a-3 只在
          //    tensor_tile_controller 断言区落 $fatal 级仿真绊线。
          reg_n_cfg            <= ncfg_e'(mmio_wr_data[3:2]);
          // [4] scu_en is RESERVED (v4.2 M1, 2026-07-23) and intentionally NOT
          // stored. The SCU adaptive path left-compacts operands, but
          // tensor_mac_array never consumes idx_out/nnz_count (:708), so the
          // compacted survivors enter the WRONG systolic row/column — measured
          // 253/256 output cells corrupted (tb: test_scu_tile.py). Until a fix
          // scatters survivors back via idx (M3 / storage wave-2), the bit is
          // tied 0 at desc_out so firmware can never trip it.
        end
        8'h0C: begin
          // R8: new OUT_CTRL MMIO layout for 3-field descriptor
          //   [1:0] exec_class, [3:2] out_class, [5:4] out_fmt, [6] ofu_round
          reg_exec_class  <= exec_class_e'(mmio_wr_data[1:0]);
          reg_out_class   <= out_class_e'(mmio_wr_data[3:2]);
          reg_out_fmt     <= out_fmt_e'(mmio_wr_data[5:4]);
          reg_ofu_round   <= out_round_e'(mmio_wr_data[6]);
        end
        8'h10: reg_epoch      <= mmio_wr_data[7:0];
        8'h14: reg_wgt_base   <= mmio_wr_data[ADDR_WIDTH-1:0];
        8'h18: reg_act_base   <= mmio_wr_data[ADDR_WIDTH-1:0];
        8'h1C: reg_scale_base <= mmio_wr_data[ADDR_WIDTH-1:0];
        8'h20: reg_result_base <= mmio_wr_data[ADDR_WIDTH-1:0];
        default: ;
      endcase
    end
  end

  // Start pulse: CTRL write with bit[0] = 1
  assign start_pulse = mmio_wr_valid && (mmio_wr_addr == 8'h00) && mmio_wr_data[0];
  assign force_abort = mmio_wr_valid && (mmio_wr_addr == 8'h00) && mmio_wr_data[1];

  // ==========================================================================
  // [3a-7/P4 2026-08-06] 拒收可观测口（规格 §5.4；预登记 s3a7_prereg_20260805.md §9）
  //
  // ~~🔴 措辞纪律：本批落的是【观测口】不是拒收；非法描述符照样入队；禁称「已拒收」。~~
  //    ▲**[3a-7/P5 2026-08-06 订正] 上面这条限制【已解除】** —— P5 已把本谓词接到
  //    `desc_push_valid` 上（见本模块下方那条 continuous assign），非法描述符**不再入队**。
  //    红绿证据（盘上）：`s3a7_p5_probes_verdict_20260806.txt` = `P5-PROBES-VERDICT=PASS`
  //      · 五个非法发 start 全被丢且 `0x1C bit[2]` 读回 1
  //      · 两个合法发照样跑完且 `bit[2]`=0（谓词没写宽）
  //    `s3a7_p5_redarms_rejudge_verdict_20260806.txt` = `P5-REDARMS-REJUDGE-VERDICT=PASS`
  //      （拆门 / 架空谓词两臂都让 R5-6 重新响 ⇒ 拦住它们的是**谓词**不是门的存在）。
  //    🔴 **仍然生效的措辞限定（裁决 B7）**：只许写「**MMIO 拒在 TB 层可观测**」，
  //    **禁写「固件可读回」** —— 集成层无读通路（`tensor_domain_top.sv:242` 读地址硬接
  //    `8'd0`、`:306` 读数据进 `_unused`、`:244` `counter_clear` tie 0）。
  //
  // 🔴 为什么先 P4 后 P5（顺序不可倒）：规格 §5.4 逐字「MMIO 拒必须可观测
  //    （丢 start + sticky error 位可读回，禁静默丢）」。先落 P5 的丢 start、
  //    后落观测口，中间那一段交付的正是 §5.4 明文禁止的**静默拒**（型 14 的机理）。
  //
  // 🔴 desc_reject 是【P4 观测口与 P5 push 门共用的同一个谓词】（裁决 D-P4-1）：
  //    ▲[3a-7/P5 2026-08-06] **已落地**：门在本模块下方（搜 `desc_push_valid` 的那条
  //    continuous assign），P5 只改了它的右值 ⇒ 观测口与拒收门共用同一个谓词，
  //    两者结构上不可能分叉出「拒了不置位 / 置位不拒」。
  //    ⛔ **3a-8 的临时闸禁并进本谓词**：3a-8 要加的是「n_cfg != NCFG_DENSE 即拒」，
  //    触发集 {2'b01,2'b10,2'b11}、蓝图项 8 逐字「3b/3c 落地后拆闸」= **临时**；
  //    而 is_valid_descriptor 是**永久**编码拒。两者寿命相反且触发集真包含，
  //    并进来会在拆临时闸当天连坐拆掉永久拒、硅上恢复静默
  //    （全案 = PROJECT_RULES §8 的 D-SPARSE-3A7-SCOPE-2026-08-05）。
  //    3a-8 必须**另起一个谓词**与本条并联，且豁免口按 TESTCASE/描述符来源判、
  //    **不按 n_cfg 值判**。
  // ==========================================================================
  logic desc_reject;
  assign desc_reject     = start_pulse && !is_valid_descriptor(desc_out);
  assign err_desc_reject = desc_reject;

  // ==========================================================================
  // [3a-7/P5 2026-08-06] 🔴 **真拒收门**（规格 §5.4；预登记 s3a7_prereg_20260805.md §10）
  //
  // 非法描述符的 start 被【丢弃】：不入队、controller 永不启动，而 P4 的
  // err_desc_reject → 0x1C bit[2] 把这次丢弃留成【可读回的 sticky 痕迹】
  // ⇒ 规格 §5.4「丢 start + sticky error 位可读回，**禁静默丢**」两半同时成立。
  // 自本行起，`PROJECT_RULES §5.0d` 型 15（跨模块 fail-open）对本通路的定性**失效**。
  //
  // 🔴🔴 **必须是纯组合 `assign`，禁插寄存拍**：R1 基线的八发 dense `#CYCLES` 是逐字比对的，
  //    插一拍会让 `R1-CADENCE-DRIFT` 八发全红，而该态**明令禁走「基线作废重采」**
  //    （BuildSheet §5 逐字）⇒ 一旦插了就只能回退重做，没有第二条路。
  //
  // 🔴 谓词与 P4 观测口**共用同一个 `desc_reject`**（裁决 D-P4-1）⇒ 结构上不可能出现
  //    「拒了不置位」或「置位不拒」。改这里必须同时想清楚 0x1C bit[2] 的语义。
  //
  // ⛔ **3a-8 的临时闸禁并进 `desc_reject`**（D-SPARSE-3A7-SCOPE-2026-08-05）：
  //    3a-8 要加的是「`n_cfg != NCFG_DENSE` 即拒」，触发集 {01,10,11}、蓝图项 8 逐字
  //    「3b/3c 落地后拆闸」= **临时**；而 `is_valid_descriptor` 是**永久**编码拒。
  //    两者寿命相反且触发集真包含 ⇒ 并进来会在拆临时闸当天连坐拆掉永久拒、硅上恢复静默。
  //    **3a-8 的正确挂法** = 在本行**另起一个谓词**与 `desc_reject` 并联，形如
  //        assign desc_push_valid = start_pulse && !desc_reject && !tmp_ncfg_gate;
  //    且 `tmp_ncfg_gate` **必须挂一个非描述符来源的豁免输入**（豁免口按 `TESTCASE` /
  //    描述符来源判，**不按 n_cfg 值判**）—— 因为该闸会一起打掉 N=2 与 N=1 两个**合法**载体
  //    （`test_tensor_sparse_cadence` 的 `0x08=0x09` 与 `test_tensor_sparse_n1_cadence`
  //     的 `0x08=0x05`，共 6 test / 2 文件）。**缺这个豁免口，3a-8 开工当天会发现落不了。**
  //
  // 🔴 **已知残余 fail-open（本片不修，登记给后续片）**：`desc_push_ready` 是本模块的
  //    **input 但全文无消费者** —— 队列满时（`wr_ready = !full` 为 0）`do_write` 为 0，
  //    start **静默丢失且无任何通知**，0x1C bit[2] 也不会置位（它只反映「非法」不反映「满」）。
  //    当前 DESC_QUEUE_DEPTH 下全仓无用例能填满队列 ⇒ 零覆盖，非本片工作面。
  // ==========================================================================
  assign desc_push_valid = start_pulse && !desc_reject;
  assign desc_out.mode             = reg_mode;
  assign desc_out.k_total          = reg_k_total;
  assign desc_out.sparse_mode      = reg_sparse_mode;
  // 🔴 [3a-3] desc_out 是【逐字段 continuous assign】，不是整体聚合 ⇒ 漏掉这一行
  //    **不报错、不告警、两闸全绿**，只会让 tile_descriptor_t.n_cfg 悬空（UNDRIVEN，
  //    而 UNDRIVEN 属 -Wall 组默认关闭，elaborate_smoke.sh 还显式 -Wno-UNDRIVEN）。
  //    自证口径（本片实测有牙，禁用 -Wall —— 它会让 38 个 elaborate 靶集体 FAIL）：
  //    跑 `verilator $LFLAGS -Wwarn-UNDRIVEN --top-module tb_tensor_gemm_core <18 源>`
  //    再数 UNDRIVEN 条数：绿基线 0 → 注释掉本行应 ≥1（报 Bits of signal are not
  //    driven: 'desc_out'[…]）→ 恢复后回 0。
  //    🔴 注意本注释块自身：PROJECT_RULES §5.0e —— `//` 后第一个词是工具名会被当成
  //    lint metacomment 整行吞掉（本片实测踩过一次），故上面那行前面加了「跑 」。
  assign desc_out.n_cfg            = reg_n_cfg;
  assign desc_out.dataflow_sel     = reg_dataflow_sel;
  assign desc_out.exec_class = reg_exec_class;
  assign desc_out.out_class  = reg_out_class;
  assign desc_out.out_fmt    = reg_out_fmt;
  assign desc_out.ofu_round  = reg_ofu_round;

  // ~~R8: illegal descriptor combination assertion (uses tensor_pkg helper)~~
  // 🔴 [3a-2 2026-08-03] **悬空注释**：本模块（tensor_cmd_decoder）全文不出现
  //   is_valid_descriptor，紧随本注释的是 desc_out.epoch 赋值，不是任何断言。
  //   ~~非法描述符在 MMIO 写入时**不被拒收**（型 15）。真正的拒收实现归 3a-7。~~
  //   ▲**[3a-7/P5 2026-08-06 订正]：型 15 的定性【已失效】。**
  //   非法描述符**在 MMIO 写入时被拒收** —— 实现点 = 本模块下方
  //   `assign desc_push_valid = start_pulse && !desc_reject;`（P5 落地，纯组合）。
  //   本注释所在处仍然没有断言（那一句本就是悬空注释），但**函数确实被消费了**：
  //   `desc_reject = start_pulse && !is_valid_descriptor(desc_out)`。
  //   全案见 tensor_pkg.sv 的 is_valid_descriptor 头注（同批已订正）。
  assign desc_out.epoch            = reg_epoch;
  assign desc_out.sparse_compress_en = 1'b0;   // RESERVED — tied off (see 0x08 decode)
  // [C1 2026-07-31] SCU 本体已删除（D-SPARSE-NM）；本 tie 与 desc 字段保留 = MMIO bit4
  // RESERVED 语义不变（D-SCU-RESERVED），守门 test_scu_tile_bit_reserved 继续有效。
  assign desc_wgt_base    = reg_wgt_base;
  assign desc_act_base    = reg_act_base;
  assign desc_scale_base  = reg_scale_base;
  assign desc_result_base = reg_result_base;

endmodule


// ############################################################################
// MODULE 3: tensor_desc_queue
// ############################################################################
//
// Buffers tile descriptors for back-to-back execution without CPU
// intervention per tile. Auto-issues next tile when controller becomes idle.
//
// Entry format: tile_descriptor_t (**41b**) + 4 × ADDR_WIDTH base addresses.
//   ⇒ ENTRY_W = 41 + 4×12 = 89（DEPTH=4）。**RTL 零改动**：ENTRY_W 早已参数化为
//     $bits(tile_descriptor_t) + 4*ADDR_WIDTH，位宽随类型自动跟随。
//   ▲订正（[3a-3] 2026-08-04）：本行原写 37b，**在 R1（37→39）那一代就已经错了**，
//     不是 3a-3 才失效的。3a-3 同时把它更到 41b。面积影响（87→89 ⇒ +8 flop）
//     🔴 **只记账不出数**：3d delta-synth 禁跑窗口仍开，未综合未测量，
//     禁止给任何 3a-3 的面积/时序数字，也禁止用「只加 2 位可忽略」替代测量。
// ============================================================================

module tensor_desc_queue
  import tensor_pkg::*;
#(
  parameter int DEPTH      = 4,
  parameter int ADDR_WIDTH = 12
) (
  input  logic               clk,
  input  logic               rst_n,

  // ---- Write port (from cmd_decoder) ----
  input  logic               wr_valid,
  output logic               wr_ready,
  input  tile_descriptor_t   wr_desc,
  input  logic [ADDR_WIDTH-1:0] wr_wgt_base,
  input  logic [ADDR_WIDTH-1:0] wr_act_base,
  input  logic [ADDR_WIDTH-1:0] wr_scale_base,
  input  logic [ADDR_WIDTH-1:0] wr_result_base,

  // ---- Read port (to controller + operand_fetch + scale_buffer) ----
  output logic               rd_valid,
  input  logic               rd_ready,       // Dequeue: controller accepts
  output tile_descriptor_t   rd_desc,
  output logic [ADDR_WIDTH-1:0] rd_wgt_base,
  output logic [ADDR_WIDTH-1:0] rd_act_base,
  output logic [ADDR_WIDTH-1:0] rd_scale_base,
  output logic [ADDR_WIDTH-1:0] rd_result_base,

  // ---- Status ----
  output logic [$clog2(DEPTH+1)-1:0] fill_level,
  output logic               full,
  output logic               empty
);

  localparam int PTR_W   = $clog2(DEPTH);
  localparam int CNT_W   = $clog2(DEPTH + 1);
  localparam int ENTRY_W = $bits(tile_descriptor_t) + 4 * ADDR_WIDTH;

  // Storage
  logic [ENTRY_W-1:0] mem [DEPTH];

  // Pack/unpack helpers
  logic [ENTRY_W-1:0] wr_packed;
  logic [ENTRY_W-1:0] rd_packed;

  assign wr_packed = {wr_desc, wr_wgt_base, wr_act_base, wr_scale_base, wr_result_base};

  // Unpack read data
  always_comb begin
    {rd_desc, rd_wgt_base, rd_act_base, rd_scale_base, rd_result_base} = rd_packed;
  end

  // Pointers and count
  logic [PTR_W-1:0] wr_ptr_q, rd_ptr_q;
  logic [CNT_W-1:0] count_q;

  assign full       = (count_q == DEPTH[CNT_W-1:0]);
  assign empty      = (count_q == '0);
  assign wr_ready   = !full;
  assign rd_valid   = !empty;
  assign fill_level = count_q;
  assign rd_packed  = mem[rd_ptr_q];

  function automatic logic [PTR_W-1:0] ptr_next(logic [PTR_W-1:0] ptr);
    return (ptr == PTR_W'(DEPTH - 1)) ? '0 : ptr + {{(PTR_W-1){1'b0}}, 1'b1};
  endfunction

  logic do_write, do_read;
  assign do_write = wr_valid && wr_ready;
  assign do_read  = rd_valid && rd_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q <= '0;
      rd_ptr_q <= '0;
      count_q  <= '0;
    end else begin
      unique case ({do_write, do_read})
        2'b11: begin
          mem[wr_ptr_q] <= wr_packed;
          wr_ptr_q <= ptr_next(wr_ptr_q);
          rd_ptr_q <= ptr_next(rd_ptr_q);
        end
        2'b10: begin
          mem[wr_ptr_q] <= wr_packed;
          wr_ptr_q <= ptr_next(wr_ptr_q);
          count_q  <= count_q + {{(CNT_W-1){1'b0}}, 1'b1};
        end
        2'b01: begin
          rd_ptr_q <= ptr_next(rd_ptr_q);
          count_q  <= count_q - {{(CNT_W-1){1'b0}}, 1'b1};
        end
        default: ;
      endcase
    end
  end

endmodule


// ############################################################################
// MODULE 4: tensor_status_csr
// ############################################################################
//
// CPU-visible read-only status registers + performance counters.
//
// Register map (read-only, byte offsets from Tensor CSR base):
//   0x00 STATUS       [0] busy, [1] done_latch, [2] scan_busy, [7:4] mode
//   0x04 K_CURSOR     [15:0] dense_k_cursor
//   0x08 QUEUE_LEVELS [2:0] RETIRED -> tied 0 (sparse ingress queue 随规格 §4.1 K 令牌通路退役，
//                           [3a-1] 2026-08-02)，[3] rsvd0，[6:4] desc_queue_level (LIVE，驱动链未断)，
//                           [31:7] rsvd0。
//        🔴 字段级退役，非寄存器级：规格 §5.2 只写「QUEUE_LEVELS 随队列退役 tie-0」，按寄存器名
//           理解会把仍活着的 desc_queue_level 一并打死（§14 吸收对表 missed/27）。
//        🔴 读写不对称：同址【写】侧属 tensor_cmd_decoder（0x08 = exec/n_cfg/RESERVED bit4），
//           与本读口无关；n_cfg 无读回口（规格 §5.2 已如实登记）。
//   0x0C ISSUE_COUNT  [31:0] total issue_en cycles
//   0x10 STEP_COUNT   [31:0] total array_step_en cycles
//   0x14 SCALE_TICKS  [31:0] total mx_scale_tick pulses
//   0x18 TILE_COUNT   [31:0] total tiles completed
//   0x1C ERROR_FLAGS  —— 🔴 字段级口径（3a-7/P4 2026-08-06，裁决 blocker B7）：
//     [0] epoch_mismatch (sticky) —— 🔴 **产生式未接**：tensor_unit_top 把
//         .err_epoch_mismatch tie 到 1'b0（该文件的 D.10 实例）⇒ **恒读 0，本 tapeout
//         不可用**（PROJECT_RULES §5.0d 型 14）。拆除**归 3a-8**，3a-7 全片禁碰那两行。
//     [1] mode_mismatch (sticky)  —— 同上，同样 tie 1'b0，同样归 3a-8。
//     [2] desc_reject (sticky)    —— **LIVE**（3a-7/P4 落地）。tensor_cmd_decoder 在
//         start 那一拍算 `!is_valid_descriptor(desc_out)` 并拉高 err_desc_reject。
//         🔴 **仅 tensor_unit_top 层可观测**：tensor_domain_top 及以上**无读通路**
//         （:242 读地址硬接 8'd0、:306 读数据进 _unused）⇒ 措辞只许写
//         「MMIO 拒在 TB 层可观测」，**禁写「固件可读回」**。
//         🔴 且 P5 之前**非法描述符照样入队**（desc_push_valid 未加门）⇒ **禁写「已拒收」**。
//     [31:3] 未定义，读回 0。
//   🔴 **读写地址不对称**：0x1C 在【读】口是本 ERROR_FLAGS，在【写】口是 SCL_BASE
//     （tensor_cmd_decoder 的 8'h1C 分支）。两者是不同的寄存器，别混。
//   🔴 **清位口**：三个 sticky 位只能由 rst_n 或 counter_clear 清。而 counter_clear 在
//     tensor_domain_top:244 被 tie 0 ⇒ **集成层无固件清位口**（已登记，不在本片修）。
// ============================================================================

module tensor_status_csr
  import tensor_pkg::*;
(
  input  logic               clk,
  input  logic               rst_n,

  // ---- MMIO Read Interface ----
  input  logic [7:0]         mmio_rd_addr,
  output logic [31:0]        mmio_rd_data,

  // ---- From tile controller ----
  input  logic               ctrl_busy,
  input  logic               ctrl_done,
  input  logic [15:0]        dense_k_cursor,
  input  tensor_mode_e          current_mode,

  // [3a-1 S2 2026-08-03] `// ---- From array ----` 段的 sparse_queue_level 端口已删
  //   （读口 0x08[2:0] 已在 S0 字段级 tie 0；产生方 mac_array 的队列本步删除）

  // ---- From desc_queue ----
  input  logic [2:0]         desc_queue_level,

  // ---- From writeback unit ----
  input  logic               wb_busy,

  // ---- Performance counter inputs ----
  input  logic               issue_en,
  input  logic               array_step_en,
  input  logic               mx_scale_tick,

  // ---- Error flags ----
  input  logic               err_epoch_mismatch,
  input  logic               err_mode_mismatch,
  // [3a-7/P4 2026-08-06] 描述符拒收（来自 tensor_cmd_decoder，规格 §5.4）。
  //   🔴 与上面两个不同：本输入**有真产生式**（见 unit_top 的 D.10 连线），
  //      不是 tie 1'b0。上面两个是型 14，拆除归 3a-8 —— **别顺手一起拆**。
  input  logic               err_desc_reject,

  // ---- Counter clear ----
  input  logic               counter_clear
);

  // Performance counters
  logic [31:0] issue_count_q;
  logic [31:0] step_count_q;
  logic [31:0] scale_tick_count_q;
  logic [31:0] tile_count_q;

  // Sticky flags
  logic done_latch_q;
  logic err_epoch_q;
  logic err_mode_q;
  logic err_desc_q;   // [3a-7/P4] 0x1C bit[2]

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      issue_count_q      <= 32'd0;
      step_count_q       <= 32'd0;
      scale_tick_count_q <= 32'd0;
      tile_count_q       <= 32'd0;
      done_latch_q       <= 1'b0;
      err_epoch_q        <= 1'b0;
      err_mode_q         <= 1'b0;
      err_desc_q         <= 1'b0;
    end else if (counter_clear) begin
      issue_count_q      <= 32'd0;
      step_count_q       <= 32'd0;
      scale_tick_count_q <= 32'd0;
      tile_count_q       <= 32'd0;
      done_latch_q       <= 1'b0;
      err_epoch_q        <= 1'b0;
      err_mode_q         <= 1'b0;
      err_desc_q         <= 1'b0;
    end else begin
      if (issue_en)      issue_count_q      <= issue_count_q + 32'd1;
      if (array_step_en) step_count_q       <= step_count_q + 32'd1;
      if (mx_scale_tick) scale_tick_count_q <= scale_tick_count_q + 32'd1;
      if (ctrl_done) begin
        tile_count_q <= tile_count_q + 32'd1;
        done_latch_q <= 1'b1;
      end
      // Sticky errors
      if (err_epoch_mismatch) err_epoch_q <= 1'b1;
      if (err_mode_mismatch)  err_mode_q  <= 1'b1;
      if (err_desc_reject)    err_desc_q  <= 1'b1;
    end
  end

  // Read MUX
  always_comb begin
    unique case (mmio_rd_addr)
      8'h00:   mmio_rd_data = {24'd0, current_mode, wb_busy, done_latch_q, ctrl_busy};
      8'h04:   mmio_rd_data = {16'd0, dense_k_cursor};
      8'h08:   mmio_rd_data = {25'd0, desc_queue_level, 4'd0};   // [3a-1] [2:0] RETIRED, [6:4] LIVE
      8'h0C:   mmio_rd_data = issue_count_q;
      8'h10:   mmio_rd_data = step_count_q;
      8'h14:   mmio_rd_data = scale_tick_count_q;
      8'h18:   mmio_rd_data = tile_count_q;
      8'h1C:   mmio_rd_data = {29'd0, err_desc_q, err_mode_q, err_epoch_q};
      default: mmio_rd_data = 32'd0;
    endcase
  end

endmodule


// ############################################################################
// MODULE 5: tensor_operand_fetch
// ############################################################################
//
// Generates SRAM read requests for weight and activation data based on
// the tile descriptor and controller phase signals.
//
// Two phases:
//   LOAD_WEIGHT: Sequential reads, one address per cycle for COLS cycles.
//                Each read returns COLS weight elements → weight_in[COLS].
//   COMPUTE:     Each issue_en cycle, read one address of activation data.
//                Each read returns ROWS activation elements → act_in[ROWS].
//
// Address generation:
//   weight: wgt_base + cycle_count  (during LOAD_WEIGHT)
//   act:    act_base + act_offset   (during COMPUTE, increments on issue_en)
// ============================================================================

module tensor_operand_fetch
  import tensor_pkg::*;
#(
  parameter int ROWS       = 16,
  parameter int COLS       = 16,
  parameter int DATA_WIDTH = 16,
  parameter int ADDR_WIDTH = 12
) (
  input  logic               clk,
  input  logic               rst_n,

  // ---- Tile configuration (from desc_queue) ----
  input  logic               tile_active,
  input  logic [ADDR_WIDTH-1:0] wgt_base_addr,
  input  logic [ADDR_WIDTH-1:0] act_base_addr,

  // ---- OS-GEMM (HW-REVIEW T1) ----
  //
  // dataflow_sel : 0 = Output-Stationary (weights STREAM during COMPUTE,
  //                symmetric with activations) ; 1 = Weight-Stationary (original
  //                LOAD_WEIGHT preload). k_total is the tile's contraction length,
  //                used by the OS zero-pad: indices >= k_total drive the operand
  //                boundary to 0 so the extended accumulate/drain window is inert
  //                and the skew chains flush between tiles.
  input  logic               dataflow_sel,
  input  logic [15:0]        k_total,

  // ---- [3a-4/M1] act 腿越界判据的 cursor 基（规格 §4.2 per-leg 拆分）----
  //
  // controller 的 `dense_k_cursor_q` 直通视图（`tensor_tile_controller.sv:1012`）。
  // 为什么 act 腿要换成它：`act_offset_q` 是**读序号**（每 issue +1），而 `k_total`
  // 的口径是 **dense 元素数**（`tensor_pkg.sv` 的 `k_total` 注释：dense element count）
  // —— 两者只在 `dense_pack_advance(mode) == 1`（BF16）时同单位。cursor 按
  // `pack_advance` 推进，与 `k_total` 天然同单位 ⇒ packed 模式（FP8/MXFP8 返 2、
  // FP4/MXFP4/UINT4_SIMD 返 4）下判据才正确。
  // 🔴 **本输入同时关闭 `Review/HANDOFF.md:16`（2026-06-21）登记的「零填充阈值是
  //    dense-K（仅 pack=1 正确）」限制** —— 该限制的 SSOT 漂移（controller 注释与
  //    `Review/Tensor_GEMM_Rewire_Plan.md §6` 只写了「partial last-K 组不重掩」、
  //    漏了阈值那半句）随本片一并回填。
  // 🔴 dense 逐位恒等是**构造性**的，不是巧合：`issue_en(t)` 注册自 `issue_d(t-1)`
  //    而 `issue_d` 建在**次态**上 ⇒ `issue_en(t) == (state_q(t)==ST_COMPUTE) && !k_done(t)`，
  //    与 controller `:628/:634` 推进 cursor 的门控**逐字同式**；两者复位点也同拍
  //    （cursor 在 ST_IDLE 每拍清零、offset 在 tile_start 脉冲清零）。
  //    DRAIN 期两者分叉（issue_en 在 OS DRAIN 恒高、offset 继续加；cursor 冻结在
  //    k_total），但双双落在越界侧 ⇒ `< k_total` 谓词逐拍相同。
  input  logic [15:0]        dense_k_cursor,

  // ---- [3a-4/M4] B3/B5 权重腿稀疏上界的两个描述符视图 ----
  //
  // `sparse_mode` 选臂、`n_cfg` 定 N（经 `ncfg_survivors()`），合成 `wgt_k_bound`。
  // 两者都取自 controller 的 latched 描述符（`ctrl_tile_desc_active`），整个 tile 稳定。
  //
  // 🔴🔴 **这两个输入漏接是【纯静默】的** ——
  //    必须显式登记，因为它决定了本级的闭包判据不能是仿真闸：
  //      · 漏接读 0 = `EXEC_DENSE` / `NCFG_DENSE` ⇒ 走 dense 臂 ⇒ 上界仍 `< k_total`
  //        ⇒ **R1 逐位全绿、N=4 探针也全绿**（PROJECT_RULES §5.0f 第 2 行：
  //        `PINMISSING` 被 elaborate_smoke 与 tb/Makefile **双双** `-Wno-` 吞掉，
  //        加 `-Wall` 也看不见）。
  //      · ~~对照：`dense_k_cursor` 漏接读 0 ⇒ `act_in_range_d` 恒真 ⇒ 零填充整体失效
  //        ⇒ R1 八形状全红，**响亮**。~~
  //        🔴🔴 **▲[M7 完整性审计订正 —— 本句已被 M4 mutation 臂 5 实测推翻]**：
  //        断开 `dense_k_cursor` 实测 **R1 `TESTS=6 PASS=6` 全绿**
  //        （`aichip_run_logs/s3a45_m4_mut_5_20260806.log`）—— per-leg 拆分后 dense 臂
  //        两腿上界**都是 `k_total`**，DRAIN 尾窗里权重腿自己就把乘积压成 0
  //        ⇒ act 腿失效被完全掩盖。抓得住它的只有 M4 的稀疏探针（`..._mut_5b_...log`）。
  //        ⇒ 🔴 **本模块【没有任何一个输入端口】的漏接是被 R1 抓得住的，三个全是静默的**
  //        —— 上面那句「性质相反」的对照**不成立**，`sparse_mode`/`n_cfg` 与
  //        `dense_k_cursor` 是**同类**。唯一定义处 = 预登记 §5.1。
  //        （本处是该失实文字的**第 5 处**，由 M7 完整性审计的全仓复扫抓到 ——
  //          M6′ 后审订三处、M7 审计补第 4 处，都以为扫全了。**教训：grep 全仓，别凭记忆。**）
  //    ⇒ 本对端口的唯一守门 = **§5.0f 推论 2 的静态自检 + 红臂**（`-Wall` 且去掉
  //      `-Wno-PINMISSING`，用现役靶的 18 源清单，并带 `^%Warning` 计数 sanity 行）。
  //      落盘 = `aichip_run_logs/s3a45_m4_lint_20260806.txt`。
  input  exec_sparse_mode_e  sparse_mode,
  input  ncfg_e              n_cfg,

  // ---- Phase control (from tile controller) ----
  input  logic               weight_load_en,     // High during LOAD_WEIGHT
  input  logic               issue_en,            // Valid compute cycle
  input  logic               tile_start,          // Pulse: new tile beginning

  // ---- SRAM read interface (to sram_wrapper) ----
  output logic               wgt_rd_en,
  output logic [ADDR_WIDTH-1:0] wgt_rd_addr,
  input  logic [DATA_WIDTH-1:0] wgt_rd_data [COLS],
  input  logic               wgt_rd_valid,

  output logic               act_rd_en,
  output logic [ADDR_WIDTH-1:0] act_rd_addr,
  input  logic [DATA_WIDTH-1:0] act_rd_data [ROWS],
  input  logic               act_rd_valid,

  // ---- To array boundary ----
  output logic [DATA_WIDTH-1:0] weight_out [COLS],
  output logic               weight_valid_out,
  output logic [DATA_WIDTH-1:0] act_out    [ROWS],
  output logic               act_valid_out
);

  // Index counters. 16-bit (NOT ADDR_WIDTH=12) so the zero-pad comparison against
  // the 16-bit k_total cannot wrap: in OS the offset advances through the whole
  // K + ROWS + COLS - 1 window, which for K near SRAM depth (e.g. K=4096) exceeds
  // 12 bits — a truncated counter would alias back below k_total in the drain tail
  // and re-admit real SRAM rows (HW-REVIEW T1 finding [1]). The SRAM ADDRESS is the
  // low ADDR_WIDTH bits of base+offset (a high-offset tail read wraps the address
  // harmlessly because its data is zero-padded anyway).
  logic [15:0] wgt_offset_q;
  logic [15:0] act_offset_q;

  // F1 (HW-REVIEW T1): in OS the weight STREAMS during COMPUTE — its read enable
  // and offset advance on issue_en, symmetric with the activation. In WS the
  // original LOAD_WEIGHT preload (advance on weight_load_en) is preserved exactly.
  logic wgt_advance;
  assign wgt_advance = dataflow_sel ? weight_load_en : issue_en;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wgt_offset_q <= '0;
      act_offset_q <= '0;
    end else if (tile_start) begin
      wgt_offset_q <= '0;
      act_offset_q <= '0;
    end else begin
      if (wgt_advance)
        wgt_offset_q <= wgt_offset_q + 16'd1;
      if (issue_en)
        act_offset_q <= act_offset_q + 16'd1;
    end
  end

  // SRAM read requests (address = low ADDR_WIDTH bits of base + offset)
  assign wgt_rd_en   = wgt_advance && tile_active;
  assign wgt_rd_addr = wgt_base_addr + wgt_offset_q[ADDR_WIDTH-1:0];
  assign act_rd_en   = issue_en && tile_active;
  assign act_rd_addr = act_base_addr + act_offset_q[ADDR_WIDTH-1:0];

  // ---- OS zero-pad (HW-REVIEW T1) -----------------------------------------
  // The OS-GEMM accumulate window runs K + ROWS + COLS - 1 issue cycles; the
  // K..K+ROWS+COLS-2 tail (and the head bubble) must present ZERO operands so
  // the extended window adds nothing and the depth-(ROWS+COLS-2) skew/hop chains
  // flush to 0 for the next tile. in_range is computed at READ time (index <
  // k_total, and a read actually fired) and registered on the ISSUE that fired
  // the read, aligning with the 1-cycle SRAM read latency. WS is untouched
  // (no zero-pad).
  // 🔴 [3a-4/M1 订正] 原文这里写的是「In OS both offsets advance on issue_en, so
  //    act_offset_q indexes both operands」—— 那是**拆分前**的形态（一根 in_range_d
  //    同管两腿）。本片按规格 §4.2 做了 per-leg 拆分：act 腿改 cursor 基、wgt 腿用
  //    自己的 wgt_offset_q，两腿各有 in_range 与 zero_pad。详见下方拆分段。
  //    「两个 offset 在 OS 下同步推进」这条事实**仍然为真**，它正是 wgt 腿逐位零扰的依据。
  //
  // NEW-1 fix (2026-07-24, C6 preflight): HOLD between issues instead of
  // free-running. The old free-running form (`in_range_d <= issue_en && ...`
  // every cycle) read 0 on the first array step after an EXEC_SPARSE_STRUCT
  // frag stall, so os_zero_pad masked the REAL operand row still held in the
  // SRAM dout register — one row silently dropped (replaced by zero) per stall
  // event. Proven by tb/test_tensor_sparse_stall (mismatch == golden minus
  // exactly the in-flight rows).
  // 🔴 [3a-1 S1 2026-08-02 连坐，S2 补记] 该红证载体已改名 `tb/pending_test_tensor_sparse_stall.py`
  //    并退出 `run_all.py:20` 的 glob ⇒ **本修复自 S1 起无现役守门**（红证仍在案，
  //    机理文档见下一行）。复活条件 = 3c 金标重写 + 新 harness。
  // Dense/WS-invariant: dense issues every
  // COMPUTE+DRAIN cycle (gated == free-running), the DRAIN bank-wait holds an
  // already-0 value, and WS never applies os_zero_pad (dataflow_sel gate).
  // Full mechanism: Review/C6_Preflight_ValidQual_SparseStall_2026-07-24.md §3.
  // ---- [3a-4/M1] per-leg 拆分（规格 §4.2）------------------------------------
  //
  // 拆之前：**一根 `in_range_d` 同管两腿**，且两腿都用 `act_offset_q` —— 在 OS 下
  // 「碰巧」正确（`wgt_advance == issue_en` ⇒ `wgt_offset_q ≡ act_offset_q`），
  // 但它把两件不同的事焊死在一起，M4 要给权重腿换上界 `⌈K/4⌉×N` 时就无处下刀。
  // 拆之后两腿各有自己的判据源：
  //   · act 腿 -> **cursor 基**（与 `k_total` 同单位，见端口注释；M1 改）
  //   · wgt 腿 -> **自己的 `wgt_offset_q`**，~~上界仍是**原始 `k_total`**（本片不动语义）~~
  // ~~🔴 **权重腿上界换成 `⌈K/4⌉×N`（经 `ncfg_survivors()`）归 M4，本片禁碰**~~
  //    ▲**[3a-4/M4 2026-08-03] 已兑现**（原文划掉保留）：稀疏臂上界 = `⌈K/4⌉ × N`，
  //    N 经 `ncfg_survivors(n_cfg)` 取（见下方 B3/B5 段）。
  // 🔴 **dense 臂两腿判据都必须保持 `< k_total`**（丁案 B5，**这一条有 R1 牙**：
  //    套用统一式会让 K%4≠0 的 R1 形状当场 `!= golden` —— 机理是 dense 臂 cursor 停在
  //    K 而非 Kp，DRAIN 的 34 拍里 act 腿若也放宽到 Kp 就不再强零，真实垃圾行被累加。
  //    该机理由 M4 的 mutation 红臂 1 实测确认，负控 = 红臂 1′）。
  // 🔴 两腿都**保留 NEW-1 的 HOLD 结构**（`else if (issue_en)`，不是自由跑）——
  //    自由跑形态会在 stall 后的首个 array step 上读 0、把仍驻留在 SRAM dout 寄存器里
  //    的真实操作数行静默替换成零（机理见上方 NEW-1 段）。
  // dense-OS 零扰证明：`wgt_offset_q ≡ act_offset_q`（同复位、同 `issue_en` 推进）
  //    ⇒ wgt 腿逐位不变；act 腿见端口注释的相位证明 ⇒ 两腿都逐位不变。
  //    WS 下两腿的 `*_zero_pad` 都被 `dataflow_sel == 1'b0` 门掉 ⇒ 亦零扰。
  // ---- [3a-4/M4] B3/B5 —— 权重腿的稀疏上界 ⌈K/4⌉ × N -------------------------
  //
  // 结构化 N:M（M=4）下权重是**压实存放**的：每个 M=4 窗口只存 N 个存活元素
  // ⇒ 权重 SRAM 里的真实行数 = ⌈K/4⌉ × N，而不是 K。超出这个行数的读都是垃圾，
  // 必须强零。act 侧不压实（激活是稠密的），所以 act 腿的上界仍是 dense 的 `k_total`
  // —— 两腿口径不同正是 M1 把 `in_range_d` 拆成两根的原因。
  //
  // 🔴 N **一律经 `ncfg_survivors()` 取，禁 open-code**（用户 2026-08-04 拍板；
  //    纪律锚 `tensor_tile_controller.sv:288`）。散落的 open-code 是 §5.0d 型 15 的温床。
  // 🔴 **dense 臂逐字保持 `< k_total`**（丁案 B5，有 R1 牙）—— 不是保守，是正确性：
  //    n_cfg=NCFG_DENSE 时 `⌈K/4⌉×4 = Kp ≥ K`，K%4≠0 时统一式会把 [K, Kp) 段放行。
  //
  // 🔴🔴 **本片诚实登记：本改动「落地未通电」。** N=4（探针的 NCFG_DENSE 配置）下
  //    `⌈K/4⌉×4 = Kp`，而 act 腿在 [K, Kp) 已强零 ⇒ 乘积恒 0 ⇒ **权重腿放不放宽，
  //    数值与拍数都一样**。真正消费本上界的是 N=2（M5′ 起）。
  //    ⇒ 本片对它的守门只有三条：① 端口静态自检（§5.0f 推论 2，见下方端口注释）
  //    ② mutation 红臂 1（两腿一起误写 ⇒ R1 四例红，证明 dense 臂 `< k_total` 承重）
  //    ③ 红臂 1′ 负控（只放宽权重腿 ⇒ 预计 8/8 全绿）。**禁称「权重腿上界已验证」。**
  logic [15:0] wgt_k_bound;
  assign wgt_k_bound = (sparse_mode == EXEC_SPARSE_STRUCT)
                     ? (((k_total + 16'd3) >> 2) * {13'd0, ncfg_survivors(n_cfg)})
                     : k_total;

  logic act_in_range_d;
  logic wgt_in_range_d;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      act_in_range_d <= 1'b0;
      wgt_in_range_d <= 1'b0;
    end else if (tile_start) begin
      act_in_range_d <= 1'b0;
      wgt_in_range_d <= 1'b0;
    end else if (issue_en) begin
      // 🔴 act 腿【逐字不动】：controller 的稀疏臂自 M4 起跑到 Kp，cursor 落在
      //    [K, Kp) 的 pad 拍全靠本行强零 —— 改它就破了「pad 拍数值惰性」，
      //    探针的数值双通道会当场红。
      act_in_range_d <= (dense_k_cursor < k_total);  // cursor 基，与 k_total 同单位
      wgt_in_range_d <= (wgt_offset_q   < wgt_k_bound);  // [3a-4/M4] per-arm 上界
    end
  end

  logic act_zero_pad;
  logic wgt_zero_pad;
  assign act_zero_pad = (dataflow_sel == 1'b0) && !act_in_range_d;
  assign wgt_zero_pad = (dataflow_sel == 1'b0) && !wgt_in_range_d;

  // Passthrough (+ OS zero-pad): SRAM read data → array boundary.
  // 1-cycle latency from SRAM read → valid data.
  always_comb begin
    for (int c = 0; c < COLS; c++)
      weight_out[c] = wgt_zero_pad ? '0 : wgt_rd_data[c];
    for (int r = 0; r < ROWS; r++)
      act_out[r]    = act_zero_pad ? '0 : act_rd_data[r];
  end
  assign weight_valid_out = wgt_rd_valid;
  assign act_valid_out    = act_rd_valid;

endmodule


// ############################################################################
// MODULE 6: tensor_scale_buffer
// ############################################################################
//
// Manages MX scale metadata independently from payload data.
// Fetches scale values from SRAM at MX block boundaries and drives
// the array's scale sideband inputs.
//
// Protocol:
//   1. On tile_start (if MX mode): fetch first block of scales.
//   2. On each mx_scale_tick: fetch next block of scales.
//   3. Scale data is broadcast to all COLS (weight) / ROWS (act) ports.
//   4. Valid signals pulse for 1 cycle when new scale data arrives.
//
// This module realizes the paper's "scale metadata as first-class citizen"
// by providing a dedicated fetch path with independent address tracking.
// ============================================================================

module tensor_scale_buffer
  import tensor_pkg::*;
#(
  parameter int ROWS       = 16,
  parameter int COLS       = 16,
  parameter int ADDR_WIDTH = 12
) (
  input  logic               clk,
  input  logic               rst_n,

  // ---- Tile configuration ----
  input  logic               mx_mode_active,
  input  logic [ADDR_WIDTH-1:0] scale_base_addr,
  input  logic               tile_start,

  // ---- Scale tick from controller ----
  input  logic               mx_scale_tick,

  // ---- SRAM read interface (to sram_wrapper) ----
  output logic               scale_rd_en,
  output logic [ADDR_WIDTH-1:0] scale_rd_addr,
  input  logic [7:0]         scale_rd_data_wgt [COLS],
  input  logic [7:0]         scale_rd_data_act [ROWS],
  input  logic               scale_rd_valid,

  // ---- To array scale sideband ----
  output logic [7:0]         weight_scale_out   [COLS],
  output logic               weight_scale_valid [COLS],
  output logic [7:0]         act_scale_out      [ROWS],
  output logic               act_scale_valid    [ROWS]
);

  // Scale block address counter
  logic [ADDR_WIDTH-1:0] scale_offset_q;
  logic                  fetch_pending_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      scale_offset_q  <= '0;
      fetch_pending_q <= 1'b0;
    end else if (tile_start) begin
      scale_offset_q  <= '0;
      fetch_pending_q <= mx_mode_active;  // Fetch first block if MX mode
    end else begin
      if (mx_scale_tick && mx_mode_active) begin
        // Next MX block boundary — advance address and request fetch
        scale_offset_q  <= scale_offset_q + ADDR_WIDTH'(1);
        fetch_pending_q <= 1'b1;
      end else if (fetch_pending_q && scale_rd_valid) begin
        fetch_pending_q <= 1'b0;  // Fetch complete
      end
    end
  end

  // SRAM read request: on tile_start (first block) or mx_scale_tick (subsequent)
  assign scale_rd_en   = (tile_start && mx_mode_active)
                       || (mx_scale_tick && mx_mode_active);
  assign scale_rd_addr = scale_base_addr + scale_offset_q;

  // Drive array scale ports when SRAM returns valid data
  always_comb begin
    for (int c = 0; c < COLS; c++) begin
      weight_scale_out[c]   = scale_rd_data_wgt[c];
      weight_scale_valid[c] = scale_rd_valid && mx_mode_active;
    end
    for (int r = 0; r < ROWS; r++) begin
      act_scale_out[r]   = scale_rd_data_act[r];
      act_scale_valid[r] = scale_rd_valid && mx_mode_active;
    end
  end

endmodule


// ############################################################################
// ############################################################################
// MODULE 7: tensor_native_store_unit (R8 Task A — REFACTORED)
// ############################################################################
//
// Previously: tensor_writeback_unit (v4.2c legacy). REFACTORED in Round E1 /
// Task A as part of the Vector Unit OFU Sidecar Migration.
//
// See:
//   Vector_Unit_OFU_Sidecar_Design_Plan.md §5.5   (design specification)
//   Tensor_Unit_Design_Rationale.md    D23 / D24 / D26
//   Phase_E1_Continuation_Task_List.md Task A   (scope and rationale)
//
// ----------------------------------------------------------------------------
// Purpose
// ----------------------------------------------------------------------------
//
// This module implements the Tensor Unit's Class B (Store-Native) result flow.
// It consumes block-float row fragments from tensor_egress_fragmentizer and
// writes them to the SRAM native region as tensor_native_capsule_t records,
// fully converter-free.
//
// Contract:
//   INPUT  : fp_acc_output_t      — internal block-float accumulator state
//   OUTPUT : tensor_native_capsule_t — architectural 64-bit storage format
//   GATING : out_class == OUT_STORE_NATIVE (Class B only)
//
// All other out_class values (OUT_FWD_VEC_NATIVE, OUT_ESCAPE_FMT) bypass this
// module entirely; the top-level routing MUX (tensor_unit_top R9) never
// asserts frag_valid to this module in those cases.
//
// ----------------------------------------------------------------------------
// What changed vs. legacy tensor_writeback_unit
// ----------------------------------------------------------------------------
//
//   REMOVED
//     - Inputs:  ofu_result[ROWS][COLS]   (OFU no longer inside Tensor Unit)
//                int_result[ROWS][COLS]   (INT path never used native store)
//                forward_eligible         (semantics subsumed by out_class)
//                forward_taken            (decision now in tensor_unit_top)
//                mode                     (not needed — capsule is format-agnostic)
//     - States:  WB_WAIT                  (no forward arbitration in Tensor domain)
//
//   ADDED
//     - Inputs:  out_class                (gating: engage only on OUT_STORE_NATIVE)
//                frag_data[COLS]          (consumer-side fragmentizer handshake)
//                frag_valid
//                frag_row_idx
//                frag_last_row
//     - Outputs: frag_ready               (back-pressure to fragmentizer)
//                native_wr_en             (64-bit native SRAM write)
//                native_wr_addr
//                native_wr_data[COLS]     (tensor_native_capsule_t payload)
//     - Function: pack_capsule()          (fp_acc_output_t → native capsule)
//
//   SIMPLIFIED
//     FSM: WB_IDLE → WB_ACTIVE → WB_FINISH   (3 states, was 4)
//
// ----------------------------------------------------------------------------
// FSM
// ----------------------------------------------------------------------------
//
//     +-----------+  frag_valid   +-------------+  handshake &&  +-----------+
//     |  WB_IDLE  | ------------> |  WB_ACTIVE  | -------------> |  WB_FINISH|
//     |           |  (OUT_STORE_  |             |  frag_last_row |           |
//     | ready=0   |   NATIVE      | ready=1     |                | ready=0   |
//     | busy=0    |   implicit)   | wr_en=      |                | done=1    |
//     |           |               |   handshake |                |           |
//     +-----^-----+               +-------------+                +-----+-----+
//           |                                                          |
//           +----------------------------------------------------------+
//                         unconditional (1 cycle)
//
//   Notes:
//   - WB_ACTIVE asserts frag_ready=1 every cycle; writes fire on handshake only.
//   - The fragmentizer guarantees frag_valid stays high until handshake
//     (AXI I6), so the store unit may safely delay its internal write by one
//     cycle if back-pressure is needed in the future. Current implementation
//     writes combinationally on handshake.
//   - WB_FINISH is a 1-cycle epoch marker for clean wb_done pulse generation;
//     it does NOT gate the next tile (the fragmentizer's bank_release signal
//     independently unblocks the controller's next ST_CAPTURE).
//
// ----------------------------------------------------------------------------
// Invariants (enforced by assertions)
// ----------------------------------------------------------------------------
//
//   I1. Module only engages when out_class == OUT_STORE_NATIVE.
//       In WB_IDLE, frag_valid|->(out_class == OUT_STORE_NATIVE).
//       This is the structural embodiment of Class B result flow.
//
//   I2. native_wr_en implies frag_valid && frag_ready (handshake coincidence).
//       Prevents spurious SRAM writes without a valid incoming row.
//
//   I3. WB_FINISH transitions unconditionally to WB_IDLE in the next cycle.
//       Clean 1-cycle done pulse contract.
//
//   I4. frag_ready is high only in WB_ACTIVE.
//       Prevents accidental acceptance in IDLE or FINISH.
//
// ----------------------------------------------------------------------------
// SRAM width annotation (Phase E4 future work)
// ----------------------------------------------------------------------------
//
// The native capsule is 64 bits wide per element. Each written row contains
// COLS = 16 capsules, so each native SRAM entry must be 16 × 64 = 1024 bits
// wide. The tensor_sram_wrapper currently models a 16-bit-wide bank only.
//
// For Phase E1, this module exposes a clean 64-bit-per-column write port
// (native_wr_data[COLS] carries tensor_native_capsule_t), but the actual
// native SRAM macro choice is deferred to Phase E4 (PE-level memory
// subsystem integration). In the interim, the native_wr_* signals may be
// left unconnected at the PE top level or routed to a behavioral stub.
// ============================================================================

module tensor_native_store_unit
  import tensor_pkg::*;
#(
  parameter int ROWS       = 16,
  parameter int COLS       = 16,
  parameter int ADDR_WIDTH = 12
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // =========================================================================
  // Result-flow routing gate (from tensor_unit_top's latched descriptor)
  // =========================================================================
  //
  // The top-level routing MUX already filters frag_valid so it is only ever
  // asserted to this module when out_class == OUT_STORE_NATIVE. The out_class
  // input here is defensive: it enables an internal assertion (I1) that
  // catches mis-routing bugs at their source. It MUST be held stable for the
  // full duration of a tile's row-scan (tensor_unit_top latches its own copy
  // on capture_fire to guarantee this).
  input  out_class_e              out_class,

  // =========================================================================
  // Base address (from tensor_unit_top, originally from cmd_decoder)
  // =========================================================================
  input  logic [ADDR_WIDTH-1:0]   result_base_addr,

  // =========================================================================
  // Consumer-side fragment ingress (from tensor_egress_fragmentizer, routed
  // by tensor_unit_top's egress MUX)
  // =========================================================================
  //
  // Upstream producer: tensor_egress_fragmentizer (EG_SCAN state).
  // Transport: one row of 16 fp_acc_output_t cells per handshake cycle.
  // Protocol: AXI-style valid/ready. I6 of the fragmentizer (valid-stable-
  //           until-handshake) means this module need not hurry — it can
  //           back-pressure safely via frag_ready.
  input  fp_acc_output_t          frag_data [COLS],
  input  logic                    frag_valid,
  output logic                    frag_ready,
  input  logic [3:0]              frag_row_idx,
  input  logic                    frag_last_row,

  // =========================================================================
  // Native SRAM write port (64-bit capsule × COLS, parallel write)
  // =========================================================================
  //
  // Each native SRAM entry holds one full row = 16 × 64 = 1024 bits.
  // Write address = result_base_addr + frag_row_idx (zero-extended).
  //
  // In Phase E1, this port is exposed at the tensor_unit_top boundary and is
  // expected to be terminated by a future native-region SRAM wrapper. A
  // behavioral stub is acceptable for unit-level simulation.
  output logic                    native_wr_en,
  output logic [ADDR_WIDTH-1:0]   native_wr_addr,
  output tensor_native_capsule_t  native_wr_data [COLS],

  // =========================================================================
  // Status
  // =========================================================================
  output logic                    wb_busy,
  output logic                    wb_done
);

  // ==========================================================================
  // Section 1: FSM state encoding (3 states, down from 4)
  // ==========================================================================

  typedef enum logic [1:0] {
    WB_IDLE   = 2'd0,
    WB_ACTIVE = 2'd1,   // Accepting rows from fragmentizer
    WB_FINISH = 2'd2    // 1-cycle done pulse epoch marker
  } nstore_state_e;

  nstore_state_e state_q, state_d;

  // Handshake convenience signal
  logic handshake;
  assign handshake = frag_valid & frag_ready;

  // ==========================================================================
  // Section 2: Capsule packer (pure combinational function)
  // ==========================================================================
  //
  // Converts an fp_acc_output_t (implementation type, the block-float
  // accumulator state) into a tensor_native_capsule_t (architectural type,
  // the on-SRAM storage contract).
  //
  // In Phase E1 the two types happen to share mantissa/exponent/flag fields,
  // so the packer is a field-by-field copy. The reserved 3-bit tail is
  // zero-initialized; Phase E4 may populate these with block_size / context /
  // epoch hints driven by the PE memory subsystem.
  //
  // Keep this function purely combinational (no state, no clock) so that the
  // write-side latency stays at 0 cycles and the module can be retimed
  // freely during backend implementation.

  function automatic tensor_native_capsule_t pack_capsule(fp_acc_output_t acc);
    tensor_native_capsule_t cap;
    cap.mant     = acc.mant;
    cap.exp      = acc.exp;
    cap.sign     = acc.sign;
    cap.is_nan   = acc.is_nan;
    cap.is_inf   = acc.is_inf;
    cap.reserved = 3'b000;   // Phase E4 future: block_size/context/epoch hints
    return cap;
  endfunction

  // ==========================================================================
  // Section 3: FSM next-state logic
  // ==========================================================================

  always_comb begin
    state_d = state_q;
    unique case (state_q)

      // ---- WB_IDLE ----
      // Wait for a valid fragment. The top-level MUX only asserts frag_valid
      // when out_class == OUT_STORE_NATIVE, but we check explicitly too so
      // the assertion I1 can catch mis-routing at the source.
      WB_IDLE: begin
        if (frag_valid && (out_class == OUT_STORE_NATIVE))
          state_d = WB_ACTIVE;
      end

      // ---- WB_ACTIVE ----
      // Accept rows every cycle. On the handshake that carries the last row,
      // transition to FINISH. If frag_valid drops mid-scan (shouldn't happen
      // due to fragmentizer I6, but defensive), stay in ACTIVE.
      WB_ACTIVE: begin
        if (handshake && frag_last_row)
          state_d = WB_FINISH;
      end

      // ---- WB_FINISH ----
      // 1-cycle epoch marker. Unconditional return to IDLE.
      WB_FINISH: begin
        state_d = WB_IDLE;
      end

      default: state_d = WB_IDLE;

    endcase
  end

  // ==========================================================================
  // Section 4: State register
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      state_q <= WB_IDLE;
    else
      state_q <= state_d;
  end

  // ==========================================================================
  // Section 5: Output generation (Moore-style from state + handshake)
  // ==========================================================================

  // ---- Handshake back-pressure ----
  // Ready only in ACTIVE. IDLE and FINISH do not accept data; the top-level
  // MUX is expected to not drive frag_valid while we're outside ACTIVE, but
  // this gating is the defensive inner fence.
  assign frag_ready = (state_q == WB_ACTIVE);

  // ---- Native SRAM write ----
  // Write fires only on an actual handshake, and only while active.
  // Address = result_base_addr + frag_row_idx (zero-extended to ADDR_WIDTH).
  // Capsule packing is combinational (see Section 2).
  assign native_wr_en   = (state_q == WB_ACTIVE) && handshake;
  assign native_wr_addr = result_base_addr
                        + ADDR_WIDTH'({{(ADDR_WIDTH-4){1'b0}}, frag_row_idx});

  always_comb begin
    for (int c = 0; c < COLS; c++)
      native_wr_data[c] = pack_capsule(frag_data[c]);
  end

  // ---- Status flags ----
  assign wb_busy = (state_q != WB_IDLE);
  assign wb_done = (state_q == WB_FINISH);

  // ==========================================================================
  // Section 6: Assertions (I1..I4)
  // ==========================================================================
  //
  // These encode the four module-level invariants from the header comment.
  // Violation of any indicates either a top-level routing bug or a
  // fragmentizer protocol deviation.

  // synopsys translate_off

  // --- I1: only engage on OUT_STORE_NATIVE ---
  //
  // When the module transitions out of IDLE it MUST be because out_class is
  // OUT_STORE_NATIVE. This catches routing MUX bugs in tensor_unit_top that
  // would mis-steer escape-class or forward-class fragments into the native
  // store path.
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == WB_IDLE && frag_valid) |-> (out_class == OUT_STORE_NATIVE)
  ) else $error("TENSOR_NATIVE_STORE [I1]: frag_valid with non-STORE_NATIVE out_class — routing mismatch");

  // --- I2: write-enable only on handshake ---
  //
  // A spurious native_wr_en without a completed handshake would corrupt the
  // SRAM native region with whatever is on frag_data (which may be stale or
  // zero outside EG_SCAN per fragmentizer I5).
  assert property (@(posedge clk) disable iff (!rst_n)
      native_wr_en |-> (frag_valid && frag_ready)
  ) else $error("TENSOR_NATIVE_STORE [I2]: native_wr_en asserted without handshake");

  // --- I3: WB_FINISH transitions unconditionally to IDLE next cycle ---
  //
  // Single-cycle epoch contract. Violation would stretch wb_done to multiple
  // cycles and double-count tile completions in tensor_status_csr.
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == WB_FINISH) |=> (state_q == WB_IDLE)
  ) else $error("TENSOR_NATIVE_STORE [I3]: WB_FINISH did not transition to IDLE in next cycle");

  // --- I4: frag_ready high only in WB_ACTIVE ---
  //
  // Prevents the store unit from claiming to accept data while IDLE or
  // FINISH, which would confuse the top-level routing MUX's back-pressure
  // MUX input.
  assert property (@(posedge clk) disable iff (!rst_n)
      frag_ready |-> (state_q == WB_ACTIVE)
  ) else $error("TENSOR_NATIVE_STORE [I4]: frag_ready asserted outside WB_ACTIVE");

  // synopsys translate_on

endmodule

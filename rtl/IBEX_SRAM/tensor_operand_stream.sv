// =============================================================================
// tensor_operand_stream.sv — L2 -> Tensor internal SRAM operand streamer
// (STEP4-E2E, increment 3b; design = Review/Step4_FastPath_Plan.md §9.5)
//
// The real Tensor unit reads operands from its INTERNAL weight/activation/scale
// SRAM; in the SoC those operands live in the shared L2 scratchpad. This FSM is
// the L2->SRAM repack bridge: on start it streams N_WGT weight rows, then N_ACT
// activation rows, then N_SCL scale rows, reading each from the L2 RO port (one
// 512b row/read) and writing it into the Tensor's dma_{wgt,act,scale}_wr_* ports
// (one 16-lane row/write). load_done_o gates the MMIO start FSM (operands must be
// resident before CTRL-start).
//
// Conventions (§9.5):
//   - one L2 row -> one tensor SRAM row, using the LOW 256b of the 512b read:
//       weight/act lane i (16b) = ro_rdata[i*16 +: 16]   (i = 0..LANES-1)
//       scale_wgt  lane i (8b)  = ro_rdata[i*8  +: 8]     (low 128b)
//       scale_act  lane i (8b)  = ro_rdata[128 + i*8 +: 8](next 128b)
//   - destination SRAM rows are sram_*_base + offset (these MUST equal the MMIO
//     WGT/ACT/SCL_BASE the start FSM programs — shared row space, base coupling).
//   - L2 source rows are l2_*_base + offset.
//
// L2 RO handshake: assert ro_req_o + ro_row_o, await ro_gnt_i, then (1-cycle
// later) ro_rvalid_i + ro_rdata_i; the DMA write fires in the rvalid cycle.
// =============================================================================
module tensor_operand_stream
    import pe_pkg::*;
#(
    parameter int ADDR_WIDTH = 12,        // Tensor internal SRAM row address
    parameter int DATA_WIDTH = 16,        // lane width (16b)
    parameter int LANES      = 16         // COLS == ROWS == 16
) (
    input  logic                       clk_i,
    input  logic                       rst_ni,

    // ── Control ──
    input  logic                       start_i,        // begin streaming a tile
    output logic                       busy_o,
    output logic                       load_done_o,     // pulse: all operands resident

    // ── Tile shape: rows per operand + L2 source bases + SRAM dest bases ──
    input  logic [15:0]                n_wgt_i,
    input  logic [15:0]                n_act_i,
    input  logic [15:0]                n_scl_i,
    input  logic [L2_BANK_AW-1:0]      l2_wgt_base_i,
    input  logic [L2_BANK_AW-1:0]      l2_act_base_i,
    input  logic [L2_BANK_AW-1:0]      l2_scl_base_i,
    input  logic [ADDR_WIDTH-1:0]      sram_wgt_base_i,
    input  logic [ADDR_WIDTH-1:0]      sram_act_base_i,
    input  logic [ADDR_WIDTH-1:0]      sram_scl_base_i,

    // ── L2 RO port (FULL_STRIPE_W = 512b) ──
    output logic                       ro_req_o,
    input  logic                       ro_gnt_i,
    input  logic                       ro_rvalid_i,
    output logic [L2_BANK_AW-1:0]      ro_row_o,
    input  logic [FULL_STRIPE_W-1:0]   ro_rdata_i,

    // ── Tensor DMA write ports ──
    output logic                       dma_wgt_wr_en_o,
    output logic [ADDR_WIDTH-1:0]      dma_wgt_wr_addr_o,
    output logic [DATA_WIDTH-1:0]      dma_wgt_wr_data_o      [LANES],
    output logic                       dma_act_wr_en_o,
    output logic [ADDR_WIDTH-1:0]      dma_act_wr_addr_o,
    output logic [DATA_WIDTH-1:0]      dma_act_wr_data_o      [LANES],
    output logic                       dma_scale_wr_en_o,
    output logic [ADDR_WIDTH-1:0]      dma_scale_wr_addr_o,
    output logic [7:0]                 dma_scale_wr_data_wgt_o [LANES],
    output logic [7:0]                 dma_scale_wr_data_act_o [LANES]
);
    // phase encoding
    localparam logic [1:0] PH_WGT = 2'd0, PH_ACT = 2'd1, PH_SCL = 2'd2, PH_END = 2'd3;

    typedef enum logic [2:0] { S_IDLE, S_NEXT, S_REQ, S_RESP, S_WRITE, S_DONE } state_e;
    state_e      state_q, state_d;
    logic [1:0]  phase_q, phase_d;
    logic [15:0] offset_q, offset_d;

    // registered write stage (latched on rvalid; replayed as a clean 1-cycle pulse)
    logic [FULL_STRIPE_W-1:0] rdata_q;
    logic [1:0]               wr_phase_q;
    logic [ADDR_WIDTH-1:0]    wr_addr_q;

    assign busy_o      = (state_q != S_IDLE);
    assign load_done_o = (state_q == S_DONE);

    // ── per-phase row count / source base / dest base selection ──
    logic [15:0]            n_cur;
    logic [L2_BANK_AW-1:0]  l2_base_cur;
    logic [ADDR_WIDTH-1:0]  sram_base_cur;
    always_comb begin
        unique case (phase_q)
            PH_WGT:  begin n_cur = n_wgt_i; l2_base_cur = l2_wgt_base_i; sram_base_cur = sram_wgt_base_i; end
            PH_ACT:  begin n_cur = n_act_i; l2_base_cur = l2_act_base_i; sram_base_cur = sram_act_base_i; end
            PH_SCL:  begin n_cur = n_scl_i; l2_base_cur = l2_scl_base_i; sram_base_cur = sram_scl_base_i; end
            default: begin n_cur = 16'd0;   l2_base_cur = '0;           sram_base_cur = '0;            end
        endcase
    end

    // ── L2 read request ──
    assign ro_req_o = (state_q == S_REQ);
    assign ro_row_o = l2_base_cur + L2_BANK_AW'(offset_q);

    // ── DMA write: repack the registered low 256b; en is a clean S_WRITE pulse ──
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            dma_wgt_wr_data_o[i]       = rdata_q[i*DATA_WIDTH +: DATA_WIDTH];
            dma_act_wr_data_o[i]       = rdata_q[i*DATA_WIDTH +: DATA_WIDTH];
            dma_scale_wr_data_wgt_o[i] = rdata_q[i*8 +: 8];
            dma_scale_wr_data_act_o[i] = rdata_q[(LANES*8) + i*8 +: 8];
        end
        dma_wgt_wr_addr_o   = wr_addr_q;
        dma_act_wr_addr_o   = wr_addr_q;
        dma_scale_wr_addr_o = wr_addr_q;

        dma_wgt_wr_en_o   = (state_q == S_WRITE) && (wr_phase_q == PH_WGT);
        dma_act_wr_en_o   = (state_q == S_WRITE) && (wr_phase_q == PH_ACT);
        dma_scale_wr_en_o = (state_q == S_WRITE) && (wr_phase_q == PH_SCL);
    end

    // ── FSM ──
    always_comb begin
        state_d  = state_q;
        phase_d  = phase_q;
        offset_d = offset_q;
        unique case (state_q)
            S_IDLE: if (start_i) begin
                        state_d = S_NEXT; phase_d = PH_WGT; offset_d = 16'd0;
                    end
            S_NEXT: if (phase_q == PH_END)        state_d = S_DONE;
                    else if (offset_q < n_cur)    state_d = S_REQ;
                    else begin                    // phase exhausted -> advance
                        phase_d  = phase_q + 2'd1;
                        offset_d = 16'd0;
                    end
            S_REQ:  if (ro_gnt_i)                 state_d = S_RESP;
            S_RESP: if (ro_rvalid_i)              state_d = S_WRITE;
            S_WRITE: begin                        // 1-cycle DMA write, then next row
                        offset_d = offset_q + 16'd1;
                        state_d  = S_NEXT;
                    end
            S_DONE:                               state_d = S_IDLE;
            default:                              state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q    <= S_IDLE;
            phase_q    <= PH_WGT;
            offset_q   <= 16'd0;
            rdata_q    <= '0;
            wr_phase_q <= PH_WGT;
            wr_addr_q  <= '0;
        end else begin
            state_q  <= state_d;
            phase_q  <= phase_d;
            offset_q <= offset_d;
            // latch the write payload/target when the read returns
            if (state_q == S_RESP && ro_rvalid_i) begin
                rdata_q    <= ro_rdata_i;
                wr_phase_q <= phase_q;
                wr_addr_q  <= sram_base_cur + ADDR_WIDTH'(offset_q);
            end
        end
    end
endmodule

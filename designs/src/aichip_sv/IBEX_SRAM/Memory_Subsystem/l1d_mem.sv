// =============================================================================
// l1d_mem.sv — L1 Data Memory (PE v5) — Memory 波1 Stage C: MIRROR restructure
//
// Provides "IBEX 1RW (Port A) + CP 1R (Port B) same-cycle different-address" on
// SINGLE-PORT real macros. Each of the 2 word-interleaved banks becomes an
// l1d_mirror_bank (Copy_I + Copy_C + write-consistency FIFO + bypass). See the
// adversarially-hardened design: Review/MemWave1_StageC_Hardened_Design_2026-07-22.md
// (40 findings, 12 critical, from workflow l1d-surgery-design-harden).
//
// Superseded: the pre-波1 version instantiated one sram_1rw1r_wrapper per bank and
// relied on the wrapper's behavioral TRUE dual-port — correct in sim but NOT
// synthesizable to single-port real macros (and it made the mirror mechanism
// unverifiable). This version's mirror is REAL RTL in both sim and synth.
//
// KEY CONTRACTS (hardened):
//   * Reads are 2-cycle (OUT_REG=1). cpu_rvalid / cpu_bank_sel / cp_rvalid are
//     free-running 2-deep shifts of the ACCEPTED event (never gated by stall) so
//     exactly one response lands per accepted access at fixed latency N+2.
//   * OBI is a WAITED grant: cpu_gnt_o = cpu_req & ~(write & bank-FIFO-full) &
//     ~rmw_busy. Never asserted-then-retracted. Copy_I-write + FIFO-push are ONE
//     atomic strobe gated by the same term → no Copy_I/Copy_C divergence.
//   * No byte mask on the real macro → sub-word writes (be != 4'hF) go through a
//     shared RMW FSM (read old word at N, sample at N+2, write merged full word).
//   * soft_reset flushes ONLY the CP-read valid + bypass pipes (lockstep with
//     cp_desc_fetch). FIFO / Copy_I / Copy_C SURVIVE soft_reset (SRAM persists →
//     a flush would permanently desync the mirror). Only rst_ni clears them.
//
// External interface: unchanged EXCEPT the added soft_reset_i input (threaded from
// cp_soft_reset via l1_subsystem/pe_top).
// =============================================================================

module l1d_mem
    import pe_pkg::*;
#(
    parameter int  WCFIFO_DEPTH = 8,       // write-consistency FIFO depth (L1D_WCFIFO_DEPTH)
    parameter bit  OUT_REG      = 1'b1,    // 2-cycle read (real-macro dout light-load)
    parameter bit  REAL_MACRO   = 1'b1     // PDK_ASAP7: bind real srambank_128x4x64
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        soft_reset_i,      // 波1: flush CP-read valid + bypass pipes only

    // ── Port 0: IBEX Data Access (OBI slave, 32b RW) ──
    input  logic        cpu_req_i,
    output logic        cpu_gnt_o,
    output logic        cpu_rvalid_o,
    input  logic [11:0] cpu_addr_i,      // byte address within 4KB
    input  logic        cpu_we_i,
    input  logic [3:0]  cpu_be_i,
    input  logic [31:0] cpu_wdata_i,
    output logic [31:0] cpu_rdata_o,
    output logic        cpu_err_o,

    // ── Port 1: CP Descriptor Fetch (64b parallel read) ──
    input  logic                    cp_req_i,
    input  logic [L1D_BANK_AW-1:0] cp_addr_i,     // word address (same for both banks)
    output logic [63:0]             cp_rdata_o,     // {bank1.cp_final, bank0.cp_final}
    output logic                    cp_rvalid_o
);

    localparam int AW = L1D_BANK_AW;    // 9 bits (512 words per bank)
    localparam int DW = 32;

    // =========================================================================
    // IBEX address decode (word-interleaved)
    // =========================================================================
    logic          sel_bank;            // cpu_addr[2]: 0=Bank0, 1=Bank1
    logic [AW-1:0] cpu_word_addr;       // cpu_addr[11:3]
    assign sel_bank      = cpu_addr_i[2];
    assign cpu_word_addr = cpu_addr_i[AW+2:3];

    assign cpu_err_o = 1'b0;

    // =========================================================================
    // Access classification
    // =========================================================================
    logic is_read, is_fullword_wr, is_subword_wr;
    assign is_read        = cpu_req_i & ~cpu_we_i;
    assign is_fullword_wr = cpu_req_i &  cpu_we_i & (cpu_be_i == 4'hF);
    assign is_subword_wr  = cpu_req_i &  cpu_we_i & (cpu_be_i != 4'hF);

    // Per-bank write-stall from the mirror banks (full & ~draining).
    logic wr_stall [2];
    logic wr_stall_sel;
    assign wr_stall_sel = sel_bank ? wr_stall[1] : wr_stall[0];

    // =========================================================================
    // Shared RMW FSM (IBEX is 1-outstanding → at most one live RMW)
    // =========================================================================
    typedef enum logic [1:0] { RMW_IDLE, RMW_D1, RMW_WB } rmw_state_e;
    rmw_state_e rmw_state;
    logic       rmw_busy;
    assign rmw_busy = (rmw_state != RMW_IDLE);

    // OBI waited grant (never asserted-then-retracted): hold on FIFO-full write or during RMW.
    assign cpu_gnt_o = cpu_req_i & ~rmw_busy
                     & ~((is_fullword_wr | is_subword_wr) & wr_stall_sel);

    logic cpu_accept;
    assign cpu_accept = cpu_req_i & cpu_gnt_o;

    // RMW trigger: an accepted sub-word write (gnt high implies state==IDLE via ~rmw_busy).
    logic rmw_trigger;
    assign rmw_trigger = is_subword_wr & cpu_gnt_o;

    // RMW latched fields (drive read/merge/writeback from these, never live OBI inputs).
    logic [AW-1:0] rmw_addr;
    logic [DW-1:0] rmw_wdata;
    logic [3:0]    rmw_be;
    logic          rmw_bank;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rmw_state <= RMW_IDLE;
            rmw_addr  <= '0; rmw_wdata <= '0; rmw_be <= '0; rmw_bank <= 1'b0;
        end else begin
            // RMW is IBEX-side, OUTSIDE soft_reset domain — let an in-flight RMW complete.
            unique case (rmw_state)
                RMW_IDLE: if (rmw_trigger) begin
                              rmw_addr  <= cpu_word_addr;
                              rmw_wdata <= cpu_wdata_i;
                              rmw_be    <= cpu_be_i;
                              rmw_bank  <= sel_bank;
                              rmw_state <= RMW_D1;
                          end
                RMW_D1:   rmw_state <= RMW_WB;
                RMW_WB:   rmw_state <= RMW_IDLE;
                default:  rmw_state <= RMW_IDLE;
            endcase
        end
    end

    logic rmw_wb;
    assign rmw_wb = (rmw_state == RMW_WB);

    // =========================================================================
    // Per-bank mirror instances
    // =========================================================================
    logic [DW-1:0] bank_ci_rdata [2];
    logic [DW-1:0] bank_cp_final [2];

    // RMW merged word (uses the rmw_bank's Copy_I old word, valid at N+2 = RMW_WB).
    logic [DW-1:0] rmw_old, rmw_merged;
    assign rmw_old = rmw_bank ? bank_ci_rdata[1] : bank_ci_rdata[0];
    always_comb begin
        for (int b = 0; b < 4; b++)
            rmw_merged[b*8 +: 8] = rmw_be[b] ? rmw_wdata[b*8 +: 8] : rmw_old[b*8 +: 8];
    end

    genvar gb;
    generate for (gb = 0; gb < 2; gb++) begin : g_bank
        logic          ci_rd_en;
        logic [AW-1:0] ci_rd_addr;
        logic          wr_commit_en;
        logic [AW-1:0] wr_addr;
        logic [DW-1:0] wr_data;

        // Copy_I read: a normal IBEX read OR the RMW old-word read issued at trigger (N).
        assign ci_rd_en   = (is_read & cpu_gnt_o & (sel_bank == 1'(gb)))
                          | (rmw_trigger & (sel_bank == 1'(gb)));
        assign ci_rd_addr = cpu_word_addr;

        // Atomic write commit: full-word write (immediate) OR RMW writeback (N+2).
        // Per-bank gated by the addressed bank — NEVER broadcast (cross-bank leak fix).
        assign wr_commit_en = (is_fullword_wr & cpu_gnt_o & (sel_bank == 1'(gb)))
                            | (rmw_wb & (rmw_bank == 1'(gb)));
        assign wr_addr      = (rmw_wb & (rmw_bank == 1'(gb))) ? rmw_addr  : cpu_word_addr;
        assign wr_data      = (rmw_wb & (rmw_bank == 1'(gb))) ? rmw_merged : cpu_wdata_i;

        l1d_mirror_bank #(
            .AW ( AW ), .DW ( DW ), .DEPTH ( WCFIFO_DEPTH ),
            .OUT_REG ( OUT_REG ), .REAL_MACRO ( REAL_MACRO )
        ) u_bank (
            .clk_i        ( clk_i             ),
            .rst_ni       ( rst_ni            ),
            .soft_reset_i ( soft_reset_i      ),
            .ci_rd_en     ( ci_rd_en          ),
            .ci_rd_addr   ( ci_rd_addr        ),
            .ci_rdata     ( bank_ci_rdata[gb] ),
            .wr_commit_en ( wr_commit_en      ),
            .wr_addr      ( wr_addr           ),
            .wr_data      ( wr_data           ),
            .wr_stall     ( wr_stall[gb]      ),
            .cp_req       ( cp_req_i          ),
            .cp_addr      ( cp_addr_i         ),
            .cp_final     ( bank_cp_final[gb] )
        );
    end endgenerate

    // =========================================================================
    // IBEX response pipes (free-running 2-deep shifts of the ACCEPTED event)
    // =========================================================================
    logic [1:0] cpu_rvalid_pipe;   // shift of cpu_accept → rvalid at N+2
    logic [1:0] cpu_bank_pipe;     // shift of sel_bank → read-mux select at N+2
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cpu_rvalid_pipe <= '0;
            cpu_bank_pipe   <= '0;
        end else begin
            cpu_rvalid_pipe <= {cpu_rvalid_pipe[0], cpu_accept};
            cpu_bank_pipe   <= {cpu_bank_pipe[0],   sel_bank};
        end
    end
    assign cpu_rvalid_o = cpu_rvalid_pipe[1];
    assign cpu_rdata_o  = cpu_bank_pipe[1] ? bank_ci_rdata[1] : bank_ci_rdata[0];

    // =========================================================================
    // CP response pipe (2-deep shift of cp_req; FLUSHED on soft_reset)
    // =========================================================================
    logic [1:0] cp_rvalid_pipe;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)             cp_rvalid_pipe <= '0;
        else if (soft_reset_i)   cp_rvalid_pipe <= '0;   // lockstep with cp_desc_fetch reset
        else                     cp_rvalid_pipe <= {cp_rvalid_pipe[0], cp_req_i};
    end
    assign cp_rvalid_o = cp_rvalid_pipe[1];

    // 64b assembly at the aligned N+2 stage (both halves are structurally aligned).
    assign cp_rdata_o = {bank_cp_final[1], bank_cp_final[0]};

    // =========================================================================
    // Liveness guard (sim-only): the drain relies on cp_req being structurally
    // bursty (≤50% Port-B duty at 2-cycle latency). A future zero-bubble CP
    // consumer that holds cp_req_i continuously would starve the drain and turn
    // the transient FIFO-full stall into a deadlock — fail LOUDLY here.
    // =========================================================================
    // synthesis translate_off
    // pragma translate_off
    localparam int CP_RUN_MAX = 256;   // "clearly stuck": cp_desc_fetch bubbles every 2 cyc; only a
                                       // never-bubbling consumer (or a FIFO-fill test artifact) runs long
                                       // — 256 consecutive is absurd for the real consumer, so it still
                                       // catches a genuinely stuck one without false-firing on bursts.
    logic [$clog2(CP_RUN_MAX+2)-1:0] cp_run_len;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)          cp_run_len <= '0;
        else if (!cp_req_i)   cp_run_len <= '0;
        else                  cp_run_len <= cp_run_len + 1'b1;
    end
    a_cp_bursty: assert property (@(posedge clk_i) disable iff (!rst_ni)
        cp_run_len <= CP_RUN_MAX[$clog2(CP_RUN_MAX+2)-1:0])
        else $error("l1d_mem: cp_req_i continuously high > %0d cycles — drain starvation risk (deadlock guard)", CP_RUN_MAX);
    // pragma translate_on
    // synthesis translate_on

endmodule

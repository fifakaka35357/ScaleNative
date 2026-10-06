// =============================================================================
// l1d_mirror_bank.sv — L1D single-bank MIRROR unit (Memory 波1, Stage C)
//
// Provides true "IBEX 1RW (Copy_I) + CP 1R (Copy_C) same-cycle different-address"
// using ONLY single-port real macros, per the adversarially-hardened design
// (Review/MemWave1_StageC_Hardened_Design_2026-07-22.md). This mechanism is REAL
// RTL present in BOTH sim (single-port behavioral wrapper) and synth (real macro)
// so the double gate + directed tests VERIFY it — not the old magic dual-port.
//
// STRUCTURE (per bank):
//   Copy_I : single-port wrapper. Serves IBEX read AND IBEX/RMW write. Authoritative
//            for IBEX (holds every IBEX write at accept), so IBEX needs no bypass.
//   Copy_C : single-port wrapper, TIME-MULTIPLEXED CP-read (priority) vs drain-write.
//   write-consistency FIFO (register shift array, DEPTH): every IBEX write to this
//            bank is pushed here and drained into Copy_C whenever Copy_C's port is
//            idle (~cp_req). A CP read whose address matches an in-flight write is
//            served from the FIFO via BYPASS (closes the RAW hole).
//
// CENTRAL CORRECTNESS SPINE (hardened design):
//   * Bypass {hit,data} is computed COMBINATIONALLY at the CP-read ISSUE cycle N
//     against the FIFO as it stands at N, then FROZEN and shifted EXACTLY 2 stages
//     (= read latency, OUT_REG=1) to surface at N+2 alongside Copy_C's macro output.
//     NEVER recomputed at the output stage — a drain that pops the entry at N+1
//     cannot erase the already-captured evidence.
//   * Newest-wins: tail-priority scan (ascending index, later match overwrites) +
//     per-slot occupancy mask (i<count); the this-cycle push is the youngest and
//     overrides (implements "CP sees NEW" on same-cycle write, and RMW-commit-cycle).
//   * FIFO / Copy_I / Copy_C / count SURVIVE soft_reset (SRAM content persists — a
//     flush would permanently desync the mirror). ONLY the bypass-result pipe is
//     flushed on soft_reset (lockstep with cp_desc_fetch) so a pre-reset in-flight
//     beat cannot surface post-restart. Hard rst_ni clears everything (coincides
//     with SRAM undefined → mirror re-inits consistently).
//   * DRAIN LIVENESS: drain_fire = ~cp_req & nonempty, pure combinational, every
//     qualifying cycle. Termination is provable — cp_desc_fetch is structurally
//     bursty (≤50% Port-B duty at 2-cycle latency) so drain rate ≥ push rate; the
//     FIFO-full→stall path is transient, never deadlock (guarded by a bind
//     assertion in l1d_mem: cp_req never continuously high > MAX_PAIRS).
// =============================================================================

module l1d_mirror_bank
#(
    parameter int AW         = 9,      // word-address width (512 words)
    parameter int DW         = 32,     // data width
    parameter int DEPTH      = 8,      // write-consistency FIFO depth (L1D_WCFIFO_DEPTH)
    parameter bit OUT_REG    = 1'b1,   // 2-cycle read (keeps real-macro dout light)
    parameter bit REAL_MACRO = 1'b1    // PDK_ASAP7: bind real srambank_128x4x64
) (
    input  logic          clk_i,
    input  logic          rst_ni,       // async hard reset — clears EVERYTHING
    input  logic          soft_reset_i, // flushes ONLY the bypass-result pipe

    // ── Copy_I access: IBEX read OR RMW old-word read (mutually exclusive with wr) ──
    input  logic          ci_rd_en,
    input  logic [AW-1:0] ci_rd_addr,
    output logic [DW-1:0] ci_rdata,     // 2-cycle read data

    // ── Atomic write commit: Copy_I write + FIFO push (ONE strobe) ──
    //    Driven by l1d_mem, already gated by ~wr_stall. For RMW = merged full word.
    input  logic          wr_commit_en,
    input  logic [AW-1:0] wr_addr,
    input  logic [DW-1:0] wr_data,
    output logic          wr_stall,     // full & ~draining → l1d must hold the write

    // ── CP read (shared address to both banks) ──
    input  logic          cp_req,
    input  logic [AW-1:0] cp_addr,
    output logic [DW-1:0] cp_final      // 2-cycle, bypass-corrected
);

    localparam int CW = $clog2(DEPTH + 1);   // count width (0..DEPTH)
    localparam int MW = DW / 8;

    // =========================================================================
    // Write-consistency FIFO — register shift array, index 0 = head (oldest)
    // =========================================================================
    logic [AW-1:0] fifo_addr [DEPTH];
    logic [DW-1:0] fifo_data [DEPTH];
    logic [CW-1:0] count;

    logic empty, full, nonempty;
    assign empty    = (count == '0);
    assign full     = (count == CW'(DEPTH));
    assign nonempty = ~empty;

    // Drain: pop head + write Copy_C whenever the CP port is idle and FIFO nonempty.
    logic drain_fire;
    assign drain_fire = ~cp_req & nonempty;

    // Write stall: full AND not draining this cycle (a simultaneous drain frees a slot).
    assign wr_stall = full & ~drain_fire;

    logic push, pop;
    assign push = wr_commit_en;   // l1d already gated by ~wr_stall
    assign pop  = drain_fire;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            count <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                fifo_addr[i] <= '0;
                fifo_data[i] <= '0;
            end
        end else begin
            // FIFO/count are OUTSIDE the soft_reset domain (SURVIVE) — only rst_ni clears.
            unique case ({push, pop})
                2'b10: begin  // push only (guaranteed ~full)
                    fifo_addr[count] <= wr_addr;
                    fifo_data[count] <= wr_data;
                    count <= count + 1'b1;
                end
                2'b01: begin  // pop only — shift toward head
                    for (int i = 0; i < DEPTH-1; i++) begin
                        fifo_addr[i] <= fifo_addr[i+1];
                        fifo_data[i] <= fifo_data[i+1];
                    end
                    count <= count - 1'b1;
                end
                2'b11: begin  // push+pop — shift down, new entry at (count-1), count unchanged
                    for (int i = 0; i < DEPTH-1; i++) begin
                        fifo_addr[i] <= fifo_addr[i+1];
                        fifo_data[i] <= fifo_data[i+1];
                    end
                    fifo_addr[count-1] <= wr_addr;
                    fifo_data[count-1] <= wr_data;
                end
                default: ; // 2'b00 hold
            endcase
        end
    end

    // =========================================================================
    // Bypass — computed COMBINATIONALLY at the CP-read issue cycle N
    // =========================================================================
    logic          bypass_hit_n;
    logic [DW-1:0] bypass_data_n;
    always_comb begin
        bypass_hit_n  = 1'b0;
        bypass_data_n = '0;
        // Registered FIFO entries: ascending scan → newest (highest occupied index) wins.
        for (int i = 0; i < DEPTH; i++) begin
            if ((i < count) && (fifo_addr[i] == cp_addr)) begin
                bypass_hit_n  = 1'b1;
                bypass_data_n = fifo_data[i];
            end
        end
        // This-cycle push is the YOUNGEST — overrides (CP-sees-NEW + RMW-commit-cycle).
        if (wr_commit_en && (wr_addr == cp_addr)) begin
            bypass_hit_n  = 1'b1;
            bypass_data_n = wr_data;
        end
    end

    // Freeze + align: shift {hit,data} exactly 2 stages (= read latency) to surface at N+2.
    logic          bypass_hit_q1, bypass_hit_q2;
    logic [DW-1:0] bypass_data_q1, bypass_data_q2;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            bypass_hit_q1 <= 1'b0; bypass_hit_q2 <= 1'b0;
            bypass_data_q1 <= '0;  bypass_data_q2 <= '0;
        end else if (soft_reset_i) begin
            // Flush the bypass-result pipe in lockstep with cp_desc_fetch's soft_reset
            // (data is don't-care once hit is cleared).
            bypass_hit_q1 <= 1'b0; bypass_hit_q2 <= 1'b0;
        end else begin
            bypass_hit_q1  <= bypass_hit_n;  bypass_data_q1 <= bypass_data_n;
            bypass_hit_q2  <= bypass_hit_q1; bypass_data_q2 <= bypass_data_q1;
        end
    end

    // =========================================================================
    // Copy_I — IBEX read + IBEX/RMW write (single-port wrapper, Port B tied off)
    // =========================================================================
    logic          ci_cea, ci_wea;
    logic [AW-1:0] ci_addr;
    assign ci_cea  = ci_rd_en | wr_commit_en;
    assign ci_wea  = wr_commit_en;                       // write priority (mutually exclusive w/ read)
    assign ci_addr = wr_commit_en ? wr_addr : ci_rd_addr;

    sram_1rw1r_wrapper #(
        .DEPTH ( 1 << AW ), .DW ( DW ), .OUT_REG ( OUT_REG ), .REAL_MACRO ( REAL_MACRO )
    ) u_copy_i (
        .clk_i    ( clk_i        ),
        .cea_i    ( ci_cea       ),
        .wea_i    ( ci_wea       ),
        .wmaska_i ( {MW{1'b1}}   ),   // full-word only (RMW merges sub-word before commit)
        .addra_i  ( ci_addr      ),
        .dina_i   ( wr_data      ),
        .douta_o  ( ci_rdata     ),
        .ceb_i    ( 1'b0         ),
        .addrb_i  ( '0           ),
        .doutb_o  (              )
    );

    // =========================================================================
    // Copy_C — CP read (priority) time-multiplexed with FIFO drain-write
    // =========================================================================
    logic          cc_cea, cc_wea;
    logic [AW-1:0] cc_addr;
    logic [DW-1:0] copyc_dout;
    assign cc_cea  = cp_req | drain_fire;                 // mutually exclusive by drain_fire def
    assign cc_wea  = drain_fire;                          // CP read has priority (wea=0)
    assign cc_addr = drain_fire ? fifo_addr[0] : cp_addr; // drain writes the head entry

    sram_1rw1r_wrapper #(
        .DEPTH ( 1 << AW ), .DW ( DW ), .OUT_REG ( OUT_REG ), .REAL_MACRO ( REAL_MACRO )
    ) u_copy_c (
        .clk_i    ( clk_i        ),
        .cea_i    ( cc_cea       ),
        .wea_i    ( cc_wea       ),
        .wmaska_i ( {MW{1'b1}}   ),
        .addra_i  ( cc_addr      ),
        .dina_i   ( fifo_data[0] ),   // drain writes the head entry's data
        .douta_o  ( copyc_dout   ),
        .ceb_i    ( 1'b0         ),
        .addrb_i  ( '0           ),
        .doutb_o  (              )
    );

    // Copy_C macro dout HOLDS across an intervening drain-write (dataout updates only
    // on read, and drain never shares a cycle with a CP read), so the N-sampled read
    // survives to N+2; the frozen bypass overrides it when hit.
    assign cp_final = bypass_hit_q2 ? bypass_data_q2 : copyc_dout;

endmodule

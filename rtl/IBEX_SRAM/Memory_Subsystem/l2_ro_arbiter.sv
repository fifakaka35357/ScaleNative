// =============================================================================
// l2_ro_arbiter.sv — L2 Read-Only Port Arbiter (PE v5, Phase 3 Batch 2)
//
// Phase 3 Batch 2 changes:
//   [PHASE3-B2-01] RENAME vec <-> tens:
//                  Post-B2, the Tensor domain is the wide (16-bank) master
//                  and the Vector domain is the narrow (8-bank, half_sel)
//                  master. This inverts the v4 binding (v4 had Vec wide,
//                  Tens narrow).
//
//   [PHASE3-B2-02] Bug fix — Vec no longer monopolizes all 16 banks.
//                  v4 had a latent bug where vec_all_win was unconditionally
//                  tied to vec_req_i, meaning whenever the wide master
//                  requested, the narrow master was unconditionally starved
//                  even when it targeted disjoint bank-halves that the
//                  wide master didn't actually need. Post-B2, the wide
//                  master (Tens) takes full 16-bank priority; the narrow
//                  master (Vec) wins its selected half only when Tens is
//                  idle.
//
//   [PHASE3-B2-03] Renamed port: tens_bank_half_i -> vec_half_sel_i
//                  Semantic: 0 = banks 0-7 (low half), 1 = banks 8-15 (high
//                  half). Exact same encoding as v4's tens_bank_half_i,
//                  only the name changes (see D17-b).
//
// Post-B2 arbitration model (D14-b degraded version):
//   Priority: Tens (wide, 16 banks) > Vec (narrow, 8 banks via half_sel)
//
//   Per-cycle outcome:
//     - Tens requests  → Tens wins 16 banks; Vec must wait
//     - Tens idle, Vec requests → Vec wins 8 banks (selected by half_sel)
//     - Both idle → no bank selected
//
//   D14-b "full version" (Tens fractional-stripe + Vec on disjoint half
//   concurrent grant) is DEFERRED — it would require tensor_unit_top to
//   expose a half_sel port, which would violate Phase 2b's wrapper-port
//   freeze. When a future phase relaxes that freeze, the arbiter logic
//   here can be upgraded without changing port names.
//
// Outputs per-bank SRAM Port 1 control signals (csb1, addr1).
// Tracks rvalid (1-cycle SRAM read latency).
//
// half_sel is a PHYSICAL bank selector (0=banks 0-7, 1=banks 8-15),
// independent of region_id (which is a ROW address concept).
// =============================================================================

module l2_ro_arbiter
    import pe_pkg::*;
#(
    parameter int NUM_BANKS = L2_NUM_BANKS,   // 16
    parameter int BANK_AW   = L2_BANK_AW      // 9
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Tensor Load Request (16 banks, full stripe) ──
    input  logic                    tens_req_i,
    input  logic [BANK_AW-1:0]     tens_row_i,       // same row for all 16 banks
    output logic                    tens_gnt_o,
    output logic                    tens_rvalid_o,

    // ── Vector Load Request (8 banks, half-stripe) ──
    input  logic                    vec_req_i,
    input  logic [BANK_AW-1:0]     vec_row_i,        // same row for selected 8 banks
    input  logic                    vec_half_sel_i,   // [PHASE3-B2-03] was tens_bank_half_i
                                                       //   0 = banks 0-7, 1 = banks 8-15
    output logic                    vec_gnt_o,
    output logic                    vec_rvalid_o,

    // ── Per-Bank SRAM Port 1 Signals ──
    output logic               pb_csb_o  [NUM_BANKS],
    output logic [BANK_AW-1:0] pb_addr_o [NUM_BANKS]
);

    // =========================================================================
    // Per-Bank Hit Detection
    //
    // [PHASE3-B2-01] Role swap:
    //   Post-B2, Tens is the WIDE master (hits all 16 banks) and Vec is
    //   the NARROW master (hits 8 banks selected by vec_half_sel_i).
    //   This is the inverse of v4's hit pattern.
    // =========================================================================
    logic [NUM_BANKS-1:0] tens_hit;
    logic [NUM_BANKS-1:0] vec_hit;

    // Tens hits all 16 banks (full stripe)
    assign tens_hit = tens_req_i ? {NUM_BANKS{1'b1}} : '0;

    // Vec hits 8 banks based on half_sel
    always_comb begin
        vec_hit = '0;
        if (vec_req_i) begin
            for (int i = 0; i < NUM_BANKS; i++) begin
                if (vec_half_sel_i)
                    vec_hit[i] = (i >= NUM_BANKS/2);    // banks 8-15
                else
                    vec_hit[i] = (i < NUM_BANKS/2);     // banks 0-7
            end
        end
    end

    // =========================================================================
    // Per-Bank Winner Selection (Priority: Tens > Vec)
    //
    // [PHASE3-B2-01] Priority chain is now Tens > Vec (inverse of v4).
    // Per-bank check: Tens wins if it hits this bank; Vec wins only if
    // Tens does NOT hit this bank (i.e. Tens is idle).
    // =========================================================================
    logic [NUM_BANKS-1:0] winner_is_tens;
    logic [NUM_BANKS-1:0] winner_is_vec;
    logic [NUM_BANKS-1:0] bank_active;

    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            winner_is_tens[i] = tens_hit[i];
            winner_is_vec[i]  = vec_hit[i] & ~tens_hit[i];
            bank_active[i]    = tens_hit[i] | vec_hit[i];
        end
    end

    // =========================================================================
    // All-or-Nothing Commit
    //
    // [PHASE3-B2-02] Bug fix: previously Vec (wide master) was
    // unconditionally granted when it requested, starving Tens (narrow
    // master) on disjoint bank-halves. Post-B2 behavior:
    //
    //   Tens wins all 16 banks if requesting (highest priority, no
    //     conflict on RO port since DMA doesn't use RO).
    //
    //   Vec wins its selected 8 banks ONLY when Tens is not requesting.
    //     (If Tens requests, Tens takes all 16 banks → Vec must wait.)
    //
    // The "D14-b degraded" qualifier: if Tens were to request only part
    // of the stripe, Vec could concurrently use the disjoint half. This
    // optimization is deferred because tensor_unit_top does not currently
    // expose a half_sel output (Phase 2b port freeze).
    // =========================================================================
    logic tens_all_win;
    logic vec_all_win;

    // Tens always wins all banks if requesting (highest priority, no
    // conflict on RO port)
    assign tens_all_win = tens_req_i;

    // Vec wins its 8 banks only if Tens is not requesting
    assign vec_all_win  = vec_req_i & ~tens_req_i;

    // =========================================================================
    // Grant Signals
    // =========================================================================
    assign tens_gnt_o = tens_all_win;
    assign vec_gnt_o  = vec_all_win;

    // =========================================================================
    // Per-Bank SRAM Port 1 Control
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            if (winner_is_tens[i]) begin
                pb_csb_o[i]  = 1'b0;           // active (csb is active-low at bank interface)
                pb_addr_o[i] = tens_row_i;
            end else if (winner_is_vec[i]) begin
                pb_csb_o[i]  = 1'b0;           // active
                pb_addr_o[i] = vec_row_i;
            end else begin
                pb_csb_o[i]  = 1'b1;           // deselected
                pb_addr_o[i] = '0;
            end
        end
    end

    // =========================================================================
    // Rvalid Tracking — [C2] 2-cycle SRAM read latency (l2_bank OUT_REG=1).
    // The RO port dout is registered once more in the SRAM wrapper, so rvalid
    // must trail the grant by 2 cycles (was 1). MUST match l2_bank's OUT_REG.
    // =========================================================================
    logic tens_rvalid_q,  vec_rvalid_q;    // stage 1 (grant + 1)
    logic tens_rvalid_q2, vec_rvalid_q2;   // stage 2 (grant + 2) → aligns with OUT_REG dout

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            tens_rvalid_q  <= 1'b0; vec_rvalid_q  <= 1'b0;
            tens_rvalid_q2 <= 1'b0; vec_rvalid_q2 <= 1'b0;
        end else begin
            tens_rvalid_q  <= tens_gnt_o;
            vec_rvalid_q   <= vec_gnt_o;
            tens_rvalid_q2 <= tens_rvalid_q;
            vec_rvalid_q2  <= vec_rvalid_q;
        end
    end

    assign tens_rvalid_o = tens_rvalid_q2;
    assign vec_rvalid_o  = vec_rvalid_q2;

endmodule

// =============================================================================
// l2_rw_arbiter.sv — L2 Read/Write Port Arbiter (PE v5, Phase 3 Batch 2 + Phase 4)
//
// Phase 4 changes:
//   [PHASE4-08] Rename yield control ports to match post-rename semantics:
//                 vec_yield_mode_i -> tens_yield_mode_i
//                 vec_quota_n_i    -> tens_quota_n_i
//               The local alias that Phase 3 Batch 2 introduced (to bridge
//               the legacy-port-name gap) is now removed — internal logic
//               directly uses the renamed ports.
//   [PHASE4-09] Correct Phase 3 Batch 2 misleading comments about perf
//               counters. The perf counter port names
//               (perf_l2_vec_stall_o / perf_l2_tens_stall_o) and their
//               internal semantics were already aligned in Phase 3 Batch 2
//               — no rename needed. The "pending Phase 4 rename" notes
//               in the Phase 3 B2 comments were erroneous and are removed.
//
// Phase 3 Batch 2 changes (for context):
//   [PHASE3-B2-01] RENAME vec <-> tens, with WIDTH + PRIORITY swap:
//                   Post-B2, Tensor (new) is the wide 16-bank master and
//                   holds the highest non-DMA priority; Vector (new) is
//                   the narrow 8-bank master at mid priority.
//
//   [PHASE3-B2-02] Priority reordering:  Tens > Vec > DMA_FILL > DMA_EVICT
//                   (v4 had Vec > Tens > DMA_FILL > DMA_EVICT).
//
//   [PHASE3-B2-05] Renamed port: tens_bank_half_i -> vec_half_sel_i
//                   (D17-b naming).
//
// Arbitrates Port 0 (RW) of all 16 L2 banks.
// Masters (priority order, default, post-Phase 4):
//   1. Tensor Store  (HIGHEST) — 16 banks write (full stripe)
//   2. Vector Store  (HIGH)    — 8 banks write (half_sel selects which 8)
//   3. DMA Fill      (LOW)     — 1 bank write
//   4. DMA Evict     (LOWEST)  — 1 bank read (read via RW port!)
//
// Tens Yield Fairness (post-Phase 4):
//   When tens_yield_mode==1 (quota-based), Tens must yield after N
//   consecutive grants if a lower-priority master is waiting. Tens drops
//   to lowest priority for 1 cycle, then quota resets.
//   tens_yield_mode==0: disabled (pure fixed priority)
//
// Key design (structurally unchanged from v4, per D27):
//   Per-bank arbitration + All-or-Nothing commit for stripe masters.
//   DMA is single-bank → always satisfies if its bank is free.
//
// Bank Hole Exploitation:
//   When Vec writes 8 banks, the other 8 are free → DMA can use them.
//   Example: Vec writes banks 0-7, DMA writes bank 12 → both proceed!
//   (Inverted from v4: v4 had this hole for Tens's narrow writes.)
//
// DMA Evict reads via Port 0 (RW port):
//   DMA evict uses the RW port's read capability so RO port stays
//   dedicated to compute data feeding (Tens/Vec loads).
// =============================================================================

module l2_rw_arbiter
    import pe_pkg::*;
#(
    parameter int NUM_BANKS = L2_NUM_BANKS,   // 16
    parameter int BANK_AW   = L2_BANK_AW      // 9
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── R5.2: Soft reset (clears yield counter + perf counters) ──
    input  logic        soft_reset_i,

    // ── Tensor Store (post-B2: wide 16-bank master, highest priority) ──
    input  logic                    tens_req_i,
    input  logic [BANK_AW-1:0]     tens_row_i,        // same row for all 16 banks
    input  logic [511:0]           tens_wdata_i,       // 16 × 32b (FULL_STRIPE_W)
    input  logic [15:0]            tens_bank_mask_i,   // typically all 1's
    output logic                    tens_gnt_o,

    // ── Vector Store (post-B2: narrow 8-bank master, mid priority) ──
    input  logic                    vec_req_i,
    input  logic [BANK_AW-1:0]     vec_row_i,
    input  logic                    vec_half_sel_i,   // [PHASE3-B2-05] was tens_bank_half_i
    input  logic [255:0]           vec_wdata_i,       // 8 × 32b (HALF_STRIPE_W)
    input  logic [7:0]             vec_bank_mask_i,    // per-bank within half
    output logic                    vec_gnt_o,

    // ── DMA Fill (write to L2) ──
    input  logic                              dma_fill_req_i,
    input  logic [L2_BANK_SEL_W-1:0]         dma_fill_bank_i,
    input  logic [BANK_AW-1:0]               dma_fill_row_i,
    input  logic [31:0]                      dma_fill_wdata_i,
    input  logic [3:0]                       dma_fill_be_i,
    output logic                              dma_fill_gnt_o,

    // ── DMA Evict (read from L2 via RW port) ──
    input  logic                              dma_evict_req_i,
    input  logic [L2_BANK_SEL_W-1:0]         dma_evict_bank_i,
    input  logic [BANK_AW-1:0]               dma_evict_row_i,
    output logic                              dma_evict_gnt_o,
    output logic                              dma_evict_rvalid_o,

    // ── Per-Bank SRAM Port 0 Signals ──
    output logic               pa_csb_o   [NUM_BANKS],
    output logic               pa_web_o   [NUM_BANKS],
    output logic [3:0]         pa_wmask_o [NUM_BANKS],
    output logic [BANK_AW-1:0] pa_addr_o  [NUM_BANKS],
    output logic [31:0]        pa_din_o   [NUM_BANKS],

    // ── Yield Control (Tens yield — the new highest-priority master) ──
    //
    // [PHASE4-08] Port names aligned with post-rename semantics: the
    // Tens domain is now the highest-priority non-DMA master, so yield
    // fairness controls target Tens. MMIO bit layout in cp_csr register
    // 0x2F is unchanged — only field/port names differ.
    input  logic [1:0]  tens_yield_mode_i,   // 0=disabled, 1=quota-based
    input  logic [3:0]  tens_quota_n_i,      // quota N: yield after N consecutive grants

    // ── Performance Counters ──
    //
    // [PHASE4-09] Phase 3 Batch 2 had a (now-removed) comment suggesting
    // these ports would be renamed in Phase 4. That note was incorrect:
    // these port names and their internal semantics are already aligned
    // (perf_l2_vec_stall_o counts new Vec narrow-master stalls,
    // perf_l2_tens_stall_o counts new Tens wide-master stalls). No rename
    // needed.
    input  logic                     perf_cnt_en_i,
    output logic [PERF_CNT_W-1:0]   perf_l2_conflict_o,   // total req-without-grant cycles
    output logic [9:0]               perf_l2_vec_stall_o,  // new Vec (narrow) stall cycles
    output logic [9:0]               perf_l2_tens_stall_o, // new Tens (wide) stall cycles
    output logic [9:0]               perf_l2_dma_stall_o
);

    // =========================================================================
    // Per-Bank Hit Detection
    //
    // [PHASE3-B2-01] Role swap:
    //   Post-B2, Tens hits all 16 banks (full stripe, was Vec in v4);
    //   Vec hits 8 banks selected by vec_half_sel_i (was Tens in v4).
    //   DMA hit logic unchanged.
    // =========================================================================
    logic [NUM_BANKS-1:0] tens_hit;
    logic [NUM_BANKS-1:0] vec_hit;
    logic [NUM_BANKS-1:0] dma_fill_hit;
    logic [NUM_BANKS-1:0] dma_evict_hit;

    always_comb begin
        // Tensor: all 16 banks (full stripe) — uses tens_bank_mask_i[15:0]
        for (int i = 0; i < NUM_BANKS; i++)
            tens_hit[i] = tens_req_i & tens_bank_mask_i[i];

        // Vector: 8 banks from selected half — uses vec_bank_mask_i[7:0]
        // P14-style guarded index avoids negative part-select lint warning.
        for (int i = 0; i < NUM_BANKS; i++) begin
            automatic int unsigned vi;
            vi = vec_half_sel_i
                 ? (i >= NUM_BANKS/2 ? i - NUM_BANKS/2 : 0)
                 : (i <  NUM_BANKS/2 ? i : 0);
            if (vec_half_sel_i)
                vec_hit[i] = vec_req_i & (i >= NUM_BANKS/2) &
                              vec_bank_mask_i[vi];
            else
                vec_hit[i] = vec_req_i & (i <  NUM_BANKS/2) &
                              vec_bank_mask_i[vi];
        end

        // DMA Fill: single bank
        for (int i = 0; i < NUM_BANKS; i++)
            dma_fill_hit[i] = dma_fill_req_i &
                              (dma_fill_bank_i == i[L2_BANK_SEL_W-1:0]);

        // DMA Evict: single bank
        for (int i = 0; i < NUM_BANKS; i++)
            dma_evict_hit[i] = dma_evict_req_i &
                               (dma_evict_bank_i == i[L2_BANK_SEL_W-1:0]);
    end

    // =========================================================================
    // [PHASE3-B2-03] Tens Yield — Quota-Based Fairness
    //
    // Problem: Tens (post-B2) has highest fixed priority. Long Tens bursts
    // (GEMM write-C streams) starve Vec/DMA indefinitely. Yield mechanism
    // temporarily demotes Tens.
    //
    // Mode 0 (disabled): original fixed priority, tens_yield = 0.
    // Mode 1 (quota-based):
    //   - tens_consec_cnt tracks consecutive Tens grants
    //   - When cnt >= tens_quota_n AND a lower-priority master is waiting,
    //     tens_yield = 1 for 1 cycle → Tens drops to lowest priority
    //   - Counter resets when: Tens not granted, or yield fires, or no Tens req
    //
    // tens_quota_n == 0 with mode 1: yield every cycle when others wait
    // (effectively round-robin between Tens and others)
    //
    // NOTE on Vec yield: a second-level yield for Vec (to prevent Vec from
    // starving DMA) is intentionally NOT added here. Post-B2, Vec is a
    // mid-priority narrow master whose expected RW footprint (transform
    // engine writebacks) is much smaller than Tens's (GEMM C writes). If
    // profiling later shows Vec starvation of DMA, a second yield can be
    // added without structural changes.
    // =========================================================================
    logic [3:0] tens_consec_cnt_q;
    logic       tens_yield;
    logic       others_waiting;

    assign others_waiting = vec_req_i | dma_fill_req_i | dma_evict_req_i;

    assign tens_yield = (tens_yield_mode_i == 2'd1) &&
                        (tens_consec_cnt_q >= tens_quota_n_i) &&
                        others_waiting;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)                 // [STEP5 slang] async reset
            tens_consec_cnt_q <= '0;
        else if (soft_reset_i)       // [STEP5 slang] sync soft-reset (mirror)
            tens_consec_cnt_q <= '0;
        else if (tens_gnt_o && tens_req_i && !tens_yield) begin
            // Saturating increment (4-bit max = 15)
            if (!(&tens_consec_cnt_q))
                tens_consec_cnt_q <= tens_consec_cnt_q + 1'b1;
        end else begin
            // Reset: Tens not granted, or yield fired, or no Tens request
            tens_consec_cnt_q <= '0;
        end
    end

    // =========================================================================
    // Phase 1: Per-Bank Tentative Winner
    //
    // [PHASE3-B2-02] New priority chain: Tens > Vec > Fill > Evict
    // When tens_yield: Tens drops to lowest → Vec > Fill > Evict > Tens
    // =========================================================================
    arb_master_e tentative [NUM_BANKS];

    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            if (tens_yield) begin
                // Yield mode: Vec > Fill > Evict > Tens (Tens demoted to lowest)
                if      (vec_hit[i])        tentative[i] = ARB_VEC;
                else if (dma_fill_hit[i])   tentative[i] = ARB_DMA_FILL;
                else if (dma_evict_hit[i])  tentative[i] = ARB_DMA_EVICT;
                else if (tens_hit[i])       tentative[i] = ARB_TENS;
                else                        tentative[i] = ARB_NONE;
            end else begin
                // Normal mode: Tens > Vec > Fill > Evict
                if      (tens_hit[i])       tentative[i] = ARB_TENS;
                else if (vec_hit[i])        tentative[i] = ARB_VEC;
                else if (dma_fill_hit[i])   tentative[i] = ARB_DMA_FILL;
                else if (dma_evict_hit[i])  tentative[i] = ARB_DMA_EVICT;
                else                        tentative[i] = ARB_NONE;
            end
        end
    end

    // =========================================================================
    // Phase 2: All-or-Nothing Check for Stripe Masters
    //
    // [PHASE3-B2-01] Role swap:
    //   Tens (now highest): all 16 banks where tens_hit must have
    //     tentative==TENS. With current priority Tens always wins when
    //     requesting (except under yield).
    //   Vec (mid priority): all hit banks must have tentative==VEC. Vec
    //     could be denied if Tens is also requesting (Tens takes precedence).
    //
    // DMA masters never cause all-or-nothing failure (single-bank, lowest
    // priority).
    // =========================================================================
    logic tens_all_win;
    logic vec_all_win;

    always_comb begin
        tens_all_win = 1'b1;
        vec_all_win  = 1'b1;

        for (int i = 0; i < NUM_BANKS; i++) begin
            if (tens_hit[i] && tentative[i] != ARB_TENS)
                tens_all_win = 1'b0;
            if (vec_hit[i] && tentative[i] != ARB_VEC)
                vec_all_win = 1'b0;
        end

        // If no request, don't claim "all win"
        if (!tens_req_i) tens_all_win = 1'b0;
        if (!vec_req_i)  vec_all_win  = 1'b0;
    end

    // =========================================================================
    // Phase 2b: Revocation & Reallocation
    //
    // [PHASE3-B2-01] Role swap: revocation now targets Tens first (the
    // new highest-priority stripe master). In practice with Tens highest,
    // Tens revocation triggers only under yield mode.
    //
    //   If Tens fails all-or-nothing → revoke Tens from all banks → reallocate.
    //   If Vec fails (after Tens revocation) → revoke Vec → reallocate.
    // =========================================================================
    arb_master_e committed [NUM_BANKS];

    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            committed[i] = tentative[i];

            // Revoke Tens if all-or-nothing failed
            if (!tens_all_win && tentative[i] == ARB_TENS) begin
                // Reallocate this bank to next priority
                if      (vec_hit[i])        committed[i] = ARB_VEC;
                else if (dma_fill_hit[i])   committed[i] = ARB_DMA_FILL;
                else if (dma_evict_hit[i])  committed[i] = ARB_DMA_EVICT;
                else                        committed[i] = ARB_NONE;
            end
        end
    end

    // Recheck Vec after possible Tens revocation
    logic vec_all_committed;
    always_comb begin
        vec_all_committed = vec_req_i;
        for (int i = 0; i < NUM_BANKS; i++) begin
            if (vec_hit[i] && committed[i] != ARB_VEC)
                vec_all_committed = 1'b0;
        end
    end

    // Final committed winners (after Vec revocation if needed)
    arb_master_e final_winner [NUM_BANKS];

    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            final_winner[i] = committed[i];

            // Revoke Vec if its all-or-nothing failed after Tens revocation
            if (!vec_all_committed && committed[i] == ARB_VEC) begin
                if      (dma_fill_hit[i])   final_winner[i] = ARB_DMA_FILL;
                else if (dma_evict_hit[i])  final_winner[i] = ARB_DMA_EVICT;
                else                        final_winner[i] = ARB_NONE;
            end
        end
    end

    // =========================================================================
    // Grant Signals
    // =========================================================================
    assign tens_gnt_o = tens_all_win;
    assign vec_gnt_o  = vec_all_committed;

    // DMA grants: per-bank, check if final_winner matches
    always_comb begin
        dma_fill_gnt_o  = 1'b0;
        dma_evict_gnt_o = 1'b0;
        for (int i = 0; i < NUM_BANKS; i++) begin
            if (dma_fill_hit[i]  && final_winner[i] == ARB_DMA_FILL)
                dma_fill_gnt_o = 1'b1;
            if (dma_evict_hit[i] && final_winner[i] == ARB_DMA_EVICT)
                dma_evict_gnt_o = 1'b1;
        end
    end

    // =========================================================================
    // Per-Bank SRAM Port 0 (RW) Control Signals
    //
    // [PHASE3-B2-01] Width mapping:
    //   ARB_TENS: 16-bank slice from tens_wdata_i[511:0]
    //   ARB_VEC:  8-bank slice from vec_wdata_i[255:0], indexed within half
    // =========================================================================
    always_comb begin
        for (int i = 0; i < NUM_BANKS; i++) begin
            // Defaults: deselected
            pa_csb_o[i]   = 1'b1;
            pa_web_o[i]   = 1'b1;          // no write
            pa_wmask_o[i] = 4'b0;
            pa_addr_o[i]  = '0;
            pa_din_o[i]   = 32'b0;

            case (final_winner[i])
                ARB_TENS: begin
                    pa_csb_o[i]   = 1'b0;     // active
                    pa_web_o[i]   = 1'b0;     // write
                    pa_wmask_o[i] = 4'hF;     // full word
                    pa_addr_o[i]  = tens_row_i;
                    pa_din_o[i]   = tens_wdata_i[i*32 +: 32];
                end

                ARB_VEC: begin
                    // P14 hygiene: declare vi at the top of this block
                    // (fixes a pre-existing v4 issue where declaration
                    //  appeared after statements — caught by pyslang).
                    automatic int unsigned vi;
                    vi = vec_half_sel_i
                         ? (i >= NUM_BANKS/2 ? i - NUM_BANKS/2 : 0)
                         : (i <  NUM_BANKS/2 ? i : 0);
                    pa_csb_o[i]   = 1'b0;
                    pa_web_o[i]   = 1'b0;     // write
                    pa_wmask_o[i] = 4'hF;
                    pa_addr_o[i]  = vec_row_i;
                    // Index within the 8-bank half.
                    // P14 guarded index avoids negative part-select lint warning.
                    // When vec_half_sel_i=1, only banks [8..15] can win ARB_VEC
                    // (vec_hit guarantees this), but lint sees the general case.
                    // Guard: clamp to 0 for banks outside the active half.
                    pa_din_o[i] = vec_wdata_i[vi*32 +: 32];
                end

                ARB_DMA_FILL: begin
                    pa_csb_o[i]   = 1'b0;
                    pa_web_o[i]   = 1'b0;     // write
                    pa_wmask_o[i] = dma_fill_be_i;
                    pa_addr_o[i]  = dma_fill_row_i;
                    pa_din_o[i]   = dma_fill_wdata_i;
                end

                ARB_DMA_EVICT: begin
                    pa_csb_o[i]   = 1'b0;
                    pa_web_o[i]   = 1'b1;     // READ (web=1)
                    pa_wmask_o[i] = 4'b0;
                    pa_addr_o[i]  = dma_evict_row_i;
                    pa_din_o[i]   = 32'b0;
                end

                default: begin
                    // bank idle — keep deselected
                end
            endcase
        end
    end

    // =========================================================================
    // DMA Evict Rvalid — [C2] 2-cycle SRAM read latency (l2_bank OUT_REG=1).
    // RW-port dout registered once more → rvalid trails grant by 2 cycles (was 1).
    // The dma_engine depth-2 evict hold (this commit's step1) tolerates the two
    // now-in-flight reads. MUST match l2_bank's OUT_REG.
    // =========================================================================
    logic dma_evict_rvalid_q, dma_evict_rvalid_q2;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dma_evict_rvalid_q  <= 1'b0;
            dma_evict_rvalid_q2 <= 1'b0;
        end else begin
            dma_evict_rvalid_q  <= dma_evict_gnt_o;
            dma_evict_rvalid_q2 <= dma_evict_rvalid_q;
        end
    end

    assign dma_evict_rvalid_o = dma_evict_rvalid_q2;

    // =========================================================================
    // R5.2 / [PHASE3-B2-04]: L2 Performance Counters
    //
    // External port names preserved from v4 (perf_l2_vec_stall_o,
    // perf_l2_tens_stall_o) — they will be renamed in Phase 4. Internal
    // semantics now track the post-rename execution domains:
    //   perf_l2_vec_stall_o  counts new Vec (narrow master) stall cycles
    //   perf_l2_tens_stall_o counts new Tens (wide master) stall cycles
    //
    // bank_conflict_stalls (32-bit saturating): total req-without-grant
    //   cycles across ALL masters. Measures overall L2 RW port contention.
    // Per-master stall counters (10-bit saturating).
    //
    // All counters: clear on rst_ni/soft_reset, gated by perf_cnt_en.
    // =========================================================================
    logic [PERF_CNT_W-1:0] l2_conflict_q;
    logic [9:0]            l2_vec_stall_q;
    logic [9:0]            l2_tens_stall_q;
    logic [9:0]            l2_dma_stall_q;

    // Trigger signals (semantics follow post-B2 port meanings)
    logic conflict_any;
    logic vec_stall;
    logic tens_stall;
    logic dma_stall;

    assign conflict_any = (tens_req_i  & ~tens_gnt_o)        |
                          (vec_req_i   & ~vec_gnt_o)         |
                          (dma_fill_req_i & ~dma_fill_gnt_o);
    // Note: dma_evict stall excluded — evict is best-effort, not latency-critical

    assign tens_stall = tens_req_i      & ~tens_gnt_o;
    assign vec_stall  = vec_req_i       & ~vec_gnt_o;
    assign dma_stall  = dma_fill_req_i  & ~dma_fill_gnt_o;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin                  // [STEP5 slang] async reset
            l2_conflict_q   <= '0;
            l2_vec_stall_q  <= '0;
            l2_tens_stall_q <= '0;
            l2_dma_stall_q  <= '0;
        end else if (soft_reset_i) begin    // [STEP5 slang] sync soft-reset (mirror)
            l2_conflict_q   <= '0;
            l2_vec_stall_q  <= '0;
            l2_tens_stall_q <= '0;
            l2_dma_stall_q  <= '0;
        end else if (perf_cnt_en_i) begin
            if (conflict_any && !(&l2_conflict_q))
                l2_conflict_q <= l2_conflict_q + 1'b1;

            if (vec_stall && !(&l2_vec_stall_q))
                l2_vec_stall_q <= l2_vec_stall_q + 1'b1;

            if (tens_stall && !(&l2_tens_stall_q))
                l2_tens_stall_q <= l2_tens_stall_q + 1'b1;

            if (dma_stall && !(&l2_dma_stall_q))
                l2_dma_stall_q <= l2_dma_stall_q + 1'b1;
        end
    end

    assign perf_l2_conflict_o   = l2_conflict_q;
    assign perf_l2_vec_stall_o  = l2_vec_stall_q;
    assign perf_l2_tens_stall_o = l2_tens_stall_q;
    assign perf_l2_dma_stall_o  = l2_dma_stall_q;

endmodule

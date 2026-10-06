// =============================================================================
// l2_subsystem.sv — L2 Scratchpad Subsystem (PE v5, Phase 3 Batch 2)
//
// Phase 3 Batch 2 changes:
//   [PHASE3-B2-01] RENAME vec <-> tens, with WIDTH SWAP:
//                   External port widths and names flip:
//                     - tens_ro_rdata_o / tens_rw_wdata_i: now 512b (was 256b)
//                     - vec_ro_rdata_o  / vec_rw_wdata_i:  now 256b (was 512b)
//                     - bank-half signal renamed tens_*_bank_half_i ->
//                       vec_*_half_sel_i (D17-b)
//                     - read-data assembly labels swap (gen_vec_rdata ->
//                       gen_tens_rdata, etc.)
//
//   [PHASE3-B2-02] Functionally unchanged beyond the swap. Per D27, the
//                   module structure is preserved; only labels, port
//                   names, and wdata/rdata ownership are relabeled.
//
// Phase 4 changes:
//   [PHASE4-08] Propagate yield port rename from l2_rw_arbiter to
//               subsystem-level ports:
//                 vec_yield_mode_i -> tens_yield_mode_i
//                 vec_quota_n_i    -> tens_quota_n_i
//   [PHASE4-09] Remove the Phase 3 Batch 2 entry claiming perf counter
//               names needed a Phase 4 rename. That claim was erroneous
//               — perf counter names and semantics were already aligned
//               in Phase 3 Batch 2.
//
// 16 × SRAM banks (word-interleaved, row-based regions)
// + RO Arbiter (Port 1: post-B2 Tens-wide > Vec-narrow)
// + RW Arbiter (Port 0: post-B2 Tens > Vec > DMA fill > DMA evict)
// + Read data assembly (Tens 512b, Vec 256b, DMA 32b)
//
// Note: This module does NOT do address decoding from byte addresses.
//       Callers (Tens/Vec/DMA stubs or wrappers) provide physical row
//       addresses (already translated from RID+row_off by cp_scheduler).
//       Bank selection is handled by the arbiters (Tens=all, Vec=half,
//       DMA=one).
// =============================================================================

module l2_subsystem
    import pe_pkg::*;
#(
    parameter int NUM_BANKS = L2_NUM_BANKS,   // 16
    parameter int BANK_AW   = L2_BANK_AW,     // 9
    // [D-SRAM-REAL-B-2026-09-03] 见 l2_bank.sv 同名参数的注释。默认 1'b1。
    //   本模块同时是 ORFS 独立设计 `aichip_l2` 的顶层（designs/asap7/aichip_l2/config.mk:18）
    //   ⇒ 默认置 1 让那条线也自动吃到真宏，不需要各自 opt-in。
    parameter bit REAL_MACRO = 1'b1
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // =========================================================================
    // Tensor Interface (post-B2: 512b = 16 banks × 32b)
    // =========================================================================
    // RO port (load) — full stripe
    input  logic                           tens_ro_req_i,
    input  logic [BANK_AW-1:0]            tens_ro_row_i,
    output logic                           tens_ro_gnt_o,
    output logic                           tens_ro_rvalid_o,
    output logic [FULL_STRIPE_W-1:0]      tens_ro_rdata_o,

    // RW port (store) — full stripe
    input  logic                           tens_rw_req_i,
    input  logic [BANK_AW-1:0]            tens_rw_row_i,
    input  logic [NUM_BANKS-1:0]          tens_rw_bank_mask_i,  // 16-bit
    input  logic [FULL_STRIPE_W-1:0]      tens_rw_wdata_i,
    output logic                           tens_rw_gnt_o,

    // =========================================================================
    // Vector Interface (post-B2: 256b = 8 banks × 32b, via half_sel)
    // =========================================================================
    // RO port (load) — half stripe, half_sel selects which 8 banks
    input  logic                           vec_ro_req_i,
    input  logic [BANK_AW-1:0]            vec_ro_row_i,
    input  logic                           vec_ro_half_sel_i,  // 0=banks 0-7, 1=banks 8-15
    output logic                           vec_ro_gnt_o,
    output logic                           vec_ro_rvalid_o,
    output logic [HALF_STRIPE_W-1:0]      vec_ro_rdata_o,

    // RW port (store) — half stripe
    input  logic                           vec_rw_req_i,
    input  logic [BANK_AW-1:0]            vec_rw_row_i,
    input  logic                           vec_rw_half_sel_i,
    input  logic [(NUM_BANKS/2)-1:0]      vec_rw_bank_mask_i,   // 8-bit within half
    input  logic [HALF_STRIPE_W-1:0]      vec_rw_wdata_i,
    output logic                           vec_rw_gnt_o,

    // =========================================================================
    // DMA Interface (32b = 1 bank) — unchanged in B2
    // =========================================================================
    // Fill (write to L2)
    input  logic                              dma_fill_req_i,
    input  logic [L2_BANK_SEL_W-1:0]         dma_fill_bank_i,
    input  logic [BANK_AW-1:0]               dma_fill_row_i,
    input  logic [31:0]                      dma_fill_wdata_i,
    input  logic [3:0]                       dma_fill_be_i,
    output logic                              dma_fill_gnt_o,

    // Evict (read from L2 via RW port)
    input  logic                              dma_evict_req_i,
    input  logic [L2_BANK_SEL_W-1:0]         dma_evict_bank_i,
    input  logic [BANK_AW-1:0]               dma_evict_row_i,
    output logic                              dma_evict_gnt_o,
    output logic                              dma_evict_rvalid_o,
    output logic [31:0]                      dma_evict_rdata_o,

    // ── RW Arbiter Controls ──
    //
    // [PHASE4-08] Yield port names aligned with Tens semantics.
    // [PHASE4-09] Perf counter names and semantics are already aligned
    // (names correspond to post-rename execution domains); no rename.
    input  logic        soft_reset_i,
    input  logic [1:0]  tens_yield_mode_i,
    input  logic [3:0]  tens_quota_n_i,
    input  logic        perf_cnt_en_i,
    output logic [PERF_CNT_W-1:0]   perf_l2_conflict_o,
    output logic [9:0]               perf_l2_vec_stall_o,    // new Vec (narrow) stall cycles
    output logic [9:0]               perf_l2_tens_stall_o,   // new Tens (wide) stall cycles
    output logic [9:0]               perf_l2_dma_stall_o
);

    // =========================================================================
    // Per-Bank Wires
    // =========================================================================
    // Port 0 (RW) — from RW arbiter
    logic               pa_csb   [NUM_BANKS];
    logic               pa_web   [NUM_BANKS];
    logic [3:0]         pa_wmask [NUM_BANKS];
    logic [BANK_AW-1:0] pa_addr  [NUM_BANKS];
    logic [31:0]        pa_din   [NUM_BANKS];
    logic [31:0]        pa_dout  [NUM_BANKS];

    // Port 1 (R) — from RO arbiter
    logic               pb_csb   [NUM_BANKS];
    logic [BANK_AW-1:0] pb_addr  [NUM_BANKS];
    logic [31:0]        pb_dout  [NUM_BANKS];

    // =========================================================================
    // RO Arbiter (Port 1)
    //
    // [PHASE3-B2-01] Tens (wide) is the primary master; Vec (narrow) is
    // secondary. Connection names follow the post-B2 arbiter port
    // signature (tens_* / vec_*).
    // =========================================================================
    l2_ro_arbiter #(
        .NUM_BANKS ( NUM_BANKS ),
        .BANK_AW   ( BANK_AW   )
    ) i_ro_arb (
        .clk_i,
        .rst_ni,

        .tens_req_i       ( tens_ro_req_i        ),
        .tens_row_i       ( tens_ro_row_i        ),
        .tens_gnt_o       ( tens_ro_gnt_o        ),
        .tens_rvalid_o    ( tens_ro_rvalid_o     ),

        .vec_req_i        ( vec_ro_req_i         ),
        .vec_row_i        ( vec_ro_row_i         ),
        .vec_half_sel_i   ( vec_ro_half_sel_i    ),
        .vec_gnt_o        ( vec_ro_gnt_o         ),
        .vec_rvalid_o     ( vec_ro_rvalid_o      ),

        .pb_csb_o         ( pb_csb               ),
        .pb_addr_o        ( pb_addr              )
    );

    // =========================================================================
    // RW Arbiter (Port 0)
    //
    // [PHASE3-B2-01,02] Post-B2 priority: Tens > Vec > DMA_FILL > DMA_EVICT
    // [PHASE3-B2-03] yield/perf legacy port names preserved at subsystem
    //                boundary; Phase 4 will rename them.
    // =========================================================================
    l2_rw_arbiter #(
        .NUM_BANKS ( NUM_BANKS ),
        .BANK_AW   ( BANK_AW   )
    ) i_rw_arb (
        .clk_i,
        .rst_ni,
        .soft_reset_i,

        .tens_req_i       ( tens_rw_req_i        ),
        .tens_row_i       ( tens_rw_row_i        ),
        .tens_wdata_i     ( tens_rw_wdata_i      ),
        .tens_bank_mask_i ( tens_rw_bank_mask_i  ),
        .tens_gnt_o       ( tens_rw_gnt_o        ),

        .vec_req_i        ( vec_rw_req_i         ),
        .vec_row_i        ( vec_rw_row_i         ),
        .vec_half_sel_i   ( vec_rw_half_sel_i    ),
        .vec_wdata_i      ( vec_rw_wdata_i       ),
        .vec_bank_mask_i  ( vec_rw_bank_mask_i   ),
        .vec_gnt_o        ( vec_rw_gnt_o         ),

        .dma_fill_req_i   ( dma_fill_req_i       ),
        .dma_fill_bank_i  ( dma_fill_bank_i      ),
        .dma_fill_row_i   ( dma_fill_row_i       ),
        .dma_fill_wdata_i ( dma_fill_wdata_i     ),
        .dma_fill_be_i    ( dma_fill_be_i        ),
        .dma_fill_gnt_o   ( dma_fill_gnt_o       ),

        .dma_evict_req_i  ( dma_evict_req_i      ),
        .dma_evict_bank_i ( dma_evict_bank_i     ),
        .dma_evict_row_i  ( dma_evict_row_i      ),
        .dma_evict_gnt_o  ( dma_evict_gnt_o      ),
        .dma_evict_rvalid_o ( dma_evict_rvalid_o ),

        .pa_csb_o         ( pa_csb               ),
        .pa_web_o         ( pa_web               ),
        .pa_wmask_o       ( pa_wmask             ),
        .pa_addr_o        ( pa_addr              ),
        .pa_din_o         ( pa_din               ),

        // [PHASE4-08] Yield ports renamed tens_*; perf counters unchanged
        .tens_yield_mode_i,
        .tens_quota_n_i,
        .perf_cnt_en_i,
        .perf_l2_conflict_o,
        .perf_l2_vec_stall_o,
        .perf_l2_tens_stall_o,
        .perf_l2_dma_stall_o
    );

    // =========================================================================
    // 16 × SRAM Bank Instances (via l2_bank, now using sram_1rw1r_wrapper)
    // =========================================================================
    generate
        for (genvar gi = 0; gi < NUM_BANKS; gi++) begin : gen_banks
            l2_bank #(
                .BANK_AW    ( BANK_AW    ),
                .REAL_MACRO ( REAL_MACRO )   // [D-SRAM-REAL-B]
            ) i_bank (
                .clk_i,

                // Port 0 (RW) from RW arbiter
                .pa_csb_i   ( pa_csb[gi]   ),
                .pa_web_i   ( pa_web[gi]   ),
                .pa_wmask_i ( pa_wmask[gi] ),
                .pa_addr_i  ( pa_addr[gi]  ),
                .pa_din_i   ( pa_din[gi]   ),
                .pa_dout_o  ( pa_dout[gi]  ),

                // Port 1 (R) from RO arbiter
                .pb_csb_i   ( pb_csb[gi]   ),
                .pb_addr_i  ( pb_addr[gi]  ),
                .pb_dout_o  ( pb_dout[gi]  )
            );
        end
    endgenerate

    // =========================================================================
    // RO Port Read Data Assembly
    //
    // [PHASE3-B2-01] Role swap relative to v4:
    //   Tensor: 512b = all 16 banks' Port 1 dout  (was Vec in v4)
    //   Vector: 256b from 8 banks selected by vec_ro_half_sel_i  (was Tens in v4)
    // =========================================================================

    // ---- Tensor: 512b = all 16 banks' Port 1 dout ----
    generate
        for (genvar gi = 0; gi < NUM_BANKS; gi++) begin : gen_tens_rdata
            assign tens_ro_rdata_o[gi*32 +: 32] = pb_dout[gi];
        end
    endgenerate

    // ---- Vector: 256b from selected 8 banks' Port 1 dout ----
    //
    // Latch half_sel on grant cycle, use on rvalid cycle.
    // [C2] 2-cycle L2 read (l2_bank OUT_REG=1): pb_dout is registered once more,
    // so the half-select used in the rdata mux is delayed +1 (q2) to align with it.
    logic vec_ro_half_sel_q, vec_ro_half_sel_q2;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            vec_ro_half_sel_q  <= 1'b0;
            vec_ro_half_sel_q2 <= 1'b0;
        end else begin
            if (vec_ro_gnt_o) vec_ro_half_sel_q <= vec_ro_half_sel_i;
            vec_ro_half_sel_q2 <= vec_ro_half_sel_q;   // +1 → aligns with registered pb_dout
        end
    end

    generate
        for (genvar gi = 0; gi < NUM_BANKS/2; gi++) begin : gen_vec_rdata
            assign vec_ro_rdata_o[gi*32 +: 32] =
                vec_ro_half_sel_q2 ? pb_dout[gi + NUM_BANKS/2] : pb_dout[gi];
        end
    endgenerate

    // =========================================================================
    // RW Port Read Data Assembly (DMA Evict only) — unchanged from v4
    //
    // DMA evict reads 1 bank via Port 0 (RW). Need 16:1 MUX.
    // Hierarchical: 4 groups × 4:1 → 4:1 (matches physical layout).
    // =========================================================================
    localparam int NUM_GROUPS    = 4;
    localparam int BANKS_PER_GRP = NUM_BANKS / NUM_GROUPS;

    // Latch bank_sel on evict grant cycle.
    // [C2] 2-cycle L2 read (l2_bank OUT_REG=1): pa_dout is registered once more,
    // so the bank-select feeding the evict read MUX is delayed +1 (q2) to align.
    logic [L2_BANK_SEL_W-1:0] dma_evict_bank_q, dma_evict_bank_q2;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            dma_evict_bank_q  <= '0;
            dma_evict_bank_q2 <= '0;
        end else begin
            if (dma_evict_gnt_o) dma_evict_bank_q <= dma_evict_bank_i;
            dma_evict_bank_q2 <= dma_evict_bank_q;   // +1 → aligns with registered pa_dout
        end
    end

    // Stage 1: Per-group 4:1 MUX
    logic [31:0] dma_rdata_group [NUM_GROUPS];
    logic [1:0]  dma_grp_sel;
    logic [1:0]  dma_ingrp_sel;

    assign dma_grp_sel   = dma_evict_bank_q2[L2_BANK_SEL_W-1 : L2_BANK_SEL_W-2];
    assign dma_ingrp_sel = dma_evict_bank_q2[1:0];

    generate
        for (genvar g = 0; g < NUM_GROUPS; g++) begin : gen_dma_rdata_grp
            always_comb begin
                case (dma_ingrp_sel)
                    2'd0: dma_rdata_group[g] = pa_dout[g*BANKS_PER_GRP + 0];
                    2'd1: dma_rdata_group[g] = pa_dout[g*BANKS_PER_GRP + 1];
                    2'd2: dma_rdata_group[g] = pa_dout[g*BANKS_PER_GRP + 2];
                    2'd3: dma_rdata_group[g] = pa_dout[g*BANKS_PER_GRP + 3];
                endcase
            end
        end
    endgenerate

    // Stage 2: Top-level 4:1 MUX
    always_comb begin
        case (dma_grp_sel)
            2'd0: dma_evict_rdata_o = dma_rdata_group[0];
            2'd1: dma_evict_rdata_o = dma_rdata_group[1];
            2'd2: dma_evict_rdata_o = dma_rdata_group[2];
            2'd3: dma_evict_rdata_o = dma_rdata_group[3];
        endcase
    end

endmodule

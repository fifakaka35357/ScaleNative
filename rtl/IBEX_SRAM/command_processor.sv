// =============================================================================
// command_processor.sv — Command Processor Top-Level (PE v5, Phase 4)
//   (R1+R2B+R3C+R4.3+R5.3+D7+D9 baseline)
//
// Phase 4 changes:
//   [PHASE4-05] Replace hierarchical reference i_scheduler.event_wake[i]
//               with formal port connection via the new cp_scheduler
//               event_wake_o output. Pure discipline fix.
//   [PHASE4-06] Add TRACE_FETCH_STALL event collector (edge-triggered,
//               D38-a definition): ctx is RUNNABLE but both current and
//               next slots are EMPTY, i.e. "should be runnable, but the
//               fetch engine hasn't caught up". Inserted as a new
//               priority level between event_wake and doorbell.
//
// Owns the per-context dual-slot registers and orchestrates:
//   cp_csr         — MMIO registers (doorbell, status, region table)
//   cp_desc_fetch  — Fetch engine: reads L1D → fills slots
//   cp_scheduler   — Scans desc_current slots → issues commands
//   cp_completion  — Routes done signals → wakes contexts
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  Per-Context Dual Slots — Completion-Driven Lifecycle (v4 fix)     │
// │                                                                     │
// │  slot_current: descriptor being evaluated / inflight / completing   │
// │  slot_next:    prefetched descriptor (ready for promotion)          │
// │                                                                     │
// │  Transitions:                                                       │
// │    fetch_fill  → if current EMPTY: fill current (immediate avail)  │
// │                  else: fill next (prefetch)                         │
// │    issue       → ctx_state → WAIT_*; current stays (inflight op)   │
// │    comp_done   → read flags from current; promote next→current     │
// │                  or clear current if next is empty                  │
// │    CHAIN_NEXT  → completion flag; scheduler keeps ctx RUNNABLE      │
// │                                                                     │
// │  NBA-safe: comb next-state logic → single always_ff register       │
// │  Priority: comp_done > fetch_fill (comp sees pre-update state,     │
// │            fetch sees post-completion state)                        │
// └─────────────────────────────────────────────────────────────────────┘
// =============================================================================

module command_processor
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // =========================================================================
    // MMIO Interface (OBI slave, from addr_decoder)
    // =========================================================================
    input  logic        mmio_req_i,
    output logic        mmio_gnt_o,
    output logic        mmio_rvalid_o,
    input  logic [8:0]  mmio_addr_i,      // D7: 9-bit for 512B MMIO
    input  logic        mmio_we_i,
    input  logic [3:0]  mmio_be_i,
    input  logic [31:0] mmio_wdata_i,
    output logic [31:0] mmio_rdata_o,
    output logic        mmio_err_o,

    // =========================================================================
    // L1D Port 1 — 64b Descriptor Fetch
    // =========================================================================
    output logic [L1D_BANK_AW-1:0] l1d_addr_o,
    output logic                    l1d_req_o,
    input  logic [63:0]             l1d_rdata_i,
    input  logic                    l1d_rvalid_i,

    // =========================================================================
    // Execution Unit Command Interfaces (valid/ready)
    // =========================================================================
    output logic        vec_cmd_valid_o,
    output vec_cmd_t    vec_cmd_o,
    input  logic        vec_cmd_ready_i,

    output logic        tens_cmd_valid_o,
    output tens_cmd_t   tens_cmd_o,
    input  logic        tens_cmd_ready_i,

    output logic        dma_cmd_valid_o,
    output dma_cmd_t    dma_cmd_o,
    input  logic        dma_cmd_ready_i,

    // =========================================================================
    // Execution Unit Done Signals
    // =========================================================================
    input  logic              vec_done_i,
    input  logic [1:0]        vec_done_ctx_i,
    input  logic [TAG_W-1:0]  vec_done_tag_i,     // D4: tag return
    input  logic              tens_done_i,
    input  logic [1:0]        tens_done_ctx_i,
    input  logic [TAG_W-1:0]  tens_done_tag_i,    // D4: tag return
    input  logic              dma_done_i,
    input  logic [1:0]        dma_done_ctx_i,
    input  logic [TAG_W-1:0]  dma_done_tag_i,     // D4: tag return

    // =========================================================================
    // Interrupt Output (to IBEX irq_fast[0])
    // =========================================================================
    output logic        irq_o,

    // =========================================================================
    // Soft Reset Output (to pe_top for routing to exec units)
    // P13: exec units need soft_reset to abort inflight operations
    // =========================================================================
    output logic        cp_soft_reset_o,

    // =========================================================================
    // R5.3: Performance / Yield Interface (pe_top ↔ l2_subsystem)
    // =========================================================================
    // L2-side perf counters (from l2_subsystem, read-only in cp_csr)
    input  logic [PERF_CNT_W-1:0] perf_l2_conflict_i,
    input  logic [9:0]            perf_l2_vec_stall_i,
    input  logic [9:0]            perf_l2_tens_stall_i,
    input  logic [9:0]            perf_l2_dma_stall_i,

    // Control outputs (from cp_csr → pe_top → l2_subsystem)
    output logic                  perf_cnt_en_o,
    output logic [1:0]            tens_yield_mode_o,
    output logic [3:0]            tens_quota_n_o,

    // ── R6.1: Clock Enable (from cp_csr PE_POWER_CTRL → pe_top ICG) ──
    output logic                  vec_clk_en_o,
    output logic                  tens_clk_en_o,
    output logic                  dma_clk_en_o
);

    // =========================================================================
    // Internal Wires: CSR ↔ CP internals
    // =========================================================================

    // CSR outputs
    logic        cp_enable;
    logic        cp_soft_reset;
    assign cp_soft_reset_o = cp_soft_reset;  // P13: expose to pe_top for exec unit routing
    logic [11:0] ring_base     [NUM_CTX];
    logic [3:0]  ring_size_log2 [NUM_CTX];
    logic [RING_PTR_W-1:0] ring_tail [NUM_CTX];
    logic [NUM_CTX-1:0]    doorbell_pulse;
    region_entry_t region_table [NUM_REGIONS];

    // Ring head pointers (from fetch engine → CSR for IBEX read)
    logic [RING_PTR_W-1:0] ring_head [NUM_CTX];

    // Context states (from scheduler → CSR for IBEX read)
    ctx_state_e ctx_state [NUM_CTX];

    // [PHASE4-05] Event wake from scheduler (formal port, replaces v4's
    // hierarchical reference i_scheduler.event_wake[i]).
    logic [NUM_CTX-1:0] sched_event_wake;

    // [PHASE4-06] FETCH_STALL edge detection signals (assigned near the
    // event collector; forward-declared here so cp_scheduler's event_wake_o
    // port connection can compile).
    logic [NUM_CTX-1:0] fetch_stall_edge;

    // =========================================================================
    // [PHASE4-hygiene] Forward declarations for v4 use-before-declaration
    // issues. These signals are assigned later (near their respective
    // submodule instances or local always blocks); v4 relied on tool
    // tolerance for forward references. pyslang is strict, so we hoist
    // the declarations here. No logical change — pure discipline fix
    // matching the same pattern applied to cp_scheduler's sel_ctx.
    // =========================================================================
    // Scheduler ↔ CSR: tag/credit observability
    logic [TAG_MAX-1:0]             vec_tag_valid, tens_tag_valid, dma_tag_valid;
    logic [SCOREBOARD_CREDIT_W-1:0] vec_credit,    tens_credit,    dma_credit;

    // CSR ↔ scheduler: event / IRQ
    logic [NUM_CTX-1:0] irq_pending_per_ctx;
    logic [NUM_CTX-1:0] event_clear;
    logic [EVT_W-1:0]   event_pending [NUM_CTX];

    // Trace ring ↔ CSR wires
    logic                    trace_enable;
    logic                    trace_freeze;
    logic                    trace_clear;
    logic [TRACE_AW-1:0]     trace_rd_index;
    logic [31:0]             trace_rd_data;
    logic [TRACE_AW-1:0]     trace_wr_ptr;
    logic                    trace_overflow;
    logic [TRACE_AW:0]       trace_count;

    // Trace ring: event_wake local alias (assigned below from sched_event_wake)
    logic [NUM_CTX-1:0] event_wake;

    // Scoreboard
    logic vec_busy, tens_busy, dma_busy;

    // IRQ set pulses (from completion → CSR)
    logic [NUM_CTX-1:0] irq_set;

    // R1.1b: Derived slot observability (from scheduler, combinational)
    //   Wired to cp_csr for CP_SLOT_STATUS register (R2.7b).
    slot_state_e slot_state_vis [NUM_CTX];

    // R2.7: Issue snapshot (from scheduler → CSR for CTX_DBG)
    logic                issue_snap_valid;
    logic [CTX_ID_W-1:0] issue_snap_ctx;
    logic [7:0]          issue_snap_opcode;
    logic [3:0]          issue_snap_ext_len;

    // R2.8: Power control (from CSR → pe_top for ICG, R6.1)
    logic vec_clk_en, tens_clk_en, dma_clk_en;
    assign vec_clk_en_o  = vec_clk_en;
    assign tens_clk_en_o = tens_clk_en;
    assign dma_clk_en_o  = dma_clk_en;

    // R3.2b: Error (from scheduler → CSR for CTX_ERR)
    logic                error_valid;
    logic [CTX_ID_W-1:0] error_ctx;
    err_class_e          error_class;

    // R3.2c: Clear error (from CSR → scheduler for CTX_ERROR→CTX_IDLE)
    logic [NUM_CTX-1:0]  clear_error;

    // R4.1: Watchdog (CSR → scheduler threshold, scheduler → CSR timeout for IRQ)
    logic [WD_CNT_W-1:0] wd_threshold;
    logic [NUM_CTX-1:0]  wd_timeout;

    // R5.3: Perf counter routing (scheduler → CSR)
    logic                  perf_cnt_en;
    logic [1:0]            tens_yield_mode;
    logic [3:0]            tens_quota_n;
    logic [PERF_CNT_W-1:0] perf_ctx_blocked  [NUM_CTX];
    logic [PERF_CNT_W-1:0] perf_ctx_barrier  [NUM_CTX];
    logic [PERF_CNT_W-1:0] perf_ctx_starved  [NUM_CTX];
    logic [PERF_CNT_W-1:0] perf_total_issue;
    logic [PERF_CNT_W-1:0] perf_total_done;

    // R5.3: Pass-through yield/perf_cnt_en to pe_top
    assign perf_cnt_en_o    = perf_cnt_en;
    assign tens_yield_mode_o = tens_yield_mode;
    assign tens_quota_n_o    = tens_quota_n;

    // =========================================================================
    // Per-Context Dual-Slot Registers
    //
    // Completion-driven lifecycle (v4 fix):
    //   current: holds the descriptor being evaluated/issued/inflight
    //   next:    prefetched descriptor awaiting promotion
    //
    // Update sources:
    //   1. comp_done (from completion router or NOP/BARRIER immediate)
    //      → Reads current flags, then promotes next→current or clears
    //   2. fetch_fill (from fetch engine)
    //      → Fills current (if EMPTY) or next (if current occupied)
    //
    // Priority: comp_done processes first (reads pre-update state),
    //           fetch_fill sees post-completion state.
    // =========================================================================
    logic [31:0]   slot_current  [NUM_CTX][DESC_SLOT_WORDS];
    slot_state_e   slot_current_state [NUM_CTX];

    logic [31:0]   slot_next     [NUM_CTX][DESC_SLOT_WORDS];
    slot_state_e   slot_next_state [NUM_CTX];

    // -- Fetch writes slots --
    logic [NUM_CTX-1:0]   fetch_fill_valid;     // fetch completed a descriptor
    logic [1:0]           fetch_fill_ctx;        // which ctx
    logic [31:0]          fetch_fill_data [DESC_SLOT_WORDS]; // descriptor words

    // -- Completion events (from cp_completion, includes NOP/BARRIER) --
    logic [NUM_CTX-1:0]   comp_done;            // execution completed for ctx
    logic [NUM_CTX-1:0]   comp_chain;           // CHAIN_NEXT flag was set

    // -- NOP/BARRIER immediate done (from scheduler) --
    logic [NUM_CTX-1:0]   nop_done;             // NOP/BARRIER completed instantly

    // =========================================================================
    // Slot Next-State Logic (combinational, NBA-race-free)
    //
    // Computes next values for all slot registers in a single comb block.
    // Priority order prevents races:
    //   Step 1: comp_done — reads CURRENT slot state, promotes/clears
    //   Step 2: fetch_fill — sees POST-completion state, fills EMPTY slot
    // =========================================================================
    logic [31:0]   slot_current_nxt  [NUM_CTX][DESC_SLOT_WORDS];
    slot_state_e   slot_current_state_nxt [NUM_CTX];
    logic [31:0]   slot_next_nxt     [NUM_CTX][DESC_SLOT_WORDS];
    slot_state_e   slot_next_state_nxt [NUM_CTX];

    always_comb begin
        // ── Default: hold ──
        for (int i = 0; i < NUM_CTX; i++) begin
            slot_current_state_nxt[i] = slot_current_state[i];
            slot_next_state_nxt[i]    = slot_next_state[i];
            for (int w = 0; w < DESC_SLOT_WORDS; w++) begin
                slot_current_nxt[i][w] = slot_current[i][w];
                slot_next_nxt[i][w]    = slot_next[i][w];
            end
        end

        for (int i = 0; i < NUM_CTX; i++) begin

            // ── Step 1: Completion-driven slot management ──
            //
            // comp_done fires when an exec unit completes (or NOP/BARRIER).
            // At this point, slot_current still holds the inflight descriptor
            // (whose flags cp_completion has already read combinationally).
            //
            // Action: promote next→current if next is valid; else clear current.
            if (comp_done[i]) begin
                if (slot_next_state[i] == SLOT_VALID) begin
                    // Promote: next → current
                    for (int w = 0; w < DESC_SLOT_WORDS; w++)
                        slot_current_nxt[i][w] = slot_next[i][w];
                    slot_current_state_nxt[i] = SLOT_VALID;
                    slot_next_state_nxt[i]    = SLOT_EMPTY;
                end else begin
                    // Nothing to promote: clear current
                    slot_current_state_nxt[i] = SLOT_EMPTY;
                    // (current data becomes stale but state == EMPTY prevents use)
                end
            end

            // ── Step 2: Fetch fills descriptor data ──
            //
            // Runs AFTER Step 1, so it sees post-completion state.
            // If current is EMPTY (either was already empty, or just cleared
            // by comp_done), fill current directly for zero-latency availability.
            // Otherwise, fill next as prefetch.
            //
            // Edge case: comp_done promotes next→current AND fetch fills:
            //   Step 1 sets current_nxt=old_next(VALID), next_nxt=EMPTY
            //   Step 2 sees current_nxt=VALID, next_nxt=EMPTY → fills next
            //   Result: current=promoted, next=new fetch data. Correct!
            //
            // Edge case: comp_done clears current (no next) AND fetch fills:
            //   Step 1 sets current_nxt=EMPTY
            //   Step 2 sees current_nxt=EMPTY → fills current directly
            //   Result: current=new fetch data, zero bubble. Correct!
            if (fetch_fill_valid[i]) begin
                if (slot_current_state_nxt[i] == SLOT_EMPTY) begin
                    // Current is empty: fill current directly
                    for (int w = 0; w < DESC_SLOT_WORDS; w++)
                        slot_current_nxt[i][w] = fetch_fill_data[w];
                    slot_current_state_nxt[i] = SLOT_VALID;
                end else if (slot_next_state_nxt[i] == SLOT_EMPTY) begin
                    // Current occupied, next is empty: fill next
                    for (int w = 0; w < DESC_SLOT_WORDS; w++)
                        slot_next_nxt[i][w] = fetch_fill_data[w];
                    slot_next_state_nxt[i] = SLOT_VALID;
                end
                // else: both occupied — should not happen (fetch only starts
                // when next_state == EMPTY), but safely drops the fill.
            end
        end
    end

    // =========================================================================
    // Slot Register Update (sequential)
    // =========================================================================
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            for (int i = 0; i < NUM_CTX; i++) begin
                slot_current_state[i] <= SLOT_EMPTY;
                slot_next_state[i]    <= SLOT_EMPTY;
                for (int w = 0; w < DESC_SLOT_WORDS; w++) begin
                    slot_current[i][w] <= '0;
                    slot_next[i][w]    <= '0;
                end
            end
        end else if (cp_soft_reset) begin  // [STEP5 slang] sync cp_soft_reset split from async reset
            for (int i = 0; i < NUM_CTX; i++) begin
                slot_current_state[i] <= SLOT_EMPTY;
                slot_next_state[i]    <= SLOT_EMPTY;
                for (int w = 0; w < DESC_SLOT_WORDS; w++) begin
                    slot_current[i][w] <= '0;
                    slot_next[i][w]    <= '0;
                end
            end
        end else begin
            for (int i = 0; i < NUM_CTX; i++) begin
                slot_current_state[i] <= slot_current_state_nxt[i];
                slot_next_state[i]    <= slot_next_state_nxt[i];
                for (int w = 0; w < DESC_SLOT_WORDS; w++) begin
                    slot_current[i][w] <= slot_current_nxt[i][w];
                    slot_next[i][w]    <= slot_next_nxt[i][w];
                end
            end
        end
    end

    // =========================================================================
    // cp_csr Instance
    // =========================================================================
    cp_csr i_csr (
        .clk_i,
        .rst_ni,

        // OBI
        .req_i    ( mmio_req_i    ),
        .gnt_o    ( mmio_gnt_o    ),
        .rvalid_o ( mmio_rvalid_o ),
        .addr_i   ( mmio_addr_i   ),
        .we_i     ( mmio_we_i     ),
        .be_i     ( mmio_be_i     ),
        .wdata_i  ( mmio_wdata_i  ),
        .rdata_o  ( mmio_rdata_o  ),
        .err_o    ( mmio_err_o    ),

        // Control
        .cp_enable_o     ( cp_enable     ),
        .cp_soft_reset_o ( cp_soft_reset ),

        // Ring config
        .ring_base_o      ( ring_base      ),
        .ring_size_log2_o ( ring_size_log2 ),
        .ring_tail_o      ( ring_tail      ),
        .doorbell_pulse_o ( doorbell_pulse ),

        // Ring head (from fetch)
        .ring_head_i ( ring_head ),

        // Ctx states
        .ctx_state_i ( ctx_state ),

        // Region table
        .region_table_o ( region_table ),

        // Scoreboard
        .vec_busy_i  ( vec_busy  ),
        .tens_busy_i ( tens_busy ),
        .dma_busy_i  ( dma_busy  ),

        // R2.8: Power control (v4: register only, ICG in R6)
        .vec_clk_en_o  ( vec_clk_en  ),
        .tens_clk_en_o ( tens_clk_en ),
        .dma_clk_en_o  ( dma_clk_en ),

        // IRQ
        .irq_set_i ( irq_set ),
        .irq_o     ( irq_o   ),

        // R2.7b: Slot state visibility (from scheduler, combinational)
        .slot_state_vis_i ( slot_state_vis ),

        // R2.7: Issue snapshot (from scheduler)
        .issue_snap_valid_i   ( issue_snap_valid   ),
        .issue_snap_ctx_i     ( issue_snap_ctx     ),
        .issue_snap_opcode_i  ( issue_snap_opcode  ),
        .issue_snap_ext_len_i ( issue_snap_ext_len ),

        // R3.2b: Error (from scheduler)
        .error_valid_i ( error_valid ),
        .error_ctx_i   ( error_ctx   ),
        .error_class_i ( error_class ),

        // R3.2c: Clear error (to scheduler)
        .clear_error_o ( clear_error ),

        // R4.1: Watchdog threshold (to scheduler)
        .wd_threshold_o ( wd_threshold ),

        // R4.3: Watchdog timeout (from scheduler, for IRQ)
        .wd_timeout_i   ( wd_timeout   ),

        // R5.1: CP-side perf counters (from scheduler)
        .perf_ctx_blocked_i ( perf_ctx_blocked ),
        .perf_ctx_barrier_i ( perf_ctx_barrier ),
        .perf_ctx_starved_i ( perf_ctx_starved ),
        .perf_total_issue_i ( perf_total_issue ),
        .perf_total_done_i  ( perf_total_done  ),

        // R5.2: L2-side perf counters (from pe_top)
        .perf_l2_conflict_i   ( perf_l2_conflict_i   ),
        .perf_l2_vec_stall_i  ( perf_l2_vec_stall_i  ),
        .perf_l2_tens_stall_i ( perf_l2_tens_stall_i ),
        .perf_l2_dma_stall_i  ( perf_l2_dma_stall_i  ),

        // R5.3: Control outputs (to scheduler + pe_top)
        .perf_cnt_en_o    ( perf_cnt_en    ),
        .tens_yield_mode_o ( tens_yield_mode ),
        .tens_quota_n_o    ( tens_quota_n    ),

        // D7: Tag + credit observability (from scheduler)
        .vec_tag_valid_i  ( vec_tag_valid ),
        .tens_tag_valid_i ( tens_tag_valid ),
        .dma_tag_valid_i  ( dma_tag_valid ),
        .vec_credit_i     ( vec_credit    ),
        .tens_credit_i    ( tens_credit   ),
        .dma_credit_i     ( dma_credit    ),

        // D7: Event system
        .irq_pending_per_ctx_o ( irq_pending_per_ctx ),
        .event_clear_o         ( event_clear         ),
        .event_pending_i       ( event_pending       ),

        // D9: Trace ring control
        .trace_enable_o    ( trace_enable   ),
        .trace_freeze_o    ( trace_freeze   ),
        .trace_clear_o     ( trace_clear    ),
        .trace_rd_index_o  ( trace_rd_index ),
        .trace_rd_data_i   ( trace_rd_data  ),
        .trace_wr_ptr_i    ( trace_wr_ptr   ),
        .trace_overflow_i  ( trace_overflow ),
        .trace_count_i     ( trace_count    )
    );

    // =========================================================================
    // Descriptor Fetch Engine
    //   RR scans ctxs → reads L1D Port 1 at 64b/cycle → fills slots
    // =========================================================================
    cp_desc_fetch i_fetch (
        .clk_i,
        .rst_ni,

        .enable_i       ( cp_enable       ),
        .soft_reset_i   ( cp_soft_reset   ),   // P13: propagate soft_reset

        // L1D Port 1
        .l1d_addr_o     ( l1d_addr_o      ),
        .l1d_req_o      ( l1d_req_o       ),
        .l1d_rdata_i    ( l1d_rdata_i     ),
        .l1d_rvalid_i   ( l1d_rvalid_i    ),

        // Ring config (from CSR)
        .ring_base_i    ( ring_base       ),
        .ring_tail_i    ( ring_tail       ),
        .ring_size_log2_i ( ring_size_log2 ),  // P10: ring size for head wrap

        // Ring head (maintained by fetch, read by CSR)
        .ring_head_o    ( ring_head       ),

        // Slot status (check if desc_next is EMPTY before starting fetch)
        .next_state_i   ( slot_next_state ),

        // Fill output (to slot registers — routing decided by slot FSM above)
        .fill_valid_o   ( fetch_fill_valid ),
        .fill_ctx_o     ( fetch_fill_ctx   ),
        .fill_data_o    ( fetch_fill_data  )
    );

    // =========================================================================
    // Completion + Scheduler
    // =========================================================================

    // Completion → Scheduler: per-ctx done vectors + per-unit tags
    logic [NUM_CTX-1:0] done_vec, done_tens, done_dma;
    logic [TAG_W-1:0]   done_vec_tag, done_tens_tag, done_dma_tag;

    // [PHASE4-hygiene] vec_tag_valid / tens_tag_valid / dma_tag_valid and
    // vec_credit / tens_credit / dma_credit forward-declared at module top.
    //
    // [PHASE4-hygiene] irq_pending_per_ctx / event_clear / event_pending
    // forward-declared at module top.

    // ── cp_completion ──
    // Routes exec unit done + ctx_id + tag + NOP/BARRIER done into per-ctx events.
    logic [31:0] current_word0 [NUM_CTX];
    generate
        for (genvar i = 0; i < NUM_CTX; i++) begin : gen_word0
            assign current_word0[i] = slot_current[i][0];
        end
    endgenerate

    cp_completion i_completion (
        // Exec unit done
        .vec_done_i      ( vec_done_i      ),
        .vec_done_ctx_i  ( vec_done_ctx_i  ),
        .vec_done_tag_i  ( vec_done_tag_i  ),  // D4
        .tens_done_i     ( tens_done_i     ),
        .tens_done_ctx_i ( tens_done_ctx_i ),
        .tens_done_tag_i ( tens_done_tag_i ),  // D4
        .dma_done_i      ( dma_done_i      ),
        .dma_done_ctx_i  ( dma_done_ctx_i  ),
        .dma_done_tag_i  ( dma_done_tag_i  ),  // D4

        // NOP/BARRIER immediate done (from scheduler)
        .nop_done_i      ( nop_done        ),

        // Desc flags (for CHAIN_NEXT / IRQ_ON_DONE)
        .current_word0_i ( current_word0 ),

        // Per-ctx completion events (to slot FSM)
        .comp_done_o  ( comp_done  ),
        .comp_chain_o ( comp_chain ),

        // Per-ctx done vectors (to scheduler)
        .done_vec_o   ( done_vec   ),
        .done_tens_o  ( done_tens  ),
        .done_dma_o   ( done_dma   ),

        // D4: Per-unit done tags (to scheduler)
        .done_vec_tag_o  ( done_vec_tag  ),
        .done_tens_tag_o ( done_tens_tag ),
        .done_dma_tag_o  ( done_dma_tag  ),

        // IRQ
        .irq_set_o    ( irq_set   )
    );

    // ── cp_scheduler ──
    // Scans desc_current → RR select → scoreboard → issue
    // R1: ready-based scheduling, CTX_BLOCKED/DONE/ERROR, auto-promote
    cp_scheduler i_scheduler (
        .clk_i,
        .rst_ni,

        .enable_i       ( cp_enable     ),
        .soft_reset_i   ( cp_soft_reset ),

        // Per-ctx slots
        .slot_current_i  ( slot_current       ),
        .current_state_i ( slot_current_state ),

        // R1.2: Ring pointers + slot_next state (for CTX_DONE / auto-promote)
        .ring_head_i      ( ring_head       ),
        .ring_tail_i      ( ring_tail       ),
        .slot_next_state_i( slot_next_state ),

        // NOP/BARRIER immediate done (to completion router)
        .nop_done_o ( nop_done ),

        // R1.1b: Derived slot observability (combinational)
        .slot_state_vis_o ( slot_state_vis ),

        // Exec unit commands
        .vec_cmd_valid_o  ( vec_cmd_valid_o  ),
        .vec_cmd_o        ( vec_cmd_o        ),
        .vec_cmd_ready_i  ( vec_cmd_ready_i  ),

        .tens_cmd_valid_o ( tens_cmd_valid_o ),
        .tens_cmd_o       ( tens_cmd_o       ),
        .tens_cmd_ready_i ( tens_cmd_ready_i ),

        .dma_cmd_valid_o  ( dma_cmd_valid_o  ),
        .dma_cmd_o        ( dma_cmd_o        ),
        .dma_cmd_ready_i  ( dma_cmd_ready_i  ),

        // Region table
        .region_table_i ( region_table ),

        // Scoreboard
        .vec_busy_o  ( vec_busy  ),
        .tens_busy_o ( tens_busy ),
        .dma_busy_o  ( dma_busy  ),

        // D3/D7: Tag + credit observability (to CSR via new wires)
        .vec_tag_valid_o  ( vec_tag_valid  ),
        .tens_tag_valid_o ( tens_tag_valid ),
        .dma_tag_valid_o  ( dma_tag_valid  ),
        .vec_credit_o     ( vec_credit     ),
        .tens_credit_o    ( tens_credit    ),
        .dma_credit_o     ( dma_credit     ),

        // Done vectors (from completion)
        .done_vec_i  ( done_vec  ),
        .done_tens_i ( done_tens ),
        .done_dma_i  ( done_dma  ),

        // D4: Done tags (from completion)
        .done_vec_tag_i  ( done_vec_tag  ),
        .done_tens_tag_i ( done_tens_tag ),
        .done_dma_tag_i  ( done_dma_tag  ),

        // Context states
        .ctx_state_o ( ctx_state ),

        // R2.7: Issue snapshot (to CSR for CTX_DBG)
        .issue_snap_valid_o   ( issue_snap_valid   ),
        .issue_snap_ctx_o     ( issue_snap_ctx     ),
        .issue_snap_opcode_o  ( issue_snap_opcode  ),
        .issue_snap_ext_len_o ( issue_snap_ext_len ),

        // R3.2b: Error (to CSR for CTX_ERR)
        .error_valid_o ( error_valid ),
        .error_ctx_o   ( error_ctx   ),
        .error_class_o ( error_class ),

        // Doorbell
        .doorbell_pulse_i ( doorbell_pulse ),

        // R3.2c: Clear error (from CSR)
        .clear_error_i ( clear_error ),

        // R4.1: Watchdog
        .wd_threshold_i ( wd_threshold ),
        .wd_timeout_o   ( wd_timeout   ),

        // R5.1: Performance counters
        .perf_cnt_en_i      ( perf_cnt_en      ),
        .perf_ctx_blocked_o ( perf_ctx_blocked ),
        .perf_ctx_barrier_o ( perf_ctx_barrier ),
        .perf_ctx_starved_o ( perf_ctx_starved ),
        .perf_total_issue_o ( perf_total_issue ),
        .perf_total_done_o  ( perf_total_done  ),

        // D6/D7: Event system
        .irq_pending_i    ( irq_pending_per_ctx ),
        .event_clear_i    ( event_clear         ),
        .event_pending_o  ( event_pending       ),

        // [PHASE4-05] Event wake: formal port replacing hierarchical ref
        .event_wake_o     ( sched_event_wake    )
    );

    // =========================================================================
    // D9/R7.3: Event Trace Ring
    //
    // Records system events with timestamps into a circular buffer.
    // cp_csr provides control (enable/freeze/clear/index) and reads data.
    // The event collector below priority-encodes one event per cycle.
    // =========================================================================

    // ── Trace ring ↔ CSR wires ──
    // [PHASE4-hygiene] trace_enable/freeze/clear/rd_index/rd_data/wr_ptr/
    // overflow/count forward-declared at module top.

    // ── Event Collector: Priority Encoder ──
    //
    // Monitors system events each cycle and produces at most one
    // trace_entry_t. Priority (high→low):
    //   1. soft_reset        — critical system event
    //   2. error_valid       — error descriptor or watchdog
    //   3. issue_ok (exec)   — descriptor dispatched to exec unit
    //   4. done_vec/tens/dma — execution completion
    //   5. event_wake        — OP_WAIT wake-up
    //   5b. [PHASE4-06] fetch_stall_edge — ctx runnable but slot empty
    //   6. doorbell          — new work queued
    //
    // Only one event is recorded per cycle. Lower-priority events
    // that coincide with higher ones are dropped (acceptable for
    // debug trace; not a functional concern).
    //
    // Note: ctx state changes happen frequently and could flood the
    // ring. They are NOT traced by default. A future TRACE_MASK CSR
    // could enable selective tracing.
    // =========================================================================
    logic          trace_valid;
    trace_entry_t  trace_entry;

    // Convenience: scheduler signals accessible via hierarchical ref
    // are re-exported as local wires through the scheduler instance ports.
    // (issue_snap_valid/ctx/opcode already exist as internal wires.)

    always_comb begin
        trace_valid = 1'b0;
        trace_entry = '0;  // timestamp overwritten by trace ring module

        // Priority 1: Soft reset
        if (cp_soft_reset) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_SOFT_RESET;
            trace_entry.ctx_id       = '0;
            trace_entry.payload      = '0;
        end
        // Priority 2: Error
        else if (error_valid) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_ERROR;
            trace_entry.ctx_id       = error_ctx;
            trace_entry.payload      = {2'b0, error_class, 4'd0};
        end
        // Priority 3: Descriptor issued to exec unit
        else if (issue_snap_valid) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_ISSUE;
            trace_entry.ctx_id       = issue_snap_ctx;
            trace_entry.payload      = {2'b0, issue_snap_opcode};
        end
        // Priority 4: Completion (vec > tens > dma)
        else if (|done_vec) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_DONE_VEC;
            // Find which ctx completed (priority encoder)
            trace_entry.ctx_id       = done_vec[0] ? 2'd0 :
                                       done_vec[1] ? 2'd1 :
                                       done_vec[2] ? 2'd2 : 2'd3;
            trace_entry.payload      = {7'd0, done_vec_tag};
        end
        else if (|done_tens) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_DONE_TENS;
            trace_entry.ctx_id       = done_tens[0] ? 2'd0 :
                                       done_tens[1] ? 2'd1 :
                                       done_tens[2] ? 2'd2 : 2'd3;
            trace_entry.payload      = {7'd0, done_tens_tag};
        end
        else if (|done_dma) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_DONE_DMA;
            trace_entry.ctx_id       = done_dma[0] ? 2'd0 :
                                       done_dma[1] ? 2'd1 :
                                       done_dma[2] ? 2'd2 : 2'd3;
            trace_entry.payload      = {7'd0, done_dma_tag};
        end
        // Priority 5: Event wake (any ctx)
        else if (|event_wake) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_EVENT_WAKE;
            trace_entry.ctx_id       = event_wake[0] ? 2'd0 :
                                       event_wake[1] ? 2'd1 :
                                       event_wake[2] ? 2'd2 : 2'd3;
            trace_entry.payload      = {2'b0, event_pending[trace_entry.ctx_id]};
        end
        // [PHASE4-06] Priority 5b: FETCH_STALL edge (any ctx)
        //
        // D38-a definition: ctx runnable but both slots empty.
        // Edge-triggered: fires once when stall begins. Payload encodes
        // the ctx's current vs next slot_state as 4-bit information
        // (high 2 bits = current_state, low 2 bits = next_state), mostly
        // '00:00' by definition of the trigger, but the field is reserved
        // in case the trigger predicate is relaxed in a future revision.
        else if (|fetch_stall_edge) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_FETCH_STALL;
            trace_entry.ctx_id       = fetch_stall_edge[0] ? 2'd0 :
                                       fetch_stall_edge[1] ? 2'd1 :
                                       fetch_stall_edge[2] ? 2'd2 : 2'd3;
            trace_entry.payload      = {2'b0,
                                        slot_current_state[trace_entry.ctx_id],
                                        slot_next_state   [trace_entry.ctx_id],
                                        4'd0};
        end
        // Priority 6: Doorbell (any ctx)
        else if (|doorbell_pulse) begin
            trace_valid              = 1'b1;
            trace_entry.event_type   = TRACE_DOORBELL;
            trace_entry.ctx_id       = doorbell_pulse[0] ? 2'd0 :
                                       doorbell_pulse[1] ? 2'd1 :
                                       doorbell_pulse[2] ? 2'd2 : 2'd3;
            trace_entry.payload      = '0;
        end
    end

    // ── Trace ring ↔ scheduler event_wake wire ──
    //
    // [PHASE4-05] event_wake is now exposed as cp_scheduler.event_wake_o
    // (a formal output port), replacing the prior hierarchical reference
    // i_scheduler.event_wake[i]. sched_event_wake is forward-declared
    // at module top; event_wake alias is also forward-declared at top.
    // The v4 post-filter "ctx_state == CTX_RUNNABLE && ..." was redundant
    // — a wake event by definition transitions into RUNNABLE.
    assign event_wake = sched_event_wake;

    // ── [PHASE4-06] FETCH_STALL edge detection (D38-a) ──
    //
    // Definition of "fetch stall" for a ctx:
    //   ctx_state == CTX_RUNNABLE  — the ctx could issue work, AND
    //   slot_current_state == SLOT_EMPTY  — but the active slot is empty, AND
    //   slot_next_state    == SLOT_EMPTY  — and no prefetched slot either
    //
    // Interpretation: the context could run, but the fetch engine hasn't
    // caught up. This is the observable signature of "software queued
    // work via doorbell, but L1D fetch latency or arbiter conflicts
    // delayed slot fill".
    //
    // Edge-triggered: fire ONCE per stall entry (i.e. when the condition
    // transitions from non-stall to stall). Without edge detection, a
    // multi-cycle stall would flood the 64-entry trace ring.
    //
    // fetch_stall_edge is forward-declared at module top.
    logic [NUM_CTX-1:0] fetch_stall_now;
    logic [NUM_CTX-1:0] fetch_stall_prev_q;

    always_comb begin
        for (int i = 0; i < NUM_CTX; i++) begin
            fetch_stall_now[i] = (ctx_state[i]           == CTX_RUNNABLE) &&
                                 (slot_current_state[i]  == SLOT_EMPTY  ) &&
                                 (slot_next_state[i]     == SLOT_EMPTY  );
        end
    end

    // Rising-edge detection: stall just entered (was not stall last cycle)
    assign fetch_stall_edge = fetch_stall_now & ~fetch_stall_prev_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)
            fetch_stall_prev_q <= '0;
        else if (cp_soft_reset)  // [STEP5 slang] sync cp_soft_reset split from async reset
            fetch_stall_prev_q <= '0;
        else
            fetch_stall_prev_q <= fetch_stall_now;
    end

    // ── event_trace_ring Instance ──
    event_trace_ring i_trace (
        .clk_i,
        .rst_ni,
        .soft_reset_i    ( cp_soft_reset  ),

        .trace_valid_i   ( trace_valid    ),
        .trace_entry_i   ( trace_entry    ),

        .trace_enable_i  ( trace_enable   ),
        .trace_freeze_i  ( trace_freeze   ),
        .trace_clear_i   ( trace_clear    ),

        .trace_rd_index_i( trace_rd_index ),
        .trace_rd_data_o ( trace_rd_data  ),

        .trace_wr_ptr_o  ( trace_wr_ptr   ),
        .trace_overflow_o( trace_overflow ),
        .trace_count_o   ( trace_count    )
    );

endmodule

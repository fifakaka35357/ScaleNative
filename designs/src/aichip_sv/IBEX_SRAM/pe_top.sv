// =============================================================================
// pe_top.sv — H-Tensor PE Top-Level (PE v5, Phase 6a rewrite)
//
// =============================================================================
// PHASE 6 REWRITE SUMMARY
// =============================================================================
//
//   [PHASE6-01] Adopt Phase 2a/2b wrappers:
//                 ibex_core directly instantiated -> pe_ibex_wrapper
//                 sky130_fd_sc_hd__sdlclkp_1      -> tech_icg_wrapper (scan ICG)
//                 tens_traffic_gen / vec_traffic_gen (v4 stubs, now renamed
//                 in Phase 5 to tensor_unit_stub / vector_unit_stub) are
//                 instantiated inside tensor_unit_top / vector_unit_top
//                 wrappers, which pe_top connects to instead of instantiating
//                 the stubs directly.
//
//   [PHASE6-02] Post-Phase-3-B2 L2 interface widths and semantics:
//                 Tens domain: WIDE master, 512b = 16 banks x 32b, no half_sel
//                 Vec  domain: NARROW master, 256b = 8 banks x 32b, 1-bit
//                              half_sel (which 8 of 16 banks)
//                 (v4 had the reverse: vec = wide, tens = narrow.)
//               All pe_top local wires renamed/resized accordingly.
//
//   [PHASE6-03] Fast path (tv_fast_fifo) is left DISCONNECTED in Phase 6a:
//                 tensor_unit_top.fwd_out_* -- wrapper ties off to
//                                              NOT-SUPPORTED (D11-b')
//                 vector_unit_top.fwd_out_* -- same
//                 The fast path will be wired in Phase 8+ when the real
//                 Tensor and Vector Unit RTL replaces the traffic-generator
//                 stubs and actually produces forwarded fragments. For now,
//                 the wrappers' tie-offs give "back-pressure rather than
//                 silent data loss" if anything mistakenly drives them.
//
//   [PHASE6-04] Phase 4->6 boundary markers RESOLVED:
//                 The "tens_ro_bank_half_i / tens_rw_bank_half_i do not
//                 exist in l2_subsystem" errors accepted at the end of
//                 Phase 4 are now eliminated. The Tens master has no
//                 half_sel; only Vec (narrow) has vec_*_half_sel_i.
//
//   [PHASE6-05] pe_assertions.sv update is reserved for Phase 6b (next
//                 round). This file (pe_top.sv) does NOT include a bind
//                 to pe_assertions -- that bind is expected to live in a
//                 testbench or the pe_assertions file itself. Phase 6b
//                 will audit and fix.
//
// =============================================================================
// ARCHITECTURE
// =============================================================================
//
//   IBEX Core -- OBI instr --> L1I (boot + fetch)
//   IBEX Core -- OBI data --> addr_decoder -- > L1D Port 0 (CPU RW)
//                                           -- > MMIO (CP CSR, Region Table)
//                                           -- > unmapped -> bus error
//
//   CP desc_fetch -- 64b read --> L1D Port 1 (both banks parallel)
//   CP scheduler  -- cmd      --> Vector / Tensor / DMA units
//   Vector Unit   -> L2 (256b half-stripe, 8 banks x 32b, half_sel)
//   Tensor Unit   -> L2 (512b full stripe, 16 banks x 32b)
//   DMA Engine    -> L2 (32b single-bank) + NoC
//
// Clock gating (R6.1):
//   PE_POWER_CTRL CSR (R2.8) controls per-unit clock gates.
//   tech_icg_wrapper wraps sky130_fd_sc_hd__sdlclkp_1 (or ASAP7 / NANGATE45
//   equivalents via PDK_* ifdefs). Gated clocks feed Vec/Tens/DMA units;
//   ungated clock feeds CP / L2 / IBEX (always-on).
//
// Reset domain (R6.2):
//   Hard reset (rst_ni):    clears ALL state (config + runtime)
//   Soft reset (cp_soft_reset): clears runtime state only, preserves config.
//                               Driven by command_processor; routed to
//                               exec units.
//
// =============================================================================

module pe_top
    import pe_pkg::*;
#(
    // IBEX Core Parameters (exposed for top-level configuration,
    // forwarded to pe_ibex_wrapper which forwards to ibex_core).
    parameter bit          PMPEnable        = 1'b0,
    parameter int unsigned PMPGranularity   = 0,
    parameter int unsigned PMPNumRegions    = 4,
    parameter int unsigned MHPMCounterNum   = 0,
    parameter int unsigned MHPMCounterWidth = 40,
    parameter bit          RV32E            = 1'b0,
    parameter bit          BranchTargetALU  = 1'b0,
    parameter bit          WritebackStage   = 1'b0,
    parameter bit          ICache           = 1'b0,
    parameter bit          ICacheECC        = 1'b0,
    parameter bit          BranchPredictor  = 1'b0,
    parameter bit          DbgTriggerEn     = 1'b0,
    parameter int unsigned DbgHwBreakNum    = 1,
    parameter bit          SecureIbex       = 1'b0,
    parameter int unsigned DmHaltAddr       = 32'h1A110800,
    parameter int unsigned DmExceptionAddr  = 32'h1A110808,
    parameter int unsigned BOOT_ADDR        = 32'h0000_0000
) (
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Boot Interface (write program to L1I before releasing fetch) ──
    input  logic        boot_req_i,
    input  logic        boot_we_i,
    input  logic [31:0] boot_addr_i,
    input  logic [31:0] boot_wdata_i,
    input  logic [3:0]  boot_be_i,

    // ── IBEX Control ──
    input  logic        test_en_i,
    input  logic [31:0] hart_id_i,
    input  logic        fetch_enable_i,

    // ── Interrupts ──
    input  logic        irq_software_i,
    input  logic        irq_timer_i,
    input  logic        irq_external_i,
    input  logic [14:0] irq_fast_i,
    input  logic        irq_nm_i,

    // ── Debug ──
    input  logic        debug_req_i,

    // ── Status ──
    output logic        alert_minor_o,
    output logic        alert_major_o,
    output logic        core_sleep_o,

    // ── NoC Interface (DMA) ──
    input  logic        noc_ing_valid_i,
    input  logic [31:0] noc_ing_data_i,
    input  logic        noc_ing_last_i,
    output logic        noc_ing_ready_o,

    output logic        noc_egr_valid_o,
    output logic [31:0] noc_egr_data_o,
    output logic        noc_egr_last_o,
    input  logic        noc_egr_ready_i
);

    // =========================================================================
    // [FIX 2026-07-12, pre-tapeout audit] Reset synchronizer — async assert,
    // SYNCHRONOUS de-assert.
    //
    // rst_ni previously fed every async-reset pin in the design directly, so its
    // RELEASE was asynchronous to clk_i. A release that lands inside a flop's
    // recovery/removal window is metastable, and different flops across a 2.4M-cell
    // die see the release at different times => the chip can come out of reset in a
    // partially-reset state. This is the classic silicon-only failure that never
    // shows up in RTL simulation, and the SDC's `set_false_path -from rst_ni` means
    // STA was not checking recovery/removal either.
    //
    // The 2-flop synchronizer keeps the asynchronous assertion (so reset still works
    // with no clock) but aligns the de-assertion to clk_i. rst_ni remains a false_path
    // in the SDC — now correctly, because the only paths from it are the async pins of
    // these two flops, and everything else releases synchronously.
    //
    // Placement note: clk_i is the ungated root. The three gated domains are all
    // clocked during reset (cp_csr reg_power_ctrl resets to 3'b111 = all clocks on),
    // so the synchronous release propagates into them correctly.
    // =========================================================================
    logic [1:0] rst_sync_q;
    logic       rst_n_sync;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) rst_sync_q <= 2'b00;
        else         rst_sync_q <= {rst_sync_q[0], 1'b1};
    end
    assign rst_n_sync = rst_sync_q[1];

    // =========================================================================
    // Internal Wires
    // =========================================================================

    // ── IBEX OBI (instruction) ──
    logic        instr_req, instr_gnt, instr_rvalid;
    logic [31:0] instr_addr, instr_rdata;
    logic        instr_err;

    // ── IBEX OBI (data) — before addr_decoder ──
    logic        data_req, data_gnt, data_rvalid;
    logic        data_we;
    logic [3:0]  data_be;
    logic [31:0] data_addr, data_wdata, data_rdata;
    logic        data_err;

    // ── L1D (CPU side, post addr_decoder) ──
    logic        l1d_cpu_req, l1d_cpu_gnt, l1d_cpu_rvalid;
    logic [31:0] l1d_cpu_addr, l1d_cpu_wdata, l1d_cpu_rdata;
    logic        l1d_cpu_we;
    logic [3:0]  l1d_cpu_be;
    logic        l1d_cpu_err;

    // ── MMIO (post addr_decoder) ──
    logic        mmio_req, mmio_gnt, mmio_rvalid;
    logic [31:0] mmio_addr, mmio_wdata, mmio_rdata;
    logic        mmio_we;
    logic [3:0]  mmio_be;
    logic        mmio_err;

    // ── L1D Port 1 (CP descriptor fetch, 64b parallel) ──
    logic                    l1d_cp_req;
    logic [L1D_BANK_AW-1:0]  l1d_cp_addr;
    logic [63:0]             l1d_cp_rdata;
    logic                    l1d_cp_rvalid;

    // ── CP ↔ Exec commands ──
    logic       vec_cmd_valid,  vec_cmd_ready;
    vec_cmd_t   vec_cmd;
    logic       tens_cmd_valid, tens_cmd_ready;
    tens_cmd_t  tens_cmd;
    logic       dma_cmd_valid,  dma_cmd_ready;
    dma_cmd_t   dma_cmd;

    // ── Exec → Completion ──
    logic                  vec_done,  tens_done,  dma_done;
    logic [CTX_ID_W-1:0]   vec_done_ctx, tens_done_ctx, dma_done_ctx;
    logic [TAG_W-1:0]      vec_done_tag, tens_done_tag, dma_done_tag;

    // ── CP IRQ + control ──
    logic       cp_irq;
    logic       cp_soft_reset;  // P13: routed to exec units

    // ── Performance counters / yield ──
    logic                  perf_cnt_en;
    logic [PERF_CNT_W-1:0] perf_l2_conflict;
    logic [9:0]            perf_l2_vec_stall;
    logic [9:0]            perf_l2_tens_stall;
    logic [9:0]            perf_l2_dma_stall;
    logic [1:0]            tens_yield_mode;   // [PHASE4-10] renamed
    logic [3:0]            tens_quota_n;      // [PHASE4-10] renamed

    // ── R6.1: Clock enables + gated clocks ──
    logic       vec_clk_en, tens_clk_en, dma_clk_en;
    logic       vec_gated_clk, tens_gated_clk, dma_gated_clk;

    // =========================================================================
    // [PHASE6-02] L2 interface wires — post-Phase-3-B2 widths
    //
    // Role swap vs v4:
    //   Tens = WIDE master: 512b data, 16-bank mask, NO half_sel
    //   Vec  = NARROW master: 256b data, 8-bank mask, 1-bit half_sel
    // =========================================================================

    // Vector RO (256b read, 8 of 16 banks; half_sel chooses which 8)
    logic                              vec_ro_req, vec_ro_gnt;
    logic [L2_BANK_AW-1:0]             vec_ro_row;
    logic                              vec_ro_half_sel;
    logic                              vec_ro_rvalid;
    logic [HALF_STRIPE_W-1:0]          vec_ro_rdata;       // 256b

    // Vector RW (256b write)
    logic                              vec_rw_req, vec_rw_gnt;
    logic [L2_BANK_AW-1:0]             vec_rw_row;
    logic                              vec_rw_half_sel;
    logic [(L2_NUM_BANKS/2)-1:0]       vec_rw_bank_mask;   // 8-bit
    logic [HALF_STRIPE_W-1:0]          vec_rw_wdata;       // 256b

    // Tensor RO (512b read, 16 banks, no half_sel)
    logic                              tens_ro_req, tens_ro_gnt;
    logic [L2_BANK_AW-1:0]             tens_ro_row;
    logic                              tens_ro_rvalid;
    logic [FULL_STRIPE_W-1:0]          tens_ro_rdata;      // 512b

    // Tensor RW (512b write, 16-bank mask)
    logic                              tens_rw_req, tens_rw_gnt;
    logic [L2_BANK_AW-1:0]             tens_rw_row;
    logic [L2_NUM_BANKS-1:0]           tens_rw_bank_mask;  // 16-bit
    logic [FULL_STRIPE_W-1:0]          tens_rw_wdata;      // 512b

    // DMA fill (write, single bank)
    logic                              dma_fill_req, dma_fill_gnt;
    logic [L2_BANK_SEL_W-1:0]          dma_fill_bank;
    logic [L2_BANK_AW-1:0]                dma_fill_row;
    logic [31:0]                       dma_fill_wdata;
    logic [3:0]                        dma_fill_be;

    // DMA evict (read, single bank)
    logic                              dma_evict_req, dma_evict_gnt;
    logic                              dma_evict_rvalid;
    logic [L2_BANK_SEL_W-1:0]          dma_evict_bank;
    logic [L2_BANK_AW-1:0]                dma_evict_row;
    logic [31:0]                       dma_evict_rdata;

    // =========================================================================
    // [PHASE6-01] IBEX core via pe_ibex_wrapper
    // =========================================================================
    pe_ibex_wrapper #(
        .PMPEnable        ( PMPEnable        ),
        .PMPGranularity   ( PMPGranularity   ),
        .PMPNumRegions    ( PMPNumRegions    ),
        .MHPMCounterNum   ( MHPMCounterNum   ),
        .MHPMCounterWidth ( MHPMCounterWidth ),
        .RV32E            ( RV32E            ),
        .BranchTargetALU  ( BranchTargetALU  ),
        .WritebackStage   ( WritebackStage   ),
        .ICache           ( ICache           ),
        .ICacheECC        ( ICacheECC        ),
        .BranchPredictor  ( BranchPredictor  ),
        .DbgTriggerEn     ( DbgTriggerEn     ),
        .DbgHwBreakNum    ( DbgHwBreakNum    ),
        .SecureIbex       ( SecureIbex       ),
        .DmHaltAddr       ( DmHaltAddr       ),
        .DmExceptionAddr  ( DmExceptionAddr  ),
        .BOOT_ADDR        ( BOOT_ADDR        )
    ) i_ibex (
        .clk_i,
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release

        .test_en_i,
        .hart_id_i,
        .fetch_enable_i,

        .instr_req_o    ( instr_req    ),
        .instr_gnt_i    ( instr_gnt    ),
        .instr_rvalid_i ( instr_rvalid ),
        .instr_addr_o   ( instr_addr   ),
        .instr_rdata_i  ( instr_rdata  ),
        .instr_err_i    ( instr_err    ),

        .data_req_o    ( data_req    ),
        .data_gnt_i    ( data_gnt    ),
        .data_rvalid_i ( data_rvalid ),
        .data_we_o     ( data_we     ),
        .data_be_o     ( data_be     ),
        .data_addr_o   ( data_addr   ),
        .data_wdata_o  ( data_wdata  ),
        .data_rdata_i  ( data_rdata  ),
        .data_err_i    ( data_err    ),

        .irq_software_i,
        .irq_timer_i,
        .irq_external_i,
        .irq_fast_i,
        .irq_nm_i,
        .cp_irq_i       ( cp_irq ),

        .debug_req_i,

        .alert_minor_o,
        .alert_major_o,
        .core_sleep_o
    );

    // =========================================================================
    // Address Decoder
    // =========================================================================
    addr_decoder i_addr_decoder (
        .clk_i,
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release

        .cpu_req_i    ( data_req    ),
        .cpu_gnt_o    ( data_gnt    ),
        .cpu_rvalid_o ( data_rvalid ),
        .cpu_addr_i   ( data_addr   ),
        .cpu_we_i     ( data_we     ),
        .cpu_be_i     ( data_be     ),
        .cpu_wdata_i  ( data_wdata  ),
        .cpu_rdata_o  ( data_rdata  ),
        .cpu_err_o    ( data_err    ),

        .l1d_req_o    ( l1d_cpu_req    ),
        .l1d_gnt_i    ( l1d_cpu_gnt    ),
        .l1d_rvalid_i ( l1d_cpu_rvalid ),
        .l1d_addr_o   ( l1d_cpu_addr   ),
        .l1d_we_o     ( l1d_cpu_we     ),
        .l1d_be_o     ( l1d_cpu_be     ),
        .l1d_wdata_o  ( l1d_cpu_wdata  ),
        .l1d_rdata_i  ( l1d_cpu_rdata  ),
        .l1d_err_i    ( l1d_cpu_err    ),

        .mmio_req_o    ( mmio_req    ),
        .mmio_gnt_i    ( mmio_gnt    ),
        .mmio_rvalid_i ( mmio_rvalid ),
        .mmio_addr_o   ( mmio_addr   ),
        .mmio_we_o     ( mmio_we     ),
        .mmio_be_o     ( mmio_be     ),
        .mmio_wdata_o  ( mmio_wdata  ),
        .mmio_rdata_i  ( mmio_rdata  ),
        .mmio_err_i    ( mmio_err    )
    );

    // =========================================================================
    // L1 Subsystem (I + D)
    // =========================================================================
    l1_subsystem i_l1 (
        .clk_i,
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release
        .soft_reset_i ( cp_soft_reset ),   // 波1: flush L1D CP-read pipe in lockstep with cp_desc_fetch

        .boot_req_i,
        .boot_we_i,
        .boot_addr_i,
        .boot_wdata_i,
        .boot_be_i,

        .instr_req_i    ( instr_req    ),
        .instr_gnt_o    ( instr_gnt    ),
        .instr_rvalid_o ( instr_rvalid ),
        .instr_addr_i   ( instr_addr   ),
        .instr_rdata_o  ( instr_rdata  ),
        .instr_err_o    ( instr_err    ),

        .cpu_req_i    ( l1d_cpu_req         ),
        .cpu_gnt_o    ( l1d_cpu_gnt         ),
        .cpu_rvalid_o ( l1d_cpu_rvalid      ),
        .cpu_addr_i   ( l1d_cpu_addr[11:0]  ),  // 12-bit byte-addr within 4KB L1D
        .cpu_we_i     ( l1d_cpu_we          ),
        .cpu_be_i     ( l1d_cpu_be          ),
        .cpu_wdata_i  ( l1d_cpu_wdata       ),
        .cpu_rdata_o  ( l1d_cpu_rdata       ),
        .cpu_err_o    ( l1d_cpu_err         ),

        .cp_req_i    ( l1d_cp_req    ),
        .cp_addr_i   ( l1d_cp_addr   ),
        .cp_rdata_o  ( l1d_cp_rdata  ),
        .cp_rvalid_o ( l1d_cp_rvalid )
    );

    // =========================================================================
    // [PHASE6-01] Clock Gating via tech_icg_wrapper
    // =========================================================================
    // [2026-07-12 DFT contract] test_en_i now reaches the clock gates.
    //   It used to go only to the IBEX. During scan shift the gate enables come
    //   from cp_csr flops that are themselves on the scan chain, so without this
    //   override the three gated domains would lose their clock mid-pattern and
    //   the scan chain would break. The tape-out partner inserts DFT on THIS RTL,
    //   so the hook must exist here. In functional mode test_en_i = 0 and nothing
    //   changes.
    tech_icg_wrapper u_vec_icg (
        .clk_i      ( clk_i         ),
        .gate_en_i  ( vec_clk_en    ),
        .test_en_i  ( test_en_i     ),
        .gated_clk_o( vec_gated_clk )
    );
    tech_icg_wrapper u_tens_icg (
        .clk_i      ( clk_i          ),
        .gate_en_i  ( tens_clk_en    ),
        .test_en_i  ( test_en_i      ),
        .gated_clk_o( tens_gated_clk )
    );
    tech_icg_wrapper u_dma_icg (
        .clk_i      ( clk_i         ),
        .gate_en_i  ( dma_clk_en    ),
        .test_en_i  ( test_en_i     ),
        .gated_clk_o( dma_gated_clk )
    );

    // =========================================================================
    // [PHASE6-02] L2 Subsystem
    // =========================================================================
    l2_subsystem i_l2 (
        .clk_i,
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release
        .soft_reset_i ( cp_soft_reset ),

        // Vector RO (256b read)
        .vec_ro_req_i       ( vec_ro_req       ),
        .vec_ro_row_i       ( vec_ro_row       ),
        .vec_ro_half_sel_i  ( vec_ro_half_sel  ),
        .vec_ro_gnt_o       ( vec_ro_gnt       ),
        .vec_ro_rvalid_o    ( vec_ro_rvalid    ),
        .vec_ro_rdata_o     ( vec_ro_rdata     ),

        // Vector RW (256b write)
        .vec_rw_req_i       ( vec_rw_req       ),
        .vec_rw_row_i       ( vec_rw_row       ),
        .vec_rw_half_sel_i  ( vec_rw_half_sel  ),
        .vec_rw_bank_mask_i ( vec_rw_bank_mask ),
        .vec_rw_wdata_i     ( vec_rw_wdata     ),
        .vec_rw_gnt_o       ( vec_rw_gnt       ),

        // Tensor RO (512b read, no half_sel)
        .tens_ro_req_i      ( tens_ro_req      ),
        .tens_ro_row_i      ( tens_ro_row      ),
        .tens_ro_gnt_o      ( tens_ro_gnt      ),
        .tens_ro_rvalid_o   ( tens_ro_rvalid   ),
        .tens_ro_rdata_o    ( tens_ro_rdata    ),

        // Tensor RW (512b write, 16-bank mask)
        .tens_rw_req_i       ( tens_rw_req       ),
        .tens_rw_row_i       ( tens_rw_row       ),
        .tens_rw_bank_mask_i ( tens_rw_bank_mask ),
        .tens_rw_wdata_i     ( tens_rw_wdata     ),
        .tens_rw_gnt_o       ( tens_rw_gnt       ),

        // DMA Fill
        .dma_fill_req_i   ( dma_fill_req   ),
        .dma_fill_bank_i  ( dma_fill_bank  ),
        .dma_fill_row_i   ( dma_fill_row   ),
        .dma_fill_wdata_i ( dma_fill_wdata ),
        .dma_fill_be_i    ( dma_fill_be    ),
        .dma_fill_gnt_o   ( dma_fill_gnt   ),

        // DMA Evict
        .dma_evict_req_i    ( dma_evict_req    ),
        .dma_evict_bank_i   ( dma_evict_bank   ),
        .dma_evict_row_i    ( dma_evict_row    ),
        .dma_evict_gnt_o    ( dma_evict_gnt    ),
        .dma_evict_rvalid_o ( dma_evict_rvalid ),
        .dma_evict_rdata_o  ( dma_evict_rdata  ),

        // Yield + perf
        .tens_yield_mode_i    ( tens_yield_mode    ),
        .tens_quota_n_i       ( tens_quota_n       ),
        .perf_cnt_en_i        ( perf_cnt_en        ),
        .perf_l2_conflict_o   ( perf_l2_conflict   ),
        .perf_l2_vec_stall_o  ( perf_l2_vec_stall  ),
        .perf_l2_tens_stall_o ( perf_l2_tens_stall ),
        .perf_l2_dma_stall_o  ( perf_l2_dma_stall  )
    );

    // =========================================================================
    // Command Processor
    // =========================================================================
    command_processor i_cp (
        .clk_i,
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release

        .mmio_req_i    ( mmio_req    ),
        .mmio_gnt_o    ( mmio_gnt    ),
        .mmio_rvalid_o ( mmio_rvalid ),
        .mmio_addr_i   ( mmio_addr   ),
        .mmio_we_i     ( mmio_we     ),
        .mmio_be_i     ( mmio_be     ),
        .mmio_wdata_i  ( mmio_wdata  ),
        .mmio_rdata_o  ( mmio_rdata  ),
        .mmio_err_o    ( mmio_err    ),

        .l1d_addr_o    ( l1d_cp_addr   ),
        .l1d_req_o     ( l1d_cp_req    ),
        .l1d_rdata_i   ( l1d_cp_rdata  ),
        .l1d_rvalid_i  ( l1d_cp_rvalid ),

        // [FIX 2026-07-12, pre-tapeout audit] Clock-gating interlock.
        //   cmd_ready of each unit is a pure state decode inside its GATED clock
        //   domain (e.g. tensor_domain_top: cmd_ready_o = (ws_q == W_IDLE)). With
        //   the clock stopped, that decode FREEZES at 1 while the CP keeps running
        //   on the ungated clk_i and never looks at *_clk_en (cp_scheduler:
        //   issue_ok = valid & ready). The handshake then "succeeds" against a unit
        //   that has no clock to latch the command with => the command is SILENTLY
        //   LOST and the CP waits for a done that will never come.
        //   Qualifying ready with the unit's own clock enable makes a stopped unit
        //   look busy, which is exactly the correct back-pressure.
        .vec_cmd_valid_o  ( vec_cmd_valid  ),
        .vec_cmd_o        ( vec_cmd        ),
        .vec_cmd_ready_i  ( vec_cmd_ready  & vec_clk_en  ),

        .tens_cmd_valid_o ( tens_cmd_valid ),
        .tens_cmd_o       ( tens_cmd       ),
        .tens_cmd_ready_i ( tens_cmd_ready & tens_clk_en ),

        .dma_cmd_valid_o  ( dma_cmd_valid  ),
        .dma_cmd_o        ( dma_cmd        ),
        .dma_cmd_ready_i  ( dma_cmd_ready  & dma_clk_en  ),

        .vec_done_i      ( vec_done      ),
        .vec_done_ctx_i  ( vec_done_ctx  ),
        .vec_done_tag_i  ( vec_done_tag  ),
        .tens_done_i     ( tens_done     ),
        .tens_done_ctx_i ( tens_done_ctx ),
        .tens_done_tag_i ( tens_done_tag ),
        .dma_done_i      ( dma_done      ),
        .dma_done_ctx_i  ( dma_done_ctx  ),
        .dma_done_tag_i  ( dma_done_tag  ),

        .irq_o ( cp_irq ),

        .cp_soft_reset_o ( cp_soft_reset ),

        .perf_l2_conflict_i   ( perf_l2_conflict   ),
        .perf_l2_vec_stall_i  ( perf_l2_vec_stall  ),
        .perf_l2_tens_stall_i ( perf_l2_tens_stall ),
        .perf_l2_dma_stall_i  ( perf_l2_dma_stall  ),
        .perf_cnt_en_o        ( perf_cnt_en        ),
        .tens_yield_mode_o    ( tens_yield_mode    ),
        .tens_quota_n_o       ( tens_quota_n       ),

        .vec_clk_en_o  ( vec_clk_en  ),
        .tens_clk_en_o ( tens_clk_en ),
        .dma_clk_en_o  ( dma_clk_en  )
    );

    // =========================================================================
    // [PHASE6-01] Execution units via wrappers (now wrapping the REAL cores)
    // [STEP4-E2E inc 4] Tensor → Vector fast path wired via tv_fast_fifo below.
    // =========================================================================

    // ── Tensor → Vector fast-path nets (whole bs_capsule_t, Q1) ──
    localparam int    TV_DW = $bits(bs_capsule_t);
    logic             tens_t2v_valid, tens_t2v_ready, tens_t2v_escape;
    bs_capsule_t      tens_t2v_cap;
    logic             tv_out_valid, tv_out_ready;
    logic [TV_DW-1:0] tv_out_data;
    bs_capsule_t      tv_out_cap;
    assign tv_out_cap = bs_capsule_t'(tv_out_data);

    // Vector Unit
    vector_unit_top i_vec (
        .clk_i        ( vec_gated_clk ),
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release
        .soft_reset_i ( cp_soft_reset ),

        .cmd_valid_i ( vec_cmd_valid ),
        .cmd_ready_o ( vec_cmd_ready ),
        .cmd_i       ( vec_cmd       ),

        // L2 RO (256b)
        .ro_req_o      ( vec_ro_req      ),
        .ro_gnt_i      ( vec_ro_gnt      ),
        .ro_rvalid_i   ( vec_ro_rvalid   ),
        .ro_half_sel_o ( vec_ro_half_sel ),
        .ro_row_o      ( vec_ro_row      ),
        .ro_rdata_i    ( vec_ro_rdata    ),

        // L2 RW (256b)
        .rw_req_o       ( vec_rw_req       ),
        .rw_gnt_i       ( vec_rw_gnt       ),
        .rw_half_sel_o  ( vec_rw_half_sel  ),
        .rw_row_o       ( vec_rw_row       ),
        .rw_bank_mask_o ( vec_rw_bank_mask ),
        .rw_wdata_o     ( vec_rw_wdata     ),

        // Fast Path (bs_capsule_t, Q1): t2v ingress fed by tv_fast_fifo from
        // the Tensor egress; v2t egress unused for the GEMM->RESADD->L2_WB E2E.
        .t2v_valid_i       ( tv_out_valid ),
        .t2v_ready_o       ( tv_out_ready ),
        .t2v_cap_i         ( tv_out_cap   ),
        .t2v_miss_valid_o  (              ),
        .t2v_miss_reason_o (              ),
        .v2t_valid_o       (           ),
        .v2t_ready_i       ( 1'b0      ),
        .v2t_cap_o         (           ),
        .v2t_miss_valid_i  ( 1'b0      ),
        .v2t_miss_reason_i ( MISS_NONE ),

        .done_o     ( vec_done     ),
        .done_ctx_o ( vec_done_ctx ),
        .done_tag_o ( vec_done_tag ),

        .unit_idle_o          ( ),
        .contract_violation_o ( )
    );

    // Tensor Unit — real Tensor core behind the tensor_domain_top wrapper
    // (renamed from tensor_unit_top to avoid colliding with Tensor/tensor_unit_top).
    tensor_domain_top i_tens (
        .clk_i        ( tens_gated_clk ),
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release
        .soft_reset_i ( cp_soft_reset  ),
        .test_en_i    ( test_en_i      ),   // [DFT] bypass soft reset in scan mode

        .cmd_valid_i ( tens_cmd_valid ),
        .cmd_ready_o ( tens_cmd_ready ),
        .cmd_i       ( tens_cmd       ),

        // L2 RO (512b, no half_sel) — used by the operand streamer
        .ro_req_o    ( tens_ro_req    ),
        .ro_gnt_i    ( tens_ro_gnt    ),
        .ro_rvalid_i ( tens_ro_rvalid ),
        .ro_row_o    ( tens_ro_row    ),
        .ro_rdata_i  ( tens_ro_rdata  ),

        // L2 RW (512b, 16-bank mask) — retired (tied off inside the wrapper)
        .rw_req_o       ( tens_rw_req       ),
        .rw_gnt_i       ( tens_rw_gnt       ),
        .rw_row_o       ( tens_rw_row       ),
        .rw_bank_mask_o ( tens_rw_bank_mask ),
        .rw_wdata_o     ( tens_rw_wdata     ),

        // Fast Path egress (Tensor → Vector, bs_capsule_t, Q1) — into tv_fast_fifo
        .t2v_valid_o  ( tens_t2v_valid  ),
        .t2v_ready_i  ( tens_t2v_ready  ),
        .t2v_cap_o    ( tens_t2v_cap    ),
        .t2v_escape_o ( tens_t2v_escape ),

        .done_o     ( tens_done     ),
        .done_ctx_o ( tens_done_ctx ),
        .done_tag_o ( tens_done_tag ),

        .unit_idle_o          ( ),
        .contract_violation_o ( )
    );

    // DMA Engine (no wrapper; direct instantiation)
    dma_engine i_dma (
        .clk_i    ( dma_gated_clk ),
        .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release

        .soft_reset_i ( cp_soft_reset ),

        .cmd_valid_i ( dma_cmd_valid ),
        .cmd_ready_o ( dma_cmd_ready ),
        .cmd_i       ( dma_cmd       ),

        .fill_req_o   ( dma_fill_req   ),
        .fill_gnt_i   ( dma_fill_gnt   ),
        .fill_bank_o  ( dma_fill_bank  ),
        .fill_row_o   ( dma_fill_row   ),
        .fill_wdata_o ( dma_fill_wdata ),
        .fill_be_o    ( dma_fill_be    ),

        .evict_req_o    ( dma_evict_req    ),
        .evict_gnt_i    ( dma_evict_gnt    ),
        .evict_rvalid_i ( dma_evict_rvalid ),
        .evict_bank_o   ( dma_evict_bank   ),
        .evict_row_o    ( dma_evict_row    ),
        .evict_rdata_i  ( dma_evict_rdata  ),

        .noc_ing_valid_i,
        .noc_ing_ready_o,
        .noc_ing_data_i,
        .noc_ing_last_i,
        .noc_egr_valid_o,
        .noc_egr_ready_i,
        .noc_egr_data_o,
        .noc_egr_last_o,

        .done_o     ( dma_done     ),
        .done_ctx_o ( dma_done_ctx ),
        .done_tag_o ( dma_done_tag )
    );

    // =========================================================================
    // [STEP4-E2E inc 4] Tensor → Vector fast path — tv_fast_fifo carries the
    // whole bs_capsule_t (Q1: DATA_W = $bits(bs_capsule_t); frag_sideband demoted
    // at the T↔V boundary). Tensor egresses GEMM-result capsules; the Vector
    // RESADD consumes them via its t2v ingress.
    //   [HW-REVIEW TIER-5 fix, 2026-06-24] Class-C ESCAPE capsules are DROPPED at
    //   this T→V fast-path boundary: in_valid is gated by ~tens_t2v_escape, so an
    //   escape-flagged row never enters the RESADD FIFO. PREVIOUSLY the escape flag
    //   was dropped while the capsule DATA was still forwarded — the high-precision
    //   escape capsule was silently consumed by RESADD = latent numerical
    //   corruption (the old comment here falsely claimed "not forwarded"). Class-C
    //   properly routes to the high-precision OFU sidecar (Phase E3, design-not-
    //   activated); until that consumer exists, escape rows are dropped here.
    //   NOTE: escape is held 0 on the activated GEMM→RESADD path, so this gate is a
    //   no-op for all live traffic and only closes the dormant latent path.
    // =========================================================================
    logic tv_fifo_in_valid;
    assign tv_fifo_in_valid = tens_t2v_valid & ~tens_t2v_escape;

    // [FIX 2026-07-12, pre-tapeout audit] Two hazards closed on this FIFO:
    //
    //  (a) FLUSH on soft reset. The FIFO sits on the UNGATED clk_i and had no
    //      flush port, while every other stage of the fast path (vector_unit
    //      flush, tensor_domain_top, dma_engine, l2_subsystem) honours
    //      cp_soft_reset. An aborted context therefore left GEMM capsules
    //      buffered here, and the NEXT RESADD silently consumed them as its
    //      SRC0 => wrong results, no error flagged.
    //
    //  (b) OUT_READY qualification. tv_out_ready comes from the Vector's t2v
    //      ingress, which is a decode inside the GATED vector domain. If the
    //      Vector is clock-stopped while that decode happens to be frozen at 1,
    //      this FIFO (still clocked) would pop a capsule every cycle into a unit
    //      that cannot latch it — silently draining the GEMM result. Qualifying
    //      with vec_clk_en makes a stopped Vector back-pressure correctly.
    logic tv_out_ready_qual;
    assign tv_out_ready_qual = tv_out_ready & vec_clk_en;

    tv_fast_fifo #(.DEPTH(4), .DATA_W(TV_DW)) i_tv_fifo (
        .clk_i, .rst_ni ( rst_n_sync ),   // [FIX 2026-07-12] synchronized release
        .flush_i        ( cp_soft_reset    ),
        .in_valid_i     ( tv_fifo_in_valid ),
        .in_ready_o     ( tens_t2v_ready ),
        .in_data_i      ( tens_t2v_cap   ),
        .in_sideband_i  ( '0             ),
        .out_valid_o    ( tv_out_valid   ),
        .out_ready_i    ( tv_out_ready_qual ),
        .out_data_o     ( tv_out_data    ),
        .out_sideband_o (                ),
        .fill_level_o   (                ),
        .overflow_o     (                ),
        .underflow_o    (                )
    );

endmodule

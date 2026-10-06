// =============================================================================
// pe_ibex_wrapper.sv — IBEX Core Wrapper for PE v5
//
// Phase 2b deliverable. Pure-new file. Wraps the IBEX RISC-V core with:
//   - All ibex_core parameters exposed as wrapper parameters (D9-2)
//   - IRQ merging (cp_irq with irq_fast[0]) moved out of pe_top (D9)
//   - BOOT_ADDR exposed as wrapper parameter, default 0 (D9-1)
//   - L1I / L1D / addr_decoder NOT included (Q18: wrapper scope = logical
//     core, not memory subsystem)
//
// =============================================================================
// ROLE IN THE ARCHITECTURE
// =============================================================================
// The wrapper exposes IBEX as a "logical core" — clock/reset, the two OBI
// ports, interrupts, debug, boot, and status. Memory and address decoding
// remain pe_top's responsibility, because L1I/L1D are PE-owned resources
// (shared with the Command Processor fetch path).
//
// Phase 6 will replace pe_top's direct ibex_core instantiation with this
// wrapper, simplifying pe_top's instance list and isolating all ibex_pkg
// imports to this file.
//
// =============================================================================
// PHASE 2B DESIGN DECISIONS REFLECTED HERE
// =============================================================================
//   D9    : Wrapper contents = core + params + IRQ merge + boot_addr;
//           NOT included = L1I/L1D/addr_decoder/OBI external connections
//   D9-1  : BOOT_ADDR is a wrapper parameter (default 32'h0000_0000),
//           not hard-coded — allows integration-level configuration
//           without changing the wrapper.
//   D9-2  : ibex_core's 9+ parameters are all exposed as wrapper
//           parameters, preserving existing pe_top configurability.
//
// =============================================================================
// IRQ MERGE RATIONALE
// =============================================================================
// Currently (v4 pe_top.sv line 264):
//     .irq_fast_i ( {irq_fast_i[14:1], cp_irq | irq_fast_i[0]} )
//
// The CP's interrupt is OR'd into the lowest bit of the fast-IRQ vector,
// letting software treat CP IRQ as just another fast interrupt source.
// This wrapper absorbs that merge so pe_top doesn't need to care.
//
// =============================================================================

module pe_ibex_wrapper
#(
    // IBEX Core Parameters (forwarded to ibex_core; defaults match v4 pe_top)
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

    // Boot address (D9-1: parameterized, default matches v4 pe_top constant)
    parameter logic [31:0] BOOT_ADDR        = 32'h0000_0000
) (
    // ── Clock / Reset ──
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        test_en_i,

    // ── Hart ID ──
    input  logic [31:0] hart_id_i,

    // ── Instruction OBI (to L1I) ──
    output logic        instr_req_o,
    input  logic        instr_gnt_i,
    input  logic        instr_rvalid_i,
    output logic [31:0] instr_addr_o,
    input  logic [31:0] instr_rdata_i,
    input  logic        instr_err_i,

    // ── Data OBI (to addr_decoder) ──
    output logic        data_req_o,
    input  logic        data_gnt_i,
    input  logic        data_rvalid_i,
    output logic        data_we_o,
    output logic [3:0]  data_be_o,
    output logic [31:0] data_addr_o,
    output logic [31:0] data_wdata_o,
    input  logic [31:0] data_rdata_i,
    input  logic        data_err_i,

    // ── Interrupts (raw, before internal merge) ──
    input  logic        irq_software_i,
    input  logic        irq_timer_i,
    input  logic        irq_external_i,
    input  logic [14:0] irq_fast_i,       // 15 fast IRQs (raw, from pe_top)
    input  logic        irq_nm_i,
    input  logic        cp_irq_i,         // CP IRQ — merged into irq_fast[0]
                                           // internally (see below)

    // ── Debug ──
    input  logic        debug_req_i,

    // ── Boot / Fetch ──
    input  logic        fetch_enable_i,

    // ── Status ──
    output logic        alert_minor_o,
    output logic        alert_major_o,
    output logic        core_sleep_o
);

    // =========================================================================
    // IRQ Merge
    //
    // Historic pe_top behavior (v4):
    //   irq_fast[0]   := cp_irq | external_irq_fast[0]
    //   irq_fast[14:1]:= external_irq_fast[14:1]
    //
    // This wrapper encapsulates that merge so callers no longer need to
    // know about it.
    // =========================================================================
    logic [14:0] merged_irq_fast;
    assign merged_irq_fast = { irq_fast_i[14:1], cp_irq_i | irq_fast_i[0] };

    // =========================================================================
    // IBEX Core Instantiation
    //
    // All parameters forwarded from wrapper parameters (D9-2).
    // Boot address sourced from BOOT_ADDR parameter (D9-1).
    // RegFile, RV32M, RV32B pinned to v4 pe_top values; these are not
    // parameterized here because they are tied to the Sky130 baseline
    // and don't change across integrations.
    // =========================================================================
    ibex_core #(
        .PMPEnable        ( PMPEnable        ),
        .PMPGranularity   ( PMPGranularity   ),
        .PMPNumRegions    ( PMPNumRegions    ),
        .MHPMCounterNum   ( MHPMCounterNum   ),
        .MHPMCounterWidth ( MHPMCounterWidth ),
        .RV32E            ( RV32E            ),
        .RV32M            ( ibex_pkg::RV32MFast ),
        .RV32B            ( ibex_pkg::RV32BNone ),
        .RegFile          ( ibex_pkg::RegFileFF ),
        .BranchTargetALU  ( BranchTargetALU  ),
        .WritebackStage   ( WritebackStage   ),
        .ICache           ( ICache           ),
        .ICacheECC        ( ICacheECC        ),
        .BranchPredictor  ( BranchPredictor  ),
        .DbgTriggerEn     ( DbgTriggerEn     ),
        .DbgHwBreakNum    ( DbgHwBreakNum    ),
        .SecureIbex       ( SecureIbex       ),
        .DmHaltAddr       ( DmHaltAddr       ),
        .DmExceptionAddr  ( DmExceptionAddr  )
    ) u_ibex_core (
        .clk_i            ( clk_i            ),
        .rst_ni           ( rst_ni           ),
        .test_en_i        ( test_en_i        ),
        .hart_id_i        ( hart_id_i        ),
        .boot_addr_i      ( BOOT_ADDR        ),

        // Instruction port
        .instr_req_o      ( instr_req_o      ),
        .instr_gnt_i      ( instr_gnt_i      ),
        .instr_rvalid_i   ( instr_rvalid_i   ),
        .instr_addr_o     ( instr_addr_o     ),
        .instr_rdata_i    ( instr_rdata_i    ),
        .instr_err_i      ( instr_err_i      ),

        // Data port
        .data_req_o       ( data_req_o       ),
        .data_gnt_i       ( data_gnt_i       ),
        .data_rvalid_i    ( data_rvalid_i    ),
        .data_we_o        ( data_we_o        ),
        .data_be_o        ( data_be_o        ),
        .data_addr_o      ( data_addr_o      ),
        .data_wdata_o     ( data_wdata_o     ),
        .data_rdata_i     ( data_rdata_i     ),
        .data_err_i       ( data_err_i       ),

        // Interrupts (with internal merge of cp_irq into irq_fast[0])
        .irq_software_i   ( irq_software_i   ),
        .irq_timer_i      ( irq_timer_i      ),
        .irq_external_i   ( irq_external_i   ),
        .irq_fast_i       ( merged_irq_fast  ),
        .irq_nm_i         ( irq_nm_i         ),

        // Debug
        .debug_req_i      ( debug_req_i      ),
        .fetch_enable_i   ( fetch_enable_i   ),

        // Status
        .alert_minor_o    ( alert_minor_o    ),
        .alert_major_o    ( alert_major_o    ),
        .core_sleep_o     ( core_sleep_o     )
    );

endmodule

// =============================================================================
// tech_icg_wrapper.sv — Technology-Portable Integrated Clock Gate
//
// Phase 2a deliverable. Pure-new file; replaces direct instantiation of
// PDK-specific ICG cells (e.g. sky130_fd_sc_hd__dlclkp_1 currently used in
// pe_top.sv) with a single abstracted interface.
//
// Phase 6 will rewire pe_top.sv to instantiate this wrapper instead of the
// raw Sky130 cell. Until Phase 6, this file is present but unused.
//
// =============================================================================
// INTERFACE CONTRACT
// =============================================================================
// Functional behavior (independent of PDK):
//
//   gated_clk_o follows clk_i whenever gate_en_i is asserted during the
//   PRIOR low phase of clk_i, and is held low otherwise. This is the
//   canonical "latch-based" ICG semantics — the enable is sampled while
//   the clock is low so the output never produces short pulses.
//
//   gate_en_i = 1, continuously → gated_clk_o ≡ clk_i
//   gate_en_i = 0, continuously → gated_clk_o ≡ 0 (held low)
//   gate_en_i changing while clk_i is high → change deferred to next low
//
// This is equivalent to:  gated_clk_o = clk_i & latch(gate_en_i @ clk_low)
//
// =============================================================================
// BACKEND DISPATCH
// =============================================================================
//   `ifdef PDK_SKY130   — sky130_fd_sc_hd__sdlclkp_1 (scan-aware latch ICG, SCE)
//   `ifdef PDK_ASAP7    — ICGx1_ASAP7_75t_R (scan-aware, SE)
//   `ifdef PDK_NANGATE45— placeholder (cell binding not finalized)
//   `else (default)     — behavioral latch-based model for simulation
//
// =============================================================================
// DFT CONTRACT  [2026-07-12 — supersedes the Phase-2a "D3 deferred" note]
// =============================================================================
//   test_en_i = 1 forces the clock ON, regardless of gate_en_i.
//
//   This is NOT optional. During scan shift the gate enable comes from a flop
//   that is itself on the scan chain, so it toggles pseudo-randomly as the
//   pattern shifts in — with no test override the gated clock switches off and
//   every flop behind it stops shifting. The scan chain is then broken and no
//   DFT tool can stitch or pattern it.
//
//   The tape-out partner runs their OWN synthesis + DFT insertion on this RTL,
//   so this override must exist HERE, in the RTL we hand over — otherwise their
//   DFT engineer has to modify our source, which is exactly the friction we are
//   handing them the RTL to avoid.
//
//   Cell mapping: sky130 has a purpose-built scan clock gate
//   (sky130_fd_sc_hd__sdlclkp_1, SCE pin) and ASAP7's ICG already exposes .SE —
//   so on both real PDKs this costs one wire, not extra logic.
//
//   Still NOT included (unchanged): retention/power-gate pins (D4 — PE v5 is
//   always-on, no power domains); timing checks (D5 — functional model only).
// =============================================================================

module tech_icg_wrapper (
    input  logic clk_i,
    input  logic gate_en_i,
    input  logic test_en_i,     // DFT: force the clock on during scan shift
    output logic gated_clk_o
);

    // -------------------------------------------------------------------------
    // Backend dispatch
    // -------------------------------------------------------------------------
`ifdef PDK_SKY130
    // Sky130 open PDK: latch-based integrated clock gate, SCAN variant.
    // Cell:  sky130_fd_sc_hd__sdlclkp_1   (was dlclkp_1 before the DFT contract)
    //   .CLK  — ungated input clock
    //   .GATE — active-high functional enable (sampled on clock low)
    //   .SCE  — scan clock enable: ORs into the enable ahead of the latch, so
    //           SCE=1 passes the clock no matter what GATE does
    //   .GCLK — gated output clock
    // Verified present in the platform: lib + lef + gds all carry sdlclkp_1/2/4,
    // and DONT_USE_CELLS does not exclude them.
    sky130_fd_sc_hd__sdlclkp_1 u_icg (
        .GCLK ( gated_clk_o ),
        .GATE ( gate_en_i   ),
        .SCE  ( test_en_i   ),
        .CLK  ( clk_i       )
    );

`elsif PDK_ASAP7
    // ASAP7: latch-based integrated clock gate (D3 unbind, 2026-07-11)
    // Cell: ICGx1_ASAP7_75t_R (asap7sc7p5t SEQ lib, verified
    // clock_gating_integrated_cell : latch_posedge_precontrol)
    //   .CLK  — ungated input clock
    //   .ENA  — active-high enable (sampled on clock low)
    //   .SE   — scan enable  [2026-07-12: now driven by test_en_i, was tied 0]
    //   .GCLK — gated output clock
    // Same logical contract as the Sky130 sdlclkp_1 branch. Simulation never
    // defines PDK_ASAP7 (synthesis-only branch, same discipline as the
    // sram_1rw1r_wrapper ASAP7 binding).
    ICGx1_ASAP7_75t_R u_icg (
        .GCLK ( gated_clk_o ),
        .CLK  ( clk_i       ),
        .ENA  ( gate_en_i   ),
        .SE   ( test_en_i   )
    );

`elsif PDK_NANGATE45
    // Nangate45 development node (OpenROAD mid-flow sanity-check)
    //
    // Same placeholder rationale as ASAP7 above.
    // synthesis translate_off
    initial $fatal(1, "tech_icg_wrapper: PDK_NANGATE45 cell binding not yet finalized");
    // synthesis translate_on

    logic gate_latched;
    // [2026-07-12 DFT contract] test_en_i ORs into the enable AHEAD of the latch,
    // exactly as SCE does inside sdlclkp_1 / SE inside ICGx1 — so the behavioural
    // model and the real cells agree bit for bit.
    always_latch begin
        if (!clk_i) gate_latched <= gate_en_i | test_en_i;
    end
    assign gated_clk_o = clk_i & gate_latched;

`else
    // -------------------------------------------------------------------------
    // Default: behavioral latch-based ICG (for simulation / lint / standalone)
    //
    // Standard idiom: latch the enable while the clock is low, then AND with
    // the clock. This mirrors the true behavior of a latch-based ICG cell
    // (e.g. Sky130 dlclkp_1) without requiring any library to be linked.
    //
    // WARNING: synthesis tools will typically REJECT this pattern (latch
    // inference is flagged) — that rejection is by design; a real PDK must
    // be chosen via `ifdef before running synthesis.
    // -------------------------------------------------------------------------
    // synthesis translate_off
    logic gate_latched;
    // [2026-07-12 DFT contract] test_en_i ORs into the enable AHEAD of the latch,
    // exactly as SCE does inside sdlclkp_1 / SE inside ICGx1 — so the behavioural
    // model and the real cells agree bit for bit.
    always_latch begin
        if (!clk_i) gate_latched <= gate_en_i | test_en_i;
    end
    assign gated_clk_o = clk_i & gate_latched;
    // synthesis translate_on

    // synthesis translate_off
    initial begin
        $display("[tech_icg_wrapper] No PDK_* defined; using behavioral ICG model.");
    end
    // synthesis translate_on
`endif

endmodule

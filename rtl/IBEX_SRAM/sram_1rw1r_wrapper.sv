// =============================================================================
// sram_1rw1r_wrapper.sv — Technology-Portable 1RW + 1R SRAM Wrapper
//
// Phase 2a deliverable. Pure-new file. Abstracts SRAM macro instantiation
// for all PE v5 SRAMs:
//   - L1I memory       (l1i_mem.sv, Phase 3)
//   - L1D bank         (l1d_mem.sv, Phase 3, word-interleaved across 2 banks)
//   - L2 bank          (l2_bank.sv, Phase 3, one wrapper per bank × 16 banks)
//
// The current v4 tree directly instantiates sky130_sram_2kbyte_1rw1r_32x512_8
// (OpenRAM-generated). Phase 3 will rewire those modules to instantiate
// this wrapper. Until Phase 3, this file is present but unused.
//
// =============================================================================
// Memory 波1 (2026-07-22, branch memory-wave1) — real ASAP7 macro + output reg
// =============================================================================
//   Two orthogonal per-instance axes were added (design MemWave1_Impl_Plan §D1/D2):
//
//   OUT_REG    — add ONE common output-register stage after the backend read
//                data (PDK-independent post-stage) → read latency 1→2 cycles.
//                Rationale: at 1GHz the real macro's dout must stay lightly
//                loaded (§3.5: full-load access 535-588ps vs light 143-198ps);
//                a register right at the output keeps the net short. Present in
//                the behavioral (sim) path too, so the 1→2-cycle latency change
//                is exercised and caught by the double gate (red-green).
//                Callers that assert OUT_REG=1 MUST deepen their read-valid /
//                data-aligned control pipelines by one stage (l1i_mem, l1d_mem).
//
//   REAL_MACRO — PDK_ASAP7 only: bind the real asap7_sram_0p0 single-port macro
//                srambank_128x4x64_6t122 (tape-out-ready, has GDS in the x64
//                width family) instead of the fakeram7_256x32 analytical model.
//                No effect on the behavioral sim path (which never defines a PDK).
//                ~~L2 keeps REAL_MACRO=0 (fakeram) in 波1 — its 4x granularity
//                mismatch is deferred to the 1MiB Ring (wave 2).~~
//                [OBSOLETE 2026-09-03] Superseded by D-SRAM-REAL-ALL / D-SRAM-REAL-B:
//                L2 now binds the SAME real macro (512x64) with the upper 32 data
//                bits tied to 0. Route A (native 512x32 = srambank_128x4x32) was
//                rejected: the package ships NO 32-bit-wide GDS and it cannot be
//                derived (all three shipped GDS flatten to height 77.804 um = the
//                64-bit-wide family; 128x4x32 needs 43.2 um). See PROJECT_RULES
//                section 8, D-SRAM-REAL-B-2026-09-03.
//                Known cost carried by route B: macro area +26.8%; upper 32 bits
//                wasted; DMA byte-mask (wmaska_i) still dropped on this arm.
//
// =============================================================================
// INTERFACE CONTRACT
// =============================================================================
// Port polarity (D4 — active-high external interface):
//   The wrapper exposes active-high control signals; internal mapping to
//   PDK-specific polarity (e.g. Sky130 OpenRAM uses active-low csb/web) is
//   the wrapper's job. Callers outside this wrapper should NEVER see
//   active-low chip/write enables.
//
//   Port A (Read-Write, full byte-mask write support):
//     cea_i    — chip enable (1 = access, 0 = deselected)
//     wea_i    — write enable (1 = write, 0 = read)  [meaningful only when cea_i=1]
//     wmaska_i — byte-lane write mask (1 = write that byte)  [DW/8 bits]
//     addra_i  — word address  [AW bits]
//     dina_i   — write data    [DW bits]
//     douta_o  — read data, valid ONE cycle (OUT_REG=0) or TWO cycles
//                (OUT_REG=1) after cea_i & !wea_i  [DW bits]
//
//   Port B (Read-Only):
//     ceb_i    — chip enable (1 = access, 0 = deselected)
//     addrb_i  — word address  [AW bits]
//     doutb_o  — read data, valid 1 (OUT_REG=0) / 2 (OUT_REG=1) cycles after ceb_i
//
// Timing (D5 — functional-only, no timing checks):
//   Read latency:  1 cycle (OUT_REG=0) / 2 cycles (OUT_REG=1)
//   Write latency: data committed at posedge of the write cycle
//   Same-cycle read-after-write on same port: reads OLD data (not bypassed)
//
// =============================================================================
// SAME-ROW RW/RO CONFLICT (Q8 — assertion included)
// =============================================================================
// The underlying 1RW1R macro has UNDEFINED behavior when Port A writes and
// Port B reads the SAME ROW in the SAME cycle. In the behavioral model we
// assert on this condition so misuse is caught at wrapper level rather
// than relying solely on the PE-top §10.2 bind assertion (which won't
// fire in standalone or subsystem-level simulation).
//
// This is a functional safety assertion, not a timing check.
//
// =============================================================================
// PARAMETERS
// =============================================================================
//   DEPTH — number of words. Default 512 matches the 2KB Sky130 macro used
//           in v4. Must be a power of 2 for Phase 3 callers (they derive
//           AW = $clog2(DEPTH) directly).
//   AW    — address width, derived from DEPTH.
//   DW    — data width. Default 32 matches v4.
//   MW    — number of byte lanes in wmaska_i, derived as DW/8.
//
// =============================================================================
// BACKEND DISPATCH
// =============================================================================
//   `ifdef PDK_SKY130   — maps DEPTH=512, DW=32 to
//                         sky130_sram_2kbyte_1rw1r_32x512_8 (OpenRAM).
//                         Other geometries must add their own mappings.
//   `ifdef PDK_ASAP7    — REAL_MACRO ? srambank_128x4x64_6t122 (real)
//                                    : fakeram7_256x32 (analytical)
//   `ifdef PDK_NANGATE45— placeholder
//   `else               — behavioral functional model
// =============================================================================

module sram_1rw1r_wrapper
#(
    parameter int DEPTH = 512,
    parameter int DW    = 32,
    parameter int AW    = $clog2(DEPTH),
    parameter int MW    = DW / 8,          // byte-mask width
    // Memory 波1 (2026-07-22): see header block for full rationale.
    parameter bit OUT_REG    = 1'b0,
    parameter bit REAL_MACRO = 1'b0
) (
    input  logic          clk_i,

    // ── Port A: Read-Write ──
    input  logic          cea_i,
    input  logic          wea_i,
    input  logic [MW-1:0] wmaska_i,
    input  logic [AW-1:0] addra_i,
    input  logic [DW-1:0] dina_i,
    output logic [DW-1:0] douta_o,

    // ── Port B: Read-Only ──
    input  logic          ceb_i,
    input  logic [AW-1:0] addrb_i,
    output logic [DW-1:0] doutb_o
);

    // -------------------------------------------------------------------------
    // Pre-OUT_REG backend read data. Every backend branch drives these; the
    // common OUT_REG stage (bottom of module) optionally registers them once
    // more before the output ports. Keeping OUT_REG PDK-independent maximises
    // the shared/verified logic (design §D1).
    // -------------------------------------------------------------------------
    logic [DW-1:0] douta_pre;
    logic [DW-1:0] doutb_pre;

    // -------------------------------------------------------------------------
    // Backend dispatch
    // -------------------------------------------------------------------------
`ifdef PDK_SKY130
    // --- Sky130 open PDK: OpenRAM-generated 1RW1R macro ---
    //
    // Current v4 macro: sky130_sram_2kbyte_1rw1r_32x512_8
    //   - 512 words × 32 bits = 2KB total
    //   - 8-bit byte-mask (4 bytes per word)
    //   - Port naming: csb/web active-low (Sky130 OpenRAM convention)
    //
    // Parameter-guard: this binding currently assumes DEPTH=512, DW=32.
    // Other geometries on Sky130 require a different OpenRAM-generated
    // macro — extend this dispatch block when such geometries are added.
    //
    // synthesis translate_off
    initial begin
        if (DEPTH != 512 || DW != 32) begin
            $fatal(1,
                "sram_1rw1r_wrapper[PDK_SKY130]: only DEPTH=512, DW=32 supported; got DEPTH=%0d DW=%0d",
                DEPTH, DW);
        end
    end
    // synthesis translate_on

    // Polarity translation: external active-high → Sky130 active-low
    logic csb_a, web_a;
    logic csb_b;
    assign csb_a = ~cea_i;
    assign web_a = ~wea_i;
    assign csb_b = ~ceb_i;

    sky130_sram_2kbyte_1rw1r_32x512_8 u_sram (
        // Port 0: Read/Write
        .clk0   ( clk_i     ),
        .csb0   ( csb_a     ),
        .web0   ( web_a     ),
        .wmask0 ( wmaska_i  ),
        .addr0  ( addra_i   ),
        .din0   ( dina_i    ),
        .dout0  ( douta_pre ),
        // Port 1: Read-Only
        .clk1   ( clk_i     ),
        .csb1   ( csb_b     ),
        .addr1  ( addrb_i   ),
        .dout1  ( doutb_pre )
    );

`elsif PDK_ASAP7
    // --- ASAP7 SYNTHESIS-ONLY binding (simulation always takes the behavioral
    //     `else` branch — this branch is never simulated). ---
    //
    // Parameter-guard: same geometry restriction as the Sky130 branch.
    // synthesis translate_off
    initial begin
        if (DEPTH != 512 || DW != 32) begin
            $fatal(1,
                "sram_1rw1r_wrapper[PDK_ASAP7]: only DEPTH=512, DW=32 supported; got DEPTH=%0d DW=%0d",
                DEPTH, DW);
        end
    end
    // synthesis translate_on

    generate if (REAL_MACRO) begin : g_real_macro
        // ---------------------------------------------------------------------
        // Memory 波1: REAL asap7_sram_0p0 macro srambank_128x4x64_6t122.
        //
        // Single-port 1RW, 512 words (ADDRESS[8:0]), 64-bit wide, no byte mask,
        // read/write mutually exclusive on the single port (the macro's own
        // comment: "should have an error assert on read & write at once").
        // L1 is 32-bit → drive the low DW bits, tie the high (64-DW).
        //
        // The 1RW1R contract is collapsed onto the single port with priority
        //   write > Port-A read > Port-B read
        // which is FUNCTIONALLY EXACT for mutex users:
        //   - L1I: boot-write and fetch-read are mutually exclusive.
        //   - L1D: does NOT rely on this collapse for concurrency — l1d_mem
        //     instantiates one single-port wrapper per mirror copy (Port B
        //     tied off) and rebuilds true 1W+1R above it (write-consistency
        //     queue + bypass). So each wrapper instance here is only ever a
        //     single-port cell.
        //   - L2 [ADDED 2026-09-04, backlog #90]: **DOES NOT satisfy the mutex
        //     premise.** l2_ro_arbiter (drives pb) and l2_rw_arbiter (drives pa)
        //     are wired independently in l2_subsystem.sv with NO bank-level
        //     interlock, so a same-bank Port-A-write + Port-B-read in the same
        //     cycle is architecturally expected (that is exactly why sky130 uses
        //     a true 1RW1R macro). On ASAP7 this arm therefore DROPS the
        //     colliding read. It also drops wmaska_i (this macro has no byte
        //     mask) while l2_rw_arbiter.sv:402 does produce a partial byte
        //     enable on the DMA-fill path.
        //     🔴 NOT introduced by route B: before D-SRAM-REAL-B, L2 was bound to
        //     ibex_asap7_sram_512x32, which is ALSO single-port write-priority
        //     with no mask. What route B changed is the SCOPE of N-5 (A/B port
        //     collapse, zero simulation): it went from "argued mutex-safe for
        //     L1I/L1D" to "known NOT to satisfy the premise for L2".
        //     ⇒ Any "closer to tape-out" claim must be weakened accordingly:
        //     the fake-macro analytical discount is removed, the PORT-CONTRACT
        //     discount is NOT. Full case: soc600_prereg_20260902.md §26.
        // 🔴 The list above is the SAFE-CALLER list. It does not update itself —
        //    adding a caller means checking that caller against the premise.
        // Any genuinely concurrent Port-A-write + Port-B-read on ONE instance
        // is analytical only (colliding read dropped) — never happens for the
        // wave-1 callers above.
        // ---------------------------------------------------------------------
        logic          rd_a;      // Port A read (priority over Port B read)
        logic          mac_re;    // any read request
        logic          mac_we;    // write request
        logic [AW-1:0] mac_ra;    // read address (A over B)
        logic [AW-1:0] mac_addr;  // final single-port address (write over read)
        logic [63:0]   mac_do;

        assign rd_a     = cea_i & ~wea_i;
        assign mac_re   = rd_a | ceb_i;
        assign mac_we   = cea_i & wea_i;
        assign mac_ra   = rd_a ? addra_i : addrb_i;
        assign mac_addr = mac_we ? addra_i : mac_ra;

        srambank_128x4x64_6t122 u_sram (
            .clk     ( clk_i                       ),
            .ADDRESS ( mac_addr                    ),
            .wd      ( {{(64-DW){1'b0}}, dina_i}   ),
            .banksel ( mac_we | mac_re             ),
            .read    ( mac_re & ~mac_we            ),
            .write   ( mac_we                      ),
            .dataout ( mac_do                      )
        );

        assign douta_pre = mac_do[DW-1:0];
        assign doutb_pre = mac_do[DW-1:0];

    end else begin : g_fakeram
        // ---------------------------------------------------------------------
        // fakeram7_256x32 depth-banked ANALYTICAL binding (D1 unbind,
        // 2026-07-11). Retained for L2 in 波1 (REAL_MACRO=0). Mirrors the tensor
        // precedent; single-port 1RW, no byte mask, priority write>A-read>B-read.
        // ---------------------------------------------------------------------
        logic          rd_a;
        logic          mac_re;
        logic [AW-1:0] mac_ra;
        logic [DW-1:0] mac_dout;

        assign rd_a   = cea_i & ~wea_i;
        assign mac_re = rd_a | ceb_i;
        assign mac_ra = rd_a ? addra_i : addrb_i;

        ibex_asap7_sram_512x32 u_sram (
            .clk  ( clk_i          ),
            .we   ( cea_i & wea_i  ),
            .wa   ( addra_i        ),
            .din  ( dina_i         ),
            .re   ( mac_re         ),
            .ra   ( mac_ra         ),
            .dout ( mac_dout       )
        );

        assign douta_pre = mac_dout;
        assign doutb_pre = mac_dout;
    end endgenerate

`elsif PDK_NANGATE45
    // --- Nangate45: placeholder pending library cell confirmation ---
    // synthesis translate_off
    initial $fatal(1, "sram_1rw1r_wrapper: PDK_NANGATE45 macro binding not yet finalized");
    // synthesis translate_on

    `define __SRAM_1RW1R_BEHAVIORAL__

`else
    // --- Default: behavioral functional model ---
    `define __SRAM_1RW1R_BEHAVIORAL__

`endif

    // -------------------------------------------------------------------------
    // Behavioral functional model
    //
    // Used:
    //   - when no PDK_* is defined (simulation / lint)
    //   - as fallback for unfinalized PDKs (Nangate45)
    //
    // Semantics:
    //   - 1-cycle synchronous read on each port (before the OUT_REG stage)
    //   - Byte-mask write on Port A
    //   - NO read-after-write bypass (matches OpenRAM behavior)
    //   - Same-row RW vs RO in the same cycle: undefined — asserted against
    // -------------------------------------------------------------------------
`ifdef __SRAM_1RW1R_BEHAVIORAL__

    // Storage
    logic [DW-1:0] mem [DEPTH];

    // Registered read-data shadows (1-cycle read latency)
    logic [DW-1:0] douta_q;
    logic [DW-1:0] doutb_q;

    // Port A: Read-Write
    //   Read: capture mem[addra_i] on posedge when cea_i && !wea_i
    //   Write: byte-mask commit to mem[addra_i] when cea_i && wea_i
    //   Deselect: output holds previous value (matches macro — not X)
    always_ff @(posedge clk_i) begin
        if (cea_i) begin
            if (wea_i) begin
                // Byte-mask write
                for (int b = 0; b < MW; b++) begin
                    if (wmaska_i[b]) begin
                        mem[addra_i][b*8 +: 8] <= dina_i[b*8 +: 8];
                    end
                end
                // On a write cycle, douta is undefined per OpenRAM behavior.
                // Leave douta_q unchanged (holds previous value) — this is a
                // functional approximation, not guaranteed equivalence.
            end else begin
                douta_q <= mem[addra_i];
            end
        end
    end

    // Port B: Read-Only
    always_ff @(posedge clk_i) begin
        if (ceb_i) begin
            doutb_q <= mem[addrb_i];
        end
    end

    assign douta_pre = douta_q;
    assign doutb_pre = doutb_q;

    // ------------------------------------------------------------------
    // Same-row RW/RO conflict assertion (Q8 — wrapper-local)
    //
    // If Port A writes and Port B reads the same row in the same cycle,
    // the underlying 1RW1R macro has undefined behavior. Flag it here so
    // standalone / subsystem simulation catches the misuse even without
    // the PE-top §10.2 bind assertion.
    //
    // NOTE: This is a NECESSARY condition (not sufficient) for correct
    // usage — the PE-top bind assertion §10.2 remains the authoritative
    // check at the integrated level.
    // ------------------------------------------------------------------
    // synthesis translate_off
    // pragma translate_off
    property p_no_same_row_write_read;
        @(posedge clk_i) disable iff (1'b0)
            !(cea_i && wea_i && ceb_i && (addra_i == addrb_i));
    endproperty
    a_no_same_row_write_read: assert property (p_no_same_row_write_read)
        else $error("sram_1rw1r_wrapper: UNDEFINED — Port A write and Port B read at same row 0x%0h",
                    addra_i);
    // pragma translate_on
    // synthesis translate_on

    // Init (simulation only — silicon starts at X)
    // synthesis translate_off
    initial begin
        for (int i = 0; i < DEPTH; i++) mem[i] = '0;
        douta_q = '0;
        doutb_q = '0;
    end
    // synthesis translate_on

`endif  // __SRAM_1RW1R_BEHAVIORAL__

    // -------------------------------------------------------------------------
    // Common OUT_REG stage (PDK-independent, design §D1/§D2)
    //
    // OUT_REG=0 → passthrough (1-cycle read latency, unchanged v4 behavior).
    // OUT_REG=1 → one extra register → 2-cycle read latency. This holds in the
    //   behavioral model above too, so the latency change is verified by the
    //   double gate (a caller that forgets to deepen its rvalid pipe fails).
    // -------------------------------------------------------------------------
    generate if (OUT_REG) begin : g_out_reg
        logic [DW-1:0] douta_q2;
        logic [DW-1:0] doutb_q2;
        always_ff @(posedge clk_i) begin
            douta_q2 <= douta_pre;
            doutb_q2 <= doutb_pre;
        end
        assign douta_o = douta_q2;
        assign doutb_o = doutb_q2;
        // synthesis translate_off
        initial begin
            douta_q2 = '0;
            doutb_q2 = '0;
        end
        // synthesis translate_on
    end else begin : g_no_out_reg
        assign douta_o = douta_pre;
        assign doutb_o = doutb_pre;
    end endgenerate

    // -------------------------------------------------------------------------
    // Macro helper cleanup
    // -------------------------------------------------------------------------
    // (SystemVerilog `define is file-scoped, not module-scoped, so we
    //  undef after the module body to avoid leaking into other files
    //  if this file is compiled in a batch.)
`ifdef __SRAM_1RW1R_BEHAVIORAL__
    `undef __SRAM_1RW1R_BEHAVIORAL__
`endif

endmodule


`ifdef PDK_ASAP7
// ############################################################################
// ibex_asap7_sram_512x32  (PDK_ASAP7 synthesis-only helper, D1 unbind)
// ############################################################################
// One 512x32 logical bank = 2 x single-port fakeram7_256x32 halves, addr bit 8
// selecting the half. Write has priority on the single 1RW port; read data is
// steered by the registered read-half select one cycle later (matches the
// macro's 1-cycle synchronous read). Analytical area/timing model only —
// never simulated. Structure mirrors tensor_asap7_sram_512x32
// (tensor_external_modules.sv) but carries an independent name so pe_top can
// elaborate both files under PDK_ASAP7 without a duplicate-module clash.
//
// Retained for the REAL_MACRO=0 path (L2 in 波1). REAL_MACRO=1 (L1) binds the
// real srambank_128x4x64_6t122 directly inside the wrapper instead.
module ibex_asap7_sram_512x32 (
  input  logic        clk,
  input  logic        we,
  input  logic [8:0]  wa,
  input  logic [31:0] din,
  input  logic        re,
  input  logic [8:0]  ra,
  output logic [31:0] dout
);
  logic [8:0]  addr;              // write-priority single-port address
  logic        sel_q;             // registered read-half select
  logic [31:0] rd_half [2];

  assign addr = we ? wa : ra;

  always_ff @(posedge clk) if (re) sel_q <= ra[8];

  generate for (genvar gh = 0; gh < 2; gh++) begin : g_half
    fakeram7_256x32 u_half (
      .clk    (clk),
      .ce_in  ((we | re) & (addr[8] == 1'(gh))),
      .we_in  (we & (wa[8] == 1'(gh))),
      .addr_in(addr[7:0]),
      .wd_in  (din),
      .rd_out (rd_half[gh])
    );
  end endgenerate

  assign dout = rd_half[sel_q];

endmodule
`endif

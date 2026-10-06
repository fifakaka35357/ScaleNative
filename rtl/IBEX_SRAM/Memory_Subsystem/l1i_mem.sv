// =============================================================================
// l1i_mem.sv — L1 Instruction Memory (PE v5, Phase 3 Batch 1)
//
// Phase 3 Batch 1 changes:
//   [PHASE3-B1-01] Replace direct sky130_sram_2kbyte_1rw1r_32x512_8
//                  instantiation with sram_1rw1r_wrapper (PDK-portable).
//                  Polarity conversion (active-low csb/web → active-high
//                  ce/we) is now handled inside the wrapper, so local
//                  csb/web derivation is removed in favor of direct
//                  active-high cea/wea signals.
//   [PHASE3-B1-02] No functional change to L1I semantics. All memory
//                  map / OBI handshake / boot-vs-fetch exclusivity
//                  behavior is identical to v4.
//
// 1 × sram_1rw1r_wrapper (DEPTH=512, DW=32 → 2KB)
//   Port 0 (RW): Boot loading (external write before fetch_enable)
//   Port 1 (R):  IBEX instruction fetch (read-only, OBI slave)
//
// Address mapping (2KB):
//   byte_addr[1:0]  = byte offset (ignored, 32-bit word aligned)
//   byte_addr[10:2] = word address within SRAM (9 bits → 512 words)
//
// OBI handshake:
//   Always grant (SRAM never stalls). rvalid 1 cycle after req & gnt.
//
// Safety:
//   Boot and fetch are mutually exclusive (fetch_enable_i guards).
//   Same-address Port 0 write + Port 1 read on same cycle is macro-level
//   undefined behavior — avoided by mutual exclusion. The sram wrapper's
//   built-in same-row RW/RO assertion (Q8 / Phase 2a) adds a further
//   simulation-time safety net at wrapper scope.
// =============================================================================

module l1i_mem
    import pe_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // ── Boot Interface (Port 0 RW — write program before fetch) ──
    input  logic        boot_req_i,
    input  logic        boot_we_i,
    input  logic [31:0] boot_addr_i,
    input  logic [31:0] boot_wdata_i,
    input  logic [3:0]  boot_be_i,

    // ── IBEX Instruction Fetch (Port 1 R — OBI slave, read-only) ──
    input  logic        fetch_req_i,
    output logic        fetch_gnt_o,
    output logic        fetch_rvalid_o,
    input  logic [31:0] fetch_addr_i,
    output logic [31:0] fetch_rdata_o,
    output logic        fetch_err_o
);

    // =========================================================================
    // Address Decoding
    // =========================================================================
    localparam int AW = L1I_BANK_AW;  // 9 bits

    // Memory 波1: OUT_REG=1 adds one output-register stage in the SRAM wrapper
    // → read latency 1→2 cycles (keeps the real macro's dout lightly loaded at
    // 1GHz, §3.5). The fetch rvalid pipe below is deepened to match. IBEX's
    // instruction prefetch buffer tolerates the extra wait state (valid-driven).
    localparam bit OUT_REG_EN = 1'b1;
    localparam int RD_LAT     = OUT_REG_EN ? 2 : 1;

    logic [AW-1:0] boot_word_addr;
    logic [AW-1:0] fetch_word_addr;

    assign boot_word_addr  = boot_addr_i[AW+1:2];   // [10:2]
    assign fetch_word_addr = fetch_addr_i[AW+1:2];

    // =========================================================================
    // OBI Handshake (fetch port — always grant, 1-cycle rvalid)
    // =========================================================================
    assign fetch_gnt_o = fetch_req_i;
    assign fetch_err_o = 1'b0;

    // rvalid pipe depth = RD_LAT (2 when OUT_REG_EN). Delaying rvalid to match
    // fetch_rdata keeps the OBI response aligned; a single-stage pipe here while
    // the data is 2-cycle would hand IBEX a stale/next instruction (the 波1
    // red-green check for this stage).
    logic [RD_LAT-1:0] fetch_rvalid_pipe;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) fetch_rvalid_pipe <= '0;
        else         fetch_rvalid_pipe <= {fetch_rvalid_pipe[RD_LAT-2:0], fetch_req_i};
    end
    assign fetch_rvalid_o = fetch_rvalid_pipe[RD_LAT-1];

    // =========================================================================
    // SRAM Port A (RW): Boot Write
    //
    // [PHASE3-B1-01] Now driven with active-high polarity; wrapper
    // internally inverts to Sky130's active-low csb/web. During fetch
    // (no boot active): cea = 0 → port deselected.
    // =========================================================================
    logic          pa_cea;
    logic          pa_wea;
    logic [3:0]    pa_wmask;
    logic [AW-1:0] pa_addr;
    logic [31:0]   pa_din;

    assign pa_cea   = boot_req_i & boot_we_i;   // active-high: asserted when boot write
    assign pa_wea   = boot_we_i;                 // always 1 when pa_cea is high (boot is write-only)
    assign pa_wmask = boot_be_i;
    assign pa_addr  = boot_word_addr;
    assign pa_din   = boot_wdata_i;

    // =========================================================================
    // SRAM Port B (R): Instruction Fetch
    //
    // [PHASE3-B1-01] Active-high ce; wrapper inverts internally.
    // =========================================================================
    logic          pb_ceb;
    logic [AW-1:0] pb_addr;
    logic [31:0]   pb_dout;

    assign pb_ceb  = fetch_req_i;
    assign pb_addr = fetch_word_addr;

    // =========================================================================
    // SRAM Wrapper Instance (PDK-portable, Phase 2a)
    //
    // 512 words × 32 bits = 2KB. When PDK_SKY130 is defined, the wrapper
    // binds to sky130_sram_2kbyte_1rw1r_32x512_8; otherwise it uses the
    // behavioral model.
    //
    // douta_o unused here (boot is write-only); wrapper still drives it
    // but we leave it unconnected and silence the lint below.
    // =========================================================================
    logic [31:0] pa_dout_unused;

    sram_1rw1r_wrapper #(
        .DEPTH      ( 512        ),
        .DW         ( 32         ),
        .OUT_REG    ( OUT_REG_EN ),   // 波1: +1 output-register stage (2-cycle read)
        .REAL_MACRO ( 1'b1       )    // 波1: bind real srambank_128x4x64 under PDK_ASAP7
    ) u_sram (
        .clk_i    ( clk_i          ),

        // Port A (RW): Boot
        .cea_i    ( pa_cea         ),
        .wea_i    ( pa_wea         ),
        .wmaska_i ( pa_wmask       ),
        .addra_i  ( pa_addr        ),
        .dina_i   ( pa_din         ),
        .douta_o  ( pa_dout_unused ),  // boot is write-only

        // Port B (R): Fetch
        .ceb_i    ( pb_ceb         ),
        .addrb_i  ( pb_addr        ),
        .doutb_o  ( pb_dout        )
    );

    // synthesis translate_off
    // verilator lint_off UNUSED
    wire _unused_pa_dout = &{1'b0, pa_dout_unused};
    // verilator lint_on UNUSED
    // synthesis translate_on

    assign fetch_rdata_o = pb_dout;

endmodule

// =============================================================================
// l2_bank.sv — Single L2 SRAM Bank Wrapper (PE v5, Phase 3 Batch 2)
//
// Phase 3 Batch 2 changes:
//   [PHASE3-B2-01] Replace direct sky130_sram_2kbyte_1rw1r_32x512_8
//                  instantiation with sram_1rw1r_wrapper (PDK-portable).
//                  Polarity conversion (active-low csb/web → active-high
//                  ce/we) is handled inside the wrapper.
//   [PHASE3-B2-02] No functional change to L2 bank semantics. TXN_ID_W
//                  ports remain reserved for future tagged L2/NoC
//                  request-response correlation (tied off by callers).
//
// One SRAM bank with:
//   Port A (RW): driven by l2_rw_arbiter (Tens store / Vec store /
//                DMA fill / DMA evict — priority Tens>Vec>DMA post-B2)
//   Port B (R):  driven by l2_ro_arbiter (Tens load / Vec load —
//                priority Tens>Vec post-B2)
//
// The arbiters pre-compute all SRAM control signals; this module
// passes them through to the wrapper after converting the historical
// active-low csb/web naming to the wrapper's active-high ce/we.
// =============================================================================

module l2_bank
    import pe_pkg::*;
#(
    parameter int BANK_AW = L2_BANK_AW,  // 9 for 2KB, 10 for 4KB
    // [C2 vec-l2-port-reg] register the SRAM dout (BOTH ports) → 2-cycle L2 read.
    // Callers MUST deepen their rvalid / bank-select pipes by +1 to match (see
    // l2_ro_arbiter tens/vec_rvalid, l2_rw_arbiter dma_evict_rvalid, l2_subsystem
    // vec_ro_half_sel / dma_evict_bank). Pipelines the macro read arc for Fmax.
    parameter bit OUT_REG = 1'b1,
    // [D-SRAM-REAL-B-2026-09-03] 路 B：绑真宏 srambank_128x4x64_6t122（512×64），
    //   数据高 32 位由 wrapper 的 g_real_macro 臂 tie 0（`.wd({{(64-DW){1'b0}}, dina_i})`）。
    //   🔴 默认 1'b1 —— 与 l1d_mem.sv:37 / l1d_mirror_bank.sv:46 同惯例。
    //   默认 0 正是 fakeram 活到今天的原因（每个实例都要显式 opt-in）。
    //   🔴 对【行为仿真】无影响：REAL_MACRO 只在 sram_1rw1r_wrapper 的
    //   `elsif PDK_ASAP7 分支（:180-271）内被读，仿真走 `else 分支（:280）。
    parameter bit REAL_MACRO = 1'b1
) (
    input  logic        clk_i,

    // ── Port 0 (RW) — from RW arbiter ──
    //
    // Legacy naming retained at this module's external interface
    // (csb/web, active-low) to minimize arbiter-side changes in
    // Phase 3 Batch 2. Polarity is converted to active-high cea/wea
    // before the internal sram_1rw1r_wrapper instance.
    input  logic               pa_csb_i,     // chip select (active low, external)
    input  logic               pa_web_i,     // write enable (active low, external)
    input  logic [3:0]         pa_wmask_i,   // byte write mask
    input  logic [BANK_AW-1:0] pa_addr_i,    // word address (row)
    input  logic [31:0]        pa_din_i,     // write data
    output logic [31:0]        pa_dout_o,    // read data
    input  logic [TXN_ID_W-1:0] pa_txn_id_i = '0, // R3.5: request tag (reserved)

    // ── Port 1 (R) — from RO arbiter ──
    input  logic               pb_csb_i,     // chip select (active low, external)
    input  logic [BANK_AW-1:0] pb_addr_i,    // word address (row)
    output logic [31:0]        pb_dout_o,    // read data
    input  logic [TXN_ID_W-1:0] pb_txn_id_i = '0  // R3.5: request tag (reserved)
);

    // =========================================================================
    // TXN_ID reserved ports (see pe_pkg §R3.5 [PHASE1-04])
    //
    // Currently tied off by callers; reserved for future tagged L2/NoC
    // request-response correlation. The sram_1rw1r_wrapper does not
    // propagate these tags — they would be latched and returned alongside
    // dout by a future wrapper revision.
    // =========================================================================
    // synthesis translate_off
    // verilator lint_off UNUSED
    wire _unused_txn_ids = &{1'b0, pa_txn_id_i, pb_txn_id_i};
    // verilator lint_on UNUSED
    // synthesis translate_on

    // =========================================================================
    // [PHASE3-B2-01] Polarity conversion: legacy active-low csb/web
    // (external interface) → active-high cea/wea (wrapper interface).
    // =========================================================================
    logic pa_cea;
    logic pa_wea;
    logic pb_ceb;

    assign pa_cea = ~pa_csb_i;    // active-low csb → active-high cea
    assign pa_wea = ~pa_web_i;    // active-low web → active-high wea
    assign pb_ceb = ~pb_csb_i;    // active-low csb → active-high ceb

    // =========================================================================
    // SRAM Wrapper Instance (PDK-portable, Phase 2a)
    //
    // [PHASE3-B2-01] Replaces direct sky130_sram_2kbyte_1rw1r_32x512_8
    // instantiation. Same geometry (512 words × 32 bits = 2KB), same
    // functional behavior.
    // =========================================================================
    sram_1rw1r_wrapper #(
        .DEPTH      ( 1 << BANK_AW ),   // 512 when BANK_AW=9
        .DW         ( 32            ),
        .OUT_REG    ( OUT_REG       ),  // [C2] +1 output-register stage on both ports
        .REAL_MACRO ( REAL_MACRO    )   // [D-SRAM-REAL-B] 路 B：512×64 真宏，高 32 位 tie 0
    ) u_sram (
        .clk_i    ( clk_i      ),

        // Port A (RW)
        .cea_i    ( pa_cea     ),
        .wea_i    ( pa_wea     ),
        .wmaska_i ( pa_wmask_i ),
        .addra_i  ( pa_addr_i  ),
        .dina_i   ( pa_din_i   ),
        .douta_o  ( pa_dout_o  ),

        // Port B (R)
        .ceb_i    ( pb_ceb     ),
        .addrb_i  ( pb_addr_i  ),
        .doutb_o  ( pb_dout_o  )
    );

endmodule

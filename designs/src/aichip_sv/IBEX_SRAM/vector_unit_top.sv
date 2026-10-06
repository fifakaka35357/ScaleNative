// =============================================================================
// vector_unit_top.sv — Vector Execution Domain Wrapper Top (256b)
//
// [STEP4-E2E, increment 2b] The wrapper now instantiates the REAL Vector Unit
// (Vector/vector_unit.sv) behind the stable PE-facing interface, replacing the
// Phase-2b traffic-gen stub. It adapts three things between pe_top and the real
// core (per Review/Step4_FastPath_Plan.md §9 decisions D-E2E-3/4/5):
//
//   1. Command  — cp_scheduler issues `vec_cmd_t`; the real core consumes
//      `vec_exec_desc_t`. `vec_cmd_to_desc` bridges them (incl. OP_VEC_RESADD).
//
//   2. L2 width — the real core's L2 RO/RW buses are FULL_STRIPE_W (512b); the
//      PE-facing port is the HALF_STRIPE_W (256b) half-stripe. A RESADD result
//      is exactly 256b (16 lanes x 16b) and the core writes it into the LOW
//      256b of its 512b RW bus with a 16'hFFFF mask, so we forward the low 256b
//      + low 8-bit mask. RO is unused by RESADD; the half-stripe read is
//      zero-extended into the 512b RO data. Full D1 256b narrowing of the core
//      is the deferred follow-on (D-E2E-4).
//
//   3. Fast path — carries the whole `bs_capsule_t` (Q1): the legacy
//      `frag_sideband_t` `fwd_*` ports are replaced by the capsule `t2v`
//      (Tensor->Vector ingress) / `v2t` (Vector->Tensor egress) ports, wired
//      straight to the real core. pe_top connects these to `tv_fast_fifo`
//      (increment 4); until then it ties them off.
//
//   half_sel (D7) is un-tied: both RO/RW half-selects are driven from the
//   command's architectural contract (`cmd_i.contract.half_sel`).
//
// =============================================================================

module vector_unit_top
    import pe_pkg::*;
    import vec_pkg::*;
(
    // ── Clock / Reset ──
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          soft_reset_i,

    // ── Command Interface (from cp_scheduler, vec_cmd_t) ──
    input  logic                          cmd_valid_i,
    output logic                          cmd_ready_o,
    input  vec_cmd_t                      cmd_i,

    // ── L2 RO Port (HALF_STRIPE_W = 256b, 8 banks) ──
    output logic                          ro_req_o,
    input  logic                          ro_gnt_i,
    input  logic                          ro_rvalid_i,
    output logic                          ro_half_sel_o,   // 0=lo half, 1=hi half (D7)
    output logic [L2_BANK_AW-1:0]         ro_row_o,
    input  logic [HALF_STRIPE_W-1:0]      ro_rdata_i,

    // ── L2 RW Port (HALF_STRIPE_W = 256b, 8 banks) ──
    output logic                          rw_req_o,
    input  logic                          rw_gnt_i,
    output logic                          rw_half_sel_o,   // (D7)
    output logic [L2_BANK_AW-1:0]         rw_row_o,
    output logic [(L2_NUM_BANKS/2)-1:0]   rw_bank_mask_o,  // 8-bit mask (half)
    output logic [HALF_STRIPE_W-1:0]      rw_wdata_o,

    // ── Fast Path Ingress (Tensor → Vector), full bs_capsule_t (Q1) ──
    input  logic                          t2v_valid_i,
    output logic                          t2v_ready_o,
    input  bs_capsule_t                   t2v_cap_i,
    output logic                          t2v_miss_valid_o,
    output fp_miss_reason_e               t2v_miss_reason_o,

    // ── Fast Path Egress (Vector → Tensor), full bs_capsule_t ──
    output logic                          v2t_valid_o,
    input  logic                          v2t_ready_i,
    output bs_capsule_t                   v2t_cap_o,
    input  logic                          v2t_miss_valid_i,
    input  fp_miss_reason_e               v2t_miss_reason_i,

    // ── Completion ──
    output logic                          done_o,
    output logic [CTX_ID_W-1:0]           done_ctx_o,
    output logic [TAG_W-1:0]              done_tag_o,

    // ── Status / Observability ──
    output logic                          unit_idle_o,
    output logic                          contract_violation_o,
    output vec_error_e                    err_code_o       // observability (debug/trace)
);

    // =========================================================================
    // Command adapter: vec_cmd_t -> vec_exec_desc_t
    // =========================================================================
    logic            desc_valid;
    logic            desc_ready;
    vec_exec_desc_t  desc;

    vec_cmd_to_desc u_cmd_to_desc (
        .cmd_valid_i  ( cmd_valid_i ),
        .cmd_ready_o  ( cmd_ready_o ),
        .cmd_i        ( cmd_i       ),
        .desc_valid_o ( desc_valid  ),
        .desc_ready_i ( desc_ready  ),
        .desc_o       ( desc        )
    );

    // =========================================================================
    // L2 width bridge (512b core <-> 256b half-stripe port)
    // =========================================================================
    logic [FULL_STRIPE_W-1:0]  vu_ro_rdata;
    logic [FULL_STRIPE_W-1:0]  vu_rw_wdata;
    logic [L2_NUM_BANKS-1:0]   vu_rw_bank_mask;

    assign vu_ro_rdata    = { {(FULL_STRIPE_W-HALF_STRIPE_W){1'b0}}, ro_rdata_i };
    assign rw_wdata_o     = vu_rw_wdata[HALF_STRIPE_W-1:0];
    assign rw_bank_mask_o = vu_rw_bank_mask[(L2_NUM_BANKS/2)-1:0];

    // =========================================================================
    // half_sel (D7): LATCH at the accepted command handshake, then hold.
    //
    // BUG FIX (adversarial review D5-1): cmd_i is valid only for the one-cycle
    // command handshake — cp_scheduler drives vec_cmd_o combinationally and
    // releases it (to '0 / the next context) the cycle after issue. But the real
    // core asserts its L2 RO (ro_req_o) and RW write-back (rw_req_o, in
    // VST_L2_WB) MANY cycles later. Driving the half-selects from the live cmd_i
    // therefore samples a STALE (default-0) half_sel at access time, writing the
    // WRONG physical 8-bank L2 half whenever half_sel=1 (the D7/N6 static
    // complementary-half scheme) — silent data corruption on RESADD/STORE/ACT
    // write-backs. Latch half_sel when the command is accepted (mirrors
    // tensor_domain_top's cmd_q) and hold for the whole op. Safe because the core
    // is single-op-in-flight: cmd_ready_o = desc_ready (asserted only in
    // VST_IDLE), so a new command cannot be accepted until the current op
    // completes, and the latch persists exactly over the op's L2 accesses.
    // (half_sel is the ONLY architectural field consumed outside vec_exec_desc_t;
    // every other cmd field rides the core's internal desc latch.)
    // =========================================================================
    logic half_sel_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)                         half_sel_q <= 1'b0;
        else if (cmd_valid_i && cmd_ready_o) half_sel_q <= cmd_i.contract.half_sel;
    end
    assign ro_half_sel_o = half_sel_q;
    assign rw_half_sel_o = half_sel_q;

    // =========================================================================
    // Status
    // =========================================================================
    logic        vu_busy;
    logic        vu_err_valid;
    vec_error_e  vu_err_code;

    // unit_idle_o over-approximates busy (safe for clock-gating): idle only when
    // the core is not busy, no command is being accepted, and no done pending.
    assign unit_idle_o          = !vu_busy && !cmd_valid_i && !done_o;
    assign contract_violation_o = vu_err_valid;
    assign err_code_o           = vu_err_code;

    // Perf counters are not surfaced at the PE top in this phase.
    logic [PERF_CNT_W-1:0] vu_perf_cnt [VEC_NUM_PERF_CNTS];

    // =========================================================================
    // Real Vector Unit
    // =========================================================================
    vector_unit u_vector_unit (
        .clk_i        ( clk_i        ),
        .rst_ni       ( rst_ni       ),
        .soft_reset_i ( soft_reset_i ),

        .desc_valid_i ( desc_valid ),
        .desc_ready_o ( desc_ready ),
        .desc_i       ( desc       ),

        // L2 RO (512b core; half-stripe bridged in)
        .ro_req_o    ( ro_req_o    ),
        .ro_gnt_i    ( ro_gnt_i    ),
        .ro_rvalid_i ( ro_rvalid_i ),
        .ro_row_o    ( ro_row_o    ),
        .ro_rdata_i  ( vu_ro_rdata ),

        // L2 RW (512b core; low half bridged out)
        .rw_req_o       ( rw_req_o        ),
        .rw_gnt_i       ( rw_gnt_i        ),
        .rw_row_o       ( rw_row_o        ),
        .rw_bank_mask_o ( vu_rw_bank_mask ),
        .rw_wdata_o     ( vu_rw_wdata     ),

        // Fast path (bs_capsule_t)
        .t2v_valid_i       ( t2v_valid_i       ),
        .t2v_ready_o       ( t2v_ready_o       ),
        .t2v_cap_i         ( t2v_cap_i         ),
        .t2v_miss_valid_o  ( t2v_miss_valid_o  ),
        .t2v_miss_reason_o ( t2v_miss_reason_o ),

        .v2t_valid_o       ( v2t_valid_o       ),
        .v2t_ready_i       ( v2t_ready_i       ),
        .v2t_cap_o         ( v2t_cap_o         ),
        .v2t_miss_valid_i  ( v2t_miss_valid_i  ),
        .v2t_miss_reason_i ( v2t_miss_reason_i ),

        // Completion
        .done_o     ( done_o     ),
        .done_ctx_o ( done_ctx_o ),
        .done_tag_o ( done_tag_o ),

        // Error / status
        .err_valid_o ( vu_err_valid ),
        .err_code_o  ( vu_err_code  ),
        .busy_o      ( vu_busy      ),

        // Perf (not surfaced this phase)
        .perf_cnt_o    ( vu_perf_cnt ),
        .perf_cnt_en_i ( 1'b0        )
    );

endmodule

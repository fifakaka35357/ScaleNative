// ============================================================================
// tb_cp_vec_store_e2e.sv — STEP4-E2E §10 (D-E2E-BENCH) command-path harness.
//
// Closes the N25 gap: the REAL cp_scheduler issues a Vector command to
// vector_unit_top, the command is released the cycle after issue, the op runs
// and makes its L2 write many cycles later, and completion loops back through
// cp_completion. The headline check is the D5-1 regression with teeth: with
// half_sel=1 the DEFERRED L2 write must still use half_sel=1 even though cmd_i
// has gone to '0 — i.e. vector_unit_top's half_sel latch holds at the integrated
// level. (No ibex CPU: this tb mocks command_processor's slot registers, which
// are plain inputs to cp_scheduler.)
//
// DUT = cp_scheduler + cp_completion + vector_unit_top.
//   - The tb presents ctx0's descriptor slot (flat slot0_i) + state; ctx0
//     auto-promotes IDLE->RUNNABLE when current_state!=EMPTY (no doorbell).
//   - On issue (issue_snap_valid_o) the tb flips slot0 -> SLOT_EMPTY as an
//     issue-time RE-ISSUE GUARD (NOT a faithful model of command_processor, which
//     clears the slot only on comp_done; it is timing-equivalent here because ctx0
//     enters CTX_WAIT_VEC at issue+1 and can_issue is then gated false regardless).
//   - The single STORE operand is injected as a SRC0 block32/E8M0 capsule on t2v.
//   - vector_unit_top.done -> cp_completion -> cp_scheduler.done_vec (credit/tag).
// ============================================================================
module tb_cp_vec_store_e2e
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,
    input  logic         enable_i,

    // ── ctx0 descriptor slot (flat 8x32b) + slot state ──
    input  logic [DESC_SLOT_WORDS*32-1:0] slot0_i,
    input  logic [1:0]                    slot0_state_i,   // slot_state_e
    input  logic                          doorbell0_i,

    // ── region table entry 0 (rid 0): phys_row = base_row + row_off ──
    input  logic [15:0]  region0_base_i,
    input  logic [15:0]  region0_num_i,

    // ── T2V capsule injection (the one STORE operand) ──
    input  logic         cap_valid_i,
    output logic         cap_ready_o,
    input  logic [BS_CAP_PAYLOAD_W-1:0] cap_payload_i,
    input  logic [1:0]   cap_role_i,          // operand_role_e
    input  logic [1:0]   cap_block_size_i,    // block_size_sel_e
    input  logic [2:0]   cap_scale_format_i,  // scale_format_e
    input  logic [7:0]   cap_inline_scale_i,
    input  logic [7:0]   cap_scale_epoch_i,
    input  logic         cap_fwd_i,
    output logic         miss_valid_o,
    output logic [3:0]   miss_reason_o,

    // ── L2 RW capture model (Vector half-stripe port) ──
    input  logic         rw_gnt_i,
    output logic         rw_req_o,
    output logic         rw_half_sel_o,
    output logic [L2_BANK_AW-1:0]    rw_row_o,
    output logic [HALF_STRIPE_W-1:0] rw_wdata_o,
    output logic [(L2_NUM_BANKS/2)-1:0] rw_bank_mask_o,

    // ── observability ──
    output logic         vec_cmd_valid_o,     // cp_scheduler issuing a vec cmd
    output logic         issue_half_sel_o,    // the issued cmd's contract.half_sel
    output logic         issue_snap_valid_o,  // pulses when scheduler issues
    output logic [7:0]   issue_opcode_o,
    output logic         vu_cmd_ready_o,      // vector_unit_top.cmd_ready
    output logic         vec_done_o,          // vector_unit_top.done
    output logic         vu_err_o,
    output logic [3:0]   vu_err_code_o,
    output logic         vu_idle_o,
    output logic         sched_error_o,       // cp_scheduler.error_valid
    output logic [3:0]   sched_error_class_o,
    output logic         wd_timeout0_o,
    output logic [3:0]   ctx0_state_o,         // ctx_state_e (debug)

    // ── internal FSM probes (debug) ──
    output logic [2:0]   vu_state_o,           // vector_unit.state_q (VST_*)
    output logic         vu_src0_loaded_o,
    output logic         vu_src1_loaded_o
);

    // debug taps into the real vector_unit FSM (read-only hierarchical refs)
    assign vu_state_o       = u_vec.u_vector_unit.state_q;
    assign vu_src0_loaded_o = u_vec.u_vector_unit.src0_loaded_q;
    assign vu_src1_loaded_o = u_vec.u_vector_unit.src1_loaded_q;

    // =========================================================================
    // Build cp_scheduler's array-typed inputs from the flat tb ports.
    // Only ctx0 / region0 carry the stimulus; the rest are empty/idle.
    // =========================================================================
    desc_slot_t   slot_current [NUM_CTX];
    slot_state_e  cur_state    [NUM_CTX];
    slot_state_e  nxt_state    [NUM_CTX];
    logic [RING_PTR_W-1:0] ring_head [NUM_CTX];
    logic [RING_PTR_W-1:0] ring_tail [NUM_CTX];
    region_entry_t region_table [NUM_REGIONS];
    logic [31:0]  word0_per_ctx [NUM_CTX];

    always_comb begin
        for (int c = 0; c < NUM_CTX; c++) begin
            for (int w = 0; w < DESC_SLOT_WORDS; w++)
                slot_current[c][w] = '0;
            cur_state[c]     = SLOT_EMPTY;
            nxt_state[c]     = SLOT_EMPTY;
            ring_head[c]     = '0;
            ring_tail[c]     = '0;
            word0_per_ctx[c] = '0;
        end
        // ctx0 = the stimulus descriptor
        for (int w = 0; w < DESC_SLOT_WORDS; w++)
            slot_current[0][w] = slot0_i[w*32 +: 32];
        cur_state[0]     = slot_state_e'(slot0_state_i);
        word0_per_ctx[0] = slot0_i[31:0];

        for (int r = 0; r < NUM_REGIONS; r++)
            region_table[r] = '0;
        region_table[0].base_row = region0_base_i;
        region_table[0].num_rows = region0_num_i;
    end

    logic [NUM_CTX-1:0] doorbell;
    assign doorbell = {{(NUM_CTX-1){1'b0}}, doorbell0_i};

    // =========================================================================
    // cp_scheduler  <->  cp_completion  <->  vector_unit_top wiring
    // =========================================================================
    logic        vec_cmd_valid, vec_cmd_ready;
    vec_cmd_t    vec_cmd;
    logic        tens_cmd_valid_unused, dma_cmd_valid_unused;
    tens_cmd_t   tens_cmd_unused;
    dma_cmd_t    dma_cmd_unused;

    logic [NUM_CTX-1:0] nop_done;
    logic [NUM_CTX-1:0] done_vec_oh;
    logic [TAG_W-1:0]   done_vec_tag;

    // vector_unit_top completion
    logic             vu_done;
    logic [1:0]          vu_done_ctx;   // done_ctx_o (CTX_ID_W=2)
    logic [TAG_W-1:0]    vu_done_tag;

    // watchdog timeouts (per-ctx); expose ctx0
    logic [NUM_CTX-1:0]  wd_timeout;
    assign wd_timeout0_o = wd_timeout[0];

    // observability taps
    assign vec_cmd_valid_o  = vec_cmd_valid;
    assign issue_half_sel_o = vec_cmd.contract.half_sel;
    assign issue_opcode_o   = vec_cmd.opcode;
    assign vu_cmd_ready_o   = vec_cmd_ready;
    assign vec_done_o       = vu_done;

    // ── injected capsule ──
    bs_capsule_t cap;
    fp_miss_reason_e miss_reason;
    always_comb begin
        cap                    = '0;
        cap.payload            = cap_payload_i;
        cap.elem_fmt           = ELEM_BFP_INTERNAL;
        cap.block_size         = block_size_sel_e'(cap_block_size_i);
        cap.scale_format       = scale_format_e'(cap_scale_format_i);
        cap.layout_tag         = 4'd0;
        cap.inline_scale       = {24'd0, cap_inline_scale_i};
        cap.scale_inline_valid = 1'b1;
        cap.scale_epoch        = cap_scale_epoch_i;
        cap.fwd_eligible       = cap_fwd_i;
        cap.multi_consumer     = 1'b0;
        cap.operand_role       = operand_role_e'(cap_role_i);
    end
    assign miss_reason_o = miss_reason;

    // ── cp_scheduler ──
    ctx_state_e ctx_state [NUM_CTX];
    assign ctx0_state_o = ctx_state[0];

    cp_scheduler u_sched (
        .clk_i, .rst_ni,
        .enable_i,
        .soft_reset_i      ( 1'b0 ),

        .slot_current_i    ( slot_current ),
        .current_state_i   ( cur_state ),
        .ring_head_i       ( ring_head ),
        .ring_tail_i       ( ring_tail ),
        .slot_next_state_i ( nxt_state ),

        .nop_done_o        ( nop_done ),
        .slot_state_vis_o  ( ),

        .vec_cmd_valid_o   ( vec_cmd_valid ),
        .vec_cmd_o         ( vec_cmd ),
        .vec_cmd_ready_i   ( vec_cmd_ready ),

        .tens_cmd_valid_o  ( tens_cmd_valid_unused ),
        .tens_cmd_o        ( tens_cmd_unused ),
        .tens_cmd_ready_i  ( 1'b1 ),

        .dma_cmd_valid_o   ( dma_cmd_valid_unused ),
        .dma_cmd_o         ( dma_cmd_unused ),
        .dma_cmd_ready_i   ( 1'b1 ),

        .region_table_i    ( region_table ),

        .vec_busy_o        ( ),
        .tens_busy_o       ( ),
        .dma_busy_o        ( ),

        .done_vec_i        ( done_vec_oh ),
        .done_tens_i       ( '0 ),
        .done_dma_i        ( '0 ),
        .done_vec_tag_i    ( done_vec_tag ),
        .done_tens_tag_i   ( '0 ),
        .done_dma_tag_i    ( '0 ),

        .ctx_state_o       ( ctx_state ),

        .doorbell_pulse_i  ( doorbell ),
        .clear_error_i     ( '0 ),

        .issue_snap_valid_o  ( issue_snap_valid_o ),
        .issue_snap_ctx_o    ( ),
        .issue_snap_opcode_o ( ),
        .issue_snap_ext_len_o( ),

        .error_valid_o     ( sched_error_o ),
        .error_ctx_o       ( ),
        .error_class_o     ( sched_error_class_o ),

        .wd_threshold_i    ( 16'hFFFF ),       // effectively disable watchdog
        .wd_timeout_o      ( wd_timeout ),

        .vec_tag_valid_o   ( ),
        .tens_tag_valid_o  ( ),
        .dma_tag_valid_o   ( ),
        .vec_credit_o      ( ),
        .tens_credit_o     ( ),
        .dma_credit_o      ( ),

        .perf_cnt_en_i     ( 1'b0 ),
        .perf_ctx_blocked_o( ),
        .perf_ctx_barrier_o( ),
        .perf_ctx_starved_o( ),
        .perf_total_issue_o( ),
        .perf_total_done_o ( ),

        .irq_pending_i     ( '0 ),
        .event_clear_i     ( '0 ),
        .event_pending_o   ( ),
        .event_wake_o      ( )
    );

    // ── cp_completion (real done router) ──
    cp_completion u_compl (
        .vec_done_i       ( vu_done ),
        .vec_done_ctx_i   ( vu_done_ctx ),
        .vec_done_tag_i   ( vu_done_tag ),
        .tens_done_i      ( 1'b0 ),
        .tens_done_ctx_i  ( 2'd0 ),
        .tens_done_tag_i  ( '0 ),
        .dma_done_i       ( 1'b0 ),
        .dma_done_ctx_i   ( 2'd0 ),
        .dma_done_tag_i   ( '0 ),

        .nop_done_i       ( nop_done ),
        .current_word0_i  ( word0_per_ctx ),

        .comp_done_o      ( ),
        .comp_chain_o     ( ),

        .done_vec_o       ( done_vec_oh ),
        .done_tens_o      ( ),
        .done_dma_o       ( ),

        .done_vec_tag_o   ( done_vec_tag ),
        .done_tens_tag_o  ( ),
        .done_dma_tag_o   ( ),

        .irq_set_o        ( )
    );

    // ── vector_unit_top (real wrapper: vec_cmd_to_desc + real vector_unit) ──
    vector_unit_top u_vec (
        .clk_i, .rst_ni, .soft_reset_i ( 1'b0 ),

        .cmd_valid_i ( vec_cmd_valid ),
        .cmd_ready_o ( vec_cmd_ready ),
        .cmd_i       ( vec_cmd       ),

        // L2 RO — unused (operands come from the fast path; ro_req tied 0 in core)
        .ro_req_o      (        ), .ro_gnt_i ( 1'b0 ), .ro_rvalid_i ( 1'b0 ),
        .ro_half_sel_o (        ), .ro_row_o (      ), .ro_rdata_i  ( '0   ),

        // L2 RW — capture
        .rw_req_o       ( rw_req_o       ),
        .rw_gnt_i       ( rw_gnt_i       ),
        .rw_half_sel_o  ( rw_half_sel_o  ),
        .rw_row_o       ( rw_row_o       ),
        .rw_bank_mask_o ( rw_bank_mask_o ),
        .rw_wdata_o     ( rw_wdata_o     ),

        // fast-path ingress (the STORE operand)
        .t2v_valid_i       ( cap_valid_i  ),
        .t2v_ready_o       ( cap_ready_o  ),
        .t2v_cap_i         ( cap          ),
        .t2v_miss_valid_o  ( miss_valid_o ),
        .t2v_miss_reason_o ( miss_reason  ),

        // fast-path egress — unused
        .v2t_valid_o       (           ),
        .v2t_ready_i       ( 1'b0      ),
        .v2t_cap_o         (           ),
        .v2t_miss_valid_i  ( 1'b0      ),
        .v2t_miss_reason_i ( MISS_NONE ),

        .done_o     ( vu_done     ),
        .done_ctx_o ( vu_done_ctx ),
        .done_tag_o ( vu_done_tag ),

        .unit_idle_o          ( vu_idle_o ),
        .contract_violation_o ( vu_err_o  ),
        .err_code_o           ( vu_err_code_o )
    );

endmodule

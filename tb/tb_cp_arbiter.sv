// ============================================================================
// tb_cp_arbiter.sv — cp_scheduler RR-arbiter head-of-line test (HW-REVIEW T4)
// ============================================================================
//
// Two runnable contexts target DIFFERENT execution units:
//   ctx0: OP_VEC_STORE  (vec unit)
//   ctx1: OP_TENS_GEMM  (tensor unit)
// Both auto-promote IDLE->RUNNABLE (current_state != EMPTY, no doorbell). The
// test drives vec_cmd_ready_i / tens_cmd_ready_i directly to model unit busy/idle.
//
// HOL bug: the RR selector picks the first can_issue ctx from rr_ptr (ctx0), and
// rr_ptr only advances on issue_ok. With vec busy (vec_cmd_ready_i=0) but a vec
// CREDIT still available, can_issue[0]=1, so ctx0 is selected every cycle and
// rr_ptr freezes — ctx1 (tensor, idle) NEVER issues. The fix masks the selector
// by per-ctx target-unit readiness so ctx0 is skipped and ctx1 issues.
//
// Observable: tens_cmd_valid_o (does the tensor-targeting ctx get to issue while
// the vec unit is busy?). Pre-fix=0 (HOL), post-fix=1.
// ============================================================================
module tb_cp_arbiter
    import pe_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,
    input  logic enable_i,
    input  logic vec_ready_i,    // model: vec unit idle/busy
    input  logic tens_ready_i,   // model: tensor unit idle/busy

    output logic vec_cmd_valid_o,
    output logic tens_cmd_valid_o,
    output logic dma_cmd_valid_o,
    output logic issue_snap_valid_o,
    output logic [1:0] issue_snap_ctx_o
);
    // ── build cp_scheduler array inputs: ctx0=VEC_STORE, ctx1=TENS_GEMM ──
    desc_slot_t    slot_current [NUM_CTX];
    slot_state_e   cur_state    [NUM_CTX];
    slot_state_e   nxt_state    [NUM_CTX];
    logic [RING_PTR_W-1:0] ring_head [NUM_CTX];
    logic [RING_PTR_W-1:0] ring_tail [NUM_CTX];
    region_entry_t region_table [NUM_REGIONS];

    always_comb begin
        for (int c = 0; c < NUM_CTX; c++) begin
            for (int w = 0; w < DESC_SLOT_WORDS; w++) slot_current[c][w] = '0;
            cur_state[c] = SLOT_EMPTY;
            nxt_state[c] = SLOT_EMPTY;
            ring_head[c] = '0;
            ring_tail[c] = '0;
        end
        // ctx0 = OP_VEC_STORE (word0[7:0]=0x02), all addrs/params 0
        slot_current[0][0] = 32'h0000_0002;
        cur_state[0]       = SLOT_VALID;
        // ctx1 = OP_TENS_GEMM (word0[7:0]=0x10)
        slot_current[1][0] = 32'h0000_0010;
        cur_state[1]       = SLOT_VALID;

        for (int r = 0; r < NUM_REGIONS; r++) region_table[r] = '0;
        region_table[0].base_row = 16'd0;
        region_table[0].num_rows = 16'd1024;   // large → no OOB for row_off 0
    end

    cp_scheduler u_sched (
        .clk_i, .rst_ni, .enable_i, .soft_reset_i ( 1'b0 ),
        .slot_current_i    ( slot_current ),
        .current_state_i   ( cur_state ),
        .ring_head_i       ( ring_head ),
        .ring_tail_i       ( ring_tail ),
        .slot_next_state_i ( nxt_state ),
        .nop_done_o        ( ),
        .slot_state_vis_o  ( ),
        .vec_cmd_valid_o   ( vec_cmd_valid_o ),
        .vec_cmd_o         ( ),
        .vec_cmd_ready_i   ( vec_ready_i ),
        .tens_cmd_valid_o  ( tens_cmd_valid_o ),
        .tens_cmd_o        ( ),
        .tens_cmd_ready_i  ( tens_ready_i ),
        .dma_cmd_valid_o   ( dma_cmd_valid_o ),
        .dma_cmd_o         ( ),
        .dma_cmd_ready_i   ( 1'b1 ),
        .region_table_i    ( region_table ),
        .vec_busy_o        ( ), .tens_busy_o ( ), .dma_busy_o ( ),
        .done_vec_i        ( '0 ), .done_tens_i ( '0 ), .done_dma_i ( '0 ),
        .done_vec_tag_i    ( '0 ), .done_tens_tag_i ( '0 ), .done_dma_tag_i ( '0 ),
        .ctx_state_o       ( ),
        .doorbell_pulse_i  ( '0 ),
        .clear_error_i     ( '0 ),
        .issue_snap_valid_o  ( issue_snap_valid_o ),
        .issue_snap_ctx_o    ( issue_snap_ctx_o ),
        .issue_snap_opcode_o ( ),
        .issue_snap_ext_len_o( ),
        .error_valid_o     ( ), .error_ctx_o ( ), .error_class_o ( ),
        .wd_threshold_i    ( 16'hFFFF ),
        .wd_timeout_o      ( ),
        .vec_tag_valid_o   ( ), .tens_tag_valid_o ( ), .dma_tag_valid_o ( ),
        .vec_credit_o      ( ), .tens_credit_o ( ), .dma_credit_o ( ),
        .perf_cnt_en_i     ( 1'b0 ),
        .perf_ctx_blocked_o( ), .perf_ctx_barrier_o( ), .perf_ctx_starved_o( ),
        .perf_total_issue_o( ), .perf_total_done_o ( ),
        .irq_pending_i     ( '0 ), .event_clear_i ( '0 ),
        .event_pending_o   ( ), .event_wake_o ( )
    );
endmodule

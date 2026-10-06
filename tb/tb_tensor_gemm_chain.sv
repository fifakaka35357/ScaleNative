// ============================================================================
// tb_tensor_gemm_chain.sv — STEP4-E2E Phase C: GEMM through tensor_domain_top.
//
// Drives a tens_cmd(GEMM) into the IBEX-side tensor_domain_top wrapper (real
// Tensor core + L2->SRAM operand streamer + MMIO start FSM) and exposes the
// fast-path egress capsule + an L2 RO port so a cocotb L2 model can supply the
// operand tile. This proves the streamer + MMIO bring-up reproduce the Phase-B
// direct-drive GEMM egress through the SoC wrapper. flattens cmd_i + t2v_cap_o
// for cocotb. Uses clk_i/rst_ni (the IBEX-side convention).
// ============================================================================
module tb_tensor_gemm_chain
    import pe_pkg::*;
    import tensor_pkg::*;
(
    input  logic                     clk_i,
    input  logic                     rst_ni,

    // ── Command (tens_cmd GEMM) ──
    input  logic                     cmd_valid_i,
    output logic                     cmd_ready_o,
    input  logic [L2_BANK_AW-1:0]    src_row_i,
    input  logic [L2_BANK_AW-1:0]    dst_row_i,
    input  logic [15:0]              param_K_i,
    input  logic [7:0]               scale_epoch_i,
    input  logic [1:0]               ctx_id_i,
    input  logic [TAG_W-1:0]         tag_i,

    // ── L2 RO model (512b) ──
    output logic                     ro_req_o,
    input  logic                     ro_gnt_i,
    input  logic                     ro_rvalid_i,
    output logic [L2_BANK_AW-1:0]    ro_row_o,
    input  logic [FULL_STRIPE_W-1:0] ro_rdata_i,

    // ── Fast-path egress capsule (t2v) ──
    input  logic                     t2v_ready_i,
    output logic                     t2v_valid_o,
    output logic                     t2v_escape_o,
    output logic [255:0]             t2v_payload,
    output logic [2:0]               t2v_sfmt,
    output logic [1:0]               t2v_block_size,
    output logic [31:0]              t2v_iscale,
    output logic [1:0]               t2v_role,
    output logic [7:0]               t2v_status,

    // ── Completion ──
    output logic                     done_o,
    output logic                     unit_idle_o
);
    tens_cmd_t cmd;
    always_comb begin
        cmd                      = '0;
        cmd.opcode               = OP_TENS_GEMM;
        cmd.src_row              = src_row_i;
        cmd.dst_row              = dst_row_i;
        cmd.param_K              = param_K_i;
        cmd.contract.scale_epoch = scale_epoch_i;
        cmd.ctx_id               = ctx_id_i;
        cmd.tag                  = tag_i;
    end

    bs_capsule_t cap;
    assign t2v_payload    = cap.payload;
    assign t2v_sfmt       = cap.scale_format;
    assign t2v_block_size = cap.block_size;
    assign t2v_iscale     = cap.inline_scale;
    assign t2v_role       = cap.operand_role;
    assign t2v_status     = cap.status_flags;

    tensor_domain_top u_dom (
        .clk_i        ( clk_i  ),
        .rst_ni       ( rst_ni ),
        .soft_reset_i ( 1'b0   ),
        .test_en_i    ( 1'b0   ),   // functional mode

        .cmd_valid_i  ( cmd_valid_i ),
        .cmd_ready_o  ( cmd_ready_o ),
        .cmd_i        ( cmd         ),

        // L2 RO (operand source)
        .ro_req_o    ( ro_req_o    ),
        .ro_gnt_i    ( ro_gnt_i    ),
        .ro_rvalid_i ( ro_rvalid_i ),
        .ro_row_o    ( ro_row_o    ),
        .ro_rdata_i  ( ro_rdata_i  ),

        // L2 RW (retired — tied off inside the wrapper)
        .rw_req_o       (        ),
        .rw_gnt_i       ( 1'b0   ),
        .rw_row_o       (        ),
        .rw_bank_mask_o (        ),
        .rw_wdata_o     (        ),

        // fast-path egress
        .t2v_valid_o ( t2v_valid_o  ),
        .t2v_ready_i ( t2v_ready_i  ),
        .t2v_cap_o   ( cap          ),
        .t2v_escape_o( t2v_escape_o ),

        // completion
        .done_o     ( done_o ),
        .done_ctx_o (        ),
        .done_tag_o (        ),

        .unit_idle_o          ( unit_idle_o ),
        .contract_violation_o (             )
    );
endmodule

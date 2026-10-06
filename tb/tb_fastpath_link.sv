// ============================================================================
// tb_fastpath_link.sv — Step-4 fast-path link capstone harness
//
// The full module-level fast path: tensor_result_packer (D2, Tensor egress) ->
// tv_fast_fifo (the PE-fabric wire, carrying the WHOLE bs_capsule_t per the Q1
// decision: DATA_W = $bits(bs_capsule_t), frag_sideband demoted) -> vec_ingress_arb
// (Vector fast-path ingress). Proves the formed capsule travels the actual wire
// FIFO bit-exact and is accepted by the Vector ingress gate.
// ============================================================================
module tb_fastpath_link
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic                       clk_i,
    input  logic                       rst_ni,
    input  tensor_pkg::fp_acc_output_t cells_i [16],
    input  block_size_sel_e            cap_block_size_i,
    input  scale_format_e              cap_scale_format_i,
    input  logic [7:0]                 cap_scale_epoch_i,
    input  elem_fmt_e                  cap_elem_fmt_i,
    input  block_size_sel_e            ctrl_block_size_i,
    input  scale_format_e              ctrl_scale_format_i,
    input  logic [7:0]                 ctrl_scale_epoch_i,
    input  logic                       in_valid_i,        // push formed capsule into FIFO
    input  logic                       out_ready_i,       // consumer ready
    input  logic                       ctrl_valid_i,
    output logic                       in_ready_o,
    output logic                       fifo_out_valid_o,
    output logic                       packer_escape_o,
    output logic                       ingress_accept_o,
    output logic                       miss_valid_o,
    output fp_miss_reason_e            miss_reason_o,
    output logic [7:0]                 out_scale_byte_o,  // observe capsule survived
    output logic signed [15:0]         out_lane0_o
);
    localparam int CAPW = $bits(bs_capsule_t);

    bs_capsule_t      cap_in, cap_out;
    logic [CAPW-1:0]  cap_in_bits, fifo_out_data;

    tensor_result_packer #(.LANES(16), .EXP_W(12)) u_pack (
        .cells_i        (cells_i),
        .target_w_sel_i (2'd2),
        .kind_fp_i      (1'b0),
        .round_rne_i    (1'b0),
        .block_size_i   (cap_block_size_i),
        .scale_format_i (cap_scale_format_i),
        .scale_epoch_i  (cap_scale_epoch_i),
        .ctx_id_i       ('0),
        .tag_i          ('0),
        .elem_fmt_i     (cap_elem_fmt_i),
        .operand_role_i (OP_SRC0),
        .spread_limit_i (4'd14),
        .capsule_o      (cap_in),
        .escape_o       (packer_escape_o),
        .all_zero_o     (),
        .block_nan_o    (),
        .block_inf_o    ()
    );
    assign cap_in_bits = cap_in;

    // PE-fabric wire: carry the WHOLE capsule on the data bus (Q1).
    tv_fast_fifo #(.DEPTH(4), .DATA_W(CAPW)) u_fifo (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .flush_i       (1'b0),                     // no soft-reset in this link bench
        .in_valid_i    (in_valid_i),
        .in_ready_o    (in_ready_o),
        .in_data_i     (cap_in_bits),
        .in_sideband_i ('0),                       // frag_sideband demoted (Q1)
        .out_valid_o   (fifo_out_valid_o),
        .out_ready_i   (out_ready_i),
        .out_data_o    (fifo_out_data),
        .out_sideband_o(),
        .fill_level_o  (),
        .overflow_o    (),
        .underflow_o   ()
    );
    assign cap_out = bs_capsule_t'(fifo_out_data);

    vec_ctrl_t ctrl;
    always_comb begin
        ctrl              = '0;
        ctrl.block_size   = ctrl_block_size_i;
        ctrl.scale_format = ctrl_scale_format_i;
        ctrl.scale_epoch  = ctrl_scale_epoch_i;
    end

    vec_ingress_arb u_arb (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .resident_valid_i (1'b0),
        .resident_ready_o (),
        .resident_cap_i   ('0),
        .fpath_valid_i    (fifo_out_valid_o),
        .fpath_ready_o    (),
        .fpath_cap_i      (cap_out),
        .ctrl_i           (ctrl),
        .ctrl_valid_i     (ctrl_valid_i),
        .out_valid_o      (ingress_accept_o),
        .out_ready_i      (out_ready_i),
        .out_cap_o        (),
        .miss_valid_o     (miss_valid_o),
        .miss_reason_o    (miss_reason_o),
        .miss_from_fpath_o()
    );

    assign out_scale_byte_o = cap_out.inline_scale[7:0];
    assign out_lane0_o      = cap_out.payload[15:0];
endmodule

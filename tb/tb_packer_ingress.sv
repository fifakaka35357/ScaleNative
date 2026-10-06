// ============================================================================
// tb_packer_ingress.sv — Step-4 contract-join harness
//
// Wires the Tensor egress capsule former (tensor_result_packer, D2) directly
// into the Vector fast-path ingress gate (vec_ingress_arb.check_capsule). This
// is the single strongest proof that the egress->ingress contract joins: a
// Tensor-formed bs_capsule_t, with a matching descriptor (vec_ctrl_t), is
// ACCEPTED with zero MISS; a mismatched descriptor produces the right miss
// reason. (Both modules are combinational for the accept/miss decision.)
// ============================================================================
module tb_packer_ingress
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  tensor_pkg::fp_acc_output_t cells_i [16],
    // capsule producer (packer) metadata
    input  block_size_sel_e  cap_block_size_i,
    input  scale_format_e    cap_scale_format_i,
    input  logic [7:0]       cap_scale_epoch_i,
    input  elem_fmt_e        cap_elem_fmt_i,
    // descriptor (vec_ctrl_t) expectation — may match or mismatch
    input  block_size_sel_e  ctrl_block_size_i,
    input  scale_format_e    ctrl_scale_format_i,
    input  logic [7:0]       ctrl_scale_epoch_i,
    input  logic             ctrl_valid_i,
    // observation
    output logic             out_valid_o,
    output logic             packer_escape_o,
    output logic             miss_valid_o,
    output fp_miss_reason_e  miss_reason_o
);
    bs_capsule_t cap;

    tensor_result_packer #(.LANES(16), .EXP_W(12)) u_pack (
        .cells_i        (cells_i),
        .target_w_sel_i (2'd2),                  // W=16 INT (Vector fast-path lane)
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
        .capsule_o      (cap),
        .escape_o       (packer_escape_o),
        .all_zero_o     (),
        .block_nan_o    (),
        .block_inf_o    ()
    );

    vec_ctrl_t ctrl;
    always_comb begin
        ctrl              = '0;
        ctrl.block_size   = ctrl_block_size_i;
        ctrl.scale_format = ctrl_scale_format_i;
        ctrl.scale_epoch  = ctrl_scale_epoch_i;
    end

    vec_ingress_arb u_arb (
        .clk_i            (1'b0),
        .rst_ni           (1'b1),
        .resident_valid_i (1'b0),
        .resident_ready_o (),
        .resident_cap_i   ('0),
        .fpath_valid_i    (1'b1),
        .fpath_ready_o    (),
        .fpath_cap_i      (cap),
        .ctrl_i           (ctrl),
        .ctrl_valid_i     (ctrl_valid_i),
        .out_valid_o      (out_valid_o),
        .out_ready_i      (1'b1),
        .out_cap_o        (),
        .miss_valid_o     (miss_valid_o),
        .miss_reason_o    (miss_reason_o),
        .miss_from_fpath_o ()
    );
endmodule

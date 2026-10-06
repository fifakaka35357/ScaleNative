// ============================================================================
// tb_vec_cmd_to_desc.sv — STEP4-E2E harness for the vec_cmd_t -> vec_exec_desc_t
// adapter, focused on the new OP_VEC_RESADD mapping (and legacy regression).
// Flattens the combinational adapter's command/contract inputs and descriptor
// outputs for cocotb. Oracle: the mapping spec in vec_cmd_to_desc.sv.
// ============================================================================
module tb_vec_cmd_to_desc
    import pe_pkg::*;
    import vec_pkg::*;
(
    input  logic [7:0]  opcode_i,
    input  logic [1:0]  block_size_log2_i,   // BS_16=0 / BS_32=1
    input  logic        fwd_eligible_i,
    input  logic [7:0]  scale_epoch_i,
    input  logic [8:0]  src_row_i,
    input  logic [8:0]  dst_row_i,
    // [T3-FF/FF3b-c] streaming contract inputs
    input  logic        src1_resident_i,
    input  logic [15:0] len_rows_i,
    input  logic [8:0]  cmd_sidecar_base_i,   // physical row (cp_scheduler xlat'd)

    output logic [5:0]  prim_id_o,
    output logic [2:0]  op_class_o,
    output logic [1:0]  desc_block_size_o,
    output logic [2:0]  desc_scale_format_o,
    output logic        desc_fwd_eligible_o,
    output logic [7:0]  desc_scale_epoch_o,
    output logic [15:0] desc_src0_ref_o,
    output logic [15:0] desc_dst_ref_o,
    // [T3-FF/FF3b-c] streaming descriptor outputs
    output logic [15:0] desc_block_count_o,
    output logic [15:0] desc_sidecar_base_o
);
    vec_cmd_t       cmd;
    vec_exec_desc_t desc;

    always_comb begin
        cmd                          = '0;
        cmd.opcode                   = desc_opcode_e'(opcode_i);
        cmd.src_row                  = src_row_i;
        cmd.dst_row                  = dst_row_i;
        cmd.len_rows                 = len_rows_i;
        cmd.sidecar_base             = cmd_sidecar_base_i;
        cmd.contract.block_size_log2 = block_size_log2_e'(block_size_log2_i);
        cmd.contract.fwd_eligible    = fwd_eligible_i;
        cmd.contract.scale_epoch     = scale_epoch_i;
        cmd.contract.src1_resident   = src1_resident_i;
    end

    vec_cmd_to_desc u_dut (
        .cmd_valid_i ( 1'b1 ),
        .cmd_ready_o (      ),
        .cmd_i       ( cmd  ),
        .desc_valid_o(      ),
        .desc_ready_i( 1'b1 ),
        .desc_o      ( desc )
    );

    assign prim_id_o           = desc.primitive_id;
    assign op_class_o          = desc.op_class;
    assign desc_block_size_o   = desc.block_size;
    assign desc_scale_format_o = desc.scale_format;
    assign desc_fwd_eligible_o = desc.fwd_eligible;
    assign desc_scale_epoch_o  = desc.scale_epoch;
    assign desc_src0_ref_o     = desc.src0_ref;
    assign desc_dst_ref_o      = desc.dst_ref;
    assign desc_block_count_o  = desc.block_count;
    assign desc_sidecar_base_o = desc.sidecar_base;
endmodule

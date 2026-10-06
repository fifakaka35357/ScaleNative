// ============================================================================
// tb_mac_ofu — testbench wrapper: mac_cell → output_format_unit (C07 end-to-end)
// ============================================================================
//
// Wires a single MAC cell's block-float accumulator output directly into the
// Output Format Unit. This is the complete intended Class-C escape dataflow
// (block-float accumulate → standard FP), and the strongest single proof that
// C07's source rebias (mac_lru/mac_cell) and OFU normalization (+47) are
// mutually consistent — neither side can be wrong in isolation and still match
// an independent IEEE golden.
//
// Test-only harness; not part of the synthesized design.
// ============================================================================
module tb_mac_ofu
  import tensor_pkg::*;
(
  input  logic         clk,
  input  logic         rst_n,
  input  tensor_mode_e mode,
  input  logic         mac_en,
  input  logic         array_step_en,   // §C6: clocks the FP feedforward stage
  input  logic         clear_acc,
  input  logic [3:0]   lane_valid,
  input  logic [15:0]  weight_in,
  input  logic         weight_load,
  input  logic [15:0]  act_in,
  input  logic [7:0]   mx_scale_a_cur,
  input  logic [7:0]   mx_scale_b_cur,
  input  out_fmt_e     out_fmt,
  input  out_round_e   round_mode,

  output logic [31:0]  ofu_result,
  output logic         ofu_valid,
  output fp_acc_output_t fp_acc_out
);

  fp_acc_output_t acc;
  fp_acc_output_t snapshot_unused;
  logic [15:0]    wstream_unused;
  logic signed [ACC_WIDTH_DEFAULT-1:0] psum_unused;
  logic [3:0]     sparsity_unused;
  logic           skip_unused;

  mac_cell u_mac (
    .clk               (clk),
    .rst_n             (rst_n),
    .mode              (mode),
    .mac_en            (mac_en),
    .array_step_en     (array_step_en),
    .clear_acc         (clear_acc),
    .capture_fire      (1'b0),
    .lane_valid        (lane_valid),
    .weight_in         (weight_in),
    .weight_load       (weight_load),
    .weight_stream_en  (1'b0),
    .act_in            (act_in),
    .mx_scale_a_cur    (mx_scale_a_cur),
    .mx_scale_b_cur    (mx_scale_b_cur),
    .psum_in           ('0),
    .psum_out          (psum_unused),
    .fp_acc_out        (acc),
    .fp_acc_snapshot   (snapshot_unused),
    .weight_stream_out (wstream_unused),
    .sparsity_map_in   (4'b0),
    .sparsity_map_out  (sparsity_unused),
    .skip_accumulation (skip_unused)
  );

  assign fp_acc_out = acc;

  output_format_unit u_ofu (
    .acc_in     (acc),
    .out_fmt    (out_fmt),
    .round_mode (round_mode),
    .result     (ofu_result),
    .ofu_valid  (ofu_valid)
  );

endmodule

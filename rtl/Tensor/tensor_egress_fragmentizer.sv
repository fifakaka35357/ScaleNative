// ============================================================================
// Tensor Egress Fragmentizer v4.3 (Round E1 / R4)
// ============================================================================
//
// NEW MODULE — introduced in Round E1 / R4 as part of the Vector Unit OFU
// Sidecar Migration. This module is the bridge between the Tensor Unit's
// per-MAC snapshot bank and the Vector-side consumers (native store unit,
// OFU sidecar, external interfaces).
//
// See:
//   Vector_Unit_OFU_Sidecar_Design_Plan.md §5.4  (design specification)
//   Tensor_Unit_Design_Rationale.md D25          (snapshot bank rationale)
//
// ----------------------------------------------------------------------------
// Purpose
// ----------------------------------------------------------------------------
//
// The tile controller drives a 1-cycle `capture_done` pulse when the tile
// FSM transitions from ST_CAPTURE → ST_DONE. At that moment, all 256 MAC
// cells have atomically latched their fp_acc_out into fp_acc_snapshot_q
// (see mac_cell.sv Section 11). The snapshot is now stable and independent
// of the accumulator state — the next tile can begin compute while this
// fragmentizer is still emitting the previous tile's results.
//
// On receiving capture_done, this module walks through rows 0..15 of the
// snapshot bank, emitting one 16-cell fragment per accepted handshake cycle.
// After the last row handshakes, it pulses bank_release and returns to IDLE,
// signaling to the controller that the snapshot bank is free for the next
// tile to write into.
//
// ----------------------------------------------------------------------------
// Interface Summary
// ----------------------------------------------------------------------------
//
//   FROM tile controller (R5):
//     capture_done        — 1-cycle pulse on ST_CAPTURE → ST_DONE
//
//   TO tile controller:
//     snapshot_bank_available — 1 = IDLE, 0 = SCAN or DONE (back-pressure)
//     bank_release_pulse      — 1-cycle pulse on SCAN → DONE completion
//
//   TO tensor_mac_array row mux (R6):
//     read_row [3:0]      — Row index to read (0..15)
//     read_en             — Read enable (only asserted in SCAN state)
//
//   FROM tensor_mac_array row mux (R6):
//     row_data [16]       — 16 fp_acc_output_t cells of the selected row
//                           (combinational row mux, no read latency)
//
//   TO downstream consumers (via tensor_unit_top routing — R9):
//     frag_data [16]      — 16 fp_acc_output_t cells (passthrough of row_data)
//     frag_valid          — AXI-style valid
//     frag_ready          — AXI-style ready (from consumer, back-pressure)
//     frag_row_idx [3:0]  — Current row index (for downstream epoch/ordering)
//     frag_last_row       — 1 on the final row of the tile
//
// ----------------------------------------------------------------------------
// Single Responsibility
// ----------------------------------------------------------------------------
//
// This module does EXACTLY ONE job: drain the snapshot bank row-by-row and
// emit clean handshaked fragments. It deliberately does NOT:
//
//   - Carry descriptor metadata (exec_class/out_class/out_fmt/epoch).
//     That is the job of tensor_unit_top (R9), which combines this
//     module's output with the controller-latched descriptor.
//
//   - Do any format conversion, rounding, or packing.
//     The output is pure block-float (fp_acc_output_t), exactly as the
//     Tensor Unit's architectural contract requires (Invariant 1 in the
//     design plan).
//
//   - Perform any egress routing decision (OUT_STORE_NATIVE vs OUT_ESCAPE_FMT
//     vs OUT_FWD_VEC_NATIVE). That is tensor_unit_top's responsibility.
//
//   - Handle any future per-MAC sparse ingress / direct injection.
//     Ingress adaptation, if ever needed, will be a separate module.
//
// This minimalism is deliberate — see Vector_Unit_OFU_Sidecar_Design_Plan.md
// §5.4 bullet 4 (Q4 decision: fragmentizer single responsibility).
//
// ----------------------------------------------------------------------------
// FSM
// ----------------------------------------------------------------------------
//
//     +----------+  capture_done   +----------+
//     |  EG_IDLE | --------------> |  EG_SCAN |
//     |          |                 |          | ---+
//     | bank_    |                 | read_row |    | handshake
//     | available|                 | = cnt    |    | && !last_row
//     |  = 1     |                 | frag_    |    |
//     +-----^----+                 |  valid=1 | <--+
//           |                      |          |
//           |                      +------+---+
//           |                             | handshake
//           |                             |  && last_row
//           |       (auto, 1 cycle)       v
//           |                      +----------+
//           +----------------------+  EG_DONE |
//                                  |          |
//                                  | bank_    |
//                                  | release_ |
//                                  | pulse=1  |
//                                  +----------+
//
//   Timing for a typical tile (16 rows, no backpressure):
//     Cycle A     : capture_done asserted      (state=IDLE -> d=SCAN)
//     Cycle A+1   : emit row 0                 (state=SCAN, row_cnt=0)
//     Cycle A+2   : emit row 1                 (row_cnt=1)
//     ...
//     Cycle A+16  : emit row 15 (last_row=1)   (row_cnt=15, d=DONE)
//     Cycle A+17  : bank_release_pulse         (state=DONE)
//     Cycle A+18  : IDLE, snapshot_bank_available=1
//
//   Worst-case occupancy: 17 cycles (16 row cycles + 1 epoch boundary).
//   For BF16 with K >= 17, compute time >= occupancy time -> no stall.
//   For smaller K, occasional CAPTURE-entry stall (see design plan risk 8.2).
//
// ----------------------------------------------------------------------------
// Invariants (enforced by assertions in Section 6)
// ----------------------------------------------------------------------------
//
//   I1. capture_done may only arrive in EG_IDLE.
//       Violation = tile overwrite (previous snapshot corrupted).
//
//   I2. snapshot_bank_available == (state_q == EG_IDLE).
//       This flag is the single source of truth for the controller's
//       ST_CAPTURE entry decision.
//
//   I3. bank_release_pulse only in EG_DONE.
//       Pulse is exactly 1 cycle wide.
//
//   I4. EG_DONE unconditionally transitions to EG_IDLE next cycle.
//       No stall, no external condition; the state is a single-cycle epoch
//       marker only.
//
//   I5. frag_valid only in EG_SCAN.
//       Outside SCAN, frag_* outputs are all zero.
//
//   I6. frag_valid stays high until handshake (AXI protocol compliance).
//       Consumer-side back-pressure cannot cause the fragmentizer to
//       drop a valid before the consumer accepts it.
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R4 — new module)
// ============================================================================

module tensor_egress_fragmentizer
  import tensor_pkg::*;
#(
  parameter int ROWS = 16,                  // Rows in the snapshot bank
  parameter int COLS = 16                   // Columns per row (fragment width)
) (
  // ---- Clock / Reset ----
  input  logic              clk,
  input  logic              rst_n,

  // ---- From tile controller (R5) ----
  //
  // capture_done is a 1-cycle pulse asserted by the tile controller exactly
  // once per tile, during the ST_CAPTURE -> ST_DONE transition. The snapshot
  // bank contents are guaranteed to be stable from this moment forward.
  input  logic              capture_done,

  // ---- To tile controller: bank state ----
  //
  // snapshot_bank_available is combinationally derived from state_q. It is
  // HIGH only in EG_IDLE. The controller gates its ST_DRAIN -> ST_CAPTURE
  // transition on this flag; if the bank is busy, the controller stalls
  // at the end of DRAIN until the previous tile's scan completes.
  output logic              snapshot_bank_available,

  // bank_release_pulse is a 1-cycle pulse asserted when the scan completes.
  // Primary use: performance counter in tensor_status_csr.
  // Also useful for debug / TB event tracing.
  output logic              bank_release_pulse,

  // ---- To tensor_mac_array (R6): row-mux read interface ----
  //
  // The array top-level exposes a 16:1 row mux over the per-MAC snapshot
  // registers. This fragmentizer drives the row index and the array
  // combinationally returns the 16 cells of that row via row_data.
  //
  // Note: no read latency. The array's row mux is pure combinational logic.
  output logic [3:0]        read_row,
  output logic              read_en,
  input  fp_acc_output_t    row_data [COLS],

  // ---- Fragment output (to tensor_unit_top routing in R9) ----
  //
  // AXI-style valid/ready handshake. Consumer drives frag_ready; this
  // fragmentizer drives all other signals.
  //
  // frag_data is a passthrough of row_data during EG_SCAN (no buffering).
  // frag_row_idx and frag_last_row are control-plane metadata — the
  // downstream consumer (native store unit, or future Vector ingress) uses
  // these to track tile completion and row ordering.
  output fp_acc_output_t    frag_data [COLS],
  output logic              frag_valid,
  input  logic              frag_ready,
  output logic [3:0]        frag_row_idx,
  output logic              frag_last_row
);

  // ==========================================================================
  // Section 1: FSM State Encoding
  // ==========================================================================

  typedef enum logic [1:0] {
    EG_IDLE = 2'b00,   // Bank empty, waiting for capture_done
    EG_SCAN = 2'b01,   // Emitting rows row_cnt_q = 0..ROWS-1
    EG_DONE = 2'b10    // 1-cycle bank release epoch marker
  } egress_state_e;

  egress_state_e state_q, state_d;

  // ==========================================================================
  // Section 2: Row Counter
  // ==========================================================================

  localparam int ROW_W = (ROWS > 1) ? $clog2(ROWS) : 1;

  // Explicit unsigned width-typed constants (avoid signed/unsigned mixing in
  // comparisons and increments, which would otherwise trigger strict-lint
  // SignCompare and ArithOpMismatch warnings).
  localparam logic [ROW_W-1:0] ROW_CNT_LAST = ROW_W'(unsigned'(ROWS - 1));
  localparam logic [ROW_W-1:0] ROW_CNT_INC  = ROW_W'(unsigned'(32'd1));

  logic [ROW_W-1:0] row_cnt_q, row_cnt_d;
  logic             last_row;
  logic             handshake;

  assign last_row  = (row_cnt_q == ROW_CNT_LAST);
  assign handshake = frag_valid & frag_ready;

  // ==========================================================================
  // Section 3: Next-State + Next-Counter Logic
  // ==========================================================================

  always_comb begin
    // Default: hold state and counter
    state_d   = state_q;
    row_cnt_d = row_cnt_q;

    unique case (state_q)

      // ---- EG_IDLE ----
      // Wait for capture_done. On pulse, enter SCAN and zero row_cnt.
      EG_IDLE: begin
        if (capture_done) begin
          state_d   = EG_SCAN;
          row_cnt_d = '0;
        end
      end

      // ---- EG_SCAN ----
      // Emit one row per cycle when handshake succeeds.
      // On last row handshake, transition to DONE.
      // If frag_ready=0, hold state and row_cnt (AXI back-pressure).
      EG_SCAN: begin
        if (handshake) begin
          if (last_row) begin
            state_d   = EG_DONE;
            // row_cnt_d left alone — will be reset on next IDLE entry
          end else begin
            row_cnt_d = row_cnt_q + ROW_CNT_INC;
          end
        end
      end

      // ---- EG_DONE ----
      // 1-cycle epoch boundary. Unconditional transition to IDLE.
      EG_DONE: begin
        state_d = EG_IDLE;
      end

      default: begin
        state_d = EG_IDLE;
      end

    endcase
  end

  // ==========================================================================
  // Section 4: State Registers
  // ==========================================================================

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q   <= EG_IDLE;
      row_cnt_q <= '0;
    end else begin
      state_q   <= state_d;
      row_cnt_q <= row_cnt_d;
    end
  end

  // ==========================================================================
  // Section 5: Output Generation (Moore outputs from state_q)
  // ==========================================================================
  //
  // All outputs are decoded combinationally from state_q (and row_cnt_q
  // for the SCAN state). frag_data is a passthrough of row_data during
  // SCAN — no buffering, no latency.

  always_comb begin
    // ---- Defaults: all outputs inactive ----
    read_row                = '0;
    read_en                 = 1'b0;
    frag_valid              = 1'b0;
    frag_row_idx            = '0;
    frag_last_row           = 1'b0;
    snapshot_bank_available = 1'b0;
    bank_release_pulse      = 1'b0;
    for (int c = 0; c < COLS; c++)
      frag_data[c] = '0;

    unique case (state_q)

      // ---- EG_IDLE ----
      EG_IDLE: begin
        snapshot_bank_available = 1'b1;
      end

      // ---- EG_SCAN ----
      EG_SCAN: begin
        // Drive row index to array row mux
        // (row_cnt_q is already ROW_W=4 bits wide for default ROWS=16, so
        //  no width cast needed; avoids a UselessCast strict-lint warning.)
        read_row = row_cnt_q;
        read_en  = 1'b1;

        // Passthrough row_data to frag_data
        for (int c = 0; c < COLS; c++)
          frag_data[c] = row_data[c];

        // Valid handshake signaling
        frag_valid    = 1'b1;
        frag_row_idx  = row_cnt_q;
        frag_last_row = last_row;
      end

      // ---- EG_DONE ----
      EG_DONE: begin
        bank_release_pulse = 1'b1;
      end

      default: ;

    endcase
  end

  // ==========================================================================
  // Section 6: Assertions
  // ==========================================================================
  //
  // These assertions encode the six architectural invariants listed in the
  // header. Violation of any of these indicates a bug in the controller or
  // a protocol violation by the downstream consumer.

  // synopsys translate_off

  // --- I1: capture_done may only arrive in EG_IDLE ---
  //
  // Tile overwrite protection. If the controller asserts capture_done while
  // the bank is still being scanned, the previous tile's snapshot would be
  // corrupted. The controller's ST_DRAIN -> ST_CAPTURE transition is gated
  // on snapshot_bank_available, so this should never happen.
  assert property (@(posedge clk) disable iff (!rst_n)
      capture_done |-> (state_q == EG_IDLE)
  ) else $error("TENSOR_EGRESS_FRAG [I1]: capture_done arrived while bank busy — tile overwrite risk");

  // --- I2: snapshot_bank_available <=> EG_IDLE ---
  //
  // The bank_available flag must exactly track the IDLE state. If these
  // diverge, the controller may make incorrect ST_CAPTURE decisions.
  assert property (@(posedge clk) disable iff (!rst_n)
      snapshot_bank_available == (state_q == EG_IDLE)
  ) else $error("TENSOR_EGRESS_FRAG [I2]: bank_available inconsistent with FSM state");

  // --- I3: bank_release_pulse only in EG_DONE ---
  assert property (@(posedge clk) disable iff (!rst_n)
      bank_release_pulse |-> (state_q == EG_DONE)
  ) else $error("TENSOR_EGRESS_FRAG [I3]: bank_release_pulse asserted outside EG_DONE");

  // --- I4: EG_DONE must transition to EG_IDLE next cycle ---
  //
  // The epoch boundary state is strictly 1 cycle. If it ever lingers, the
  // bank_release_pulse would widen beyond 1 cycle and perf counters would
  // double-count.
  assert property (@(posedge clk) disable iff (!rst_n)
      (state_q == EG_DONE) |=> (state_q == EG_IDLE)
  ) else $error("TENSOR_EGRESS_FRAG [I4]: EG_DONE did not transition to IDLE in next cycle");

  // --- I5: frag_valid only in EG_SCAN ---
  //
  // Outside SCAN, frag_data is zero and frag_valid is low. This ensures
  // the downstream consumer sees a clean protocol.
  assert property (@(posedge clk) disable iff (!rst_n)
      frag_valid |-> (state_q == EG_SCAN)
  ) else $error("TENSOR_EGRESS_FRAG [I5]: frag_valid asserted outside EG_SCAN");

  // --- I6: frag_valid stable until handshake (AXI protocol compliance) ---
  //
  // If the consumer is not ready (frag_ready=0), the fragmentizer must
  // hold frag_valid high until the transfer actually completes. Dropping
  // valid without a completed handshake is a protocol violation.
  assert property (@(posedge clk) disable iff (!rst_n)
      (frag_valid && !frag_ready) |=> frag_valid
  ) else $error("TENSOR_EGRESS_FRAG [I6]: frag_valid deasserted without handshake");

  // synopsys translate_on

endmodule

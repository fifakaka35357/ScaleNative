// ============================================================================
// Tensor Unit Top (Round E1 / R9) — Top-Level Wrapper
// ============================================================================
//
// This module is the RTL embodiment of "the Tensor Unit" as an architectural
// whole. It is a single-responsibility wrapper: it instantiates all Tensor
// Unit submodules, wires them together, and exposes a clean, stable external
// interface to the PE top level.
//
// See:
//   Vector_Unit_OFU_Sidecar_Design_Plan.md §6   (top-level wiring plan)
//   Tensor_Unit_Design_Rationale.md    D23/D25/D26
//   Phase_E1_Continuation_Task_List.md Task B    (scope, port freeze)
//
// ----------------------------------------------------------------------------
// Single-Responsibility Boundary
// ----------------------------------------------------------------------------
//
// This wrapper contains NO compute logic. It contains only:
//   1. Submodule instantiations
//   2. Wire declarations between submodules
//   3. Egress routing MUX (combinational, routing decision only)
//   4. One-cycle shadow registers for scan-time descriptor fields
//      (tile_desc_scan_q, result_base_scan_q) — see note below
//   5. Assertions
//
// ALL FSM logic lives in tensor_tile_controller (R5) and
// tensor_egress_fragmentizer (R4). ALL datapath logic lives in
// tensor_mac_array (R6). This wrapper deliberately stays thin so that its
// diff surface remains small as the Tensor Unit evolves.
//
// ----------------------------------------------------------------------------
// Why we need a scan-time shadow register
// ----------------------------------------------------------------------------
//
// When tensor_egress_fragmentizer is emitting rows for tile N, the
// tensor_tile_controller may already be processing tile N+1 (compute or
// drain — the two pipelines overlap by design, gated on the snapshot bank
// available flag). At that moment:
//
//   - tile_desc_active tracks tile N+1 (the currently-computing tile).
//   - desc_result_base may also have advanced if a new descriptor was
//     dequeued.
//
// But the fragmentizer's row-scan must write to tile N's destination, with
// tile N's out_class/out_fmt/epoch metadata. So this wrapper maintains a
// one-stage shadow register that snapshots the current-tile descriptor and
// result_base at the moment of capture_fire. This shadow is used by:
//
//   - The egress routing MUX (picks OUT_STORE_NATIVE vs OUT_ESCAPE_FMT path).
//   - tensor_native_store_unit (receives out_class and result_base_addr).
//   - External egress metadata (egress_frag_out_class / out_fmt / epoch).
//
// The shadow lifetime is: latched on capture_fire, valid through the
// subsequent EG_SCAN phase, overwritten on the NEXT capture_fire. Because
// the fragmentizer's bank_release gates the controller's next ST_CAPTURE
// entry, we are guaranteed that the shadow is never overwritten while a
// scan is still in progress.
//
// ----------------------------------------------------------------------------
// Egress Routing MUX (§5.4 of design plan, Task B spec item 3)
// ----------------------------------------------------------------------------
//
// tensor_egress_fragmentizer emits row fragments without knowing where they
// go. This wrapper makes the routing decision based on tile_desc_scan_q.out_class:
//
//   OUT_STORE_NATIVE  → native_store_unit           (Class B, Phase E1 alive)
//   OUT_FWD_VEC_NATIVE→ external egress port        (Class A, Phase E2+ wired)
//   OUT_ESCAPE_FMT    → external egress port        (Class C, Phase E3+ wired)
//
// For Class A and Class C, the external egress port is shared — downstream
// (Vector Unit or OFU sidecar) uses out_class and out_fmt to decide what to
// do. This keeps the top-level port count minimal.
//
// The MUX is expressed as:
//
//   route_to_native = (tile_desc_scan_q.out_class == OUT_STORE_NATIVE)
//   native_store.frag_valid = frag_valid_from_fragmentizer & route_to_native
//   egress_frag_valid       = frag_valid_from_fragmentizer & !route_to_native
//   frag_ready_to_fragmentizer = route_to_native ? native_store.frag_ready
//                                                 : egress_frag_ready
//
// ----------------------------------------------------------------------------
// External port naming freeze (Task B spec item 4)
// ----------------------------------------------------------------------------
//
//   egress_frag_*     → this Tensor Unit's perspective (the row is egressing)
//   vector_ingress_*  → the Vector Unit's perspective (the row is ingressing)
//
// These names will be wired together in Phase E4 at pe_top.sv. Neither side
// embeds the other's name in its own ports — the pairing is done at PE top.
//
// Author:  H-Tensor Project
// Version: 4.3 (Round E1 / R9 — tensor_unit_top creation)
// ============================================================================

module tensor_unit_top
  import tensor_pkg::*;
#(
  parameter int ROWS       = 16,
  parameter int COLS       = 16,
  parameter int DATA_WIDTH = 16,
  parameter int ACC_WIDTH  = ACC_WIDTH_DEFAULT,   // 48
  parameter int SRAM_DEPTH = 512,                 // [STEP5/D-ORFS-SRAM] 4096->512: 综合用现成 512-deep 宏 banking(24 宏)；原型 16x16 tile K<<512。ADDR_WIDTH 保留 12(超宽无害)
  parameter int ADDR_WIDTH = 12,                  // 地址口宽(实际用 [8:0])
  parameter int DESC_QUEUE_DEPTH = 4,
  parameter bit ZEROSKIP_EN     = 1'b1,  // [C1 2026-07-31] 原 SPARSE_EN 拆分：per-cell 零门控
  // [3a-1 S2 2026-08-03] parameter bit SPARSE_QUEUE_EN 已删（K 令牌通路退役，规格 §4.1）
  // [P4/D-CONV-BASE] converter-based baseline (paper headline delta). Default 0 =
  // converter-free (bit-identical to today). =1 adds a 16x per-egress OFU bank
  // formatting each result to standard FP + a widened FP writeback (gen_cb only).
  parameter bit CONVERTER_BASED   = 1'b0,
  parameter bit CONVERTER_PER_MAC = 1'b0   // secondary ablation (256x per-MAC); NOT YET implemented
) (
  // =========================================================================
  // Clock / Reset
  // =========================================================================
  input  logic                    clk,
  input  logic                    rst_n,

  // =========================================================================
  // MMIO Interface (command + status)
  // =========================================================================
  //
  // Single 8-bit address space shared by cmd_decoder (writes) and status_csr
  // (reads). Register maps are documented inside each submodule's header.
  input  logic                    mmio_wr_valid,
  input  logic [7:0]              mmio_wr_addr,
  input  logic [31:0]             mmio_wr_data,

  input  logic [7:0]              mmio_rd_addr,
  output logic [31:0]             mmio_rd_data,

  input  logic                    counter_clear,   // Clear performance counters

  // =========================================================================
  // DMA Write Ports to Behavioral SRAM (for test data loading)
  // =========================================================================
  //
  // Passed through to tensor_sram_wrapper. Phase E4 may replace these with
  // a real DMA engine's port into the PE memory subsystem.
  input  logic                    dma_wgt_wr_en,
  input  logic [ADDR_WIDTH-1:0]   dma_wgt_wr_addr,
  input  logic [DATA_WIDTH-1:0]   dma_wgt_wr_data   [COLS],

  input  logic                    dma_act_wr_en,
  input  logic [ADDR_WIDTH-1:0]   dma_act_wr_addr,
  input  logic [DATA_WIDTH-1:0]   dma_act_wr_data   [ROWS],

  input  logic                    dma_scale_wr_en,
  input  logic [ADDR_WIDTH-1:0]   dma_scale_wr_addr,
  input  logic [7:0]              dma_scale_wr_data_wgt [COLS],
  input  logic [7:0]              dma_scale_wr_data_act [ROWS],

  // =========================================================================
  // [3a-1 S4 2026-08-03] Sparse Fragment Ingress —— 三个外部端口已删除
  // =========================================================================
  //   sparse_frag_valid / sparse_frag_ready / sparse_frag_in
  // 规格 §4.1「K 令牌通路退役」收口。原注释宣称的 **D19 ready↔valid 解耦语义**
  // （ready 由队列水位驱动、与 valid 无关）随通路一并作废 —— 队列已于 S2 删除。

  // =========================================================================
  // Egress Fragment Port (Class A + Class C external path, Phase E2/E3 wire)
  // =========================================================================
  //
  // In Phase E1, the Class A (OUT_FWD_VEC_NATIVE) and Class C (OUT_ESCAPE_FMT)
  // paths are both routed to this single external port. The consumer (Vector
  // Unit in Phase E2 for Class A, Vector OFU sidecar in Phase E3 for Class C)
  // reads out_class and out_fmt to dispatch internally.
  //
  // From the Tensor Unit's perspective this is an EGRESS port. At pe_top.sv
  // (Phase E4) these signals will be wired to the Vector Unit's symmetric
  // vector_ingress_* ports.
  //
  // [STEP4-D2] The egress now emits ONE formed block16 fast-path capsule per row
  // (bs_capsule_t) instead of 16 raw fp_acc_output_t cells — tensor_result_packer
  // narrows 48b->16b in-line (Q9 port change sanctioned). egress_frag_escape is
  // asserted when the row's exponent spread exceeds the block-float budget (route
  // Class C instead of forwarding the capsule).
  output pe_pkg::bs_capsule_t     egress_frag_capsule,
  output logic                    egress_frag_escape,
  output logic                    egress_frag_valid,
  input  logic                    egress_frag_ready,
  output logic [3:0]              egress_frag_row_idx,
  output logic                    egress_frag_last_row,
  output out_class_e              egress_frag_out_class,
  output out_fmt_e                egress_frag_out_fmt,
  output logic [7:0]              egress_frag_epoch,

  // =========================================================================
  // Native SRAM Write Port (Class B, Phase E4 native-region SRAM macro)
  // =========================================================================
  //
  // Exposed at the top level so that PE integration can bind this to a
  // 64-bit-wide native-region SRAM macro in Phase E4. In Phase E1 unit
  // simulations, these signals may be terminated by a behavioral stub or
  // left unconnected (monitored by TB).
  //
  // One native SRAM entry = COLS × 64 bits. Write address = result_base
  // + row_idx. See tensor_native_store_unit for full description.
  output logic                    native_wr_en,
  output logic [ADDR_WIDTH-1:0]   native_wr_addr,
  output tensor_native_capsule_t  native_wr_data [COLS],

  // [P4/D-CONV-BASE] converter-based widened FP writeback (SRAM-wall side of the
  // headline). Persistent ports (SV ports can't be generate-conditional); driven
  // only when CONVERTER_BASED=1, else tied '0. Each element = 32b standard FP
  // (FP32 full / BF16/FP16 [15:0] / FP8 [7:0]) from the per-egress OFU bank.
  output logic                    ofu_wr_en,
  output logic [ADDR_WIDTH-1:0]   ofu_wr_addr,
  output logic [31:0]             ofu_wr_data [COLS],

  // [P4/D-CONV-BASE] 256x per-MAC OFU ablation digest (CONVERTER_PER_MAC; tied 0 else)
  output logic [31:0]             pmac_ofu_digest,

  // =========================================================================
  // Top-Level Status
  // =========================================================================
  //
  // Aggregated from the tile controller, native store unit, and
  // fragmentizer. Additional per-submodule detail is available via the
  // status_csr MMIO read port.
  output logic                    tu_busy,         // Any submodule active
  output logic                    tu_tile_done,    // Pulse: controller tile done
  output logic                    tu_capture_done, // Pulse: snapshot ready
  output logic                    tu_scan_done,    // Pulse: scan bank released
  output logic                    tu_wb_done       // Pulse: native store finished
);

  // ==========================================================================
  // ==========================================================================
  //                      SECTION A: Internal Signal Declarations
  // ==========================================================================
  // ==========================================================================

  // ---- cmd_decoder ↔ desc_queue ----
  logic                      desc_push_valid;
  logic                      desc_push_ready;
  tile_descriptor_t          desc_out;
  logic [ADDR_WIDTH-1:0]     desc_wgt_base;
  logic [ADDR_WIDTH-1:0]     desc_act_base;
  logic [ADDR_WIDTH-1:0]     desc_scale_base;
  logic [ADDR_WIDTH-1:0]     desc_result_base;
  logic                      force_abort;         // Currently unused but exposed by decoder

  // ---- desc_queue ↔ tile_controller + operand_fetch + scale_buffer ----
  logic                      dq_rd_valid;
  logic                      dq_rd_ready;
  tile_descriptor_t          dq_rd_desc;
  logic [ADDR_WIDTH-1:0]     dq_rd_wgt_base;
  logic [ADDR_WIDTH-1:0]     dq_rd_act_base;
  logic [ADDR_WIDTH-1:0]     dq_rd_scale_base;
  logic [ADDR_WIDTH-1:0]     dq_rd_result_base;
  logic [$clog2(DESC_QUEUE_DEPTH+1)-1:0] dq_fill_level;
  logic                      dq_full;
  logic                      dq_empty;

  // ---- Tile controller outputs ----
  logic                      ctrl_busy;
  logic                      ctrl_done;
  logic                      ctrl_issue_en;
  logic                      ctrl_array_step_en;
  logic                      ctrl_clear_acc;
  logic                      ctrl_weight_load_en;
  logic                      ctrl_capture_fire;
  logic                      ctrl_capture_done;
  logic                      ctrl_result_valid;
  logic [3:0]                ctrl_active_tail_mask;
  logic                      ctrl_mx_scale_tick;
  logic                      ctrl_mx_mode_active;
  logic                      ctrl_tile_start_out;
  tile_descriptor_t          ctrl_tile_desc_active;
  logic [15:0]               ctrl_dense_k_cursor;

  // ---- Tile controller inputs (driven elsewhere) ----
  logic                      ctrl_start;
  // [3a-1 S2] ctrl_frag_dense_k_advance / ctrl_frag_valid_in / ctrl_frag_group_last
  //   三条已删 —— 实测无驱动无读者（各只有一行声明），是 v4.2b 留下的死网线。
  logic                      snapshot_bank_available;

  // ---- operand_fetch ↔ sram_wrapper ↔ mac_array ----
  logic                      wgt_rd_en;
  logic [ADDR_WIDTH-1:0]     wgt_rd_addr;
  logic [DATA_WIDTH-1:0]     wgt_rd_data [COLS];
  logic                      wgt_rd_valid;

  logic                      act_rd_en;
  logic [ADDR_WIDTH-1:0]     act_rd_addr;
  logic [DATA_WIDTH-1:0]     act_rd_data [ROWS];
  logic                      act_rd_valid;

  logic [DATA_WIDTH-1:0]     weight_out [COLS];
  logic                      weight_valid_out;
  logic [DATA_WIDTH-1:0]     act_out    [ROWS];
  logic                      act_valid_out;

  // ---- scale_buffer ↔ sram_wrapper ↔ mac_array ----
  logic                      scale_rd_en;
  logic [ADDR_WIDTH-1:0]     scale_rd_addr;
  logic [7:0]                scale_rd_data_wgt [COLS];
  logic [7:0]                scale_rd_data_act [ROWS];
  logic                      scale_rd_valid;

  logic [7:0]                weight_scale_out   [COLS];
  logic                      weight_scale_valid [COLS];
  logic [7:0]                act_scale_out      [ROWS];
  logic                      act_scale_valid    [ROWS];

  // ---- mac_array ↔ fragmentizer (snapshot row mux) ----
  logic [3:0]                snapshot_read_row;
  logic                      snapshot_read_en;
  fp_acc_output_t            snapshot_row_data [COLS];

  // ---- [3a-1 S2/S3 2026-08-03] mac_array 的 sparse ingress queue 已删 ----
  //    S2 曾在此保留 5 条 mac_sparse_deq_* wire 并绑常量，作为 S2↔S3 之间唯一的
  //    可 elaborate 中间态装置（controller 的 frag_* 输入端口 S3 才删）。
  //    **S3 已与 controller 端口同 commit 删除**，中间态窗口关闭。

  // [K1c] controller next-state control views -> array quadrant clones
  logic [3:0]                ctrl_tail_mask_d;
  logic                      ctrl_clear_acc_d;
  logic                      ctrl_capture_fire_d;
  logic                      ctrl_step_d;

  // INT psum chain output + live FP result (debug-only paths, unused at top level)
  logic signed [ACC_WIDTH-1:0] mac_result [ROWS][COLS];
  logic                        mac_result_valid;
  fp_acc_output_t              mac_fp_result [ROWS][COLS];

  // ---- fragmentizer outputs ----
  fp_acc_output_t            frag_data_bus [COLS];
  logic                      frag_valid_bus;
  logic                      frag_ready_bus;          // into fragmentizer (routed back)
  logic [3:0]                frag_row_idx_bus;
  logic                      frag_last_row_bus;
  logic                      bank_release_pulse;

  // ---- native_store_unit handshake ----
  logic                      ns_frag_valid_mux;   // MUX output, defined in Section E
  logic                      ns_frag_ready;
  logic                      ns_wb_busy;
  logic                      ns_wb_done;

  // ==========================================================================
  // ==========================================================================
  //                SECTION B: Scan-Time Descriptor Shadow
  // ==========================================================================
  // ==========================================================================
  //
  // See header comment "Why we need a scan-time shadow register" for the
  // full rationale. This shadow latches the current-tile descriptor and
  // result_base at capture_fire, providing stable metadata for the egress
  // routing MUX and the native store unit throughout the subsequent scan
  // even as the controller begins work on the next tile.

  tile_descriptor_t          tile_desc_scan_q;
  logic [ADDR_WIDTH-1:0]     result_base_scan_q;

  // One-stage shadow of the currently-computing tile's result_base, latched
  // on controller.start. We need this intermediate stage because
  // tile_desc_active is latched inside tile_controller on start, but
  // result_base is not — so we mirror that latching here to keep the two
  // in sync when capture_fire eventually fires.
  logic [ADDR_WIDTH-1:0]     result_base_compute_q;

  // [STEP4-E2E] Operand-base latches (wgt/act/scale), latched on ctrl_start.
  //
  // BUG FIX (first GEMM bring-up, §9.8): the operand SRAM bases were wired
  // straight from the desc_queue HEAD (dq_rd_{wgt,act,scale}_base) into
  // operand_fetch / scale_buffer. But the queue is DEQUEUED on the same
  // ctrl_start pulse that launches the tile (dq_rd_ready = ctrl_start), so one
  // cycle later the head advances to the NEXT (empty=0) entry. operand_fetch
  // then reads weight/activation rows from base 0 for the ENTIRE tile —
  // silently correct only when the base happened to be 0. (result_base was
  // already latched here for exactly this reason — see result_base_compute_q;
  // the wgt/act/scale bases simply weren't. This restores symmetry.) The bases
  // must persist for the whole tile lifetime, so latch them at start.
  logic [ADDR_WIDTH-1:0]     wgt_base_q, act_base_q, scale_base_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result_base_compute_q <= '0;
      wgt_base_q            <= '0;
      act_base_q            <= '0;
      scale_base_q          <= '0;
    end else if (ctrl_start) begin
      result_base_compute_q <= dq_rd_result_base;
      wgt_base_q            <= dq_rd_wgt_base;
      act_base_q            <= dq_rd_act_base;
      scale_base_q          <= dq_rd_scale_base;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tile_desc_scan_q   <= '0;
      result_base_scan_q <= '0;
    end else if (ctrl_capture_fire) begin
      tile_desc_scan_q   <= ctrl_tile_desc_active;
      result_base_scan_q <= result_base_compute_q;
    end
  end

  // ==========================================================================
  // ==========================================================================
  //                SECTION C: Descriptor Start-Pulse Arbiter
  // ==========================================================================
  // ==========================================================================
  //
  // The desc_queue holds fully-assembled descriptors. Whenever the
  // controller is idle and the queue has a head, we pulse `start` (which
  // simultaneously dequeues the head and latches it into tile_desc_q inside
  // tile_controller). This is the simplest policy: FIFO auto-issue.

  assign ctrl_start    = dq_rd_valid && !ctrl_busy;
  assign dq_rd_ready   = ctrl_start;

  // ==========================================================================
  // ==========================================================================
  //                SECTION D: Submodule Instantiations
  // ==========================================================================
  // ==========================================================================

  // --------------------------------------------------------------------------
  // D.1  tensor_cmd_decoder — MMIO → descriptor
  // --------------------------------------------------------------------------
  // [3a-7/P4 2026-08-06] decoder → status_csr 的拒收观测线（规格 §5.4）。
  //   🔴 §5.0f 提醒：这条线的两端**都是纯静默方向**（删连接留端口 = PINMISSING 被两闸
  //      waive；输出悬空 = UNDRIVEN 默认关）⇒ 三个改点必须**同 commit**（推论 1），
  //      且必须配 lint 红臂才算自证生效（判据见 prereg §9.2 的六条 RA）。
  logic dec_err_desc_reject;

  tensor_cmd_decoder #(
    .ADDR_WIDTH(ADDR_WIDTH)
  ) u_cmd_decoder (
    .clk              (clk),
    .rst_n            (rst_n),

    .mmio_wr_valid    (mmio_wr_valid),
    .mmio_wr_addr     (mmio_wr_addr),
    .mmio_wr_data     (mmio_wr_data),

    .desc_push_valid  (desc_push_valid),
    .desc_push_ready  (desc_push_ready),
    .desc_out         (desc_out),
    .desc_wgt_base    (desc_wgt_base),
    .desc_act_base    (desc_act_base),
    .desc_scale_base  (desc_scale_base),
    .desc_result_base (desc_result_base),

    .err_desc_reject  (dec_err_desc_reject),

    .force_abort      (force_abort),
    .ctrl_busy        (ctrl_busy)
  );

  // --------------------------------------------------------------------------
  // D.2  tensor_desc_queue — descriptor FIFO
  // --------------------------------------------------------------------------
  tensor_desc_queue #(
    .DEPTH      (DESC_QUEUE_DEPTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_desc_queue (
    .clk            (clk),
    .rst_n          (rst_n),

    .wr_valid       (desc_push_valid),
    .wr_ready       (desc_push_ready),
    .wr_desc        (desc_out),
    .wr_wgt_base    (desc_wgt_base),
    .wr_act_base    (desc_act_base),
    .wr_scale_base  (desc_scale_base),
    .wr_result_base (desc_result_base),

    .rd_valid       (dq_rd_valid),
    .rd_ready       (dq_rd_ready),
    .rd_desc        (dq_rd_desc),
    .rd_wgt_base    (dq_rd_wgt_base),
    .rd_act_base    (dq_rd_act_base),
    .rd_scale_base  (dq_rd_scale_base),
    .rd_result_base (dq_rd_result_base),

    .fill_level     (dq_fill_level),
    .full           (dq_full),
    .empty          (dq_empty)
  );

  // --------------------------------------------------------------------------
  // D.3  tensor_tile_controller — FSM
  // --------------------------------------------------------------------------
  tensor_tile_controller #(
    .ROWS (ROWS),
    .COLS (COLS)
  ) u_tile_controller (
    .clk                     (clk),
    .rst_n                   (rst_n),

    // Command interface
    .start                   (ctrl_start),
    .tile_desc               (dq_rd_desc),

    // Sparse runtime handshake (fragment already dequeued by mac_array's
    // sparse_ingress_queue; these come from mac_array's dequeued view)

    // Snapshot bank handshake
    .snapshot_bank_available (snapshot_bank_available),

    // Status
    .busy                    (ctrl_busy),
    .done                    (ctrl_done),

    // Array control
    .issue_en                (ctrl_issue_en),
    .array_step_en           (ctrl_array_step_en),
    // [K1c] next-state views for the array quadrant clones
    .active_tail_mask_d      (ctrl_tail_mask_d),
    .clear_acc_d             (ctrl_clear_acc_d),
    .capture_fire_d          (ctrl_capture_fire_d),
    .array_step_en_d         (ctrl_step_d),
    .clear_acc               (ctrl_clear_acc),
    .weight_load_en          (ctrl_weight_load_en),

    // Snapshot capture
    .capture_fire            (ctrl_capture_fire),
    .capture_done            (ctrl_capture_done),

    // K iteration
    .result_valid            (ctrl_result_valid),
    .active_tail_mask        (ctrl_active_tail_mask),

    // MX scale
    .mx_scale_tick           (ctrl_mx_scale_tick),
    .mx_mode_active          (ctrl_mx_mode_active),

    // Tile lifecycle
    .tile_start_out          (ctrl_tile_start_out),

    // Active descriptor (used by the scan-time shadow and egress MUX)
    .tile_desc_active        (ctrl_tile_desc_active),

    // Debug
    .dense_k_cursor_out      (ctrl_dense_k_cursor)
  );

  // --------------------------------------------------------------------------
  // D.4  tensor_operand_fetch — descriptor-driven weight/act read
  // --------------------------------------------------------------------------
  //
  // tile_active = ctrl_busy (operand_fetch is live whenever a tile is in
  //               flight — its internal weight_load_en / issue_en gating
  //               narrows down the actual SRAM accesses to the right phases).
  tensor_operand_fetch #(
    .ROWS       (ROWS),
    .COLS       (COLS),
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_operand_fetch (
    .clk              (clk),
    .rst_n            (rst_n),

    .tile_active      (ctrl_busy),
    .wgt_base_addr    (wgt_base_q),    // [STEP4-E2E] latched-at-start base (see fix above)
    .act_base_addr    (act_base_q),    // [STEP4-E2E] latched-at-start base

    // OS-GEMM T1: dataflow + contraction length for weight-stream + zero-pad.
    // Both come from the controller's latched descriptor (stable for the tile).
    .dataflow_sel     (ctrl_tile_desc_active.dataflow_sel),
    .k_total          (ctrl_tile_desc_active.k_total),

    // [3a-4/M1] act 腿越界判据的 cursor 基（规格 §4.2 per-leg 拆分）。
    //   净线 ctrl_dense_k_cursor 早已在（controller :246/:1012 → :534），本片只是
    //   多接一处 —— 无需新开 controller 端口。按 PROJECT_RULES §5.0f 登记为
    //   **1 个方向**（加输入 + 同 commit 接线）；~~漏接是**响亮**的：未接输入读 0
    //   ⇒ act_in_range_d 恒真 ⇒ 零填充整体失效 ⇒ R1 八形状全红。~~
    //   🔴🔴 **[3a-4/M4 2026-08-03 实测推翻，原文划掉保留]**：上面那句是**前 per-leg 拆分**
    //   时代的表述（那时一根 in_range_d 同管两腿）。M1 拆成两腿之后它已不成立 ——
    //   mutation 臂 5 实测断开本连线：**R1 TESTS=6 PASS=6 全绿、CONSUMED 8/8**
    //   （s3a45_m4_mut_5_20260806.log）。机理：dense 臂两腿上界**都是 k_total**，
    //   DRAIN 尾窗里权重腿自己就把乘积压成 0 ⇒ act 腿失效被权重腿完全掩盖。
    //   ⇒ **本连线漏接对 R1 是【纯静默】的**，与下面两条同类，不是反例。
    //   真正抓得住它的是 **M4 的稀疏探针**（臂 5b 实测：k23/k25/k26 三发
    //   256/256、256/256、245/256 cell != dense golden；k24 因 Kp=K 无 pad 拍而不受影响，
    //   s3a45_m4_mut_5b_20260806.log）—— 稀疏臂权重上界是 Kp，[K,Kp) 段权重腿不再强零，
    //   act 腿成为唯一防线。**该守门是 M4 才出现的，M1 那一刻并不存在。**
    //   ⇒ M1 的端口闭包实际上**只由 §5.0f 静态自检守住**（那条确实跑了且配了红臂，
    //     s3a45_m1_lint_20260806.txt 绿 0 / 红 1）。静态自检在本模块不是可选项。
    .dense_k_cursor   (ctrl_dense_k_cursor),

    // [3a-4/M4] B3/B5 权重腿稀疏上界 ⌈K/4⌉×N 的两个描述符视图。
    //   🔴 **这两条漏接是纯静默的**（未接输入读 0 = EXEC_DENSE/NCFG_DENSE ⇒ 走 dense 臂
    //   ⇒ R1 与探针全绿）。**与上面那条 cursor 同类**（见上方 M4 订正框：
    //   原以为 cursor 是响亮的反例，实测推翻）⇒ **本模块目前【没有】任何一个输入端口
    //   的漏接是被 R1 抓得住的**。
    //   按 PROJECT_RULES §5.0f 登记为 **1 个方向**（加输入 + 同 commit 接线），
    //   闭包判据 = §5.0f 推论 2 的静态自检 + 红臂，**不是**任何一条仿真闸。
    .sparse_mode      (ctrl_tile_desc_active.sparse_mode),
    .n_cfg            (ctrl_tile_desc_active.n_cfg),

    .weight_load_en   (ctrl_weight_load_en),
    .issue_en         (ctrl_issue_en),
    .tile_start       (ctrl_tile_start_out),

    .wgt_rd_en        (wgt_rd_en),
    .wgt_rd_addr      (wgt_rd_addr),
    .wgt_rd_data      (wgt_rd_data),
    .wgt_rd_valid     (wgt_rd_valid),

    .act_rd_en        (act_rd_en),
    .act_rd_addr      (act_rd_addr),
    .act_rd_data      (act_rd_data),
    .act_rd_valid     (act_rd_valid),

    .weight_out       (weight_out),
    .weight_valid_out (weight_valid_out),
    .act_out          (act_out),
    .act_valid_out    (act_valid_out)
  );

  // --------------------------------------------------------------------------
  // D.5  tensor_scale_buffer — MX scale fetch + boundary alignment
  // --------------------------------------------------------------------------
  tensor_scale_buffer #(
    .ROWS       (ROWS),
    .COLS       (COLS),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_scale_buffer (
    .clk                (clk),
    .rst_n              (rst_n),

    .mx_mode_active     (ctrl_mx_mode_active),
    .scale_base_addr    (scale_base_q),  // [STEP4-E2E] latched-at-start base (see fix above)
    .tile_start         (ctrl_tile_start_out),

    .mx_scale_tick      (ctrl_mx_scale_tick),

    .scale_rd_en        (scale_rd_en),
    .scale_rd_addr      (scale_rd_addr),
    .scale_rd_data_wgt  (scale_rd_data_wgt),
    .scale_rd_data_act  (scale_rd_data_act),
    .scale_rd_valid     (scale_rd_valid),

    .weight_scale_out   (weight_scale_out),
    .weight_scale_valid (weight_scale_valid),
    .act_scale_out      (act_scale_out),
    .act_scale_valid    (act_scale_valid)
  );

  // --------------------------------------------------------------------------
  // D.6  tensor_sram_wrapper — behavioral SRAM (3 banks)
  // --------------------------------------------------------------------------
  //
  // The write port (wr_en/wr_addr/wr_data) was the legacy formatted-output
  // writeback path driven by the old tensor_writeback_unit. That path has
  // been removed in Round E1. For Phase E1 we tie the legacy formatted-write
  // port to disabled; native-region writes go to native_wr_* (top-level
  // output) and will bind to a future 64-bit-wide native SRAM macro.
  tensor_sram_wrapper #(
    .ROWS       (ROWS),
    .COLS       (COLS),
    .DATA_WIDTH (DATA_WIDTH),
    .SRAM_DEPTH (SRAM_DEPTH),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_sram_wrapper (
    .clk               (clk),
    .rst_n             (rst_n),

    .wgt_rd_en         (wgt_rd_en),
    .wgt_rd_addr       (wgt_rd_addr),
    .wgt_rd_data       (wgt_rd_data),
    .wgt_rd_valid      (wgt_rd_valid),

    .act_rd_en         (act_rd_en),
    .act_rd_addr       (act_rd_addr),
    .act_rd_data       (act_rd_data),
    .act_rd_valid      (act_rd_valid),

    .scale_rd_en       (scale_rd_en),
    .scale_rd_addr     (scale_rd_addr),
    .scale_rd_data_wgt (scale_rd_data_wgt),
    .scale_rd_data_act (scale_rd_data_act),
    .scale_rd_valid    (scale_rd_valid),

    // Legacy formatted writeback port — disabled in Phase E1.
    .wr_en             (1'b0),
    .wr_addr           ('0),
    .wr_data           ('{default:'0}),

    .dma_wgt_wr_en         (dma_wgt_wr_en),
    .dma_wgt_wr_addr       (dma_wgt_wr_addr),
    .dma_wgt_wr_data       (dma_wgt_wr_data),

    .dma_act_wr_en         (dma_act_wr_en),
    .dma_act_wr_addr       (dma_act_wr_addr),
    .dma_act_wr_data       (dma_act_wr_data),

    .dma_scale_wr_en       (dma_scale_wr_en),
    .dma_scale_wr_addr     (dma_scale_wr_addr),
    .dma_scale_wr_data_wgt (dma_scale_wr_data_wgt),
    .dma_scale_wr_data_act (dma_scale_wr_data_act)
  );

  // --------------------------------------------------------------------------
  // D.7  tensor_mac_array — 16×16 systolic compute core + snapshot bank
  // --------------------------------------------------------------------------
  //
  // [3a-1 S4 2026-08-03] S2 补的 `assign sparse_frag_ready = 1'b0;` 与其记述已随
  //   外部端口一并删除，S2↔S4 的过渡装置全部拆净。

  tensor_mac_array #(
    .ROWS       (ROWS),
    .COLS       (COLS),
    .DATA_WIDTH (DATA_WIDTH),
    .ACC_WIDTH  (ACC_WIDTH),
    .ZEROSKIP_EN     (ZEROSKIP_EN),
    .CONVERTER_PER_MAC (CONVERTER_PER_MAC)
  ) u_mac_array (
    .clk                (clk),
    .rst_n              (rst_n),

    .mode               (ctrl_tile_desc_active.mode),
    .issue_en           (ctrl_issue_en),
    .array_step_en      (ctrl_array_step_en),
    .weight_load        (ctrl_weight_load_en),
    .clear_acc          (ctrl_clear_acc),

    // Snapshot capture + row mux
    .capture_fire       (ctrl_capture_fire),
    .snapshot_read_row  (snapshot_read_row),
    .snapshot_read_en   (snapshot_read_en),
    .snapshot_row_data  (snapshot_row_data),

    .active_tail_mask   (ctrl_active_tail_mask),
    // [K1c] next-state control views -> per-quadrant clone registers
    .ctrl_tail_mask_d   (ctrl_tail_mask_d),
    .ctrl_clear_acc_d   (ctrl_clear_acc_d),
    .ctrl_capture_fire_d (ctrl_capture_fire_d),
    .ctrl_step_d        (ctrl_step_d),
    .dataflow_sel       (ctrl_tile_desc_active.dataflow_sel),

    // Sparse execution mode (per-tile, from descriptor)
    // [3a-1 S2] 保留：新守卫（tensor_mac_array.sv Assertions 段）的唯一观测量
    .sparse_exec_mode   (ctrl_tile_desc_active.sparse_mode),

    // [3a-1 S2 2026-08-03] sparse fragment 写侧 3 条 + 读侧 7 条连接已删（端口已不存在）

    // Tile lifecycle
    .tile_start         (ctrl_tile_start_out),
    .ctrl_result_valid  (ctrl_result_valid),

    // Data inputs
    .weight_in          (weight_out),
    .weight_valid       (weight_valid_out),
    .act_in             (act_out),
    .act_valid          (act_valid_out),

    // INT/MX result (unused at top level — Class A/B/C all go through snapshot)
    .result             (mac_result),
    .result_valid       (mac_result_valid),

    // Live FP result (debug-only, unused at top level)
    .fp_result          (mac_fp_result),

    // [P4/D-CONV-BASE] 256x per-MAC OFU ablation digest -> top output
    .pmac_ofu_digest    (pmac_ofu_digest),

    // MX scale sideband
    .weight_scale_in    (weight_scale_out),
    .weight_scale_valid (weight_scale_valid),
    .act_scale_in       (act_scale_out),
    .act_scale_valid    (act_scale_valid)
  );

  // --------------------------------------------------------------------------
  // D.8  tensor_egress_fragmentizer — snapshot row scan
  // --------------------------------------------------------------------------
  //
  // Consumer-side handshake is multiplexed in Section E below. Here we wire
  // the producer side (from mac_array's snapshot bank) and the control
  // handshake (from the tile controller).
  tensor_egress_fragmentizer #(
    .ROWS (ROWS),
    .COLS (COLS)
  ) u_egress_fragmentizer (
    .clk                     (clk),
    .rst_n                   (rst_n),

    .capture_done            (ctrl_capture_done),

    .snapshot_bank_available (snapshot_bank_available),
    .bank_release_pulse      (bank_release_pulse),

    .read_row                (snapshot_read_row),
    .read_en                 (snapshot_read_en),
    .row_data                (snapshot_row_data),

    .frag_data               (frag_data_bus),
    .frag_valid              (frag_valid_bus),
    .frag_ready              (frag_ready_bus),
    .frag_row_idx            (frag_row_idx_bus),
    .frag_last_row           (frag_last_row_bus)
  );

  // --------------------------------------------------------------------------
  // D.9  tensor_native_store_unit — Class B store (fragmentizer consumer)
  // --------------------------------------------------------------------------
  tensor_native_store_unit #(
    .ROWS       (ROWS),
    .COLS       (COLS),
    .ADDR_WIDTH (ADDR_WIDTH)
  ) u_native_store (
    .clk              (clk),
    .rst_n            (rst_n),

    .out_class        (tile_desc_scan_q.out_class),
    .result_base_addr (result_base_scan_q),

    // Handshake input is MUXed in Section E
    .frag_data        (frag_data_bus),
    .frag_valid       (ns_frag_valid_mux),
    .frag_ready       (ns_frag_ready),
    .frag_row_idx     (frag_row_idx_bus),
    .frag_last_row    (frag_last_row_bus),

    // Native SRAM write port (external)
    .native_wr_en     (native_wr_en),
    .native_wr_addr   (native_wr_addr),
    .native_wr_data   (native_wr_data),

    .wb_busy          (ns_wb_busy),
    .wb_done          (ns_wb_done)
  );

  // --------------------------------------------------------------------------
  // D.10  tensor_status_csr — CPU-visible status + counters
  // --------------------------------------------------------------------------
  tensor_status_csr u_status_csr (
    .clk                (clk),
    .rst_n              (rst_n),

    .mmio_rd_addr       (mmio_rd_addr),
    .mmio_rd_data       (mmio_rd_data),

    .ctrl_busy          (ctrl_busy),
    .ctrl_done          (ctrl_done),
    .dense_k_cursor     (ctrl_dense_k_cursor),
    .current_mode       (ctrl_tile_desc_active.mode),

    // [3a-1 S2] .sparse_queue_level 连接已删（status_csr 端口同步删除；
    //   CSR 0x08[2:0] 已在 S0 字段级 tie 0，[6:4] desc_queue_level 是活体）
    .desc_queue_level   (3'(dq_fill_level)),

    .wb_busy            (ns_wb_busy),

    // Performance counter inputs
    .issue_en           (ctrl_issue_en),
    .array_step_en      (ctrl_array_step_en),
    .mx_scale_tick      (ctrl_mx_scale_tick),

    // Error flags: not yet driven at this layer — tie to 0
    // 🔴 [3a-7/P4] 下面这两行是 PROJECT_RULES §5.0d 型 14（守卫恒读 0）的在册实例，
    //    拆除**归 3a-8**。3a-7 全片一个字不碰它们 —— 它们就在新连线的紧邻行，
    //    是本片停机清单第 7 条最大的诱因。commit 前须 git diff 逐行确认零改动。
    .err_epoch_mismatch (1'b0),
    .err_mode_mismatch  (1'b0),
    // [3a-7/P4 2026-08-06] 🔴 与上两行**性质相反**：本条有真产生式（u_cmd_decoder），
    //    是 0x1C bit[2] 的 LIVE 驱动源，不是 tie。
    .err_desc_reject    (dec_err_desc_reject),

    .counter_clear      (counter_clear)
  );

  // ==========================================================================
  // ==========================================================================
  //                  SECTION E: Egress Routing MUX (Task B spec item 3)
  // ==========================================================================
  // ==========================================================================
  //
  // Consumer-select MUX in the top wrapper. Decides per-row whether the
  // fragmentizer's output goes to tensor_native_store_unit (Class B) or to
  // the external egress port (Class A / Class C).
  //
  // The fragmentizer sees a single unified frag_ready input. The routing is
  // transparent to it — it keeps AXI-protocol compliance on that single
  // handshake channel (see fragmentizer Invariant I6).

  // Routing predicate — evaluated from scan-time shadow so it stays stable
  // across the entire row-scan phase even if the controller advances to the
  // next tile.
  logic route_to_native;
  assign route_to_native = (tile_desc_scan_q.out_class == OUT_STORE_NATIVE);

  // Consumer 1: tensor_native_store_unit (Class B)
  assign ns_frag_valid_mux = frag_valid_bus & route_to_native;

  // Consumer 2: external egress port (Class A + Class C)
  assign egress_frag_valid = frag_valid_bus & ~route_to_native;

  // Consolidated ready back to fragmentizer
  assign frag_ready_bus = route_to_native ? ns_frag_ready
                                          : egress_frag_ready;

  // [STEP4-D2] tensor_result_packer — form the block16 fast-path capsule from the
  // current egress row. The row = C[i][0..15] = 16 output channels of one token =
  // a natural block16 MX block along the OUTPUT-channel dim (Design_Notes N5),
  // independent of the input MX block along K. Fast-path lane = signed INT16
  // block-float (the Vector RESADD lane); epoch/round from the scan-time shadow.
  // native_store (Class B) keeps consuming the raw frag_data_bus via its own port
  // (unchanged) — this packer sits only on the egress branch.
  //
  // [STEP4-E2E Phase D] block16 shared scale = SCALE_E4M3, the dual-ecosystem
  // NVFP4 default for block16 (D12). This MATCHES the Vector RESADD descriptor,
  // which derives scale_format from the block size in vec_cmd_to_desc (block16 ->
  // SCALE_E4M3, block32 -> SCALE_E8M0); vec_ingress_arb exact-matches block_size +
  // scale_format, so an E8M0 block16 capsule would MISS (§9.8 F3). The packer
  // emits an E4M3 byte with mant=0, so the Vector scale adapter sees mant_corr=128
  // (precise-mode correction = identity) — the proven tb_vec_consume_e2e config.
  tensor_result_packer #(.LANES(COLS), .EXP_W(12)) u_result_packer (
    .cells_i        (frag_data_bus),
    .target_w_sel_i (2'd2),                                  // W=16 INT lane
    .kind_fp_i      (1'b0),
    .round_rne_i    (tile_desc_scan_q.ofu_round == OUT_ROUND_RNE),
    .block_size_i   (pe_pkg::BLOCK_SIZE_16),
    .scale_format_i (pe_pkg::SCALE_E4M3),
    .scale_epoch_i  (tile_desc_scan_q.epoch),
    .ctx_id_i       ('0),
    .tag_i          ('0),
    .elem_fmt_i     (pe_pkg::ELEM_BFP_INTERNAL),
    .operand_role_i (pe_pkg::OP_SRC0),
    .spread_limit_i (4'd14),
    .capsule_o      (egress_frag_capsule),
    .escape_o       (egress_frag_escape),
    .all_zero_o     (),
    .block_nan_o    (),
    .block_inf_o    ()
  );
  assign egress_frag_row_idx  = frag_row_idx_bus;
  assign egress_frag_last_row = frag_last_row_bus;

  // External egress metadata comes from the scan-time shadow (the descriptor
  // of the tile being scanned, which may be a previous tile to the one the
  // controller is now working on).
  assign egress_frag_out_class = tile_desc_scan_q.out_class;
  assign egress_frag_out_fmt   = tile_desc_scan_q.out_fmt;
  assign egress_frag_epoch     = tile_desc_scan_q.epoch;

  // ==========================================================================
  // [P4/D-CONV-BASE] CONVERTER-BASED BASELINE (pure-additive; the converter-free
  // egress above — u_result_packer + native_store + route MUX — is UNTOUCHED).
  // When CONVERTER_BASED=1, gen_cb adds a 16x per-egress OFU bank (one
  // output_format_unit per column, tapping frag_data_bus) that formats each result
  // to a STANDARD FP word, plus a widened FP writeback (ofu_wr_*). This DELIBERATELY
  // re-introduces the OFU-in-Tensor "architectural leak" as the faithful-v4.2c
  // object-of-argument baseline (NOT an endorsed architecture) — see
  // output_format_unit.sv header + Plan/ConverterBased_Baseline_Plan.md.
  // =1 area/Fmax delta vs =0 = the marginal cost of a boundary converter.
  // out_fmt/round reuse the scan-shadow descriptor (no new MMIO; documented reuse).
  // ==========================================================================
  generate
    if (CONVERTER_BASED) begin : gen_cb
      logic [31:0] ofu_result [COLS];
      for (genvar c = 0; c < COLS; c++) begin : g_ofu_bank
        output_format_unit u_ofu (
          .acc_in     (frag_data_bus[c]),
          .out_fmt    (tile_desc_scan_q.out_fmt),
          .round_mode (tile_desc_scan_q.ofu_round),
          .result     (ofu_result[c]),
          .ofu_valid  ()
        );
      end
      // Widened FP store: one write per egress row; monotonic write pointer
      // (row-paced like native_store; the addr scheme itself is PPA-neutral).
      logic [ADDR_WIDTH-1:0] ofu_wr_ptr_q;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)              ofu_wr_ptr_q <= '0;
        else if (frag_valid_bus) ofu_wr_ptr_q <= ofu_wr_ptr_q + 1'b1;
      end
      assign ofu_wr_en   = frag_valid_bus;
      assign ofu_wr_addr = ofu_wr_ptr_q;
      for (genvar c = 0; c < COLS; c++) begin : g_ofu_wb
        assign ofu_wr_data[c] = ofu_result[c];
      end
    end else begin : gen_cf
      // converter-free: only the NEW ofu_wr_* ports are tied off here; the
      // converter-free egress (packer/native_store/route MUX) is untouched.
      assign ofu_wr_en   = 1'b0;
      assign ofu_wr_addr = '0;
      for (genvar c = 0; c < COLS; c++) begin : g_ofu_tie
        assign ofu_wr_data[c] = '0;
      end
    end
  endgenerate

  // ==========================================================================
  // ==========================================================================
  //                 SECTION F: Top-Level Status Aggregation
  // ==========================================================================
  // ==========================================================================

  assign tu_busy         = ctrl_busy | ns_wb_busy | (frag_valid_bus); // any pipeline stage active
  assign tu_tile_done    = ctrl_done;
  assign tu_capture_done = ctrl_capture_done;
  assign tu_scan_done    = bank_release_pulse;
  assign tu_wb_done      = ns_wb_done;

  // ==========================================================================
  // ==========================================================================
  //                 SECTION G: Assertions
  // ==========================================================================
  // ==========================================================================

  // synopsys translate_off

  // --- G1: at most one of the two egress consumers ever handshakes ---
  //
  // The routing MUX is mutually exclusive by construction. This assertion
  // catches accidental re-introduction of shared routing (e.g. a future
  // optimization that tries to broadcast to both consumers).
  assert property (@(posedge clk) disable iff (!rst_n)
      !(ns_frag_valid_mux && egress_frag_valid)
  ) else $error("TENSOR_UNIT_TOP [G1]: both egress consumers simultaneously valid");

  // --- G2: descriptor legality — catch illegal out_class values reaching scan shadow ---
  //
  // ~~🔴 [3a-2 2026-08-03] 下面这句是假声明（型 15）：实测 tensor_cmd_decoder 全文
  //   不调用 is_valid_descriptor，推送无条件……真正的拒收实现归 3a-7。~~
  //   ▲**[3a-7/P5 2026-08-06 订正]：下面那句原文【已由实现追平，不再是假声明】。**
  //   `tensor_cmd_decoder` 现在确实调用 `is_valid_descriptor` 并据此拒收：
  //   `assign desc_push_valid = start_pulse && !desc_reject;`（纯组合，P5 落地）。
  //   🔴 **但本 SVA（G2）的现役价值随之翻面**：非法描述符**根本进不了队列**
  //   ⇒ 本条「第二道防线」对它们**结构性不可达、零红样本**。
  //   留着它是**便宜的冗余**（万一门被改坏），但**禁再把它记为「有红样本的守门」**。
  //   原文（现在是真的了）保留：
  // The cmd_decoder is expected to reject illegal descriptors via
  // is_valid_descriptor() before they ever enter the queue, but a second
  // line of defence at the scan-time shadow is cheap and robust.
  //
  // 🔴 [3a-7/P3 2026-08-05] **本条【不】随 R5-6 升 $fatal**（裁决 D6，理由是规范性的）：
  //   ① 规格 §5.4 逐字**只点名 R5-6**；
  //   ② 本条的响点在 fragment **已发出之后**（采样量 `tile_desc_scan_q` 由 `ctrl_capture_fire`
  //      装载）⇒ 性质是**尸检层第二道防线**，不是守卫；
  //   ③ 升级会让它与 R5-6 抢首发，进一步搅乱 guard-probe 的 tag 归因（R0 审查 blocker B3）。
  //   推翻它需要两件：规格 §5.4 一并点名 G2 **且**给出 G2 与 R5-6 的首发次序分析与各自红样本。
  //
  // 🔴 **上游遮蔽登记**：3a-7/P3 起，凡 is_valid_descriptor 判非法的描述符都会先被
  //   R5-6（`$fatal`，早一拍）中止 ⇒ **本条在那些注入下结构性不可能响**。
  //   3a-7/P5 把门加到 `desc_push_valid` 上之后，非法描述符**根本不入队** ⇒ 遮蔽更彻底。
  //   ⇒ **禁把本条继续记为「有红样本的守门」**；它的红样本转绿条件 = 一条能绕过 push 门
  //   直驱 `tile_desc_scan_q` 的注入路径（本片不做，登记在收口报告）。
  assert property (@(posedge clk) disable iff (!rst_n)
      frag_valid_bus |-> is_valid_descriptor(tile_desc_scan_q)
  ) else $error("TENSOR_UNIT_TOP [G2]: scan shadow carries illegal descriptor combination");

  // --- G3: bank_release_pulse implies fragmentizer is retiring scan ---
  //
  // When bank_release fires, the shadow should remain valid for one more
  // cycle (for any downstream logic that wants to latch completion
  // metadata). This assertion just sanity-checks that frag_valid_bus is
  // already low by the release cycle (per fragmentizer's EG_DONE contract).
  assert property (@(posedge clk) disable iff (!rst_n)
      bank_release_pulse |-> !frag_valid_bus
  ) else $error("TENSOR_UNIT_TOP [G3]: bank_release_pulse while frag_valid still high");

  // synopsys translate_on

endmodule

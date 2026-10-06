// =============================================================================
// tensor_cmd_mmio_seq.sv — tens_cmd_t -> MMIO start sequence (STEP4-E2E, inc 3a)
//
// The real Tensor unit (Tensor/tensor_unit_top) is controlled over an MMIO
// register interface (fire-and-forget writes; a CTRL@0x00 bit[0] start pulse
// latches the param registers and pushes a tile descriptor). The PE issues
// tens_cmd_t. This little FSM bridges them: on a tensor command it emits the
// fixed register-write sequence, then the start pulse, then waits for the
// tile-done pulse and returns a PE completion (ctx/tag).
//
// MMIO map (Tensor/tensor_external_modules.sv tensor_cmd_decoder):
//   0x04 K_TOTAL   [15:0]
//   0x0C OUT_CTRL  [1:0]exec_class [3:2]out_class [5:4]out_fmt [6]ofu_round
//   0x10 EPOCH     [7:0]
//   0x14 WGT_BASE / 0x18 ACT_BASE / 0x1C SCL_BASE / 0x20 RES_BASE  (internal SRAM rows)
//   0x00 CTRL      [7:4]=mode, [8]=dataflow_sel, bit[0]=start pulse
//
// For the E2E we request Class A (OUT_FWD_VEC_NATIVE) so the GEMM result rows
// egress as bs_capsule_t to the fast path. The operand base addresses point
// into the Tensor's INTERNAL SRAM; the L2->SRAM operand streamer (increment 3b)
// loads that SRAM before this FSM runs and owns the actual base layout — here
// the bases are carried from the command rows as placeholders.
//
// [STEP4-E2E Phase C] The CTRL register is written TWICE: a mode pre-set
// (0x00 = MODE_BF16<<4, bit0=0) FIRST, then the start pulse (0x00 = MODE_BF16<<4
// | 1) LAST. This is REQUIRED: tensor_cmd_decoder latches reg_mode registered,
// but the descriptor pushed by the start write reads the PRIOR reg_mode — so the
// mode must be programmed by an earlier 0x00 write (§9.8 F2). Without it the
// descriptor mode defaults to the reset value MODE_UINT4_SIMD, whose results live
// in the INT psum chain (not the FP-accumulator snapshot that egresses) — so the
// egress capsule would be ALL-ZERO (§9.8 F1).
//
// [2026-07-12] The mode is NO LONGER a constant: contract.elem_fmt is now mapped
// to tensor_mode_e (see tens_mode_from_elem_fmt below), so software can select the
// block-scaled formats (MXFP4/MXFP8/MXINT8) from a descriptor. ELEM_NONE — the
// default contract every existing bench issues — still maps to MODE_BF16, so the
// established behaviour is preserved bit for bit.
// =============================================================================
module tensor_cmd_mmio_seq
    import pe_pkg::*;
    import tensor_pkg::*;
#(
    parameter int ADDR_WIDTH = 12
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,

    // ── Command in (from cp_scheduler via the wrapper) ──
    input  logic                 cmd_valid_i,
    output logic                 cmd_ready_o,
    input  tens_cmd_t            cmd_i,

    // ── Tile completion pulse from the real Tensor top (tu_tile_done) ──
    input  logic                 tile_done_i,

    // ── MMIO out to the real Tensor top ──
    output logic                 mmio_wr_valid_o,
    output logic [7:0]           mmio_wr_addr_o,
    output logic [31:0]          mmio_wr_data_o,

    // ── PE completion out ──
    output logic                 done_o,
    output logic [CTX_ID_W-1:0]  done_ctx_o,
    output logic [TAG_W-1:0]     done_tag_o,

    output logic                 busy_o
);
    // MMIO register addresses
    localparam logic [7:0] A_CTRL=8'h00, A_KTOTAL=8'h04, A_SPARSE=8'h08, A_OUTCTRL=8'h0C,
                           A_EPOCH=8'h10,
                           A_WGT=8'h14, A_ACT=8'h18, A_SCL=8'h1C, A_RES=8'h20;

    // =========================================================================
    // [3a-3 2026-08-04] exec 由 n_cfg 派生 —— 规格 §5.1/§5.2
    // =========================================================================
    // n_cfg 是唯一权威；exec（0x08[1:0]）是它的派生量。
    //
    // 🔴 派生**必须**落在本模块，不能搬进 tensor_cmd_decoder（规格 §5.1 原文）。
    //    理由是可执行的、不是风格问题：tb/scratch_guard_probe.py 直写 0x08[1:0]，
    //    ~~那是 3a-1 RED-1/RED-2 的唯一红臂。~~ 若 decoder 用 [3:2] 覆盖 [1:0]，
    //    该探针再也推不动 sparse_exec_mode ⇒ 白名单臂静默退回零覆盖。
    //    ▲[3a-4/M2 2026-08-06 订正]（原文划掉保留）：**RED-1（`0x08=0x01`）已于 M2
    //    按计划由红转绿**（`tensor_mac_array` 白名单放宽到 `{EXEC_DENSE, EXEC_SPARSE_STRUCT}`）。
    //    今天靠这条注入口活着的红臂 = 保留编码两发（`0x08=0x03` / `0x08=0x02`）
    //    + WS 绊线一发 + n_cfg 侧 P3/P4 两发 —— **注入口只增不减，本条纪律不变。**
    //
    // 编码对齐 tensor_pkg::ncfg_e（本包不 import tensor_pkg，故用裸位比较）：
    //    n_cfg==2'b00(NCFG_DENSE) -> exec=2'b00(EXEC_DENSE)
    //    否则                      -> exec=2'b01(EXEC_SPARSE_STRUCT)
    // 保留值 2'b11 走同一条「非 dense」路径（规格 §5.2「矛盾组合按 n_cfg=11 同路径」）；
    // 🔴 本模块**不做拒收**（PROJECT_RULES §5.0d C7）——拒收归 3a-7/3a-8。
    logic [1:0] derived_exec;
    assign derived_exec = (cmd_q.n_cfg == 2'b00) ? 2'b00 : 2'b01;

    // =========================================================================
    // [FIX 2026-07-12, pre-tapeout audit] contract.elem_fmt -> tensor_mode_e.
    //
    // The compute mode used to be a CONSTANT (MODE_BF16), so the descriptor field
    // contract.elem_fmt — which cp_scheduler faithfully carries all the way here —
    // was silently dropped. Consequence on silicon: software running on the IBEX
    // could only ever launch BF16 GEMMs. The block-scaled formats (MXFP4 / MXFP8 /
    // MXINT8) that this chip exists to demonstrate would have been UNREACHABLE from
    // the CPU — the datapath is there, but nothing could select it.
    //
    // Backward compatibility: the default contract (pe_pkg make_default_contract)
    // sets elem_fmt = ELEM_NONE, and every existing bench issues that default, so
    // ELEM_NONE must keep mapping to MODE_BF16 — today's behaviour, bit for bit.
    //
    // Formats the Tensor core has no mode for (FP16, BFP_INTERNAL, reserved) also
    // fall back to BF16 here. Rejecting them is the CP's job (poison-on-issue ->
    // ERR_INVALID_PARAM, pe_pkg:758); this leaf must stay total.
    //
    // 🔴 [C-1 2026-07-31] THE ABOVE DELEGATION WAS A CROSS-MODULE FAIL-OPEN UNTIL
    // TODAY. From 2026-07-12 to 2026-07-31 this comment named the CP as the gate,
    // but no such check existed anywhere — MISS_UNSUPPORTED_FMT (pe_pkg) had ZERO
    // consumers repo-wide. Both sides assumed the other was gating, so a contract
    // with ELEM_INT8/INT4 was accepted, translated to MODE_UINT8/UINT4_SIMD, and
    // executed — while the INT psum chain has NO reader in tensor_unit_top and
    // egress moves only the FP accumulator ⇒ firmware received a capsule that was
    // neither an error nor the answer. ELEM_FP8_E5M2 was equally unsafe (RTL is
    // E4M3FN-only; the $fatal guard in mac_lru.sv is inside `translate_off`, i.e.
    // simulation-only, no protection in silicon).
    //
    // The gate now EXISTS and is named:
    //   whitelist  = pe_pkg::fmt_tensor_executable()
    //   enforced at cp_desc_fetch.sv ST_FETCH_PAIR_N (word 6, wi == 6)
    //   red/green  = tb/test_cp_pe_fetch_e2e.py::test_cp_fetch_poison_bad_elem_fmt
    //                (+ ..._good_elem_fmt as the paired green)
    // 🔴 If you add a tensor_mode_e or change this map, update that whitelist in
    //    the same commit — otherwise this delegation silently becomes a lie again.
    // Registered as fail-open type 15 (PROJECT_RULES §5.0d);
    // sweep = Review/UNWIRED_CAPABILITY_SWEEP_2026-07-31.md (C-1).
    //
    // Note: the MX *block size* (MX_BLOCK_SIZE, tensor_pkg) is a compile-time
    // constant of the array, not a per-tile field — contract.block_size_log2 is
    // therefore not programmable here.
    // =========================================================================
    function automatic logic [3:0] tens_mode_from_elem_fmt(input elem_fmt_e f);
        unique case (f)
            ELEM_BF16:      return tensor_mode_e'(MODE_BF16);
            ELEM_FP8_E4M3:  return tensor_mode_e'(MODE_FP8);        // variant per FP8_FMT param
            ELEM_FP8_E5M2:  return tensor_mode_e'(MODE_FP8);        //   (single FP8 datapath)
            ELEM_FP4_E2M1:  return tensor_mode_e'(MODE_FP4);
            ELEM_INT8:      return tensor_mode_e'(MODE_UINT8);
            ELEM_INT4:      return tensor_mode_e'(MODE_UINT4_SIMD);
            ELEM_MXFP8:     return tensor_mode_e'(MODE_MXFP8);      // block-scaled (OCP MX)
            ELEM_MXFP4:     return tensor_mode_e'(MODE_MXFP4);      // block-scaled (OCP MX)
            ELEM_MXINT8:    return tensor_mode_e'(MODE_MXINT8);     // block-scaled
            default:        return tensor_mode_e'(MODE_BF16);       // ELEM_NONE / unimplemented
        endcase
    endfunction

    // Compute mode programmed into CTRL[7:4], derived from the tile contract.
    logic [3:0] tens_mode;
    assign tens_mode = tens_mode_from_elem_fmt(cmd_q.contract.elem_fmt);

    // [3a-3] 8 -> 9：0x08 写插在 step 2（A_KTOTAL 之后），start 顺延为 step 9。
    //   step_q 是 [3:0]，装得下 4'd9，**不需扩位**。
    //   不变量「start 必须是序列最后一写」结构上不受影响 —— start 由
    //   `step_q == LAST_STEP` 定义（见下方 S_EMIT 分支），不是绝对号码。
    //   ▲规格 §5.1 原文写「插入 step 1（K_TOTAL 之后）」与 RTL 自相矛盾（step 1 已是
    //     A_KTOTAL）⇒ 真值 step 2，已加规格 §5.1b 订正框。
    localparam logic [3:0] LAST_STEP = 4'd9;                        // 10 MMIO writes/tile

    typedef enum logic [1:0] { S_IDLE, S_EMIT, S_WAIT, S_DONE } state_e;
    state_e     state_q, state_d;
    logic [3:0] step_q,  step_d;     // 0..9 : ten MMIO writes per tile
    tens_cmd_t  cmd_q;

    assign cmd_ready_o = (state_q == S_IDLE);
    assign busy_o      = (state_q != S_IDLE);

    // ── MMIO emit (combinational from the current step) ──
    always_comb begin
        mmio_wr_valid_o = (state_q == S_EMIT);
        mmio_wr_addr_o  = A_CTRL;
        mmio_wr_data_o  = 32'd0;
        unique case (step_q)
            4'd0: begin mmio_wr_addr_o = A_CTRL;             // mode pre-set (bit0=0, no start)
                        mmio_wr_data_o = {24'd0, tens_mode, 4'd0}; end
            4'd1: begin mmio_wr_addr_o = A_KTOTAL;
                        mmio_wr_data_o = {16'd0, cmd_q.param_K}; end
            // [3a-3] 新插一步：0x08 = {n_cfg[3:2], exec[1:0]}。bit4(scu_en) 与
            //   [31:5] 保持 0（bit4 是 D-SCU-RESERVED 打死位，写 1 会被 decoder 忽略，
            //   但这里也不写，免得日后有人当它是 live 的）。
            4'd2: begin mmio_wr_addr_o = A_SPARSE;
                        mmio_wr_data_o = {28'd0, cmd_q.n_cfg, derived_exec}; end
            4'd3: begin mmio_wr_addr_o = A_OUTCTRL;          // Class A -> fast path
                        mmio_wr_data_o = 32'd0;
                        mmio_wr_data_o[3:2] = OUT_FWD_VEC_NATIVE;
                        mmio_wr_data_o[5:4] = OUT_FMT_BF16; end   // ignored for Class A
            4'd4: begin mmio_wr_addr_o = A_EPOCH;
                        mmio_wr_data_o = {24'd0, cmd_q.contract.scale_epoch}; end
            4'd5: begin mmio_wr_addr_o = A_WGT;             // L2_BANK_AW(9) -> 32b
                        mmio_wr_data_o = 32'(cmd_q.src_row); end
            4'd6: begin mmio_wr_addr_o = A_ACT;
                        mmio_wr_data_o = 32'(cmd_q.src_row); end
            4'd7: begin mmio_wr_addr_o = A_SCL;
                        mmio_wr_data_o = 32'd0; end
            4'd8: begin mmio_wr_addr_o = A_RES;
                        mmio_wr_data_o = 32'(cmd_q.dst_row); end
            4'd9: begin mmio_wr_addr_o = A_CTRL;             // start pulse + mode, LAST
                        mmio_wr_data_o = {24'd0, tens_mode, 3'd0, 1'b1}; end
            // 🔴 逐号对表纪律：上面的最大 case label 必须等于 LAST_STEP。
            //    不等则漏号那一拍会走 default 并发出 (A_CTRL, 32'd0)——不会静默
            //    （test_tensor_gemm_chain / test_soc_e2e 有全零 fail-closed 断言会逮住），
            //    但会浪费一整轮门禁去定位。
            default: ;
        endcase
    end

    // ── FSM next-state ──
    always_comb begin
        state_d = state_q;
        step_d  = step_q;
        case (state_q)
            S_IDLE: if (cmd_valid_i) begin state_d = S_EMIT; step_d = 4'd0; end
            S_EMIT: if (step_q == LAST_STEP) state_d = S_WAIT;
                    else                     step_d = step_q + 4'd1;
            S_WAIT: if (tile_done_i)         state_d = S_DONE;
            S_DONE:                          state_d = S_IDLE;
            default:                         state_d = S_IDLE;
        endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q <= S_IDLE;
            step_q  <= 4'd0;
            cmd_q   <= '0;
        end else begin
            state_q <= state_d;
            step_q  <= step_d;
            if (state_q == S_IDLE && cmd_valid_i) cmd_q <= cmd_i;
        end
    end

    assign done_o     = (state_q == S_DONE);
    assign done_ctx_o = cmd_q.ctx_id;
    assign done_tag_o = cmd_q.tag;
endmodule

// ============================================================================
// tb_tensor_cmd_mmio_seq.sv — STEP4-E2E (inc 3a) harness: flatten the
// tens_cmd_t -> MMIO start-sequence FSM for cocotb.
// ============================================================================
module tb_tensor_cmd_mmio_seq
    import pe_pkg::*;
    import tensor_pkg::*;
(
    input  logic                 clk_i,
    input  logic                 rst_ni,

    input  logic                 cmd_valid_i,
    output logic                 cmd_ready_o,
    input  logic [15:0]          param_K_i,
    input  logic [7:0]           scale_epoch_i,
    input  logic [8:0]           src_row_i,
    input  logic [8:0]           dst_row_i,
    input  logic [1:0]           ctx_id_i,
    input  logic [TAG_W-1:0]     tag_i,
    // [3a-3 2026-08-04] n_cfg 注入口。🔴 没有这个端口，新插的 0x08 写就恒发 0，
    //   用例退化成「只验地址不验数据」—— 而那正是本用例要防的失效模式。
    //   本端口在 python 侧必须驱**非 0**（见 test_tensor_cmd_mmio_seq.py 的两臂）。
    input  logic [1:0]           n_cfg_i,

    input  logic                 tile_done_i,

    output logic                 mmio_wr_valid_o,
    output logic [7:0]           mmio_wr_addr_o,
    output logic [31:0]          mmio_wr_data_o,

    output logic                 done_o,
    output logic [CTX_ID_W-1:0]  done_ctx_o,
    output logic [TAG_W-1:0]     done_tag_o,
    output logic                 busy_o
);
    tens_cmd_t cmd;
    always_comb begin
        cmd                      = '0;
        cmd.opcode               = OP_TENS_GEMM;
        cmd.param_K              = param_K_i;
        cmd.contract.scale_epoch = scale_epoch_i;
        cmd.src_row              = src_row_i;
        cmd.dst_row              = dst_row_i;
        cmd.ctx_id               = ctx_id_i;
        cmd.tag                  = tag_i;
        // 🔴 漏掉这一行是【纯静默】的：上面的 `cmd = '0;` 让字段有驱动且恒 0，
        //    两闸全绿、lint 零告警。红臂 = 注释掉本行，非 0 臂必须报
        //    "MMIO sequence mismatch"（数据段对不上）。
        cmd.n_cfg                = n_cfg_i;
    end

    tensor_cmd_mmio_seq u_dut (
        .clk_i           ( clk_i           ),
        .rst_ni          ( rst_ni          ),
        .cmd_valid_i     ( cmd_valid_i     ),
        .cmd_ready_o     ( cmd_ready_o     ),
        .cmd_i           ( cmd             ),
        .tile_done_i     ( tile_done_i     ),
        .mmio_wr_valid_o ( mmio_wr_valid_o ),
        .mmio_wr_addr_o  ( mmio_wr_addr_o  ),
        .mmio_wr_data_o  ( mmio_wr_data_o  ),
        .done_o          ( done_o          ),
        .done_ctx_o      ( done_ctx_o      ),
        .done_tag_o      ( done_tag_o      ),
        .busy_o          ( busy_o          )
    );
endmodule

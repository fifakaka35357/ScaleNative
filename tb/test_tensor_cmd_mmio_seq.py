"""
cocotb test for tensor_cmd_mmio_seq (STEP4-E2E inc 3a): a tens_cmd_t drives the
MMIO start-sequence into the real Tensor top — **ten** register writes ending in
the CTRL start pulse, then a wait for tile_done and a PE completion (ctx/tag).

[3a-3 2026-08-04] 写次数 9 -> 10：0x08 (SPARSE) 写插在 A_KTOTAL 之后（step 2），
start 顺延为 step 9 = 新 LAST_STEP。规格 §5.1 + §5.1b 订正框。
  🔴 原 docstring 与 :61 写的 "eight / 8-write" **在插步之前就已经是错的**
     （LAST_STEP=4'd8 ⇒ step 0..8 ⇒ 9 写）。本次一并订正。

**两臂，缺一不可**（B1 裁决，用户 2026-08-04 拍板）：
  · test_tensor_cmd_mmio_seq          —— n_cfg 非 0（NCFG_2OF4），钉死 0x08 的**数据段**
  · test_tensor_cmd_mmio_seq_n_cfg0   —— n_cfg = 0（dense），钉死派生 exec 也必须是 0
  单有非 0 臂，"exec 被硬写成常量" 的 bug 通不过检查；单有 0 臂，
  则 tb 漏接 cmd.n_cfg / python 不驱 / 驱 0 三种失效形态**全部产出 data==0 而过闸**
  （tb_tensor_cmd_mmio_seq.sv 的 `cmd = '0;` 兜底）—— 那正是本用例要防的
  「只验地址不验数据」。

🔴 本 toplevel 的源清单里**没有** tensor_tile_controller ⇒ 3a-3 落在那里的
   n_cfg $fatal 绊线不在本编译单元内 ⇒ 非 0 臂在此不会中止仿真。

Sampled on the FALLING edge (stable mid-cycle) to avoid rising-edge resume races.

Run: cd tb && make MODULE=test_tensor_cmd_mmio_seq TOPLEVEL=tb_tensor_cmd_mmio_seq \
        VERILOG_SOURCES="../rtl/IBEX_SRAM/pe_pkg.sv ../rtl/Tensor/tensor_pkg.sv \
        ../rtl/IBEX_SRAM/tensor_cmd_mmio_seq.sv ../tb/tb_tensor_cmd_mmio_seq.sv"
"""
import tbreset
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge

A_KTOTAL, A_SPARSE, A_OUTCTRL, A_EPOCH = 0x04, 0x08, 0x0C, 0x10
A_WGT, A_ACT, A_SCL, A_RES, A_CTRL = 0x14, 0x18, 0x1C, 0x20, 0x00

# tensor_pkg::ncfg_e —— 唯一权威在 Tensor/tensor_pkg.sv（规格 §5.1a 编码表）。
# 🔴 这里写符号不写字面量：expected 一旦硬编码成 0x9，编码若改本用例会变成
#    "证明了一个过时的常量"。
# ▲[3a-4/M2 2026-08-06 订正] 原文括注「~~可改窗口 = 3a-5 之前~~」已被规格 §5.1a-bis
#    逐字作废（M=8 的拦路者是元数据宽度不是码位；`ncfg_survivors()` 是 SV 侧唯一 N 来源
#    ⇒ 改编码永远只是「改一个函数 + 重跑稀疏金标」）。**写符号不写字面量这条纪律本身不变。**
NCFG_DENSE, NCFG_1OF4, NCFG_2OF4, NCFG_RESERVED = 0b00, 0b01, 0b10, 0b11
# tensor_pkg::exec_sparse_mode_e
EXEC_DENSE, EXEC_SPARSE_STRUCT = 0b00, 0b01

DRIVEN_INPUTS = ("cmd_valid_i", "param_K_i", "scale_epoch_i", "src_row_i",
                 "dst_row_i", "ctx_id_i", "tag_i", "n_cfg_i", "tile_done_i")


async def reset(dut):
    for sig in DRIVEN_INPUTS:
        getattr(dut, sig).value = 0
    dut.rst_ni.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk_i)
    dut.rst_ni.value = 1
    await FallingEdge(dut.clk_i)


def _expected(K, EPOCH, SRC, DST, MODE_BF16, n_cfg):
    """10 元 (addr, data) 精确序列。0x08 那一元用**符号表达式**钉两段位域。"""
    derived_exec = EXEC_DENSE if n_cfg == NCFG_DENSE else EXEC_SPARSE_STRUCT
    return [
        (A_CTRL,    MODE_BF16 << 4),         # mode pre-set (BF16), bit[0]=0, FIRST (§9.8 F2)
        (A_KTOTAL,  K),
        # [3a-3] 0x08 = {n_cfg[3:2], exec[1:0]}；bit4(scu_en, D-SCU-RESERVED) 与
        #        [31:5] 必须是 0。exec 由 n_cfg 派生（规格 §5.2「n_cfg 为唯一权威」）。
        (A_SPARSE,  (n_cfg << 2) | derived_exec),
        (A_OUTCTRL, 0),                      # out_class=OUT_FWD_VEC_NATIVE(0), out_fmt=BF16(0)
        (A_EPOCH,   EPOCH),
        (A_WGT,     SRC),
        (A_ACT,     SRC),
        (A_SCL,     0),
        (A_RES,     DST),
        (A_CTRL,    (MODE_BF16 << 4) | 1),   # start pulse + mode, bit[0]=1, LAST
    ]


async def _run_seq(dut, n_cfg, tag_name):
    await tbreset.preclock_reset(dut, rst="rst_ni")  # [批5 X-prop] 起时钟前复位已确定
    cocotb.start_soon(Clock(dut.clk_i, 10, "ns").start())
    await reset(dut)
    fails = []

    K, EPOCH, SRC, DST, CTX, TAG = 64, 0xA5, 0x12, 0x34, 2, 3
    MODE_BF16 = 4
    expected = _expected(K, EPOCH, SRC, DST, MODE_BF16, n_cfg)

    dut.param_K_i.value = K
    dut.scale_epoch_i.value = EPOCH
    dut.src_row_i.value = SRC
    dut.dst_row_i.value = DST
    dut.ctx_id_i.value = CTX
    dut.tag_i.value = TAG
    dut.n_cfg_i.value = n_cfg
    dut.cmd_valid_i.value = 1

    # capture the 10-write MMIO stream; drop cmd_valid once the FSM is busy
    seq, dropped = [], False
    for _ in range(40):
        await FallingEdge(dut.clk_i)
        if int(dut.busy_o.value) == 1 and not dropped:
            dut.cmd_valid_i.value = 0
            dropped = True
        if int(dut.mmio_wr_valid_o.value) == 1:
            seq.append((int(dut.mmio_wr_addr_o.value), int(dut.mmio_wr_data_o.value)))
        if len(seq) == len(expected):
            break
    if seq != expected:
        fails.append("MMIO sequence mismatch:\n   got=%s\n   exp=%s" %
                     ([(hex(a), d) for a, d in seq], [(hex(a), d) for a, d in expected]))

    # no further writes after the start pulse
    await FallingEdge(dut.clk_i)
    if int(dut.mmio_wr_valid_o.value) == 1:
        fails.append("extra MMIO write after start pulse")
    if int(dut.busy_o.value) != 1:
        fails.append("FSM not busy while awaiting tile_done")

    # complete the tile -> PE done pulse with the command's ctx/tag
    dut.tile_done_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.tile_done_i.value = 0
    got_done = False
    for _ in range(4):
        await FallingEdge(dut.clk_i)
        if int(dut.done_o.value) == 1:
            got_done = True
            if int(dut.done_ctx_o.value) != CTX:
                fails.append("done_ctx=%d exp=%d" % (int(dut.done_ctx_o.value), CTX))
            if int(dut.done_tag_o.value) != TAG:
                fails.append("done_tag=%d exp=%d" % (int(dut.done_tag_o.value), TAG))
            break
    if not got_done:
        fails.append("done_o never pulsed after tile_done")

    # returns to IDLE (ready) within a couple cycles
    ready = False
    for _ in range(4):
        await FallingEdge(dut.clk_i)
        if int(dut.cmd_ready_o.value) == 1:
            ready = True
            break
    if not ready:
        fails.append("did not return to IDLE (cmd_ready) after done")

    assert not fails, "tensor_cmd_mmio_seq[%s] failures (%d):\n  %s" % (
        tag_name, len(fails), "\n  ".join(fails))
    dut._log.info("tensor_cmd_mmio_seq[%s]: 10-write MMIO start sequence + done all correct"
                  % tag_name)


@cocotb.test()
async def test_tensor_cmd_mmio_seq(dut):
    """非 0 臂：n_cfg=NCFG_2OF4 ⇒ 0x08 数据段必须是 (0b10<<2)|0b01。

    这一臂是「数据段真被验了」的唯一证据。红臂 = 注释掉
    tb_tensor_cmd_mmio_seq.sv 的 `cmd.n_cfg = n_cfg_i;` ⇒ 本臂必须报
    MMIO sequence mismatch（0 臂不会红 —— 那正是单臂不够的原因）。
    """
    await _run_seq(dut, NCFG_2OF4, "n_cfg=2of4")


@cocotb.test()
async def test_tensor_cmd_mmio_seq_n_cfg0(dut):
    """dense 臂：n_cfg=NCFG_DENSE ⇒ 派生 exec 也必须是 EXEC_DENSE，0x08 数据 = 0。

    单有非 0 臂时，「exec 被硬写成常量 EXEC_SPARSE_STRUCT」会通不过任何检查。
    本臂还顺带证明：dense 编程路径在插步之后 0x08 写的是 0，
    与 R1 的 8 个 dense case（走直写、根本不写 0x08）语义一致。
    """
    await _run_seq(dut, NCFG_DENSE, "n_cfg=dense")

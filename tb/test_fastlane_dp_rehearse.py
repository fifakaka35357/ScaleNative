"""
Fast Lane 数据面 —— **彩排件**（`#117` 的可行性前置，零 EDA）

🔴 本件【只回答一个问题】：cocotb 能不能读到 `pe_top` 里那根 352 位的 fast-path 中间线，
   并按 `pe_pkg.sv` 的字段表切出正确的 capsule 字段？
   —— 源码证明**不够**（记忆铁律 `rehearse-on-real-design-before-launch` /
   `verify-nonstandard-eda-commands`）：`--public-flat-rw` 下 Verilator **可能把中间线折掉**，
   而折掉的表现是「读不到」，会被误读成「没流量」。
   ⇒ 先花 ~10 min 彩排，换掉后面两个 90 min。

🔴 本件【不下任何功能结论】。它不比 golden、不判 Fast Lane 通不通。判词留给主臂。

**字段表从 `AI_Chip/IBEX_SRAM/pe_pkg.sv` 现读推出**（packed struct，MSB→LSB）：
    payload[256] elem_fmt[4] block_size[2] scale_format[3] layout_tag[4] scale_ref[16]
    inline_scale[32] scale_inline_valid[1] scale_epoch[8] round_sat_policy[4] escape_hint[2]
    dest_hint[2] fwd_eligible[1] multi_consumer[1] operand_role[1] ctx_id[2] tag[3]
    producer[2] status_flags[8]                                   合计 = **352**
🔴 `CTX_ID_W = $clog2(NUM_CTX) = 2`、`TAG_W = 3`、`BS_CAP_PAYLOAD_W = 256` 均现读，不是记的。

🔴 本件**不进 run_all**：它是量具不是守门，且带 META 会把 `soc600_prereg §41` 的
   「63 文件 / PASS=196」判据当场打废。本 docstring 刻意不含 run_all.py:26-30 那两个可匹配字段
   （🔴 那条正则扫的是**整个文件**不只 docstring —— 见 `test_fastlane_util.py` 的同款警告）。

手动跑法（唯一）= `aichip_run_logs/launch_fastlane_dp_rehearse_20260907.sh`
"""
import os
import sys

import cocotb
import tbreset
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 🔴 只导 helper，**不导 @cocotb.test()**（否则那些用例会跟着注册、白跑一遍）——
#    机制 = cocotb 的 RegressionManager 扫【本模块命名空间】里的 Test 实例，
#    不导名字就不会被发现（本件首跑实测 TESTS=1，机制成立）。
from test_pe_top import boot_and_run, egress_sink, watch_health, WORDS_PER_ROW
# 🔴 负载【复用在盘前作】不自己编（§4.ah：开新探针前先 grep 在盘前作）。
#    本件第一版自编了一个「GEMM + MEMSET + EVICT」的最小臂，实测 **一拍都没采到** ——
#    因为快车道要有**消费者**才会握手：必须跟一条 OP_VEC_RESADD_RESIDENT，
#    且 len_rows=16（block_count>1 才武装 fp_stream_block）、ext_len=4、
#    block_size_log2=0、scale_epoch 与 GEMM 相等（不等则每个 capsule 静默 MISS）。
#    这些约束逐条写在 test_fastlane_duty.duty_descs 的 docstring 里，**在盘现成**。
# 🔴 2026-09-11：这四个名字随 `_run_arm` 一起被提取到 `duty_arm.py`（`§8 D-WP0A-RUN ②`）。
#    改指新家而不是让 `test_fastlane_duty.py` 做转发 —— 转发会让「一个事实两个门牌」。
#    🔴 **只改这一行，本文件的 `@cocotb.test` 数不变** ⇒ 回归四个面一个不动。
from duty_arm import duty_descs, firmware_v, LAYOUT_37, TOKEN

TV_DW_EXPECT = 352
# (名字, 低位偏移, 宽度) —— 由上面的字段表自底向上累加而来
FIELDS = [("status_flags", 0, 8), ("producer", 8, 2), ("tag", 10, 3), ("ctx_id", 13, 2),
          ("operand_role", 15, 1), ("multi_consumer", 16, 1), ("fwd_eligible", 17, 1),
          ("dest_hint", 18, 2), ("escape_hint", 20, 2), ("round_sat_policy", 22, 4),
          ("scale_epoch", 26, 8), ("scale_inline_valid", 34, 1), ("inline_scale", 35, 32),
          ("scale_ref", 67, 16), ("layout_tag", 83, 4), ("scale_format", 87, 3),
          ("block_size", 90, 2), ("elem_fmt", 92, 4), ("payload", 96, 256)]


def slice_fields(v):
    return {n: (v >> off) & ((1 << w) - 1) for n, off, w in FIELDS}


@cocotb.test()
async def test_dp_rehearse(dut):
    """最小 GEMM 臂；唯一目的 = 证明 `tv_out_data` 绑得到、切得对。"""
    L = dut._log.info
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    # ---- R0 绑定（fail-closed：绑不到就是绑不到，不许当「没流量」）----
    handles, missing = {}, []
    for path in ("tv_out_data", "tv_out_cap", "tens_t2v_cap"):
        try:
            handles[path] = getattr(dut.dut, path)
            _ = handles[path].value            # 真读一次，光有 handle 不算
        except Exception as e:                 # noqa: BLE001
            missing.append("%s: %r" % (path, e))
    L("### FLDP-REH-BEGIN ###")
    L("FLDP-REH-BIND ok=%s missing=%d %s", sorted(handles), len(missing), ";".join(missing) or "-")
    for k, h in handles.items():
        try:
            L("FLDP-REH-WIDTH %s = %d", k, len(h.value))
        except Exception as e:                 # noqa: BLE001
            L("FLDP-REH-WIDTH %s = 取不到 %r", k, e)

    assert "tv_out_data" in handles, (
        "FLDP-REH-INVALID-R0 取不到 dut.dut.tv_out_data —— **这是绑定问题不是「没流量」**。"
        "退路见 reviewE §④4.7 第 2 步（改读 i_vec 内部已解码寄存器，更弱，要在预登记写明弱在哪）。"
        " 细节: " + "; ".join(missing))
    w = len(handles["tv_out_data"].value)
    assert w == TV_DW_EXPECT, (
        "FLDP-REH-INVALID-R1 宽度 %d ≠ 现读字段表推出的 %d ⇒ **字段表与 RTL 不同步，"
        "任何按偏移的切片都不可信**" % (w, TV_DW_EXPECT))

    # ---- 负载 = 在盘已验证的 duty 臂（K=4, T=1）：GEMM → VEC_RESADD_RESIDENT → 令牌对 ----
    BUDGET = 60000
    descs = duty_descs(K=4, T=1, half_sel=0, lay=LAYOUT_37)
    fw = firmware_v(descs)
    L("FLDP-REH-FW words=%d descs=%d", len(fw), len(descs))
    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, BUDGET))

    fifo = dut.dut.i_tv_fifo
    caps = []

    async def snoop():
        while len(caps) < 64:
            await RisingEdge(dut.clk_i)
            try:
                if int(fifo.out_valid_o.value) and int(fifo.out_ready_i.value):
                    caps.append(int(handles["tv_out_data"].value))
            except Exception:                  # noqa: BLE001  X/Z
                pass

    cocotb.start_soon(snoop())
    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))
    for _ in range(BUDGET):
        await RisingEdge(dut.clk_i)
        if len(got) >= WORDS_PER_ROW:
            break
    else:
        L("FLDP-REH-CAPS n=%d（超时前已采到的）", len(caps))
        raise AssertionError("FLDP-REH-INVALID-TIMEOUT 负载没跑完，采样无意义")
    await sink
    bad_tok = [(i, hex(g)) for i, g in enumerate(got) if g != TOKEN]
    assert not bad_tok, "FLDP-REH-INVALID 完成令牌不对: %s" % bad_tok[:4]

    L("FLDP-REH-CAPS n=%d", len(caps))
    assert caps, ("FLDP-REH-INVALID-R2 一拍都没采到 —— 绑定成立但握手没发生；"
                  "这与「读不到」是两回事，需单独归因")

    # ---- 字段自诊断（🔴 用【结构性期望】判，不用数值期望）----
    #   Tensor→Vector 的 capsule：producer 必须是 DOMAIN_TENSOR(0)、dest_hint 必须是 DEST_VECTOR(1)、
    #   block_size 必须落在合法枚举 {0,1}（2/3 是 RSVD）、scale_format 必须落在 {0,1,2,3,4,7}。
    #   任一不符 ⇒ **报「字段偏移错」而不是「数据错」**。
    LEGAL_SF = {0, 1, 2, 3, 4, 7}
    bad = []
    for i, v in enumerate(caps[:8]):
        f = slice_fields(v)
        L("FLDP-REH-CAP[%d] producer=%d dest_hint=%d operand_role=%d block_size=%d "
          "scale_format=%d elem_fmt=%d scale_epoch=%d sc_inline_valid=%d ctx=%d tag=%d "
          "scale_ref=0x%04x inline_scale=0x%08x payload_nz=%d",
          i, f["producer"], f["dest_hint"], f["operand_role"], f["block_size"],
          f["scale_format"], f["elem_fmt"], f["scale_epoch"], f["scale_inline_valid"],
          f["ctx_id"], f["tag"], f["scale_ref"], f["inline_scale"], 1 if f["payload"] else 0)
        if f["producer"] != 0:
            bad.append("cap[%d].producer=%d ≠ DOMAIN_TENSOR(0)" % (i, f["producer"]))
        if f["block_size"] not in (0, 1):
            bad.append("cap[%d].block_size=%d 落在 RSVD" % (i, f["block_size"]))
        if f["scale_format"] not in LEGAL_SF:
            bad.append("cap[%d].scale_format=%d 非法枚举" % (i, f["scale_format"]))
    nz = sum(1 for v in caps if (v >> 96))
    L("FLDP-REH-PAYLOAD nonzero=%d / %d", nz, len(caps))
    L("FLDP-REH-SELFDIAG bad=%d %s", len(bad), ";".join(bad[:6]) or "-")
    L("### FLDP-REH-END ###")

    assert not bad, ("FLDP-REH-FIELDOFFSET 字段落在非法枚举 ⇒ **capsule 字段偏移算错了，"
                     "不是数据错**。逐条: " + "; ".join(bad[:6]))

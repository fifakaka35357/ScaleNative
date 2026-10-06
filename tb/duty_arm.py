"""
Fast Lane (i_tv_fifo) **占空比** 实测 —— 预登记 aichip_run_logs/soc600_prereg_20260902.md §37

🔴 本件【只读采样】：不驱动任何 DUT 内部信号、不改 RTL、不改 test_pe_top.py。
   它与 test_fastlane_util.py（§36 的臂 A）的区别只有一个，但那是全部的区别：
   **它真的下了 Vector 命令。** 上一趟 Vector 从没被叫醒（N_out=0），
   于是「消费者忙」与「消费者从没就绪」逐字不可区分（§36.6.4，欠账 #105）。

🔴 本件【不进 run_all】—— 量具不是守门。
   run_all.py:26-30 要同时解析到两个字段才会构建；本 docstring 刻意不含它们的可匹配形态。
   手动跑法 = aichip_run_logs/launch_fastlane_duty_20260905.sh
   🔴 跑之前必须 rm -rf sim_build（§37.1-⑧：Vtop.mk 不依赖顶层名 ⇒ 会静默跑在错的模型上）。

消费者为什么必须是 OP_VEC_RESADD_RESIDENT(0x05) 而不是 OP_VEC_RESADD(0x04)：§37.1-③/④。
一句话：Tensor egress 把 operand_role 硬写成 OP_SRC0（tensor_unit_top.sv:928），
pe_top 又没有 tb 注入口 ⇒ 0x04 等不到 SRC1 ⇒ VST_ERROR，而 done_o 照样拉高、
err 口在 pe_top 没接 ⇒ CP 看到「成功」。那会得到一个日志全绿、数字是垃圾的结果。
"""

# ═══════════════════════════════════════════════════════════════════════════
# 🔴🔴 2026-09-11 提取自 `test_fastlane_duty.py` 的 1–656 行（`§8 D-WP0A-RUN-2026-09-11 ②`，用户拍板）。
#
# **为什么提取**：`wp0_min_probe.py`（`prereg §51`）要复用 `_run_arm`，而「复刻一份」会留
# ~58 行重复代码、违「一个事实一个家」；「只加 extra_probe= 形参」零重复但仍改在盘 test_*.py
# 且不解决重复的根。⇒ 用户明知代价仍选「提取到共享模块，两边都 import」。
#
# 🔴 **本模块【不带 test_ 前缀】** ⇒ `run_all.py` 的 `glob("test_*.py")` 结构上看不见它
#    ⇒ 回归的四个面（elaborate 靶 / test_*.py 数 / @cocotb.test 数 / 运行面）**一个不动**。
#
# 🔴 **提取前后必须逐位相同**（硬闸 `G-EXTRACT`）：重跑 duty 全 8 臂，每臂的
#    `P_tile` / `C_med` / `Θ_D` 与基线逐位比对；任一不同 ⇒ **回滚，不许留在盘上**。
#    基线 = `aichip_run_logs/fastlane_duty_L0_20260911.log`（**不是 09-05 那份** ——
#    它拍摄于 S4 第一刀 `d151d8d` 之前；实测两者逐位相同，但基线仍取 L0 以隔离变量）。
#    判决器 = `aichip_run_logs/g_extract_gate.py`（自测 18/18）。
#
# 🔴 本文件**内容逐字等于原 1–656 行**（除本注释块）—— 提取是纯搬运，不做任何清理。
# ═══════════════════════════════════════════════════════════════════════════
import os
import sys

import cocotb
import tbreset
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rv32_asm import assemble
from test_pe_top import (boot_and_run, egress_sink, watch_health, WORDS_PER_ROW,
                         L1D_BASE, MMIO_BASE, SLOT_BYTES,
                         CP_CTRL, CP_STATUS, CTX0_RING_BASE, CTX0_RING_CFG,
                         CTX0_DOORBELL, REGION0_BASE, REGION0_NUM,
                         CTX_DONE, CTX_ERROR)

# ── 描述符 opcode（pe_pkg.sv:252-283）──
OP_VEC_RESADD_RESIDENT = 0x05
OP_TENS_GEMM           = 0x10
OP_DMA_EVICT           = 0x21
OP_DMA_MEMSET          = 0x22
ELEM_BF16 = 0

WD_THRESHOLD = 0xB8      # cp_csr.sv:6'h2E —— 复位 0xFFFF，本件调小让楔死快点现形
RING_CFG_4   = 4         # cp_csr.sv clamp_ring_cfg 上限 = RING_PTR_W = 4 ⇒ 16 槽

# ── L2 行布局（L2_TOTAL_ROWS=512，pe_pkg.sv:72）──
T_SRC       = 0          # GEMM 读 src..src+2K
TOKEN_ROW   = 400
REGION_ROWS = 512
TOKEN       = 0x600D_600D

# 🔴 行图【参数化】（§38.2 `D-19`）：§37 的三臂（T=3, K≤24）必须逐位复现当回归控
#    ⇒ 它们继续用 LAYOUT_37；ARM D（T=6, K≤48）的行段会撞，另给 LAYOUT_38。
#    撞的两处：K=48 时 GEMM 读到行 2K=96 > T_DST(64)；T=6 时 OUT 段吃到 351 > SIDECAR(320)。
LAYOUT_37 = dict(T_DST=64,  RESID_BASE=128, OUT_BASE=256, SIDECAR_ROW=320)
# 🔴 T_DST 取 176 而不是 112：112 只够 K≤55，于是 K>55 时【行图断言先响】，
#    安全界 K_MAX_DUAL(80) 就永远轮不到 —— 又一个够不着的分支（本片同族第八次，
#    彩排的反控当场抓到）。176 让 K≤85 的 GEMM 跨度 [0,2K+1) 都不撞，
#    ⇒ K_MAX_DUAL 成为【真正】的绑定判据，而不是一条摆设。
LAYOUT_38 = dict(T_DST=176, RESID_BASE=192, OUT_BASE=288, SIDECAR_ROW=384)


def check_layout(lay, K, T):
    """构造期断言各行段不相交。🔴 region 只查【起始行】，base+len 不查 ⇒ 这是软件纪律。"""
    segs = [("GEMM_src", 0, 2 * K + 1),
            ("T_DST",    lay["T_DST"], 1),
            ("RESID",    lay["RESID_BASE"], 16 * T),
            ("OUT",      lay["OUT_BASE"], 16 * T),
            ("SIDECAR",  lay["SIDECAR_ROW"], 1),
            ("TOKEN",    TOKEN_ROW, 1)]
    for i, (n1, a1, l1) in enumerate(segs):
        assert a1 + l1 <= REGION_ROWS, f"{n1} 段越过 L2 的 {REGION_ROWS} 行"
        for n2, a2, l2 in segs[i + 1:]:
            assert a1 + l1 <= a2 or a2 + l2 <= a1, \
                f"行段相交: {n1}[{a1},{a1+l1}) vs {n2}[{a2},{a2+l2})  (K={K} T={T})"
    return lay

CAPS_PER_TILE = 16       # tensor_egress_fragmentizer.sv:151 ROWS=16 —— 结构常量，与 M/N/K 无关


def build_desc_v(opcode, src_off=0, dst_off=0, len_rows=1, outer_count=0,
                 stride_rows=0, memset_val=0, ctx=0, ext_len=4,
                 src_rid=0, dst_rid=0, elem_fmt=0, param_m=0, param_n=0, param_k=0,
                 block_size_log2=0, half_sel=0, scale_rid=0, scale_epoch=0,
                 src1_resident=0, scale_row_off=0, src1_scale_ref=0):
    """完整的 8 字描述符构造器。

    🔴 为什么不能用 test_pe_top.build_desc：它只写 w[6]=elem_fmt&0xF、w[7]=0
       （test_pe_top.py:128-129），而 Vector 描述符要的
       src1_resident(w6[28]) / scale_epoch(w6[27:20]) / scale_rid(w6[19:16]) /
       scale_row_off(w7[15:0]) 全部够不着。字段布局 = pe_pkg.sv extract_tile_contract。
       🔴 test_pe_top.py 是 run_all 守门，不许改（§36.1）⇒ 只能在这里另写一个。
    """
    w = [0] * 8
    w[0] = (opcode & 0xFF) | ((ext_len & 0xF) << 8) | ((ctx & 0x3) << 12)
    w[1] = (src_off & 0xFFFF) | ((src_rid & 0xF) << 24)
    w[2] = (dst_off & 0xFFFF) | ((dst_rid & 0xF) << 24)
    w[3] = (len_rows & 0xFFFF) | ((stride_rows & 0xFFFF) << 16)
    if opcode == OP_TENS_GEMM:
        w[4] = (param_m & 0xFFFF) | ((param_n & 0xFFFF) << 16)
        w[5] = param_k & 0xFFFF
    else:
        w[4] = outer_count & 0xFFFF
        w[5] = memset_val & 0xFFFFFFFF
    w[6] = ((elem_fmt & 0xF)
            | ((block_size_log2 & 0x3) << 4)
            | ((half_sel & 0x1) << 9)
            | ((scale_rid & 0xF) << 16)
            | ((scale_epoch & 0xFF) << 20)
            | ((src1_resident & 0x1) << 28))
    w[7] = (scale_row_off & 0xFFFF) | ((src1_scale_ref & 0xFFFF) << 16)
    return w


def duty_descs(K, T, half_sel=0, lay=None):
    """§37.2.1 的描述符表：[GEMM_i, VEC_i] × T + MEMSET + EVICT（ctx0 单环）。

    🔴 顺序是 GEMM 在前、交替（§37.1-⑤）：
       · GEMM 在它的 16 行 egress 扫描【排干之前】就报 done ⇒ VEC_i 才 issue 得了；
       · 两个 GEMM 背靠背会在 ST_DRAIN 上等 snapshot_bank_available，而放开那个 bank
         要靠排在它【后面】的 VEC ⇒ 环死。交替顺序结构上排除它。
    🔴 VEC 的 len_rows 必须 = 16 且 > 1：
       block_count = len_rows（vec_cmd_to_desc.sv:183-184）⇒ 一条描述符吃掉一趟 GEMM 的 16 个 capsule；
       且 block_count>1 才武装 fp_stream_block（vector_unit.sv:707-711），
       否则快车道在 WAIT_OP1 还开着 ⇒ 多吸一个 OP_SRC0 ⇒ VERR_ROLE_MISORDER，静默死。
    🔴 epoch 两侧必须相等（都取 0）：vec_ingress_arb.sv:121 逐字段精确匹配，
       不等则每个 capsule 都 MISS，而 MISS 是【静默背压】，与「慢」逐字不可区分。
    """
    lay = check_layout(lay or LAYOUT_37, K, T)
    d = []
    for i in range(T):
        d.append(build_desc_v(OP_TENS_GEMM, src_off=T_SRC, dst_off=lay["T_DST"], len_rows=1,
                              param_m=16, param_n=16, param_k=K,
                              elem_fmt=ELEM_BF16, scale_epoch=0, ext_len=4))
        d.append(build_desc_v(OP_VEC_RESADD_RESIDENT,
                              src_off=lay["RESID_BASE"] + i * 16,
                              dst_off=lay["OUT_BASE"] + i * 16,
                              len_rows=CAPS_PER_TILE,          # ← block_count = 16
                              ext_len=4,                        # min_ext_for_opcode(0x05)=4
                              block_size_log2=0,                # BS_16 ⇒ 配 packer 的 BLOCK_SIZE_16
                              half_sel=half_sel,                # L2 半条带选择（正控臂翻成 1）
                              scale_epoch=0,                    # ← 必须等于 GEMM 的
                              src1_resident=1,
                              scale_row_off=lay["SIDECAR_ROW"]))
    d.append(build_desc_v(OP_DMA_MEMSET, dst_off=TOKEN_ROW, len_rows=1, memset_val=TOKEN))
    d.append(build_desc_v(OP_DMA_EVICT,  src_off=TOKEN_ROW, len_rows=1))
    return d


def firmware_v(descs):
    """自带的固件生成器（不改 test_pe_top.firmware_src）。

    与它的差别只有三处，每处都有理由：
      ① RING_CFG = 4（16 槽）而不是 3（8 槽）—— 本负载要 8 条描述符，
         而 doorbell 只取 wdata[3:0] 再与 ring_mask 相与（cp_csr.sv:6'h06），
         cfg=3 时 mask=0x7 ⇒ tail=8 会被掩成 0 == head ⇒ 环判空、什么都不跑、**且不置 warn 位**。
      ② 写 WD_THRESHOLD（0xB8）—— 复位是 0xFFFF；调小让「楔死」在 4096 拍内现形，
         而不是 65535 拍后才变成 CTX_ERROR（§37.1-⑤）。
      ③ region0 num_rows = 512 —— 覆盖 GEMM 的 src..src+2K、RESID、OUT、SIDECAR、TOKEN。
         🔴 region 只检查【起始行】（cp_scheduler.sv 的 region_oob），base+len 不检查 ⇒
            上面的行布局是【软件纪律】，不是硬件保证。
    """
    n = len(descs)
    assert n <= 15, f"一次 doorbell 最多 15 条（tail==head 判空），给了 {n}"
    s = [f"    li   s0, {hex(L1D_BASE)}",
         f"    li   s1, {hex(MMIO_BASE)}"]
    for k in range(n):
        for i, word in enumerate(descs[k]):
            off = k * SLOT_BYTES + i * 4
            assert off < 2048, "sw 的 12 位有符号立即数够不着"
            if word == 0:
                s.append(f"    sw   zero, {off}(s0)")
            else:
                s.append(f"    li   t0, {hex(word)}")
                s.append(f"    sw   t0, {off}(s0)")
    s.append(f"    sw   zero, {REGION0_BASE}(s1)")
    s.append(f"    li   t0, {REGION_ROWS}")
    s.append(f"    sw   t0, {REGION0_NUM}(s1)")
    s.append(f"    li   t0, 4096")                       # ② watchdog
    s.append(f"    sw   t0, {WD_THRESHOLD}(s1)")
    s.append(f"    sw   zero, {CTX0_RING_BASE}(s1)")     # ring 基址 = L1D 偏移 0
    s.append(f"    li   t0, {RING_CFG_4}")               # ① 16 槽
    s.append(f"    sw   t0, {CTX0_RING_CFG}(s1)")
    s.append(f"    li   t0, 1")                          # enable 在 doorbell 之前
    s.append(f"    sw   t0, {CP_CTRL}(s1)")
    s.append(f"    li   t0, {n}")                        # doorbell = 绝对 tail
    s.append(f"    sw   t0, {CTX0_DOORBELL}(s1)")
    s.append("poll:")
    s.append(f"    lw   t1, {CP_STATUS}(s1)")
    s.append( "    andi t1, t1, 0xF")
    s.append(f"    li   t2, {CTX_ERROR}")
    s.append( "    beq  t1, t2, err")
    s.append(f"    li   t2, {CTX_DONE}")
    s.append( "    bne  t1, t2, poll")
    s.append("done:")
    s.append( "    j    done")
    s.append("err:")
    s.append( "    j    err")
    return assemble("\n".join(s), base=0x80)


# ═══════════════ ARM D：双 ctx 重叠臂（预登记 soc600_prereg §38）═══════════════
CTX1_RING_BASE = 0x20    # cp_csr.sv:434 (6'h08)
CTX1_RING_CFG  = 0x24    # cp_csr.sv:435 (6'h09)
CTX1_DOORBELL  = 0x28    # cp_csr.sv:443 (6'h0A)；doorbell_wr[1] 独立译码在 :606
RING0_OFF      = 0x000   # 16 槽 × 32B ⇒ [0x000,0x1FF]
RING1_OFF      = 0x200   # 16 槽 × 32B ⇒ [0x200,0x3FF]；32B 对齐、不相交、在 [11:0] 内
K_MAX_DUAL     = 80      # §38.1-④ 硬界 85（VEC_0 等整个首个生产周期，11K+81>1022 ⇒ K≥86 静默死）


def duty_descs_dual(K, T, lay=None):
    """ARM D 的两个环。

    🔴 §38.1-③：描述符里的 `ctx` 字段是【装饰性】的 —— `cp_scheduler.sv:573/604` 取的是
       环号 `sel_ctx`，`w0[13:12]` 在这条路径上不被读。
       ⇒ **只改描述符 ctx 而不另开环，会逐位退化成 ARM C，而且是静默的。**
       真正让它变成双 ctx 的是 CTX1_RING_BASE/CFG/DOORBELL 这三个 CSR。
    🔴 令牌必须在 **ring1 尾部**（§38.2 `D-10`）：`ttc:896` 的 done 与 `:917` 的 capture_done
       同拍 ⇒ 令牌放 ring0 会在最后一趟 tile 的 capsule 一个都没进 FIFO 时就到 NoC。
    """
    # 🔴 安全界先判：它是 ARM D 特有的（VEC_0 要等整个首个生产周期），
    #    行图相交只是次生后果 ⇒ 先判它，报错才指向真因。
    assert K <= K_MAX_DUAL, (
        f"K={K} 越过 ARM D 的安全界 {K_MAX_DUAL}（§38.1-④：11K+81>1022 ⇒ K≥86 静默 VST_ERROR）")
    lay = check_layout(lay or LAYOUT_38, K, T)
    r0 = [build_desc_v(OP_TENS_GEMM, src_off=T_SRC, dst_off=lay["T_DST"], len_rows=1,
                       param_m=16, param_n=16, param_k=K,
                       elem_fmt=ELEM_BF16, scale_epoch=0, ext_len=4) for _ in range(T)]
    r1 = [build_desc_v(OP_VEC_RESADD_RESIDENT,
                       src_off=lay["RESID_BASE"] + i * 16,
                       dst_off=lay["OUT_BASE"] + i * 16,
                       len_rows=CAPS_PER_TILE, ext_len=4, block_size_log2=0,
                       scale_epoch=0, src1_resident=1,
                       scale_row_off=lay["SIDECAR_ROW"]) for i in range(T)]
    r1.append(build_desc_v(OP_DMA_MEMSET, dst_off=TOKEN_ROW, len_rows=1, memset_val=TOKEN))
    r1.append(build_desc_v(OP_DMA_EVICT,  src_off=TOKEN_ROW, len_rows=1))
    # 🔴 §38.2.1 不变式，构造期这一半（运行期那一半是闸 V5d/V5/V4b/V4）
    assert len(r1) - 2 == len(r0), "V != G：条数失配的三种形态【全部是静默的】"
    return r0, r1


def firmware_v2(r0, r1):
    """双环固件。与 firmware_v 的差别只有三处，每处都有理由：

    ① 编【两个】环的 base/cfg（ctx1 在 0x20/0x24）。`CP_CTRL.enable` 是**全局**一位
       （`cp_csr.sv:200,400,874`）⇒ 只写一次。
    ② 敲【两次】门铃。🔴 顺序 = ring0(GEMM) 先、ring1(VEC) 后 ——
       生产侧**没有任何超时**（fragmentizer 一直举 frag_valid、FIFO 填到 5），
       消费侧有 `op_wait_cnt >= 1023` 的静默死 ⇒ **迟到免费、早到致命**。
    ③ 轮询【两个】nibble：ctx0 在 CP_STATUS[3:0]、ctx1 在 [7:4]（`cp_csr.sv:679-683`）。
       任一 ctx 进 CTX_ERROR(7) 即跳 err，**不许只看 ctx0**（§38 风险 D-4）。
    """
    n0, n1 = len(r0), len(r1)
    assert n0 <= 15 and n1 <= 15, "一次 doorbell 最多 15 条（tail==head 判空）"
    assert RING0_OFF % 32 == 0 and RING1_OFF % 32 == 0
    assert RING0_OFF + 16 * 32 <= RING1_OFF, "两环重叠"
    assert RING1_OFF + 16 * 32 <= 4096, "ring1 越过 L1D"
    s = [f"    li   s0, {hex(L1D_BASE)}", f"    li   s1, {hex(MMIO_BASE)}"]
    for base, ring in ((RING0_OFF, r0), (RING1_OFF, r1)):
        for k, desc in enumerate(ring):
            for i, word in enumerate(desc):
                off = base + k * SLOT_BYTES + i * 4
                assert off < 2048, "sw 的 12 位有符号立即数够不着"
                if word == 0:
                    s.append(f"    sw   zero, {off}(s0)")
                else:
                    s.append(f"    li   t0, {hex(word)}")
                    s.append(f"    sw   t0, {off}(s0)")
    s.append(f"    sw   zero, {REGION0_BASE}(s1)")
    s.append(f"    li   t0, {REGION_ROWS}")
    s.append(f"    sw   t0, {REGION0_NUM}(s1)")
    # 🔴 §38.1-⑤：CP 看门狗【不是】ARM D 的守门（wd_progress 含 done_vec，而 VST_ERROR
    #    也拉 done_o ⇒ 消费者一饿死反而把 wd_cnt 清零）。仍写 4096，只为兜 ctx0 的真楔死。
    s.append(f"    li   t0, 4096")
    s.append(f"    sw   t0, {WD_THRESHOLD}(s1)")
    s.append(f"    li   t0, {RING0_OFF}")
    s.append(f"    sw   t0, {CTX0_RING_BASE}(s1)")
    s.append(f"    li   t0, {RING_CFG_4}")
    s.append(f"    sw   t0, {CTX0_RING_CFG}(s1)")
    s.append(f"    li   t0, {RING1_OFF}")
    s.append(f"    sw   t0, {CTX1_RING_BASE}(s1)")
    s.append(f"    li   t0, {RING_CFG_4}")
    s.append(f"    sw   t0, {CTX1_RING_CFG}(s1)")
    s.append(f"    li   t0, 1")                       # enable 全局，且在门铃之前
    s.append(f"    sw   t0, {CP_CTRL}(s1)")
    s.append(f"    li   t0, {n0}")                    # ② ring0 先
    s.append(f"    sw   t0, {CTX0_DOORBELL}(s1)")
    s.append(f"    li   t0, {n1}")                    #    ring1 后
    s.append(f"    sw   t0, {CTX1_DOORBELL}(s1)")
    # ③ 轮询两个 nibble
    s.append("poll:")
    s.append(f"    lw   t1, {CP_STATUS}(s1)")
    s.append( "    andi t3, t1, 0xF")                 # ctx0
    s.append( "    srli t4, t1, 4")
    s.append( "    andi t4, t4, 0xF")                 # ctx1
    s.append(f"    li   t2, {CTX_ERROR}")
    s.append( "    beq  t3, t2, err")
    s.append( "    beq  t4, t2, err")
    s.append(f"    li   t2, {CTX_DONE}")
    s.append( "    bne  t3, t2, poll")
    s.append( "    bne  t4, t2, poll")
    s.append("done:")
    s.append( "    j    done")
    s.append("err:")
    s.append( "    j    err")
    return assemble("\n".join(s), base=0x80)


# ── 采样面（§37.3）。层次根 = dut.dut = pe_top ────────────────────────────────
# 硬绑（缺一即 V0 INVALID）：这 8 根是 §36 臂 A 实跑过、确认可读的那一组。
FIFO_SIGS = ["in_valid_i", "in_ready_o", "out_valid_o", "out_ready_i", "fill_level_o"]
CORE_HARD = ["vec_clk_en", "tens_t2v_valid", "tens_t2v_escape"]

# 🔴 软绑（缺了【不】中止，但对应的闸判 UNCOVERED —— 绝不判绿）。
#    为什么分两组：`--public-flat-rw` 让信号 public，但 verilator 仍可能把
#    「在父层留空的输出口」折掉。源码证明它存在【不够】（§4.aq，本项目为此付过
#    `all_registers -clock_pins` 的 SIGSEGV）。硬绑它们 = 一次 7 分钟编译换一条报错；
#    软绑 = 同一次编译仍拿得到占空比，只是那几条闸诚实地判「没测到」。
CORE_SOFT = ["tv_out_ready", "vec_cmd_valid", "vec_cmd_ready",
             "tens_cmd_valid", "tens_cmd_ready", "tens_clk_en",
             # 🔴 ARM D 追加（§38.3）。完成侧计数与 cmd 侧（VC_iss）失效模式不相关；
             #    *_done_ctx 是「这一趟真的是双 ctx」的唯一执行者（§38.1-③ 的 D-1）。
             #    仍然【软绑】：源码证明存在不够（§4.aq），缺 ⇒ 对应闸 UNCOVERED。
             "vec_done", "vec_done_ctx", "tens_done", "tens_done_ctx",
             # 只报不判：量 RO 口争用（D-13）把 Q 抬高多少
             "vec_ro_req", "tens_ro_req"]
# 这四根在 pe_top 上【没接】（pe_top.sv:628-629 / :640-641 留空），只能层次读。
# 它们是闸 V1（Vector 静默出错）与 V3（契约不匹配的静默背压）的唯一执行者。
VEC_SOFT  = ["contract_violation_o", "err_code_o", "t2v_miss_valid_o", "t2v_miss_reason_o"]


class FlProbe2:
    """逐拍采样 Fast Lane 两端 + Vector 的错误/miss 旁路。**只读，不驱动。**"""

    def __init__(self, dut):
        self.dut = dut
        self.core = dut.dut
        self.missing = []          # 硬缺 ⇒ V0 INVALID
        self.missing_opt = []      # 软缺 ⇒ 对应闸判 UNCOVERED
        self.h = {}
        for s in FIFO_SIGS:
            self._bind("fifo." + s, lambda s=s: getattr(self.core.i_tv_fifo, s), s, True)
        for s in CORE_HARD:
            self._bind("pe_top." + s, lambda s=s: getattr(self.core, s), s, True)
        for s in CORE_SOFT:
            self._bind("pe_top." + s, lambda s=s: getattr(self.core, s), s, False)
        for s in VEC_SOFT:
            self._bind("i_vec." + s, lambda s=s: getattr(self.core.i_vec, s), s, False)
        self.reset_counters()

    def _bind(self, label, getter, key, hard):
        try:
            h = getter()
            int(h.value)                            # 🔴 绑得到 ≠ 读得动，当场读一次
            self.h[key] = h
        except Exception as e:                      # noqa: BLE001
            (self.missing if hard else self.missing_opt).append(f"{label}: {e!r}")

    def has(self, *keys):
        """某条闸的执行者是否齐全。缺 ⇒ 该闸 UNCOVERED，**不许判绿**。"""
        return all(k in self.h for k in keys)

    def reset_counters(self):
        self.N_cyc = 0
        self.N_in = self.N_out = 0
        self.S_prod = self.S_cons = 0
        self.R_qual = self.R_raw = self.G_cyc = 0
        self.VC_iss = self.TC_iss = 0
        # 🔴 §37.11.3：S_cons 结构恒 0（vec_ingress_arb.sv:145-152 + vec_fastpath_if.sv:171
        #    ⇒ out_ready 蕴含 out_valid），不携带信息。E_hungry 才是可达的饥饿计数器：
        #    「消费者手里有在飞描述符，而 FIFO 空着」。与 S_prod 失效模式不相关。
        self.E_hungry = 0
        self.vec_inflight = 0        # 未消费完的 beat 数（issue 时 +CAPS_PER_TILE）
        # ── ARM D 追加（§38.3）──
        self.E_run = self.E_hungry_runmax = 0
        self.tens_inflight = 0
        self.OVL_cmd = 0             # 重叠检测器 A：两边同时持有描述符的拍数
        self.vec_accept_cyc = []
        self.vec_done_cyc = []
        self.tens_done_cyc = []
        self.vd_prev = self.td_prev = 0
        self.vec_done_ctxs = set()   # 检测器 C：完成回执的 ctx 归属
        self.tens_done_ctxs = set()
        self.RO_both = self.RO_tens = self.RO_vec = 0
        self.P_off = self.D_esc = 0
        self.fill_sum = 0
        self.fill_max = 0
        self.x_cnt = 0                    # 🔴 X/Z 读数单独计，不许静默当 0
        self.verr_seen = 0
        self.verr_code = None
        self.miss_cnt = 0
        self.miss_reason = None
        self.first_tens_cyc = None        # 窗口 B 的起点
        self.tens_accept_cyc = []         # 每趟 GEMM 被接受的拍号
        self.beat_cyc = []                # 每个入口 beat 的拍号（算 P_tile / C 的原料）
        self.out_cyc = []
        self.first_ready_cyc = None

    def _v(self, name):
        sig = self.h.get(name)
        if sig is None:
            return 0
        try:
            return int(sig.value)
        except Exception:                  # noqa: BLE001  X/Z
            self.x_cnt += 1
            return 0

    async def run(self, max_cycles):
        while self.N_cyc < max_cycles:
            await RisingEdge(self.dut.clk_i)
            self.N_cyc += 1
            c = self.N_cyc
            iv, ir = self._v("in_valid_i"), self._v("in_ready_o")
            ov, orr = self._v("out_valid_o"), self._v("out_ready_i")
            fill = self._v("fill_level_o")
            gate = self._v("vec_clk_en")
            pv, pe = self._v("tens_t2v_valid"), self._v("tens_t2v_escape")
            rraw = self._v("tv_out_ready")
            vcv, vcr = self._v("vec_cmd_valid"), self._v("vec_cmd_ready")
            tcv, tcr = self._v("tens_cmd_valid"), self._v("tens_cmd_ready")
            tge = self._v("tens_clk_en")

            if iv and ir:
                self.N_in += 1
                self.beat_cyc.append(c)
            if ov and orr:
                self.N_out += 1
                self.out_cyc.append(c)
                if self.vec_inflight > 0:
                    self.vec_inflight -= 1
            if iv and not ir:
                self.S_prod += 1
            if orr and not ov:
                self.S_cons += 1
            if orr:
                self.R_qual += 1
                if self.first_ready_cyc is None:
                    self.first_ready_cyc = c
            if rraw:
                self.R_raw += 1
            if gate:
                self.G_cyc += 1
            # 🔴 §37.11.4：数 beat 不数拍。valid 在被背压时一直举着，
            #    Σ(valid) 会把「堵了 552 拍」读成「产了 600 个」。
            if pv and ir:
                self.P_off += 1
                if pe:
                    self.D_esc += 1
            # 🔴 CP 侧的握手要带各自的 clk_en（pe_top.sv:546,550 就是这么接进 CP 的）
            if vcv and vcr and gate:
                self.VC_iss += 1
                self.vec_inflight += CAPS_PER_TILE
                self.vec_accept_cyc.append(c)
            if tcv and tcr and tge:
                self.TC_iss += 1
                self.tens_inflight += 1
                self.tens_accept_cyc.append(c)
                if self.first_tens_cyc is None:
                    self.first_tens_cyc = c
            # 🔴 完成侧要【边沿】检测：done_o 在停钟时会保持，电平计数会多数
            vdq = 1 if (self._v("vec_done") and gate) else 0
            if vdq and not self.vd_prev:
                self.vec_done_cyc.append(c)
                self.vec_done_ctxs.add(self._v("vec_done_ctx"))
            self.vd_prev = vdq
            tdq = 1 if (self._v("tens_done") and tge) else 0
            if tdq and not self.td_prev:
                self.tens_done_cyc.append(c)
                self.tens_done_ctxs.add(self._v("tens_done_ctx"))
                if self.tens_inflight > 0:
                    self.tens_inflight -= 1
            self.td_prev = tdq
            # 重叠检测器 A：两边同时持有在飞描述符
            if self.tens_inflight > 0 and self.vec_inflight > 0:
                self.OVL_cmd += 1
            # RO 口争用（只报不判，D-13）
            vro, tro = self._v("vec_ro_req"), self._v("tens_ro_req")
            if vro: self.RO_vec += 1
            if tro: self.RO_tens += 1
            if vro and tro: self.RO_both += 1
            # 🔴 D-16：E_hungry 的测试必须在【所有 inflight 更新之后】。
            #    原来它在 out 分支里、位于 vec_inflight += 16 之前 ⇒ 受理那一拍永远是盲的。
            if self.vec_inflight > 0 and not ov:
                self.E_hungry += 1
                self.E_run += 1
                self.E_hungry_runmax = max(self.E_hungry_runmax, self.E_run)
            else:
                self.E_run = 0
            # 🔴 sticky：这两条一旦出现过就永远记着（它们是脉冲）
            if self._v("contract_violation_o"):
                self.verr_seen += 1
                if self.verr_code is None:
                    self.verr_code = self._v("err_code_o")
            if self._v("t2v_miss_valid_o"):
                self.miss_cnt += 1
                if self.miss_reason is None:
                    self.miss_reason = self._v("t2v_miss_reason_o")
            self.fill_sum += fill
            self.fill_max = max(self.fill_max, fill)

    # ── 派生量（游程与周期）──────────────────────────────────────────────────
    def runs(self):
        """入口 beat 的游程统计。🔴 和 ≠ 形状：只有游程能区分「突发后空转」与「均匀慢」。"""
        if not self.beat_cyc:
            return 0, 0, 0
        run_max = cur = 1
        gap_max = 0
        bursts = 1
        for a, b in zip(self.beat_cyc, self.beat_cyc[1:]):
            if b == a + 1:
                cur += 1
                run_max = max(run_max, cur)
            else:
                cur = 1
                bursts += 1
                gap_max = max(gap_max, b - a)
        return run_max, gap_max, bursts

    def interleave(self):
        """重叠检测器 B（§38.3）：对每个 tile j，问是否有 tens_accept 落在
        (vec_accept[j], out_cyc[16j+15]) 的【内部】。
        🔴 零新绑 —— 只用时间戳 ⇒ 与检测器 A（OVL_cmd）失效模式不相关。
        串行臂里 GEMM_{j+1} 排在 VEC_j 的 done 之后 ⇒ 结构恒 0（它自带负控）。"""
        n = 0
        for j, va in enumerate(self.vec_accept_cyc):
            k = 16 * j + 15
            if k >= len(self.out_cyc):
                break
            hi = self.out_cyc[k]
            if any(va < t < hi for t in self.tens_accept_cyc):
                n += 1
        return n

    def d_disp(self):
        """CP 交接延迟 d = tens_done -> 下一次 tens_accept。**本项目从未采样过**（§38.1-②）。"""
        out = []
        for td in self.tens_done_cyc:
            nxt = [t for t in self.tens_accept_cyc if t > td]
            if nxt:
                out.append(nxt[0] - td)
        return out

    def periods(self):
        """P_tile = 相邻两趟 GEMM 被接受的拍差；C = tile 内相邻 beat 间隔的中位数。"""
        p = [b - a for a, b in zip(self.tens_accept_cyc, self.tens_accept_cyc[1:])]
        gaps = sorted(b - a for a, b in zip(self.beat_cyc, self.beat_cyc[1:]) if 1 < b - a < 200)
        med = gaps[len(gaps) // 2] if gaps else None
        return p, med, len(gaps)

    def report(self, dut, tag, K, T):
        """机器可读输出。**判词留给 petop_fastlane_judge.py，本件不下结论。**"""
        L = dut._log.info
        run_max, gap_max, bursts = self.runs()
        p_tile, c_med, n_gap = self.periods()
        nb = self.N_cyc - (self.first_tens_cyc - 1) if self.first_tens_cyc else 0
        nc = (self.beat_cyc[-1] - self.beat_cyc[0] + 1) if len(self.beat_cyc) >= 2 else 0
        L("### FLDUTY-BEGIN %s ###", tag)
        L("FLDUTY-ARM tag=%s K=%d T=%d caps_expected=%d", tag, K, T, CAPS_PER_TILE * T)
        L("FLDUTY-MISSING %d %s", len(self.missing), ";".join(self.missing) or "-")
        L("FLDUTY-MISSOPT %d %s", len(self.missing_opt), ";".join(self.missing_opt) or "-")
        # 🔴 每条软闸的【执行者可用性】单独播报；判决器据此判 UNCOVERED 而不是绿
        L("FLDUTY-AVAIL verr=%d miss=%d denomB=%d vciss=%d rraw=%d",
          int(self.has("contract_violation_o", "err_code_o")),
          int(self.has("t2v_miss_valid_o")),
          int(self.has("tens_cmd_valid", "tens_cmd_ready", "tens_clk_en")),
          int(self.has("vec_cmd_valid", "vec_cmd_ready")),
          int(self.has("tv_out_ready")))
        L("FLDUTY-XCNT x_reads=%d", self.x_cnt)
        L("FLDUTY-CNT N_in=%d N_out=%d S_prod=%d S_cons=%d P_off=%d D_esc=%d E_hungry=%d",
          self.N_in, self.N_out, self.S_prod, self.S_cons, self.P_off, self.D_esc, self.E_hungry)
        # 🔴 S_cons 结构恒 0（§37.11.1 有证明），单独播报以免被读成信息
        L("FLDUTY-NOTE S_cons_is_structurally_zero=1 R_qual_eq_N_out=%d",
          int(self.R_qual == self.N_out))
        L("FLDUTY-BRIEF VC_iss=%d TC_iss=%d R_qual=%d R_raw=%d G_cyc=%d first_ready=%s",
          self.VC_iss, self.TC_iss, self.R_qual, self.R_raw, self.G_cyc, self.first_ready_cyc)
        L("FLDUTY-ERR verr_seen=%d verr_code=%s miss_cnt=%d miss_reason=%s",
          self.verr_seen, self.verr_code, self.miss_cnt, self.miss_reason)
        # 🔴 #108：每个比值都把分母写进键名
        L("FLDUTY-DENOM N_cyc_A_reset=%d N_cyc_B_postboot=%d N_cyc_C_burst=%d first_tens=%s",
          self.N_cyc, nb, nc, self.first_tens_cyc)
        L("FLDUTY-U U_A_reset=%.6f U_B_postboot=%.6f U_C_burst=%.6f",
          self.N_in / max(1, self.N_cyc), self.N_in / max(1, nb), self.N_in / max(1, nc))
        L("FLDUTY-SHAPE in_run_max=%d in_gap_max=%d n_bursts=%d fill_mean=%.4f fill_max=%d",
          run_max, gap_max, bursts, self.fill_sum / max(1, self.N_cyc), self.fill_max)
        L("FLDUTY-PERIOD P_tile=%s C_med=%s n_gap=%d", p_tile, c_med, n_gap)
        dd = self.d_disp()
        L("FLDUTY-OVL OVL_cmd=%d n_interleave=%d n_vec_done=%d n_tens_done=%d "
          "vec_done_ctxs=%s tens_done_ctxs=%s",
          self.OVL_cmd, self.interleave(), len(self.vec_done_cyc), len(self.tens_done_cyc),
          sorted(self.vec_done_ctxs) or "-", sorted(self.tens_done_ctxs) or "-")
        L("FLDUTY-DDISP d_disp=%s d_min=%s d_max=%s",
          dd, (min(dd) if dd else None), (max(dd) if dd else None))
        L("FLDUTY-RO RO_both=%d RO_tens=%d RO_vec=%d E_hungry_runmax=%d",
          self.RO_both, self.RO_tens, self.RO_vec, self.E_hungry_runmax)
        L("### FLDUTY-END %s ###", tag)


async def _run_arm(dut, tag, K, T, budget=60000, half_sel=0, dual=False, tail_cycles=64,
                   extra_probe=None):
    # 🔴 `extra_probe`（2026-09-11 加，`§8 D-WP0A-RUN-2026-09-11 ②`）：**默认 None**。
    #    给 `wp0_min_probe.py`（`prereg §51`）挂一个**只读**采样协程用。
    #    🔴 三条硬约束，缺一就会打破 `G-EXTRACT`：
    #    ① `None` 时**一个 `start_soon` 都不发** ⇒ 与提取前逐位相同（已实测 gx1a：128 行逐字同）；
    #    ② 它的 `start_soon` 排在既有 `probe.run` **之后** ⇒ 不改变既有协程的注册顺序；
    #    ③ 挂上之后仍须过 `G-EXTRACT-2`（真探针在跑的情况下再与 L0 逐位比一次）——
    #       「挂上探针以后结果还一样」是整条路最承重的假设，v3 对抗审查 `M4#7` 点名它没有闸。
    await tbreset.preclock_reset(dut, rst="rst_ni")
    cocotb.start_soon(Clock(dut.clk_i, 10, units="ns").start())

    probe = FlProbe2(dut)
    # 🔴 V0 正控：层次路径必须成立。取不到 ⇒ **是路径写错，不是「没流量」**。
    assert not probe.missing, (
        "FLDUTY-INVALID-V0 取不到这些【硬绑】信号（层次路径 / verilator 优化 / "
        "sim_build 是别的顶层）: " + "; ".join(probe.missing))
    if probe.missing_opt:
        dut._log.warning("FLDUTY-SOFTMISS 软绑缺 %d 根 ⇒ 对应闸判 UNCOVERED（不是绿）: %s",
                         len(probe.missing_opt), "; ".join(probe.missing_opt))

    if dual:
        r0, r1 = duty_descs_dual(K, T)
        fw = firmware_v2(r0, r1)
        ndesc = len(r0) + len(r1)
        dut._log.info("FLDUTY-FW words=%d ring0=%d ring1=%d K=%d T=%d dual=1",
                      len(fw), len(r0), len(r1), K, T)
    else:
        descs = duty_descs(K, T, half_sel=half_sel,
                           lay=(LAYOUT_38 if T > 3 or K > 24 else LAYOUT_37))
        fw = firmware_v(descs)
        ndesc = len(descs)
        dut._log.info("FLDUTY-FW words=%d descs=%d K=%d T=%d half_sel=%d dual=0",
                      len(fw), ndesc, K, T, half_sel)
    await boot_and_run(dut, fw)
    cocotb.start_soon(watch_health(dut, budget))
    cocotb.start_soon(probe.run(budget))
    if extra_probe is not None:                      # 🔴 排在既有协程之后，见上方 ②
        cocotb.start_soon(extra_probe(dut, tag, K, T, dual, budget))

    got = []
    sink = cocotb.start_soon(egress_sink(dut, got, WORDS_PER_ROW))
    for _ in range(budget):
        await RisingEdge(dut.clk_i)
        if len(got) >= WORDS_PER_ROW:
            break
    else:
        # 🔴 超时【本身】是 FL-WEDGE 的签名（§37.1-⑤ 的 H2）。先出报告再抛，
        #    否则判决器拿不到任何计数、只能判 INVALID，信息全丢。
        probe.report(dut, tag + "-TIMEOUT", K, T)
        raise AssertionError(
            f"FLDUTY-TIMEOUT-{tag} 负载没跑完（{budget} 拍），计数无意义；"
            "若 Tensor 卡在 ST_DRAIN 即 §37.1-⑤ 的 H2 楔死")
    await sink
    probe.report(dut, tag, K, T)

    # 🔴 决定性证伪实验（§38.10）：台架的退出条件是 NoC 令牌，不是 CTX_DONE。
    #    串行臂的令牌来自 ctx0 自己环尾的 DMA，而 dma_engine 的 done_o 要等 ST_DONE
    #    ⇒ ctx0 的 CTX_DONE 落在台架【停钟之后】3-4 拍 ⇒ §10.18 被遮蔽。
    #    多走几拍就该在【单 ctx】臂上以同样的 wd_cnt=1 / CTX_DONE 复现。
    #    放在 report() 之后 ⇒ 计数器不受影响，§37 三臂仍逐位复现（回归控不被污染）。
    for _ in range(tail_cycles):
        await RisingEdge(dut.clk_i)

    bad = [(i, hex(g)) for i, g in enumerate(got) if g != TOKEN]
    assert not bad, f"FLDUTY-INVALID-{tag} 完成令牌不对: {bad[:4]}"
    # 🔴 本件只断言【测量本身成立】，不断言占空比高低（那是判决器的事，§37.4/§37.5）。
    assert probe.N_cyc > 0, "FLDUTY-INVALID 采样器一拍都没采到"
    assert probe.N_in <= probe.N_cyc, "FLDUTY-INVALID 计数不自洽 N_in > N_cyc"

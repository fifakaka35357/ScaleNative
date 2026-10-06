# cocotb + Verilator regression harness for H-Tensor numeric datapath.
# Usage: make MODULE=test_mac_lru TOPLEVEL=mac_lru
#        make clean
TOPDIR := $(shell cd .. && pwd)

SIM ?= verilator
TOPLEVEL_LANG ?= verilog

# --- per-test overridable ---
TOPLEVEL ?= mac_lru
MODULE   ?= test_mac_lru
VERILOG_SOURCES ?= $(TOPDIR)/rtl/Tensor/tensor_pkg.sv $(TOPDIR)/rtl/Tensor/mac_lru.sv

# Verilator: treat .sv as SystemVerilog; silence project-style lints.
# -Wno-LATCH: Verilator false-positive on case-scoped `automatic` combinational
#   temporaries (re-initialized every evaluation; correct in sim and synth).
# (vec_lane_array's tz_shifter feed-through UNOPTFLAT is waived in-RTL with a
#  SCOPED /* verilator lint_off UNOPTFLAT */, not a project-wide flag — SV-2.)
EXTRA_ARGS += -sv -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-WIDTHEXPAND \
              -Wno-WIDTHTRUNC -Wno-CASEINCOMPLETE -Wno-SIDEEFFECT -Wno-LATCH

# --- pe_top (CPU-driven SoC bench) ---------------------------------------------
# The vendored IBEX lives only in the ORFS tree (single source of truth; pe_top's
# config.mk points at the same files). Its prim_assert.svh needs an include dir.
# Harmless for every other test — it is only an -I path.
IBEX_DIR := $(TOPDIR)/designs/src/aichip_sv/ibex
EXTRA_ARGS += -I$(IBEX_DIR)/vendor/lowrisc_ip/prim/rtl
# pe_top has deep hierarchies and a 2.4M-gate-equivalent RTL; raise Verilator's
# unroll/inline limits so it does not bail out on the MAC array generate loops.
EXTRA_ARGS += -Wno-UNOPTFLAT -Wno-BLKANDNBLK -Wno-MULTIDRIVEN --unroll-count 1024
# -Wno-PINMISSING: pe_top deliberately leaves some observability ports open
#   (vector_unit_top.err_code_o — the CP has no exec-error input; a KNOWN
#   limitation, see Review/PreTapeout_RTL_Fixes_2026-07-12.md).
# -Wno-COMBDLY: tech_icg_wrapper's *behavioural* (non-PDK) branch models the ICG
#   latch with `<=` inside always_latch. Verilator executes it as blocking, which
#   is the correct latch semantics; the synthesised PDK branch uses a real cell.
EXTRA_ARGS += -Wno-PINMISSING -Wno-COMBDLY
# --assert: WITHOUT it Verilator silently DISCARDS every `assert property` /
#   immediate assert in the RTL — i.e. the inline tripwires in vector_unit.sv
#   ([VEC-PIPE ⑥] phase discipline, [C-MX ⑦ C3] shared-exp, [C5] operand-prep)
#   and ~80 more across Tensor/IBEX_SRAM were dead code in the gate. Measured
#   2026-07-24: with it, sim_build carries assertion sites tagged
#   vector_unit.sv:<line>; without it, ZERO.
EXTRA_ARGS += --assert
# 🔴🔴 [2026-09-01] --bbox-unsup 是 pe_assertions.sv 能进编译面的前提（16 处 ## 时序 SVA）。
#   代价必须写明：它把不支持的构造【静默黑盒化】—— **编得过但不检查**，是 fail-open。
#   实测受影响的真断言只有 3 条（按名登记于欠账 #48）：
#       a_no_done_reset · a_soft_reset_ctx · a_vis_blocked
#   其余 5 处是 cover、4 处是 §10.16c 的 sequence 声明（该段已 `ifndef VERILATOR 守卫）。
#   ⇒ pe_top 断言的诚实计数 = **96 条真跑 / 3 条黑盒**，不是 99。
EXTRA_ARGS += --bbox-unsup

# --- X-prop 红绿道（批 4a 搭载件，P2「数据寄存器去异步复位」的前置）-----------
# 🔴 现门禁对「去复位」是 fail-open：Verilator 默认把所有信号零初始化，而本设计
#    绝大多数寄存器的复位值恰好就是 0 —— 删掉复位后仿真行为逐位不变，测试照绿。
#    实测确认（2026-07-29）：本 Makefile 此前没有任何 --x-initial / --x-assign。
# 打开方式（不改变默认 run_all 语义）：
#    make XPROP=1 XSEED=1 MODULE=... TOPLEVEL=... VERILOG_SOURCES="..."
#    XPROP=1 XSEED=1 python3 run_all.py <filter>     # 环境变量经 ?= 透传给 make
# 双种子跑法 = 同一用例分别用 XSEED=1 与 XSEED=2 各跑一遍（种子不同则随机复位
# 值不同；只有一个种子红也算红）。
#   --x-initial unique : 未初始化信号取「每处唯一」的随机值，而非 0
#   --x-assign unique  : RTL 里显式赋 'x 的地方同样随机化
#   +verilator+rand+reset+2 : 运行期把上述随机化真正打开（0=全零 1=全一 2=随机）
#   +verilator+seed+N       : 钉住随机序列，保证红/绿可复现
XPROP ?= 0
XSEED ?= 1
ifeq ($(XPROP),1)
EXTRA_ARGS += --x-initial unique --x-assign unique
PLUSARGS   += +verilator+rand+reset+2 +verilator+seed+$(XSEED)
endif

# --- 逐测试的编译钩子（2026-09-04 加，默认空 ⇒ 对现有测试逐字无影响）-------------
# 🔴 为什么需要它：`EXTRA_ARGS` 与 cocotb 的 `COMPILE_ARGS` 都是用 `+=` 累积的，
#    而 **make 的命令行赋值会覆盖 makefile 里的全部赋值（含 `+=`）** ⇒
#    在命令行写 `EXTRA_ARGS=...` 会冲掉本文件的 `-Wno-*`；写 `COMPILE_ARGS=...` 会冲掉
#    cocotb 的 `--vpi --public-flat-rw --prefix Vtop -o Vtop`（`Makefile.verilator:57`），
#    表现是 **verilator 跑完却不生成 `Vtop.mk`**，报错信息完全不指向真因。
#    ⇒ 需要一个**只增不覆盖**的入口。
# 用法: make ... TEST_EXTRA="-DPDK_ASAP7 -GREAL_MACRO=1"
TEST_EXTRA ?=
EXTRA_ARGS += $(TEST_EXTRA)

include $(shell cocotb-config --makefiles)/Makefile.sim

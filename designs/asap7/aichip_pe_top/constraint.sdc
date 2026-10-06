# =============================================================================
# pe_top — ASAP7 SDC（liberty 时间单位 = ps）。[2026-07-13]
#
# 与 sky130 版（designs/sky130hd/aichip_pe_top/constraint.sdc）逐条同构，
# 只有【时间单位】不同：ns -> ps，且预算按 ASAP7 签核约定重取，
# **不是把 sky130 的 ns 值乘 1000**（那会得到荒唐的 IO 预算）。
#
#   sky130                      ASAP7（本文件）
#   clk_period       70.0 ns    20000 ps  (20 ns / 50 MHz)
#   uncertainty      0.15 ns    50 ps
#   latency          0.29 ns    50 ps
#   IO delay         1.0 ns     100 ps
#   （ps 预算取值 = aichip_tensor_signoff/constraint.sdc 的已验证约定）
#
# 20000 ps 的依据（不是拍脑袋）：
#   sky130 pe_top 的 post-3_4 reg2reg 实测 = 103.59 ns（临界路径 = Vector
#   compact-MX 的 ctrl_q[32] -> cmx_lane[228]）。跨 PDK 延迟比用同一份 RTL 的
#   Tensor 实测标定：sky130 OS Fmax 20.64 MHz (48.45ns) vs ASAP7 125.96 MHz
#   (7.94ns) = 6.1×。=> pe_top 在 ASAP7 上预期 103.59 / 6.1 ≈ 17 ns。
#   20 ns 给 repair 留余量。**Fmax 以 post-route report_clock_min_period 为准
#   （reg2reg 口径），不是固定时钟的 WNS** —— 与 sky130/ASAP7 签核同一口径。
#
# ⚠️ ASAP7 的 SEQ 库 DFF 只有 QN 输出（QN = !存储值）—— 2026-07-12 审计 blocker。
#    下面的 set_case_analysis 是【极性感知】的：命中 QN 脚就钉 1（= dataflow_sel 0 = OS）。
#    sky130 有 Q 脚故历来正确；此写法对两种库都成立。**不得改回无条件钉 0。**
# =============================================================================
current_design pe_top

set clk_name      core_clock
set clk_port_name clk_i
# [2026-07-18 Round 3] 20000 -> 10000：[VEC-PIPE ⑥] 后让 repair 攻击 en_latch 锥。
# 🔴 [2026-07-19 R3a 实测证伪 10ns]：10ns 的 repair 压力把 IBEX CSR 角落塞成
# 布线死结（GRT 热点 capacity 20/usage 31 = 超容 55%，congestion.rpt 全部集中
# die 西缘 x=11-29µm；GRT-0115 带拥塞放行 → DRT 53k 违例平台期不收敛，杀于
# iter16）。布线需求总量只 +0.8% —— 是【局部】热点不是全局爆炸。失败现场 =
# base_10ns_congested_20260719。
# -> 12000：en_latch 锥（12.65ns）仍受压（探索目标保住），10-12.65ns 区间的
# 海量路径不再被过度加压。若 12ns 仍 GRT-0115 → 再退 14ns 或转热点定点修。
#
# 🔴🔴 [2026-09-02 订正] 上面【整段退钟理由已被证伪、就此作废】——「en_latch 锥 = 12.65ns」是错的。
#   该端点是 negative level-sensitive latch（petop_sta_final.log:2600-2601 逐字），
#   参考沿是 T/2 不是 T，用 `T − slack` 外推无定义。正确式 slack0(T) = T/2 − 2653.70
#   ⇒ 零借用 T_min = 5307.4 ps (188.4 MHz)、满借用 2745.2 ps (364.3 MHz)。
#   ⇒ 在 T=12000 下该端点零借用 slack = +3346.30 ps，**根本不「受压」**。
#   ⇒ 20000→10000→12000 这两步退钟，理由建立在一个算错倍率的墙上（实付两轮 P&R：
#     07-19 10ns 拥塞失败、07-21 R4b 12ns DRT 被杀）。
#   全文订正 = Paper/PPA_Tables_SSOT.md 注 P-g② 的 ▲订正框 `C-PG2-LATCH`；欠账 #49。
#
# 🔴 **`clk_period = 12000` 这个【值】本次未动**，只作废它的【理由】。
#   改值 = 改口径 ⇒ 必须先重新论证并预登记（S-5 卡着；见 PROJECT_RULES §4.ag-BACKLOG #49）。
#   重新论证时真正该盯的【不是】 en_latch。
#
# 🔴🔴 [2026-09-02 二次订正] 上一行原写「真正该盯的是 Vector ctrl_q[32]→cmx_lane[227]
#   (8815.35 ps)」—— **那也是错的，它是 pre-VEC-PIPE⑥ 的绑定路径**。
#   07-21 R4b（post-⑥）实测已换族：
#     Startpoint i_tens/u_tensor/u_egress_fragmentizer/state_q[2]
#     Endpoint   i_tv_fifo/mem[1][248]      post-CTS period_min = 8299.57 ps
#     (PPA_Evidence_Snapshots/2026-07-21_asap7_petop_r4b/4_cts_final.rpt:19,19725,19727)
#   ⇒ **真墙 = Tensor egress 打包锥，不是 Vector 广播**（HANDOFF_2026-08-07_SoC600.md:40-44）。
#
# 🔴🔴🔴 [2026-09-02 三次订正 · 欠账 #59] 上一稿在这里写的
#   「该锥 3652 ps 是【真逻辑深度】(72% 逻辑、非长线) ⇒ SDC/物理旋钮解决不了」
#   —— **这句是三重错，整句作废**：
#     ① `3652` 是**整条 8237.5 ps 路径上所有真逻辑门之和**，不是 egress 那一段；
#     ② `u_egress_fragmentizer` 只占 **138.60 ps (3.8%)**，质量在 `u_result_packer` **2581.44 ps (70.7%)**；
#     ③ 「72%」是 **cell 延迟占比**不是逻辑深度 —— 真逻辑仅 **44.3%**，**48.7% 是工具插的 buffer/中继**。
#   ⇒ **「物理旋钮解决不了」失去依据**（近一半质量恰恰是物理旋钮的作用域）。
#   订正依据 = `soc600_review_raw_20260807.json:122` 的 `corrected` 字段；
#   错误来源 = 同一份 JSON `:120` 的 `impact` 字段，**被 8 处活文档逐字继承**
#   （规则 `PROJECT_RULES §4.ax`：从审查 JSON 搬结论必须同时读 `corrected`）。
set clk_period    12000
set clk_port      [get_ports $clk_port_name]
create_clock -name $clk_name -period $clk_period $clk_port

set_clock_uncertainty 50 [get_clocks $clk_name]
# Pre-CTS 理想时钟延迟；post-CTS 流程切 propagated。
set_clock_latency 50 [get_clocks $clk_name]

# ---- 虚拟 I/O 时钟，固定 ABSOLUTE 预算（不随周期缩放）----
create_clock -name io_clk -period $clk_period
set_clock_uncertainty 50 [get_clocks io_clk]
set IO_DLY 100
set non_clock_inputs [all_inputs -no_clocks]
set_input_delay  $IO_DLY -clock io_clk $non_clock_inputs
set_output_delay $IO_DLY -clock io_clk [all_outputs]

# 异步低有效复位：布局前是巨大的无缓冲广播，从不是数据通路操作数。
# [2026-07-17 已修 · PROJECT_RULES §4.3b] 本行端口 false_path 只盖【起点=rst_ni】；
# 真正的 51,487 扇出广播起点是同步器输出寄存器 rst_sync_q[1]（外加
# i_cp/i_csr/cp_soft_reset_o 与 test_en_i 经 i_tens/dom_rst_n）。修法=下面的
# 【endpoint 侧】false_path 块，本行保留不动。
set_false_path -from [get_ports rst_ni]

# ----------------------------------------------------------------------------
# 复位树 recovery 屏蔽 —— endpoint 侧（与 sky130 版同构，唯一实质差异=异步脚名）。
# 不枚举起点：soft_reset/test_en 有真实功能扇出（CSR 读回、ICG SCE、done 门控），
# -from 一刀切会误杀活路径。recovery/removal 的 PathEnd 就生成在异步脚上、该脚
# 无其它时序端点 -> 误杀面≈0、天然覆盖全部起点、不受 repair buffer 分段影响
# （-through 网名在 CTS/route 阶段会失效）。
#   -setup = 只杀 recovery（max 类）；removal（min 类）故意保留 —— sky130
#            post-route 最差 removal 仅 +0.61ns，是真实短路径安全检查。
# ⚠️ ASAP7 SEQ 库唯一异步 flop = DFFASRHQNx1，异步脚 RESETN + SETN【两个都要盖】，
#    照抄 sky130 的 */RESET_B 会 100% 漏光。**不得回抄。** 且 QN-only 约定下
#    liberty 里 preset="!RESETN"、clear="!SETN"（脚名与 clear/preset 角色互换）
#    ——本块两脚全盖不受影响，但未来任何按极性处理复位脚的约束必须先看这条。
# 设计级 pin 数以首次 read_sdc 日志的 SDC-INFO 计数为基准记录；层次网表文本
# grep 会因死 uniquified 模块虚高（sky130 实测虚高 25%），不得当设计级计数用。
# 注意：这只是报告/repair_timing 努力方向的卫生工程，不作废 GDS —— repair_design
# 电气修复（max_slew/max_cap/max_fanout）不看 exception，复位 buffer 树照建；
# 释放偏斜走【披露】而非修复（合作方后端自建平衡复位树）。
# ----------------------------------------------------------------------------
set a7_rstn_pins [get_pins -quiet -hierarchical */RESETN]
set a7_setn_pins [get_pins -quiet -hierarchical */SETN]
# 🔴🔴 [#58 · 2026-09-02] `puts` -> `error`（fail-closed）。这是本文件三处 `SDC-ERROR` 之一。
#   病根：原文是 `puts`，于是「异步脚一个都没匹到」只在日志里留一行，**流程照跑、rc=0**
#   —— 与 `D-R1-MCP-2026-08-11` 的病根逐字同形。
#   工具语义**已在真工具上验过**（不是读源码推的）：OpenSTA `include_file` 的
#   `sta_continue_on_error` 缺省 0（`tcl/Util.tcl:377`）且 ORFS 不覆盖
#   ⇒ SDC 里的 `error` 会中断整份 SDC、让 `read_sdc` 抛错、进程退出码 1
#   （证据 `aichip_run_logs/b58_sdcerr_cmdproof_20260811.log`）。
if { [llength $a7_rstn_pins] == 0 } {
  error "SDC-ERROR: no */RESETN async pins matched (asap7 DFFASRHQN) -> reset recovery NOT masked; rst_sync_q\[1\] fanout will pollute repair_timing and async reports. Check netlist/library."
}
# 🔴 SETN 这条**有意保持 WARN**（#58 登记的三处不含本条）：漏盖 SETN 会让那些 recovery 路径
#   **保持被约束** = 偏悲观，不会让 Fmax 变好看。只有【乐观方向】的失效才值得 fail-closed。
#   把每一条都升级成 error 的代价是 96 min 综合白跑，收益是 0。
if { [llength $a7_setn_pins] == 0 } {
  puts "SDC-WARN: 0 */SETN pins matched but DFFASRHQN carries BOTH async pins (count should ~= RESETN) -> coverage broken, audit netlist."
}
set a7_async_pins [concat $a7_rstn_pins $a7_setn_pins]
if { [llength $a7_async_pins] > 0 } {
  puts "SDC-INFO: false_path -setup -to [llength $a7_rstn_pins] RESETN + [llength $a7_setn_pins] SETN async pins (recovery masked; removal kept constrained; reset release skew disclosed to partner)"
  set_false_path -setup -to $a7_async_pins
}

# ----------------------------------------------------------------------------
# Tensor OS 钉死 —— 对 Tensor 子树的 dataflow_sel 触发器做 case_analysis 0。
# SCOPED：tensor_cmd_mmio_seq.sv 也有同名信号；只有 i_tens 里那个（单一源
# tile_desc_q 位）该被钉。
#
# 🔴🔴 [#58 同批 · 2026-09-02] 补 `DF_EXPECT` 计数闸（tile 侧 2026-08-11 已做，
#   `m1_tensor_1600.sdc:60-64`；pe_top 是 `D-R1-MCP` 登记的 OPEN 4 之一，一直没做）。
#   为什么这条比 MCP 那条**更狠**：它干的是 `set_case_analysis`（把脚钉成常量、直接剪掉
#   逻辑锥）。原写法**只在「一个都没匹到」时打 WARN，匹多了完全无声** ——
#   多钉一个寄存器 = 悄悄剪掉一片本该计时的逻辑，**Fmax 会变好看**，而没有任何东西变红。
#   这正是【乐观方向】的失效 ⇒ 必须 fail-closed。
#   实测期望（2026-09-02 真跑 `logs/asap7/aichip_pe_top/base/1_synth.log:34`）：**恰好 1 个**
#     i_tens/u_tensor/u_cmd_decoder.reg_dataflow_sel$_DFFE_PN0P_
#   （tile 控制器内的 `tile_desc_active[16]` 那一位走下方**另一段**独立 pin-down，不计入本条。）
# ----------------------------------------------------------------------------
set DF_EXPECT 1
set df_all [get_cells -quiet -hierarchical *dataflow_sel*]
set df_cells {}
foreach c $df_all {
  if { [string first "i_tens" [get_full_name $c]] >= 0 } { lappend df_cells $c }
}
if { [llength $df_cells] != $DF_EXPECT } {
  error "SDC-ERROR: dataflow_sel case_analysis 覆盖面漂移：i_tens 内匹到 [llength $df_cells] 个，期望 $DF_EXPECT（全网表 glob 命中 [llength $df_all] 个）-> set_case_analysis 会把脚钉成常量、剪掉逻辑锥；多钉/少钉都会静默改变 Fmax。必须先查清新出现/消失的是哪个寄存器再改 DF_EXPECT。见 PROJECT_RULES §4.z-bis 与 §4.ag-BACKLOG #58。"
}
# 🔴 打印**全名**而不是 `$df_cells` —— cell 对象的字符串形态是工具内部句柄
#   （2026-09-02 真跑逐字：`on: _606c0af4a75e0000_p_Instance`），日志因此不可审计。
#   闸必须打印【依据】，不能只打印判词（PROJECT_RULES §4.au）。
set df_names {}
foreach c $df_cells { lappend df_names [get_full_name $c] }
puts "SDC-INFO: set_case_analysis (polarity-aware OS pin-down) on: $df_names (glob 全网表命中 [llength $df_all]，i_tens 内 [llength $df_cells]/$DF_EXPECT)"
foreach dfc $df_cells {
  set qpins [get_pins -quiet -of_objects $dfc -filter {direction == output}]
  foreach qpin $qpins {
    # 极性感知：ASAP7 的 SEQ 库 DFF 只有 QN（QN = !存储值），钉 OS(dataflow_sel=0)
    # 必须钉 QN=1。sky130 有 Q 脚。此写法对两种库都成立。
    if { [string match {*QN} [get_property $qpin full_name]] } {
      set_case_analysis 1 $qpin
      puts "SDC-INFO:   QN pin [get_property $qpin full_name] -> case 1 (=dataflow_sel 0, OS)"
    } else {
      set_case_analysis 0 $qpin
      puts "SDC-INFO:   Q pin [get_property $qpin full_name] -> case 0 (OS)"
    }
  }
}

# ============================================================================
# Tensor 每 tile 的准静态控制 —— multicycle。
# ============================================================================
# 🔴🔴🔴 [#58 FIX · 2026-09-02 · 裁决 D-R1-MCP-2026-08-11 搬到 pe_top]
#   宽 glob + `i_tens` 字符串过滤  ⇒  **结构锚 + 家族白名单 + fail-closed**
#
# 病历（**pe_top 是 `D-R1-MCP` 自己登记的「OPEN 4」之一，收窄只做在 tile 侧**）：
#   · 2026-07-18 本段实测 `multicycling 6 i_tens quasi-static control regs`，零 SDC-ERROR。
#   · 2026-09-01 欠账 `#31` 把产品 RTL 同步进构建树 ⇒ `c6_mode_q` 进入 pe_top 网表。
#   · 2026-09-02 阶段 A 实测：`mode_q=1030/6` ⇒ `multicycling **1062**`（**177×**）。
#     多收的 1024 个是 `i_tens/u_tensor/u_mac_array/gen_row[R].gen_col[C].u_mac/c6_mode_q[b]`
#     —— **逐拍消费**的流水寄存器，却白拿了 `-setup 4`。
#   · 🔴 本段**自己打印了** `SDC-ERROR ... Audit before trusting Fmax`，**但那是 `puts`**
#     ⇒ `make` 照样 rc=0、`1_synth.odb` 照样落盘。**改动本身正确，静默作废了别处的前提。**
#   · 后果两条，都在【乐观方向】：① `-setup 4` 施加在 1062 个寄存器上 ⇒ **Fmax 必然虚高**；
#     ② 同批 `-hold 3` 施加在 1062 个上 ⇒ **真 hold 违例可能被整片吞掉**
#     （`PathEnd.cc:803-808`；而 pe_top **有真 reg2reg hold 违例**，是当前的一票否决项）。
#
# 修法三件（与 tile 侧同构，缺一不可）：
#   ①【致命化】计数不符从 `puts` 改 `error`（本文件三处 SDC-ERROR 全部致命化）。
#   ②【锚在结构上】用层级 `*u_tile_controller/*` 圈范围，**不是**往名字黑名单里再加一条。
#      原 `*err_mode_q*` 黑名单已删 —— 黑名单对**新出现的名字**永远是瞎的，
#      `c6_mode_q` 就是这么进来的。（实测 `err_mode_q` 不在 tile 控制器内，结构上天然排除。）
#   ③【白名单 + 反向闸】叶名必须落在显式家族表里否则 error；且收窄后 c6_mode_q 命中数必须为 0，
#      并配**非零正控**（否则反向闸会因为「根本没找到 c6」而恒绿）。
#
# 🔴 为什么锚写 `*u_tile_controller/*` 而不是钉死 `i_tens/u_tensor/u_tile_controller/*`：
#   pe_top 的全名分隔符**不统一**（实测：`i_tens/u_tensor/u_tile_controller/...` 用 `/`，
#   而 `i_tens/u_tensor/u_cmd_decoder.reg_dataflow_sel`、`i_vec.u_vector_unit/...` 用 `.`）
#   —— 那是 yosys 展平的产物，会随综合脚本变。钉死全路径 ⇒ 上游一展平就匹 0 个、
#   96 min 白跑。`*u_tile_controller/*` 仍然把 `u_mac_array/.../u_mac/` 结构性排除在外
#   （这才是本修法要挡的东西），同时对路径变化免疫；**路径本身走【披露】不走【判红】**
#   （下方 SDC-INFO 打印实际父前缀），因为它不改变覆盖面。
#
# 🔴 收窄只会**移除**被放宽的寄存器 ⇒ 比原来严格 ⇒ **不需要新的有效性推导**。
#   原有效性条件（对抗验证 2026-07-21，存档）：OS 执行 + ST_LOAD_WEIGHT=16 拍 +
#   ST_CLEAR_ACC=1 拍结构不变 -> 首次架构性消费 = 锁存后第 18 拍，`-setup 4` 余量 14 拍；
#   WS 口径或流水缩短必须重推导（mode_q 与 tile_desc_active[0] 有 WS 第 1-2 拍消费窗）
#   —— 合作方双模式重签不可照抄。
# ============================================================================
set QS_SCOPE {*u_tile_controller/*}
# 家族白名单与期望计数。🔴 改这张表 = 改口径，必须同批给出有效性推导。
#   本表的数**逐个来自真产物**，不是抄 tile 侧的：
#     `results/asap7/aichip_pe_top/base/1_2_yosys.v` 里
#     module `tensor_tile_controller$pe_top.i_tens.u_tensor.u_tile_controller` 内的实例声明计数
#     = mode_q 4 · sparse_mode_q 2 · k_total_q 16 · tile_desc_active 17 · n_cfg_q 2
#   其中 tile_desc_active 的 17 = 16（进 MCP）+ 1（bit16 = dataflow_sel，走下方 OS pin-down）。
#   交叉核对：4+2+16+16 = **38**，与 `D-R1-MCP` 在 tile 侧收窄后的 38 逐字一致（同一份 RTL）。
array set QS_EXPECT {mode_q 4 sparse_mode_q 2 k_total_q 16 tile_desc_active 16 n_cfg_q 2}

set qs_cells    {}
set tda16_cells {}
set ncfg_cells  {}
set qs_alien    {}
set qs_outside  {}
set qs_c6_out   0
array set QS_PARENT {}
foreach f [array names QS_EXPECT] { set QS_GOT($f) 0 }

foreach g {*mode_q* *k_total_q* *tile_desc_active* *n_cfg_q*} {
  foreach c [get_cells -quiet -hierarchical $g] {
    set fn [get_full_name $c]
    if { ![string match $QS_SCOPE $fn] } {
      if { [string match {*c6_mode_q*} $fn] } {
        incr qs_c6_out
      } else {
        lappend qs_outside $fn
      }
      continue
    }
    set par $fn
    regsub {u_tile_controller/.*$} $par {} par
    set QS_PARENT($par) 1
    set leaf [lindex [split $fn /] end]
    regsub {\$.*}        $leaf {} base
    regsub {\[[0-9]+\]$} $base {} base
    set bit -1
    if { [regexp {\[([0-9]+)\]\$} $leaf -> b] } { set bit $b }
    if { ![info exists QS_EXPECT($base)] } { lappend qs_alien $fn ; continue }
    if { $base eq "tile_desc_active" && $bit == 16 } { lappend tda16_cells $c ; continue }
    # 🔴 `n_cfg_q`：**登记进白名单（让漂移闸过），但【分流出 MCP】**。
    #   pe_top 侧的两条理由（不是抄 tile 侧的口径可比性那条）：
    #   ① 🔴 **pe_top 有真 reg2reg hold 违例**，按 §4.w 是一票否决项。`-hold 3` 每多盖一个
    #      寄存器，就多一分把真违例吞掉的机会（`PathEnd.cc:803-808`）。
    #      在 hold 还没清干净之前，MCP 覆盖面只许缩不许扩。
    #   ② **与 tile 侧同口径**：tile 臂也不给它 MCP。pe_top 的数将来要和 tile 的数并排看，
    #      两边的放宽面不一样 = 两边的 Fmax 不可比。
    #   代价 = 两个控制寄存器不放宽；它们不在绑定路径上（实测绑定路径 = Tensor egress 打包锥，
    #   `#57`）。要改回「给它 MCP」必须同批重做有效性推导并登记。
    if { $base eq "n_cfg_q" } { lappend ncfg_cells $c ; incr QS_GOT($base) ; continue }
    lappend qs_cells $c ; incr QS_GOT($base)
  }
}

# ---- 披露（不判红）：锚外命中 + 实际父前缀 ----------------------------------
puts "SDC-INFO: QS_SCOPE='$QS_SCOPE' 实际父前缀: [lsort [array names QS_PARENT]]"
puts "SDC-INFO: 锚外命中 c6_mode_q $qs_c6_out 个（结构性排除，正确）；锚外其它命中 [llength $qs_outside] 个，保持完全约束（正确）: $qs_outside"

# ---- 闸① 家族计数（白名单）：不符 ⇒ **error**（2026-09-02 前是 puts，这就是 #58 的病根）----
set qs_bad {}
foreach f [lsort [array names QS_EXPECT]] {
  if { $QS_GOT($f) != $QS_EXPECT($f) } { lappend qs_bad "$f=$QS_GOT($f)/$QS_EXPECT($f)" }
}
if { [llength $tda16_cells] != 1 } { lappend qs_bad "tda16=[llength $tda16_cells]/1" }
if { [llength $qs_alien] != 0 } {
  lappend qs_bad "未登记叶名 [llength $qs_alien] 个(如 [lindex $qs_alien 0])"
}
if { [llength $qs_bad] != 0 } {
  error "SDC-ERROR: quasi-static family drift: [join $qs_bad { }] (scope=$QS_SCOPE) -> 网表命名或家族构成变了，覆盖面已不是设计时的样子。必须先重做有效性推导再改 QS_EXPECT；在此之前 Fmax 不可信。见 PROJECT_RULES §8 D-R1-MCP-2026-08-11 与 §4.ag-BACKLOG #58。"
}

# ---- 闸② 反向闸 G-QS-NOC6：收窄后不许再有 C6 流水寄存器（配非零正控）----
# 🔴 正控刻意用 `get_cells -hierarchical`（而不是 R1 探针那条 `get_pins -hierarchical {*/D}`）：
#   后者只在 **post-route** 上验过，而本段跑在 **synth** 阶段 —— 拿一个在别的阶段验过的
#   原语当正控，正是「口径混排藏在一条闸里」（PROJECT_RULES §4.w-quater）。
# 🔴 这个数**只能当「非零」用，不是触发器计数**，别拿去当规模数引用；**它随流程阶段变**
#   （tile 侧 2026-08-11 两阶段都量过：synth 1024 / post-route 2048 = flop + 同名 TIE 伴生）。
#   pe_top 2026-09-02 synth 实测同样是 **1024**。
set n_c6    [llength [get_cells -quiet -hierarchical *c6_mode_q*]]
set n_c6_in 0
foreach c $qs_cells { if { [string match {*c6_mode_q*} [get_full_name $c]] } { incr n_c6_in } }
# 正控的**声明制**逃生口（与 tile 侧同名同义，故一次声明覆盖两边）：
#   候选刀 K1c-A 会删掉 `c6_mode_q` 这个寄存器；届时 `n_c6 == 0` 会 error 把整趟 P&R 打掉。
#   修法不是删闸（删了就正是本闸自己那句「是闸瞎了，不是设计干净了」），而是换锚，
#   且锚由调用方显式给出（本文件**不猜**一个还不存在的设计里对象叫什么），并配反控。
set _K1CA 0
if { [info exists ::env(B58_K1CA_LANDED)] } { set _K1CA $::env(B58_K1CA_LANDED) }
if { $_K1CA ni {0 1} } {
  error "SDC-ERROR: B58_K1CA_LANDED 只能是 0|1（收到 '$_K1CA'）"
}
if { $_K1CA == 0 } {
  if { $n_c6 == 0 } {
    error "SDC-ERROR: G-QS-NOC6 正控失效：网表里一个 c6_mode_q 都没找到 -> 反向闸恒绿、结构性失明（是闸瞎了，不是设计干净了）。若本网表【本就该】没有它（K1c-A 已落地），须显式给 B58_K1CA_LANDED=1 与 B58_K1CA_ANCHOR=<承接 mode 选择的对象 glob> 重跑，并在判据里登记这次声明。"
  }
} else {
  if { ![info exists ::env(B58_K1CA_ANCHOR)] } {
    error "SDC-ERROR: 声明了 B58_K1CA_LANDED=1 却没给 B58_K1CA_ANCHOR -> 正控无锚 = 闸瞎了（本文件不猜对象名）。"
  }
  set _anc [llength [get_cells -quiet -hierarchical $::env(B58_K1CA_ANCHOR)]]
  if { $_anc == 0 } {
    error "SDC-ERROR: G-QS-NOC6 换锚后正控仍失效：B58_K1CA_ANCHOR='$::env(B58_K1CA_ANCHOR)' 一个都没找到。"
  }
  if { $n_c6 != 0 } {
    error "SDC-ERROR: G-QS-NOC6 反控红：声明了 K1c-A 已落地，却仍有 $n_c6 个 c6_mode_q -> 刀没真落地（或网表拿错了）。"
  }
  puts "SDC-INFO: G-QS-NOC6 换锚 PASS (B58_K1CA_LANDED=1 anchor='$::env(B58_K1CA_ANCHOR)' hits=$_anc, c6_mode_q=0)"
}
if { $n_c6_in != 0 } {
  error "SDC-ERROR: G-QS-NOC6 反向闸红：收窄后仍有 $n_c6_in 个 c6_mode_q 落进准静态集合（网表 c6 总数 $n_c6）-> 这正是 R1 证伪的那条放宽，绝不允许复发。"
}
puts "SDC-INFO: G-QS-NOC6 PASS (c6_mode_q glob hits=$n_c6 非触发器计数-随阶段变-synth约1024-postroute约2048, in qs_cells=0)"

# ---- 闸③ 空集：一个都没匹到 ⇒ **error**（原为 puts，#58 三处之一）----
if { [llength $qs_cells] == 0 } {
  error "SDC-ERROR: no i_tens quasi-static regs matched -> control-broadcast artifact will NOT be relaxed; Fmax will be under-reported. Check netlist names / QS_SCOPE."
}
set qs_names {}
foreach c $qs_cells { lappend qs_names [get_full_name $c] }
puts "SDC-INFO: multicycling [llength $qs_cells] i_tens quasi-static control regs (mode_q=$QS_GOT(mode_q) sparse_mode_q=$QS_GOT(sparse_mode_q) k_total_q=$QS_GOT(k_total_q) tile_desc_active excl bit16=$QS_GOT(tile_desc_active) n_cfg_q=$QS_GOT(n_cfg_q)-diverted): $qs_names"
# 🔴🔴 `-setup` 与 `-hold` **同去同留**：只撤 setup 留 `-hold 3` ⇒ hold required 提前 3 拍
#   ⇒ hold 检查近乎恒过、整片吞掉真违例，**而且不会有任何东西变红**（`PathEnd.cc:803-808`）。
#   pe_top 当前正卡在 hold ⇒ 这是灾难级操作错误。
set_multicycle_path -setup 4 -from $qs_cells
set_multicycle_path -hold  3 -from $qs_cells
# 🔴 供下游比对：本行是**活体计数**；真正治理 floorplan..signoff 的却是 `write_sdc` 展开出的
#   `1_synth.sdc`（**冻结名单**）。两者之间隔着 `eliminate_dead_logic` —— pe_top 2026-09-02
#   实测差 5 个（tile_desc_active 被判死 5 位：活体 16 -> 冻结 11）。名单必须在**它真正治理
#   的那份产物上**再被检一次。
puts "SDC-QSCOUNT [llength $qs_cells]"
# 🔴 分流披露：n_cfg_q 在白名单里但**不进 MCP**（理由见收集循环处）。
puts "SDC-NCFG-DIVERTED [llength $ncfg_cells] (whitelisted, NOT multicycled)"
if { [llength $ncfg_cells] != $QS_EXPECT(n_cfg_q) } {
  error "SDC-ERROR: n_cfg_q 分流数 [llength $ncfg_cells] != 期望 $QS_EXPECT(n_cfg_q) —— 分流逻辑失效"
}
# 🔴 反控：分流件绝不许出现在 MCP 列表里（防有人把 continue 删了而没人变红）
foreach _nc $ncfg_cells {
  if { [lsearch -exact $qs_cells $_nc] >= 0 } {
    error "SDC-ERROR: n_cfg_q 同时出现在 qs_cells 里 ⇒ 分流失效"
  }
}

# tile_desc_active[16]（i_tens tile 控制器内 dataflow_sel 锁存位）：极性感知 OS pin-down。
foreach dfc $tda16_cells {
  foreach qpin [get_pins -quiet -of_objects $dfc -filter {direction == output}] {
    if { [string match {*QN} [get_property $qpin full_name]] } {
      set_case_analysis 1 $qpin
      puts "SDC-INFO: OS pin-down tile_desc_active\[16\] QN [get_property $qpin full_name] -> case 1 (=dataflow_sel 0, OS)"
    } else {
      set_case_analysis 0 $qpin
      puts "SDC-INFO: OS pin-down tile_desc_active\[16\] Q [get_property $qpin full_name] -> case 0 (OS)"
    }
  }
}

# =============================================================================
# 不要 multicycle / 不要 false_path（真正逐周期，P&R 会 buffer 它们）：
#   - 全部 Vector 域的 cell（零掩蔽纪律，含 vector_unit 的 mode_q / streaming_mode_q）
#   - Tensor 的逐周期清单：issue_en/mac_en、array_step_en、clear_acc、capture_fire、
#     active_tail_mask、weight_load、mx_scale_tick、dense_k_cursor_q、systolic 流、
#     acc_mant_reg 递归、**c6_mode_q（R1 已证伪，见上方 G-QS-NOC6）**
#   - L2 数据通路（req/gnt/rdata 组装）、ICG enable（3× tech_icg_wrapper）
# =============================================================================

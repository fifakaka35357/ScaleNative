# =============================================================================
# m1_tensor_1670.sdc — M1 Tensor 现役签核约束（clk_period 见下方 set）。
#   ~~"FROZEN measurement copy of aichip_run_logs/s0_tensor_1670.sdc"~~
#   🔴 **上面那句话在 2026-08-11 之后不再成立**：R1 修法（裁决 D-R1-MCP-2026-08-11）
#      落在本件，`aichip_run_logs/s0_tensor_1670.sdc` 保持 2026-07-23 原样、
#      只用于**复现旧测量**，绝不要拿它跑新臂。两者已**有意分叉**。
#   本族两件：`m1_tensor_1670.sdc`（现役）与 `m1_tensor_1600.sdc`（批 5.7 S1-b 收紧周期臂）。
#   🔴 **除第 2 行标题与 `set clk_period` 外，两件必须逐字相同**，而且这条一致性是
#      **可执行的等式**，不是约定：
#        python3 aichip_run_logs/b58_sdc_twin.py --check   # 闸（已挂发臂 preflight = G-SDC-TWIN）
#        python3 aichip_run_logs/b58_sdc_twin.py --sync    # 改完本件后同步孪生件
#      理由 = PROJECT_RULES §4.z-sexies 形状③「同一事实写在两处」。
# =============================================================================
# =============================================================================
# tensor_unit_top — ASAP7 SIGNOFF SDC (liberty time unit = ps).
#
# 20000 ps (20 ns / 50 MHz) signoff clock: ASAP7 pre-route packer = 11.27 ns;
# expected post-route degradation (7nm fine-wire RC, sky130 Tensor showed
# +34% pre->post, 7nm likely steeper ~+70%) -> ~18-20 ns. 20 ns gives repair
# margin toward WNS>=0. Fmax reported via post-route report_clock_min_period
# (reg2reg), NOT fixed-clock WNS — same idiom as sky130 signoff.
#
# ps-convention budgets (NOT sky130 ns values x1000): uncertainty 50ps,
# latency 50ps (overridden post-CTS by propagated), I/O 100ps absolute.
#
# OS pin-down + quasi-static multicycle blocks are RTL-STRUCTURAL (same signal
# names as sky130), VERIFIED to match on ASAP7 in the delta STA
# (asap7_delta_sta.tcl: "case_analysis 0 on 1 dataflow_sel", "multicycling 6").
# =============================================================================
set clk_name      core_clock
set clk_port_name clk
set clk_period    1670
set clk_port      [get_ports $clk_port_name]
create_clock -name $clk_name -period $clk_period $clk_port

set_clock_uncertainty 50 [get_clocks $clk_name]
# Pre-CTS ideal-clock latency; POST-CTS the flow uses set_propagated_clock.
set_clock_latency 50 [get_clocks $clk_name]

# ---- I/O: fixed ABSOLUTE budget 100 ps (all top I/O slow/quasi-static) -------
set io_dly 100
set non_clock_inputs [all_inputs -no_clocks]
set_input_delay  $io_dly -clock $clk_name $non_clock_inputs
set_output_delay $io_dly -clock $clk_name [all_outputs]

# ---- Async active-low reset false_path (never a datapath operand) ------------
set_false_path -from [get_ports rst_n]

# ---- OS pin-down: set_case_analysis 0 on dataflow_sel (HEADLINE) -------------
set df_cells [get_cells -quiet -hierarchical *dataflow_sel*]
# 🔴 [2026-08-11 与 R1 同批补，欠账「新-5」] `PROJECT_RULES §4.z-bis` 要求
#   **每个 glob 都要配计数断言，且断言红必须 fail-closed**。这条 glob 此前只在
#   「一个都没匹到」时打 `SDC-WARN`，**匹多了完全无声** —— 而它干的是 `set_case_analysis`
#   （把脚钉成常量、直接剪掉逻辑锥），比多周期放宽更狠：多钉一个寄存器 =
#   悄悄剪掉一片本该计时的逻辑，Fmax 会**变好看**，而没有任何东西变红。
#   本文件上方 :73-75 的注释自陈过这条 glob 的**同族前科**（原 glob 只钉到 cmd_decoder
#   暂存寄存器，tile 控制器内的锁存位一直没被钉住，直到 2026-07-21 审计才发现）。
# 实测期望（A7VT `1_synth.sdc` 展开件）：恰好 1 个 = `u_cmd_decoder.reg_dataflow_sel$_DFFE_PN0P_`。
#   （tile 控制器内的 `tile_desc_active[16]` 那一位走下方**另一段**独立的 pin-down，不计入本条。）
set DF_EXPECT 1
if { [llength $df_cells] != $DF_EXPECT } {
  error "SDC-ERROR: dataflow_sel case_analysis 覆盖面漂移：匹到 [llength $df_cells] 个，期望 $DF_EXPECT（$df_cells）-> set_case_analysis 会把脚钉成常量、剪掉逻辑锥；多钉/少钉都会静默改变 Fmax。必须先查清新出现/消失的是哪个寄存器再改 DF_EXPECT。见 PROJECT_RULES §4.z-bis 与 §4.z-sexies。"
}
if {[llength $df_cells] == 0} {
  puts "SDC-WARN: no *dataflow_sel* register matched -> WS psum NOT pruned."
} else {
  puts "SDC-INFO: set_case_analysis (OS pin-down, polarity-aware) on: $df_cells"
  foreach dfc $df_cells {
    set qpins [get_pins -quiet -of_objects $dfc -filter {direction == output}]
    foreach qpin $qpins {
      # LOCAL FIX 2026-07-12（审计 blocker）：ASAP7 SEQ 库 DFF 仅有 QN 输出
      # （QN = !存储值）。钉 OS（dataflow_sel=0）时 QN 必须钉 1；
      # 旧写法对任意 output pin 一律钉 0，在 QN-only 库上把模式钉反成 WS。
      if {[string match {*QN} [get_property $qpin full_name]]} {
        set_case_analysis 1 $qpin
        puts "SDC-INFO:   QN pin [get_property $qpin full_name] -> case 1 (=dataflow_sel 0, OS)"
      } else {
        set_case_analysis 0 $qpin
        puts "SDC-INFO:   Q pin [get_property $qpin full_name] -> case 0 (OS)"
      }
    }
  }
}

# ---- Quasi-static per-tile control MULTICYCLE (launch side only, -from) ------
# [LOCAL FIX 2026-07-21] tile_desc_q 39-bit 家族全覆盖（此前只盖 6/39 bit）。
# yosys 按 wire alias 给 flop 拆名（Q0 与 pe_top 两网表实证）：
#   mode_q[3:0] + sparse_mode_q[1:0]   (6)  — 原有覆盖
#   k_total_q[15:0]                   (16)  — Q0 实测临界路径发射端（5408.56ps）
#   tile_desc_active[15:0]            (16)  — 其余描述符位（epoch/out_*/exec 等）
# 🔴 tile_desc_active[16] = dataflow_sel：锁存后第 1 拍即被架构性消费
#   （wgt_advance mux，tensor_external_modules.sv:870）→ 绝不 MCP。
#   它改走下方 OS pin-down（case_analysis）——补全 headline OS 口径：原
#   *dataflow_sel* glob 只钉到 cmd_decoder 暂存寄存器，常量不穿 desc queue
#   时序元件，tile 控制器内的锁存位一直没被钉住（2026-07-21 审计发现）。
# ⚠️ 严禁宽 glob：*k_total*（无 _q）会扫进 cmd_decoder 的 reg_k_total[*]
#   （MMIO 暂存，min_first_use=1 拍）；*tile_desc* 会扫进 tile_desc_scan_q。
# 有效性条件（存档，对抗验证 2026-07-21）：OS 执行 + ST_LOAD_WEIGHT=16 拍 +
#   ST_CLEAR_ACC=1 拍结构不变 → 全家族首次架构性消费 = 锁存后第 18 拍，
#   -setup 4 余量 14 拍。WS 口径或流水缩短必须重推导（mode_q 与
#   tile_desc_active[0] 存在 WS 第 1-2 拍消费窗）——合作方双模式重签不可照抄。
# =============================================================================
# 🔴🔴 [R1 FIX 2026-08-11 · 裁决 D-R1-MCP-2026-08-11] 宽 glob ⇒ **结构性精确匹配**
#
# 病历（**这一段本身就是「静默耦合族」的标本**，族定义与铁律 = PROJECT_RULES §4.z-sexies）：
#   · 2026-07-23 写下时它是**对的** —— m1t_adder/m1t_base 实测 `mode_q family=6`，零 SDC-ERROR。
#   · 2026-07-24 C6 流水寄存器 `c6_mode_q` 落地那一刻（`m1t_c6_synth.log` 第一条 1030），
#     宽 glob `*mode_q*` 从 6 个变成 **1030 个** —— 多收 1024 个
#     `u_mac_array/gen_row[R].gen_col[C].u_mac/c6_mode_q[b]`。它们是**逐拍消费**的流水
#     寄存器，根本不是准静态，却白拿了 `-setup 4`。
#   · 代价实测（零 P&R 对照，技术记录 §11）：**278.25 ps** 假余量 = 610.94 vs 522.18 MHz。
#   · 🔴 本段**自己打印过** `SDC-ERROR ... Audit before trusting Fmax` —— 但那是 `puts`，
#     流程照常跑完 ⇒ 错误以「一个看起来完全正常的数字」活了 18 天、污染 9 张网表。
#     **改动本身正确，静默作废了别处的前提，没有任何闸变红。**
#
# 修法三件，缺一不可：
#   ①【致命化】计数不符从 `puts` 改 `error`。cmdproof 已在真工具上验过正反控
#      （`aichip_run_logs/b58_sdcerr_cmdproof_20260811.log`）：OpenSTA `include_file` 的
#      `sta_continue_on_error` 缺省 0（`tcl/Util.tcl:377`）且 ORFS 不覆盖
#      ⇒ SDC 里的 `error` 会中断整份 SDC、让 `read_sdc` 抛错、进程退出码 1。
#   ②【锚在结构上】用层级前缀 `u_tile_controller/` 圈范围，而**不是**往名字黑名单里再加一条。
#      原 `*err_mode_q*` 黑名单已删 —— 黑名单对**新出现的名字**永远是瞎的，c6_mode_q 就是这么进来的。
#   ③【白名单 + 反向闸】叶名必须落在显式家族表里否则 error；且收窄后 c6_mode_q 命中数必须为 0，
#      并配**非零正控**（否则反向闸会因为「根本没找到 c6」而恒绿）。
#
# 🔴 为什么用 `get_full_name` + `string match`，而不是 `get_cells {u_tile_controller/mode_q*}`：
#   后者的**层级前缀 glob 语义未在本工具链上实测**。而「`-hierarchical <叶名 glob>` 收集」与
#   「`get_full_name` 取全名」两个原语在本文件里**都已有在跑的实证** ⇒ 本修法零新 EDA 语义。
#   名字形态实测（`1_synth.sdc` 展开件，A7VT）：
#     u_tile_controller/mode_q[0]$_DFFE_PN0P_                            ← 目标
#     u_mac_array/gen_row[0].gen_col[0].u_mac/c6_mode_q[0]$_DFFE_PN0P_   ← 必须排除
# =============================================================================
set QS_SCOPE {u_tile_controller/*}
# 家族白名单与期望计数。🔴 改这张表 = 改口径，必须同批给出有效性推导（见上方"有效性条件"）。
#   位序依据 `tensor_pkg.sv` 的 `tile_descriptor_t`（39 bit，LSB 在下）：
#     sparse_compress_en=0 · epoch=1..8 · ofu_round=9 · out_fmt=10..11 · out_class=12..13
#     · exec_class=14..15 · dataflow_sel=16 · sparse_mode=17..18 · k_total=19..34 · mode=35..38
#   yosys 按 wire alias 拆名 ⇒ 17..38 那段另起名 sparse_mode_q/k_total_q/mode_q，
#   0..16 留在 tile_desc_active[*]；bit16=dataflow_sel 走下方 OS pin-down ⇒ 期望 16。
# 🔴 2026-08-14 位序订正（3a-3 把 `n_cfg` 插进 `tile_descriptor_t`，39b -> **41b**）：
#   真实位序（`AI_Chip/Tensor/tensor_pkg.sv` 的 packed struct，首成员 = MSB）=
#     mode[40:37] · k_total[36:21] · sparse_mode[20:19] · **n_cfg[18:17]** · dataflow_sel[16] · 其余[15:0]
#   🔴 `n_cfg` 插在 `dataflow_sel` **之上** ⇒ bit0..16 逐位未动 ⇒ 下面 `bit == 16` 仍钉对 dataflow_sel。
#   **这是运气不是设计**：字段若排在 dataflow_sel 之下，pin-down 会把稀疏配置位钉成常量、
#   同时放走真正的 OS 选择器，而 tda16 只数个数（仍 1）⇒ **靠计数闸兜底，没有名字级断言**。
#   （已登记为欠账：应加一条从 tensor_pkg.sv 读字段序、断言 dataflow_sel 偏移 == 16 的零机时闸。）
# 🔴 `n_cfg_q` 今天期望 **0**（Tensor RTL 里还没有它；n_cfg 目前只在 AI_Chip/IBEX_SRAM 侧）。
#   写 0 而不是"以后自动收进来"是**有意的**：3a-4/3a-5 接活那天它会让本段 error，
#   逼出一份有效性推导 —— **"自动收进来"正是 c6_mode_q 犯的那个错。**
# 🔴 2026-08-14：`n_cfg_q` 0 -> **2**（3a-3 把 n_cfg 加进 tile_descriptor_t，39b->41b）。
#   绊线如期开火并逼出了推导（见下面 §有效性推导）。**但它被分流出 MCP**（见收集循环里的注释）
#   ⇒ `qs_cells` 仍是 38，展开进 write_sdc 的家族键**不变** ⇒ `mcp_class()` 仍判 **v2**。
array set QS_EXPECT {mode_q 4 sparse_mode_q 2 k_total_q 16 tile_desc_active 16 n_cfg_q 2}

set qs_cells    {}
set tda16_cells {}
set ncfg_cells  {}
set qs_alien    {}
foreach f [array names QS_EXPECT] { set QS_GOT($f) 0 }

foreach g {*mode_q* *k_total_q* *tile_desc_active* *n_cfg_q*} {
  foreach c [get_cells -quiet -hierarchical $g] {
    set fn [get_full_name $c]
    if { ![string match $QS_SCOPE $fn] } continue
    set leaf [lindex [split $fn /] end]
    regsub {\$.*}        $leaf {} base
    regsub {\[[0-9]+\]$} $base {} base
    set bit -1
    if { [regexp {\[([0-9]+)\]\$} $leaf -> b] } { set bit $b }
    if { ![info exists QS_EXPECT($base)] } { lappend qs_alien $fn ; continue }
    if { $base eq "tile_desc_active" && $bit == 16 } { lappend tda16_cells $c ; continue }
    # =========================================================================
    # 🔴🔴 2026-08-14 `n_cfg_q`：**登记进白名单（让漂移闸过），但【分流出 MCP】**
    #
    #   3a-3 把 `n_cfg` 加进 `tile_descriptor_t`（39b→41b），于是 `n_cfg_q` 出现在网表里，
    #   :140-142 那条**预先埋好的绊线**如期开火（`n_cfg_q=2/0`）。它要的是一份有效性推导。
    #
    #   **推导做了，结论是「可以 MCP」**（首次架构性消费在锁存后第 17-18 拍，余量 ~14 拍，
    #   见下面 §有效性推导）。**但我们仍然【不给】它 MCP**，两条理由都不是时序：
    #
    #   ① 🔴 **口径可比性**：`b58_mcp_frozen_gate.mcp_class()` 的 `V2_FAMS` 是
    #      {mode_q, sparse_mode_q, k_total_q, tile_desc_active}。把 `n_cfg_q` 放进
    #      `qs_cells` ⇒ 展开进 `write_sdc` 的家族多一个键 ⇒ 该函数返回 **`unknown`**
    #      ⇒ 判决器 `G-SDCVER-HARD` fail-closed ⇒ 新臂的数**不能与丙/VR1/b56v2 并列**。
    #      而「把 n_cfg_q 塞进 V2_FAMS」是**更坏**的修法：那等于宣布「35 条的 v2」与
    #      「37 条的 v2」是同一口径，会让 `G-SDCVER-HARD` **静默放行一次真正的跨口径比较**
    #      —— 与 R1 的病根逐字同形（该文件 :87-89 自己写着「都干净 ≠ 可并列比较」）。
    #
    #   ② 🔴 **测量有效性**：`n_cfg_q` 的两条扇出锥（`k_step`@controller:446、
    #      `drain_limit`@:597）**正是 3a 往数据通路里加的那块硬件**。给它们 `-setup 4`
    #      等于**把本臂要测的新增代价从 setup 检查里豁免掉** ——
    #      而「甲 − 丙 = K1b + 3a 合计值」正是实验矩阵要量的那个数。
    #      不豁免 ⇒ 量到的是 3a 的**全额**代价。**这是更诚实的测量。**
    #
    #   ⇒ 代价 = 两个控制寄存器不放宽。它们不在临界路径上（本文件 :89 记着发射端是
    #     `k_total_q`；丙的实测绑定路径终点也在 `acc_*_reg` 族）。
    #   🔴 **要改回「给它 MCP」，必须同批**：`mcp_class()` 新立一类（**不许并进 v2**）+
    #     全部基线重打标 + `b58_sdc_tcldry.tcl` 的三处硬写 + 各臂判据的 `JUDGE-REQUIRE`。
    # =========================================================================
    if { $base eq "n_cfg_q" } { lappend ncfg_cells $c ; incr QS_GOT($base) ; continue }
    lappend qs_cells $c ; incr QS_GOT($base)
  }
}

# ---- 闸① 家族计数（白名单）：不符 ⇒ **error**（2026-08-11 前是 puts，这就是病根）----
set qs_bad {}
foreach f [lsort [array names QS_EXPECT]] {
  if { $QS_GOT($f) != $QS_EXPECT($f) } { lappend qs_bad "$f=$QS_GOT($f)/$QS_EXPECT($f)" }
}
if { [llength $tda16_cells] != 1 } { lappend qs_bad "tda16=[llength $tda16_cells]/1" }
if { [llength $qs_alien] != 0 } {
  lappend qs_bad "未登记叶名 [llength $qs_alien] 个(如 [lindex $qs_alien 0])"
}
if { [llength $qs_bad] != 0 } {
  error "SDC-ERROR: quasi-static family drift: [join $qs_bad { }] (scope=$QS_SCOPE) -> 网表命名或家族构成变了，覆盖面已不是设计时的样子。必须先重做有效性推导再改 QS_EXPECT；在此之前 Fmax 不可信。见 PROJECT_RULES §8 D-R1-MCP-2026-08-11 与 §4.z-sexies。"
}

# ---- 闸② 反向闸 G-QS-NOC6：收窄后不许再有 C6 流水寄存器（配非零正控）----
# 🔴 正控刻意用 `get_cells -hierarchical`（而不是 R1 探针那条 `get_pins -hierarchical {*/D}`）：
#   后者只在 **post-route** 上验过，而本段跑在 **synth** 阶段 —— 拿一个在别的阶段验过的
#   原语当正控，正是「口径混排藏在一条闸里」（PROJECT_RULES §4.w-quater）。
#   `get_cells -hierarchical *c6_mode_q*` 则是本文件在 synth 阶段**天天在跑**的那条。
# 🔴 这个数**只能当"非零"用，不是触发器计数**，别拿去当规模数引用。
#   🔴 **它随流程阶段变**（2026-08-11 实测两个阶段都量过）：
#     · **synth 阶段（本段跑的地方）**：`1024` —— 此时 TIE 伴生单元还没出现
#     · **post-route**（R1 探针量的地方）：`2048` = flop 1024 + 同名 TIEHIx1 伴生 1024
#   本段第一稿的注解只写了 post-route 的 2048，那是**拿别的阶段的数注解本阶段的闸**
#   —— 与 R1 勘误 E-1 同一个错（引用前作必须登记前作的流程阶段，PROJECT_RULES §4.w-quater）。
#   闸本身不受影响（它只要求 > 0），但注解已订正。
set n_c6    [llength [get_cells -quiet -hierarchical *c6_mode_q*]]
set n_c6_in 0
foreach c $qs_cells { if { [string match {*c6_mode_q*} [get_full_name $c]] } { incr n_c6_in } }
# =============================================================================
# 🔴 2026-08-14 —— 正控改为**声明制**（`PROJECT_RULES §4.w-sexies` 的 B58_SCU_EXPECT 同型）
#
# **为什么**：候选刀 **K1c-A**（把 `unique case (mode)` mux 挪到 c6 秩上游）会**删掉
#   `c6_mode_q` 这个寄存器**。届时本正控 `n_c6 == 0` 直接 `error`，而 OpenSTA 的
#   `sta_continue_on_error` 缺省 0 ⇒ **read_sdc 抛错、整趟 P&R 在第一小时全废**。
#   （Step 3 发刀前 114-agent 审查的 F2；全案 = 交接 §12.1。）
#
# 🔴 **修法不是删闸** —— 删了就正是本闸自己那句「是闸瞎了，不是设计干净了」。
#   改为：默认（未声明）**行为逐字不变**；声明 K1c-A 已落地时**换锚**，
#   且锚由调用方显式给出（本文件**不猜**一个还不存在的设计里对象叫什么），
#   并配**反控**（声明落地却仍有 c6_mode_q ⇒ 判红，说明刀没真落地）。
# =============================================================================
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

if { [llength $qs_cells] == 0 } {
  error "SDC-ERROR: no quasi-static regs matched -> Fmax will be under-reported."
}
puts "SDC-INFO: multicycling [llength $qs_cells] quasi-static control regs (mode_q family=[expr {$QS_GOT(mode_q)+$QS_GOT(sparse_mode_q)}] k_total_q=$QS_GOT(k_total_q) tile_desc_active excl bit16=$QS_GOT(tile_desc_active) n_cfg_q=$QS_GOT(n_cfg_q)): $qs_cells"
# 🔴🔴 `-setup` 与 `-hold` **同去同留**：只撤 setup 留 `-hold 3` ⇒ hold required 提前 3 拍
#   ⇒ hold 检查近乎恒过、整片吞掉真违例，**而且不会有任何东西变红**（`PathEnd.cc:803-808`）。
#   hold 正是本战役当前的卡点 ⇒ 这是灾难级操作错误。
set_multicycle_path -setup 4 -from $qs_cells
set_multicycle_path -hold  3 -from $qs_cells
# 🔴 供下游 G-MCP-FROZEN 比对：本行是**活体计数**；真正治理 floorplan..signoff 的却是
#   `write_sdc` 展开出的 `1_synth.sdc`（**冻结名单**）。两者之间隔着 `eliminate_dead_logic`
#   —— 08-11 实测差 3 个（tile_desc_active bit 0/14/15 被判死）。这是铁律形状④，
#   所以名单必须在**它真正治理的那份产物上**再被检一次。
puts "SDC-QSCOUNT [llength $qs_cells]"
# 🔴 分流披露：n_cfg_q 在白名单里但**不进 MCP**（理由见收集循环处）。下游解析器看到的
#   `set_multicycle_path -from` 列表里没有它 ⇒ mcp_class() 的家族键不变 ⇒ 口径仍是 v2。
puts "SDC-NCFG-DIVERTED [llength $ncfg_cells] (whitelisted, NOT multicycled)"
if { [llength $ncfg_cells] != $QS_EXPECT(n_cfg_q) } {
  error "SDC-ERROR: n_cfg_q 分流数 [llength $ncfg_cells] != 期望 $QS_EXPECT(n_cfg_q) —— 分流逻辑失效"
}
# 🔴 反控：分流件绝不许出现在 MCP 列表里（防有人把 continue 删了而没人变红）
foreach _nc $ncfg_cells {
  if { [lsearch -exact $qs_cells $_nc] >= 0 } {
    error "SDC-ERROR: n_cfg_q 同时出现在 qs_cells 里 ⇒ 分流失效，口径会从 v2 掉成 unknown"
  }
}
# tile_desc_active[16]（tile 控制器内 dataflow_sel 锁存位）：极性感知 OS pin-down。
foreach dfc $tda16_cells {
  foreach qpin [get_pins -quiet -of_objects $dfc -filter {direction == output}] {
    if {[string match {*QN} [get_property $qpin full_name]]} {
      set_case_analysis 1 $qpin
      puts "SDC-INFO: OS pin-down tile_desc_active\[16\] QN [get_property $qpin full_name] -> case 1 (=dataflow_sel 0, OS)"
    } else {
      set_case_analysis 0 $qpin
      puts "SDC-INFO: OS pin-down tile_desc_active\[16\] Q [get_property $qpin full_name] -> case 0 (OS)"
    }
  }
}

# =============================================================================
# DO NOT MULTICYCLE / DO NOT FALSE_PATH (true per-cycle; P&R buffers them):
#   issue_en/mac_en, array_step_en, clear_acc, capture_fire, active_tail_mask,
#   weight_load(_eff), mx_scale_tick, dense_k_cursor_q, systolic streams,
#   acc_mant_reg recursion (the real compute path). See sky130 template.
# =============================================================================

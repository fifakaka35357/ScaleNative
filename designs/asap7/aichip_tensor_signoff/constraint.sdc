# =============================================================================
# 🔴🔴 [2026-09-02 · 欠账 #58 同批 · `D-R1-MCP-2026-08-11` 的 OPEN 名单] 本文件的
#   全部 `puts "SDC-ERROR..."` 已改为 `error`（fail-closed）。
#
#   **为什么**：`puts` 版本让「覆盖面已经不是设计时的样子」这件事**只在日志里留一行、
#   流程照跑 rc=0** —— 2026-09-02 在 `asap7/aichip_pe_top` 上实付了一次：
#   `#31` 同步产品 RTL 后 `c6_mode_q` 进入网表，宽 glob `*mode_q*` 从命中 6 变成 **1030**，
#   于是 `set_multicycle_path -setup 4` 被施加在 **1062** 个寄存器上（其中 1024 个是**逐拍
#   消费**的流水寄存器）⇒ **Fmax 必然虚高**，而 `make` 全程 rc=0、没有任何东西变红。
#
#   工具语义已在真工具上验过（`aichip_run_logs/b58_sdcerr_cmdproof_20260811.log`，以及
#   2026-09-02 pe_top 上的正反控 `petop_58fix_rehearsal_{pos,neg}_20260902.log`）：
#   SDC 里的 `error` 会中断整份 SDC、`read_sdc` 抛错、`make` 退出码非 0。
#
# 🔴 **本文件的宽 glob【尚未】收窄** —— 只做了致命化。
#   收窄需要**本设计自己的网表**来定家族期望值（`QS_EXPECT`），而本设计在盘**没有
#   `1_synth.sdc` / `1_2_yosys.v`**（2026-09-02 核过）。按「代号别推断，去它的家读」，
#   不许照抄别的设计的数当本设计的期望值。
#   ⇒ 已完成的参考实现（**都是在各自的真网表上验过的**）：
#       · tile 顶层（`tensor_unit_top`）= `asap7/m1_tensor_1670.sdc`（结构锚 `u_tile_controller/*`）
#       · pe_top 顶层                   = `asap7/aichip_pe_top/constraint.sdc`（锚 `*u_tile_controller/*`）
#     照搬时**必须先在本设计的真网表上重新数一遍家族**，并配正反控。
#
# 🔴 **本次改动的直接后果（有意）**：若本设计的网表已含 `c6_mode_q`，计数断言会当场
#   `error`、`read_sdc` 抛错、这趟 P&R 在第一步就停。**这是正确结果** ——
#   它的替代品是「跑完 19 小时、拿到一个虚高的 Fmax、没人知道」。
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
set clk_period    20000
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
set qs_cells {}
set n_mode 0
foreach c [get_cells -quiet -hierarchical *mode_q*] {
  if {[string match {*err_mode_q*} [get_name $c]]} continue
  lappend qs_cells $c ; incr n_mode
}
set n_kt 0
foreach c [get_cells -quiet -hierarchical *k_total_q*] {
  lappend qs_cells $c ; incr n_kt
}
set n_tda 0
set tda16_cells {}
foreach c [get_cells -quiet -hierarchical *tile_desc_active*] {
  if {[string match {*tile_desc_active\[16\]*} [get_full_name $c]]} {
    lappend tda16_cells $c ; continue
  }
  lappend qs_cells $c ; incr n_tda
}
if { $n_mode != 6 || $n_kt != 16 || $n_tda != 16 || [llength $tda16_cells] != 1 } {
  error "SDC-ERROR: quasi-static family count mismatch: mode_q=$n_mode/6 k_total_q=$n_kt/16 tile_desc_active(!16)=$n_tda/16 tda16=[llength $tda16_cells]/1 -> netlist naming drifted; coverage NOT as designed. Audit before trusting Fmax."
}
if {[llength $qs_cells] == 0} {
  error "SDC-ERROR: no quasi-static regs matched -> Fmax will be under-reported."
} else {
  puts "SDC-INFO: multicycling [llength $qs_cells] quasi-static control regs (mode_q family=$n_mode k_total_q=$n_kt tile_desc_active excl bit16=$n_tda): $qs_cells"
  set_multicycle_path -setup 4 -from $qs_cells
  set_multicycle_path -hold  3 -from $qs_cells
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

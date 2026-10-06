# =============================================================================
# 🔴 v2 fork（2026-08-16）—— **只给移基座之后的臂用**（甲 K1BV2 / 乙 K1BVT）。
#   原件 `m1t_b58base/b58_caliber_align.tcl` 头注写着「落盘后不再原地编辑」，
#   且它被 A0 / A0V2(丙) 共用 ⇒ **不原地改**，fork 出本件。**老臂行为逐字不变。**
#
# 唯一差异 = `sq` 锚为 0 时的处置：
#   原件：`if { $n_sq == 0 || $n_out == 0 } { exit 91 }` —— 无条件红。
#   3a 把 `tensor_sparse_ingress_queue` 退役了（S2 删文件、S4 删外部端口），
#   产品 HEAD 的 `tensor_mac_array.sv` **不再实例化**它 ⇒ **新基座臂的 sq 必然 = 0**。
#   实测：甲跑到 CTS 段撞 `exit 91`（`[B58] G-HOOK 命中: sq=0 all_outputs=2002`）。
#
# 🔴 这是**同一个假设的第三份拷贝**：
#     ① `b58_sta_signoff.tcl:140`（测量侧）—— 2026-08-14 已改为声明制
#     ② 本件（**实现侧**）—— 当时漏了，代价 = 甲跑到第 1.9 h 才红
#     ③ `m1_tensor_1670.sdc` 的 QS/pin-down 段（另一个锚，不同事）
#   在盘 `b58_scu_assumption_scan.py` 守的是 **SCU** 假设，对 `sq` 假设**结构性失明**。
#
# 修法（与测量侧同构，**不是放宽**）：sq 为 0 **只在显式声明时**放行，
#   并打一行说明「结构性不适用」而非「被跳过」；未声明仍 `exit 91`。
#   声明口 = 环境变量 `B58_SQ_ABSENT_OK=1`，由发射件在
#   `ANCHOR_EXPECT` 以 `0,` 开头（= 已预登记 sq=0）时导出 ⇒ **与判据同一个事实源**。
#
# 🔴 口径影响：**没有**。原件对 50 个队列 cell 打 `set_false_path -from $sq`；
#   本件在 sq=0 时无路径可切 —— 两边的计时覆盖范围相同（那边切掉、这边不存在）。
# =============================================================================
# =============================================================================
# 批 5.8 —— 口径对齐（2026-08-08）。挂 PRE_CTS_TCL。**两臂共用**（A0 基线 / A1 K1b）。
#
# 🔴 与 `m1t_b56/b56_caliber_align_v2.tcl` 的关系（**口径继承声明**）：
#   F1/F2/F3 三条禁令、`max_fanout 32`、fail-closed 语义、逐个 `get_full_name` 的写法
#   **全部逐字沿用**。只做**一处**改动，且该改动是被迫的：
#
#   🔴 **删掉 SCU 锚**（`set scu [get_cells *u_weight_scu*]` + 它的 fail-closed 条件
#      + 它的 `set_false_path -from $scu`）。
#      **原因**：`sparsity_compression_unit` 已于 2026-08-01（ORFS 仓 `a3df7eef6`）
#      从镜像与 `VERILOG_FILES` 中删除 —— 在盘理由是「**已证明是恒等变换
#      （压错轴 + scatter 是逆映射）**」，经六员对抗核查 + 用户逐点拍板。
#      ⇒ 在 post-SCU 基座上 `n_scu` 恒为 0，沿用 v2 会在此 `exit 91`（实测结论，非推测）。
#
#   🔴 **口径变更声明（不得省略）**：基线 `m1t_b56` 的部署口径**排除了 9539 个 SCU cell**
#      的路径（一手证据：`[B56] G-HOOK 命中: sq=50 scu=9539 all_outputs=2003`）。
#      本口径没有这一条 —— **因为那些 cell 已不存在，不是因为改了尺**。
#      ⇒ 与 `591.20 MHz` 的可比性**不是自动成立的**，判读须按判据
#        `aichip_run_logs/b58_twoarm_prereg_20260808.md §3` 走（两臂内部可比是硬保证，
#        跨到 b56 的比较只作参考且必须带口径标签）。
#
#   🔴 **F1 仍然生效**：实现侧**绝不** `set_false_path -from [all_inputs]`
#      —— 那会停掉输入喂寄存器的 hold 修复（setup 修不好只是慢；hold 修不好芯片不工作且不可修）。
#      探针侧有 `-from [all_inputs]` 是**另一回事**（只读报告的口径定义），两者不得混为一谈。
#
# 🔴 落盘后不再原地编辑（PROJECT_RULES §1.1）。
# =============================================================================
# ---- 保留 max_fanout（不保留会混淆实验：批2起全链都带它）----
set_max_fanout 32 [current_design]
puts "\[B58\] set_max_fanout 32 applied (自批2起全链继承)"

# ---- 口径对齐 ----
set sq   [get_cells -hierarchical {*u_sparse_ingress_queue*} -quiet]
set outs [all_outputs]
set n_sq  [llength $sq]
set n_out [llength $outs]
# 🔴 SCU 已删 ⇒ 这里**主动核对它确实为 0**，把"预期的缺席"变成可见记录，
#    而不是让后来者靠猜。若某天它又出现，本行会立刻暴露基座变了。
set scu_probe [get_cells -hierarchical {*u_weight_scu*} -quiet]
puts "\[B58\] G-HOOK 命中: sq=$n_sq all_outputs=$n_out  (scu=[llength $scu_probe] 预期 0，已于 a3df7eef6 删除)"

# 🔴 G-HOOK fail-closed：任一必需锚为 0 即中止（防"钩子跑了但没命中"）
if { $n_out == 0 } {
    puts "\[B58\] G-HOOK FAIL —— all_outputs 命中 0，口径对齐未落上，fail-closed"
    exit 91
}
if { $n_sq == 0 } {
    if { [info exists ::env(B58_SQ_ABSENT_OK)] && $::env(B58_SQ_ABSENT_OK) eq "1" } {
        puts "\[B58\] G-HOOK sq=0，但已显式声明 B58_SQ_ABSENT_OK=1（判据预登记 ANCHOR_EXPECT 以 0 开头）"
        puts "\[B58\] 🔴 ⇒ 本臂网表里没有 sparse ingress queue（3a 退役），`set_false_path -from \$sq`"
        puts "\[B58\] 🔴   **结构性不适用**，不是被跳过。与 sq>0 的臂计时覆盖范围相同。"
    } else {
        puts "\[B58\] G-HOOK FAIL —— sq 锚命中 0 且未声明 B58_SQ_ABSENT_OK=1，fail-closed"
        puts "\[B58\] 🔴 若本臂结构上就没有该队列，请在臂表用 ANCHOR_EXPECT=0,<outs>,<ins> 预登记"
        exit 91
    }
}
# 🔴 反向 fail-closed：SCU 若"复活"，说明基座不是 post-SCU，两臂口径前提失效
if { [llength $scu_probe] != 0 } {
    puts "\[B58\] G-HOOK FAIL —— scu 命中 [llength $scu_probe]，但本口径件是为 post-SCU 基座写的"
    exit 92
}
# 🔴 get_full_name 收【单个对象】，传集合会 STA-2204 "is not an object"（v1 实付）。逐个取。
set i 0
foreach c $sq { if {$i<2} { puts "\[B58\] G-HOOK 样例 sq : [get_full_name $c]" ; incr i } }
# 🔴 2026-08-22（欠账 #18）：**声称必须与施加同源** —— 原 :94 无条件写「false_path from sq」，而施加被 :92 守住。
if { $n_sq > 0 } { set_false_path -from $sq ; set _sqclaim "false_path from sq（$n_sq 个）" } else { set _sqclaim "🔴 **未施加** false_path from sq（sq=0 ⇒ 结构性不适用，见上方 G-HOOK 段）" }
set_false_path -setup -to $outs
puts "\[B58\] 口径对齐已施加: $_sqclaim + **-setup only** to all_outputs"
puts "\[B58\] 🔴 未施加 -from \[all_inputs\]（禁令 F1：hold 不可修，风险不对称）"
puts "\[B58\] 🔴 未施加 from scu（SCU 已删，不是放宽口径）"
puts "\[B58\] CALIBER-ALIGN-APPLIED sq=$n_sq"

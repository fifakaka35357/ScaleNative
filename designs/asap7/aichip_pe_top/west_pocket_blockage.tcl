# =============================================================================
# [2026-07-21] A7 pe_top R4a 探针轮：西缘口袋 SOFT placement blockage。
# 挂载点：POST_MACRO_PLACE_TCL（RTLMP 之后、写 2_2 odb 之前 → blockage 随 odb
# 持久化流入 GP）。
#
# 根因（R3a/b 取证 + sha1 三方对照，2026-07-21 审查钉死）：
#   GP（GPL_TIMING_DRIVEN=0，确定性）把 i_ibex cs_registers_i 团块压进 die 最
#   西缘口袋（热点 x<31µm、y≈399-472µm；congestion.rpt 99.8% 违例含 CSR 网）
#   → GRT 11696 溢出 GRT-0115 带病放行 → DRT 5.3 万违例平台，两轮 (10ns/12ns)
#   GP odb sha1 逐位相同 = 同网表确定性死亡，退钟/重跑无效。
#   绿基线 R2（网表差仅 +0.09%）CSR 落南缘 → GRT 0/0/0、DRC=0。
#
# 修法 = PROJECT_RULES §3.4/§3.4a：必须 SOFT（GPL 挡住成片铺 cell / DPL 放行
#   中继与合法化 / check_placement 不炸；硬 blockage 会 DPL-0033/0036 崩 3_5）。
# 几何：x∈[2,40]µm × y∈[250,660]µm —— 覆盖西缘宏 halo 墙之间的整个口袋
#   （绿基线宏几何实测：西缘三列宏 +halo15 在 y≈2-248 与 y≈661-907 全封，
#    中段 y≈248-661 是西端靠 die 边封死的口袋，R3 热点带 y399-472 在其中心）。
#   面积 15.6kµm² ≈ movable 的 3%，代价可忽略。
# 单变量纪律：本轮只加此 blockage；pad/halo/DIE/SDC 周期全部不动（对照 R3b）。
# =============================================================================
# [R4a→R4b 退火]  x[2,40]：CSR 质心 12→54.7µm，死亡签名消除但 39% 残留挤墙边 x=40。
# ✅ x[2,64]（当前）：探针 PASS —— west(x<50)=0、zone=0、质心 75µm、bbox x≥64.2µm，
#   团块彻底清出西区死亡带。
# 🎉 GRT 实测确认（2026-07-21 19:26）：0/0/0 溢出、无 GRT-0115、wirelength 26.66M µm
#   （比 R2 里程碑 27.57M 还少）、do-grt rc=0。与 R2(0/0/0→DRC=0)同成功签名。
#   R3a/b 两轮失败的头号 blocker 攻克。日志=aichip_run_logs/a7_r4b_grt.log。
set block [ord::get_db_block]
set dbu [$block getDbUnitsPerMicron]
set bx0 [expr {int(2   * $dbu)}]
set by0 [expr {int(250 * $dbu)}]
set bx1 [expr {int(64  * $dbu)}]
set by1 [expr {int(660 * $dbu)}]
set bk [odb::dbBlockage_create $block $bx0 $by0 $bx1 $by1]
$bk setSoft
puts "R4A-INFO: west-pocket SOFT blockage created x\[2,64\]um y\[250,660\]um (dbu=$dbu)"

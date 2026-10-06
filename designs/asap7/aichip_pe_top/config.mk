# =============================================================================
# AI_Chip full PE SoC — pe_top on ASAP7 (IBEX + Command Processor + L1/L2 +
# Tensor + Vector).  [2026-07-13]
#
# 目的：给论文一个【双 PDK 的 SoC 对照】。
#   sky130hd = 流片工艺（真 OpenRAM 宏 + 真 GDS）
#   ASAP7    = 先进节点投影（合成存储模型 fakeram7 + 空宏 footprint）
#
# ⚠️⚠️ 诚信口径（必须随任何 ASAP7 面积数字一起披露）：
#   1) fakeram7 是 ABKGroup FakeRAM2.0 的【合成模型】，不是 SRAM 编译器输出。
#      platforms/asap7/fakeram.cfg:6 逐字写着 "#SAMPLE INPUT FILE; VALUES NOT REALISTIC"。
#   2) fakeram7 【没有 GDS】—— platforms/asap7/config.mk:217 `GDS_ALLOW_EMPTY ?= fakeram.*`，
#      platforms/asap7/gds/ 下一个 fakeram GDS 都没有。**最终 GDS 里 SRAM 的位置是空洞。**
#      route DRC（TritonRoute 读 LEF 抽象）仍然有效，但任何 GDS 层面的可制造性宣称都不成立。
#   3) 位密度：sky130 真 OpenRAM = 17.37 um²/bit；fakeram7 = 0.0429 um²/bit → SRAM 缩了 405×，
#      而同树实测的 logic 只缩 59-61× → **SRAM 比 logic 多缩 6.7 倍，这在物理上是反的**
#      （真实工艺里 SRAM 缩得比 logic 慢）。敏感度：若 SRAM 按 logic 速率缩，宏面积
#      0.030 -> 0.204 mm²，die 约 +50%。
#
# 宏数量：ASAP7 只有 256 深的 fakeram7，而本设计的逻辑 bank 是 512 深 →
#   ~~sram_1rw1r_wrapper.sv 的 ibex_asap7_sram_512x32 内部 bank 2 个 fakeram7_256x32~~
#   (addr[8] 选半区) -> ~~43 个逻辑 bank = 86 个物理宏~~。🔴 [D-SRAM-REAL-B 2026-09-03] 已作废：全部逻辑 bank 绑真宏 srambank_128x4x64 ⇒ **33 个物理宏**（L1I 1 + L1D 4 + Tensor 12 + L2 16），零 fakeram。
#   旁证：sky130 tensor 24 宏 -> asap7 48；sky130 l2 16 -> asap7 32（均为 2×）。
#
# 与 sky130 pe_top 的差异（其余全部相同）：
#   PLATFORM / VERILOG_DEFINES / SRAM 宏 LEF+LIB（无 GDS）/ SDC 时间单位 ns->ps /
#   宏摆放改用 RTLMP 自动（sky130 的 explicit-DIE + macro-grid tcl 在 ASAP7 上无意义：
#   宏小 810 倍、几何地板从 7448.86um 蒸发到 ~260um）
# =============================================================================
export PLATFORM           = asap7
export DESIGN_NAME        = pe_top
export DESIGN_NICKNAME    = aichip_pe_top

export SYNTH_HDL_FRONTEND = slang
export SYNTH_HIERARCHICAL  = 1
export VERILOG_DEFINES    = -D PDK_ASAP7
export VERILOG_TOP_PARAMS = SRAM_DEPTH 512

# [2026-07-14] ⚠️ 必须与 sky130 pe_top 对齐，否则双 PDK 面积不可比。
# sky130 的 designs/sky130hd/aichip_pe_top/config.mk 显式设了 `ADDER_MAP_FILE :=`（空），
# 关掉了 yosys 的加法器提取(EXTRACT_FA, SAT-based)与库加法器映射。
# 若 ASAP7 用平台默认(cells_adders_*.v)，两边综合出的网表结构不同 -> 面积对比是苹果比橘子。
# 实测代价：不关它，EXTRACT_FA 在 2.4M cell 的 pe_top 上跑 >55 分钟无进展（2026-07-14）。
export ADDER_MAP_FILE     :=

# [继承 sky130 pe_top] pe_top 里 90% 的 cell 是扁平 Tensor 阵列；A1 重捕获 mux 让
# dataflow_sel 扇出 +800。=1 时 sky130 实测 repair_design 45 小时死墙。=0 已在
# sky130（19分18秒）和 ASAP7 Tensor（15.5 分钟）双双验证。
export REMOVE_ABC_BUFFERS = 0

# --- SRAM 宏（Memory 波1 2026-07-22，分支 memory-wave1）---
#   L1I / L1D / Tensor operand → 真 ASAP7 SRAM 宏 srambank_128x4x64_6t122
#     （asap7_sram_0p0；真 LEF 16.0×77.76µm + 真 LIB 单角 0.7V/25C）= 摘掉 fakeram
#     的【分析模型/无 GDS 时序】折扣。17 真宏(L1I 1 + L1D 4 + Tensor 12)。
#   ~~L2（16 bank × 2）→ 仍 fakeram7_256x32（32 宏）；粒度 4× 问题 → 波2 1MiB Ring。~~ 🔴 [D-SRAM-REAL-B] L2 改为 16 × srambank_128x4x64（高 32 位 tie 0）；路 A（原生 512×32）因包里无 32 位宽 GDS 且不可派生而被否。
#   ⚠️ 诚信口径（随任何波1 面积/时序数字披露）：
#     - srambank LIB 是【单角 0.7V/25C TT】，非多角签核；min_period 弧字面为 0（未建模）
#       → 800MHz+ 频率上限不能引 lib 作证（见 ASAP7_Memory_Architecture_Design §1/§3.5）。
#     - ~~srambank GDS 顶层 cell 名=`srambank_128b` ≠ LEF 名 → streamout 前必须 klayout 改名~~
#       🔴 ▲订正（2026-08-04）：**改名早在 2026-07-26 就做完了，别再跑那条 klayout 命令。**
#       在用件 = third_party/asap7_sram_0p0/gds/srambank_128x4x64_6t122_renamed.gds
#       （GDS STRNAME 实测：112 个结构里"从未被任何 SREF/AREF 引用"的唯一一个 =
#        srambank_128x4x64_6t122，与 LEF MACRO / verilog module / 网表实名四方同名）。
#       🔴 srambank_128b.gds 是**改名前的原件、非在用件** —— 照旧文重跑 klayout 会在 gds/ 里
#       造出第三份文件并可能把 ADDITIONAL_GDS 指错。
#       现成配方在 designs/asap7/m1t_adder/config.mk:32-33（12 宏已端到端跑通，
#       logs/asap7/m1t_adder/base/6_1_merge.log 三条 INFO 全过，峰值 16.5 GB / 2:37.64）。
#     - L2 fakeram7 仍无 GDS + 分析模型（原口径不变）。
REAL_SRAM = $(FLOW_HOME)/../../../third_party/asap7_sram_0p0/generated
export ADDITIONAL_LEFS = $(PLATFORM_DIR)/lef/fakeram7_256x32.lef \
                         $(REAL_SRAM)/LEF/srambank_128x4x64_6t122.lef
export ADDITIONAL_LIBS = $(PLATFORM_DIR)/lib/NLDM/fakeram7_256x32.lib \
                         $(REAL_SRAM)/LIB/srambank_128x4x64_6t122.lib
# [M-SRAM-A7 2026-08-04] 真宏 GDS 接线（配方逐字照抄 designs/asap7/m1t_adder/config.mk:32-33，
#   那份已于 2026-07-26 10:34 在 12 宏上端到端跑通：6_1_merge.log 三条 INFO 全过、
#   峰值 16,524,968 KB、耗时 2:37.64、产物 6_final.gds 5,554,493,720 B）。
# 🔴 绝对路径：上面的 REAL_SRAM 指向 generated/（该目录【无】GDS），GDS 在其兄弟目录 gds/。
export ADDITIONAL_GDS += $(FLOW_HOME)/../../../third_party/asap7_sram_0p0/gds/srambank_128x4x64_6t122_renamed.gds
# 🔴 收窄：srambank 从 ALLOW_EMPTY 里除名（它现在真有 GDS 了；留着 = 把「GDS 没吃进去」
#   静默放行成空腔）。**fakeram.* 必须保留** —— L2 的 32 个 fakeram7_256x32 至今无 GDS。
#   收窄本身即红绿自证：若 ADDITIONAL_GDS 路径写错/文件缺失，6_1_merge 会当场报
#   「LEF Cell 'srambank_128x4x64_6t122' has no matching GDS/OAS cell」而不是静默空腔。
export GDS_ALLOW_EMPTY =

# --- 源码清单：与 sky130 pe_top 逐字相同（packages 优先；排除 SVA bind 文件）---
SRC      = $(DESIGN_HOME)/src/aichip_sv
PKGS     = $(SRC)/ibex/ibex_pkg.sv $(SRC)/IBEX_SRAM/pe_pkg.sv $(SRC)/Tensor/tensor_pkg.sv $(SRC)/Vector/vec_pkg.sv
ALLSV    = $(wildcard $(SRC)/ibex/*.sv) \
           $(wildcard $(SRC)/IBEX_SRAM/*.sv) $(wildcard $(SRC)/IBEX_SRAM/Memory_Subsystem/*.sv) \
           $(wildcard $(SRC)/Tensor/*.sv) \
           $(wildcard $(SRC)/Vector/*.sv) $(wildcard $(SRC)/Vector/Unchanged/Vector/*.sv)
# 🔴🔴 2026-09-01：filter-out 增列 %tensor_sparse_ingress_queue.sv
#   产品 RTL 在 `5aa8874 [3a-1 S2]` 已删该文件，3a-2 又把它依赖的三个类型连体除名；
#   镜像里那份是冻结基座时代的遗留（T1 按清单 cp，**拷贝在结构上无法表达「删除」**）。
#   本 config 用 $(wildcard $(SRC)/Tensor/*.sv) 吃整目录 ⇒ 必然吞进它 ⇒ elaborate 必死。
#   实测（2026-08-31 纯前端 read_slang）：rc=1 / wall 3 s / 7 errors，其中 3 条来自本文件。
#   🔴 **不删文件、只摘出综合面** —— 保留 aichip_tensor_signoff/config.mk:67 记的 A0 恢复路径。
export VERILOG_FILES = $(PKGS) \
           $(filter-out $(PKGS) %pe_assertions.sv %vec_assertions.sv %tensor_sparse_ingress_queue.sv,$(ALLSV)) \
           $(SRC)/ibex/syn/rtl/prim_clock_gating.v

export VERILOG_INCLUDE_DIRS = $(SRC)/ibex/vendor/lowrisc_ip/prim/rtl

export SDC_FILE = $(DESIGN_HOME)/$(PLATFORM)/$(DESIGN_NICKNAME)/constraint.sdc

# =============================================================================
# Floorplan：util-based + RTLMP 自动摆宏（不用 sky130 的 explicit DIE + grid tcl）
# 理由：ASAP7 的宏是 8.36 x 42.0 um（sky130 是 683.1 x 416.54，大 810 倍）；
#       ~~86 宏总面积仅 0.030 mm²，占 die 约 4%~~ 🔴 [2026-09-03] 现行 33 宏 = 41057.28 µm²，占 core 2.078%（换宏前 49 宏 = 32386.56 µm² / 1.639%）；
#       且 fakeram7 的 OBS 只挡 M1-M4，M5/M6/M7 可从宏上方穿过
#       （sky130 的宏挡 met1-met4，而 GRT 会把 met4 的 obs 抬到 met5
#        —— GlobalRouter.cpp:5081 `if (top_layer+1 == getMaxRoutingLayer()) top_layer++;`
#        sky130: 4+1==5(MAX) 命中 -> 宏上方 0 层；ASAP7: 4+1=5 != 7(MAX) 不命中 -> 3 层自由）
#       -> 宏在 ASAP7 上既不是面积瓶颈也不是布线瓶颈，几何网格失去意义。
# =============================================================================
export CORE_UTILIZATION   = 20
export CORE_ASPECT_RATIO  = 1
export CORE_MARGIN        = 2
export PLACE_DENSITY      = 0.40
# 宏 pin 全部在 M4（= MIN_CLK_ROUTING_LAYER）-> halo 需给 pin access 留空间。
# 已验证值：aichip_l2(6.3k cell/32 宏) halo=4；aichip_tensor_signoff(2.4M cell/48 宏) halo=15。
# pe_top（3.16M cell / ~~86~~ **33** 宏）两者都不覆盖 -> 先取 15（保守），后续可扫 4/8/15。
export MACRO_PLACE_HALO   = 15 15

# [Memory 波1 D5, 2026-07-22] 真宏 srambank 预置绕过 MPL Snapper（MPL-0005：多层 union
# bbox center vs RightWayOnGridOnly M3）。place_macro -exact 跳过 snapMacro + 置 LOCKED，
# ~~rtl_macro_placer 随后只摆 32 fakeram（跳过 fixed srambank）。~~ 🔴 [D-SRAM-REAL-B] 路 B 之后**没有 fakeram 可摆**：33 个宏全是 srambank、全被本 tcl 置 FIRM ⇒ MPL 提前 return（PROJECT_RULES §3 推论 2）。X≡9 mod 36nm 使 M3 stub 落 track。
# 🔴 布线 pin-access（M4/M5 shape off-grid）待 do-grt/do-drt 烟测验证。
export MACRO_PLACEMENT_TCL = $(DESIGN_HOME)/asap7/aichip_pe_top/manual_macro_place.tcl
# ▲ 2026-10-02 #286 P-Y（宏 Y −9 nm，白名单 {-9, 0}，只对原件 srambank LEF 成立）并入共用脚本 —— prereg soc600 §71；彩排 MERGE-PROOF-OK
export AICHIP_MACRO_Y_DY = -9

# --- P&R 病态驯化旋钮（D-TENSOR-PR 配方，PDK 无关）---
export GPL_TIMING_DRIVEN      = 0
export ENABLE_DPO             = 0
export TNS_END_PERCENT        = 5
export SKIP_INCREMENTAL_REPAIR = 1
export CELL_PAD_IN_SITES_GLOBAL_PLACEMENT = 2
export CELL_PAD_IN_SITES_DETAIL_PLACEMENT = 1
export GLOBAL_ROUTE_ARGS = -congestion_iterations 40 -congestion_report_iter_step 5 -allow_congestion -verbose
export MAX_REPAIR_ANTENNAS_ITER_GRT =

# [2026-07-13] 与 sky130 pe_top 同源：REMOVE_ABC_BUFFERS=0 会让 floorplan 跑一个对本设计
# 【结构性无效】的 repair（move sequence "unbuffer,sizeup,swap,vt_swap" 里没有任何插 buffer
# 的动作，而违例全部来自 i_tens/dom_rst_n —— fanout 51,487）。sky130 实测空转 3.6 小时零收益。
# 这条网是 RTL 结构，**与 PDK 无关**，ASAP7 一样会撞上。
# （ASAP7 Tensor 独立跑没覆盖这个：它的 reset 是顶层端口，没有 tensor_domain_top 的门控复位。）
export SKIP_FLOORPLAN_REPAIR = 1

# [2026-07-17] 保险：跳过 DRT 后天线修复（sky130 实测崩 GRT-0183，预防）。
export SKIP_ANTENNA_REPAIR_POST_DRT = 1

# [2026-07-21 R4a 探针轮] 西缘口袋 SOFT blockage + GP 后 CSR 几何探针。
# 根因：R3a/b 两轮 GP（确定性，odb sha1 逐位同）把 IBEX CSR 团块压进西缘口袋
# → GRT-0115 → DRT 5.3 万违例平台。修法首发=软 blockage（§3.4a 纪律）。
# 单变量纪律：pad/halo/DIE/周期均不动（对照 R3b）。探针 FAIL 时发射脚本停机。
# [Memory 波1 D5] R4b 旧布局探针（86-fakeram, gp_probe_csr.tcl / west_pocket_blockage.tcl）
#   绝对坐标钉死在旧 952µm 布局 → 新真宏 1350µm 布局上会 fail-open（旧矩形 80% 落在
#   L2 宏 halo 内、探针 FAIL 区大半压宏下），已停用，勿直接取消注释（见 M1_Scoping_Plan §A4/§B0-7）。
# [M1 2026-07-23] 替代=几何无关探针 gp_probe_clump.tcl（阈值全取 core 比例、修 (0,0) fail-open、
#   判决文件按 GP_PROBE_TAG 打标）。先跑它看 CSR 团块在新布局是否复现/落哪（util 20 下可能根本不复现，
#   B1 rank4）→ 若需 blockage，其矩形必须【由探针输出反推】，不得复用旧坐标。启用时（Stage S5）：
# export GP_PROBE_TAG          = m1s5_20260723
# export POST_GLOBAL_PLACE_TCL = $(DESIGN_HOME)/$(PLATFORM)/$(DESIGN_NICKNAME)/gp_probe_clump.tcl

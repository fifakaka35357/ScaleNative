[English](BUILD.md) | **简体中文**

# 构建与运行说明

本文说明 ScaleNative 的仿真测试与版图流程预期怎么跑。本文是英文版
[BUILD.md](BUILD.md) 的中文对照，两者有出入时以英文版为准。

## 1. 先读这一节

**本文里的内容都还没有在本仓的目录结构下演练过。** 测试与流程是在私有的开发目录里做的、
跑的，那里的目录结构与本仓不同。这次发布把文件搬进了你现在看到的目录结构，改掉了读文件时
查出的路径问题（`tb/` 下五个文件，清单见第 2 节），并补上了黄金模型目录。测试在这里没有
跑过，流程也没有照本文从零搭过。`scripts/` 里的辅助脚本是为这次发布写的，没有在干净的检出
上跑过。

实际的含义是：

- 下面的命令可能因为某处路径没改到而失败。遇到这种情况，原因多半在本仓，不在你的环境。
- 列出的工具版本是我们用过的版本，别的版本没有试过。
- 在本仓目录结构下跑通全部测试、从零搭起流程，列在 [FUTURE_WORK.zh-CN.md](FUTURE_WORK.zh-CN.md)
  的近期一层。做完之后会回来订正本文。

RTL、测试与版图本身的限制，见 [README](../README.zh-CN.md#已知限制)。

## 2. 仓里有什么，没有什么

仓里有：

| 路径 | 内容 |
|---|---|
| `rtl/` | 本项目自己写的 RTL（`IBEX_SRAM/`、`Tensor/`、`Vector/`） |
| `tb/` | cocotb 测试（`test_*.py`）、SystemVerilog 测试台（`tb_*.sv`）、cocotb 用的 `Makefile`、运行脚本 `run_all.py`、lint 扫描脚本 `elaborate_smoke.sh` |
| `Model/` | Python 写的黄金模型（`bfp_golden.py`），测试会导入它 |
| `designs/asap7/` | 七个设计配置目录、它们共用的两份约束文件，另有两个目录（`m1t_b5/`、`m1t_k1b/`）各只放一个 Tensor 这条链要用的钩子脚本 |
| `designs/src/aichip_sv/` | 流程读入的那份 RTL 副本，`ibex/` 下是带入的 Ibex 核 |
| `patches/` | `orfs-local.patch`（改 OpenROAD-flow-scripts 的流程脚本）与 `sram-bitwidth.patch`（改 SRAM 宏包里的一份库文件） |
| `scripts/` | `aichip_setup.sh`（获取依赖、打补丁）、`aichip_run.sh`（对一份配置启动流程）、`rename_gds_top.py`（由前者调用） |
| `docs/` | 本文与未来工作文档 |
| `paper/` | 论文草稿：LaTeX 源文件、中文对照稿与图。它单独构建，见 [paper/README-build.zh-CN.md](../paper/README-build.zh-CN.md) |

仓里没有、需要另外获取的：

- OpenROAD、Yosys 以及流程用到的其它工具。
- OpenROAD-flow-scripts，ASAP7 的平台文件也由它提供。
- ASAP7 的 SRAM 宏包 `asap7_sram_0p0`。
- 版图结果。我们各趟运行的 GDS、DEF、网表、报告与日志都不在仓里。

`rtl/` 与 `designs/src/aichip_sv/` 里是同一份项目 RTL 的两份副本：测试读前者，流程读后者。
后者还带着 Ibex 核，PE 一级的那个测试从那里读它。

与我们的开发目录相比，`tb/` 下有五个文件改过，改的只是路径：`Makefile`、
`elaborate_smoke.sh`，以及 `test_pe_top.py`、`test_l1i_real_a7.py`、
`test_srambank_real.py` 三个文件文档串里的源文件清单。`rtl/`、`tb/`、`Model/` 与
`designs/` 下的其余文件都是原样的副本。

`tb/` 下有八个文件不在回归范围内：`_r1_preproof.py`、
`pending_test_tensor_sparse_stall.py`、`scratch_guard_probe.py`、
`scratch_ivd_probe.py`、`scratch_pad_probe.py`、`scratch_sticky_probe.py`、
`wp0_bind_rehearse.py` 与 `wp0_min_probe.py`。其中七个是为单次实验写的探针，有的已经
退役。`pending_test_tensor_sparse_stall.py` 是一个退役的测试，它的测试台已经删掉，跑不
起来。这些文件的名字不以 `test_` 开头，`run_all.py` 不会跑它们。保留它们，是因为 RTL 的
注释提到了其中四个。它们头注里说的发射脚本没有公开。

## 3. 版本

下面是最近一次仿真与版图运行所在机器上的版本。除另有说明的以外，别的版本没有试过。

| 项 | 我们用的版本 | 说明 |
|---|---|---|
| 操作系统 | Ubuntu 26.04.1 LTS | |
| Verilator | 5.032 | 发行版自带的包 |
| cocotb | 1.9.2 | cocotb 2.x 不能用：有些测试用到了 2.x 已删除或改名的接口 |
| cocotb 用的 Python | 3.13 | 放在虚拟环境里。cocotb 1.9.2 配 Python 3.14 没有试过 |
| GNU make、GCC | 4.4.1、15.2 | |
| RISC-V binutils | `riscv64-unknown-elf-as` 2.45 | 只有一个测试需要，见 4.5 |
| OpenROAD-flow-scripts | 上游提交 `49416916f08ca3640464c755aed883c25d25a153` | 另加 `patches/orfs-local.patch` |
| OpenROAD | `26Q3-2676-g943a4d2c92` | 即流程脚本在该提交下的子模块提交 |
| Yosys | 0.68+（`a5af9d690`），带 slang 前端 | 即流程脚本在该提交下的子模块提交 |
| KLayout | 0.30.12 | GDS 合并与安装脚本要用 |
| ASAP7 平台文件 | OpenROAD-flow-scripts 在上述提交下自带的那一份 | |
| `asap7_sram_0p0` | 提交 `9f5af0939e8dd3cc1a9693a50b23441691dd7d25` | 另加 `patches/sram-bitwidth.patch` |

上游标签为 `26Q3-661-g49416916f` 的容器镜像对应同一个流程脚本提交。我们用它对上游的
`gcd` 示例做过一次交叉核对，没有用它跑本仓的设计。

## 4. 仿真

### 4.1 准备

装好 Verilator，再建一个带 cocotb 1.9.2 的 Python 环境：

```sh
python3.13 -m venv ~/.venvs/scalenative
. ~/.venvs/scalenative/bin/activate
pip install "cocotb==1.9.2"
```

### 4.2 跑全部测试

```sh
cd tb
python3 run_all.py > run_all.txt 2>&1
tail -n 80 run_all.txt
```

`run_all.py` 从每个 `test_*.py` 的文档串里读出顶层模块与源文件清单，对每个测试文件调一次
`make`，每个测试之前先清构建目录。结束时每个测试文件打一行，最后是合计：

```
  ----- TOTAL: PASS=<n> FAIL=<f> across <k> files -----
```

有五个测试文件的文档串里没有构建信息（四个 `test_fastlane_*` 文件与
`test_wd124_poscontrol`）。它们会被列为 `NO-META`，`run_all.py` 不跑它们。在我们的机器上
整套跑完约 50 分钟。它是单线程的，而且每个测试文件都要重新编一次仿真器。

### 4.3 跑一部分，或只跑一个测试

```sh
cd tb
python3 run_all.py mac_lru        # 文件名里含 "mac_lru" 的测试

make clean
make MODULE=test_mac_lru TOPLEVEL=mac_lru \
     VERILOG_SOURCES="../rtl/Tensor/tensor_pkg.sv ../rtl/Tensor/mac_lru.sv"
```

每个测试确切的 `make` 命令写在它文档串的 `Run:` 一段里。

### 4.4 怎么读结果

- 看 `PASS=`/`FAIL=` 的数。直接调 `make` 时，它的退出码看不出 cocotb 测试过没过。
- 过滤串一个测试文件也没匹配到时，`run_all.py` 的退出码是 0。请核对合计行里的文件数是不是
  你预期的。
- 所有测试都编到同一个 `tb/sim_build` 目录里。不要同时跑两个测试，也不要在 `run_all.py`
  运行期间再跑别的测试。手工换顶层模块时先 `make clean`。

### 4.5 有额外要求的测试

| 测试 | 需要 |
|---|---|
| `test_rv32_asm_xcheck` | `riscv64-unknown-elf-as`。这个测试拿 `tb/rv32_asm.py` 里的小汇编器与真正的汇编器对比。没有这个工具时，它什么也不查就算通过 |
| `test_pe_top` | `designs/src/aichip_sv/ibex/` 下的 Ibex 源码，仓里有 |
| `test_l1i_real_a7`、`test_srambank_real` | SRAM 宏的 Verilog 模型 `third_party/asap7_sram_0p0/generated/verilog/srambank_128x4x64_6t122.v`。它不在仓里，由 `scripts/aichip_setup.sh` 取来（见 5.1）。`test_l1i_real_a7` 还需要它文档串里写的编译选项，`run_all.py` 会带上 |

### 4.6 选项

- `XPROP=1 XSEED=<n>`：把每个信号的初值随机化，而不是取 0。用两个不同的种子各跑一遍，可以
  找出依赖初值的寄存器：`XPROP=1 XSEED=1 python3 run_all.py <filter>`。
- `TEST_EXTRA="..."`：给一次 `make` 追加编译选项。不要在命令行上传 `EXTRA_ARGS` 或
  `COMPILE_ARGS`：命令行赋值会顶掉 `Makefile` 与 cocotb 设好的选项。

### 4.7 lint 扫描

```sh
bash tb/elaborate_smoke.sh
```

它对各个 package 和一组有代表性的模块跑 `verilator --lint-only`，逐个打 PASS 或 FAIL。
其中有一项要读 4.5 里说的 SRAM 宏模型。

## 5. 版图流程

### 5.1 获取依赖

```sh
bash scripts/aichip_setup.sh
```

脚本在仓的根目录下建两个目录，git 都不跟踪它们。

- `_ext/OpenROAD-flow-scripts/`：第 3 节所列提交的 OpenROAD-flow-scripts，连同子模块，
  并打上 `patches/orfs-local.patch`。
- `third_party/asap7_sram_0p0/`：第 3 节所列提交的 SRAM 宏包，打上
  `patches/sram-bitwidth.patch`，并多出一份 GDS 文件（见下）。

哪一步失败，脚本就停在哪一步。补丁打不上时不要强行打：补丁是针对钉住的那两个提交写的。

脚本不编工具。请按 OpenROAD-flow-scripts 的文档，在 `_ext/OpenROAD-flow-scripts/` 里
把 OpenROAD、Yosys 等编好。

如果要手工搭，有三处细节：

- **流程补丁。** 它改四个流程脚本（`cts.tcl`、`detail_route.tcl`、`floorplan.tcl`、
  `util.tcl`）。它加了 `SKIP_FLOORPLAN_REPAIR`，用来跳过 floorplan 阶段的时序修复；
  配置里设了这个变量，不打补丁的话它不起作用，结果会不同。它还加了两个可选参数（时钟树综合
  之后合法化用的 `DPL_MAX_DISPLACEMENT`、时序修复用的 `MAX_BUFFER_PERCENT`），并在天线
  修复之前给布线后的数据库存一个检查点。
- **SRAM 宏包放在哪。** 配置文件按相对于流程目录的位置找它：
  `$(FLOW_HOME)/../../../third_party/asap7_sram_0p0`。流程脚本在
  `<A>/<B>/OpenROAD-flow-scripts` 时，宏包必须在 `<A>/third_party/asap7_sram_0p0`。
  脚本建出的目录满足这一点。
- **改名的 GDS。** 配置读的是 `gds/srambank_128x4x64_6t122_renamed.gds`，宏包里没有这个
  文件。它是宏包里 `gds/srambank_64b.gds` 的副本，只是把顶层单元 `srambank_64b` 改名为
  `srambank_128x4x64_6t122`，也就是 LEF 里宏的名字。`srambank_64b.gds` 的文件名虽然是
  这样，装的却正是这个宏的版图；`srambank_128b.gds` 是另一个宏。安装脚本用 KLayout 做
  这份副本。缺了这个单元，GDS 合并这一步会报错停下。配置文件里有些注释对这一步的说法不同，
  已经过期。

### 5.2 三个设计

| 设计 | 配置 | 顶层模块 | 约束里的时钟周期 |
|---|---|---|---|
| Vector 单元 | `asap7/m1v_mc2f/config.mk`（包含 `aichip_vector`） | `vector_unit` | 1670 ps |
| Tensor 单元 | `asap7/m1t_b58k1bv2/config.mk`（包含 `m1t_pnr`、`m1t_adder`、`aichip_tensor_signoff`） | `tensor_unit_top` | 1670 ps |
| PE 顶层 | `asap7/aichip_pe_top/config.mk` | `pe_top` | 12000 ps |

时钟周期是流程的设置，不是达到的频率。

`aichip_tensor_signoff` 是 Tensor 这条链的底层，不能单独跑。请用 `m1t_b58k1bv2`。

### 5.3 跑一个设计

```sh
export QT_QPA_PLATFORM=offscreen      # 没有显示器时出报告里的图
export COLUMNS=4096                   # 见第 6 节
bash scripts/aichip_run.sh asap7/m1v_mc2f/config.mk LEC_CHECK=0
```

`aichip_run.sh` 进到 `_ext/OpenROAD-flow-scripts/flow` 下调 `make`，把 `DESIGN_HOME`
设成本仓的 `designs/` 目录，所以设计留在流程目录之外。配置路径后面的参数都会传给 `make`，
例如 `synth` 这样的目标，或者 `FLOW_VARIANT=<name>`。

建议从 Vector 单元开始。它没有 SRAM 宏，在三个设计里小得多。

`LEC_CHECK=0` 关掉流程里的逻辑等价检查。我们的各趟运行都是关着它跑的。`scripts/aichip_run.sh`
头注与 `scripts/aichip_setup.sh` 末尾提示里的示例命令没有带这个参数。

跑 Tensor 单元时还要多设一个变量：

```sh
B58_SQ_ABSENT_OK=1 bash scripts/aichip_run.sh asap7/m1t_b58k1bv2/config.mk LEC_CHECK=0
```

不设的话，时钟树综合之前执行的一个钩子
（`designs/asap7/m1t_b58k1bv2/b58_caliber_align_v2.tcl`）会以退出码 91 让流程停下。

### 5.4 我们的几趟是怎么起的

论文里的版图是在私有的开发目录里按下面的方式跑出来的。表里说的包装配置不在本仓里。

| 设计 | 变体名 | 与 5.3 的命令相比差在哪 |
|---|---|---|
| Vector 单元 | `nm20261002` | 命令行上加 `FLOW_VARIANT=nm20261002`，别的没有 |
| Tensor 单元 | `py_s42` | 用一份包装配置：包含 `m1t_b58k1bv2/config.mk`，再加上变体名和一个固定全局布线种子的钩子（全局布线之前执行 `set_global_routing_random -seed 42`） |
| PE 顶层 | `py` | 用一份包装配置：包含 `aichip_pe_top/config.mk`，并把宏摆放脚本换成把 SRAM 宏在 Y 方向挪 -9 nm 的版本。这个偏移之后已经并进公开的 `manual_macro_place.tcl`，由配置里的 `AICHIP_MACRO_Y_DY = -9` 选中。所以公开的文件是那一趟所用文件的后续版本，不是同一份文件 |

三趟用的都是最近一次 RTL 改动之前的 RTL（见 README）。

### 5.5 资源

在我们的机器上（24 线程，90 GiB 内存另加交换空间），完整跑一趟，Vector 单元大约一个半
小时，Tensor 单元大约九小时，PE 顶层大约十小时。PE 顶层这一趟的最后几个阶段用满了内存，
另用了几十 GiB 交换空间。PE 顶层跑一趟写出约 100 GB 的结果。

### 5.6 会看到什么

- PE 顶层这一趟结束时还剩四条布线设计规则违例（见 README 的已知限制）。
- 我们这几趟的最终报告里都有时序违例：Vector 与 Tensor 两趟有建立时间违例，Tensor 与
  PE 顶层两趟有保持时间违例，三趟都有最大转换时间违例（见 README 已知限制第 28 条）。看到
  它们不代表你的环境有问题。
- `aichip_pe_top/config.mk` 与 `aichip_tensor_signoff/config.mk` 仍然会读入
  `fakeram7_256x32` 的 LEF 与库，但不会产生它的任何实例。
- 日志信息与注释里会提到没有公开的内部笔记。

## 6. 环境上的几点

下面是我们遇到过的问题，在你的机器上不一定会出现。

- **Yosys 可能卡在 ABC。** 用这个版本的 Yosys 时，如果流程在没有终端的环境里跑（没有
  `TERM`，例如由服务管理器启动），同时 `TMPDIR` 的路径又很长，综合会一直等下去。设
  `COLUMNS=4096`，或者设 `TERM`，或者把 `TMPDIR` 换成短路径，三者任一都可以避开。
- **出报告里的图要设显示方式。** 没有显示器时设 `QT_QPA_PLATFORM=offscreen`。
- **`~/.local/bin` 里的 Python 可能弄坏工具的编译。** 编流程工具时，如果 `PATH` 里排在
  前面的是装在个人目录下的 Python，等价检查工具会链接到一个运行时找不到的 Python 库，流程在第一次
  等价检查处停下。请用干净的 `PATH` 编工具。
- **大的几趟要独占机器。** 跑 PE 顶层或 Tensor 时，不要同时跑测试或另一趟流程。

## 7. 没有演练过的事

明确列出来：下面各项在本仓的目录结构下都没有做过。

- 跑 `python3 run_all.py` 或任何单个测试；
- 跑 `tb/elaborate_smoke.sh`；
- 跑 `tb/baseline/regen_r1_dense.sh`，它经一个临时的 git worktree 从某个提交重建
  `tb/baseline/` 下的参考快照；
- 在干净的检出上跑 `scripts/aichip_setup.sh`，包括 GDS 改名这一步；
- 用 `scripts/aichip_run.sh` 跑三个设计中的任何一个；
- 只带七个配置目录与两个钩子目录的情况下跑 Tensor 这条链。

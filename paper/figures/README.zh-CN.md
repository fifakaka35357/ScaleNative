[English](README.md) | **简体中文**

# 图

本目录存放 ScaleNative 论文里已经画好的图：五张架构图和一张版图图。每张图有一份 PDF，和生成它的源文件放在一起。PDF 是按原大放进论文的，不做缩放。本文与英文版有出入时，以英文版为准。

## 各张图

| 图 | 画的是什么 | 论文里的图位 | 页面尺寸 |
|---|---|---|---|
| `fig-system.pdf` | 系统组织：一颗 SoC，里面有一张同型 PE 的 Mesh、host 接口、Control Core 和共享的 L3；其中一个 PE 就地放大 | `fig:system`，“Microarchitecture”一节 | 3.33 in × 2.1 in |
| `fig-pe.pdf` | 一个 PE 的微架构：控制一列、Tensor 单元、快通道、Vector 单元和 L2 | `fig:pe`，“Microarchitecture”一节 | 7.0 in × 2.4 in |
| `fig-tensor.pdf` | Tensor 单元：阵列组织、一个 MAC 单元、出口处的块形成 | `fig:tensor`，“Microarchitecture”一节 | 7.0 in × 1.9 in |
| `fig-vector.pdf` | Vector 单元：两个 Vector 核、入口核对、向 L2 的写回 | `fig:vector`，“Microarchitecture”一节 | 7.0 in × 2.4 in |
| `fig-flow.pdf` | 评估流程：左边是输入，右边是各种证据形式 | `fig:flow`，“Evaluation Methodology”一节 | 3.33 in × 1.5 in |
| `fig-layout.pdf` | 一个 PE 的布线后版图，各模块带框 | `fig:layout`，“Results”一节 | 3.33 in × 3.33 in |

宽 3.33 in 是论文的一栏，宽 7.0 in 是通栏。各图里的字都不小于 8 bp。

## 目标设计与原型

五张架构图画的是论文所述的目标设计，不是本仓里的 RTL；本仓的 RTL 只实现了这个设计的一部分。原型有什么、缺什么，写在论文里各图的图注里，也列在[仓库 README](../../README.zh-CN.md) 的已知限制里。设计本身还没定的地方，图上画成通用形态。点线框和点线标的是还没定的部分。

版图图是另一类图。它画的是某一趟布局布线的结果，用的是更早的一版 RTL。细节见下文它自己的一节。

## 文件

| 文件 | 内容 |
|---|---|
| `fig-system.tex`、`fig-pe.tex`、`fig-tensor.tex`、`fig-vector.tex`、`fig-flow.tex` | 五张架构图的独立外壳，每个出一页 PDF |
| `fig-system-body.tex`、`fig-pe-body.tex`、`fig-tensor-body.tex`、`fig-vector-body.tex`、`fig-flow-body.tex` | 图本身，用 TikZ 画；在载入了样式件的文档里，也可以用 `\input` 直接读入 |
| `scalenative-figstyle.sty` | 五张图共用的样式件：字体与字号、颜色、线型、块的形状和画布 |
| `fig-layout.tex`、`fig-layout-base.png` | 版图图：框、引线和名字，以及它们下面的底图 |
| `build-figures.sh` | 编出六份 PDF 并做检查 |
| `tools/check_figure_pdf.py` | 读出 PDF 里每一处文字的字号；构建脚本用它 |

## 重新编图

```sh
./build-figures.sh                # 六张图全部重编并检查
./build-figures.sh fig-pe         # 只编一张
./build-figures.sh --check-only   # 只检查目录里已有的 PDF，不编
python3 tools/check_figure_pdf.py --selftest   # 字号读取工具自带的正反控
```

脚本需要 `pdflatex`（带 TikZ、`standalone` 文档类和 TeX Gyre Heros 字体）、poppler 的 `pdfinfo` 与 `pdffonts`，以及 `python3`。我们用的是 TeX Live 2025（pdfTeX 1.40.28）。在 Debian 或 Ubuntu 上，对应的包是 `texlive-latex-extra`、`texlive-pictures`、`tex-gyre` 和 `poppler-utils`。构建时不开 shell escape，也不联网。中间文件写在临时目录里。

每编完一张图，脚本检查它的 PDF：

1. 页面尺寸。PDF 只有一页。页面宽恰为 3.33 in 或 7.0 in，高与上表所列相同。容差是 0.002 in。
2. 字体。所有字体都已嵌入，并且没有 Type 3 字体。
3. 字号。没有小于 8 bp 的字。字号是从 PDF 的文字操作符里读出来的。

有三件事脚本不查：有没有东西画到了画布之外，有没有字压在别的字上，有没有线从名字上穿过。改过图之后，请打开 PDF 看一眼。其中头一件，样式件里讲画布的一节说明了另外两种定界方式，可以帮上忙。

源文件里关掉了 pdfTeX 本来会写进 PDF 的日期和文档 ID。我们试的几次里，用同一套 TeX 重复构建，得到的 PDF 逐字节相同。换一个版本的 TeX，字节可能不同。

版图图的底图不能从本仓重新生成，原因见下一节。

## 版图图

- **是哪一趟。** 图上是 PE 顶层这一趟，它的配置在 `designs/asap7/aichip_pe_top`。这一趟用 OpenROAD-flow-scripts 在 ASAP7 预测型 PDK 上做完了布局和布线。布线后的设计数据的日期是 2026-10-01。它是 EDA 估计，不是硅上的结果。这张图是中间版本，每跑完一次全流程就重出一次。
- **按数据绘制，不是截图。** 底图 `fig-layout-base.png` 是脚本按布线后设计数据里已摆放的单元画出来的。它不是截图，也不是版图工具渲染的图。这个脚本和布线后的数据（一个约 6 GB 的 DEF 文件）都不在本仓里，所以底图在这里重新生成不了。`fig-layout.tex` 只在底图上画框、引线和名字。
- **画了什么。** 底图是 1998 × 1998 px，也就是 600 ppi 下的 3.33 in。整幅图就是 die，一个边长 1428.5 µm 的正方形。逻辑单元画成灰色，33 个 SRAM 宏画成带斜纹的暗红。每个 2 × 2 px 的小方格（在 die 上约 1.43 µm）里只要压着至少一个已摆放的逻辑单元，就涂成灰色。所以灰色表示哪里有单元，不表示有多密：die 的 81.2 % 涂成了灰色，而单元只占 die 面积的 19.5 %。填充单元、tap 单元、连线、过孔、引脚、电源网和设计规则违例的标记都没有画。这一趟布线后还剩的违例列在仓库 README 里。
- **框。** 设计是扁平布局的，所以框只是画图用的标示，不是布图规划里的区域。三个框圈住 SRAM 宏：L2 的 16 个、L1 的 5 个、Operand buffer 的 12 个。另外三个框是按逻辑单元拟合的，让一个模块的大部分单元落在框里。每个框我们给两个占比：框内的单元面积里有多少属于这个模块，这个模块的单元面积里有多少落在框内。Command processor 是 85.70 % 和 87.00 %，Ibex CPU 是 92.81 % 和 97.78 %，Vector 单元是 93.24 % 和 89.45 %。六个框以外的部分都标作 Tensor 单元，两个占比是 95.52 % 和 88.35 %。DMA（占逻辑单元面积的 0.20 %）和快通道 FIFO（0.37 %）太小，没有画框。
- **时钟约束。** 这一趟给工具的时钟周期是 12000 ps。这个数是流程的设置，不是达到的周期。这张图不报告任何时序结果，而且这一趟的时序没有收敛。
- **RTL 的版本。** 这一趟用的是 Vector 单元平方和单元做数值修正之前的 RTL。那一版不在本仓里。按那一版，PE 只有一个 Vector 核，L2 是 32 KiB。

这一趟以及另外两趟块级运行的数，论文里列在这张图后面的表里。

## 权利说明

图及其源文件是论文的一部分，不在仓库其余部分所用的 Apache License 2.0 范围内。Copyright 2026 The ScaleNative Authors. 保留全部权利。完整的说明见[论文目录的 README](../README.zh-CN.md)。

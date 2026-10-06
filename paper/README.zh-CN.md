[English](README.md) | **简体中文**

# 论文

本目录存放 ScaleNative 的论文：英文稿源文件、作者自己把关用的中文对照稿、图，以及预先编好的论文稿。两种语言的版本有出入时，以英文稿为准。

## 目录内容

| 路径 | 内容 |
|---|---|
| `main-acm.tex`、`main-ieee.tex`、`body.tex`、`sections/`、`tables/`、`preamble/`、`backmatter/`、`authors.tex`、`refs.bib` | 英文稿，LaTeX 源文件，有两个入口文件（ACM 与 IEEE 两种版式） |
| `paper.zh-CN.md` | 中文对照稿，逐段对应 |
| `figures/` | 六张已经画好的图：PDF、生成它们的源文件和一个构建脚本；见 [figures/README.zh-CN.md](figures/README.zh-CN.md) |
| `pdf/` | 预先编好的论文稿，每个入口文件一份 PDF：`scalenative-draft-acm.pdf` 与 `scalenative-draft-ieee.pdf` |
| `build.sh`、`test_matrix.sh`、`check_align.py`、`page_report.py` | 构建及其检查；见 [README-build.zh-CN.md](README-build.zh-CN.md) |

论文稿目前是第一版完整正文。结果处是占位，还有八张图是空框。

## 权利说明

本目录的内容不在仓库其余部分所用的 Apache License 2.0 范围内。`paper/` 下的每个文件都是如此：论文稿源文件、中文对照稿、图及其源文件、编译出的 PDF、构建脚本。

Copyright 2026 The ScaleNative Authors. 保留全部权利。作者名单见 [`AUTHORS`](../AUTHORS) 文件。

欢迎阅读和引用这些材料。

未经作者许可，不得转载、再发布或改编其全部或任何部分，图也在内。

如需许可，请在本仓库提 issue。

论文稿目前是草稿。作者可能在以后的发布中修改本说明，例如在论文投稿或发表时。

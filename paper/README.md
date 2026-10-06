**English** | [简体中文](README.zh-CN.md)

# Paper

This directory holds the ScaleNative paper: the English manuscript sources, a Chinese companion text that the authors keep for their own cross-checking, the figures, and the manuscript compiled in advance. Where the two language versions differ, the English manuscript is the one that counts.

## Contents

| Path | Content |
|---|---|
| `main-acm.tex`, `main-ieee.tex`, `body.tex`, `sections/`, `tables/`, `preamble/`, `backmatter/`, `authors.tex`, `refs.bib` | the English manuscript, as LaTeX sources with two entry files (ACM and IEEE formats) |
| `paper.zh-CN.md` | the Chinese companion text, paragraph by paragraph |
| `figures/` | the six finished figures: PDFs, the sources they are built from and a build script; see [figures/README.md](figures/README.md) |
| `pdf/` | the manuscript compiled in advance, one PDF per entry file: `scalenative-draft-acm.pdf` and `scalenative-draft-ieee.pdf` |
| `build.sh`, `test_matrix.sh`, `check_align.py`, `page_report.py` | the build and its checks; see [README-build.md](README-build.md) |

The manuscript is a first full draft. Its results are placeholders, and eight of its figures are still empty frames.

## Rights

The contents of this directory are not covered by the Apache License 2.0 that applies to the rest of the repository. This holds for every file under `paper/`: the manuscript sources, the Chinese companion text, the figures and their source files, any compiled PDF, and the build scripts.

Copyright 2026 The ScaleNative Authors. All rights reserved. The authors are listed in the [`AUTHORS`](../AUTHORS) file.

You are welcome to read this material and to cite it.

You may not redistribute, republish or adapt it, in whole or in part, without the authors' permission. This includes the figures.

To ask for permission, open an issue in this repository.

The manuscript is a draft. The authors may change this statement in a later release, for example when the paper is submitted or published.

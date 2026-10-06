**English** | [简体中文](README.zh-CN.md)

# Figures

This directory holds the finished figures of the ScaleNative paper: five architecture figures and one layout figure. Each figure comes as a PDF together with the source it is built from. The PDFs are made to be placed in the paper at their natural size, without scaling. Where this file and its Chinese version differ, the English version is the reference.

## The figures

| Figure | What it shows | Slot in the paper | Page size |
|---|---|---|---|
| `fig-system.pdf` | System organization: an SoC with a mesh of identical PEs, a host interface, a Control Core and a shared L3. One PE is enlarged. | `fig:system`, section "Microarchitecture" | 3.33 in × 2.1 in |
| `fig-pe.pdf` | Microarchitecture of one PE: the control column, the Tensor unit, the fast lanes, the Vector unit and L2 | `fig:pe`, section "Microarchitecture" | 7.0 in × 2.4 in |
| `fig-tensor.pdf` | Tensor unit: array organization, one MAC cell, and block formation at the outlets | `fig:tensor`, section "Microarchitecture" | 7.0 in × 1.9 in |
| `fig-vector.pdf` | Vector unit: the two Vector cores, the ingress check and the write-back to L2 | `fig:vector`, section "Microarchitecture" | 7.0 in × 2.4 in |
| `fig-flow.pdf` | Evaluation flow: inputs on the left, forms of evidence on the right | `fig:flow`, section "Evaluation Methodology" | 3.33 in × 1.5 in |
| `fig-layout.pdf` | Post-route layout of one PE, with frames around its blocks | `fig:layout`, section "Results" | 3.33 in × 3.33 in |

A width of 3.33 in is one column of the paper, and 7.0 in is the full text width. No lettering in any of the figures is smaller than 8 bp.

## Target design and prototype

The five architecture figures show the target design that the paper describes. They do not show the RTL in this repository, which implements part of that design. What the prototype has and what it lacks is stated in the caption of each figure in the paper, and in the known limitations listed in the [repository README](../../README.md). Where the design itself is not decided yet, a figure draws that part in generic form. Dotted boxes and dotted lines mark parts that are still open.

The layout figure is of a different kind. It shows what one place-and-route run produced from an earlier revision of the RTL. Its section below gives the details.

## Files

| File | Content |
|---|---|
| `fig-system.tex`, `fig-pe.tex`, `fig-tensor.tex`, `fig-vector.tex`, `fig-flow.tex` | standalone wrappers of the five architecture figures; each gives one PDF page |
| `fig-system-body.tex`, `fig-pe-body.tex`, `fig-tensor-body.tex`, `fig-vector-body.tex`, `fig-flow-body.tex` | the drawings themselves, in TikZ; a body can also be read with `\input` inside a document that loads the style file |
| `scalenative-figstyle.sty` | the style shared by the five figures: fonts and sizes, colours, line kinds, block shapes and the canvas |
| `fig-layout.tex`, `fig-layout-base.png` | the layout figure: the frames, leaders and names, and the base image they are drawn over |
| `build-figures.sh` | builds the six PDFs and checks them |
| `tools/check_figure_pdf.py` | reads the size of every piece of text in a PDF; the build script uses it |

## Rebuilding

```sh
./build-figures.sh                # build and check all six figures
./build-figures.sh fig-pe         # one figure
./build-figures.sh --check-only   # check the PDFs that are here, build nothing
python3 tools/check_figure_pdf.py --selftest   # the controls of the size reader
```

The script needs `pdflatex` with TikZ, the `standalone` class and the TeX Gyre Heros fonts, `pdfinfo` and `pdffonts` from poppler, and `python3`. We used TeX Live 2025 (pdfTeX 1.40.28). On Debian or Ubuntu the packages are `texlive-latex-extra`, `texlive-pictures`, `tex-gyre` and `poppler-utils`. The build runs without shell escape and without network access. Intermediate files go to a temporary directory.

After building a figure, the script checks its PDF:

1. Page size. The PDF has one page. The page is exactly 3.33 in or 7.0 in wide, and as high as the table above says. The tolerance is 0.002 in.
2. Fonts. Every font is embedded, and none is a Type 3 font.
3. Lettering. No text is smaller than 8 bp. The sizes are read from the text operators of the PDF.

The script does not check three things: whether anything is drawn outside the canvas, whether lettering is printed over other lettering, and whether a line runs through a name. Look at the PDF after you change a figure. For the first of the three, the canvas section of the style file describes two extra box modes that help.

The sources switch off the dates and the document ID that pdfTeX would otherwise write into a PDF. In our runs, repeated builds with one TeX installation gave byte-identical PDF files. A different TeX version may give different bytes.

The base image of the layout figure cannot be rebuilt from this repository. The next section says why.

## The layout figure

- **The run.** The figure shows the PE top-level run, whose configuration is in `designs/asap7/aichip_pe_top`. The run went through placement and routing with OpenROAD-flow-scripts on the ASAP7 predictive PDK. The routed design data are dated 2026-10-01. The result is an EDA estimate, not silicon. The figure is an intermediate version and is reissued after each full run of the flow.
- **Drawn from data, not a screenshot.** The base image `fig-layout-base.png` is drawn by a script from the placed components in the routed design data. It is not a screenshot, and it is not a rendering made by a layout tool. The script and the routed data, a DEF file of about 6 GB, are not in this repository. The base image can therefore not be regenerated here. `fig-layout.tex` only draws the frames, the leaders and the names over it.
- **What is drawn.** The image is 1998 × 1998 px, which is 3.33 in at 600 ppi. The whole image is the die, a square with a side of 1428.5 µm. Logic cells are grey, and the 33 SRAM macros are hatched red. A square of 2 × 2 px, about 1.43 µm on the die, is painted grey when at least one placed logic cell overlaps it. The grey therefore shows where cells are, not how dense they are: 81.2 % of the die is painted grey, while the cells cover 19.5 % of the die area. Fill cells, tap cells, wires, vias, pins, the power grid and design-rule markers are not drawn. The routing violations that remain in this run are listed in the repository README.
- **Frames.** The design is placed flat, so a frame is a drawing aid and not a floorplan region. Three frames enclose SRAM macros: 16 macros of L2, 5 of L1 and 12 of the Operand buffer. Three more frames are fitted to logic cells so that most of the cells of a block are inside. For each of them we give two shares: how much of the cell area inside the frame belongs to the block, and how much of the cell area of the block is inside the frame. They are 85.70 % and 87.00 % for the Command processor, 92.81 % and 97.78 % for the Ibex CPU, and 93.24 % and 89.45 % for the Vector unit. Everything outside the six frames is labelled Tensor unit, with shares of 95.52 % and 88.35 %. The DMA engine (0.20 % of the logic-cell area) and the fast-lane FIFO (0.37 %) are too small to frame.
- **Clock constraint.** The run was given a clock period of 12000 ps. This number is a flow setting, not an achieved period. The figure reports no timing result, and timing is not closed in this run.
- **RTL revision.** The run used the RTL as it was before the correction to the sum-of-squares unit of the Vector unit. That revision is not in this repository. As built in that revision, the PE has one Vector core and an L2 of 32 KiB.

The paper gives the numbers of this run, and of the two block-level runs, in the table that follows the figure.

## Rights

The figures and their sources are part of the paper. They are not covered by the Apache License 2.0 that applies to the rest of the repository. Copyright 2026 The ScaleNative Authors. All rights reserved. The full statement is in the [README of the paper directory](../README.md).

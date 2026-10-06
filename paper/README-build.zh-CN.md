[English](README-build.md) | **简体中文**

# 论文的构建

本文是英文版 [README-build.md](README-build.md) 的中文对照。两者有出入时，以英文版为准。

本目录存放论文的 LaTeX 源文件、论文的图和一份中文对照稿。正文只写一遍，写在不依赖文档类的章节文件
里，再经两个很薄的入口文件编译：`main-acm.tex`（acmart，为主）与 `main-ieee.tex`
（IEEEtran）。本目录里的材料可以怎样使用，写在 [README.zh-CN.md](README.zh-CN.md) 里。

目前论文是**第一版完整正文**：每一段、每一条图注与表注都已写成，结果处是占位。六张图已经放入
（`fig:system`、`fig:pe`、`fig:tensor`、`fig:vector`、`fig:flow` 与 `fig:layout`），七张表都已经排出；
`tab:placements` 里有两格是占位。其余八张图（`fig:handoff`、`fig:workload`、`fig:retain`、`fig:payoff`、
`fig:correct`、`fig:metadata`、`fig:failvis-cost` 与 `fig:system-proj`）仍是按预算尺寸画的空框。

这一状态下的页数，取自 2026-10-06 的构建报告（TeX Live 2025）：正文（参考文献之前的全部内容）在
ACM 入口的分享版里占 11.00 页，在 IEEE 入口的分享版里占 10.42 页；在各投稿版里占 10.94 页
（ASPLOS 2027）、10.18 页（MICRO 2026）、10.15 页（ISCA 2026）与 10.25 页（HPCA 2027）。四家会议
的上限都是 11 页。ACM 入口的分享版把第 11 页排到了最后一行：正文再多一行，就会超过 11 页。

## 快速开始

```sh
./build.sh            # share build of both entries -> out/main-acm.pdf, out/main-ieee.pdf
./build.sh --check    # the same, then compare the English text with the Chinese draft
./build.sh --help     # every option
```

环境要求：TeX Live 2025 或更新的版本，带 `latexmk`、`pdflatex`、`bibtex`、`acmart`
文档类（我们用的是 v2.16）与 `IEEEtran` 文档类（V1.8b），以及它们的字体与 `.bst` 文件。
在 Debian/Ubuntu 上，这些来自 `texlive-publishers`（两个文档类及其 `.bst` 文件）、
`texlive-fonts-extra`（acmart 用到的字体）、`texlive-latex-extra`、
`texlive-latex-recommended`、`texlive-fonts-recommended` 与 `latexmk`。每次构建之后打印的
报告要用到 `pdfinfo`、`pdffonts`、`pdftotext`（poppler）和 `python3`，构建本身不需要它们。
文档类文件不放在本目录里：请用 TeX 发行版自带的，投稿时用会议指定的。

`build.sh` 调用 `latexmk` 时关闭 shell escape，也不读任何 `latexmkrc`。两个入口文件也可以
直接用 `latexmk -pdf main-acm.tex` 编译（例如在 Overleaf 上），得到的是分享版。

每次构建之后，脚本会打印：生效的开关、未定义的引用、overfull box（横向与纵向）、BibTeX 的错误与警告、
页数、正文在哪里结束（参考文献之前的页数，各会议数的就是它；占位也占地方，所以要把缺省构建与
`--tbd=none` 的构建对着看；`--fill` 只填充仍带 `\fillto` 的文本单元，现在已经没有这样的单元），
以及是否所有字体都已嵌入、没有 Type 3 字体。下列情形构建会失败：
有字体没有嵌入；分享版里出现了会议的投稿横幅；匿名版的正文或元数据里出现了 `authors.tex`
里的姓名、邮箱或单位，或者出现了公开的系统名或公开仓的地址（`preamble/meta.tex`）。

## 目录

```
main-acm.tex            entry: acmart; share build = sigplan, 10 pt (the ASPLOS page format)
main-ieee.tex           entry: IEEEtran, conference, 10 pt (the ISCA 2026 / HPCA 2027 format)
body.tex                the list of section files, shared by both entries
sections/00-abstract.tex ... 10-conclusion.tex    the text, one file per section
tables/tab-*.tex        the bodies of the typeset tables, one file per table (read by the section files)
authors.tex             the author list, written once for both classes
refs.bib                the bibliography
backmatter/acks.tex     acknowledgments          (share build only)
backmatter/ai-use.tex   statement on generative AI tools   (off by default)
backmatter/appendix.tex appendix                 (off by default)
preamble/switches.tex   every build switch and its default
preamble/common.tex     macros shared by both entries
preamble/meta.tex       title, system name, repository link
preamble/terms.tex      terminology macros
preamble/float-budget.tex   size of every figure and table slot
preamble/authors-acm.tex, authors-ieee.tex   how authors.tex is rendered by each class
figures/                finished figures: PDFs, their sources, a build script and a README
pdf/                    the share build of both entries, compiled in advance
paper.zh-CN.md          Chinese companion draft, paragraph by paragraph
check_align.py          compares sections/*.tex with paper.zh-CN.md
page_report.py          measures where the body ends in a built PDF
build.sh                the build
test_matrix.sh          builds every variant and checks what each must and must not print
README.md, README.zh-CN.md                what this directory holds, and the rights statement
README-build.md, README-build.zh-CN.md    this file and its Chinese version
out/                    build output (not under version control)
```

只有两个入口文件和 `preamble/authors-*.tex` 知道当前用的是哪个文档类。

## `figures/` 与 `pdf/` 两个目录

`figures/` 存放六张已经画好的图。每张图有一份 PDF，和生成它的源文件放在一起：五张架构图是
TikZ 源文件，共用一个样式件；版图图是一个画在底图上的很短的 LaTeX 文件。
[figures/README.zh-CN.md](figures/README.zh-CN.md) 逐个说明了各个文件、编图要用的工具，以及
版图图的来历。

```sh
cd figures
./build-figures.sh                # rebuild and check all six figures
./build-figures.sh fig-pe         # one figure
./build-figures.sh --check-only   # check the PDFs that are there, build nothing
```

每编完一张图，脚本检查它的 PDF：页面宽恰为 3.33 in 或 7.0 in，高与这张图的图位相同；所有字体
都已嵌入，并且没有 Type 3 字体；没有小于 8 bp 的字。论文的构建不会重编这些图，它插入的是
`figures/` 里现有的 PDF，所以要先重编图，再编论文。版图图的底图不能从本仓重新生成，原因见
[figures/README.zh-CN.md](figures/README.zh-CN.md)。

`pdf/` 存放预先编好的两个入口的分享版，供没有装 TeX 的读者直接看：`pdf/scalenative-draft-acm.pdf` 与
`pdf/scalenative-draft-ieee.pdf`。它们是缺省的 `./build.sh` 跑出来的 `out/main-acm.pdf` 与
`out/main-ieee.pdf` 的拷贝。没有任何东西会自动更新它们：正文、表或图改了之后，要把这两个文件
重新拷一遍。`pdf/` 里的 PDF 与源文件有出入时，以源文件为准。在这里编出的 PDF 不记录所插入的图的
文件名（`preamble/common.tex` 里的 `\pdfsuppressptexinfo`，只对 pdfTeX 有效）；TeX 发行版的生成器
字样与创建时间仍然会写进去。

## 开关

开关是一个存着一个词的宏。它们由 `build.sh` 设置；完整的清单与缺省值在
`preamble/switches.tex` 的开头。

| 想要什么 | 命令 |
|---|---|
| 分享版（印姓名，没有横幅，占位可见） | `./build.sh` |
| 双盲版，不针对某个会议 | `./build.sh submit` |
| ASPLOS 2027 的选项（`sigplan, anonymous, review, nonacm`） | `./build.sh submit --venue=asplos27` |
| MICRO 2026 的模板（`sigconf, screen, review`，有横幅） | `./build.sh submit --venue=micro26 --id=123` |
| ISCA 2026 的模板（横幅放在作者行的位置） | `./build.sh submit --venue=isca26 --id=123` |
| HPCA 2027 的模板（横幅是单独的一块） | `./build.sh submit --venue=hpca27 --id=123` |
| 预览 MICRO 的版式，不带横幅 | `./build.sh --venue=micro26` |
| 只编一个入口 | `./build.sh --only=acm` |
| 去掉占位（每句话是否仍然读得通？） | `./build.sh --tbd=none` |
| 占位用隐形墨水（即用 `--set PaperParTags=no` 构建时的版面） | `./build.sh --tbd=blank` |
| 按字数预算核页数 | `./build.sh --fill` |
| 把 `refs.bib` 全部印出来 | `./build.sh --nocite-all` |
| 其它开关 | `./build.sh --set PaperParTags=no --set PaperAIUse=yes` |

下面几条是内置的规则，关不掉：

- 会议的投稿横幅（"… Submission #N – Confidential Draft – Do NOT Distribute!!"）只在
  `submit` 构建、且所选会议的模板带横幅时才印。分享版永远不印。
- 匿名版完全不读 `authors.tex`，不印致谢、草稿说明和公开仓的链接。
- `--tbd=blank` 会把占位的文字留在 PDF 的文本层里。它只用来核页数，绝不要用于投稿。

各种变体写到 `out/<entry>--<variant>.pdf`，所以不会覆盖分享版。

### 各会议的差别

下表是 2026-10-05 从各会议的网页读到的。这一轮四家的截稿日期都已经过了，下一轮的规则当时
还没有公布；投稿之前请再核一遍。

| | ASPLOS 2027 | MICRO 2026 | ISCA 2026 | HPCA 2027 |
|---|---|---|---|---|
| 入口 | `main-acm` | `main-acm` | `main-ieee` | `main-ieee` |
| 正文字号 | 10 pt | 9 pt | 10 pt | 10 pt |
| 页数上限（不含参考文献） | 11 | 11 | 11 | 11 |
| 第 1 页的横幅 | 没有 | 有 | 有 | 有 |
| 投稿稿里的致谢 | 只许放 AI 使用说明 | 不允许 | 放 AI 使用说明 | — |
| AI 使用说明（`--set PaperAIUse=yes`） | 在参考文献之前，不计页数 | 不印 | 在致谢里，计页数 | 参考文献之后的附录 "AI use"，不计页数 |
| 附录（`--set PaperAppendix=yes`） | 允许，不计页数 | 不允许（会被压掉） | 计入页数上限 | 没有说明 |
| 图内的文字 | 不小于 8 pt | "legible" | "legible" | "legible" |

MICRO 与 ASPLOS 会拒收压缩版面的稿子。任何地方都不要用 `\vspace`、负的间距，或改变间距的
宏包。

## `sections/*.tex` 的写作规则

1. **不用依赖文档类的命令。** 同一个文件要在 acmart 与 IEEEtran 下都能编译。
2. **引用只用 `\cite{key}`**（IEEEtran 没有 natbib）。还没有进 `refs.bib` 的出处，写成
   `\citeTBD{name of the source}`。
3. **交叉引用**写成 `\figref{fig:x}`、`\tabref{tab:x}`、`\secref{sec:x}`；它们会印出各
   文档类自己用的词。
4. **术语**里要保持一致、或者还可能改的，是 `preamble/terms.tex` 里的宏（`\TensorUnit`、
   `\VectorUnit`、`\armBD` … `\armSM`、`\evRTL`、`\evPostRoute`、`\SysName` 等）。图上
   标出来的名字，正文里照图上的写法写。物理结果一律不叫 "measured"。
5. **正文里不写版面**：图的尺寸取自 `preamble/float-budget.tex`；排好的表，表体连同字号与栏宽
   单独放在 `tables/` 下的一个文件里。

### 文本单元与编号

每一段、每一条图注或表注都是一个*文本单元*。它以一行标记开头；段落另带一个可以印出来的
标签：

```latex
%% P:sec3.2-p1
\ptag{sec3.2-p1}%
Text of the paragraph ...
```

- 编号是标识，不是位置：`sec3.2-p1`、`abs-p1`、`fig5-cap`、`tab2-cap`。编号一经给出就
  **冻结**：不重排，不复用。后来插入的段落加后缀（`sec3.2-p1a`）；删掉的段落留下空号；挪动
  的段落保留原来的编号。
- 除标题与注释之外，任何内容都不能落在文本单元之外，而且一个文本单元就是一段：新的一段要有
  自己的标记行与编号（空行之后还有文字的话，检查器会报出来）。
- `\section{...}\label{sec:...}` 与 `\subsection{...}\label{sec:...}` 要写在同一行。
- 摘要文件里不能有空行。

还没有写的文本单元里放的是 `\Intent{...}`（一句话的提要）、占位，以及
`\fillto{n}`（这一段的字数预算，供 `--fill` 使用）。写某一段时，把 `\Intent{...}` 与
`\fillto{...}` 两行换成正文，保留标记、标签和仍然开着的占位。目前已经没有只是提要的文本单元。

### 占位

```latex
Each PE has two Vector cores \TBD{D1}{form, width and division of labour of the two cores}.
```

会印成 `[TBD-D1: form, width and division of labour of the two cores]`。

- 每个待定事项一个编号，它出现在哪里都用同一个编号。在用的类别：`D<n>` 硬件设计事项，
  `E<n>` 实验，`P` 性能数据的来源，`C` 贡献的组织，`N` 名称与措辞，`W` 还没写的文字。
- 描述用平实的话说明在等什么（至多十二个词左右），不带引用与括号。不要在占位的位置写一个
  编出来的数或方向。
- 去掉占位之后，句子必须仍然读得通（`./build.sh --tbd=none`）。
- 分享版的末尾有一份未关闭占位的索引（`W` 类不列）。
  `python3 check_align.py --tbd-table` 把同样的内容打印成 Markdown 表格。

### 图与表

每张图、每张表都有一个位置：

```latex
%% P:fig5-cap
\FigSlot{fig:pe}%
  {what the figure shows}%
  {status}%
  {caption}
```

图画好之前，这个位置是一个按预算尺寸画的空框，所以构建出来的页数已经接近实际。空框里印的是
「这张图画什么」与它的状态。图登记之后，PDF 取代空框，这两段文字不再印出来。其中「这张图画
什么」这一段此后用作这张图的替代文字（acmart 的 `\Description`），所以要把它写成对成图实际
内容的描述。

- 单栏图按 **3.33 in** 宽画，通栏图按 **7.0 in** 宽画，高度取
  `preamble/float-budget.tex` 里给的值。图按原始尺寸插入，不做缩放；宽度偏差超过 1 pt 时
  构建会给出警告。
- 成图里的文字不小于 **8 pt**（最好 9 pt）。
- 导出矢量 PDF，字体全部嵌入，不带 Type 3 字体（`pdffonts figure.pdf`）。
- 不能只靠颜色来区分两样东西。
- 登记文件：在 `preamble/float-budget.tex` 里写 `\FloatFile{fig:pe}{figures/fig-pe}`。六张
  画好的图都已在那里登记。
- 要排一张表时，把它的 `\TabSlot{...}` 换成 `table`（或 `table*`）环境，`\label` 与标记行
  保持不变。环境里先写 `\centering\SlotName{<label>}%`，再写 `\caption` 与 `\label`，然后单独一行
  写 `\input{tables/<file>}`，中间不要留空行。`tables/` 里的那个文件放 tabular 与表脚：开头是
  `\TableSize`（在每种版式下都是 8 pt），栏距由它自己设，文件里同样不能有空行。七张表都是这样
  写的；`sections/06-results.tex` 里的 `tab:layout-runs` 与 `tables/tab-layout-runs.tex` 是一个
  例子。

## 中文对照稿

`paper.zh-CN.md` 与英文正文逐个文本单元对应，供读中文的作者把关。以英文正文为准。约定如下：

| 英文（LaTeX） | 中文（Markdown） |
|---|---|
| `%% P:sec3.2-p1` | 单独一行的 `<!-- P:sec3.2-p1 -->` |
| `\TBD{D1}{...}` | `[TBD-D1: ...]` |
| `\cite{KeyA,KeyB}` | `[@KeyA; @KeyB]` |
| `\citeTBD{Some source}` | `[ref: Some source]`（用词相同） |
| `\figref{fig:pe}`、`\secref{sec:retain}` | `[图 5](#fig:pe)`、`[§3.4](#sec:retain)` |
| `\FigSlot{fig:pe}...`、`\label{...}` | `<a id="fig:pe"></a>` |
| `\FigSlot` 里的 `{what the figure shows}` | `画的是：` 后面的几句（图还没画时写 `要画：`） |
| 排好的表（`tables/<file>.tex`） | 数字相同的 Markdown 表格，放在表注那一段之后；表脚并进表注那一段，写在 `表脚：` 之后；跨栏的格只写一次，被它盖住的格留空或写 `同左` |
| `\section{...}\label{sec:x}` | `## 3 标题 <a id="sec:x"></a>` |
| 数字、单位、模型名与格式名 | 写同样的数字（`FP32`、`5,580`、`12.5%`） |
| 写成单词的数（`three`） | 写成中文数字（`三`） |

给译者的说明写在 HTML 注释（`<!-- ... -->`）里，检查时会被忽略。

```sh
python3 check_align.py                                           # are the two the same version? (after a build it also
                                                                 # checks the numbers shown in the Chinese links)
python3 check_align.py --aux out/_build/main-acm/main-acm.aux    # the same, naming the .aux file explicitly
python3 check_align.py --selftest                                # the checker's own positive and negative controls
python3 check_align.py --list                                    # what was extracted from each unit
```

检查器逐个文本单元比较：编号及其次序、标题、用数字写的数、引用键、交叉引用、标签、占位的
编号，以及还要补的参考文献。它还会报出：格式不对的标记、落在文本单元之外的文字、`refs.bib`
里没有的引用键、指向未定义标签的引用，以及读了不同章节文件的入口文件。只有一侧仍是一句话
提要的文本单元，它也会报出来。表体在 `tables/` 里的表，它把那个文件当作读入它的文本单元的一部分
来读；`tables/` 里没有被任何单元读入、或被两个单元读入的文件，以及文本单元里别的 `\input`，它都会
报出来。它判断不了译文是否忠实；计量单位、正负号和写成单词的数，它不比较。

## 作者

姓名只出现在 `authors.tex` 这一处：

```latex
\PaperAffil{a}{Institution}{City}{Country}
\PaperAuthor{Full Name}{a}{name@example.org}
```

有两个单位的作者写 `{a,b}`；最后一个参数留空就不印邮箱。姓名写全称。目前不印邮箱，也没有
标通讯作者。

## 把 PDF 发给别人之前

```sh
./build.sh --check        # both entries build; fonts embedded; English and Chinese aligned
./test_matrix.sh          # after changing an entry file or a file in preamble/
./build.sh && cp out/main-acm.pdf pdf/scalenative-draft-acm.pdf \
           && cp out/main-ieee.pdf pdf/scalenative-draft-ieee.pdf    # refresh the PDFs kept in pdf/
```

投稿时另外还要做：用 `submit --venue=...` 构建；确认没有留下占位
（`grep -rn 'TBD{' sections backmatter`）；读一遍会议当期的征稿启事；会议有要求时，给论文
换一个与任何公开版本都不同的标题（`\PaperTitleCore`；匿名版已经会把项目名从标题里去掉）；
在 `preamble/meta.tex` 里设置 `\PaperSysNameAnon`；如果有匿名的制品链接，用
`--set PaperRepoAnonURL=https://...` 传进来（`\RepoLink` 会印出它；不传的话 `\RepoLink`
印的是一句中性的话）。

## 已知的局限

- 各会议的预设照的是 ASPLOS 2027、MICRO 2026、ISCA 2026 与 HPCA 2027 的模板，没有经过
  任何一家会议的格式检查器。
- 会议模板下不匿名的终稿（camera-ready）构建没有实现。
- `page_report.py` 靠参考文献的标题来定位参考文献表；没有参考文献时它什么也不报。
- 用 `--fill` 时会印出整个参考文献库，因为带引用的提要被隐藏了。

**English** | [简体中文](README-build.zh-CN.md)

# Building the paper

A Chinese version of this file is in [README-build.zh-CN.md](README-build.zh-CN.md). Where the two differ, this English version is the reference.

This directory holds the LaTeX source of the paper, its figures and a Chinese companion draft.
The text is written once, in class-independent section files, and compiled through two
thin entry files: `main-acm.tex` (acmart, the primary one) and `main-ieee.tex` (IEEEtran).
What may be done with the material in this directory is stated in [README.md](README.md).

At the moment the paper is a **first full draft**: every paragraph and caption is written, and results are
placeholders. Six figures are in place (`fig:system`, `fig:pe`, `fig:tensor`, `fig:vector`, `fig:flow` and
`fig:layout`) and all seven tables are typeset; two cells of `tab:placements` hold placeholders. The other
eight figures (`fig:handoff`, `fig:workload`, `fig:retain`, `fig:payoff`, `fig:correct`, `fig:metadata`,
`fig:failvis-cost` and `fig:system-proj`) are still empty frames of the budgeted size.

Page counts of this state, read from the build report on 2026-10-06 (TeX Live 2025): the body, which is
everything up to the references, takes 11.00 pages in the share build of the ACM entry and 10.42 in that of
the IEEE entry; in the submission builds it takes 10.94 pages (ASPLOS 2027), 10.18 (MICRO 2026), 10.15
(ISCA 2026) and 10.25 (HPCA 2027). All four venues allow 11. The share build of the ACM entry fills
page 11 to the last line: one more line of text moves it past 11 pages.

## Quick start

```sh
./build.sh            # share build of both entries -> out/main-acm.pdf, out/main-ieee.pdf
./build.sh --check    # the same, then compare the English text with the Chinese draft
./build.sh --help     # every option
```

Requirements: TeX Live 2025 or later with `latexmk`, `pdflatex`, `bibtex`, the `acmart`
class (v2.16 was used) and the `IEEEtran` class (V1.8b) with their fonts and `.bst` files;
on Debian/Ubuntu these come from `texlive-publishers` (both classes and their `.bst` files),
`texlive-fonts-extra` (the fonts acmart uses), `texlive-latex-extra`,
`texlive-latex-recommended`, `texlive-fonts-recommended` and `latexmk`. `pdfinfo`, `pdffonts` and `pdftotext`
(poppler) and `python3` are used for the report printed after each build; the build itself
does not need them. The class files are not kept in this directory: use the ones of the
TeX distribution, or the ones a venue prescribes when submitting.

`build.sh` runs `latexmk` with shell escape disabled and without reading any `latexmkrc`.
Both entry files also compile with a plain `latexmk -pdf main-acm.tex` (for example on
Overleaf); that gives the share build.

After each build the script prints: the switches in effect, undefined references, overfull
boxes (horizontal and vertical), BibTeX errors and warnings, the page count, where the body ends (pages up to the
references, which is what the venues count; the placeholders take room too, so compare the default
build with `--tbd=none`; `--fill` pads only units that still carry `\fillto`, and none does now), and whether every font is embedded and none is Type 3. It fails if a font is not embedded, if a share build shows a venue banner, or if an
anonymous build shows a name, an email or an institution from `authors.tex`, the public system name or the public
repository URL (`preamble/meta.tex`) in its text or metadata.

## Layout

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

Only the two entry files and `preamble/authors-*.tex` know which class is in use.

## The `figures/` and `pdf/` directories

`figures/` holds the six finished figures. Each one is a PDF that lies next to the source it is built
from: TikZ sources with one shared style file for the five architecture figures, and a short LaTeX file
drawn over a base image for the layout figure. [figures/README.md](figures/README.md) describes every
file, the tools the figure build needs, and where the layout figure comes from.

```sh
cd figures
./build-figures.sh                # rebuild and check all six figures
./build-figures.sh fig-pe         # one figure
./build-figures.sh --check-only   # check the PDFs that are there, build nothing
```

After building a figure the script checks its PDF: the page is exactly 3.33 in or 7.0 in wide and as
high as the slot of the figure, every font is embedded and none is a Type 3 font, and no lettering is
smaller than 8 bp. The build of the paper does not rebuild the figures. It includes the PDFs that are in
`figures/`, so rebuild a figure first and the paper after it. The base image of the layout figure cannot
be regenerated from this repository; [figures/README.md](figures/README.md) says why.

`pdf/` holds the share build of both entries, compiled in advance for readers who have no TeX
installation: `pdf/scalenative-draft-acm.pdf` and `pdf/scalenative-draft-ieee.pdf`. They are copies of
`out/main-acm.pdf` and `out/main-ieee.pdf` from a default `./build.sh` run. Nothing refreshes them
automatically: copy the two files again when the text, a table or a figure changes. Where a PDF in `pdf/`
and the sources differ, the sources are the reference. A PDF built here records no file names of the
included figures (`\pdfsuppressptexinfo` in `preamble/common.tex`, pdfTeX only). It still carries the
producer string of the TeX distribution and its creation time.

## Switches

A switch is a macro that holds a word. `build.sh` sets them; the full list with defaults is
at the top of `preamble/switches.tex`.

| What you want | Command |
|---|---|
| Share build (names printed, no banner, placeholders visible) | `./build.sh` |
| Double-blind build, no particular venue | `./build.sh submit` |
| ASPLOS 2027 options (`sigplan, anonymous, review, nonacm`) | `./build.sh submit --venue=asplos27` |
| MICRO 2026 template (`sigconf, screen, review`, banner) | `./build.sh submit --venue=micro26 --id=123` |
| ISCA 2026 template (banner as the author line) | `./build.sh submit --venue=isca26 --id=123` |
| HPCA 2027 template (banner block) | `./build.sh submit --venue=hpca27 --id=123` |
| Preview the MICRO page format without a banner | `./build.sh --venue=micro26` |
| One entry only | `./build.sh --only=acm` |
| Placeholders removed (does every sentence still read?) | `./build.sh --tbd=none` |
| Placeholders in invisible ink (the layout of a build with `--set PaperParTags=no`) | `./build.sh --tbd=blank` |
| Page-count check against the word budget | `./build.sh --fill` |
| Print all of `refs.bib` | `./build.sh --nocite-all` |
| Any other switch | `./build.sh --set PaperParTags=no --set PaperAIUse=yes` |

Rules that are built in and cannot be switched off:

- A venue banner ("… Submission #N – Confidential Draft – Do NOT Distribute!!") is printed
  only by a `submit` build for a venue whose template has one. A share build never prints it.
- An anonymous build does not read `authors.tex` at all and prints no acknowledgments, no
  draft note and no public repository link.
- `--tbd=blank` leaves the placeholder words in the text layer of the PDF. Use it to check
  page counts, never for a submission.

Variants are written to `out/<entry>--<variant>.pdf`, so they do not overwrite the share build.

### What differs between venues

Read from the venues' pages on 2026-10-05. All four deadlines of that cycle have passed and
the next cycle's rules were not published; check them again before submitting.

| | ASPLOS 2027 | MICRO 2026 | ISCA 2026 | HPCA 2027 |
|---|---|---|---|---|
| Entry | `main-acm` | `main-acm` | `main-ieee` | `main-ieee` |
| Body font | 10 pt | 9 pt | 10 pt | 10 pt |
| Page limit (references excluded) | 11 | 11 | 11 | 11 |
| Banner on page 1 | none | yes | yes | yes |
| Acknowledgments in a submission | AI-use statement only | not allowed | AI-use statement | — |
| AI-use statement (`--set PaperAIUse=yes`) | before the references, not counted | not printed | in the acknowledgments, counted | appendix "AI use" after the references, not counted |
| Appendix (`--set PaperAppendix=yes`) | allowed, not counted | not allowed (suppressed) | counted in the limit | not stated |
| Lettering inside figures | at least 8 pt | "legible" | "legible" | "legible" |

MICRO and ASPLOS reject papers that squeeze the layout. Do not use `\vspace`, negative
skips or packages that change spacing, anywhere.

## Writing rules for `sections/*.tex`

1. **No class-specific commands.** The same file is compiled under acmart and IEEEtran.
2. **Cite with `\cite{key}` only** (IEEEtran has no natbib). A source that is not yet in
   `refs.bib` is written `\citeTBD{name of the source}`.
3. **Cross references** are `\figref{fig:x}`, `\tabref{tab:x}`, `\secref{sec:x}`; they print
   the word each class uses.
4. **Terms** that must stay consistent or may still change are macros in
   `preamble/terms.tex` (`\TensorUnit`, `\VectorUnit`, `\armBD` … `\armSM`, `\evRTL`,
   `\evPostRoute`, `\SysName`, …). A name that is lettered on a figure is written in the text as it
   is written there. A physical result is never called "measured".
5. **No layout in the text**: figure sizes come from `preamble/float-budget.tex`, and the body of a
   typeset table, with its type size and column widths, lives in its own file under `tables/`.

### Units and their ids

Every paragraph and every caption is a *unit*. It starts with a marker line and, for
paragraphs, a tag that can be printed:

```latex
%% P:sec3.2-p1
\ptag{sec3.2-p1}%
Text of the paragraph ...
```

- The id is an identifier, not a position: `sec3.2-p1`, `abs-p1`, `fig5-cap`, `tab2-cap`.
  Once given, an id is **frozen**: never renumber, never reuse. A paragraph inserted later
  takes a suffix (`sec3.2-p1a`); a deleted one leaves a gap; a moved one keeps its id.
- Nothing may stand outside a unit except headings and comments, and a unit is one paragraph:
  a new paragraph needs its own marker line and id (the checker reports text after a blank line).
- `\section{...}\label{sec:...}` and `\subsection{...}\label{sec:...}` stay on one line.
- The abstract file must not contain blank lines.

A unit that is not written yet holds `\Intent{...}` (a one-sentence stub),
placeholders, and `\fillto{n}` (the word budget of the paragraph, used by `--fill`). When
you write a paragraph, replace the `\Intent{...}` and `\fillto{...}` lines with the text and
keep the marker, the tag and the placeholders that are still open. No unit is a stub at the moment.

### Placeholders

```latex
Each PE has two Vector cores \TBD{D1}{form, width and division of labour of the two cores}.
```

prints `[TBD-D1: form, width and division of labour of the two cores]`.

- One id per open item, the same id wherever the item appears. Classes in use: `D<n>`
  hardware design items, `E<n>` experiments, `P` source of performance data, `C` contribution
  structure, `N` names and wording, `W` text still to be written.
- The description says what is awaited, in plain words (at most about twelve), with no
  references or brackets. Do not write an invented number or a direction in its place.
- The sentence must still read when the placeholder is removed (`./build.sh --tbd=none`).
- The share build ends with an index of the open placeholders (class `W` is left out).
  `python3 check_align.py --tbd-table` prints the same information as a Markdown table.

### Figures and tables

Each figure and table has a slot:

```latex
%% P:fig5-cap
\FigSlot{fig:pe}%
  {what the figure shows}%
  {status}%
  {caption}
```

Until the figure exists the slot is an empty frame of the budgeted size, so the page count
of a build is already realistic. The frame prints what the figure shows and its status. Once the
figure is registered, the PDF takes the place of the frame and these two texts are no longer printed.
The text that says what the figure shows then serves as the alternative text of the figure
(`\Description` in acmart), so write it as a description of what the finished figure actually shows.

- Draw a single-column figure **3.33 in** wide and a full-width figure **7.0 in** wide, at
  the height given in `preamble/float-budget.tex`. Figures are included at their natural
  size and are never scaled; the build warns when the width is off by more than 1 pt.
- No lettering smaller than **8 pt** in the finished size (9 pt preferred).
- Export vector PDF with all fonts embedded and no Type 3 fonts (`pdffonts figure.pdf`).
- Colour must not be the only way to tell two things apart.
- Register the file: `\FloatFile{fig:pe}{figures/fig-pe}` in `preamble/float-budget.tex`. The six
  finished figures are registered there.
- To typeset a table, replace its `\TabSlot{...}` by a `table` (or `table*`) environment
  with the same `\label` and the same marker line. Inside it write `\centering\SlotName{<label>}%`,
  then `\caption` and `\label`, then `\input{tables/<file>}` on a line of its own, and leave no blank
  line. The file in `tables/` holds the tabular and its footer: it starts with `\TableSize` (8 pt in
  every page format), sets its own column separation, and contains no blank line either. All seven
  tables are written this way; `tab:layout-runs` in `sections/06-results.tex` with
  `tables/tab-layout-runs.tex` is an example.

## The Chinese companion draft

`paper.zh-CN.md` mirrors the English text unit by unit, for review by the authors who read
Chinese. The English text is authoritative. Conventions:

| English (LaTeX) | Chinese (Markdown) |
|---|---|
| `%% P:sec3.2-p1` | `<!-- P:sec3.2-p1 -->` on a line of its own |
| `\TBD{D1}{...}` | `[TBD-D1: ...]` |
| `\cite{KeyA,KeyB}` | `[@KeyA; @KeyB]` |
| `\citeTBD{Some source}` | `[ref: Some source]` (same words) |
| `\figref{fig:pe}`, `\secref{sec:retain}` | `[图 5](#fig:pe)`, `[§3.4](#sec:retain)` |
| `\FigSlot{fig:pe}...`, `\label{...}` | `<a id="fig:pe"></a>` |
| `{what the figure shows}` in `\FigSlot` | the sentences after `画的是：` (`要画：` while the figure is not drawn) |
| a typeset table (`tables/<file>.tex`) | a Markdown table with the same numbers, after the caption paragraph; the footer of the table goes into that paragraph, after `表脚：`; a cell that spans columns is written once, and the cells it covers stay empty or say `同左` |
| `\section{...}\label{sec:x}` | `## 3 标题 <a id="sec:x"></a>` |
| numbers, units, model and format names | the same digits (`FP32`, `5,580`, `12.5%`) |
| a number spelled as a word (`three`) | a Chinese numeral (`三`) |

Notes for the translator go in HTML comments (`<!-- ... -->`); they are ignored.

```sh
python3 check_align.py                                           # are the two the same version? (after a build it also
                                                                 # checks the numbers shown in the Chinese links)
python3 check_align.py --aux out/_build/main-acm/main-acm.aux    # the same, naming the .aux file explicitly
python3 check_align.py --selftest                                # the checker's own positive and negative controls
python3 check_align.py --list                                    # what was extracted from each unit
```

The checker compares, unit by unit, the ids and their order, the headings, the numbers
written with digits, the citation keys, the cross references, the labels, the placeholder
ids and the references still to be added. It also reports malformed markers, text outside
any unit, citation keys missing from `refs.bib`, references to undefined labels, and entry
files that read different section files. It also reports a unit that is still a one-sentence stub on one side only.
It reads the body of a table from `tables/` as part of the unit that inputs it, and reports a file in
`tables/` that no unit reads or that two units read, and any other `\input` inside a unit.
It cannot tell whether a translation is faithful; it does not compare units of measurement, signs, or numbers spelled as words.

## Authors

`authors.tex` is the only place where names appear:

```latex
\PaperAffil{a}{Institution}{City}{Country}
\PaperAuthor{Full Name}{a}{name@example.org}
```

An author with two affiliations takes `{a,b}`; an empty last argument prints no email.
Names are written in full. No email is printed and no corresponding author is marked yet.

## Before sending a PDF to anyone

```sh
./build.sh --check        # both entries build; fonts embedded; English and Chinese aligned
./test_matrix.sh          # after changing an entry file or a file in preamble/
./build.sh && cp out/main-acm.pdf pdf/scalenative-draft-acm.pdf \
           && cp out/main-ieee.pdf pdf/scalenative-draft-ieee.pdf    # refresh the PDFs kept in pdf/
```

For a submission, additionally: build with `submit --venue=...`; make sure no placeholder is
left (`grep -rn 'TBD{' sections backmatter`); read the venue's current call for papers; give
the paper a title that differs from any public version if the venue asks for it (`\PaperTitleCore`;
an anonymous build already drops the project name from the title); set
`\PaperSysNameAnon` in `preamble/meta.tex`; and, if there is an anonymized artifact link,
pass it with `--set PaperRepoAnonURL=https://...` (`\RepoLink` then prints it; without it
`\RepoLink` prints a neutral phrase).

## Known limits

- The venue presets follow the templates of ASPLOS 2027, MICRO 2026, ISCA 2026 and HPCA 2027.
  They have not been run through any venue's format checker.
- A non-anonymous camera-ready build of a venue template is not implemented.
- `page_report.py` locates the reference list by its heading; if there are no references it
  reports nothing.
- With `--fill` the whole bibliography is printed, because the stubs that carry the citations
  are hidden.

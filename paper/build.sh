#!/usr/bin/env bash
# build.sh -- one command builds the paper with latexmk; PDFs land in out/.
#
#   ./build.sh                       share build of both entries -> out/main-acm.pdf, out/main-ieee.pdf
#   ./build.sh --help                all options
#
# Needs: latexmk, pdflatex, bibtex (TeX Live 2025 or later with acmart and IEEEtran).
# Uses, when present: pdfinfo, pdffonts, pdftotext (poppler) for the report after each build.
# No make, no shell escape, no network.
set -euo pipefail
cd "$(dirname "$0")"

usage() {
  cat <<'EOF'
usage: ./build.sh [share|submit] [options]

  share                 (default) the version circulated among the authors: names printed,
                        no venue banner, open placeholders visible
  submit                double-blind version: anonymous, no acknowledgments; with --venue
                        also the class options and the banner of that venue's template

  --venue=V             asplos27 | micro26 (ACM entry only) | isca26 | hpca27 (IEEE entry only)
  --id=N                submission number printed in a banner (default NaN)
  --only=acm|ieee       build one entry only
  --tbd=show|blank|none placeholders: visible / same layout in invisible ink / removed
  --fill                pad every paragraph and caption to its word budget (page-count check;
                        placeholders are removed unless --tbd is given)
  --nocite-all          print every entry of refs.bib (a test of the bibliography)
  --set NAME=VALUE      set any switch of preamble/switches.tex, e.g. --set PaperParTags=no
  --check               after a default share build, also run check_align.py
  --clean               delete out/ and stop
  -h, --help            this text

Output: out/<entry>[--<variant>].pdf ; intermediate files in out/_build/<entry>[--<variant>]/.
Exit status: 0 ok; 1 a build failed; 3 a PDF has a font that is not embedded or is Type 3;
4 a share build shows a venue banner; 5 an anonymous build shows an author name, an email, an institution,
the public system name or the public repository URL; 6 check_align.py failed.
EOF
}

MODE=share; VENUE=none; ID=""; ONLY=both; CHECK=0
SETS=()              # NAME=VALUE pairs, in the order given
TAG=""
addtag() { TAG="${TAG:+$TAG-}$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    share|submit) MODE=$1 ;;
    --venue=*)    VENUE=${1#*=} ;;
    --id=*)       ID=${1#*=} ;;
    --only=*)     ONLY=${1#*=} ;;
    --tbd=*)      SETS+=("PaperTBD=${1#*=}"); addtag "tbd-${1#*=}" ;;
    --fill)       SETS+=("PaperFill=yes"); addtag fill ;;
    --nocite-all) SETS+=("PaperNociteAll=yes"); addtag nociteall ;;
    --set)        shift; [ $# -gt 0 ] || { echo "build.sh: --set needs NAME=VALUE" >&2; exit 2; }
                  case "$1" in Paper[A-Za-z]*=*) ;; *) echo "build.sh: --set wants PaperName=value, got '$1'" >&2; exit 2 ;; esac
                  SETS+=("$1")
                  k=$(printf '%s' "${1%%=*}" | sed 's/^Paper//' | tr 'A-Z' 'a-z'); v=${1#*=}
                  case "$v" in *[!A-Za-z0-9]*|"") addtag "$k" ;; *) addtag "$k-$(printf '%s' "$v" | tr 'A-Z' 'a-z')" ;; esac ;;
    --check)      CHECK=1 ;;
    --clean)      rm -rf out; echo "removed out/"; exit 0 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "build.sh: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
  shift
done

case "$ONLY" in both|acm|ieee) ;; *) echo "build.sh: --only=acm|ieee" >&2; exit 2 ;; esac
case "$VENUE" in
  none)             ENTRIES="main-acm main-ieee" ;;
  asplos27|micro26) ENTRIES="main-acm" ;;
  isca26|hpca27)    ENTRIES="main-ieee" ;;
  *) echo "build.sh: unknown venue '$VENUE'" >&2; exit 2 ;;
esac
[ "$ONLY" = acm ]  && ENTRIES=$(printf '%s\n' $ENTRIES | grep -x main-acm  || true)
[ "$ONLY" = ieee ] && ENTRIES=$(printf '%s\n' $ENTRIES | grep -x main-ieee || true)
[ -n "$ENTRIES" ] || { echo "build.sh: venue '$VENUE' is not implemented by the entry selected with --only=$ONLY" >&2; exit 2; }

# TeX code placed in front of \input{<entry>}: one \def per switch
PRETEX=""
VARIANT=""
if [ "$MODE" != share ] || [ "$VENUE" != none ]; then
  PRETEX="\\def\\PaperMode{$MODE}\\def\\PaperVenue{$VENUE}"
  VARIANT="$MODE"; [ "$VENUE" != none ] && VARIANT="$VARIANT-$VENUE"
fi
[ -n "$ID" ] && PRETEX="$PRETEX\\def\\PaperSubmissionID{$ID}"
for kv in ${SETS[@]+"${SETS[@]}"}; do PRETEX="$PRETEX\\def\\${kv%%=*}{${kv#*=}}"; done
[ -n "$TAG" ] && VARIANT="${VARIANT:+$VARIANT-}$TAG"

have() { command -v "$1" >/dev/null 2>&1; }
# Strings that must not appear in an anonymous PDF, one per line: author names and emails,
# institutions (authors.tex), the public system name and the public repository URL (preamble/meta.tex).
identifying_strings() {
  sed -n 's/^[[:space:]]*\\PaperAuthor{\([^}]*\)}.*/\1/p' authors.tex
  sed -n 's/^[[:space:]]*\\PaperAuthor{[^}]*}{[^}]*}{\([^}]*\)}.*/\1/p' authors.tex
  sed -n 's/^[[:space:]]*\\PaperAffil{[^}]*}{\([^}]*\)}.*/\1/p' authors.tex | tr ',' '\n'
  sed -n 's/^\\newcommand{\\PaperSysNamePublic}{\([^}]*\)}.*/\1/p' preamble/meta.tex | grep -v '[][~]' || true
  sed -n 's/^\\providecommand{\\PaperRepoURL}{\([^}]*\)}.*/\1/p' preamble/meta.tex
}
for t in latexmk pdflatex bibtex; do have "$t" || { echo "build.sh: $t not found" >&2; exit 1; }; done

# long log lines, so that warnings can be counted with grep
export max_print_line=1000 error_line=254 half_error_line=238
mkdir -p out/_build
STATUS=0
for E in $ENTRIES; do
  NAME="$E${VARIANT:+--$VARIANT}"
  BDIR="out/_build/$NAME"
  mkdir -p "$BDIR"
  rm -f "out/$NAME.pdf"      # a failed build must not leave the PDF of an earlier build behind
  echo "== $NAME"
  run_latexmk() {
    latexmk -norc -pdf -interaction=nonstopmode -halt-on-error -file-line-error \
        -outdir="$BDIR" -pretex="$PRETEX" -pdflatex='pdflatex -no-shell-escape %O %P' \
        "$E.tex" > "$BDIR/latexmk.out" 2>&1
  }
  # A failed run can leave a broken .bbl or .aux behind that fails every later run:
  # on failure, start once more from an empty build directory before giving up.
  if ! run_latexmk; then
    rm -rf "$BDIR"; mkdir -p "$BDIR"
    echo "   first attempt failed; retrying from an empty build directory"
  fi
  if [ ! -f "$BDIR/$E.pdf" ] && ! run_latexmk; then
    echo "   BUILD FAILED -- first errors (full output: $BDIR/latexmk.out, log: $BDIR/$E.log):"
    grep -n -m 5 -E '^[^ ]+:[0-9]+: |^! ' "$BDIR/$E.log" 2>/dev/null | sed 's/^/     /' || true
    STATUS=1; continue
  fi
  cp "$BDIR/$E.pdf" "out/$NAME.pdf"
  LOG="$BDIR/$E.log"; BLG="$BDIR/$E.blg"
  grep -m 1 '^\[paper\] build:' "$LOG" | sed 's/^/   /' || true
  UND=$(grep -c -E 'Warning: (Reference|Citation) .* undefined' "$LOG" || true)
  OVF=$(grep -c '^Overfull \\hbox' "$LOG" || true)
  OVV=$(grep -c '^Overfull \\vbox' "$LOG" || true)      # a page or column whose content is too high (e.g. floats that leave no room)
  PW=$(grep -c '^\[paper\] WARNING' "$LOG" || true)
  BE=0; BW=0
  if [ -f "$BLG" ]; then
    BE=$(grep -c -E '^(I couldn.t|---line|Illegal|Repeated entry|I was expecting|.*-- error)' "$BLG" || true)
    BW=$(grep -c '^Warning--' "$BLG" || true)
  fi
  echo "   log: undefined references/citations $UND; overfull hboxes $OVF, vboxes $OVV; [paper] warnings $PW; bibtex errors $BE, warnings $BW"
  [ "$PW" -gt 0 ] && grep '^\[paper\] WARNING' "$LOG" | sed 's/^/     /'
  if have pdfinfo; then
    echo "   pages: $(pdfinfo "out/$NAME.pdf" | awk '/^Pages:/{print $2}')   page size: $(pdfinfo "out/$NAME.pdf" | sed -n 's/^Page size: *//p')"
  fi
  if have pdftotext && have python3; then
    echo "   $(python3 page_report.py "out/$NAME.pdf" "$LOG" || true)"
  fi
  if have pdffonts; then
    FT=$(pdffonts "out/$NAME.pdf" | tail -n +3)
    NF=$(printf '%s\n' "$FT" | grep -c . || true)
    # columns of pdffonts: name type encoding emb sub uni object-ID ; "emb" is the 5th field from the end
    NOEMB=$(printf '%s\n' "$FT" | awk 'NF{ if ($(NF-4) != "yes") n++ } END{print n+0}')
    T3=$(printf '%s\n' "$FT" | grep -c 'Type 3' || true)
    echo "   fonts: $NF; not embedded: $NOEMB; Type 3: $T3"
    if [ "$NOEMB" -gt 0 ] || [ "$T3" -gt 0 ]; then
      printf '%s\n' "$FT" | sed 's/^/     /'; echo "   FONT CHECK FAILED"; [ "$STATUS" -eq 0 ] && STATUS=3
    fi
  fi
  if have pdftotext; then
    TXT=$(pdftotext "out/$NAME.pdf" - 2>/dev/null || true)
    META=$(have pdfinfo && pdfinfo "out/$NAME.pdf" || true)
    if [ "$MODE" = share ]; then
      if printf '%s\n' "$TXT" | grep -q -E 'Confidential Draft|Do NOT Distribute|Submission #'; then
        echo "   BANNER CHECK FAILED: a share build prints a venue banner"; [ "$STATUS" -eq 0 ] && STATUS=4
      else
        echo "   banner check: no venue banner in this share build"
      fi
    fi
    if grep -q 'anon=yes' <(grep -m 1 '^\[paper\] build:' "$LOG"); then
      # text layer, Info dictionary and XMP packet with all white space removed, so that a name or a URL
      # broken across two lines is still found; the second copy also undoes hyphenation at a line end
      XMP=$(have pdfinfo && pdfinfo -meta "out/$NAME.pdf" 2>/dev/null || true)
      HAY=$(printf '%s\n%s\n%s\n' "$TXT" "$META" "$XMP" | tr '\n\f\t' '   ' | tr -s ' ')
      HAY=$(printf '%s\n%s\n' "$(printf '%s' "$HAY" | tr -d ' ')" "$(printf '%s' "$HAY" | sed 's/- //g' | tr -d ' ')")
      LEAK=0; NWHO=0
      while IFS= read -r who; do
        who=$(printf '%s' "$who" | sed 's/^ *//; s/ *$//')
        [ -n "$who" ] || continue
        NWHO=$((NWHO+1))
        if printf '%s\n' "$HAY" | grep -q -i -F -- "$(printf '%s' "$who" | tr -d ' ')"; then echo "   ANONYMITY CHECK FAILED: '$who' appears in the PDF"; LEAK=1; fi
      done < <(identifying_strings)
      if [ "$LEAK" -eq 1 ]; then [ "$STATUS" -eq 0 ] && STATUS=5; else echo "   anonymity check: none of the $NWHO identifying strings (names, emails, institutions, public system name, repository URL) appears in the PDF text or metadata"; fi
    fi
  fi
  echo "   -> out/$NAME.pdf"
done

if [ "$CHECK" -eq 1 ]; then
  echo "== check_align.py"
  AUX="out/_build/main-acm/main-acm.aux"
  if [ -f "$AUX" ]; then python3 check_align.py --aux "$AUX" || STATUS=6; else python3 check_align.py || STATUS=6; fi
fi
exit "$STATUS"

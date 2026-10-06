#!/usr/bin/env bash
# Copyright 2026 The ScaleNative Authors.
# All rights reserved.  Not under the repository's Apache-2.0 license; see ../README.md.
#
# build-figures.sh -- build the figures of the paper and check every PDF.
#
#   ./build-figures.sh                  build and check all six figures
#   ./build-figures.sh fig-pe fig-flow  only the named figures
#   ./build-figures.sh --check-only     check the PDFs that are already here; build nothing
#   ./build-figures.sh --help
#
# Each figure is built with pdflatex (no shell escape) from fig-<name>.tex, and the PDF is written
# next to its source.  Three checks follow; a figure passes only if all three pass, and the script
# exits with 1 if any figure fails:
#   1. page size   one page, exactly 3.33 in or 7.0 in wide and as high as the table below says
#                  (pdfinfo; tolerance 0.002 in)
#   2. fonts       every font is embedded and none is a Type 3 font (pdffonts)
#   3. lettering   no text in the PDF is smaller than 8 bp (tools/check_figure_pdf.py)
# Not checked: whether anything is drawn outside the canvas, lettering printed over lettering,
# and lines through lettering.  Look at the result.
#
# Needs: pdflatex with TikZ, the standalone class and the TeX Gyre Heros fonts; pdfinfo and
# pdffonts (poppler); python3.  No make, no shell escape, no network.
# Intermediate files go to a temporary directory.  It is removed when everything passes and kept
# (its path is printed) when something fails.  Set FIG_BUILD_DIR to choose the directory yourself.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# name          width (in)  height (in)   -- the sizes of the figure slots in the paper
FIGURES="
fig-system      3.33        2.1
fig-pe          7.0         2.4
fig-tensor      7.0         1.9
fig-vector      7.0         2.4
fig-flow        3.33        1.5
fig-layout      3.33        3.33
"
MIN_BP=8          # smallest lettering allowed, in bp (1/72 in)
TOL_IN=0.002      # tolerance on the page size, in inches

usage() { sed -n '5,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CHECK_ONLY=0
WANT=()
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) WANT+=("${arg%.tex}") ;;
  esac
done

NEED="pdfinfo pdffonts python3"
[ "$CHECK_ONLY" -eq 1 ] || NEED="pdflatex $NEED"
for tool in $NEED; do
  command -v "$tool" > /dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done
for name in ${WANT[@]+"${WANT[@]}"}; do
  printf '%s\n' "$FIGURES" | awk -v n="$name" '$1 == n { found = 1 } END { exit !found }' \
    || { echo "not a figure of this directory: $name" >&2; exit 2; }
done

if [ "$CHECK_ONLY" -eq 0 ]; then
  if [ -n "${FIG_BUILD_DIR:-}" ]; then
    BUILD=$FIG_BUILD_DIR; KEEP=1; mkdir -p "$BUILD" || exit 2
    BUILD=$(cd "$BUILD" && pwd)
  else
    BUILD=$(mktemp -d) || exit 2; KEEP=0
  fi
fi

# build <name>: run pdflatex in the build directory, copy the PDF next to the source
build() {
  local name=$1
  ( cd "$BUILD" && TEXINPUTS="$HERE:${TEXINPUTS:-}" pdflatex -interaction=nonstopmode -halt-on-error \
      -no-shell-escape -jobname="$name" "\\input{$name.tex}" < /dev/null > "$name.stdout" 2>&1 ) || return 1
  cp "$BUILD/$name.pdf" "$HERE/$name.pdf"
}

# check <name> <width in> <height in>: the three checks; prints one line per check
check() {
  local name=$1 win=$2 hin=$3 pdf="$HERE/$1.pdf" rc=0 info pages wpt hpt fonts nf noemb t3 out trc line
  # 1. page size
  info=$(pdfinfo "$pdf" 2> /dev/null) || { echo "   page size: pdfinfo cannot read the file -> FAIL"; return 1; }
  pages=$(printf '%s\n' "$info" | awk '/^Pages:/ { print $2 }')
  wpt=$(printf '%s\n' "$info" | awk '/^Page size:/ { print $3 }')
  hpt=$(printf '%s\n' "$info" | awk '/^Page size:/ { print $5 }')
  if python3 -c "import sys
p, w, h, win, hin, tol = int(sys.argv[1]), float(sys.argv[2]) / 72, float(sys.argv[3]) / 72, float(sys.argv[4]), float(sys.argv[5]), float(sys.argv[6])
sys.exit(0 if p == 1 and abs(w - win) <= tol and abs(h - hin) <= tol else 1)" "${pages:-0}" "${wpt:-0}" "${hpt:-0}" "$win" "$hin" "$TOL_IN"
  then echo "   page size: ${pages} page, ${wpt} x ${hpt} bp = $win in x $hin in -> PASS"
  else echo "   page size: ${pages:-?} page(s), ${wpt:-?} x ${hpt:-?} bp, wanted $win in x $hin in -> FAIL"; rc=1
  fi
  # 2. fonts: pdffonts prints two header lines, then one line per font;
  #    counted from the right the columns are: object id (2 fields), uni, sub, emb
  fonts=$(pdffonts "$pdf" 2> /dev/null | tail -n +3)
  nf=$(printf '%s\n' "$fonts" | grep -c . || true)
  noemb=$(printf '%s\n' "$fonts" | awk 'NF { if ($(NF-4) != "yes") n++ } END { print n + 0 }')
  t3=$(printf '%s\n' "$fonts" | grep -c 'Type 3' || true)
  if [ "$nf" -gt 0 ] && [ "$noemb" -eq 0 ] && [ "$t3" -eq 0 ]
  then echo "   fonts: $nf, not embedded: $noemb, Type 3: $t3 -> PASS"
  else echo "   fonts: $nf, not embedded: $noemb, Type 3: $t3 -> FAIL"; rc=1
  fi
  # 3. smallest lettering
  out=$(python3 "$HERE/tools/check_figure_pdf.py" --min "$MIN_BP" "$pdf" 2>&1); trc=$?
  line=$(printf '%s\n' "$out" | grep -m 1 -e 'minimum >=' -e 'no text' -e 'cannot read' | sed 's/^ *//')
  if [ "$trc" -eq 0 ] && [ -n "$line" ]
  then echo "   lettering: $line"
  else case "$line" in *FAIL*) echo "   lettering: $line" ;; *) echo "   lettering: ${line:-the check did not run} -> FAIL" ;; esac
       printf '%s\n' "$out" | sed -n '/minimum >=/,$p' | tail -n +2 | sed 's/^ */      /'
       rc=1
  fi
  return $rc
}

FAILED=0; DONE=0
while read -r name win hin; do
  [ -n "$name" ] || continue
  if [ "${#WANT[@]}" -gt 0 ]; then
    case " ${WANT[*]} " in *" $name "*) ;; *) continue ;; esac
  fi
  DONE=$((DONE + 1))
  echo "== $name"
  if [ "$CHECK_ONLY" -eq 0 ]; then
    if ! build "$name"; then
      echo "   build: pdflatex failed, see $BUILD/$name.log"
      grep -n -m 5 '^!' "$BUILD/$name.log" 2> /dev/null | sed 's/^/      /'
      echo "FAIL $name"; FAILED=$((FAILED + 1)); continue
    fi
    echo "   build: $name.pdf written"
  elif [ ! -f "$HERE/$name.pdf" ]; then
    echo "   $name.pdf is not here"; echo "FAIL $name"; FAILED=$((FAILED + 1)); continue
  fi
  if check "$name" "$win" "$hin"; then echo "PASS $name"; else echo "FAIL $name"; FAILED=$((FAILED + 1)); fi
done <<EOF
$FIGURES
EOF

if [ "$CHECK_ONLY" -eq 0 ]; then
  if [ "$FAILED" -eq 0 ] && [ "$KEEP" -eq 0 ]; then rm -rf "$BUILD"; else echo "intermediate files: $BUILD"; fi
fi
if [ "$FAILED" -eq 0 ] && [ "$DONE" -gt 0 ]; then echo "ALL $DONE FIGURES PASS"; exit 0; fi
echo "$FAILED OF $DONE FIGURES FAIL"; exit 1

#!/usr/bin/env bash
# test_matrix.sh -- builds every variant of both entries and checks what must and must not be
# printed in each (venue banner, author names, acknowledgments, placeholders, AI-use statement,
# appendix).  Run it after touching an entry file, preamble/switches.tex or preamble/common.tex.
# Needs build.sh's tools plus pdfinfo and pdftotext.  Takes a few minutes.
#   ./test_matrix.sh            run everything
#   ./test_matrix.sh --keep     keep out/ from a previous run (default: start from an empty out/)
set -uo pipefail
cd "$(dirname "$0")"
[ "${1:-}" = "--keep" ] || rm -rf out
FAIL=0; N=0
BANNER='Confidential Draft'
NAME=$(sed -n 's/^[[:space:]]*\\PaperAuthor{\([^}]*\)}.*/\1/p' authors.tex | head -n 1)
[ -n "$NAME" ] || { echo "test_matrix: no \\PaperAuthor line in authors.tex"; exit 2; }

# text of a PDF as one line (line breaks become spaces), followed by its metadata
text() { { pdftotext "out/$1.pdf" - 2>/dev/null; pdfinfo "out/$1.pdf" 2>/dev/null; } | tr '\n\f' '  '; }
pages() { pdfinfo "out/$1.pdf" 2>/dev/null | awk '/^Pages:/{print $2}'; }
# expect <pdf> has|lacks <fixed string> <what>      (case is ignored: IEEE headings are small capitals;
# choose strings without hyphens and not inside a heading, where text extraction inserts spaces)
# probe <pdf> has|lacks <fixed string>: exit status 0 if true, 1 if false, 2 if the PDF is missing
probe() {
  [ -s "out/$1.pdf" ] || return 2
  local n; n=$(text "$1" | grep -c -i -F -- "$3" || true)
  if [ "$2" = has ]; then [ "$n" -gt 0 ]; else [ "$n" -eq 0 ]; fi
}
expect() {
  N=$((N+1))
  probe "$1" "$2" "$3"; local rc=$?
  if [ "$rc" -eq 0 ]; then printf '  ok    %-34s %-5s %s\n' "$1" "$2" "$4"
  elif [ "$rc" -eq 2 ]; then printf '  FAIL  %-34s does not exist, cannot check: %s\n' "$1" "$4"; FAIL=$((FAIL+1))
  else printf '  FAIL  %-34s should %s %s (searched for "%s")\n' "$1" "$2" "$4" "$3"; FAIL=$((FAIL+1)); fi
}
# control <expected probe status> <pdf> has|lacks <string> <what>: the probe itself must be able to say no
control() {
  N=$((N+1))
  probe "$2" "$3" "$4"; local rc=$?
  if [ "$rc" -eq "$1" ]; then printf '  ok    control: %s\n' "$5"
  else printf '  FAIL  control: %s (probe returned %s, expected %s)\n' "$5" "$rc" "$1"; FAIL=$((FAIL+1)); fi
}
build() {  # build <expected exit status> <args...>
  local want=$1; shift
  N=$((N+1))
  ./build.sh "$@" > out.matrix.log 2>&1; local rc=$?
  mkdir -p out; cat out.matrix.log >> out/matrix-builds.log; rm -f out.matrix.log
  if [ "$rc" -eq "$want" ]; then printf '  ok    build.sh %-40s exit %s\n' "$*" "$rc"
  else printf '  FAIL  build.sh %-40s exit %s, expected %s (see out/matrix-builds.log)\n' "$*" "$rc" "$want"; FAIL=$((FAIL+1)); fi
}

echo "== share build (default)"
build 0
control 1 main-acm lacks "$NAME"                   "the probe reports a name that is printed"
control 1 main-acm has   "zz-no-such-text-zz"      "the probe reports text that is absent"
control 2 no-such-pdf lacks "$NAME"                "the probe refuses a PDF that does not exist"
for e in main-acm main-ieee; do
  expect $e has   "$NAME"               "author names"
  expect $e lacks "$BANNER"             "venue banner"
  expect $e has   "[TBD"               "placeholders"
  expect $e has   "This list is"        "index of open placeholders"
  expect $e has   "Working draft"       "draft note on page 1"
  expect $e has   "acknowledgments, to be written" "acknowledgments stub"
  expect $e lacks "generative AI"       "AI-use statement"
  expect $e lacks "if any]" "appendix"
done

echo "== share build, MICRO page format (sigconf, 9 pt): still no banner"
build 0 --venue=micro26
expect main-acm--share-micro26 lacks "$BANNER" "venue banner"
expect main-acm--share-micro26 has   "$NAME"   "author names"

echo "== submit, no venue (both entries)"
build 0 submit
for e in main-acm--submit main-ieee--submit; do
  expect $e lacks "$NAME"               "author names"
  expect $e has   "Anonymous Author"    "anonymous author line"
  expect $e lacks "$BANNER"             "venue banner"
  expect $e lacks "acknowledgments, to be written" "acknowledgments"
  expect $e lacks "Working draft"       "draft note"
  expect $e lacks "This list is"        "index of open placeholders"
done

echo "== submit, per venue"
build 0 submit --venue=asplos27
expect main-acm--submit-asplos27 lacks "$NAME"            "author names"
expect main-acm--submit-asplos27 has   "Anonymous Author" "anonymous author line"
expect main-acm--submit-asplos27 lacks "$BANNER"          "venue banner (ASPLOS has none)"
build 0 submit --venue=micro26 --id=123
expect main-acm--submit-micro26 has   "MICRO 2026 Submission #123" "MICRO banner with the id"
expect main-acm--submit-micro26 lacks "$NAME"             "author names"
build 0 submit --venue=isca26 --id=45
expect main-ieee--submit-isca26 has   "ISCA 2026 Submission #45" "ISCA banner with the id"
control 1 main-ieee--submit-isca26 lacks "$BANNER"  "the probe sees a venue banner where there is one"
expect main-ieee--submit-isca26 lacks "$NAME"             "author names"
build 0 submit --venue=hpca27
expect main-ieee--submit-hpca27 has   "HPCA 2027 Submission #NaN" "HPCA banner with the default id"
expect main-ieee--submit-hpca27 lacks "$NAME"             "author names"

echo "== AI-use statement and appendix, where each venue wants them"
build 0 --set PaperAIUse=yes --set PaperAppendix=yes
for e in main-acm--aiuse-yes-appendix-yes main-ieee--aiuse-yes-appendix-yes; do
  expect $e has "generative AI"          "AI-use statement"
  expect $e has "if any]" "appendix"
done
build 0 submit --venue=asplos27 --set PaperAIUse=yes --set PaperAppendix=yes
expect main-acm--submit-asplos27-aiuse-yes-appendix-yes has "generative AI"          "AI-use statement (acmart drops the acks environment when anonymous)"
expect main-acm--submit-asplos27-aiuse-yes-appendix-yes has "if any]" "appendix"
build 0 submit --venue=micro26 --set PaperAIUse=yes --set PaperAppendix=yes
expect main-acm--submit-micro26-aiuse-yes-appendix-yes lacks "generative AI"          "AI-use statement (MICRO: no acknowledgments)"
expect main-acm--submit-micro26-aiuse-yes-appendix-yes lacks "if any]" "appendix (MICRO: none allowed)"
build 0 submit --venue=isca26 --set PaperAIUse=yes
expect main-ieee--submit-isca26-aiuse-yes has "generative AI" "AI-use statement"
build 0 submit --venue=hpca27 --set PaperAIUse=yes
expect main-ieee--submit-hpca27-aiuse-yes has "generative AI" "AI-use statement"

echo "== placeholders: blank and none"
build 0 --tbd=none
build 0 --tbd=blank
for e in main-acm main-ieee; do
  expect $e--tbd-none  lacks "[TBD" "placeholders"
  expect $e--tbd-blank has   "[TBD" "placeholder text in the text layer (invisible ink; not for submission)"
  N=$((N+1))
  if [ "$(pages $e)" = "$(pages $e--tbd-blank)" ] || [ "$(pages $e--tbd-blank)" -lt "$(pages $e)" ]; then
    printf '  ok    %-34s pages %s (default build %s; the default also prints the index page)\n' "$e--tbd-blank" "$(pages $e--tbd-blank)" "$(pages $e)"
  else printf '  FAIL  %-34s has more pages (%s) than the default build (%s)\n' "$e--tbd-blank" "$(pages $e--tbd-blank)" "$(pages $e)"; FAIL=$((FAIL+1)); fi
done

echo "== filler to the word budget, and the whole bibliography"
build 0 --fill
build 0 --nocite-all
for e in main-acm main-ieee; do
  expect $e--fill lacks "[TBD" "placeholders"
  printf '  note  %-34s pages %s\n' "$e--fill" "$(pages $e--fill)"
  printf '  note  %-34s pages %s\n' "$e--nociteall" "$(pages $e--nociteall)"
done

echo "== switches that must be refused"
build 1 --set PaperMode=final
build 2 submit --venue=isca26 --only=acm
build 2 --venue=nowhere

echo
if [ "$FAIL" -eq 0 ]; then echo "test_matrix: all $N checks passed"; else echo "test_matrix: $FAIL of $N checks FAILED"; fi
exit $(( FAIL > 0 ))

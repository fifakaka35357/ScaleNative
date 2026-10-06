#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""page_report.py -- how many pages does the body of the paper take?

The four venues count the pages up to the references.  This script finds where the reference
list starts in a built PDF and reports that position as a number of pages, e.g. 10.93.

  python3 page_report.py out/main-acm.pdf out/_build/main-acm/main-acm.log

It reads word positions with `pdftotext -bbox` and the size of the text block from the line
"[paper] geometry: ..." that preamble/common.tex writes to the log.  The answer is a layout
measurement of this build, good to a few hundredths of a page; it says nothing about content.
Exit status: 0 measured, 2 could not measure.
"""
import re
import subprocess
import sys


def to_bp(tex_dimen):                  # "72.26999pt" (TeX points) -> PDF points (1/72 in)
    return float(tex_dimen[:-2]) * 72.0 / 72.27


def measure(pdf, log):
    geo = None
    with open(log, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.search(r"\[paper\] geometry: top=(\S+pt) textheight=(\S+pt) textwidth=(\S+pt) columnwidth=(\S+pt)", line)
            if m:
                geo = [to_bp(x) for x in m.groups()]
    if geo is None:
        return None, "no '[paper] geometry:' line in %s" % log
    top, height, textwidth, colwidth = geo
    ncols = 2 if colwidth < 0.75 * textwidth else 1
    xml = subprocess.run(["pdftotext", "-bbox", pdf, "-"], stdout=subprocess.PIPE, universal_newlines=True, check=True).stdout
    pages = []
    for pm in re.finditer(r"<page width=\"([\d.]+)\" height=\"([\d.]+)\">(.*?)</page>", xml, re.S):
        words = [(float(a), float(b), float(c), float(d), w) for a, b, c, d, w in re.findall(
            r"<word xMin=\"([\d.]+)\" yMin=\"([\d.]+)\" xMax=\"([\d.]+)\" yMax=\"([\d.]+)\">(.*?)</word>", pm.group(3))]
        pages.append((float(pm.group(1)), float(pm.group(2)), words))
    if not pages:
        return None, "pdftotext -bbox returned no pages for %s" % pdf
    hit = None
    for pi, (pw, ph, words) in enumerate(pages):
        firsts = [(t[0], t[1]) for t in words if t[4] == "[1]"]
        for k, (x0, y0, x1, y1, w) in enumerate(words):
            # "References" (acmart) / "REFERENCES" or "R" + "EFERENCES" (IEEEtran small capitals)
            if w not in ("References", "REFERENCES", "EFERENCES"):
                continue
            # the heading is the one with entry "[1]" just below it in the same column; the order of
            # the words in the file is no guide (the other column and margin line numbers interleave).
            # "Same column" is judged by the half of the page, not by the distance between the two
            # words: IEEEtran centres the heading, so it starts far to the right of "[1]".
            below = any((ncols == 1 or (fx > pw / 2.0) == (x0 > pw / 2.0)) and 0.0 < fy - y0 < 60.0
                        for fx, fy in firsts)
            # or, when the heading ends a column, "[1]" is the next thing in reading order
            nxt = "[1]" in [t[4] for t in words[k + 1:k + 3]]
            if below or nxt:
                hit = (pi, pw, x0, y0)
    if hit is None:
        return None, "could not find the heading of the reference list in %s" % pdf
    pi, pw, x0, y0 = hit
    col = 1 if (ncols == 2 and x0 > pw / 2.0) else 0
    frac = min(1.0, max(0.0, (y0 - top) / height))
    body = pi + (col + frac) / ncols
    return dict(total=len(pages), body=body, page=pi + 1, column=col + 1, frac=frac, ncols=ncols), None


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    try:
        r, err = measure(sys.argv[1], sys.argv[2])
    except (OSError, subprocess.CalledProcessError) as e:
        r, err = None, str(e)
    if r is None:
        print("page_report: not measured (%s)" % err)
        return 2
    print("body: %.2f pages up to the references (which start on page %d, column %d, %.0f%% down); %d pages in all" % (
        r["body"], r["page"], r["column"], 100 * r["frac"], r["total"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

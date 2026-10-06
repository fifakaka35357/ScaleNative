#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_align.py -- is the Chinese companion draft the same version as the English LaTeX text?

Compares  sections/*.tex  (English, the text that is compiled)  with  paper.zh-CN.md
(Chinese, paragraph by paragraph) and reports every place where the two disagree on
(the body of a typeset table lives in tables/<file>.tex; a unit reads it with \\input{tables/<file>} on a
line of its own, and the checker reads that file as part of the unit)

  ids       the set and the order of unit ids (a unit is a paragraph or a caption)
  structure the sequence of section / subsection headings and units, and the heading labels
  numbers   the multiset of numbers written with digits in each unit
  cites     the set of citation keys in each unit            (\\cite{k}        <->  [@k])
  refs      the set of cross-reference labels in each unit   (\\figref{l} ...  <->  [text](#l))
  labels    the labels a unit defines                        (\\FigSlot{l}, \\label{l}  <->  <a id="l"></a>)
  TBD ids   the multiset of placeholder ids in each unit     (\\TBD{id}{..}    <->  [TBD-id: ..])
  refs TBD  the multiset of references still to be added     (\\citeTBD{s}     <->  [ref: s])
  stubs     whether the unit is still a one-sentence stub    (\\Intent{..}     <->  本段要说：/ 图注要说：/ 表注要说：)

It also checks things on one side only: malformed markers, text outside any unit, a unit that holds
more than one paragraph (text after a blank line: a paragraph added without a marker), duplicate ids,
\\ptag ids that differ from their marker, citation keys missing from refs.bib, references to
undefined labels, citation commands other than \\cite, that main-acm.tex and main-ieee.tex
read the same section files, and that every file in tables/ is read by exactly one unit.  With --aux it compares the numbers shown in the Chinese links
("[图 5](#fig:pe)") with the numbers LaTeX assigned.

Pure Python 3 standard library.  Exit status: 0 aligned, 1 not aligned, 2 cannot run, 3 self-test failed.

  python3 check_align.py                 check the paper in this directory
  python3 check_align.py --aux out/_build/main-acm/main-acm.aux
  python3 check_align.py --selftest      positive and negative controls (synthetic and on the real files)
  python3 check_align.py --list          per-unit table of what was extracted
  python3 check_align.py --tbd-table     Markdown table of the open placeholders
"""
import argparse
import collections
import os
import re
import sys

# --------------------------------------------------------------------------------------
# conventions
# --------------------------------------------------------------------------------------
RE_EN_MARK = re.compile(r"^%% P:(\S+)[ \t]*$")
RE_EN_NEARMARK = re.compile(r"^\s*%+\s*[Pp]\s*:")
RE_EN_VHEAD = re.compile(r"^%% H([12]):\s*(.*?)\s*$")
RE_EN_HEAD = re.compile(r"^\s*\\(section|subsection)\*?\s*(?=[\[{])")
# a unit reads the body of its table from tables/: the line is replaced by the lines of that file
RE_EN_TABIN = re.compile(r"^\s*\\input\s*\{\s*(tables/[^}\s]+?)(?:\.tex)?\s*\}\s*(?:%.*)?$")
RE_EN_INPUT = re.compile(r"\\(?:input|include)\s*\{\s*([^}]*?)\s*\}")
RE_ZH_MARK = re.compile(r"^<!--\s?P:(\S+)\s?-->[ \t]*$")
RE_ZH_NEARMARK = re.compile(r"<!--\s*[Pp]\s*:")
RE_ZH_HEAD = re.compile(r"^(#{1,6})\s+(.*)$")
RE_ID = re.compile(r"^[A-Za-z][A-Za-z0-9.\-]*$")
RE_TBD_ID = re.compile(r"^[A-Za-z][A-Za-z0-9.\-]*$")
REF_MACROS = ("ref", "figref", "tabref", "secref", "eqref", "pageref", "autoref", "cref", "Cref")
BAD_CITE = re.compile(r"\\(citep|citet|citeauthor|citeyear|citealp|citealt|parencite|textcite|autocite|footcite)\b")
# macros whose leading brace groups are layout, not content: name -> number of groups to drop
STRIP_ARGS = {"fillto": 1, "includegraphics": 1, "input": 1, "url": 1, "hspace": 1, "vspace": 1, "rule": 2,
              "multicolumn": 2, "multirow": 2, "cline": 1, "cmidrule": 1, "parbox": 1, "resizebox": 2,
              "scalebox": 1, "setlength": 2, "fontsize": 2, "textcolor": 1, "color": 1, "colorbox": 1,
              "begin": 1, "end": 1, "bibliographystyle": 1, "bibliography": 1, "href": 1, "SlotName": 1}
# environments whose first argument after \begin{name} is a column specification
SPEC_ENVS = ("tabular", "tabular*", "tabularx", "array")
# of these, the ones whose first argument is the table width and whose second is the column specification
WIDTH_ENVS = ("tabular*", "tabularx")

Issue = collections.namedtuple("Issue", "code where msg")
FULLWIDTH = str.maketrans("０１２３４５６７８９．，％", "0123456789.,%")


class Unit(object):
    def __init__(self, uid, where):
        self.id = uid
        self.where = where
        self.lines = []
        self.numbers = []
        self.cites = set()
        self.refs = set()
        self.labels = set()
        self.tbd = []
        self.reftbd = []
        self.links = []          # (label, link text): Chinese side only

    @property
    def text(self):
        return "\n".join(self.lines)


class Doc(object):
    def __init__(self, lang):
        self.lang = lang
        self.units = []
        self.struct = []         # ("H1"|"H2", label or None) and ("P", id)
        self.head_labels = {}    # label -> heading text
        self.head_numbers = []   # (label, number string written in the heading): Chinese side only
        self.table_reads = collections.OrderedDict()   # tables/<file>.tex -> units that read it: English side only
        self.issues = []

    def add(self, code, where, msg):
        self.issues.append(Issue(code, where, msg))


# --------------------------------------------------------------------------------------
# small parsing helpers
# --------------------------------------------------------------------------------------
def numbers_in(text):
    """Multiset (sorted list) of numbers written with digits."""
    t = text.translate(FULLWIDTH).replace("{,}", ",")
    out = []
    for tok in re.findall(r"\d+(?:[.,]\d+)*", t):
        if re.match(r"^\d{1,3}(?:,\d{3})+(?:\.\d+)?$", tok):
            out.append(tok.replace(",", ""))
        else:
            out.extend(p for p in tok.split(",") if p)
    return sorted(out)


def strip_tex_comments(text):
    return "\n".join(re.sub(r"(?<!\\)%.*$", "", ln) for ln in text.split("\n"))


def read_group(s, i):
    """s[i] == '{' -> (content, index after the closing brace); None if unbalanced."""
    depth = 0
    j = i
    while j < len(s):
        c = s[j]
        if c == "\\":
            j += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return s[i + 1:j], j + 1
        j += 1
    return None


def take_macro(s, name, ngroups, optional=True):
    """Find every \\name followed by `ngroups` brace groups.  Returns (list of group tuples, s with them removed)."""
    found = []
    pat = re.compile(r"\\" + re.escape(name) + r"(?![A-Za-z@])\*?")
    pos = 0
    out = []
    while True:
        m = pat.search(s, pos)
        if not m:
            out.append(s[pos:])
            break
        j = m.end()
        k = j
        while k < len(s) and s[k] in " \t\n":
            k += 1
        while optional and k < len(s) and s[k] == "[":
            e = s.find("]", k)
            if e < 0:
                break
            k = e + 1
            while k < len(s) and s[k] in " \t\n":
                k += 1
        groups = []
        ok = True
        for _ in range(ngroups):
            while k < len(s) and s[k] in " \t\n":
                k += 1
            if k < len(s) and s[k] == "%":            # line that ends in a comment sign
                nl = s.find("\n", k)
                k = len(s) if nl < 0 else nl + 1
                while k < len(s) and s[k] in " \t\n":
                    k += 1
            g = read_group(s, k) if k < len(s) and s[k] == "{" else None
            if g is None:
                ok = False
                break
            groups.append(g[0])
            k = g[1]
        if not ok:
            out.append(s[pos:m.end()])
            pos = m.end()
            continue
        found.append(tuple(groups))
        out.append(s[pos:m.start()])
        out.append(" ")
        pos = k
    return found, "".join(out)


# --------------------------------------------------------------------------------------
# English side
# --------------------------------------------------------------------------------------
def analyse_en_unit(u, doc):
    raw = u.text
    for m in BAD_CITE.finditer(strip_tex_comments(raw)):
        doc.add("E-CITECMD", u.where, "unit %s uses \\%s; only \\cite is allowed (it must work in both classes)" % (u.id, m.group(1)))
    s = strip_tex_comments(raw)
    tags, s = take_macro(s, "ptag", 1)
    for (t,) in tags:
        if t.strip() != u.id:
            doc.add("E-PTAG", u.where, "unit %s: \\ptag{%s} does not repeat the marker id" % (u.id, t.strip()))
    for slot in ("FigSlot", "TabSlot"):
        got, s = take_macro(s, slot, 1)
        for (lab,) in got:
            u.labels.add(lab.strip())
    got, s = take_macro(s, "label", 1)
    for (lab,) in got:
        u.labels.add(lab.strip())
    got, s = take_macro(s, "citeTBD", 1)
    u.reftbd = sorted(" ".join(g[0].split()) for g in got)
    got, s = take_macro(s, "cite", 1)
    for (keys,) in got:
        u.cites.update(k.strip() for k in keys.split(",") if k.strip())
    for name in REF_MACROS:
        got, s = take_macro(s, name, 1)
        for (labs,) in got:
            u.refs.update(x.strip() for x in labs.split(",") if x.strip())
    # table markup whose argument is layout, not content: \cmidrule(lr){2-4}, \addlinespace[2pt], \\[2pt]
    s = re.sub(r"\\cmidrule\s*\([^)]*\)", lambda m: "\\cmidrule", s)
    s = re.sub(r"\\(addlinespace|\\\*?)[ \t]*\[[^\]]*\]", lambda m: "\\" + m.group(1), s)
    # column specifications of tabular-like environments (tabular* and tabularx take the width first)
    for env in SPEC_ENVS:
        s = re.sub(r"\\begin\{" + re.escape(env) + r"\}(\[[^\]]*\])?",
                   lambda m, wide=(env in WIDTH_ENVS): "\\PAspecW" if wide else "\\PAspec", s)
    s = re.sub(r"(\\PAspecW\s*\{[^{}]*\})\s*\[[^\]]*\]", lambda m: m.group(1), s)
    _, s = take_macro(s, "PAspecW", 2)
    _, s = take_macro(s, "PAspec", 1)
    for name, n in STRIP_ARGS.items():
        _, s = take_macro(s, name, n)
    # placeholders: keep the description (its numbers must match too), record the id
    out = []
    pos = 0
    pat = re.compile(r"\\TBD(?![A-Za-z@])")
    while True:
        m = pat.search(s, pos)
        if not m:
            out.append(s[pos:])
            break
        k = m.end()
        g1 = read_group(s, k) if k < len(s) and s[k] == "{" else None
        g2 = read_group(s, g1[1]) if g1 and g1[1] < len(s) and s[g1[1]] == "{" else None
        if not g1 or not g2:
            doc.add("E-SYNTAX", u.where, "unit %s: \\TBD needs two brace groups written without a break: \\TBD{id}{what it waits for}" % u.id)
            out.append(s[pos:m.end()])
            pos = m.end()
            continue
        tid = g1[0].strip()
        if not RE_TBD_ID.match(tid):
            doc.add("E-SYNTAX", u.where, "unit %s: placeholder id '%s' must be letters, digits, '.' or '-'" % (u.id, tid))
        if re.search(r"\\(cite|ref|figref|tabref|secref|TBD|label)\b", g2[0]) or "[" in g2[0] or "]" in g2[0]:
            doc.add("E-SYNTAX", u.where, "unit %s: the description of TBD-%s must be plain words (no references, citations or brackets)" % (u.id, tid))
        u.tbd.append(tid)
        out.append(s[pos:m.start()])
        out.append(" " + g2[0] + " ")
        pos = g2[1]
    s = "".join(out)
    u.tbd.sort()
    u.refs -= u.labels
    u.numbers = numbers_in(s)


def parse_en(files, order):
    """files: {relative path: text}; order: paths in reading order."""
    doc = Doc("en")
    for path in order:
        text = files[path]
        cur = None
        for n, line in enumerate(text.split("\n"), 1):
            where = "%s:%d" % (path, n)
            m = RE_EN_MARK.match(line)
            if m:
                cur = Unit(m.group(1), where)
                doc.units.append(cur)
                doc.struct.append(("P", cur.id))
                if not RE_ID.match(cur.id):
                    doc.add("E-MARKER", where, "unit id '%s' must be letters, digits, '.' or '-'" % cur.id)
                continue
            if RE_EN_NEARMARK.match(line):
                doc.add("E-MARKER", where, "looks like a unit marker but is not exactly '%%%% P:<id>': %r" % line.strip())
                continue
            m = RE_EN_VHEAD.match(line)
            if m:
                cur = None
                doc.struct.append(("H" + m.group(1), None))
                continue
            if RE_EN_HEAD.match(strip_tex_comments(line)):
                cur = None
                level = "H1" if "\\section" in line else "H2"
                lm = re.search(r"\\label\{([^}]+)\}", line)
                label = lm.group(1).strip() if lm else None
                if label:
                    if label in doc.head_labels:
                        doc.add("E-DUPLABEL", where, "label '%s' is defined twice" % label)
                    doc.head_labels[label] = line.strip()
                doc.struct.append((level, label))
                continue
            if cur is not None:
                m = RE_EN_TABIN.match(line)
                if m:
                    tpath = m.group(1) + ".tex"
                    doc.table_reads.setdefault(tpath, []).append(cur.id)
                    if tpath in files:
                        cur.lines.extend(files[tpath].rstrip("\n").split("\n"))
                    else:
                        doc.add("E-FILES", where, "unit %s reads %s, which does not exist" % (cur.id, tpath))
                    continue
                for im in RE_EN_INPUT.finditer(strip_tex_comments(line)):
                    doc.add("E-FILES", where, "unit %s reads '%s' with \\input; only \\input{tables/<file>} on a line of its own is "
                            "followed, so that text would be compiled but not compared" % (cur.id, im.group(1)))
                cur.lines.append(line)
            elif line.strip() and not line.lstrip().startswith("%"):
                doc.add("E-ORPHAN", where, "text outside any unit (every paragraph needs a '%%%% P:<id>' line): %r" % line.strip()[:60])
    for tpath in sorted(p for p in files if p.startswith("tables/")):
        n = len(doc.table_reads.get(tpath, []))
        if n == 0:
            doc.add("E-FILES", tpath, "%s exists but no unit reads it (it would not be checked or compiled)" % tpath)
        elif n > 1:
            doc.add("E-FILES", tpath, "%s is read by %d units (%s); a table body belongs to one unit" % (tpath, n, ", ".join(doc.table_reads[tpath])))
    for u in doc.units:
        analyse_en_unit(u, doc)
    return doc


# --------------------------------------------------------------------------------------
# Chinese side
# --------------------------------------------------------------------------------------
RE_ZH_ANCHOR = re.compile(r"<a\s+(?:id|name)\s*=\s*\"([^\"]+)\"\s*>\s*</a>")
RE_ZH_CITE = re.compile(r"\[\s*(@[^\[\]]+?)\s*\]")
RE_ZH_TBD = re.compile(r"\[TBD-([^:\[\]\s]+):[ \t]*([^\[\]]*)\]")
RE_ZH_REFTBD = re.compile(r"\[ref:[ \t]*([^\[\]]*)\]")
RE_ZH_LINK = re.compile(r"\[([^\[\]]*)\]\(([^)\s]*)\)")


def analyse_zh_unit(u, doc):
    s = re.sub(r"<!--.*?-->", " ", u.text, flags=re.S)
    for m in RE_ZH_ANCHOR.finditer(s):
        u.labels.add(m.group(1).strip())
    s = RE_ZH_ANCHOR.sub(" ", s)

    def cite(m):
        for part in m.group(1).split(";"):
            part = part.strip()
            if not part.startswith("@") or " " in part:
                doc.add("E-SYNTAX", u.where, "unit %s: citation must look like [@key] or [@key1; @key2], got [%s]" % (u.id, m.group(1)))
                continue
            u.cites.add(part[1:])
        return " "
    s = RE_ZH_CITE.sub(cite, s)

    def tbd(m):
        tid = m.group(1)
        if not RE_TBD_ID.match(tid):
            doc.add("E-SYNTAX", u.where, "unit %s: placeholder id '%s' must be letters, digits, '.' or '-'" % (u.id, tid))
        u.tbd.append(tid)
        return " " + m.group(2) + " "
    s = RE_ZH_TBD.sub(tbd, s)
    u.tbd.sort()

    def reftbd(m):
        u.reftbd.append(" ".join(m.group(1).split()))
        return " "
    s = RE_ZH_REFTBD.sub(reftbd, s)
    u.reftbd.sort()

    def link(m):
        text, target = m.group(1), m.group(2)
        if target.startswith("#"):
            u.refs.add(target[1:])
            u.links.append((target[1:], text))
            return " "
        return " " + text + " "          # external link: keep the words, drop the URL
    s = RE_ZH_LINK.sub(link, s)
    s = re.sub(r"<https?://[^>]*>", " ", s)
    s = re.sub(r"https?://\S+", " ", s)
    for bad in ("[TBD", "[@", "[ref:"):
        if bad in s:
            doc.add("E-SYNTAX", u.where, "unit %s: '%s...' is not well formed (descriptions must not contain brackets)" % (u.id, bad))
    u.refs -= u.labels
    u.numbers = numbers_in(s)


def parse_zh(text, path="paper.zh-CN.md"):
    doc = Doc("zh")
    cur = None
    seen_h1 = False
    for n, line in enumerate(text.split("\n"), 1):
        where = "%s:%d" % (path, n)
        m = RE_ZH_MARK.match(line)
        if m:
            cur = Unit(m.group(1), where)
            doc.units.append(cur)
            doc.struct.append(("P", cur.id))
            if not RE_ID.match(cur.id):
                doc.add("E-MARKER", where, "unit id '%s' must be letters, digits, '.' or '-'" % cur.id)
            continue
        if line.lstrip().startswith("<!--") and RE_ZH_NEARMARK.search(line):
            doc.add("E-MARKER", where, "looks like a unit marker but is not exactly '<!-- P:<id> -->' on a line of its own: %r" % line.strip()[:60])
            continue
        m = RE_ZH_HEAD.match(line)
        if m:
            cur = None
            level = len(m.group(1))
            if level == 1:
                continue                      # document title
            seen_h1 = True
            body = m.group(2)
            am = RE_ZH_ANCHOR.search(body)
            label = am.group(1).strip() if am else None
            if label:
                if label in doc.head_labels:
                    doc.add("E-DUPLABEL", where, "label '%s' is defined twice" % label)
                doc.head_labels[label] = body
                nm = re.match(r"\s*(\d+(?:\.\d+)*)", body)
                if nm:
                    doc.head_numbers.append((label, nm.group(1), where))
            doc.struct.append(("H%d" % (level - 1), label))
            continue
        if cur is not None:
            cur.lines.append(line)
        elif seen_h1 and line.strip():
            doc.add("E-ORPHAN", where, "text outside any unit (every paragraph needs a '<!-- P:<id> -->' line): %r" % line.strip()[:40])
    for u in doc.units:
        analyse_zh_unit(u, doc)
    return doc


# --------------------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------------------
def one_sided(doc, bib_keys):
    seen = {}
    alllabels = dict((lab, "heading") for lab in doc.head_labels)
    for u in doc.units:
        if u.id in seen:
            doc.add("E-DUP", u.where, "unit id '%s' is used twice (first at %s)" % (u.id, seen[u.id]))
        seen.setdefault(u.id, u.where)
        for lab in u.labels:
            if lab in alllabels:
                doc.add("E-DUPLABEL", u.where, "label '%s' is defined twice" % lab)
            alllabels[lab] = u.id
        if not "".join(u.lines).strip():
            doc.add("E-EMPTY", u.where, "unit %s has no text" % u.id)
        # one unit is one paragraph: text after a blank line inside a unit is a second paragraph without a marker
        seen_text = gap = False
        for ln in u.lines:
            t = ln.strip()
            if doc.lang == "en":
                if t.startswith("%"):
                    continue
            else:
                t = re.sub(r"<!--.*?-->", "", t).strip() if t else t
                if ln.strip() and not t:
                    continue                      # a line that is only a translator's note
            if not t:
                gap = gap or seen_text
            elif gap and not t.startswith("|"):   # (rows of a Markdown table may follow a blank line)
                doc.add("E-MULTIPAR", u.where, "unit %s holds more than one paragraph: text follows a blank line (%r); "
                        "give the new paragraph its own marker line and id" % (u.id, t[:40]))
                break
            else:
                seen_text = True
    for u in doc.units:
        for lab in sorted(u.refs):
            if lab not in alllabels:
                doc.add("E-UNDEFREF", u.where, "unit %s refers to '%s', which no heading or unit defines" % (u.id, lab))
        if bib_keys is not None:
            for k in sorted(u.cites):
                if k not in bib_keys:
                    doc.add("E-BIBKEY", u.where, "unit %s cites '%s', which is not in refs.bib" % (u.id, k))


def compare(en, zh):
    issues = []
    e_ids = [u.id for u in en.units]
    z_ids = [u.id for u in zh.units]
    e_set, z_set = set(e_ids), set(z_ids)
    for i in e_ids:
        if i not in z_set:
            issues.append(Issue("E-IDSET", [u.where for u in en.units if u.id == i][0], "unit %s is in the English text but not in the Chinese draft" % i))
    for i in z_ids:
        if i not in e_set:
            issues.append(Issue("E-IDSET", [u.where for u in zh.units if u.id == i][0], "unit %s is in the Chinese draft but not in the English text" % i))
    common_e = [i for i in e_ids if i in z_set]
    common_z = [i for i in z_ids if i in e_set]
    if common_e != common_z:
        for a, b in zip(common_e, common_z):
            if a != b:
                issues.append(Issue("E-ORDER", "-", "units are in a different order: English has %s where the Chinese draft has %s" % (a, b)))
                break
    if en.struct != zh.struct and e_set == z_set and common_e == common_z:
        k = 0
        while k < min(len(en.struct), len(zh.struct)) and en.struct[k] == zh.struct[k]:
            k += 1
        a = en.struct[k] if k < len(en.struct) else "(end)"
        b = zh.struct[k] if k < len(zh.struct) else "(end)"
        prev = en.struct[k - 1] if k else "(start)"
        issues.append(Issue("E-STRUCT", "-", "headings and units do not line up after %s: English has %s, Chinese has %s" % (prev, a, b)))
    eu = dict((u.id, u) for u in en.units)
    zu = dict((u.id, u) for u in zh.units)
    for i in common_e:
        a, b = eu[i], zu[i]
        w = "%s | %s" % (a.where, b.where)
        if a.numbers != b.numbers:
            ca, cb = collections.Counter(a.numbers), collections.Counter(b.numbers)
            issues.append(Issue("E-NUM", w, "unit %s: numbers differ; only in English %s, only in Chinese %s" % (
                i, sorted((ca - cb).elements()), sorted((cb - ca).elements()))))
        if a.cites != b.cites:
            issues.append(Issue("E-CITE", w, "unit %s: citation keys differ; only in English %s, only in Chinese %s" % (
                i, sorted(a.cites - b.cites), sorted(b.cites - a.cites))))
        if a.refs != b.refs:
            issues.append(Issue("E-REF", w, "unit %s: cross references differ; only in English %s, only in Chinese %s" % (
                i, sorted(a.refs - b.refs), sorted(b.refs - a.refs))))
        if a.labels != b.labels:
            issues.append(Issue("E-LABEL", w, "unit %s: defined labels differ; English %s, Chinese %s" % (i, sorted(a.labels), sorted(b.labels))))
        if a.tbd != b.tbd:
            ca, cb = collections.Counter(a.tbd), collections.Counter(b.tbd)
            issues.append(Issue("E-TBD", w, "unit %s: placeholder ids differ; only in English %s, only in Chinese %s" % (
                i, sorted((ca - cb).elements()), sorted((cb - ca).elements()))))
        a_stub = bool(re.search(r"\\Intent\s*\{", strip_tex_comments(a.text)))
        b_stub = bool(re.search(r"(本段|图注|表注)要说：", re.sub(r"<!--.*?-->", " ", b.text, flags=re.S)))
        if a_stub != b_stub:
            issues.append(Issue("E-STUB", w, "unit %s: %s is still the one-sentence stub and %s is not" % (
                i, "English" if a_stub else "Chinese", "Chinese" if a_stub else "English")))
        if a.reftbd != b.reftbd:
            ca, cb = collections.Counter(a.reftbd), collections.Counter(b.reftbd)
            issues.append(Issue("E-REFTBD", w, "unit %s: references to be added differ; only in English %s, only in Chinese %s" % (
                i, sorted((ca - cb).elements()), sorted((cb - ca).elements()))))
    return issues


def check_shell(mains, body_text, disk_sections):
    """Both entry files must read the same content; every section file on disk must be read."""
    issues = []
    sets = {}
    for name, text in sorted(mains.items()):
        ins, _ = take_macro(strip_tex_comments(text), "input", 1)
        sets[name] = sorted(x[0].strip() for x in ins if x[0].strip() == "body" or x[0].strip().startswith("sections/"))
    names = sorted(sets)
    for name in names:
        if "body" not in sets[name]:
            issues.append(Issue("E-SHELL", name, "%s does not \\input{body}" % name))
        if len([x for x in sets[name] if x.startswith("sections/")]) != 1:
            issues.append(Issue("E-SHELL", name, "%s must \\input exactly one section file itself (the abstract); it reads %s" % (name, sets[name])))
    if len(names) >= 2 and any(sets[n] != sets[names[0]] for n in names[1:]):
        issues.append(Issue("E-SHELL", ",".join(names), "the entry files read different content: %s" % sets))
    ins, _ = take_macro(strip_tex_comments(body_text), "input", 1)
    body = [x[0].strip() for x in ins]
    order = []
    if names:
        order += [x for x in sets[names[0]] if x.startswith("sections/")]
    order += body
    order = [p if p.endswith(".tex") else p + ".tex" for p in order]
    for p in order:
        if p not in disk_sections:
            issues.append(Issue("E-FILES", p, "%s is read by the paper but does not exist" % p))
    for p in sorted(disk_sections):
        if p not in order:
            issues.append(Issue("E-FILES", p, "%s exists but no entry file reads it (it would not be checked or compiled)" % p))
    if len(set(order)) != len(order):
        issues.append(Issue("E-FILES", "body.tex", "a section file is read twice"))
    return issues, [p for p in order if p in disk_sections]


def parse_aux(text):
    labels = {}
    for m in re.finditer(r"\\newlabel\{([^}]+)\}\{\{([^{}]*)\}", text):
        labels[m.group(1)] = m.group(2)
    return labels


def check_linknumbers(zh, aux):
    issues = []
    n_checked = n_skipped = 0
    items = []
    for u in zh.units:
        for lab, text in u.links:
            nm = re.search(r"\d+(?:\.\d+)*", text.translate(FULLWIDTH))
            items.append((lab, nm.group(0) if nm else None, u.where, "link '%s' in unit %s" % (text, u.id)))
    for lab, num, where in zh.head_numbers:
        items.append((lab, num, where, "heading"))
    for lab, num, where, what in items:
        if num is None or lab not in aux or not re.match(r"^\d+(?:\.\d+)*$", aux[lab]):
            n_skipped += 1
            continue
        n_checked += 1
        if aux[lab] != num:
            issues.append(Issue("E-LINKNUM", where, "%s shows %s, but '%s' is number %s in the compiled paper" % (what, num, lab, aux[lab])))
    return issues, n_checked, n_skipped


def run(en_files, mains, body_text, zh_text, bib_keys, aux=None):
    """Everything on in-memory text, so that the controls can mutate it.  Returns (issues, en, zh, stats)."""
    shell_issues, order = check_shell(mains, body_text, set(p for p in en_files if p.startswith("sections/")))
    en = parse_en(en_files, order)
    zh = parse_zh(zh_text)
    one_sided(en, bib_keys)
    one_sided(zh, bib_keys)
    issues = shell_issues + en.issues + zh.issues + compare(en, zh)
    stats = collections.OrderedDict()
    stats["units en"] = len(en.units)
    stats["units zh"] = len(zh.units)
    for key, f in (("numbers", lambda u: len(u.numbers)), ("cites", lambda u: len(u.cites)), ("refs", lambda u: len(u.refs)),
                   ("labels", lambda u: len(u.labels)), ("tbd", lambda u: len(u.tbd)), ("reftbd", lambda u: len(u.reftbd))):
        stats[key + " en"] = sum(f(u) for u in en.units)
        stats[key + " zh"] = sum(f(u) for u in zh.units)
    stats["table bodies read"] = sum(1 for p in en.table_reads if p in en_files)
    stats["headings en"] = sum(1 for t in en.struct if t[0] != "P")
    stats["headings zh"] = sum(1 for t in zh.struct if t[0] != "P")
    if aux is not None:
        li, nc, ns = check_linknumbers(zh, aux)
        issues += li
        stats["link numbers checked"] = nc
        stats["link numbers skipped"] = ns
    return issues, en, zh, stats


# --------------------------------------------------------------------------------------
# loading
# --------------------------------------------------------------------------------------
def bib_keys_of(text):
    return set(m.group(1).strip() for m in re.finditer(r"^\s*@(?!comment|string|preamble)\w+\s*\{\s*([^,\s]+)\s*,", text, re.M | re.I))


def load(paper_dir, zh_name):
    def rd(p):
        with open(os.path.join(paper_dir, p), encoding="utf-8") as f:
            return f.read()
    sec_dir = os.path.join(paper_dir, "sections")
    en_files = dict(("sections/" + n, rd("sections/" + n)) for n in sorted(os.listdir(sec_dir)) if n.endswith(".tex"))
    tab_dir = os.path.join(paper_dir, "tables")      # bodies of typeset tables, read by the units that \\input them
    if os.path.isdir(tab_dir):
        en_files.update(("tables/" + n, rd("tables/" + n)) for n in sorted(os.listdir(tab_dir)) if n.endswith(".tex"))
    mains = dict((n, rd(n)) for n in sorted(os.listdir(paper_dir)) if re.match(r"^main-.*\.tex$", n))
    if not mains:
        raise IOError("no main-*.tex in %s" % paper_dir)
    return en_files, mains, rd("body.tex"), rd(zh_name), bib_keys_of(rd("refs.bib"))


# --------------------------------------------------------------------------------------
# controls
# --------------------------------------------------------------------------------------
FIX_MAIN = "\\input{preamble/switches}\n\\begin{abstract}\n\\input{sections/00-abstract}\n\\end{abstract}\n\\input{body}\n"
FIX_BODY = "\\input{sections/01-one}\n\\input{sections/02-two}\n"
FIX_EN = {
    "sections/00-abstract.tex": "%% H1: Abstract\n%% P:abs-p1\n\\ptag{abs-p1}%\nA summary with 3 results on ASAP7. \\TBD{E4}{sweep at 600 MHz}\n",
    "sections/01-one.tex": (
        "\\section{One}\\label{sec:one}\n\n"
        "%% P:sec1-p1\n\\ptag{sec1-p1}%\nFirst paragraph cites \\cite{KeyA,KeyB} and \\citeTBD{Some Spec v2}; it covers 5,580 words "
        "and 12.5\\% of area (\\figref{fig:x}, \\secref{sec:two}). \\TBD{D1}{two cores}\n\\fillto{90}\n\n"
        "%% P:fig1-cap\n\\FigSlot{fig:x}%\n  {What it shows}%\n  {not drawn}%\n  {Caption with 16 lanes. \\TBD{W}{caption pending}\\fillto{40}}\n\n"
        "%% P:sec1-p2\n\\ptag{sec1-p2}%\nSecond paragraph, FP32 against BF16. % a comment with 999 in it\n"),
    "sections/02-two.tex": (
        "\\section{Two}\\label{sec:two}\n\n\\subsection{Two A}\\label{sec:two-a}\n\n"
        "%% P:sec2.1-p1\n\\ptag{sec2.1-p1}%\nA table \\tabref{tab:y} follows; see also \\secref{sec:one}.\n\n"
        "%% P:tab1-cap\n\\TabSlot{tab:y}{rows}{typeset later}{Caption. \\TBD{W}{caption pending}}\n\n"
        "%% P:tab2-cap\n\\begin{table}[t]\\centering\n\\caption{A typeset table. \\TBD{W}{numbers pending}}\\label{tab:z}\n"
        "\\begin{tabular*}{\\columnwidth}[t]{@{\\extracolsep{\\fill}}lp{1.2in}r@{}}\n\\toprule\n"
        "Row & \\multicolumn{2}{c}{Share} \\\\\n\\cmidrule(lr){2-3}\n"
        "A & 4-bit & 42.5 \\\\[2pt]\nB & 8-bit & 7,168 \\\\\n\\addlinespace[3pt]\n\\bottomrule\n\\end{tabular*}\n\\end{table}\n\n"
        "%% P:tab3-cap\n\\begin{table}[t]\n\\centering\\SlotName{tab:w}%\n\\caption{A table whose body is in its own file.}\\label{tab:w}\n"
        "\\input{tables/tab-w}\n\\end{table}\n"),
    "tables/tab-w.tex": (
        "%% tables/tab-w.tex -- body of a table; this comment has 555 in it\n\\TableSize\\setlength{\\tabcolsep}{3pt}%\n"
        "\\begin{tabular}{@{}lr@{}}\n\\toprule\nKind & Count \\\\\n\\midrule\nA & 1,024 \\\\\n"
        "B & 61 \\TBD{E9}{count pending} \\\\\n\\bottomrule\n\\end{tabular}\n"),
}
FIX_ZH = (
    "[English](sections/) | **简体中文**\n\n> 说明文字，可以有数字 123。\n\n# 标题\n\n"
    "## 摘要\n\n<!-- P:abs-p1 -->\n在 ASAP7 上给出 3 条结果。[TBD-E4: 600 MHz 下的扫描]\n\n"
    "## 1 第一节 <a id=\"sec:one\"></a>\n\n"
    "<!-- P:sec1-p1 -->\n第一段引 [@KeyA; @KeyB] 与 [ref: Some Spec v2]；共 5,580 词、面积的 12.5%（[图 1](#fig:x)、[§2](#sec:two)）。[TBD-D1: 两个核]\n\n"
    "<!-- P:fig1-cap -->\n<a id=\"fig:x\"></a>**[图 1](#fig:x)** 要画：……。图注：16 条通道。[TBD-W: 图注待写]\n\n"
    "<!-- P:sec1-p2 -->\n第二段，FP32 对 BF16。<!-- 译注：这里的 777 不算 -->\n\n"
    "## 2 第二节 <a id=\"sec:two\"></a>\n\n### 2.1 小节 <a id=\"sec:two-a\"></a>\n\n"
    "<!-- P:sec2.1-p1 -->\n下面是一张表（[表 1](#tab:y)）；另见 [§1](#sec:one)。\n\n"
    "<!-- P:tab1-cap -->\n<a id=\"tab:y\"></a>**[表 1](#tab:y)** 要列：……。[TBD-W: 表注待写]\n\n"
    "<!-- P:tab2-cap -->\n<a id=\"tab:z\"></a>**[表 2](#tab:z)** 表注：排好的一张表。[TBD-W: 数待填]\n\n"
    "| 行 | 占比 | |\n|---|---|---:|\n| A | 4 bit | 42.5 |\n| B | 8 bit | 7,168 |\n\n"
    "<!-- P:tab3-cap -->\n<a id=\"tab:w\"></a>**[表 3](#tab:w)** 表注：表体在单独文件里的一张表。\n\n"
    "| 类 | 个数 |\n|---|---:|\n| A | 1,024 |\n| B | 61 [TBD-E9: 个数待定] |\n"
)
FIX_BIB = set(["KeyA", "KeyB", "KeyC"])
FIX_AUX = {"fig:x": "1", "tab:y": "1", "tab:z": "2", "tab:w": "3", "sec:one": "1", "sec:two": "2", "sec:two-a": "2.1"}


def sub1(text, pattern, repl, what, flags=0):
    """Replace exactly the first match; raise if the pattern is absent (a control that changes nothing proves nothing)."""
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n != 1 or new == text:
        raise LookupError("mutation '%s' found nothing to change" % what)
    return new


def in_units(fn):
    """Apply a Chinese-side mutation only from the first unit marker on: the header of the file
    explains the notation with examples, and a control that edits an example changes nothing."""
    def wrapped(t):
        m = re.search(r"(?m)^<!-- P:", t)
        if not m:
            raise LookupError("no unit marker")
        return t[:m.start()] + fn(t[m.start():])
    return wrapped


def drop_cite(t):
    m = re.search(r"\[@[^\]]+\]", t)
    if not m:
        raise LookupError("no citation")
    parts = [x.strip() for x in m.group(0)[1:-1].split(";")]
    repl = "" if len(parts) == 1 else "[" + "; ".join(parts[1:]) + "]"
    return t[:m.start()] + repl + t[m.end():]


def mutations():
    """(name, side, function(text) -> text, expected issue code).  side: zh | en:* | main | body"""
    def swap_first_two_units(t):
        m = re.search(r"(<!-- P:\S+ -->\n[^\n]*\n\n)(<!-- P:\S+ -->\n[^\n]*\n)", t)
        if not m:
            raise LookupError("no two adjacent units")
        return t[:m.start()] + m.group(2) + "\n" + m.group(1).rstrip("\n") + "\n" + t[m.end():]

    def dup_first_unit(t):
        m = re.search(r"<!-- P:\S+ -->\n[^\n]*\n", t)
        return t[:m.end()] + "\n" + m.group(0) + t[m.end():]

    def bump_number_zh(t):
        # a digit that is plain text: not in a marker, an id, a key, a link target or a link text
        for m in re.finditer(r"(?m)^(?!<!--)(?!#)(?!>).*$", t):
            line = m.group(0)
            masked = re.sub(r"\[[^\]]*\]\([^)]*\)|\[@[^\]]*\]|\[TBD-[^:]*:|<a [^>]*>|<!--.*?-->", lambda k: "\0" * len(k.group(0)), line)
            d = re.search(r"\d", masked)
            if d and t[:m.start()].count("<!-- P:") > 0:
                i = m.start() + d.start()
                return t[:i] + str((int(t[i]) + 1) % 10) + t[i + 1:]
        raise LookupError("no plain digit in the Chinese text")

    def bump_number_en(t):
        for m in re.finditer(r"(?m)^(?!%)(?!\\ptag)(?!\\fillto)(?!\\section)(?!\\subsection).*$", t):
            line = m.group(0)
            masked = re.sub(r"\\(cite|figref|tabref|secref|ref|label|FigSlot|TabSlot|ptag|fillto)\{[^}]*\}|\\TBD\{[^}]*\}|(?<!\\)%.*$",
                            lambda k: "\0" * len(k.group(0)), line)
            d = re.search(r"\d", masked)
            if d:
                i = m.start() + d.start()
                return t[:i] + str((int(t[i]) + 1) % 10) + t[i + 1:]
        raise LookupError("no plain digit in the English text")

    def bump_tabular_cell_en(t):
        # a digit in a row of a typeset table (a line with "&" that ends a row), not one inside \multicolumn{n}{..}
        for m in re.finditer(r"(?m)^(?!%)[^\n]*&[^\n]*\\\\", t):
            if "\\multicolumn" in m.group(0):
                continue
            d = re.search(r"\d", m.group(0))
            if d:
                i = m.start() + d.start()
                return t[:i] + str((int(t[i]) + 1) % 10) + t[i + 1:]
        raise LookupError("no table row with a digit in the English text")

    def bump_table_cell_zh(t):
        for m in re.finditer(r"(?m)^\|[^\n]*\|[ \t]*$", t):
            if re.match(r"^\|[\s:|-]+\|?\s*$", m.group(0)):
                continue                          # the |---|---| line
            d = re.search(r"\d", m.group(0))
            if d:
                i = m.start() + d.start()
                return t[:i] + str((int(t[i]) + 1) % 10) + t[i + 1:]
        raise LookupError("no table row with a digit in the Chinese draft")

    def orphan_zh(t):
        return sub1(t, r"(?m)^(## [^\n]*\n)", r"\1\n这一行不属于任何一段。\n", "orphan")

    muts = [
        ("zh: one marker line deleted", "zh", lambda t: sub1(t, r"<!-- P:\S+ -->\n", "", "drop marker"), "E-IDSET"),
        ("zh: one unit id renamed", "zh", lambda t: sub1(t, r"<!-- P:(\S+) -->", r"<!-- P:\1x -->", "rename id"), "E-IDSET"),
        ("zh: two units swapped", "zh", swap_first_two_units, "E-ORDER"),
        ("zh: one unit duplicated", "zh", dup_first_unit, "E-DUP"),
        ("zh: marker mistyped", "zh", lambda t: sub1(t, r"<!-- P:(\S+) -->", r"<!--P : \1-->", "marker typo"), "E-MARKER"),
        ("zh: one digit changed", "zh", bump_number_zh, "E-NUM"),
        ("en: one digit changed", "en:*", bump_number_en, "E-NUM"),
        ("en: one digit of a typeset table cell changed", "en:*", bump_tabular_cell_en, "E-NUM"),
        ("zh: one digit of a table row changed", "zh", bump_table_cell_zh, "E-NUM"),
        ("en: one digit changed in a file of tables/", "en:tables", bump_tabular_cell_en, "E-NUM"),
        ("en: blank line inside a file of tables/", "en:tables", lambda t: sub1(t, r"\\midrule\n", r"\\midrule\n\n", "blank line in a table body"), "E-MULTIPAR"),
        ("en: a file of tables/ is no longer read", "en:*", lambda t: sub1(t, r"(?m)^\\input\{tables/[^}]+\}\n", "", "drop table input"), "E-FILES"),
        ("en: \\input of a table body that does not exist", "en:*", lambda t: sub1(t, r"(\\input\{tables/[^}]+)\}", r"\1-x}", "retarget table input"), "E-FILES"),
        ("en: a unit reads a file outside tables/", "en:*", lambda t: sub1(t, r"\\input\{tables/", r"\\input{elsewhere/", "input outside tables/"), "E-FILES"),
        ("zh: one citation key removed", "zh", drop_cite, "E-CITE"),
        ("zh: citation key not in refs.bib", "zh", lambda t: sub1(t, r"\[@[^\];]+", "[@NoSuchKey2099", "bad key"), "E-BIBKEY"),
        ("zh: cross reference retargeted", "zh", lambda t: sub1(t, r"(?m)^(?!<a )(.*?\]\(#)[^)]+\)", r"\1sec:nowhere)", "retarget ref"), "E-REF"),
        ("zh: reference to an undefined label", "zh", lambda t: sub1(t, r"(?m)^(?!<a )(.*?\]\(#)[^)]+\)", r"\1sec:nowhere)", "undefined ref"), "E-UNDEFREF"),
        ("zh: placeholder id changed", "zh", lambda t: sub1(t, r"\[TBD-[^:]+:", "[TBD-Z9:", "tbd id"), "E-TBD"),
        ("en: one placeholder removed", "en:*", lambda t: sub1(t, r"\\TBD\{[^}]*\}\{[^}]*\}", "", "drop TBD"), "E-TBD"),
        ("zh: reference-to-add reworded", "zh", lambda t: sub1(t, r"\[ref: ", "[ref: another ", "reftbd"), "E-REFTBD"),
        ("zh: caption anchor renamed", "zh", lambda t: sub1(t, r"(?m)^<a id=\"([^\"]+)\"></a>", r'<a id="\1-x"></a>', "anchor"), "E-LABEL"),
        ("zh: text outside any unit", "zh", orphan_zh, "E-ORPHAN"),
        ("zh: subsection promoted to section", "zh", lambda t: sub1(t, r"(?m)^### ", "## ", "heading level"), "E-STRUCT"),
        ("zh: heading anchor renamed", "zh", lambda t: sub1(t, r"(?m)^(## [^\n]*<a id=\")([^\"]+)", r"\1\2-x", "heading anchor"), "E-STRUCT"),
        ("en: marker mistyped", "en:*", lambda t: sub1(t, r"(?m)^%% P:(\S+)$", r"%% P: \1", "en marker typo"), "E-MARKER"),
        ("en: \\ptag differs from its marker", "en:*", lambda t: sub1(t, r"\\ptag\{([^}]+)\}", r"\\ptag{\1x}", "ptag"), "E-PTAG"),
        ("en: \\citep used", "en:*", lambda t: sub1(t, r"\\cite\{", r"\\citep{", "citep"), "E-CITECMD"),
        ("en: text outside any unit", "en:*", lambda t: sub1(t, r"(?m)^(\\section[^\n]*\n)", r"\1\nA stray sentence.\n", "en orphan"), "E-ORPHAN"),
        ("entry file no longer reads body.tex", "main", lambda t: sub1(t, r"\\input\{body\}", "", "main body"), "E-SHELL"),
        ("a section file dropped from body.tex", "body", lambda t: sub1(t, r"\\input\{sections/[^}]+\}\n", "", "body list"), "E-FILES"),
        ("zh: number shown in a link changed (needs --aux data)", "zh", lambda t: sub1(t, r"\[(图|表|§) ?(\d)", lambda m: "[%s %d" % (m.group(1), (int(m.group(2)) + 3) % 10), "link number"), "E-LINKNUM"),
    ]
    return [(n, side, in_units(fn) if side == "zh" else fn, exp) for n, side, fn, exp in muts]


def apply_mutation(side, fn, en_files, mains, body, zh):
    en_files, mains = dict(en_files), dict(mains)
    where = side
    if side == "zh":
        zh = fn(zh)
    elif side == "body":
        body = fn(body)
    elif side == "main":
        name = sorted(mains)[-1]
        mains[name] = fn(mains[name])
        where = name
    elif side.startswith("en:"):
        done = False
        for p in sorted(q for q in en_files if side != "en:tables" or q.startswith("tables/")):
            try:
                en_files[p] = fn(en_files[p])
                where = p
                done = True
                break
            except LookupError:
                continue
        if not done:
            raise LookupError("nothing to change in any English file")
    return en_files, mains, body, zh, where


def controls(label, en_files, mains, body, zh, bib, aux, must_be_live):
    """Positive control (clean input passes, and every channel carried something) then one negative control per mutation."""
    rows = []
    issues, en, zhd, stats = run(en_files, mains, body, zh, bib, aux)
    ok = not issues
    rows.append(("positive", "unchanged input reports nothing", "no issue", "no issue" if ok else "; ".join(sorted(set(i.code for i in issues))), "PASS" if ok else "FAIL"))
    dead = [k for k in ("numbers", "cites", "refs", "labels", "tbd", "reftbd") if stats[k + " en"] == 0 or stats[k + " zh"] == 0]
    if must_be_live:
        rows.append(("positive", "every channel extracted something on both sides", "none empty", "empty: %s" % dead if dead else "none empty", "FAIL" if dead else "PASS"))
    elif dead:
        rows.append(("positive", "channels that extracted nothing from the real files", "-", ", ".join(dead), "NOTE"))
    for name, side, fn, expect in mutations():
        if expect == "E-LINKNUM" and aux is None:
            rows.append(("negative", name, expect, "no .aux data given", "SKIP"))
            continue
        try:
            m_en, m_mains, m_body, m_zh, where = apply_mutation(side, fn, en_files, mains, body, zh)
        except LookupError as e:
            rows.append(("negative", name, expect, "nothing to mutate (%s)" % e, "SKIP"))
            continue
        got, _, _, _ = run(m_en, m_mains, m_body, m_zh, bib, aux)
        codes = sorted(set(i.code for i in got))
        rows.append(("negative", name, expect, ", ".join(codes) if codes else "no issue", "PASS" if expect in codes else "FAIL"))
    print("-- controls on %s" % label)
    for kind, name, expect, got, verdict in rows:
        print("  %-4s %-8s %-55s expect %-10s got %s" % (verdict, kind, name, expect, got))
    return rows


def selftest(paper_dir, zh_name, aux_path):
    fails = skips = 0
    rows = controls("the built-in fixture", FIX_EN, {"main-acm.tex": FIX_MAIN, "main-ieee.tex": FIX_MAIN}, FIX_BODY, FIX_ZH, FIX_BIB, FIX_AUX, True)
    fails += sum(1 for r in rows if r[4] == "FAIL")
    skips += sum(1 for r in rows if r[4] == "SKIP")
    if any(r[4] == "SKIP" for r in rows):
        fails += 1           # on the fixture every mutation must apply
        print("  FAIL the fixture must exercise every mutation; some were skipped")
    try:
        en_files, mains, body, zh, bib = load(paper_dir, zh_name)
    except (IOError, OSError) as e:
        print("-- controls on the real files: SKIPPED, cannot read them (%s)" % e)
        return 3
    aux = None
    if aux_path:
        with open(aux_path, encoding="utf-8", errors="replace") as f:
            aux = parse_aux(f.read())
    rows = controls("the real files in %s%s" % (paper_dir, " (with %s)" % aux_path if aux else " (no --aux)"), en_files, mains, body, zh, bib, aux, False)
    fails += sum(1 for r in rows if r[4] == "FAIL")
    real_skips = sum(1 for r in rows if r[4] == "SKIP")
    print("self-test: %s; %d control(s) skipped on the real files%s" % (
        "FAILED (%d)" % fails if fails else "all controls behaved as expected", real_skips,
        " -- a skipped control is not a pass: that kind of content does not occur yet, or --aux was not given" if real_skips else ""))
    return 3 if fails else 0


# --------------------------------------------------------------------------------------
# reports
# --------------------------------------------------------------------------------------
def tbd_table(en, zh):
    rows = collections.OrderedDict()
    for u in en.units:
        s = strip_tex_comments(u.text)
        for m in re.finditer(r"\\TBD\{([^}]*)\}\{([^}]*)\}", s):
            rows.setdefault(m.group(1), []).append((u.id, m.group(2)))
    zdesc = collections.defaultdict(list)
    for u in zh.units:
        for m in RE_ZH_TBD.finditer(u.text):
            zdesc[(m.group(1), u.id)].append(m.group(2).strip())

    def key(k):
        m = re.match(r"([A-Za-z]+)(\d*)", k)
        return (m.group(1), int(m.group(2) or 0))
    print("| id | occurrences | units | waits for (English) | 等什么（中文） |")
    print("|---|---:|---|---|---|")
    for tid in sorted(rows, key=key):
        occ = rows[tid]
        en_d = []
        zh_d = []
        for uid, d in occ:
            if d not in en_d:
                en_d.append(d)
            for z in zdesc.get((tid, uid), []):
                if z not in zh_d:
                    zh_d.append(z)
        units = []
        for uid, _ in occ:
            if uid not in units:
                units.append(uid)
        if len(units) > 6:
            units = units[:6] + ["... (%d units)" % len(set(u for u, _ in occ))]
        print("| TBD-%s | %d | %s | %s | %s |" % (tid, len(occ), ", ".join(units), " / ".join(en_d[:4]) + (" / ..." if len(en_d) > 4 else ""),
                                              " / ".join(zh_d[:4]) + (" / ..." if len(zh_d) > 4 else "")))


def main():
    ap = argparse.ArgumentParser(description="Compare the English section files with the Chinese companion draft.")
    ap.add_argument("--paper-dir", default=os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--zh", default="paper.zh-CN.md", help="Chinese draft, relative to the paper directory")
    ap.add_argument("--aux", help="a main-acm.aux from a finished build: also check the numbers shown in Chinese links")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--tbd-table", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true", help="print the verdict line only")
    a = ap.parse_args()
    if a.selftest:
        return selftest(a.paper_dir, a.zh, a.aux)
    try:
        en_files, mains, body, zh_text, bib = load(a.paper_dir, a.zh)
        aux = None
        if not a.aux:
            cand = os.path.join(a.paper_dir, "out", "_build", "main-acm", "main-acm.aux")
            if os.path.isfile(cand):
                a.aux = cand
                if not a.quiet:
                    print("note: using %s for the numbers shown in Chinese links" % os.path.relpath(cand, a.paper_dir))
        if a.aux:
            with open(a.aux, encoding="utf-8", errors="replace") as f:
                aux = parse_aux(f.read())
            if not aux:
                print("check_align: %s contains no \\newlabel lines" % a.aux, file=sys.stderr)
                return 2
    except (IOError, OSError) as e:
        print("check_align: cannot read the paper: %s" % e, file=sys.stderr)
        return 2
    issues, en, zh, stats = run(en_files, mains, body, zh_text, bib, aux)
    if a.tbd_table:
        tbd_table(en, zh)
        return 0
    if a.list:
        zu = dict((u.id, u) for u in zh.units)
        for u in en.units:
            z = zu.get(u.id)
            print("%-12s numbers=%s cites=%d refs=%s labels=%s tbd=%s reftbd=%d%s" % (
                u.id, u.numbers, len(u.cites), sorted(u.refs), sorted(u.labels), u.tbd, len(u.reftbd), "" if z else "   (no Chinese unit)"))
    if not a.quiet:
        for i in issues:
            print("[%s] %s: %s" % (i.code, i.where, i.msg))
        print("scanned: " + "; ".join("%s %s" % (k, v) for k, v in stats.items()))
        if aux is None:
            print("note: numbers shown in Chinese links were not checked (no --aux)")
    if stats["units en"] == 0 or stats["units zh"] == 0:
        print("check_align: NOT ALIGNED -- no units found on one side (wrong directory?)")
        return 1
    if issues:
        print("check_align: NOT ALIGNED -- %d issue(s): %s" % (len(issues), ", ".join("%s x%d" % kv for kv in sorted(collections.Counter(i.code for i in issues).items()))))
        return 1
    print("check_align: aligned -- %d units, %d headings" % (stats["units en"], stats["headings en"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())

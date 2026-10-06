#!/usr/bin/env python3
# Copyright 2026 The ScaleNative Authors.
# All rights reserved.  Not under the repository's Apache-2.0 license; see ../../README.md.
"""check_figure_pdf.py -- effective size of every piece of text in a PDF, and a check on the minimum.

A small self-contained PDF reader (Python standard library only): it parses the object table (including
object streams), walks every page's content stream, follows Form XObjects (that is what \\includegraphics
of a PDF becomes) and tracks the transformation matrix, so the size it reports is the size on the printed
page: Tf size x text-matrix scale x CTM scale, in bp (1/72 in).

  check_figure_pdf.py FILE.pdf                    list the sizes; exit 0
  check_figure_pdf.py --min 8 FILE.pdf            exit 1 if any text is smaller than 8 bp (tolerance 0.005)
  check_figure_pdf.py --min 8 --only-forms F.pdf  check only text inside included graphics (Form XObjects),
                                                  e.g. the figures inside the built paper
  check_figure_pdf.py --selftest                  built-in positive and negative controls
Exit: 0 pass / 1 text below the minimum / 2 could not read the file, or it has no text to check.

Limits: it reads the text-showing operators, so text that was converted to outlines is not seen, and
neither is lettering inside a bitmap.  It handles Flate-compressed streams only.
"""
import re, sys, zlib, math

class Ref:
    __slots__ = ('n',)
    def __init__(self, n): self.n = n
    def __repr__(self): return f'R{self.n}'
class Name(str): pass
class Op(str): pass

class Lexer:
    def __init__(self, data, pos=0): self.d = data; self.p = pos
    def skipws(self):
        d = self.d; n = len(d)
        while self.p < n:
            c = d[self.p:self.p + 1]
            if c in (b' ', b'\t', b'\r', b'\n', b'\x0c', b'\x00'): self.p += 1
            elif c == b'%':
                while self.p < n and d[self.p:self.p + 1] not in (b'\r', b'\n'): self.p += 1
            else: break
    def token(self):
        """returns a python object: number, Name, bytes (string), list, dict, Ref-less; operators as Op"""
        self.skipws(); d = self.d
        if self.p >= len(d): return None
        c = d[self.p:self.p + 1]
        if c == b'/':
            m = re.compile(rb'/([^\s()<>\[\]{}/%]*)').match(d, self.p); self.p = m.end()
            return Name(m.group(1).decode('latin-1'))
        if c == b'(':
            depth = 0; out = bytearray(); self.p += 1
            while self.p < len(d):
                ch = d[self.p:self.p + 1]
                if ch == b'\\':
                    nx = d[self.p + 1:self.p + 2]
                    mp = {b'n': b'\n', b'r': b'\r', b't': b'\t', b'b': b'\b', b'f': b'\f', b'(': b'(', b')': b')', b'\\': b'\\'}
                    if nx in mp: out += mp[nx]; self.p += 2
                    elif nx.isdigit():
                        m = re.compile(rb'[0-7]{1,3}').match(d, self.p + 1); out.append(int(m.group(0), 8) & 255); self.p = m.end()
                    elif nx in (b'\r', b'\n'):
                        self.p += 2
                        if nx == b'\r' and d[self.p:self.p + 1] == b'\n': self.p += 1
                    else: out += nx; self.p += 2
                elif ch == b'(': depth += 1; out += ch; self.p += 1
                elif ch == b')':
                    if depth == 0: self.p += 1; break
                    depth -= 1; out += ch; self.p += 1
                else: out += ch; self.p += 1
            return bytes(out)
        if c == b'<':
            if d[self.p:self.p + 2] == b'<<':
                self.p += 2; res = {}
                while True:
                    self.skipws()
                    if d[self.p:self.p + 2] == b'>>': self.p += 2; break
                    k = self.token()
                    if k is None: break
                    v = self.value()
                    res[str(k)] = v
                return res
            e = d.index(b'>', self.p); hx = re.sub(rb'\s', b'', d[self.p + 1:e]); self.p = e + 1
            if len(hx) % 2: hx += b'0'
            return bytes.fromhex(hx.decode('ascii'))
        if c == b'[':
            self.p += 1; res = []
            while True:
                self.skipws()
                if d[self.p:self.p + 1] == b']': self.p += 1; break
                v = self.value()
                if v is None and self.p >= len(d): break
                res.append(v)
            return res
        m = re.compile(rb'[^\s()<>\[\]{}/%]+').match(d, self.p)
        if not m: self.p += 1; return Op(c.decode('latin-1'))
        self.p = m.end(); t = m.group(0)
        try:
            return int(t)
        except ValueError:
            try: return float(t)
            except ValueError: return Op(t.decode('latin-1'))
    def value(self):
        """like token() but folds 'n g R' into a Ref"""
        v = self.token()
        if isinstance(v, int) and not isinstance(v, bool):
            save = self.p
            g = self.token()
            if isinstance(g, int):
                r = self.token()
                if isinstance(r, Op) and r == 'R': return Ref(v)
            self.p = save
        return v

class PDF:
    def __init__(self, data):
        self.data = data; self.objs = {}; self.streams = {}
        self._scan()
    def _scan(self):
        d = self.data; pos = 0; pend = []
        pat = re.compile(rb'(?<![0-9])(\d+)\s+(\d+)\s+obj\b')
        while True:
            m = pat.search(d, pos)
            if not m: break
            n = int(m.group(1)); lx = Lexer(d, m.end())
            try: val = lx.value()
            except Exception: pos = m.end(); continue
            lx.skipws(); end = lx.p
            if d[lx.p:lx.p + 6] == b'stream':
                s = lx.p + 6
                if d[s:s + 2] == b'\r\n': s += 2
                elif d[s:s + 1] in (b'\n', b'\r'): s += 1
                L = val.get('Length') if isinstance(val, dict) else None
                if isinstance(L, int): e = s + L
                else:
                    e = d.find(b'endstream', s)
                    if e < 0: e = len(d)
                    if isinstance(L, Ref): pend.append((n, s, L))
                self.streams[n] = (s, e); end = e
            self.objs[n] = val; pos = max(end, m.end())
        for n, s, L in pend:
            Lv = self.objs.get(L.n)
            if isinstance(Lv, int): self.streams[n] = (s, s + Lv)
        # object streams
        for n, val in list(self.objs.items()):
            if isinstance(val, dict) and val.get('Type') == 'ObjStm':
                raw = self.stream(n)
                if raw is None: continue
                N = self.res(val.get('N')); first = self.res(val.get('First'))
                hd = Lexer(raw[:first]); pairs = []
                for _ in range(N):
                    a = hd.token(); b = hd.token(); pairs.append((a, b))
                for a, b in pairs:
                    lx = Lexer(raw, first + b)
                    try: self.objs.setdefault(a, lx.value())
                    except Exception: pass
    def res(self, v, depth=0):
        while isinstance(v, Ref) and depth < 20:
            v = self.objs.get(v.n); depth += 1
        return v
    def stream(self, n):
        if n not in self.streams: return None
        s, e = self.streams[n]; raw = self.data[s:e]; dct = self.objs.get(n) or {}
        flt = self.res(dct.get('Filter'))
        flts = flt if isinstance(flt, list) else ([flt] if flt else [])
        for f in flts:
            f = self.res(f)
            if f == 'FlateDecode':
                try: raw = zlib.decompress(raw)
                except zlib.error:
                    try: raw = zlib.decompressobj().decompress(raw)
                    except zlib.error: return None
                parms = self.res(dct.get('DecodeParms'))
                if isinstance(parms, dict) and self.res(parms.get('Predictor', 1)) >= 10:
                    cols = self.res(parms.get('Columns', 1)); rowlen = cols + 1; out = bytearray(); prev = bytearray(cols)
                    for i in range(0, len(raw), rowlen):
                        ft = raw[i]; row = bytearray(raw[i + 1:i + rowlen])
                        if ft == 2:
                            for j in range(len(row)): row[j] = (row[j] + prev[j]) & 255
                        elif ft == 1:
                            for j in range(1, len(row)): row[j] = (row[j] + row[j - 1]) & 255
                        out += row; prev = row
                    raw = bytes(out)
            else: return None
        return raw
    def pages(self):
        return [(n, v) for n, v in sorted(self.objs.items()) if isinstance(v, dict) and v.get('Type') == 'Page']
    def inherited(self, page, key):
        v = page; depth = 0
        while isinstance(v, dict) and depth < 30:
            if key in v: return self.res(v[key])
            v = self.res(v.get('Parent')); depth += 1
        return None

def mmul(a, b):   # a then b  (row-vector convention, PDF): [a b c d e f]
    return [a[0] * b[0] + a[1] * b[2], a[0] * b[1] + a[1] * b[3], a[2] * b[0] + a[3] * b[2], a[2] * b[1] + a[3] * b[3],
            a[4] * b[0] + a[5] * b[2] + b[4], a[4] * b[1] + a[5] * b[3] + b[5]]
IDENT = [1, 0, 0, 1, 0, 0]

def fontname(pdf, resources, fname):
    fonts = pdf.res((resources or {}).get('Font')) or {}
    f = pdf.res(fonts.get(fname)) or {}
    bf = f.get('BaseFont')
    if bf is None:
        desc = pdf.res(f.get('DescendantFonts'))
        if isinstance(desc, list) and desc: bf = (pdf.res(desc[0]) or {}).get('BaseFont')
    sub = f.get('Subtype')
    return (str(bf) if bf else '?'), (str(sub) if sub else '?')

def walk(pdf, content, resources, ctm, where, out, depth=0):
    if content is None or depth > 8: return
    lx = Lexer(content); stack = []; font = None; size = 0.0; tm = IDENT[:]; ops = []
    while True:
        t = lx.token()
        if t is None: break
        if not isinstance(t, Op): ops.append(t); continue
        op = str(t)
        try:
            if op == 'q': stack.append((ctm[:], font, size))
            elif op == 'Q':
                if stack: ctm, font, size = stack.pop()
            elif op == 'cm' and len(ops) >= 6: ctm = mmul([float(x) for x in ops[-6:]], ctm)
            elif op == 'BT': tm = IDENT[:]
            elif op == 'Tf' and len(ops) >= 2: font = str(ops[-2]); size = float(ops[-1])
            elif op == 'Tm' and len(ops) >= 6: tm = [float(x) for x in ops[-6:]]
            elif op in ('Tj', 'TJ', "'", '"') and ops:
                arg = ops[-1]; txt = b''
                if isinstance(arg, bytes): txt = arg
                elif isinstance(arg, list): txt = b''.join(x for x in arg if isinstance(x, bytes))
                m = mmul(tm, ctm)
                sy = math.hypot(m[2], m[3]); sx = math.hypot(m[0], m[1])
                bf, sub = fontname(pdf, resources, font)
                out.append(dict(where=where, font=bf, subtype=sub, tf=size, eff=abs(size) * sy, effx=abs(size) * sx, text=txt))
            elif op == 'Do' and ops:
                xo = pdf.res((resources or {}).get('XObject')) or {}
                ref = xo.get(str(ops[-1])); form = pdf.res(ref)
                if isinstance(form, dict) and form.get('Subtype') == 'Form' and isinstance(ref, Ref):
                    fm = pdf.res(form.get('Matrix')) or IDENT
                    sub_res = pdf.res(form.get('Resources')) or resources
                    walk(pdf, pdf.stream(ref.n), sub_res, mmul([float(x) for x in fm], ctm), where + f'>form{ref.n}', out, depth + 1)
            elif op == 'BI':   # inline image: skip to EI
                e = lx.d.find(b'EI', lx.p); lx.p = e + 2 if e >= 0 else len(lx.d)
        except Exception as ex:
            out.append(dict(where=where, font='!parse', subtype='?', tf=0, eff=float('nan'), effx=0, text=str(ex).encode()))
        ops = []

def analyse(path):
    data = open(path, 'rb').read()
    pdf = PDF(data); out = []; pages = pdf.pages(); boxes = []
    for i, (n, pg) in enumerate(pages, 1):
        res = pdf.inherited(pg, 'Resources'); mb = pdf.inherited(pg, 'MediaBox'); boxes.append(mb)
        cont = pg.get('Contents'); refs = cont if isinstance(pdf.res(cont), list) else [cont]
        if isinstance(pdf.res(cont), list): refs = pdf.res(cont)
        buf = b''
        for r in refs:
            if isinstance(r, Ref):
                s = pdf.stream(r.n)
                if s: buf += s + b'\n'
        walk(pdf, buf, res, IDENT[:], f'p{i}', out)
    return out, boxes, len(pdf.objs)

def show(txt):
    s = txt.decode('latin-1', 'replace')
    if sum(1 for ch in s if 32 <= ord(ch) < 127) < 0.7 * max(1, len(s)): return '<glyph ids>'
    return ''.join(ch if 32 <= ord(ch) < 127 else '?' for ch in s)[:38]

def report(path, minbp=None, only_forms=False, quiet=False):
    try: out, boxes, nobj = analyse(path)
    except Exception as ex:
        print(f'{path}: cannot read ({ex})'); return 2
    if not quiet: print(f'== {path}: {nobj} objects, {len(boxes)} page(s), {len(out)} text-showing operations')
    rc = 0
    if not out and minbp is not None:
        print('   no text found -> the check cannot pass on an empty reading'); return 2
    groups = {}
    for r in out:
        scope = 'in included graphic' if '>form' in r['where'] else 'page level'
        k = (scope, r['font'], r['subtype'], round(r['eff'], 2), round(r['tf'], 2))
        g = groups.setdefault(k, [0, []]); g[0] += 1
        if len(g[1]) < 3: g[1].append(show(r['text']))
    if not quiet:
        print(f"   {'scope':20s} {'font':34s} {'type':9s} {'on page':>8s} {'Tf':>6s} {'n':>4s}  sample")
        for k in sorted(groups, key=lambda k: (k[0], k[3], k[1])):
            n, smp = groups[k]
            print(f"   {k[0]:20s} {k[1][:34]:34s} {k[2][:9]:9s} {k[3]:8.2f} {k[4]:6.2f} {n:4d}  {' | '.join(smp)[:70]}")
    sel = [r for r in out if (not only_forms or '>form' in r['where'])]
    if minbp is not None:
        if not sel: print('   no text in scope -> the check cannot pass'); return 2
        bad = [r for r in sel if not (r['eff'] >= minbp - 0.005)]
        mn = min(r['eff'] for r in sel)
        print(f"   minimum >= {minbp} bp{' (included graphics only)' if only_forms else ''}: smallest = {mn:.2f} bp over {len(sel)} operations -> {'PASS' if not bad else 'FAIL (%d below)' % len(bad)}")
        if bad:
            rc = 1
            for r in bad[:6]: print(f"      {r['eff']:.2f} bp  {r['font']}  {show(r['text'])}")
    return rc

def selftest():
    """positive controls: hand-made PDFs with 8 bp text pass; negative controls: 7.9 bp text fails,
    8 bp text inside a form placed at 0.95 scale fails, 10 bp text under a 0.7 text matrix fails,
    and a PDF without text does not pass."""
    def mk(body_stream, form=None):
        objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 240 100] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Fm1 6 0 R >> >> >>',
                b'<< /Length %d >>\nstream\n' % len(body_stream) + body_stream + b'\nendstream',
                b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
        f = form or b''
        objs.append(b'<< /Type /XObject /Subtype /Form /BBox [0 0 100 50] /Resources << /Font << /F1 5 0 R >> >> /Length %d >>\nstream\n' % len(f) + f + b'\nendstream')
        out = b'%PDF-1.4\n'
        for i, o in enumerate(objs, 1): out += b'%d 0 obj\n' % i + o + b'\nendobj\n'
        return out + b'trailer << /Root 1 0 R >>\n%%EOF\n'
    import tempfile, os
    cases = [('page text 8 bp', mk(b'BT /F1 8 Tf 10 10 Td (Hxg) Tj ET'), 8, False, 0),
             ('page text 7.9 bp', mk(b'BT /F1 7.9 Tf 10 10 Td (Hxg) Tj ET'), 8, False, 1),
             ('form 8 bp at scale 1', mk(b'q 1 0 0 1 5 5 cm /Fm1 Do Q', b'BT /F1 8 Tf 1 1 Td (Hxg) Tj ET'), 8, True, 0),
             ('form 8 bp at scale 0.95', mk(b'q 0.95 0 0 0.95 5 5 cm /Fm1 Do Q', b'BT /F1 8 Tf 1 1 Td (Hxg) Tj ET'), 8, True, 1),
             ('form 10 bp, Tm scale 0.7', mk(b'q 1 0 0 1 5 5 cm /Fm1 Do Q', b'BT /F1 10 Tf 0.7 0 0 0.7 1 1 Tm (Hxg) Tj ET'), 8, True, 1),
             ('no text at all', mk(b'0 0 m 10 10 l S'), 8, False, 2)]
    ok = True
    with tempfile.TemporaryDirectory() as d:
        for name, data, mn, of, want in cases:
            p = os.path.join(d, 'selftest.pdf')
            with open(p, 'wb') as fh: fh.write(data)
            got = report(p, mn, of, quiet=True)
            print(f"   selftest {name:28s} want rc={want} got rc={got} {'ok' if got == want else 'MISMATCH'}")
            ok &= (got == want)
    print('SELFTEST', 'PASS' if ok else 'FAIL'); return 0 if ok else 1

if __name__ == '__main__':
    a = sys.argv[1:]
    if '--selftest' in a: sys.exit(selftest())
    mn = None; of = False; files = []
    i = 0
    while i < len(a):
        if a[i] == '--min' and i + 1 < len(a): mn = float(a[i + 1]); i += 2
        elif a[i] == '--only-forms': of = True; i += 1
        elif a[i].startswith('--'): print(f'unknown option {a[i]}'); print(__doc__); sys.exit(2)
        else: files.append(a[i]); i += 1
    if not files: print(__doc__); sys.exit(2)
    rc = 0
    for f in files: rc = max(rc, report(f, mn, of))
    sys.exit(rc)

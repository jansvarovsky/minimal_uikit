#!/usr/bin/env python3
"""tlc: compile the explicit .tl source language to a VM image or to C.

usage: tlc.py OUTDIR [--check-only] FILE.tl...
Writes OUTDIR/image_vm.h, OUTDIR/image_c.h, OUTDIR/gen.c and OUTDIR/check.m.

Values are 64-bit words. Kinds: w (word/object) and d (double).
ARM64 assigns integer and FP registers independently, and homogeneous float
structs (CGRect...) travel in consecutive d registers, so a call only needs
to know which arguments are doubles.
"""
import lzma
import os
import struct
import sys


class Str(str):
    pass


class Sym(str):
    pass


class Err(Exception):
    pass


def parse(text, fname):
    toks = []
    i, n, line = 0, len(text), 1
    while i < n:
        c = text[i]
        if c == "\n":
            line += 1
            i += 1
        elif c.isspace():
            i += 1
        elif c == ";":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "()":
            toks.append((c, line))
            i += 1
        elif c == '"':
            j, out = i + 1, []
            while text[j] != '"':
                if text[j] == "\\":
                    j += 1
                    out.append({"n": "\n", "t": "\t"}.get(text[j], text[j]))
                else:
                    out.append(text[j])
                j += 1
            toks.append((Str("".join(out)), line))
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '()"':
                j += 1
            a = text[i:j]
            try:
                v = int(a)
            except ValueError:
                try:
                    v = float(a) if a[0] in "-.0123456789" and a not in "-" else Sym(a)
                except ValueError:
                    v = Sym(a)
            toks.append((v, line))
            i = j
    pos = 0

    def form():
        nonlocal pos
        t, l = toks[pos]
        pos += 1
        if t == "(" and not isinstance(t, Str):
            out = Lst()
            out.line, out.file = l, fname
            while toks[pos][0] != ")" or isinstance(toks[pos][0], Str):
                out.append(form())
            pos += 1
            return out
        if t == ")" and not isinstance(t, Str):
            raise Err(f"{fname}:{l}: stray )")
        return t

    out = []
    while pos < len(toks):
        out.append(form())
    return out


class Lst(list):
    line = 0
    file = ""


class Pool:
    def __init__(self):
        self.items, self.idx = [], {}

    def get(self, k):
        if k not in self.idx:
            self.idx[k] = len(self.items)
            self.items.append(k)
        return self.idx[k]


class Fn:
    def __init__(self, name, nargs):
        self.name, self.nargs = name, nargs
        self.code, self.locals, self.nlocals, self.cls = [], {}, 0, None
        self.labels = 0

    def local(self, name, kind):
        if name not in self.locals:
            self.locals[name] = (self.nlocals, kind)
            self.nlocals += 1
        return self.locals[name]

    def label(self):
        self.labels += 1
        return self.labels


TYPE_KIND = {"void": "v", "CGFloat": "d", "double": "d", "CGRect": "dddd", "UIEdgeInsets": "dddd",
             "NSDirectionalEdgeInsets": "dddd", "CGSize": "dd", "CGPoint": "dd", "BOOL": "b"}
BIN = {"+": 0, "-": 1, "*": 2, "/": 3, "%": 4, "<": 5, "=": 6, ">": 7, "&": 8}
FBIN = {"+": 9, "-": 10, "*": 11, "/": 12, "<": 13, ">": 14}


class Compiler:
    def __init__(self):
        self.strs, self.sels, self.clss, self.cfs = Pool(), Pool(), Pool(), Pool()
        self.sigs, self.cfsig, self.globals, self.defs = {}, {}, {}, {}
        self.fns, self.classes, self.checks, self.bodies = [], [], [], []
        self.nameclass = set()

    def err(self, x, msg):
        raise Err(f"{getattr(x, 'file', '?')}:{getattr(x, 'line', '?')}: {msg}")

    def kinds(self, types, x):
        out = ""
        for t in types:
            if t == "float":
                self.err(x, "float parameters are not supported")
            out += TYPE_KIND.get(t, "w") if t != "BOOL" else "w"
        return out

    def top(self, forms):
        for f in forms:
            h = f[0]
            if h == "sig":
                self.sig(f)
            elif h == "cfn":
                ret, types = f[2], f[3:]
                rk = TYPE_KIND.get(ret, "w")
                self.cfsig[str(f[1])] = (("v" if rk == "v" else rk), self.kinds([str(t) for t in types], f))
            elif h == "global":
                for g in f[1:]:
                    self.globals.setdefault(str(g), (len(self.globals), "w"))
            elif h == "def":
                self.defs[str(f[1])] = (len(self.fns), [str(p) for p in f[2]])
                fn = Fn(str(f[1]), len(f[2]))
                self.fns.append(fn)
                self.bodies.append((fn, f[2], f[3:], None))
            elif h == "class":
                self.classdef(f)
            else:
                self.err(f, f"unknown top form {h}")
        i = 0
        while i < len(self.bodies):  # blocks append more
            fn, params, body, _ = self.bodies[i]
            if fn.code == [] and not getattr(fn, "done", False):
                self.compile_fn(fn, params, body)
            i += 1

    def sig(self, f):
        c, sel, ret, types = str(f[1]), str(f[2]), str(f[3]), [str(t) for t in f[4:]]
        static = c.startswith("+")
        cname = c.lstrip("+")
        parts = sel.split(":")[:-1] if ":" in sel else [sel]
        if ":" in sel and len(parts) != len(types):
            self.err(f, f"{sel}: expected {len(parts)} types")
        rk = TYPE_KIND.get(ret, "w")
        key = self.kinds(types, f)
        old = self.sigs.get(sel)
        val = (rk, key)
        if old and old != val:
            self.err(f, f"{sel}: conflicting signatures {old} {val}")
        self.sigs[sel] = val
        self.checks.append((static, cname, sel, parts, ret, types))

    def classdef(self, f):
        name, sup, protos = str(f[1]), str(f[2]), [str(p) for p in f[3]]
        ms = []
        for m in f[4:]:
            if m[0] != "method":
                self.err(m, "expected method")
            sel, params, body = str(m[1]), m[2], m[3:]
            rd = 0
            if sel.endswith("->d"):
                sel, rd = sel[:-3], 1
            kinds = "".join("d" if str(p).endswith(":d") else "w" for p in params[1:])
            fn = Fn(f"{name}.{sel}", len(params))
            fn.cls = name
            self.fns.append(fn)
            self.bodies.append((fn, params, body, None))
            ms.append((Str(sel), len(self.fns) - 1, kinds, rd))
            self.selreg(sel)
        self.nameclass.add(name)
        self.classes.append((name, sup, protos, ms))

    def selreg(self, sel):
        key = (sel, "w")
        return self.sels.get(key) if key not in self.sels.idx else self.sels.idx[key]

    def compile_fn(self, fn, params, body):
        fn.done = True
        for p in params:
            s = str(p)
            fn.local(s[:-2] if s.endswith(":d") else s, "d" if s.endswith(":d") else "w")
        self.block_locals(fn)
        k = self.body(fn, body, True)
        fn.code.append(("retv",))

    def block_locals(self, fn):
        for c in getattr(fn, "caps", []):
            fn.local(c, "w")

    def body(self, fn, forms, want):
        k = "v"
        for i, x in enumerate(forms):
            last = i == len(forms) - 1
            k = self.expr(fn, x, want and last)
        if not forms and want:
            fn.code.append(("pushi", 0))
            k = "w"
        return k

    def sym(self, fn, s, x, want):
        if s in ("nil", "false"):
            if want:
                fn.code.append(("pushi", 0))
            return "w"
        if s == "true":
            if want:
                fn.code.append(("pushi", 1))
            return "w"
        if not want:
            return "v"
        if s in fn.locals:
            i, k = fn.locals[s]
            fn.code.append(("load", i))
            return k
        if s in self.globals:
            fn.code.append(("gload", self.globals[s][0]))
            return "w"
        if s[0].isupper():
            fn.code.append(("cls", self.clss.get(s)))
            return "w"
        self.err(x, f"unknown name {s}")

    def arg(self, fn, a, kind, x):
        if kind == "d" and isinstance(a, (int, float)) and not isinstance(a, bool):
            fn.code.append(("pushd", float(a)))
            return
        k = self.expr(fn, a, True)
        if k != kind:
            self.err(x, f"argument {a!r}: kind {k}, expected {kind}")

    def expr(self, fn, x, want):
        c = fn.code
        if isinstance(x, Str):
            if want:
                c.append(("str", self.strs.get(str(x))))
            return "w"
        if isinstance(x, bool) or isinstance(x, int):
            if want:
                c.append(("pushi", int(x)))
            return "w"
        if isinstance(x, float):
            if want:
                c.append(("pushd", x))
            return "d"
        if isinstance(x, Sym):
            return self.sym(fn, str(x), x, want)
        if not x:
            self.err(x, "empty form")
        h = x[0]
        if not isinstance(h, Sym):
            self.err(x, f"bad head {h!r}")
        h = str(h)
        if h.startswith(".") and len(h) > 1:
            return self.send(fn, x, h[1:], want)
        m = getattr(self, "f_" + {"if": "if_", "and": "and_", "or": "or_", "not": "not_", "do": "do", "while": "while_",
                                  "let": "let", "set": "set", "block": "block", "str": "str", "list": "list",
                                  "dict": "dict", "at": "at", "ivar": "ivar", "ivar!": "ivarset", "new": "new",
                                  "super": "super", "invoke": "invoke", "return": "ret", "itof": "itof", "peek": "peek",
                                  "ftoi": "ftoi"}.get(h, "_none"), None)
        if m:
            return m(fn, x, want)
        if h in BIN or h in FBIN:
            return self.bin(fn, x, h, want)
        if h in self.defs:
            i, ps = self.defs[h]
            if len(x) - 1 != len(ps):
                self.err(x, f"{h}: expected {len(ps)} args")
            for a in x[1:]:
                self.expr_w(fn, a, x)
            c.append(("call", i, len(ps)))
            if not want:
                c.append(("pop",))
                return "v"
            return "w"
        if h in self.cfsig:
            return self.cfcall(fn, x, h, want)
        self.err(x, f"unknown form {h}")

    def expr_w(self, fn, a, x):
        k = self.expr(fn, a, True)
        if k != "w":
            self.err(x, f"{a!r} must be a word, got {k}")

    def send(self, fn, x, name, want):
        member = None
        if "@" in name:
            name, member = name.split("@")
            member = int(member)
        if name not in self.sigs:
            self.err(x, f"no (sig ...) for selector {name}")
        rk, ak = self.sigs[name]
        if len(x) - 2 != len(ak):
            self.err(x, f"{name}: expected {len(ak)} args, got {len(x) - 2}")
        self.expr_w(fn, x[1], x)
        for a, k in zip(x[2:], ak):
            self.arg(fn, a, k, x)
        if rk in ("dddd", "dd"):
            if member is None:
                self.err(x, f"{name} returns a struct: use {name}@N")
            r = "ABCD"[member]
        elif rk == "b":
            r = "b"
        elif rk == "d":
            r = "d"
        else:
            r = rk
        idx = self.sels.get((name, r + ak))
        c = fn.code
        c.append(("send", idx))
        return self.result(fn, r, want)

    def result(self, fn, r, want):
        c = fn.code
        if r == "v":
            if want:
                c.append(("pushi", 0))
                return "w"
            return "v"
        if not want:
            c.append(("pop",))
            return "v"
        return "d" if r in "dABCD" else "w"

    def cfcall(self, fn, x, h, want):
        rk, ak = self.cfsig[h]
        if len(x) - 1 != len(ak):
            self.err(x, f"{h}: expected {len(ak)} args")
        for a, k in zip(x[1:], ak):
            self.arg(fn, a, k, x)
        fn.code.append(("cf", self.cfs.get((h, rk + ak))))
        return self.result(fn, rk, want)

    def bin(self, fn, x, h, want):
        a, b = x[1], x[2]
        fl = isinstance(a, float) or isinstance(b, float)
        mark = len(fn.code)
        ka = self.expr(fn, a, True)
        if ka == "d":
            fl = True
        if fl and ka != "d":
            del fn.code[mark:]
            self.arg(fn, a, "d", x)
        if fl:
            self.arg(fn, b, "d", x)
            if h not in FBIN:
                self.err(x, f"{h} has no float form")
            fn.code.append(("bin", FBIN[h]))
            k = "w" if h in "<>" else "d"
        else:
            self.expr_w(fn, b, x)
            fn.code.append(("bin", BIN[h]))
            k = "w"
        if not want:
            fn.code.append(("pop",))
            return "v"
        return k

    def f_if_(self, fn, x, want):
        L1, L2 = fn.label(), fn.label()
        self.expr_w(fn, x[1], x)
        fn.code.append(("jz", L1))
        k = self.expr(fn, x[2], want)
        fn.code.append(("jmp", L2))
        fn.code.append(("label", L1))
        if len(x) > 3:
            k2 = self.expr(fn, x[3], want)
        else:
            if want:
                fn.code.append(("pushi", 0))
            k2 = k
        fn.code.append(("label", L2))
        if want and k != k2:
            self.err(x, "if branches differ in kind")
        return k if want else "v"

    def f_and_(self, fn, x, want):
        return self.f_if_(fn, Lst([Sym("if"), x[1], x[2], Sym("false")]), want)

    def f_or_(self, fn, x, want):
        t = "__or%d" % fn.label()
        fn.local(t, "w")
        return self.f_do(fn, Lst([Sym("do"), Lst([Sym("let"), Sym(t), x[1]]),
                                  Lst([Sym("if"), Sym(t), Sym(t), x[2]])]), want)

    def f_not_(self, fn, x, want):
        self.expr_w(fn, x[1], x)
        fn.code.append(("not",))
        if not want:
            fn.code.append(("pop",))
            return "v"
        return "w"

    def f_do(self, fn, x, want):
        return self.body(fn, x[1:], want)

    def f_while_(self, fn, x, want):
        L1, L2 = fn.label(), fn.label()
        fn.code.append(("label", L1))
        self.expr_w(fn, x[1], x)
        fn.code.append(("jz", L2))
        self.body(fn, x[2:], False)
        fn.code.append(("jmp", L1))
        fn.code.append(("label", L2))
        if want:
            fn.code.append(("pushi", 0))
            return "w"
        return "v"

    def f_let(self, fn, x, want):
        n = str(x[1])
        k = self.expr(fn, x[2], True)
        i, k0 = fn.local(n, k)
        if k0 != k:
            self.err(x, f"{n} changes kind")
        fn.code.append(("store", i))
        return self.unit(fn, want)

    def unit(self, fn, want):
        if want:
            fn.code.append(("pushi", 0))
            return "w"
        return "v"

    def f_set(self, fn, x, want):
        self.expr_w(fn, x[2], x)
        g = str(x[1])
        if g not in self.globals:
            self.err(x, f"unknown global {g}")
        fn.code.append(("gstore", self.globals[g][0]))
        return self.unit(fn, want)

    def f_block(self, fn, x, want):
        params = [str(p) for p in x[1]]
        names = set()

        def walk(f):
            if isinstance(f, list):
                for y in f:
                    walk(y)
            elif isinstance(f, Sym):
                names.add(str(f))

        walk(x[2:])
        caps = sorted(n for n in names if n in fn.locals and n not in params)
        for n in caps:
            if fn.locals[n][1] != "w":
                self.err(x, f"cannot capture double {n}")
        b = Fn(f"{fn.name}.block", len(params))
        b.cls = fn.cls
        b.caps = caps
        self.fns.append(b)
        self.bodies.append((b, x[1], x[2:], None))
        for n in caps:
            fn.code.append(("load", fn.locals[n][0]))
        fn.code.append(("block", len(self.fns) - 1, len(params), len(caps)))
        if not want:
            fn.code.append(("pop",))
            return "v"
        return "w"

    def seq(self, fn, x, op, want):
        for a in x[1:]:
            self.expr_w(fn, a, x)
        fn.code.append((op, len(x) - 1))
        if not want:
            fn.code.append(("pop",))
            return "v"
        return "w"

    def f_list(self, fn, x, want):
        return self.seq(fn, x, "arr", want)

    def f_dict(self, fn, x, want):
        return self.seq(fn, x, "dict", want)

    def f_str(self, fn, x, want):
        self.sigs.setdefault("stringByAppendingString:", ("w", "w"))
        self.expr_w(fn, x[1], x)
        for a in x[2:]:
            self.expr_w(fn, a, x)
            fn.code.append(("send", self.sels.get(("stringByAppendingString:", "ww"))))
        return "w" if want or fn.code.append(("pop",)) else "v"

    def f_at(self, fn, x, want):
        self.expr_w(fn, x[1], x)
        self.expr_w(fn, x[2], x)
        fn.code.append(("send", self.sels.get(("valueForKeyPath:", "ww"))))
        return "w" if want or fn.code.append(("pop",)) else "v"

    def f_ivar(self, fn, x, want):
        self.expr_w(fn, x[1], x)
        fn.code.append(("str", self.strs.get(str(x[2]))))
        fn.code.append(("aget",))
        return "w" if want or fn.code.append(("pop",)) else "v"

    def f_ivarset(self, fn, x, want):
        self.expr_w(fn, x[1], x)
        fn.code.append(("str", self.strs.get(str(x[2]))))
        self.expr_w(fn, x[3], x)
        fn.code.append(("aset",))
        return self.unit(fn, want)

    def f_new(self, fn, x, want):
        c = fn.code
        c.append(("cls", self.clss.get(str(x[1]))))
        c.append(("send", self.sels.get(("new", "w"))))
        c.append(("send", self.sels.get(("autorelease", "w"))))
        return "w" if want or c.append(("pop",)) else "v"

    def f_super(self, fn, x, want):
        name = str(x[1])
        rk, ak = self.sigs[name]
        self.expr_w(fn, x[2], x)
        for a, k in zip(x[3:], ak):
            self.arg(fn, a, k, x)
        idx = self.sels.get((name, ("v" if rk == "v" else ("b" if rk == "b" else rk)) + ak))
        fn.code.append(("super", idx, self.clss.get(fn.cls)))
        return self.result(fn, "v" if rk == "v" else rk, want)

    def f_invoke(self, fn, x, want):
        n = len(x) - 2
        for a in x[1:]:
            self.expr_w(fn, a, x)
        fn.code.append(("invoke", n))
        if not want:
            fn.code.append(("pop",))
            return "v"
        return "w"

    def f_ret(self, fn, x, want):
        if len(x) > 1:
            self.expr(fn, x[1], True)
        else:
            fn.code.append(("pushi", 0))
        fn.code.append(("retv",))
        if want:
            fn.code.append(("pushi", 0))
            return "w"
        return "v"

    def f_peek(self, fn, x, want):
        self.expr_w(fn, x[1], x)
        fn.code.append(("peek",))
        return "w" if want or fn.code.append(("pop",)) else "v"

    def f_itof(self, fn, x, want):
        self.expr_w(fn, x[1], x)
        fn.code.append(("itof",))
        return "d" if want or fn.code.append(("pop",)) else "v"

    def f_ftoi(self, fn, x, want):
        self.arg(fn, x[1], "d", x)
        fn.code.append(("ftoi",))
        return "w" if want or fn.code.append(("pop",)) else "v"


OPS = ["pushi", "pushd", "str", "cls", "load", "store", "gload", "gstore", "send", "super", "call", "retv",
       "jmp", "jz", "bin", "not", "pop", "arr", "dict", "cf", "block", "invoke", "aget", "aset", "itof", "ftoi", "peek"]


def varint(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def zig(v):
    return varint((v << 1) ^ (v >> 63) if v >= 0 else ((-v) << 1) - 1)


def cstr(s):
    return s.encode() + b"\0"


def serialize_fn(fn):
    """Returns (bytes, maxstack)."""
    # layout pass: jumps are 2 bytes
    def enc(ins, pos, labels):
        o = ins[0]
        b = bytes([OPS.index(o)])
        if o == "pushi":
            return b + zig(ins[1])
        if o == "pushd":
            return b + struct.pack("<f", ins[1])
        if o in ("str", "cls", "load", "store", "gload", "gstore", "send", "cf", "arr", "dict", "invoke", "bin"):
            return b + varint(ins[1])
        if o == "super":
            return b + varint(ins[1]) + varint(ins[2])
        if o == "call":
            return b + varint(ins[1]) + varint(ins[2])
        if o == "block":
            return b + varint(ins[1]) + varint(ins[2]) + varint(ins[3])
        if o in ("jmp", "jz"):
            rel = labels.get(ins[1], 0) - (pos + 3)
            return b + struct.pack("<h", rel)
        return b

    labels = {}
    for _ in range(2):
        pos = 0
        for ins in fn.code:
            if ins[0] == "label":
                labels[ins[1]] = pos
            else:
                pos += len(enc(ins, pos, labels))
    out = bytearray()
    for ins in fn.code:
        if ins[0] != "label":
            out += enc(ins, len(out), labels)
    return bytes(out)


def depths(c, fn):
    """Static stack depth before each instruction."""
    d, res, labels, mx = 0, [], {}, 0
    for ins in fn.code:
        o = ins[0]
        if o == "label":
            d = labels.get(ins[1], d)
            res.append(d)
            continue
        res.append(d)
        delta = {"pushi": 1, "pushd": 1, "str": 1, "cls": 1, "load": 1, "store": -1, "gload": 1, "gstore": -1,
                 "jz": -1, "pop": -1, "bin": -1, "not": 0, "aget": -1, "aset": -3, "itof": 0, "ftoi": 0, "peek": 0,
                 "retv": -1, "jmp": 0}.get(o)
        if o == "send" or o == "super":
            key = c.sels.items[ins[1]][1]
            delta = -len(key[1:]) - (1 if key[0] == "v" else 0)
        elif o == "cf":
            key = c.cfs.items[ins[1]][1]
            delta = -len(key[1:]) + (0 if key[0] == "v" else 1)
        elif o == "call":
            delta = 1 - ins[2]
        elif o == "arr":
            delta = 1 - ins[1]
        elif o == "dict":
            delta = 1 - ins[1]
        elif o == "invoke":
            delta = -ins[1]
        elif o == "block":
            delta = 1 - ins[3]
        d += delta
        mx = max(mx, d + 1)
        if o in ("jz", "jmp"):
            labels[ins[1]] = d
        if o == "retv":
            d = 0
    fn.maxstack = mx + 1
    return res


def image(c, vm):
    b = bytearray()
    for n in (len(c.strs.items), len(c.sels.items), len(c.clss.items), len(c.cfs.items), len(c.fns),
              len(c.globals), len(c.classes)):
        b += varint(n)
    for s in c.strs.items:
        b += cstr(s)
    for name, kinds in c.sels.items:
        b += cstr(name) + (cstr(kinds) if vm else b"")
    for s in c.clss.items:
        b += cstr(s)
    for name, kinds in c.cfs.items:
        b += cstr(name) + (cstr(kinds) if vm else b"")
    for name, sup, protos, ms in c.classes:
        b += cstr(name) + cstr(sup) + varint(len(protos))
        for p in protos:
            b += cstr(p)
        b += varint(len(ms))
        for sel, f, kinds, rd in ms:
            k = next(i for i, (n, kk) in enumerate(c.sels.items) if n == str(sel))
            b += varint(k) + varint(f) + cstr(kinds) + bytes([rd])
    if vm:
        for fn in c.fns:
            depths(c, fn)
            code = serialize_fn(fn)
            b += varint(fn.nlocals) + varint(fn.maxstack) + varint(len(code)) + code
    return bytes(b)


def emit_c(c):
    out = []
    n = len(c.fns)
    out.append("".join(f"static W f{i}(W*a);\n" for i in range(n)))
    for i, fn in enumerate(c.fns):
        d = depths(c, fn)
        L = ["static W f%d(W*a){" % i]
        if fn.nlocals:
            L.append("W " + ",".join(f"l{j}={'a[%d]' % j if j < fn.nargs + len(getattr(fn, 'caps', [])) else '0'}"
                                     for j in range(fn.nlocals)) + ";")
        L.append("W " + ",".join(f"s{j}=0" for j in range(fn.maxstack + 2)) + ";")
        for ins, sp in zip(fn.code, d):
            o = ins[0]
            T = lambda j: f"s{sp + j}"
            if o == "label":
                L.append(f"L{ins[1]}:;")
            elif o == "pushi":
                L.append(f"{T(0)}={ins[1]}L;")
            elif o == "pushd":
                L.append(f"{T(0)}=DW({ins[1]!r});")
            elif o == "str":
                L.append(f"{T(0)}=nstr({ins[1]});")
            elif o == "cls":
                L.append(f"{T(0)}=cl({ins[1]});")
            elif o == "load":
                L.append(f"{T(0)}=l{ins[1]};")
            elif o == "store":
                L.append(f"l{ins[1]}={T(-1)};")
            elif o == "gload":
                L.append(f"{T(0)}=G[{ins[1]}];")
            elif o == "gstore":
                L.append(f"G[{ins[1]}]=ret_w({T(-1)});")
            elif o in ("send", "super", "cf"):
                L.append(c_call(c, ins, sp))
            elif o == "call":
                args = ",".join(f"s{sp - ins[2] + j}" for j in range(ins[2])) or "0"
                L.append(f"{{W t[]={{{args}}};s{sp - ins[2]}=f{ins[1]}(t);}}")
            elif o == "retv":
                L.append(f"return {T(-1)};")
            elif o == "jmp":
                L.append(f"goto L{ins[1]};")
            elif o == "jz":
                L.append(f"if(!{T(-1)})goto L{ins[1]};")
            elif o == "bin":
                a, b = T(-2), T(-1)
                k = ins[1]
                ops = {0: "+", 1: "-", 2: "*", 3: "/", 4: "%", 5: "<", 6: "==", 7: ">", 8: "&"}
                if k in ops:
                    L.append(f"{a}=(long){a}{ops[k]}(long){b};")
                else:
                    f = {9: "+", 10: "-", 11: "*", 12: "/", 13: "<", 14: ">"}[k]
                    if k >= 13:
                        L.append(f"{a}=WD({a}){f}WD({b});")
                    else:
                        L.append(f"{a}=DW(WD({a}){f}WD({b}));")
            elif o == "not":
                L.append(f"{T(-1)}=!{T(-1)};")
            elif o == "pop":
                pass
            elif o in ("arr", "dict"):
                n2 = ins[1]
                args = ",".join(f"s{sp - n2 + j}" for j in range(n2)) or "0"
                L.append(f"{{W t[]={{{args}}};s{sp - n2}=mk{o}(t,{n2});}}")
            elif o == "block":
                nc = ins[3]
                args = ",".join(f"s{sp - nc + j}" for j in range(nc)) or "0"
                L.append(f"{{W t[]={{{args}}};s{sp - nc}=mkblock({ins[1]},{ins[2]},t,{nc});}}")
            elif o == "invoke":
                n2 = ins[1]
                a = [f"s{sp - n2 + j}" for j in range(n2)] + ["0"] * (4 - n2)
                L.append(f"s{sp - n2 - 1}=((W(^)(W,W,W,W))s{sp - n2 - 1})({','.join(a[:4])});")
            elif o == "aget":
                L.append(f"{T(-2)}=aget({T(-2)},{T(-1)});")
            elif o == "aset":
                L.append(f"aset({T(-3)},{T(-2)},{T(-1)});")
            elif o == "itof":
                L.append(f"{T(-1)}=DW((double)(long){T(-1)});")
            elif o == "peek":
                L.append(f"{T(-1)}=*(W*){T(-1)};")
            elif o == "ftoi":
                L.append(f"{T(-1)}=(W)(long)WD({T(-1)});")
            else:
                raise Err("emit " + o)
        L.append("return 0;}")
        out.append("".join(L) + "\n")
    out.append("static W(*const FN[])(W*)={" + ",".join(f"f{i}" for i in range(n)) + "};\n")
    return "".join(out)


def c_call(c, ins, sp):
    o = ins[0]
    key = (c.cfs if o == "cf" else c.sels).items[ins[1]][1]
    r, ak = key[0], key[1:]
    n = len(ak)
    base = sp - n
    args, types = [], []
    for j, k in enumerate(ak):
        s = f"s{base + j}"
        args.append(f"WD({s})" if k == "d" else s)
        types.append("double" if k == "d" else "W")
    ret = {"v": "void", "w": "W", "b": "W", "d": "double"}.get(r, "R4")
    if o == "cf":
        fn = f"((({ret}(*)({','.join(types) or 'void'}))CF[{ins[1]}]))"
        call = f"{fn}({','.join(args)})"
        dest = base
    elif o == "send":
        fn = f"(({ret}(*)({','.join(['W', 'SEL'] + types)}))objc_msgSend)"
        call = f"{fn}({','.join([f's{base - 1}', f'SL[{ins[1]}]'] + args)})"
        dest = base - 1
    else:
        fn = f"(({ret}(*)({','.join(['void*', 'SEL'] + types)}))objc_msgSendSuper)"
        call = (f"{fn}({','.join([f'&(struct objc_super){{(id)s{base - 1},class_getSuperclass((Class)cl({ins[2]}))}}', f'SL[{ins[1]}]'] + args)})")
        dest = base - 1
    if r == "v":
        return call + ";"
    if r == "w":
        return f"s{dest}={call};"
    if r == "b":
        return f"s{dest}=({call})&255;"
    if r == "d":
        return f"s{dest}=DW({call});"
    return f"s{dest}=DW(({call}).v[{'ABCD'.index(r)}]);"


def check_m(c):
    out = ["#import <UIKit/UIKit.h>\n#import <AVKit/AVKit.h>\n#import <PhotosUI/PhotosUI.h>\n#import <AuthenticationServices/AuthenticationServices.h>\n"]
    for i, (static, cname, sel, parts, ret, types) in enumerate(c.checks):
        params = [f"{cname} *o"] if not static else []
        params += [f"{t} a{j}" for j, t in enumerate(types)]
        if ":" in sel:
            call = " ".join(f"{p}:a{j}" for j, p in enumerate(parts))
        else:
            call = sel
        recv = cname if static else "o"
        send = f"[{recv} {call}]"
        body = f"(void){send};" if ret in ("void", "id", "instancetype") else f"{ret} r = {send}; (void)r;"
        out.append(f"void c{i}({', '.join(params) or 'void'}) {{ {body} }}\n")
    return "".join(out)


def header(name, data, raw):
    return f"#define {name}N {len(data)}\n#define {name}RAW {raw}\nstatic const unsigned char {name}[]={{" + ",".join(map(str, data)) + "};\n"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out, files = args[0], args[1:]
    c = Compiler()
    # selectors the compiler itself relies on
    for sel, sig in (("stringByAppendingString:", ("w", "w")), ("valueForKeyPath:", ("w", "w")),
                     ("new", ("w", "")), ("autorelease", ("w", ""))):
        c.sigs.setdefault(sel, sig)
    try:
        forms = []
        for f in files:
            forms += parse(open(f).read(), f)
        c.top(forms)
    except Err as e:
        sys.exit(f"tlc error: {e}")
    os.makedirs(out, exist_ok=True)
    xz = dict(format=lzma.FORMAT_XZ, check=lzma.CHECK_NONE,
              filters=[{"id": lzma.FILTER_LZMA2, "preset": 9 | lzma.PRESET_EXTREME, "lc": 3, "lp": 0, "pb": 0}])
    for name, vm in (("IMG", True), ("IMG", False)):
        raw = image(c, vm)
        data = lzma.compress(raw, **xz)
        open(f"{out}/image_{'vm' if vm else 'c'}.h", "w").write(header(name, data, len(raw)))
        print(f"{'vm' if vm else 'c '} image raw {len(raw)} xz {len(data)}")
    open(f"{out}/gen.c", "w").write(emit_c(c))
    open(f"{out}/check.m", "w").write(check_m(c))
    print(f"fns {len(c.fns)} sels {len(c.sels.items)} strs {len(c.strs.items)}")


if __name__ == "__main__":
    main()

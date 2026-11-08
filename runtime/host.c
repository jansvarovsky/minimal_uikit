// Native host: unpacks the compressed image, registers classes, runs the app.
// -DVM interprets bytecode; otherwise generated native code is included.
#include <Block.h>
#include <compression.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned long W;
typedef unsigned char u8;
typedef struct { double v[4]; } R4;
extern int UIApplicationMain(int, char **, void *, void *);
extern id objc_retain(id);

#ifdef VM
#include "image_vm.h"
#else
#include "image_c.h"
#endif

static inline W DW(double d) { W w; memcpy(&w, &d, 8); return w; }
static inline double WD(W w) { double d; memcpy(&d, &w, 8); return d; }

#define MS0(r) ((W (*)(W, SEL))objc_msgSend)
static const u8 *P;
static W rv(void) { W v = 0; int s = 0, b; do { b = *P++; v |= (W)(b & 127) << s; s += 7; } while (b & 128); return v; }
static const char *rs(void) { const char *s = (const char *)P; P += strlen(s) + 1; return s; }

static const char **SR, **CN, **CFK, **SK;
static W *NS, *CLS, *G;
static SEL *SL;
static void **CF;

static W nstr(W i) {
    if (!NS[i]) NS[i] = ((W (*)(W, SEL, const char *))objc_msgSend)(MS0(0)((W)objc_getClass("NSString"), sel_registerName("alloc")),
                                                                    sel_registerName("initWithUTF8String:"), SR[i]);
    return NS[i];
}
static W cl(W i) { if (!CLS[i]) CLS[i] = (W)objc_getClass(CN[i]); return CLS[i]; }

// Values that can be objects live above __PAGEZERO; small integers do not.
static W ret_w(W v) { if (v >= 0x100000000UL) objc_retain((id)v); return v; }

static W mkarr(W *t, int n) {
    W out[n ? n : 1]; int m = 0;
    for (int i = 0; i < n; i++) if (t[i]) out[m++] = t[i];
    return ((W (*)(W, SEL, W *, W))objc_msgSend)((W)objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), out, m);
}
static W mkdict(W *t, int n) {
    W k[n ? n : 1], v[n ? n : 1]; int m = 0;
    for (int i = 0; i + 1 < n; i += 2) if (t[i + 1]) { k[m] = t[i]; v[m++] = t[i + 1]; }
    return ((W (*)(W, SEL, W *, W *, W))objc_msgSend)((W)objc_getClass("NSDictionary"), sel_registerName("dictionaryWithObjects:forKeys:count:"), v, k, m);
}
static W aget(W o, W k) { return (W)objc_getAssociatedObject((id)o, (void *)k); }
static void aset(W o, W k, W v) { objc_setAssociatedObject((id)o, (void *)k, (id)v, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }

static W mkblock(int f, int na, W *caps, int nc);

#ifdef VM
typedef struct { int nl, ms; const u8 *code; } Fn;
static Fn *FNS;

enum { PUSHI, PUSHD, STR, CLSO, LOAD, STORE, GLOAD, GSTORE, SEND, SUPER, CALL, RETV, JMP, JZ, BIN, NOT, POP, ARR, DICT, CFO,
       BLOCK, INVOKE, AGET, ASET, ITOF, FTOI, PEEK };

static W callw(void *f, W *w, double *d, char r) {
#define ARGS w[0], w[1], w[2], w[3], w[4], w[5], w[6], w[7], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]
#define SIG W, W, W, W, W, W, W, W, double, double, double, double, double, double, double, double
    return r == 'd' ? DW(((double (*)(SIG))f)(ARGS)) : ((W (*)(SIG))f)(ARGS);
}

static W run(int f, W *a, int na);
static W dosend(int si, W *args, W recv, void *sup) {
    const char *k = SK[si]; char r = *k++;
    W w[6] = {0}; double d[8] = {0}; int iw = 0, id = 0;
    for (int j = 0; k[j]; j++) { if (k[j] == 'd') d[id++] = WD(args[j]); else w[iw++] = args[j]; }
    if (r >= 'A' && r <= 'D') {
        R4 v = sup ? ((R4 (*)(void *, SEL, W, W, W, W, W, W, double, double, double, double, double, double, double, double))objc_msgSendSuper)(sup, SL[si], w[0], w[1], w[2], w[3], w[4], w[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7])
                   : ((R4 (*)(W, SEL, W, W, W, W, W, W, double, double, double, double, double, double, double, double))objc_msgSend)(recv, SL[si], w[0], w[1], w[2], w[3], w[4], w[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]);
        return DW(v.v[r - 'A']);
    }
    if (r == 'd') {
        W v = sup ? DW(((double (*)(void *, SEL, W, W, W, W, W, W, double, double, double, double, double, double, double, double))objc_msgSendSuper)(sup, SL[si], w[0], w[1], w[2], w[3], w[4], w[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]))
                  : DW(((double (*)(W, SEL, W, W, W, W, W, W, double, double, double, double, double, double, double, double))objc_msgSend)(recv, SL[si], w[0], w[1], w[2], w[3], w[4], w[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]));
        return v;
    }
    W v = sup ? ((W (*)(void *, SEL, W, W, W, W, W, W, double, double, double, double, double, double, double, double))objc_msgSendSuper)(sup, SL[si], w[0], w[1], w[2], w[3], w[4], w[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7])
              : ((W (*)(W, SEL, W, W, W, W, W, W, double, double, double, double, double, double, double, double))objc_msgSend)(recv, SL[si], w[0], w[1], w[2], w[3], w[4], w[5], d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7]);
    return r == 'b' ? (v & 255) : v;
}

static W run(int f, W *a, int na) {
    Fn *F = &FNS[f];
    W L[F->nl + 1], S[F->ms + 2], *sp = S;
    memset(L, 0, sizeof(W) * (F->nl + 1));
    memcpy(L, a, sizeof(W) * na);
    const u8 *p = F->code;
#define V ({ W v_ = 0; int s_ = 0, b_; do { b_ = *p++; v_ |= (W)(b_ & 127) << s_; s_ += 7; } while (b_ & 128); v_; })
    for (;;) switch (*p++) {
    case PUSHI: { W z = V; *sp++ = (z >> 1) ^ -(z & 1); break; }
    case PUSHD: { float x; memcpy(&x, p, 4); p += 4; *sp++ = DW(x); break; }
    case STR: { W i = V; *sp++ = nstr(i); break; }
    case CLSO: { W i = V; *sp++ = cl(i); break; }
    case LOAD: { W i = V; *sp++ = L[i]; break; }
    case STORE: { W i = V; L[i] = *--sp; break; }
    case GLOAD: { W i = V; *sp++ = G[i]; break; }
    case GSTORE: { W i = V; G[i] = ret_w(*--sp); break; }
    case SEND: {
        W i = V; const char *k = SK[i]; int n = strlen(k + 1); sp -= n;
        W v = dosend(i, sp, sp[-1], 0);
        if (*k == 'v') sp--; else sp[-1] = v;
        break;
    }
    case SUPER: {
        W i = V, c = V; const char *k = SK[i]; int n = strlen(k + 1); sp -= n;
        struct objc_super su = {(id)sp[-1], class_getSuperclass((Class)cl(c))};
        W v = dosend(i, sp, 0, &su);
        if (*k == 'v') sp--; else sp[-1] = v;
        break;
    }
    case CALL: { W i = V, n = V; sp -= n; W v = run((int)i, sp, (int)n); *sp++ = v; break; }
    case RETV: return sp[-1];
    case JMP: { short r; memcpy(&r, p, 2); p += 2 + r; break; }
    case JZ: { short r; memcpy(&r, p, 2); p += 2; if (!*--sp) p += r; break; }
    case BIN: {
        W op = V; sp--; W x = sp[-1], y = sp[0]; long lx = x, ly = y; double dx = WD(x), dy = WD(y);
        switch (op) {
        case 0: sp[-1] = lx + ly; break; case 1: sp[-1] = lx - ly; break; case 2: sp[-1] = lx * ly; break; case 3: sp[-1] = lx / ly; break;
        case 4: sp[-1] = lx % ly; break; case 5: sp[-1] = lx < ly; break; case 6: sp[-1] = x == y; break; case 7: sp[-1] = lx > ly; break;
        case 8: sp[-1] = x & y; break;
        case 9: sp[-1] = DW(dx + dy); break; case 10: sp[-1] = DW(dx - dy); break; case 11: sp[-1] = DW(dx * dy); break; case 12: sp[-1] = DW(dx / dy); break;
        case 13: sp[-1] = dx < dy; break; case 14: sp[-1] = dx > dy; break;
        }
        break;
    }
    case NOT: sp[-1] = !sp[-1]; break;
    case POP: sp--; break;
    case ARR: { W n = V; sp -= n; *sp = mkarr(sp, (int)n); sp++; break; }
    case DICT: { W n = V; sp -= n; *sp = mkdict(sp, (int)n); sp++; break; }
    case CFO: {
        W i = V; const char *k = CFK[i]; char r = *k++; int n = strlen(k); sp -= n;
        W w[8] = {0}; double d[8] = {0}; int iw = 0, id = 0;
        for (int j = 0; j < n; j++) { if (k[j] == 'd') d[id++] = WD(sp[j]); else w[iw++] = sp[j]; }
        W v = callw(CF[i], w, d, r);
        if (r != 'v') *sp++ = v;
        break;
    }
    case BLOCK: { W fi = V, nargs = V, nc = V; sp -= nc; *sp = mkblock((int)fi, (int)nargs, sp, (int)nc); sp++; break; }
    case INVOKE: {
        W n = V; sp -= n; W x[4] = {0}; memcpy(x, sp, n * sizeof(W));
        sp[-1] = ((W (^)(W, W, W, W))sp[-1])(x[0], x[1], x[2], x[3]);
        break;
    }
    case AGET: sp--; sp[-1] = aget(sp[-1], sp[0]); break;
    case ASET: sp -= 3; aset(sp[0], sp[1], sp[2]); break;
    case ITOF: sp[-1] = DW((double)(long)sp[-1]); break;
    case FTOI: sp[-1] = (W)(long)WD(sp[-1]); break;
    case PEEK: sp[-1] = *(W *)sp[-1]; break;
    }
}
#define CALLF(f, a, n) run(f, a, n)
#else
#include "gen.c"
#define CALLF(f, a, n) FN[f](a)
#endif

static W mkblock(int f, int na, W *caps, int nc) {
    W *c = malloc(sizeof(W) * (nc + 1));
    for (int i = 0; i < nc; i++) c[i] = ret_w(caps[i]);
    W (^b)(W, W, W, W) = ^W(W x, W y, W z, W q) {
        W a[na + nc + 1];
        W in[4] = {x, y, z, q};
        for (int i = 0; i < na; i++) a[i] = in[i];
        for (int i = 0; i < nc; i++) a[na + i] = c[i];
        if (pthread_main_np()) return CALLF(f, a, na + nc);
        W *h = malloc(sizeof(a)); memcpy(h, a, sizeof(a));
        for (int i = 0; i < na; i++) ret_w(h[i]);
        dispatch_async(dispatch_get_main_queue(), ^{ CALLF(f, h, na + nc); });
        return 0;
    };
    return (W)Block_copy(b);
}

typedef struct { Class c; SEL s; int f; const char *k; } M;
static M *MT; static int NM;

static W disp(W self, SEL cmd, W *w, double *d) {
    for (Class k = object_getClass((id)self); k; k = class_getSuperclass(k))
        for (int i = 0; i < NM; i++)
            if (MT[i].s == cmd && MT[i].c == k) {
                W a[14]; int iw = 0, id = 0, n = 1; a[0] = self;
                for (const char *q = MT[i].k; *q; q++) a[n++] = *q == 'd' ? DW(d[id++]) : w[iw++];
                return CALLF(MT[i].f, a, n);
            }
    return 0;
}
#define IMPARGS W self, SEL c, W a, W b, W e, W f, W g, W h, double d0, double d1, double d2, double d3
#define IMPBODY W w[] = {a, b, e, f, g, h}; double d[] = {d0, d1, d2, d3}; W r = disp(self, c, w, d);
static W imp(IMPARGS) { IMPBODY return r; }
static double impd(IMPARGS) { IMPBODY return WD(r); }

#ifdef TEST
void ts_test_start(void);
#endif

int main(int argc, char **argv) {
    u8 *raw = malloc(IMGRAW + 1);
    compression_decode_buffer(raw, IMGRAW + 1, IMG, IMGN, 0, COMPRESSION_LZMA);
    P = raw;
    int ns = rv(), nsl = rv(), nc = rv(), ncf = rv(), nf = rv(), ng = rv(), nk = rv();
    SR = malloc(sizeof(char *) * (ns + 1)); NS = calloc(ns + 1, 8);
    for (int i = 0; i < ns; i++) SR[i] = rs();
    SL = malloc(sizeof(SEL) * (nsl + 1)); SK = malloc(sizeof(char *) * (nsl + 1));
    for (int i = 0; i < nsl; i++) { SL[i] = sel_registerName(rs());
#ifdef VM
        SK[i] = rs();
#endif
    }
    CN = malloc(sizeof(char *) * (nc + 1)); CLS = calloc(nc + 1, 8);
    for (int i = 0; i < nc; i++) CN[i] = rs();
    CF = malloc(sizeof(void *) * (ncf + 1)); CFK = malloc(sizeof(char *) * (ncf + 1));
    for (int i = 0; i < ncf; i++) { CF[i] = dlsym(RTLD_DEFAULT, rs());
#ifdef VM
        CFK[i] = rs();
#endif
    }
    G = calloc(ng + 1, 8);
    MT = malloc(sizeof(M) * 512);
    for (int i = 0; i < nk; i++) {
        const char *name = rs(), *sup = rs();
        Class c = objc_allocateClassPair(objc_getClass(sup), name, 0);
        for (W n = rv(); n; n--) class_addProtocol(c, objc_getProtocol(rs()));
        for (W n = rv(); n; n--) {
            int si = (int)rv(), f = (int)rv(); const char *k = rs(); int rd = *P++;
            char types[24]; int t = 0; types[t++] = rd ? 'd' : '@'; types[t++] = '@'; types[t++] = ':';
            for (const char *q = k; *q && t < 22; q++) types[t++] = *q == 'd' ? 'd' : '@';
            types[t] = 0;
            class_addMethod(c, SL[si], rd ? (IMP)impd : (IMP)imp, types);
            MT[NM++] = (M){c, SL[si], f, k};
        }
        objc_registerClassPair(c);
    }
#ifdef VM
    FNS = malloc(sizeof(Fn) * (nf + 1));
    for (int i = 0; i < nf; i++) { FNS[i].nl = (int)rv(); FNS[i].ms = (int)rv(); W l = rv(); FNS[i].code = P; P += l; }
#endif
    (void)nf;
#ifdef TEST
    ts_test_start();
#endif
    W name = ((W (*)(W, SEL, const char *))objc_msgSend)((W)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), "A");
    return UIApplicationMain(argc, argv, 0, (void *)name);
}

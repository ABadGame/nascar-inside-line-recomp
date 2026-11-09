"""Order-independent jump table finder for XenonRecomp.

XenonAnalyse only matches fixed instruction sequences; this game's compiler
schedules them differently (e.g. lis / rlwinm / addi / lwzx). Instead, for every
bctr we find the guarding `cmplwi crN, rIdx, N` + `bgt/ble crN`, then
symbolically execute forward to the bctr and work out where CTR came from.

usage: python find_switches.py default.bin out.toml
"""
import struct, sys
from bisect import bisect_right

BASE = 0x82000000
CODE = [(0x822C0000, 0x8372CF44), (0x8372D000, 0x83741EC0), (0x83742000, 0x83743024)]
PDATA = (0x82232400, 0x822B3058)
BCTR = 0x4E800420

img = open(sys.argv[1], "rb").read()


def w(a):
    return struct.unpack_from(">I", img, a - BASE)[0]


def h(a):
    return struct.unpack_from(">H", img, a - BASE)[0]


def b(a):
    return img[a - BASE]


def s16(x):
    return x - 0x10000 if x & 0x8000 else x


# function bounds from .pdata, used to sanity-check labels
funcs = []
for a in range(PDATA[0], PDATA[1], 8):
    beg, packed = w(a), w(a + 4)
    if beg:
        funcs.append((beg, ((packed >> 8) & 0x3FFFFF) * 4))
funcs.sort()
starts = [f[0] for f in funcs]


def func_of(addr):
    i = bisect_right(starts, addr) - 1
    if i >= 0 and funcs[i][0] <= addr < funcs[i][0] + funcs[i][1]:
        return funcs[i]
    return None


def find_guard(bctr):
    """Walk back to the conditional branch + cmplwi that bound the index."""
    cr = None
    for i in range(1, 40):
        a = bctr - 4 * i
        x = w(a)
        op = x >> 26
        if x == BCTR:
            return None  # ran into a previous switch
        if cr is None:
            bo, bi = (x >> 21) & 31, (x >> 16) & 31
            # bc / bclr with "branch if CR bit GT set" (bgt) or "if GT clear" (ble)
            is_bc = op == 16 or (op == 19 and (x >> 1) & 0x3FF == 16)
            if is_bc and bi % 4 == 1 and (bo & 0x14) in (0x04, 0x0C) and bo & 0x10 == 0:
                cr = bi // 4
                guard = a
                default = None
                if op == 16 and not x & 2:
                    default = (a + s16(x & 0xFFFC)) & 0xFFFFFFFF
                bgt = bool(bo & 0x08)
        else:
            if op == 10 and (x >> 23) & 7 == cr and not (x >> 21) & 1:  # cmplwi
                return a, (x >> 16) & 31, x & 0xFFFF, guard, default, bgt
    return None


def simulate(start, bctr, ridx):
    """Forward symbolic execution from start to bctr. Returns (ctr expr, idx intact)."""
    R = {ridx: ("idx", 1)}
    ctr = None
    for a in range(start, bctr, 4):
        x = w(a)
        op, rd, ra, rb = x >> 26, (x >> 21) & 31, (x >> 16) & 31, (x >> 11) & 31
        imm = x & 0xFFFF
        v = "keep"
        if op == 15:  # addis / lis
            base = 0 if ra == 0 else (R.get(ra) if (R.get(ra) or (None,))[0] == "c" else None)
            v = ("c", ((base[1] if base else 0) + (imm << 16)) & 0xFFFFFFFF) if (ra == 0 or base) else None
        elif op == 14:  # addi / li
            if ra == 0:
                v = ("c", s16(imm) & 0xFFFFFFFF)
            elif (R.get(ra) or (None,))[0] == "c":
                v = ("c", (R[ra][1] + s16(imm)) & 0xFFFFFFFF)
            else:
                v = None
        elif op == 24:  # ori rA, rS, imm (dest is ra)
            src = R.get(rd)
            R[ra] = ("c", src[1] | imm) if src and src[0] == "c" else (src if imm == 0 else None)
            continue
        elif op == 21:  # rlwinm rA, rS, sh, mb, me (dest is ra)
            sh, mb, me = (x >> 11) & 31, (x >> 6) & 31, (x >> 1) & 31
            src = R.get(rd)
            res = None
            if src and mb == 0 and me == 31 - sh:  # plain shift left
                if src[0] == "idx":
                    res = ("idx", src[1] << sh)
                elif src[0] == "ld":
                    res = ("ld", src[1], src[2], src[3] + sh)
            elif src and sh == 0 and mb == 24 and me == 31 and src[0] == "ld":  # clrlwi 24 on byte load
                res = src
            R[ra] = res
            continue
        elif op == 31:
            xo = (x >> 1) & 0x3FF
            if xo in (23, 87, 279):  # lwzx, lbzx, lhzx
                size = {23: 4, 87: 1, 279: 2}[xo]
                A, Bv = R.get(ra), R.get(rb)
                if A and A[0] == "idx":
                    A, Bv = Bv, A
                if A and A[0] == "c" and Bv and Bv[0] == "idx" and Bv[1] == size:
                    v = ("ld", size, A[1], 0)
                else:
                    v = None
            elif xo == 266:  # add
                A, Bv = R.get(ra), R.get(rb)
                if A and A[0] == "ld":
                    A, Bv = Bv, A
                v = ("tgt", A[1], Bv) if A and A[0] == "c" and Bv and Bv[0] == "ld" else None
            elif xo == 444:  # or rA, rS, rB  (mr when rS == rB)
                R[ra] = R.get(rd) if rd == rb else None
                continue
            elif xo == 467 and ((x >> 16) & 0x1F) | (((x >> 11) & 0x1F) << 5) == 9:  # mtctr
                ctr = R.get(rd)
                continue
            elif xo in (151, 215, 407, 150, 183, 0, 32, 662, 918):  # stores / cmp: no GPR dest
                continue
            else:
                v = None
        elif op in (36, 37, 38, 39, 44, 45, 52, 53, 54, 55, 62, 10, 11, 16, 18, 19):  # stores, cmp, branches
            continue
        elif op in (20, 21, 23, 24, 25, 26, 27, 28, 29):  # logical immediates: dest is ra
            R[ra] = None
            continue
        else:
            v = None
        if v != "keep":
            R[rd] = v
    return ctr, R.get(ridx) == ("idx", 1)


MAX_GAP = 0x20  # alignment padding allowed between merged chunks
DEBUG = False
dbg = []


def merge_range(lo, hi):
    i0, i1 = bisect_right(starts, lo) - 1, bisect_right(starts, hi) - 1
    if i0 < 0 or not (funcs[i1][0] <= hi < funcs[i1][0] + funcs[i1][1]):
        return None
    if not (funcs[i0][0] <= lo < funcs[i0][0] + funcs[i0][1]):
        return None
    for k in range(i0, i1):
        if funcs[k + 1][0] - (funcs[k][0] + funcs[k][1]) > MAX_GAP:
            return None
    return funcs[i0][0], funcs[i1][0] + funcs[i1][1]


def section_of(a):
    for lo, hi in CODE:
        if lo <= a < hi:
            return lo, hi
    return None


def gap_function(a, labels):
    """Bounds of a leaf function (no .pdata) that contains `a`.

    The gap between two .pdata functions can hold several leaf functions,
    separated by zero padding; split on that padding.
    """
    i = bisect_right(starts, a) - 1
    sec = section_of(a)
    gap_lo = funcs[i][0] + funcs[i][1] if i >= 0 else sec[0]
    gap_hi = funcs[i + 1][0] if i + 1 < len(funcs) else sec[1]
    gap_lo, gap_hi = max(gap_lo, sec[0]), min(gap_hi, sec[1])
    if not (gap_lo <= a < gap_hi):
        return None
    bounds = [p for p in range(gap_lo, gap_hi, 4) if w(p) != 0 and (p == gap_lo or w(p - 4) == 0)]
    fstart = max((p for p in bounds if p <= a), default=None)
    if fstart is None:
        return None
    top = max(labels + [a])
    fend = min((p for p in bounds if p > top), default=gap_hi)
    while fend > fstart and w(fend - 4) == 0:
        fend -= 4
    if not all(fstart <= l < fend for l in labels):
        return None
    return fstart, fend


tables, skipped, merges = [], {}, []
total = 0
for lo, hi in CODE:
    for a in range(lo, hi, 4):
        if w(a) != BCTR:
            continue
        total += 1
        g = find_guard(a)
        if not g:
            skipped["no cmplwi/bgt guard (likely a virtual/indirect call)"] = skipped.get("no cmplwi/bgt guard (likely a virtual/indirect call)", 0) + 1
            continue
        cmp_a, ridx, n, guard_a, default, bgt = g
        if not bgt:
            skipped["guard is ble (fallthrough default) - not handled"] = skipped.get("guard is ble (fallthrough default) - not handled", 0) + 1
            continue
        ctr, intact = simulate(cmp_a + 4, a, ridx)
        if not intact:
            skipped["index register overwritten before bctr"] = skipped.get("index register overwritten before bctr", 0) + 1
            continue
        count = n + 1
        if ctr and ctr[0] == "ld" and ctr[1] == 4 and ctr[3] == 0:
            kind, labels = "absolute", [w(ctr[2] + 4 * i) for i in range(count)]
        elif ctr and ctr[0] == "tgt":
            base, ld = ctr[1], ctr[2]
            rd = {1: b, 2: h, 4: w}[ld[1]]
            kind = {1: "byte offset", 2: "short offset", 4: "word offset"}[ld[1]] + (f" <<{ld[3]}" if ld[3] else "")
            labels = [(base + (rd(ld[2] + ld[1] * i) << ld[3])) & 0xFFFFFFFF for i in range(count)]
        else:
            skipped["could not resolve CTR source"] = skipped.get("could not resolve CTR source", 0) + 1
            continue
        f = func_of(a)
        bad = [l for l in labels if not f or not (f[0] <= l < f[0] + f[1])]
        if bad:
            # Labels in neighbouring .pdata chunks: merge the chunks into one
            # explicit function so the switch stays inside it.
            m = merge_range(min(labels + [a]), max(labels)) if f else gap_function(a, labels)
            if DEBUG and len(dbg) < 8: dbg.append((a, f, min(labels), max(labels), len(labels), kind, sum(1 for l in labels if not f or not (f[0] <= l < f[0] + f[1]))))
            if not m:
                skipped["labels outside function, chunks not contiguous"] = skipped.get("labels outside function, chunks not contiguous", 0) + 1
                continue
            merges.append(m)
        tables.append((a, ridx, default, labels, kind))

kinds = {}
for t in tables:
    kinds[t[4]] = kinds.get(t[4], 0) + 1
print(f"bctr total: {total}")
print(f"jump tables: {len(tables)}  {kinds}")
for k, v in sorted(skipped.items(), key=lambda kv: -kv[1]):
    print(f"  skipped {v:5d}  {k}")

# union overlapping merges, write as a TOML `functions = [...]` fragment
merged = []
for lo, hi in sorted(merges):
    if merged and lo <= merged[-1][1]:
        merged[-1][1] = max(merged[-1][1], hi)
    else:
        merged.append([lo, hi])
print(f"merged function ranges: {len(merged)} (from {len(merges)} tables)")
with open(sys.argv[3], "w") as o:
    o.write("functions = [\n")
    for lo, hi in merged:
        o.write(f"    {{ address = 0x{lo:X}, size = 0x{hi - lo:X} }},\n")
    o.write("]\n")

with open(sys.argv[2], "w") as o:
    o.write("# Generated by tools/find_switches.py (order-independent jump table finder)\n")
    o.write("# base = address of the bctr itself; r = index register from the guarding cmplwi\n\n")
    for a, r, d, labels, kind in tables:
        o.write(f"[[switch]]  # {kind}\nbase = 0x{a:X}\nr = {r}\n")
        o.write(f"default = 0x{(d or 0):X}\nlabels = [\n")
        for l in labels:
            o.write(f"    0x{l:X},\n")
        o.write("]\n\n")

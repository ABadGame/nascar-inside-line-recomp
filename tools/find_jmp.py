"""Find setjmp/longjmp candidates: functions that call RtlUnwind, and the
functions next to them, with a quick look at what they store/load.

usage: python find_jmp.py default.bin imports.txt
"""
import struct, sys
from bisect import bisect_right

BASE = 0x82000000
TEXT = (0x822C0000, 0x8372CF44)
PDATA = (0x82232400, 0x822B3058)

img = open(sys.argv[1], "rb").read()
imports = {}
for line in open(sys.argv[2]):
    a, _, n = line.strip().partition(" ")
    imports[n] = int(a, 16)

w = lambda a: struct.unpack_from(">I", img, a - BASE)[0]

# .pdata: (begin, packed) ; function length = bits 8..29 (in instructions)
funcs = []
for a in range(PDATA[0], PDATA[1], 8):
    begin, packed = w(a), w(a + 4)
    if begin == 0:
        continue
    funcs.append((begin, ((packed >> 8) & 0x3FFFFF) * 4))
funcs.sort()
starts = [f[0] for f in funcs]
print(f"{len(funcs)} functions in .pdata")


def func_of(addr):
    i = bisect_right(starts, addr) - 1
    if i >= 0 and funcs[i][0] <= addr < funcs[i][0] + funcs[i][1]:
        return funcs[i]
    return None


def callers(target):
    out = []
    for a in range(TEXT[0], TEXT[1], 4):
        x = w(a)
        if x >> 26 == 18 and x & 3 == 1:
            li = x & 0x03FFFFFC
            if li & 0x02000000:
                li -= 0x04000000
            if a + li == target:
                out.append(a)
    return out


def summarize(begin, size):
    """Count interesting op kinds keyed off r3 (jmp_buf pointer)."""
    kinds = {"std r3": 0, "ld r3": 0, "stfd r3": 0, "lfd r3": 0, "stvx": 0, "lvx": 0, "mflr": 0, "mtlr": 0, "mfcr": 0, "mtcrf": 0, "bl": 0}
    for a in range(begin, begin + size, 4):
        x = w(a)
        op, ra = x >> 26, (x >> 16) & 31
        if op == 62 and ra == 3: kinds["std r3"] += 1
        if op == 58 and ra == 3: kinds["ld r3"] += 1
        if op == 54 and ra == 3: kinds["stfd r3"] += 1
        if op == 50 and ra == 3: kinds["lfd r3"] += 1
        if op == 31 and (x >> 1) & 0x3FF == 231: kinds["stvx"] += 1
        if op == 31 and (x >> 1) & 0x3FF == 103: kinds["lvx"] += 1
        if x == 0x7D8802A6 or (x & 0xFC1FFFFF) == 0x7C0802A6: kinds["mflr"] += 1
        if (x & 0xFC1FFFFF) == 0x7C0803A6: kinds["mtlr"] += 1
        if (x & 0xFC1FFFFF) == 0x7C000026: kinds["mfcr"] += 1
        if (x & 0xFC0007FE) == 0x7C000120: kinds["mtcrf"] += 1
        if op == 18 and x & 1: kinds["bl"] += 1
    return {k: v for k, v in kinds.items() if v}


target = imports["__imp__RtlUnwind"]
seen = []
for c in callers(target):
    f = func_of(c)
    print(f"call @0x{c:08X} in func", f"0x{f[0]:08X} (+0x{f[1]:X})" if f else "?")
    if f and f not in seen:
        seen.append(f)

for f in seen:
    i = starts.index(f[0])
    for j in range(max(0, i - 2), min(len(funcs), i + 4)):
        b, s = funcs[j]
        mark = "  <== calls RtlUnwind" if funcs[j] in seen else ""
        print(f"  0x{b:08X} size 0x{s:04X} {summarize(b, s)}{mark}")
    print()

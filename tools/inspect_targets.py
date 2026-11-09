"""Describe branch targets ReXGlue reported as 'not in any function'.

usage: python inspect_targets.py default.bin 0xADDR [0xADDR ...]
For each target: the surrounding .pdata functions, the word before it, and
the instructions from the target to its first terminator (blr / b / bctr).
"""
import struct, sys
from bisect import bisect_right

BASE = 0x82000000
PDATA = (0x82232400, 0x822B3058)
img = open(sys.argv[1], "rb").read()
w = lambda a: struct.unpack_from(">I", img, a - BASE)[0]

funcs = []
for a in range(PDATA[0], PDATA[1], 8):
    b, p = w(a), w(a + 4)
    if b:
        funcs.append((b, ((p >> 8) & 0x3FFFFF) * 4))
funcs.sort()
starts = [f[0] for f in funcs]


def kind(x, a):
    op = x >> 26
    if x == 0x4E800020: return "blr", True
    if x == 0x4E800420: return "bctr", True
    if x == 0: return "(zero)", False
    if op == 18:
        li = x & 0x03FFFFFC
        if li & 0x02000000: li -= 0x04000000
        t = (a + li) & 0xFFFFFFFF
        return ("bl" if x & 1 else "b") + f" 0x{t:08X}", not (x & 1)
    if op == 16:
        bd = x & 0xFFFC
        if bd & 0x8000: bd -= 0x10000
        return f"bc 0x{(a + bd) & 0xFFFFFFFF:08X}", False
    return "", False


for t in (int(v, 16) for v in sys.argv[2:]):
    i = bisect_right(starts, t) - 1
    prev = funcs[i] if i >= 0 else None
    nxt = funcs[i + 1] if i + 1 < len(funcs) else None
    gap_lo = prev[0] + prev[1] if prev else 0
    print(f"== 0x{t:08X}  gap 0x{gap_lo:08X}..0x{nxt[0]:08X} (prev pdata fn 0x{prev[0]:08X}+0x{prev[1]:X})")
    print(f"   word before: {w(t - 4):08x} {kind(w(t - 4), t - 4)[0]}")
    a, n = t, 0
    while n < 64:
        s, term = kind(w(a), a)
        if s or n < 2:
            print(f"   0x{a:08X} {w(a):08x} {s}")
        if term:
            break
        a += 4; n += 1
    print(f"   -> body ends at 0x{a + 4:08X} (size 0x{a + 4 - t:X}); next pdata fn at 0x{nxt[0]:08X}")

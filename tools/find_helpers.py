"""Locate the PPC register save/restore helpers XenonRecomp needs.

usage: python find_helpers.py default.bin
The .bin is the flat image produced by xexdump (base 0x82000000).
"""
import struct, sys

BASE = 0x82000000
TEXT = (0x822C0000, 0x8372CF44)  # .text from xexdump

img = open(sys.argv[1], "rb").read()
words = lambda off, n: struct.unpack_from(f">{n}I", img, off)


def find_all(pat):
    out, i = [], img.find(pat, TEXT[0] - BASE, TEXT[1] - BASE)
    while i != -1:
        if i % 4 == 0:
            out.append(i)
        i = img.find(pat, i + 4, TEXT[1] - BASE)
    return out


def check_gpr(off, opbase):
    # 18 consecutive std/ld r14..r31 at -0x98..-0x10(r1)
    for k in range(18):
        rt = 14 + k
        d = (-0x98 + 8 * k) & 0xFFFC
        if words(off + 4 * k, 1)[0] != (opbase | rt << 21 | 1 << 16 | d):
            return False
    return True


def check_fpr(off, opbase):
    # 18 consecutive stfd/lfd f14..f31 at -0x90..-0x8(r12)
    for k in range(18):
        rt = 14 + k
        d = (-0x90 + 8 * k) & 0xFFFF
        if words(off + 4 * k, 1)[0] != (opbase | rt << 21 | 12 << 16 | d):
            return False
    return words(off + 72, 1)[0] == 0x4E800020  # blr


results = {}
for name, pat, chk in [
    ("savegprlr_14", 0xF9C1FF68, lambda o: check_gpr(o, 0xF8000000)),
    ("restgprlr_14", 0xE9C1FF68, lambda o: check_gpr(o, 0xE8000000)),
    ("savefpr_14", 0xD9CCFF70, lambda o: check_fpr(o, 0xD8000000)),
    ("restfpr_14", 0xC9CCFF70, lambda o: check_fpr(o, 0xC8000000)),
]:
    hits = [o for o in find_all(struct.pack(">I", pat)) if chk(o)]
    results[name] = hits

for name, pat in [
    ("savevmx_14", bytes.fromhex("3960fee07dcb61ce")),
    ("restvmx_14", bytes.fromhex("3960fee07dcb60ce")),
    ("savevmx_64", bytes.fromhex("3960fc00100b61cb")),
    ("restvmx_64", bytes.fromhex("3960fc00100b60cb")),
]:
    results[name] = find_all(pat)

for name, hits in results.items():
    print(f"{name:14s}", " ".join(f"0x{BASE + h:08X}" for h in hits) or "NOT FOUND")
    if hits:
        h = hits[0]
        tail = words(h, 24)
        print("               first words:", " ".join(f"{w:08x}" for w in tail[:8]), "...")

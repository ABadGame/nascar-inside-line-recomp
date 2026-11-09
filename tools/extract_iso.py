"""Extract every file from an XGD2 Xbox 360 ISO, keeping the directory tree.

usage: python extract_iso.py game.iso outdir
Existing files with the right size are skipped. The console's $SystemUpdate
folder (a dashboard update the game never reads) is not extracted.
"""
import os, struct, sys

BASE = 0xFD90000  # XGD2 game partition
SECT = 2048
iso, out = sys.argv[1], sys.argv[2]
f = open(iso, "rb")


def rd(off, n):
    f.seek(off)
    return f.read(n)


vd = rd(BASE + 32 * SECT, SECT)
assert vd[:20] == b"MICROSOFT*XBOX*MEDIA", "not an XGD2 image"
root_sec, root_size = struct.unpack_from("<II", vd, 20)
files = []


def walk(sec, size, path):
    data = rd(BASE + sec * SECT, size)
    stack, seen = [0], set()
    while stack:
        o = stack.pop()
        if o in seen or o * 4 + 14 > len(data):
            continue
        seen.add(o)
        p = o * 4
        l, r, s, sz, attr, nl = struct.unpack_from("<HHIIBB", data, p)
        if l == 0xFFFF and r == 0xFFFF:
            continue
        name = data[p + 14:p + 14 + nl].decode("latin1")
        if l: stack.append(l)
        if r: stack.append(r)
        full = f"{path}/{name}" if path else name
        if attr & 0x10:
            if full.lower().startswith("$systemupdate"):
                continue
            os.makedirs(os.path.join(out, full), exist_ok=True)
            if sz:
                walk(s, sz, full)
        else:
            files.append((full, s, sz))


walk(root_sec, root_size, "")
CHUNK = 64 << 20
files = [f for f in files if not f[0].lower().startswith("$systemupdate")]
for name, s, sz in sorted(files):
    dst = os.path.join(out, name)
    if os.path.exists(dst) and os.path.getsize(dst) == sz:
        print(f"skip  {name}")
        continue
    os.makedirs(os.path.dirname(dst) or out, exist_ok=True)
    f.seek(BASE + s * SECT)
    left = sz
    with open(dst, "wb") as o:
        while left:
            n = min(CHUNK, left)
            o.write(f.read(n))
            left -= n
    print(f"wrote {name} ({sz / 2**20:.1f} MB)")
print(f"{len(files)} files")

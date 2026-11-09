"""Add [functions] entries for code ReXGlue missed, using its real function bounds.

usage:
  python find_code_ptrs.py default.bin imports.txt BASELINE.bounds.txt generated_dir \
         base_fixups.toml out_fixups.toml [codegen.out ...]

BASELINE.bounds.txt is written by the patched codegen (<out_dir>.bounds.txt,
"base end authority" per line) from a run using only base_fixups.toml, so it
reflects what ReXGlue found on its own. Re-running with the same inputs gives
the same output.

1. Function-pointer targets (lis/addi|ori pairs in code, 32-bit words in data):
   - already a function start                      -> skip (ReXGlue's span is trusted)
   - inside a PDATA/DISCOVERED/VTABLE/CONFIG body  -> skip (internal label)
   - inside an import thunk                        -> skip
   - inside a GAP_FILL body, or in no function     -> new entry, if it follows a
     terminator/padding and is not already an internal label (loc_XXXXXXXX)
2. "Unresolved conditional branch to T from F" warnings in codegen output:
   the function containing F was cut short; grow it to cover T.
Overlaps are resolved by cutting the earlier entry back to the next entry.
"""
import glob, os, re, struct, sys
from bisect import bisect_right

GAP_FILL, DISCOVERED, VTABLE, HELPER, PDATA, CONFIG, IMPORT = range(7)
BASE = 0x82000000
CODE = [(0x822C0000, 0x8372CF44), (0x8372D000, 0x83741EC0), (0x83742000, 0x83743024)]
DATA = [(0x82000600, 0x82232274), (0x822B3200, 0x822B5C44), (0x83755C00, 0x83AE0A24)]

bin_path, imports_path, bounds_path, gen_dir, base_fixups, out_fixups = sys.argv[1:7]
codegen_outs = sys.argv[7:]

img = open(bin_path, "rb").read()
w = lambda a: struct.unpack_from(">I", img, a - BASE)[0]
s16 = lambda x: x - 0x10000 if x & 0x8000 else x
in_code = lambda a: any(lo <= a < hi for lo, hi in CODE)

# --- ReXGlue's own functions ---
fns = []
for line in open(bounds_path):
    b, e, auth = line.split()
    fns.append((int(b, 16), int(e, 16), int(auth)))
fns.sort()
fstarts = [f[0] for f in fns]
starts_set = set(fstarts)


def containing(a):
    """Function whose body contains a (not counting its start), or None."""
    # Functions do not nest (save/restore helpers may overlap), so the nearest
    # few starts at or below `a` are enough.
    i = bisect_right(fstarts, a) - 1
    for j in range(i, max(i - 4, -1), -1):
        b, e, auth = fns[j]
        if b < a < e:
            return fns[j]
    return None


imports = sorted(int(l.split()[0], 16) for l in open(imports_path) if l.strip())
in_imports = lambda a: imports and imports[0] <= a < imports[-1] + 0x10

labels = set()
for cpp in glob.glob(os.path.join(gen_dir, "*_recomp.*.cpp")):
    labels.update(int(m, 16) for m in re.findall(r"^loc_([0-9A-F]{8}):", open(cpp).read(), re.M))


def plausible_start(a):
    prev = w(a - 4)
    op = prev >> 26
    return prev in (0, 0x4E800020, 0x4E800420) or op == 18  # blr/bctr/pad, b, or noreturn bl


def branch_target(x, a):
    op = x >> 26
    if op == 16:
        return (a + s16(x & 0xFFFC)) & 0xFFFFFFFF
    if op == 18 and not x & 2:
        li = x & 0x03FFFFFC
        return (a + (li - 0x04000000 if li & 0x02000000 else li)) & 0xFFFFFFFF
    return None


def extent(t, limit):
    """End of a leaf starting at t: first blr/bctr/b past the furthest internal branch."""
    furthest, a = t, t
    while a < limit:
        x = w(a)
        if x == 0:
            return a
        op, bt = x >> 26, branch_target(x, a)
        if bt is not None and t <= bt < limit and not (op == 18 and x & 1):
            if op == 16 or bt > a:          # bc anywhere inside, or a forward b skip
                furthest = max(furthest, bt)
                if op == 18:
                    a += 4
                    continue
        if (x in (0x4E800020, 0x4E800420) or (op == 18 and not x & 1)) and a >= furthest:
            return a + 4
        a += 4
    return limit


# --- base fixups (hand-checked) ---
entry_re = re.compile(r'^"0x([0-9A-F]+)" = \{ size = 0x([0-9A-F]+) \}\s*(?:#\s*(.*))?$', re.M)
entries = {int(a, 16): [int(s, 16), c or ""] for a, s, c in entry_re.findall(open(base_fixups).read())}
base_count = len(entries)

# --- 1. pointer targets ---
cands = {}
for lo, hi in CODE:
    for a in range(lo, hi, 4):
        x = w(a)
        if x >> 26 != 15 or (x >> 16) & 31:
            continue
        rx, up = (x >> 21) & 31, (x & 0xFFFF) << 16
        for k in range(1, 17):
            y = w(a + 4 * k); op = y >> 26
            if op == 14 and (y >> 16) & 31 == rx:
                t = (up + s16(y & 0xFFFF)) & 0xFFFFFFFF
            elif op == 24 and (y >> 21) & 31 == rx:
                t = up | (y & 0xFFFF)
            else:
                if op in (14, 15, 32, 34, 40, 42, 58) and (y >> 21) & 31 == rx:
                    break
                continue
            if t % 4 == 0 and in_code(t):
                cands.setdefault(t, f"lis/addi @0x{a:08X}")
            break
for lo, hi in DATA:
    for a in range(lo, hi - 3, 4):
        t = w(a)
        if t % 4 == 0 and in_code(t):
            cands.setdefault(t, f"data ptr @0x{a:08X}")

accepted = {}
why_skip = {}
for t, why in sorted(cands.items()):
    reason = None
    if t in starts_set or t in entries:
        reason = "already a function"
    elif in_imports(t):
        reason = "import thunk"
    elif w(t) == 0 or not plausible_start(t):
        reason = "not a plausible start"
    elif w(t - 4) == 0x4E800420 and why.startswith("lis/addi") and (in_code(w(t)) or w(t) >> 26 == 0):
        # a table right after its bctr: absolute entries are code addresses,
        # byte/short offset entries decode as opcode 0. Real code is neither.
        reason = "jump table data after bctr"
    else:
        c = containing(t)
        if c and c[2] not in (GAP_FILL, CONFIG):  # CONFIG bounds come from the base list, re-checked below
            reason = "inside a real function"
        elif t in labels:
            reason = "internal label"
    if reason:
        why_skip[reason] = why_skip.get(reason, 0) + 1
    else:
        accepted[t] = why

hard = sorted({f[0] for f in fns if f[2] != GAP_FILL} | set(accepted) | set(entries))


def next_hard(a):
    i = bisect_right(hard, a)
    return hard[i] if i < len(hard) else CODE[0][1]


for t, why in accepted.items():
    entries[t] = [extent(t, next_hard(t)) - t, why]

# --- 2. grow functions with unresolved internal branches ---
grown = 0
for path in codegen_outs:
    for tgt, src in re.findall(r"Unresolved conditional branch to 0x([0-9A-F]+) from 0x([0-9A-F]+)", open(path).read()):
        tgt, src = int(tgt, 16), int(src, 16)
        owner = next((a for a in sorted(entries, reverse=True) if a <= src < a + entries[a][0]), None)
        if owner is None:
            c = containing(src) or next((f for f in fns if f[0] == src), None)
            if not c:
                print(f"  ?? no function contains 0x{src:08X}")
                continue
            owner = c[0]
            entries[owner] = [c[1] - c[0], f"grown: ReXGlue body ended at 0x{c[1]:08X}"]
        end = max(owner + entries[owner][0], extent(tgt, next_hard(tgt)))
        entries[owner][0] = end - owner
        if "branch to" not in entries[owner][1]:
            entries[owner][1] += f"; covers branch to 0x{tgt:08X} from 0x{src:08X}"
        grown += 1

# --- overlaps ---
order = sorted(entries)
for i in range(len(order) - 1):
    a, b = order[i], order[i + 1]
    if a + entries[a][0] > b:
        print(f"  shrink 0x{a:08X}: 0x{entries[a][0]:X} -> 0x{b - a:X} (next entry 0x{b:08X})")
        entries[a][0] = b - a

with open(out_fixups, "w") as o:
    o.write("# Function entries for code ReXGlue left outside any function.\n")
    o.write("# Generated by tools/find_code_ptrs.py from the hand-checked base list plus\n")
    o.write("# unregistered pointer targets and cut-short functions. Do not edit by hand:\n")
    o.write("# edit the base list (nascar/nascar_fixups.base.toml) and regenerate.\n\n")
    o.write("[functions]\n")
    for a in order:
        o.write(f'"0x{a:X}" = {{ size = 0x{entries[a][0]:X} }}  # {entries[a][1]}\n')

print(f"{len(fns)} functions in baseline, {len(labels)} labels, {len(cands)} pointer candidates")
for k, v in sorted(why_skip.items(), key=lambda kv: -kv[1]):
    print(f"  skipped {v:6d}  {k}")
print(f"{base_count} base + {len(accepted)} pointer targets, {grown} grown -> {len(entries)} entries")

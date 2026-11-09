"""Convert find_switches.py output (XenonRecomp format) to a ReXGlue include.

usage: python to_rexglue.py switch_tables.toml functions.fragment.toml out.toml
"""
import sys, tomllib

sw = tomllib.load(open(sys.argv[1], "rb")).get("switch", [])
fn = tomllib.load(open(sys.argv[2], "rb")).get("functions", [])

with open(sys.argv[3], "w") as o:
    o.write("# Jump tables + leaf function bounds from tools/find_switches.py\n")
    o.write("# (order-independent finder; this game's compiler schedules lis/rlwinm/addi)\n\n")
    o.write("[functions]\n")
    for f in fn:
        o.write(f'"0x{f["address"]:X}" = {{ size = 0x{f["size"]:X} }}\n')
    o.write("\n")
    for t in sw:
        o.write(f"[[switch_tables]]\naddress = 0x{t['base']:X}\nregister = {t['r']}\nlabels = [")
        o.write(", ".join(f"0x{l:X}" for l in t["labels"]))
        o.write("]\n\n")
print(f"{len(sw)} switch tables, {len(fn)} functions -> {sys.argv[3]}")

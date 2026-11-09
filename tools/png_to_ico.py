"""Wrap a PNG in a Windows .ico (PNG-compressed icon entry, Vista+) and write
a matching .rc file so the icon can be compiled into an executable.

usage: python png_to_ico.py title.png nascar.ico nascar.rc
"""
import struct, sys

png_path, ico_path, rc_path = sys.argv[1:4]
png = open(png_path, "rb").read()
if png[:8] != b"\x89PNG\r\n\x1a\n" or png[12:16] != b"IHDR":
    sys.exit(f"{png_path} is not a PNG")
width, height = struct.unpack(">II", png[16:24])
if not (1 <= width <= 256 and 1 <= height <= 256):
    sys.exit(f"icon size {width}x{height} is outside 1..256")

# ICONDIR (reserved, type=1 icon, count=1) + one ICONDIRENTRY, then the PNG.
header = struct.pack("<HHH", 0, 1, 1)
entry = struct.pack("<BBBBHHII",
                    width % 256, height % 256,  # 0 means 256
                    0, 0,                       # palette colours, reserved
                    1, 32,                      # planes, bits per pixel
                    len(png), 6 + 16)           # data size, data offset
with open(ico_path, "wb") as f:
    f.write(header + entry + png)

ico_name = ico_path.replace("\\", "/").rsplit("/", 1)[-1]
with open(rc_path, "w") as f:
    # Resource ID 1 is the icon Explorer and the taskbar show for the exe.
    f.write(f'1 ICON "{ico_name}"\n')
print(f"{width}x{height} PNG -> {ico_path} + {rc_path}")

#!/usr/bin/env python3
#
# Generates samples/etv-test-arabic.ttf: a subset of Noto Sans Arabic (SIL Open
# Font License 1.1; the copyright and license name records are kept) with only
# beh, lam, alef and space, renamed to "ETV Test Arabic" so it never matches an
# installed Noto.
#
# The subset keeps the GSUB joining forms and the lam-alef ligature, which is
# what HarfBuzz (libass complex shaping) uses. It drops the Arabic Presentation
# Forms code points and U+FEFF, which is what FriBidi (libass simple shaping)
# turns the text into, so the two shapers render this font differently: simple
# shaping draws boxes or fallback glyphs, complex shaping draws the ligature.
#
# Needs fontTools. Usage: make-arabic-lam-alef-font.py [/path/to/NotoSansArabic-Regular.ttf]

import os
import subprocess
import sys

from fontTools import subset
from fontTools.ttLib import TTFont

FAMILY = "ETV Test Arabic"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "etv-test-arabic.ttf")


def find_source():
    if len(sys.argv) > 1:
        return sys.argv[1]
    return subprocess.run(
        ["fc-match", "-f", "%{file}", "Noto Sans Arabic:style=Regular"],
        check=True, capture_output=True, text=True,
    ).stdout


src = find_source()
font = TTFont(src)
if "Noto Sans Arabic" not in font["name"].getDebugName(1):
    sys.exit(f"ERROR: {src} is not Noto Sans Arabic")

options = subset.Options()
options.layout_features = ["*"]
options.name_IDs = ["*"]
options.name_languages = ["*"]
options.notdef_outline = True
options.hinting = False
subsetter = subset.Subsetter(options)
subsetter.populate(unicodes=[0x20, 0x0627, 0x0628, 0x0644])
subsetter.subset(font)

cmap = font.getBestCmap()
leaked = [cp for cp in cmap if cp == 0xFEFF or 0xFB50 <= cp <= 0xFDFF or 0xFE70 <= cp <= 0xFEFC]
if leaked:
    sys.exit("ERROR: presentation forms survived the subset: " + ", ".join(f"U+{cp:04X}" for cp in leaked))

ps_name = FAMILY.replace(" ", "")
for record in font["name"].names:
    if record.nameID in (1, 16):
        record.string = FAMILY
    elif record.nameID == 4:
        record.string = FAMILY + " Regular"
    elif record.nameID == 6:
        record.string = ps_name + "-Regular"
    elif record.nameID == 3:
        record.string = ps_name + "-Regular;subset"

font.save(OUT)
print(f"{OUT}: {os.path.getsize(OUT)} bytes, code points " + " ".join(f"U+{cp:04X}" for cp in sorted(cmap)))

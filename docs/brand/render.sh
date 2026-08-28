#!/bin/sh
# Render icon.svg to PNG at every size a directory asks for.
#
# Chrome, not ImageMagick: magick has no librsvg delegate here and renders this
# file as a black square. And the window must be TALLER than the target, because
# headless Chrome's viewport is shorter than the window it is given — at
# --window-size=512,512 the bottom 87 rows come back transparent. Render tall,
# crop square.
set -eu
cd "$(dirname "$0")"
google-chrome --headless --disable-gpu --no-sandbox --hide-scrollbars \
  --force-device-scale-factor=1 --default-background-color=00000000 \
  --window-size=512,700 --screenshot=raw.png "file://$PWD/wrap.html" 2>/dev/null
python3 - <<'PY'
from PIL import Image
im = Image.open('raw.png').convert('RGBA').crop((0, 0, 512, 512))
im.save('icon-512.png')
for s in (256, 128, 64, 32, 16):
    im.resize((s, s), Image.LANCZOS).save(f'icon-{s}.png')
px = im.load()
rows = [y for y in range(512) if any(px[x, y][3] > 0 for x in range(0, 512, 8))]
assert (min(rows), max(rows)) == (0, 511), f"clipped: rows {min(rows)}..{max(rows)}"
print("rendered icon-512/256/128/64/32/16.png")
PY
rm -f raw.png

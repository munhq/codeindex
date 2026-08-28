#!/bin/sh
# Regenerate the PNG exports from icon.svg and logo.svg.
#
# Only the sizes something actually references are committed — icon-512.png
# (server.json, the .mcpb manifest, Smithery, Docker) and icon-128.png (the .mcpb
# manifest). Every other size is a build artefact: this script writes them into a
# temp directory, prints where, and leaves the repository alone. Committing seven
# PNGs nothing reads is how a repo fills up with files no one dares delete.
#
# Chrome, not ImageMagick: magick has no librsvg delegate here and renders these
# files as a black square. And the window must be TALLER than the target, because
# headless Chrome's viewport is shorter than the window it is given — at
# --window-size=512,512 the bottom 87 rows come back transparent.
#
#   ./render.sh            regenerate the two committed PNGs
#   ./render.sh --all      also write every other size to a temp directory
set -eu
cd "$(dirname "$0")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

shot() {   # shot <svg> <width> <height> <out.png> <scale> <full-bleed 1|0>
    cat > "$tmp/wrap.html" <<HTML
<!doctype html><html><head><style>
html,body{margin:0;padding:0;background:transparent}
img{display:block;width:${2}px;height:${3}px}
</style></head><body><img src="$PWD/$1"></body></html>
HTML
    google-chrome --headless --disable-gpu --no-sandbox --hide-scrollbars \
        --force-device-scale-factor="$5" --default-background-color=00000000 \
        --window-size="$2",$(( $3 + 260 )) \
        --screenshot="$tmp/raw.png" "file://$tmp/wrap.html" 2>/dev/null
    python3 - "$tmp/raw.png" "$4" "$2" "$3" "$5" "$6" <<'PY'
import sys
from PIL import Image
raw, out, w, h, scale, bleed = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), sys.argv[6] == '1'
im = Image.open(raw).convert('RGBA').crop((0, 0, w * scale, h * scale))
if scale != 1:
    im = im.resize((w, h), Image.LANCZOS)
im.save(out)
px = im.load()
rows = [y for y in range(h) if any(px[x, y][3] > 0 for x in range(0, w, 8))]
if not rows:
    raise SystemExit("nothing rendered")
# The icon is a filled square, so any transparent edge row means Chrome's short
# viewport clipped it. The wordmark has margins by design, so it is only checked
# for ink — asserting full bleed there fails on a correct render.
if bleed:
    assert (min(rows), max(rows)) == (0, h - 1), f"clipped: rows {min(rows)}..{max(rows)} of {h}"
PY
}

shot icon.svg 512 512 icon-512.png 1 1
python3 - <<'PY'
from PIL import Image
Image.open('icon-512.png').resize((128, 128), Image.LANCZOS).save('icon-128.png')
PY
echo "wrote icon-512.png and icon-128.png (the two anything references)"

if [ "${1:-}" = "--all" ]; then
    out="$(mktemp -d)"
    shot logo.svg 470 140 "$out/logo-470.png" 2 0
    # GitHub's social preview: 1280x640, uploaded once through repo Settings.
    # GitHub stores its own copy, so this is never committed — regenerate it here
    # when the card changes.
    shot social.svg 1280 640 "$out/social-1280x640.png" 1 1
    python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
im = Image.open('icon-512.png')
for s in (256, 64, 32, 16):
    im.resize((s, s), Image.LANCZOS).save(f"{out}/icon-{s}.png")
PY
    echo "not committed, regenerate as needed: $out"
    echo "  social-1280x640.png -> upload at Settings > Social preview"
fi

#!/usr/bin/env bash
# Render the ai& wordmark for the boot splash (Plymouth theme "aiand") and the
# idle screen (tsv-idle-screen), from rootfs/assets/aiand-wordmark.svg.
# Run on the laptop; the outputs are checked in, so build-image.sh does not
# need rsvg-convert or ImageMagick.
#
#   rootfs/scripts/render-logo.sh
#   ACCENT=white rootfs/scripts/render-logo.sh   # recolour the red accent too
#
# The source SVG has four #151517 shapes (the letters and the lower chevron) and
# one #C70007 shape (the red accent stripe). #151517 becomes #ffffff. The red
# accent is kept by default (ACCENT=red); ACCENT=white makes the mark all white.
#
# Outputs:
#   assets/aiand-wordmark-white.svg                   recoloured source
#   assets/preview-splash-800x1280.png                what Plymouth draws (progress shown at 40 %)
#   assets/preview-idle-800x1280.png                  what tsv-idle-screen writes to /dev/fb0
#   overlay/usr/share/plymouth/themes/aiand/logo.png  wordmark, 520 px wide, transparent
#   overlay/usr/share/plymouth/themes/aiand/bar.png   1x1 white pixel (progress bar)
#   overlay/usr/share/tsv/idle-screen/idle-800x1280.{xrgb8888,rgb565}.zst
#                                                     raw framebuffer images (little endian)
#   idle-rotate/logo-524x175.bgrx.zst                 the wordmark for tsv-idle-rotate
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TOP=$(cd "$HERE/.." && pwd)
ASSETS=$TOP/assets
THEME=$HERE/overlay/usr/share/plymouth/themes/aiand
IDLE=$HERE/overlay/usr/share/tsv/idle-screen
SRC=$ASSETS/aiand-wordmark.svg
ACCENT=${ACCENT:-red}

# Panel: 800x1280 portrait (native), ~189 ppi. Wordmark at 65 % of the width.
W=800 H=1280
LOGO_W=520                       # 0.65 * 800
# Must match aiand.script (bar geometry) and tsv-idle-screen (nothing to match:
# it writes the whole frame).
BAR_W=160 BAR_H=3 BAR_GAP=110    # gap from the bottom of the wordmark
BAR_TRACK=0.20 BAR_FILL=0.75     # opacities over black

for t in rsvg-convert magick python3 zstd; do
    command -v $t >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done
[[ -f $SRC ]] || { echo "missing $SRC" >&2; exit 1; }
mkdir -p "$THEME" "$IDLE"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---- recolour (the source is never modified)
case $ACCENT in
    red) sed 's/#151517/#ffffff/g' "$SRC" ;;
    white) sed -e 's/#151517/#ffffff/g' -e 's/#C70007/#ffffff/gI' "$SRC" ;;
    *) echo "ACCENT must be red or white" >&2; exit 1 ;;
esac > "$ASSETS/aiand-wordmark-white.svg"
grep -q '#151517' "$ASSETS/aiand-wordmark-white.svg" && { echo "recolour failed" >&2; exit 1; }

# ---- wordmark, transparent background. The SVG has no viewBox, so scale with
# --zoom (1280 -> 520) rather than --width.
zoom=$(python3 -c "print($LOGO_W / 1280)")
rsvg-convert --zoom "$zoom" "$ASSETS/aiand-wordmark-white.svg" -o "$tmp/logo.png"
magick "$tmp/logo.png" -strip -define png:color-type=6 "$THEME/logo.png"
read -r lw lh < <(magick identify -format '%w %h\n' "$THEME/logo.png")
[[ $lw == "$LOGO_W" ]] || { echo "unexpected logo width $lw" >&2; exit 1; }
magick -size 1x1 xc:white -strip -define png:color-type=6 "$THEME/bar.png"

# ---- geometry, computed the way aiand.script computes it (Math.Int truncates)
lx=$(( (W - lw) / 2 )) ly=$(( (H - lh) / 2 ))
bx=$(( (W - BAR_W) / 2 )) by=$(( ly + lh + BAR_GAP ))
fill_w=$(( BAR_W * 40 / 100 ))
# Plymouth draws the fill sprite over the track sprite, both white with opacity.
track=$(python3 -c "print(round(255 * $BAR_TRACK))")
fill=$(python3 -c "print(round(255 * $BAR_FILL + 255 * $BAR_TRACK * (1 - $BAR_FILL)))")

# ---- idle screen: black, wordmark centred, nothing else
magick -size ${W}x${H} xc:black "$THEME/logo.png" -geometry +$lx+$ly -composite \
    -alpha off -strip -define png:color-type=2 "$ASSETS/preview-idle-800x1280.png"

# ---- splash preview: idle frame plus the progress bar (track + 40 % fill)
magick "$ASSETS/preview-idle-800x1280.png" \
    -fill "rgb($track,$track,$track)" -draw "rectangle $bx,$by $((bx + BAR_W - 1)),$((by + BAR_H - 1))" \
    -fill "rgb($fill,$fill,$fill)" -draw "rectangle $bx,$by $((bx + fill_w - 1)),$((by + BAR_H - 1))" \
    -alpha off -strip -define png:color-type=2 "$ASSETS/preview-splash-800x1280.png"

# ---- raw framebuffer images for tsv-idle-screen. msm's fbdev is 32 bpp
# XRGB8888 (bytes B,G,R,X in memory) with pitch ALIGN(800, 32) * 4 = 3200; the
# RGB565 copy covers a 16 bpp fbdev.
magick "$ASSETS/preview-idle-800x1280.png" -depth 8 "rgb:$tmp/idle.rgb"
python3 -I - "$tmp/idle.rgb" "$tmp/idle.xrgb8888" "$tmp/idle.rgb565" <<'PY'
import sys
src = open(sys.argv[1], "rb").read()
assert len(src) == 800 * 1280 * 3, len(src)
x = bytearray(800 * 1280 * 4)
x[0::4] = src[2::3]          # B
x[1::4] = src[1::3]          # G
x[2::4] = src[0::3]          # R
x[3::4] = b"\xff" * (800 * 1280)
open(sys.argv[2], "wb").write(x)
r, g, b = src[0::3], src[1::3], src[2::3]
o = bytearray(800 * 1280 * 2)
for i in range(800 * 1280):
    v = ((r[i] >> 3) << 11) | ((g[i] >> 2) << 5) | (b[i] >> 3)
    o[2 * i] = v & 0xff
    o[2 * i + 1] = v >> 8
open(sys.argv[3], "wb").write(o)
PY
zstd -q -19 -f "$tmp/idle.xrgb8888" -o "$IDLE/idle-800x1280.xrgb8888.zst"
zstd -q -19 -f "$tmp/idle.rgb565" -o "$IDLE/idle-800x1280.rgb565.zst"

# ---- tsv-idle-rotate's logo: the static frame's wordmark with a 2 px black
# border, 524x175 at +$((lx - 2))+$((ly - 2)), same B,G,R,X bytes (already
# composited on black). Embedded into the binary by idle-rotate/build.sh,
# which assumes these numbers (LW, LH, LOGO_X0, LOGO_Y0 in tsv-idle-rotate.c).
[[ $lw == 520 && $lh == 171 && $lx == 140 && $ly == 554 ]] ||
    { echo "logo geometry changed: update idle-rotate/tsv-idle-rotate.c" >&2; exit 1; }
python3 -I - "$tmp/idle.xrgb8888" "$tmp/logo.bgrx" <<'PY'
import sys
src = open(sys.argv[1], "rb").read()
out = b"".join(src[(y * 800 + 138) * 4:(y * 800 + 138 + 524) * 4] for y in range(552, 552 + 175))
assert len(out) == 524 * 175 * 4
open(sys.argv[2], "wb").write(out)
PY
zstd -q -19 -f "$tmp/logo.bgrx" -o "$HERE/idle-rotate/logo-524x175.bgrx.zst"

echo "render-logo: accent=$ACCENT logo ${lw}x${lh} at +$lx+$ly, bar ${BAR_W}x${BAR_H} at +$bx+$by"
ls -l "$THEME"/*.png "$IDLE"/*.zst "$HERE"/idle-rotate/*.zst "$ASSETS"/preview-*.png | awk '{print $5, $NF}'

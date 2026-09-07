#!/usr/bin/env bash
# render-icon.sh / CueSync AR
#
# Regenerates every app-icon PNG from the vector master
# (Design/cuesync-icon.svg) so the icon is reviewable as an SVG diff rather
# than as opaque binaries. Also rebuilds Design/preview.png, the contact
# sheet used to judge legibility at 40 px.
#
# Requires:
#   rsvg-convert   (brew install librsvg)
#   python3 + Pillow, for the preview sheet only (pip install Pillow).
#     If Pillow is missing the icon PNGs are still written and the preview
#     step is skipped with a warning.
#
# Xcode 26 / iOS 26 takes a single 1024x1024 image per appearance and
# derives every other slot itself, so three PNGs are all the asset catalog
# needs: default (opaque), dark, tinted (grayscale, transparent).
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER=Design/cuesync-icon.svg
OUT=App/Resources/Assets.xcassets/AppIcon.appiconset
SIZE=1024

command -v rsvg-convert >/dev/null || {
  echo "render-icon.sh: rsvg-convert not found (brew install librsvg)" >&2
  exit 1
}

render() { # render <output.png> [stylesheet.css]
  local out="$1" css="${2:-}"
  if [[ -n "$css" ]]; then
    rsvg-convert --stylesheet "$css" -w "$SIZE" -h "$SIZE" "$MASTER" -o "$out"
  else
    rsvg-convert -w "$SIZE" -h "$SIZE" "$MASTER" -o "$out"
  fi
  echo "wrote $out ($(wc -c <"$out" | tr -d ' ') bytes)"
}

render "$OUT/AppIcon.png"
render "$OUT/AppIcon-dark.png"   Design/appearances/dark.css
render "$OUT/AppIcon-tinted.png" Design/appearances/tinted.css

# The App Store / default icon must be opaque. rsvg-convert writes an RGB
# PNG when nothing is transparent, so this is a check, not a conversion.
if sips -g hasAlpha "$OUT/AppIcon.png" | grep -q "hasAlpha: yes"; then
  echo "render-icon.sh: AppIcon.png has an alpha channel; the default icon must be opaque" >&2
  exit 1
fi

if python3 -c "import PIL" 2>/dev/null; then
  python3 Scripts/render-icon-preview.py "$OUT" Design/preview.png
else
  echo "render-icon.sh: Pillow not available to python3; skipped Design/preview.png" >&2
fi

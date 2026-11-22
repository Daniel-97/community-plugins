#!/usr/bin/env bash
# Generates the image fixtures used by the notification battery.
# Fixtures are local artifacts: they are not committed (see README).
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
out="$here/fixtures"
mkdir -p "$out"

if command -v magick >/dev/null 2>&1; then
  mg=magick
elif command -v convert >/dev/null 2>&1; then
  mg=convert
else
  echo "error: ImageMagick (magick/convert) is required to build fixtures" >&2
  exit 2
fi

# Avatar-like PNG: orange background, white head and shoulders.
"$mg" -size 96x96 xc:'#E8710A' \
  -fill white -draw 'circle 48,34 48,20' \
  -fill white -draw 'ellipse 48,88 34,28 0,360' \
  "$out/avatar.png"

# Photo-like JPEG: blue vertical gradient.
"$mg" -size 160x96 gradient:'#1565C0-#90CAF9' \
  -quality 85 "$out/photo.jpg"

echo "fixtures written to $out"

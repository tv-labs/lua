#!/usr/bin/env bash
# Rasterize the Open Graph image (priv/static/images/og.svg) to PNG.
# Social platforms inconsistently support SVG OG images, so the served
# meta tags point at the PNG; the SVG remains the editable source.
#
# Requires: rsvg-convert (`brew install librsvg`).

set -euo pipefail

cd "$(dirname "$0")/.."

SRC="priv/static/images/og.svg"
DST="priv/static/images/og.png"

if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "error: rsvg-convert not found. Install with: brew install librsvg" >&2
  exit 1
fi

rsvg-convert "$SRC" -w 1200 -h 630 -o "$DST"
echo "wrote $DST ($(wc -c < "$DST") bytes)"

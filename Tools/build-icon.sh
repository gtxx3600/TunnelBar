#!/bin/bash
# 从 1024px 原图生成 macOS 的标准与 Retina 图标尺寸。
set -euo pipefail

SOURCE_ICON="${1:?请提供图标 PNG 路径}"
OUTPUT_ICON="${2:?请提供输出 ICNS 路径}"
ICON_TEMP=$(mktemp -d "${TMPDIR:-/tmp/}tunnelbar-icon.XXXXXX")
trap 'rm -rf "$ICON_TEMP"' EXIT
ICONSET="$ICON_TEMP/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUTPUT_ICON")"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" "$SOURCE_ICON" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$ICONSET" --output "$OUTPUT_ICON"

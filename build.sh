#!/bin/bash
# 编译 TunnelBar 并组装 .app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TunnelBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/3] swiftc 编译中…"
swiftc -O -swift-version 5 -parse-as-library \
  -o "$APP/Contents/MacOS/tunnel-bar" \
  Sources/*.swift

echo "[2/3] 生成应用图标…"
bash Tools/build-icon.sh Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.icns"

echo "[3/3] 组装 bundle…"
cp Resources/Info.plist "$APP/Contents/"
touch "$APP"

echo "完成: $(pwd)/$APP"
echo "运行: open $(pwd)/$APP"

#!/bin/bash
# 编译 TunnelBar 并组装 .app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TunnelBar.app"
mkdir -p "$APP/Contents/MacOS"

echo "[1/2] swiftc 编译中…"
swiftc -O -swift-version 5 -parse-as-library \
  -o "$APP/Contents/MacOS/tunnel-bar" \
  Sources/main.swift

echo "[2/2] 组装 bundle…"
cp Resources/Info.plist "$APP/Contents/"

echo "完成: $(pwd)/$APP"
echo "运行: open $(pwd)/$APP"

#!/bin/bash
# 编译 TunnelBar 并组装 .app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/TunnelBar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "[1/4] swiftc 编译中…"
swiftc -O -swift-version 5 -parse-as-library \
  -o "$APP/Contents/MacOS/tunnel-bar" \
  Sources/*.swift

echo "[2/4] 生成应用图标…"
bash Tools/build-icon.sh Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.icns"

echo "[3/4] 组装 bundle…"
cp Resources/Info.plist "$APP/Contents/"

# SMAppService 要求完整应用具有有效签名；本机构建默认使用 ad-hoc 签名。
echo "[4/4] 签名并验证应用…"
codesign --force --sign "${TUNNELBAR_SIGN_IDENTITY:--}" --identifier org.tunnelbar.app "$APP"
codesign --verify --strict "$APP"
touch "$APP"

echo "完成: $(pwd)/$APP"
echo "运行: open $(pwd)/$APP"

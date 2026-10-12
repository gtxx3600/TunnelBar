#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARTWORK_DIR=$(mktemp -d "${TMPDIR:-/tmp/}tunnelbar-readme.XXXXXX")
trap 'rm -rf "$ARTWORK_DIR"' EXIT

# 所有界面由独立演示数据生成，不读取用户配置或启动 SSH。
./preview.sh
./config-preview.sh
mkdir -p docs/images
swiftc Tools/ReadmeArtwork.swift -o "$ARTWORK_DIR/readme-artwork"
"$ARTWORK_DIR/readme-artwork" docs/images
cp build/panel-preview/light-groups.png docs/images/panel-light.png
cp build/panel-preview/dark-readme.png docs/images/panel-dark.png
cp build/config-preview/light-grouped-tunnel.png docs/images/configuration.png
cp build/config-preview/light-templates.png docs/images/templates.png
cp build/config-preview/light-ssh-import.png docs/images/ssh-import.png

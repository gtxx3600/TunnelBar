#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

PREVIEW_DIR=$(mktemp -d "${TMPDIR:-/tmp/}tunnelbar-preview.XXXXXX")
trap 'rm -rf "$PREVIEW_DIR"' EXIT

swiftc -swift-version 5 -parse-as-library \
  Sources/TunnelModels.swift Sources/ConfigStore.swift Sources/TunnelManager.swift \
  Sources/TunnelPanelView.swift Tools/PanelPreview.swift -o "$PREVIEW_DIR/panel-preview"
"$PREVIEW_DIR/panel-preview" "${1:-build/panel-preview}"

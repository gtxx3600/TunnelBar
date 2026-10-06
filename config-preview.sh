#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

CONFIG_PREVIEW_DIR=$(mktemp -d "${TMPDIR:-/tmp/}tunnelbar-config-preview.XXXXXX")
trap 'rm -rf "$CONFIG_PREVIEW_DIR"' EXIT

swiftc -swift-version 5 -parse-as-library \
  Sources/TunnelModels.swift Sources/ConfigDraft.swift Sources/SSHConfigImport.swift \
  Sources/SSHConfigImportView.swift Sources/ConfigEditorView.swift \
  Tools/ConfigPreview.swift -o "$CONFIG_PREVIEW_DIR/config-preview"
"$CONFIG_PREVIEW_DIR/config-preview" "${1:-build/config-preview}"

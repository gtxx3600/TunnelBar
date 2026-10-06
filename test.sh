#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp/}tunnelbar-tests.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT

clang Tests/mock-ssh.c -o "$TEST_DIR/mock-ssh"
swiftc -swift-version 5 -parse-as-library \
  Sources/TunnelModels.swift Sources/PrivateStorage.swift Sources/ConfigStore.swift \
  Sources/TunnelManager.swift Sources/SSHConfigImport.swift \
  Tests/RegressionTests.swift -o "$TEST_DIR/regression-tests"
"$TEST_DIR/regression-tests" "$TEST_DIR" "$TEST_DIR/mock-ssh"

# 配置编辑器草稿规则使用纯数据测试，不读在线配置。
swiftc -swift-version 5 -parse-as-library \
  Sources/TunnelModels.swift Sources/ConfigDraft.swift Tests/ConfigDraftTests.swift \
  -o "$TEST_DIR/config-draft-tests"
"$TEST_DIR/config-draft-tests"

# SSH 配置导入仅读取独立临时文件，不运行 SSH、不读取真实 ~/.ssh。
swiftc -swift-version 5 -parse-as-library \
  Sources/TunnelModels.swift Sources/ConfigDraft.swift Sources/SSHConfigImport.swift \
  Tests/SSHConfigImportTests.swift -o "$TEST_DIR/ssh-config-import-tests"
"$TEST_DIR/ssh-config-import-tests"

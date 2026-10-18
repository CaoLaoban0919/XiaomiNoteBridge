#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$ROOT/build"
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(rg --files "$ROOT/Sources" -g '*.swift' -g '!App.swift' | sort)
xcrun swiftc -swift-version 5 -parse-as-library -disable-sandbox -framework Carbon \
  "${SOURCES[@]}" "$ROOT/Tools/ImportApprovalUITests.swift" -o "$ROOT/build/import-approval-ui-tests"
"$ROOT/build/import-approval-ui-tests"

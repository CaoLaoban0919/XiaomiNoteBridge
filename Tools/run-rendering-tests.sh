#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export MINOTE_TEST_OUTPUT="$ROOT/outputs"
mkdir -p "$ROOT/build" "$ROOT/outputs"
xcrun swiftc -swift-version 5 -parse-as-library -D MATH_MARKUP_AVAILABLE \
  "$ROOT/Sources/AI/MathMarkup.swift" "$ROOT/Sources/AI/CartesianChart.swift" "$ROOT/Sources/AI/StatisticalChart.swift" "$ROOT/Sources/AI/SurfaceChart.swift" "$ROOT/Sources/AI/AITextToHTML.swift" \
  "$ROOT/Tools/MathMarkupTests.swift" -o "$ROOT/build/math-markup-tests"
"$ROOT/build/math-markup-tests"
xcrun swiftc -swift-version 5 -disable-sandbox -D APP_VIEWS -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/AI/MathMarkup.swift" \
  "$ROOT/Sources/AI/CartesianChart.swift" "$ROOT/Sources/AI/StatisticalChart.swift" "$ROOT/Sources/AI/SurfaceChart.swift" "$ROOT/Sources/AI/AITextToHTML.swift" "$ROOT/Sources/AI/MathWebDocument.swift" \
  "$ROOT/Sources/AI/MathImageRenderer.swift" "$ROOT/Sources/AI/NoteExportHTML.swift" \
  "$ROOT/Sources/AI/ChatRichContentView.swift" "$ROOT/Sources/Editor/WebNoteEditor.swift" \
  "$ROOT/Sources/EnexWriter.swift" "$ROOT/Sources/XiaomiConvert.swift" \
  "$ROOT/Sources/CredentialsStore.swift" "$ROOT/Sources/SyncState.swift" \
  "$ROOT/Sources/ScriptProcess.swift" "$ROOT/Sources/NotesBridge.swift" "$ROOT/Sources/NotesImporter.swift" \
  "$ROOT/Sources/Store/StoreContract.swift" "$ROOT/Sources/Store/NoteCache.swift" "$ROOT/Sources/Store/ImportEngine.swift" \
  "$ROOT/Tools/ImportPipelineTests.swift" -framework Carbon \
  "$ROOT/Tools/MathWebRuntimeTests.swift" -o "$ROOT/build/math-web-tests"
# 从实际 app Bundle 加载资源，避免环境变量掩盖资源未打包或路径错误。
TEST_BUNDLE_ROOT="$(mktemp -d "$ROOT/build/math-bundle-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUNDLE_ROOT"' EXIT
TEST_APP="$TEST_BUNDLE_ROOT/MathWebTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cp "$ROOT/build/math-web-tests" "$TEST_APP/Contents/MacOS/MathWebTests"
cp -R "$ROOT/Resources/katex" "$TEST_APP/Contents/Resources/"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MathWebTests</string>
<key>CFBundleIdentifier</key><string>local.minotebridge.math-tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
env -u MINOTE_RESOURCE_PATH "$TEST_APP/Contents/MacOS/MathWebTests"

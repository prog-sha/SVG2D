#!/bin/sh
# 配布アドオンを隔離した実エディタで開き、symbolの点操作と画面を確認する。
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/Applications/Godot 4.7.2.app/Contents/MacOS/Godot} # 検証する実エディタ
project=$(mktemp -d "$root/tmp/oss-editor.XXXXXX") # 本体のエディタ設定を変えない作業場所
cp "$root/tests/editor_project.godot" "$project/project.godot"
cp -R "$root/addons" "$project/addons"
mkdir -p "$project/tests/svg/integration" "$root/tmp/oss-editor-captures"
cp "$root/tests/oss_editor_integration.gd" "$project/tests/editor_inspector_test.gd"
cp "$root/tests/editor_test_plugin.cfg" "$project/tests/"
cp "$root/tests/svg/integration/symbol.svg" "$project/tests/svg/integration/"
SVG2D_VISUAL_OUTPUT="$root/tmp/oss-editor-captures" "$godot" --editor --path "$project" \
  --resolution 1000x700 --position 10000,10000 --quit-after 600 > "$root/tmp/oss_editor.log" 2>&1
cat "$root/tmp/oss_editor.log"
grep -q 'OSS editor integration: .* PASSED' "$root/tmp/oss_editor.log"
if grep -q '^ERROR:\|^SCRIPT ERROR:' "$root/tmp/oss_editor.log"; then exit 1; fi

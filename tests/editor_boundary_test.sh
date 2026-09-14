#!/bin/sh
# 編集拡張が実行時コードから参照されない構造を確かめる。
# 責務: ゲーム側のGDExtensionと編集UIの依存方向を短時間で判断すること。
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if rg -n 'addons/svg2d/editor|EditorPlugin|EditorInterface' src addons/svg2d/svg2d.gdextension; then
  echo "実行時コードから編集拡張を参照しているよ"
  exit 1
fi
rg -q 'EDITOR_PREFIX' addons/svg2d/editor/export_filter.gd
echo "SVG editor boundary test passed"

#!/bin/sh
# SVG2D を現在の環境向けに組み立て、公開 API を画面なしで確かめる。
# 責務: 開発中の確認を一つの入口へまとめ、失敗をそのまま返すこと。
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
case $(uname -s) in
  Darwin) host=macos ;; # Apple の開発機
  Linux) host=linux ;;  # Linux の開発機
  *) host=${1:-} ;;      # ほかの環境では引数を使う
esac
platform=${1:-$host} # 手元の環境に合わせる組み立て先
scalar=${SVG2D_SCALAR:-no} # yesならベクトル命令を使わない経路を確かめる
if [ -n "${GODOT:-}" ]; then
  godot=$GODOT
elif [ "$platform" = macos ]; then
  godot=/Applications/Godot\ 4.7.1.app/Contents/MacOS/Godot
else
  godot=$(command -v godot || command -v godot4 || true)
fi
[ -x "$godot" ] || { echo "Godot 4.7 が見つからないよ。GODOT で場所を渡してね"; exit 2; }

cd "$root"
"$godot" --headless --path "$root" --script tests/editor_document_test.gd
"$godot" --resolution 800x500 --path "$root" --script tests/editor_ui_test.gd
"$godot" --resolution 1400x800 --path "$root" --script tests/editor_ui_test.gd
sh tests/editor_boundary_test.sh
scons platform="$platform" target=template_debug svg2d_scalar="$scalar"
result=$("$godot" --resolution 64x48 --quit-after 180 --path "$root" --script tests/test.gd 2>&1)
printf '%s\n' "$result"
printf '%s\n' "$result" | grep -q "SVG2D / SVG3Dの試験に通ったよ"
printf '%s\n' "$result" | grep -q "SVG2D profile max RMSE"
printf '%s\n' "$result" | grep -q "SVG3D profile max RMSE"
if printf '%s\n' "$result" | grep -q '^ERROR:'; then
  echo "Godotがエラーを出したよ"
  exit 1
fi

# 配布用addonsを空のプロジェクトへ入れ、プラグイン有効状態の実エディターで確かめる。
editor_root=$(mktemp -d)
trap 'rm -rf "$editor_root"' EXIT HUP INT TERM
cp tests/editor_project.godot "$editor_root/project.godot"
cp -R addons "$editor_root/addons"
mkdir "$editor_root/tests"
cp tests/editor_inspector_test.gd "$editor_root/tests/editor_inspector_test.gd"
cp tests/editor_test_plugin.cfg "$editor_root/tests/editor_test_plugin.cfg"
cp -R tests/svg "$editor_root/tests/svg"
editor_result=$("$godot" --headless --editor --path "$editor_root" --quit-after 600 2>&1)
printf '%s\n' "$editor_result"
printf '%s\n' "$editor_result" | grep -q "SVG Inspectorの試験に通ったよ"
if printf '%s\n' "$editor_result" | grep -q '^ERROR:'; then
  echo "Godotエディターがエラーを出したよ"
  exit 1
fi

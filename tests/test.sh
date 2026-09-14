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
"$godot" --resolution 1400x800 --path "$root" --script tests/editor_ui_test.gd
sh tests/editor_boundary_test.sh
scons platform="$platform" target=template_debug svg2d_scalar="$scalar"
result=$("$godot" --resolution 64x48 --quit-after 180 --path "$root" --script tests/test.gd 2>&1)
printf '%s\n' "$result"
printf '%s\n' "$result" | grep -q "SVG2D / SVG3Dの試験に通ったよ"
printf '%s\n' "$result" | grep -q "SVG2D profile max RMSE"
printf '%s\n' "$result" | grep -q "SVG3D profile max RMSE"

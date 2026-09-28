#!/bin/sh
# 多段変換の素材と棒人間を実エディタで撮影し、SVGの描画変化を確認する。
# 責務: 独立したプロジェクトで表示と画素を保存し、欠落や同一フレームを検出する。
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/Applications/Godot 4.7.2.app/Contents/MacOS/Godot}
[ -x "$godot" ] || { echo "Godot executable not found"; exit 2; }
output=${SVG2D_VISUAL_OUTPUT:-"$root/tmp/editor-visual-output"}
mkdir -p "$root/tmp" "$output"
project=$(mktemp -d "$root/tmp/editor-visual.XXXXXX")
trap 'rm -rf "$project"' EXIT HUP INT TERM
cp "$root/tests/editor_visual_project.godot" "$project/project.godot"
cp -R "$root/addons" "$project/addons"
mkdir -p "$project/examples"
cp -R "$root/examples/stickman" "$project/examples/stickman"
mkdir -p "$project/tests"
cp "$root/tests/editor_visual_capture.gd" "$root/tests/editor_visual_capture_plugin.cfg" \
	"$root/tests/editor_transform_fixture.gd" "$project/tests/"
log="$project/capture.log"
if SVG2D_VISUAL_OUTPUT="$output" \
	"$godot" --editor --path "$project" --resolution 1400x900 \
	--position 10000,10000 --quit-after 3600 >"$log" 2>&1; then
	:
else
	cat "$log"
	exit 1
fi
cp "$log" "$root/tmp/editor-visual.log"
if grep -q '^ERROR:\|^SCRIPT ERROR:' "$log"; then
	cat "$log"
	exit 1
fi
if ! grep -q 'SVG editor visual capture complete' "$log"; then
	cat "$log"
	exit 1
fi
grep -q 'Nested stickman 2D/3D: two handle points, fill/stroke, camera move and flips passed' "$log"
test -s "$output/fixture-source.png"
for workspace in 2d 3d; do
	for frame in 0 1; do test -s "$output/transform-$workspace-$frame.png"; done
	for frame in 0 1; do test -s "$output/fixture-render-$workspace-$frame.png"; done
	test -s "$output/transform-$workspace-both-flips.png"
	for frame in 0 1; do
		grep -Fq "Captured $output/transform-$workspace-$frame.png" "$log"
	done
	grep -Fq "Captured $output/transform-$workspace-both-flips.png" "$log"
	first=$(shasum -a 256 "$output/transform-$workspace-0.png" | awk '{print $1}')
	second=$(shasum -a 256 "$output/transform-$workspace-1.png" | awk '{print $1}')
	[ "$first" != "$second" ] || { echo "$workspace frames did not change"; exit 1; }
	first=$(shasum -a 256 "$output/fixture-render-$workspace-0.png" | awk '{print $1}')
	second=$(shasum -a 256 "$output/fixture-render-$workspace-1.png" | awk '{print $1}')
	[ "$first" != "$second" ] || { echo "$workspace rendered SVG did not change"; exit 1; }
	for frame in 0 1; do
		test -s "$output/editor-$workspace-$frame.png"
		test -s "$output/stickman-render-$workspace-$frame.png"
	done
	first=$(shasum -a 256 "$output/stickman-render-$workspace-0.png" | awk '{print $1}')
	second=$(shasum -a 256 "$output/stickman-render-$workspace-1.png" | awk '{print $1}')
	[ "$first" != "$second" ] || { echo "$workspace stickman did not animate"; exit 1; }
done
cat "$log"

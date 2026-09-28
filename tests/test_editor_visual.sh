#!/bin/sh
# Capture the same multilevel-transform fixture as the editor input tests.
# Requires a real renderer, but no mouse automation or computer-use service.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/Applications/Godot 4.7.1.app/Contents/MacOS/Godot}
[ -x "$godot" ] || { echo "Godot executable not found"; exit 2; }
output=${SVG2D_VISUAL_OUTPUT:-"$root/tmp/editor-visual-output"}
mkdir -p "$root/tmp" "$output"
project=$(mktemp -d "$root/tmp/editor-visual.XXXXXX")
trap 'rm -rf "$project"' EXIT HUP INT TERM
cp "$root/tests/editor_visual_project.godot" "$project/project.godot"
cp -R "$root/addons" "$project/addons"
mkdir -p "$project/tests"
cp "$root/tests/editor_visual_capture.gd" "$root/tests/editor_visual_capture_plugin.cfg" \
	"$root/tests/editor_transform_fixture.gd" "$project/tests/"
log="$project/capture.log"
SVG2D_VISUAL_TRANSFORM_ONLY=1 SVG2D_VISUAL_OUTPUT="$output" \
	"$godot" --editor --path "$project" --resolution 1400x900 \
	--position 10000,10000 --quit-after 900 >"$log" 2>&1
if grep -q '^ERROR:\|^SCRIPT ERROR:' "$log"; then
	cat "$log"
	exit 1
fi
grep -q 'SVG editor visual capture complete' "$log"
for workspace in 2d 3d; do
	for frame in 0 1; do test -s "$output/transform-$workspace-$frame.png"; done
	test -s "$output/transform-$workspace-both-flips.png"
	for frame in 0 1; do
		grep -Fq "Captured $output/transform-$workspace-$frame.png" "$log"
	done
	grep -Fq "Captured $output/transform-$workspace-both-flips.png" "$log"
	first=$(shasum -a 256 "$output/transform-$workspace-0.png" | awk '{print $1}')
	second=$(shasum -a 256 "$output/transform-$workspace-1.png" | awk '{print $1}')
	[ "$first" != "$second" ] || { echo "$workspace frames did not change"; exit 1; }
done
cat "$log"

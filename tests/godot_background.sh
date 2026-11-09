#!/bin/sh
# 実描画が必要な試験をバックグラウンド起動し、作業中のアプリを前面に保つ。
set -eu
log=$1
shift
godot=${GODOT:-/Applications/Godot 4.7.2.app/Contents/MacOS/Godot}
mkdir -p "$(dirname "$log")"
log=$(cd "$(dirname "$log")" && pwd)/$(basename "$log")
status=0
if [ "$(uname -s)" = Darwin ]; then
	app=${godot%/Contents/MacOS/*}
	[ "$app" != "$godot" ] || { echo "Background tests require a Godot .app on macOS"; exit 2; }
	work=$(mktemp -d "$(dirname "$log")/godot-launch.XXXXXX")
	trap 'rm -rf "$work"' EXIT HUP INT TERM
	# LaunchServicesから隠して起動し、既存Godotとは別プロセスで終了を待つ。
	/usr/bin/open -g -j -n -W -a "$app" --stdout "$work/out" --stderr "$work/err" \
		--env "SVG2D_VISUAL_OUTPUT=${SVG2D_VISUAL_OUTPUT:-}" \
		--args --windowed --single-window --position 10000,10000 --resolution 1000x600 "$@" || status=$?
	cat "$work/out" "$work/err" >"$log"
else
	"$godot" --windowed --single-window --position 10000,10000 --resolution 1000x600 "$@" >"$log" 2>&1 || status=$?
fi
cat "$log"
exit "$status"

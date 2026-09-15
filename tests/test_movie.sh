#!/bin/sh
# AnimationPlayerでSVG接点を動かし、Godot MovieWriterの実出力を検証する。
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
godot=${GODOT:-/Applications/Godot 4.7.1.app/Contents/MacOS/Godot}
[ -x "$godot" ] || { echo "Godot 4.7 が見つからないよ。GODOT で場所を渡してね"; exit 2; }
command -v ffmpeg >/dev/null || { echo "動画フレーム確認にはffmpegが必要だよ"; exit 2; }
command -v ffprobe >/dev/null || { echo "動画情報の確認にはffprobeが必要だよ"; exit 2; }

movie_root=$(mktemp -d)
trap 'rm -rf "$movie_root"' EXIT HUP INT TERM
# Godot 4.7.1のmacOS版はheadless MovieWriterでDummy textureを参照して落ちるため、
# 実レンダラーを画面外のウィンドウで使う。これはUI操作を必要としない。
render_movie() {
	label=$1
	scene=$2
	copy_to=$3
	movie="$movie_root/$label.avi"
	log="$movie_root/$label.log"
	if [ "$(uname -s)" = Darwin ]; then
		"$godot" --path "$root" --position 10000,10000 \
			--resolution 640x360 --fixed-fps 30 --disable-vsync \
			--write-movie "$movie" --quit-after 60 "$scene" >"$log" 2>&1
	else
		"$godot" --path "$root" \
			--resolution 640x360 --fixed-fps 30 --disable-vsync \
			--write-movie "$movie" --quit-after 60 "$scene" >"$log" 2>&1
	fi
	cat "$log"
	test -s "$movie"
	grep -q "Done recording movie at path" "$log"
	if grep -q '^ERROR:' "$log"; then
		echo "$label MovieWriter実行中にGodotがエラーを出したよ"
		exit 1
	fi
	frames=$(ffprobe -v error -count_frames -select_streams v:0 \
		-show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$movie")
	[ "$frames" -ge 59 ] && [ "$frames" -le 61 ] || {
		echo "$label MovieWriterのフレーム数が不正だよ: $frames"
		exit 1
	}
	frame_dir="$movie_root/$label-frames"
	mkdir "$frame_dir"
	ffmpeg -v error -i "$movie" -vf "select='eq(n,0)+eq(n,15)+eq(n,30)+eq(n,45)'" \
		-vsync 0 "$frame_dir/frame-%02d.png"
	hashes=$(shasum -a 256 "$frame_dir"/frame-*.png | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
	[ "$hashes" -eq 4 ] || {
		echo "$label 棒人間の4時点が変化していないよ: $hashes unique frames"
		exit 1
	}
	if [ -n "$copy_to" ]; then cp "$movie" "$copy_to"; fi
	echo "$label SVG stickman movie passed: $frames frames, $hashes unique checkpoints"
}

render_movie stickman2d res://examples/stickman/stickman_movie.tscn "${SVG2D_MOVIE_COPY:-}"
render_movie stickman3d res://examples/stickman/stickman_movie_3d.tscn "${SVG3D_MOVIE_COPY:-}"

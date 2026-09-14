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
movie="$movie_root/stickman.avi"
log="$movie_root/godot.log"

# Godot 4.7.1のmacOS版はheadless MovieWriterでDummy textureを参照して落ちるため、
# 実レンダラーを画面外のウィンドウで使う。これはUI操作を必要としない。
if [ "$(uname -s)" = Darwin ]; then
	"$godot" --path "$root" --position 10000,10000 \
		--resolution 640x360 --fixed-fps 30 --disable-vsync \
		--write-movie "$movie" --quit-after 60 \
		res://examples/stickman/stickman_movie.tscn >"$log" 2>&1
else
	"$godot" --path "$root" \
		--resolution 640x360 --fixed-fps 30 --disable-vsync \
		--write-movie "$movie" --quit-after 60 \
		res://examples/stickman/stickman_movie.tscn >"$log" 2>&1
fi
cat "$log"
test -s "$movie"
grep -q "Stickman MovieWriter demo" "$log"
if grep -q '^ERROR:' "$log"; then
	echo "MovieWriter実行中にGodotがエラーを出したよ"
	exit 1
fi

frames=$(ffprobe -v error -count_frames -select_streams v:0 \
	-show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$movie")
[ "$frames" -ge 59 ] && [ "$frames" -le 61 ] || {
	echo "MovieWriterのフレーム数が不正だよ: $frames"
	exit 1
}

ffmpeg -v error -i "$movie" -vf "select='eq(n,0)+eq(n,15)+eq(n,30)+eq(n,45)'" \
	-vsync 0 "$movie_root/frame-%02d.png"
hashes=$(shasum -a 256 "$movie_root"/frame-*.png | awk '{print $1}' | sort -u | wc -l | tr -d ' ')
[ "$hashes" -eq 4 ] || {
	echo "棒人間の4時点が変化していないよ: $hashes unique frames"
	exit 1
}

if [ -n "${SVG2D_MOVIE_COPY:-}" ]; then
	cp "$movie" "$SVG2D_MOVIE_COPY"
fi
echo "SVG stickman movie passed: $frames frames, $hashes unique checkpoints"

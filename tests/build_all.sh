#!/bin/bash
# 全配布先を必要なときだけ組み立てる入口。
# 責務: 入力と成果物の内容を対象別に記録し、変化のないSCons起動を省く。
# 設計思想: debugだけが使う文書も分離し、差分の影響範囲を最小化する。
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
records="$root/addons/svg2d/bin/build_fingerprints.txt" # 追跡する対象別の入力・出力指紋
scratch="$root/tmp/build-fingerprints" # 安全に記録を書き換える作業場所
generation_record="$scratch/godot-cpp-generation.txt" # 共有生成物の構成と実内容
mode=${1:-}
mkdir -p "$scratch"

# ファイル内容を使い、時刻や作業場所に左右されない指紋を作る。
digest() { shasum -a 256 | awk '{print $1}'; }
file_digest() { shasum -a 256 "$1" | awk '{print $1}'; }

# godot-cppの生成ヘッダーは全対象で共有されるため、外部ビルドによる汚染も検出する。
generated_digest() {
	find "$root/godot-cpp/gen" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.inc' -o -name '*.cpp' \) \
		-print 2>/dev/null | LC_ALL=C sort | while IFS= read -r file; do
		printf '%s %s\n' "${file#$root/}" "$(file_digest "$file")"
	done | digest
}

# 共通入力は起動ごとに1回だけ読む。説明XMLはdebug対象だけへ影響させる。
common_digest=$({
	find "$root/src" -type f ! -path "$root/src/gen/*" -print | LC_ALL=C sort | while IFS= read -r file; do
		printf '%s %s\n' "${file#$root/}" "$(file_digest "$file")"
	done
	for file in "$root/SConstruct" "$root/build_profile.json" "$root/tests/build_all.sh"; do
		printf '%s %s\n' "${file#$root/}" "$(file_digest "$file")"
	done
	git -C "$root/godot-cpp" rev-parse HEAD
	git -C "$root/godot-cpp" diff --binary -- .
} | digest)
debug_docs_digest=$(find "$root/doc_classes" -type f -name '*.xml' -print | LC_ALL=C sort | while IFS= read -r file; do
	printf '%s %s\n' "${file#$root/}" "$(file_digest "$file")"
done | digest)

input_digest() {
	local id=$1 target=$2 command_key=$3
	if [ "$target" = template_debug ]; then
		printf '%s\n%s\n%s\n%s\n' "$id" "$command_key" "$common_digest" "$debug_docs_digest" | digest
	else
		printf '%s\n%s\n%s\n' "$id" "$command_key" "$common_digest" | digest
	fi
}

# 1対象の記録だけを置換し、途中失敗で既存記録を壊さない。
record() {
	local id=$1 input=$2 output=$3 temp="$scratch/records.$$"
	if [ -f "$records" ]; then awk -v id="$id" '$1 != id' "$records" > "$temp"; else : > "$temp"; fi
	printf '%s %s %s\n' "$id" "$input" "$output" >> "$temp"
	LC_ALL=C sort "$temp" > "$records"
	rm -f "$temp"
}

# ローカルのApple・Windows・Android・Webと、Linux用コンテナを同じ表から実行する。
run_build() {
	local platform=$1 target=$2 arch=$3 runner=$4 action=${5:-}
	case "$runner" in
		local) (cd "$root" && scons $action platform="$platform" target="$target" arch="$arch") ;;
		android) (cd "$root" && ANDROID_HOME= scons $action platform=android target="$target" arch=arm64) ;;
		web) (cd "$root" && scons $action platform=web target="$target" arch=wasm32 threads=no) ;;
		linux-arm64) podman run --rm -v "$root:/src" -w /src localhost/gd-linux-builder:latest \
			bash -lc "scons $action platform=linux target=$target arch=arm64" ;;
		linux-x86_64) podman run --rm --platform linux/amd64 -v "$root:/src" -w /src \
			localhost/gd-linux-builder-x64:latest bash -lc "scons -j2 $action platform=linux target=$target arch=x86_64" ;;
	 esac
}

# 構成が違う生成物を静的ライブラリーへ混ぜない。通常は記録照合だけで終了する。
prepare_generation() {
	local platform=$1 target=$2 arch=$3 runner=$4
	local desired actual known
	desired=$(printf 'api=4.7 arch_bits=64 precision=single profile=%s godot_cpp=%s\n' \
		"$(file_digest "$root/build_profile.json")" "$(git -C "$root/godot-cpp" rev-parse HEAD)" | digest)
	actual=$(generated_digest)
	known=$(awk 'NR == 1 { print $1 " " $2 }' "$generation_record" 2>/dev/null || true)
	if [ "$known" != "$desired $actual" ]; then
		printf 'CLEAN shared godot-cpp bindings before %s/%s/%s\n' "$platform" "$target" "$arch"
		run_build "$platform" "$target" "$arch" "$runner" -c
	fi
	printf '%s %s\n' "$desired" "$(generated_digest)" > "$generation_record"
}

built=0
skipped=0
targets=(
	"macos-debug|macos|template_debug|universal|local|addons/svg2d/bin/macos/libsvg2d.macos.template_debug.dylib"
	"macos-release|macos|template_release|universal|local|addons/svg2d/bin/macos/libsvg2d.macos.template_release.dylib"
	"windows-debug|windows|template_debug|x86_64|local|addons/svg2d/bin/windows/svg2d.windows.template_debug.x86_64.dll"
	"windows-release|windows|template_release|x86_64|local|addons/svg2d/bin/windows/svg2d.windows.template_release.x86_64.dll"
	"linux-x86_64-debug|linux|template_debug|x86_64|linux-x86_64|addons/svg2d/bin/linux/libsvg2d.linux.template_debug.x86_64.so"
	"linux-x86_64-release|linux|template_release|x86_64|linux-x86_64|addons/svg2d/bin/linux/libsvg2d.linux.template_release.x86_64.so"
	"linux-arm64-debug|linux|template_debug|arm64|linux-arm64|addons/svg2d/bin/linux/libsvg2d.linux.template_debug.arm64.so"
	"linux-arm64-release|linux|template_release|arm64|linux-arm64|addons/svg2d/bin/linux/libsvg2d.linux.template_release.arm64.so"
	"android-debug|android|template_debug|arm64|android|addons/svg2d/bin/android/libsvg2d.android.template_debug.arm64.so"
	"android-release|android|template_release|arm64|android|addons/svg2d/bin/android/libsvg2d.android.template_release.arm64.so"
	"ios-debug|ios|template_debug|arm64|local|addons/svg2d/bin/ios/libsvg2d.ios.template_debug.arm64.dylib"
	"ios-release|ios|template_release|arm64|local|addons/svg2d/bin/ios/libsvg2d.ios.template_release.arm64.dylib"
	"web-debug|web|template_debug|wasm32|web|addons/svg2d/bin/web/libsvg2d.web.template_debug.wasm32.nothreads.wasm"
	"web-release|web|template_release|wasm32|web|addons/svg2d/bin/web/libsvg2d.web.template_release.wasm32.nothreads.wasm"
)

for spec in "${targets[@]}"; do
	IFS='|' read -r id platform target arch runner relative <<< "$spec"
	output="$root/$relative"
	key="$platform $target $arch $runner"
	input=$(input_digest "$id" "$target" "$key")
	known=$(awk -v id="$id" '$1 == id { print $2 " " $3 }' "$records" 2>/dev/null || true)
	actual=
	[ ! -f "$output" ] || actual=$(file_digest "$output")
	if [ "$mode" = --adopt ] && [ -n "$actual" ]; then
		record "$id" "$input" "$actual"
		printf 'ADOPT %s\n' "$id"
		skipped=$((skipped + 1))
	elif [ "$mode" != --force ] && [ "$known" = "$input $actual" ] && [ -n "$actual" ]; then
		printf 'SKIP  %s\n' "$id"
		skipped=$((skipped + 1))
	else
		printf 'BUILD %s\n' "$id"
		prepare_generation "$platform" "$target" "$arch" "$runner"
		run_build "$platform" "$target" "$arch" "$runner"
		[ -f "$output" ] || { echo "Missing output: $relative" >&2; exit 1; }
		case "$platform" in linux) chmod +x "$output" ;; esac
		printf '%s %s\n' "$(awk 'NR == 1 { print $1 }' "$generation_record")" "$(generated_digest)" > "$generation_record"
		record "$id" "$input" "$(file_digest "$output")"
		built=$((built + 1))
	fi
done

printf 'Build summary: %d built, %d unchanged\n' "$built" "$skipped"

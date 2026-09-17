#!/bin/sh
# ベクトル命令と通常CPU経路が同じ画素を返すか確かめる。
# 責務: 両方を同じ試験へ通し、SHA-256の完全一致を判断して通常版へ戻すこと。
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

# 終了時は配布に使う通常版へ戻す。
restore() {
  scons platform=macos target=template_debug >/dev/null
}
trap restore EXIT

fast=$(SVG2D_SCALAR=no SVG2D_SKIP_EDITOR=yes sh tests/test.sh)
plain=$(SVG2D_SCALAR=yes SVG2D_SKIP_EDITOR=yes sh tests/test.sh)
fast_hash=$(printf '%s\n' "$fast" | sed -n 's/^SVG pixel SHA256: //p')
plain_hash=$(printf '%s\n' "$plain" | sed -n 's/^SVG pixel SHA256: //p')
fast_rope=$(printf '%s\n' "$fast" | sed -n 's/^Rope simulation backend: //p')
plain_rope=$(printf '%s\n' "$plain" | sed -n 's/^Rope simulation backend: //p')
[ -n "$fast_hash" ]
[ "$fast_hash" = "$plain_hash" ]
[ "$plain_rope" = scalar ]
[ "$fast_rope" = neon ] || [ "$fast_rope" = sse2 ]
printf 'SIMD / scalar pixel SHA256: %s\n' "$fast_hash"
printf 'Rope simulation backends: %s / %s\n' "$fast_rope" "$plain_rope"

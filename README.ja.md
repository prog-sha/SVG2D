# SVG2D

[English](README.md) | **日本語**

SVG2D は、SVG を Godot の 2D・3D シーンに表示するための軽量な GDExtension アドオンだよ。2Dでは `SVG2D`、3Dでは `SVG3D` ノードを使おう。どちらも画面上の描画領域を整数画素で見て解像度を更新し、同じ画素数の間は画像を使い回すよ。

配布済みのアドオンは Godot 4.7 以降、Windows x86_64、macOS Universal に対応しているよ。導入方法、使い方、対応している SVG 機能は [`addons/svg2d/README.ja.md`](addons/svg2d/README.ja.md) を見てね。

## ソースから組み立てよう

Godot 4.7、C++17 コンパイラー、SCons を用意し、ビルド用のサブモジュールと一緒に取得しよう。

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=macos target=template_debug
scons platform=macos target=template_release
```

ほかの対応環境向けに組み立てるときは `platform` を変えよう。配布には `template_release`、開発には `template_debug` を使うよ。

## 確かめよう

macOS ではテスト用スクリプトが Godot 4.7.1 を自動で探すよ。Godot が別の場所にあるときは `GODOT` を指定しよう。

```sh
GODOT=/path/to/godot sh tests/test.sh
```

SSE2やNEONを使わない通常CPU経路を確かめるときは、`SVG2D_SCALAR=yes` を付けよう。

macOSで両方の画素がSHA-256まで一致するか確かめるときは、`sh tests/test_simd.sh` を実行しよう。

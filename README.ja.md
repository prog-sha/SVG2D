# SVG2D

[English](README.md) | **日本語**

SVG2D は、SVG を Godot の 2D・3D シーンに表示・編集するための軽量な GDExtension アドオンだよ。`SVGAnimate2D` / `SVGAnimate3D` ではトポロジーを変えずに接点とカーブを編集し、AnimationPlayerへ点番号ごとのキーを登録できるよ。画像素材のPBD紐には `SpriteRope2D` / `SpriteRope3D`、SVG素材には別クラスの `SVGRope2D` / `SVGRope3D` を使おう。紐の粒子にはGodot標準のPinJointを通して `PhysicsBody2D` / `PhysicsBody3D` を接続できるよ。

エディターではSVGの不透明な絵をクリックして2D・3Dノードをドラッグできるよ。Inspectorの **Create Hitbox** にある **Rect** はGodot標準の `StaticBody` + 矩形Collision子ノードを、**Shape** は透明な穴を除いたSVG外周から2Dポリゴンまたは薄い3D形状を自動生成するよ。

英語版を基準文書とし、配布済みのアドオンは Godot 4.7 以降、Windows x86_64、macOS Universal、Linux x86_64/arm64、Android arm64、Web wasm32（スレッドなし）に対応しているよ。導入方法、使い方、対応している SVG 機能は [`addons/svg2d/README.ja.md`](addons/svg2d/README.ja.md) を見てね。

## ソースから組み立てよう

Godot 4.7、C++17 コンパイラー、SCons を用意し、ビルド用のサブモジュールと一緒に取得しよう。

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=macos target=template_debug
scons platform=macos target=template_release
```

ほかの対応環境向けに組み立てるときは `platform` と `arch` を変えよう。AndroidにはAndroid NDK、WebにはEmscriptenが必要で、配布するWeb版は `threads=no` だよ。配布には `template_release`、開発には `template_debug` を使おう。

## 確かめよう

macOS ではテスト用スクリプトが Godot 4.7.1 を自動で探すよ。Godot が別の場所にあるときは `GODOT` を指定しよう。

```sh
GODOT=/path/to/godot sh tests/test.sh
```

SSE2やNEONを使わない通常CPU経路を確かめるときは、`SVG2D_SCALAR=yes` を付けよう。

macOSで両方の画素がSHA-256まで一致するか確かめるときは、`sh tests/test_simd.sh` を実行しよう。

配布する全GDExtensionパスに宣言どおりの形式・アーキテクチャのバイナリがあるかは、`python3 tests/test_binaries.py` で確認できるよ。

`SVGAnimate2D` と `AnimationPlayer` で棒人間の接点を動かす例は [`examples/stickman/stickman_movie.tscn`](examples/stickman/stickman_movie.tscn)、`SVGAnimate3D` でジャンプ・1回転・着地させる例は [`examples/stickman/stickman_movie_3d.tscn`](examples/stickman/stickman_movie_3d.tscn) だよ。どちらもスクリプトを使わず、ノードとキーフレームをTSCNへ保存しているよ。Godot MovieWriterで各60フレームを書き出して自動確認するにはffmpegを用意して次を実行しよう。

```sh
sh tests/test_movie.sh
```

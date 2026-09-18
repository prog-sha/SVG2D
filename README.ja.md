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

## 処理量とメモリの設定

| Inspector設定 | 対象 | 効果 |
| --- | --- | --- |
| `deferred_updates` | SVGAnimate2D / 3D | 既定ON。同じ更新周期の接点編集をまとめ、SVGの再構築・再解析を1回にする。 |
| `keep_render_cache` | SVG2D / 3Dとその派生 | OFFで画像化後の中間バッファを解放。再描画時の再計算は増える。表示テクスチャは残る。 |
| `dynamic_mesh` | SpriteRope3D / SVGRope3D | 既定ON。頂点と境界だけ更新し、UV・三角形の再生成と転送を省く。 |

接点の取得・シーン保存は常に最新の編集値を使う。遅延更新中に2Dテクスチャをすぐ取得する場合は `flush_paths()` を先に呼ぶ。3Dテクスチャの表示反映はidle時に行う。`get_render_cache_bytes()` で中間バッファの概算を確認できる。

`SVGAnimate2D` / `SVGAnimate3D` でも、Inspectorの `animation_enabled` をONにすると、通常のSVGと同じうごメモ風の輪郭揺れを使える。`jitter_amount` が揺れ幅、`animation_interval` が切り替え間隔。接点をAnimationPlayerで動かしていても揺れの周期は続く。エディターの接点・ハンドル・選択位置と保存値は、揺れを加える前の座標を使う。

`cache_animation_frames` は、ONなら4パターンを保持し、OFFなら画像1枚を更新する。SVGAnimateは連続変形向けにOFFが既定。通常のSVG2D / SVG3DはONが既定。静止した形を揺らし続ける場合はON、メモリを抑えて接点を頻繁に動かす場合はOFFを使う。どちらも同じ揺れを描く。

### 接点アニメーションの履歴キャッシュ

SVGAnimateの **Animation Cache → Animation Cache Mode** は **Exact Frames** が既定。以前と完全に同じ接点形状・解像度・揺れ条件へ戻ったとき、SVG解析・画像化・画像転送を省ける。座標や時間の丸めは行わないため、毎回異なる補間座標では再利用できない。過去フレームの保持が不要な場合は **Disabled** を使う。

**Animation Cache Limit Mb** は履歴の上限（既定32 MiB、1〜256）。最大512枚まで保持し、上限を超えたら最近使っていない画像から解放する。1枚だけで上限を超える画像は保持しない。表示中の画像や通常の描画用バッファはこの上限とは別。`src` の再設定、モード変更、`clear_animation_cache()` で履歴を消せる。

`get_animation_cache_hits()`、`get_animation_cache_misses()`、`get_animation_cache_bytes()`、`get_animation_cache_frame_count()` で利用状況を確認できる。`cache_animation_frames` は現在の形の揺れ4パターン、**Exact Frames** は過去の接点形状も含む履歴を扱う。どちらも編集点・ハンドルの位置には影響しない。

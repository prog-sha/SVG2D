# SVG2D

[English](README.md) | **日本語**

SVG2D は、SVG を Godot の 2D・3D シーンに表示するための軽量な GDExtension アドオンだよ。画面上の描画領域を見て解像度を更新し、同じ画素数では作った画像を使い回すよ。`SVG3D` は投影寸法の1.5倍以上で画像化し、ミップマップも作るよ。

## 対応環境

- Godot 4.7 以降
- Windows x86_64
- macOS Universal

配布ファイルには、Windows x86_64 と macOS Universal のデバッグ用・配布用バイナリーが入っているよ。

## 導入しよう

1. `svg2d` フォルダーを自分のプロジェクトの `addons` フォルダーへコピーしよう。
2. Godot の「プロジェクト」→「プロジェクト設定」→「プラグイン」を開こう。
3. **SVG2D** を有効にしよう。

## 使ってみよう

2Dシーンでは `SVG2D`、3Dシーンでは `SVG3D` ノードを追加し、インスペクターの `src` にある **Open SVG…** から `.svg` 素材を選ぼう。選んだ絵と寸法もその場でプレビューできるよ。SVG文書の幅と高さが自然な寸法になり、2D・3D編集画面では不透明な絵をクリックしてノードをドラッグできるよ。画面上の寸法は `SVG2D` の変形やカメラで変えよう。`SVG3D` の空間内での寸法は `pixel_size` で調整しよう。

Inspectorの **Create Hitbox** では、Godot標準の `StaticBody` + Collision子ノード構成を自動生成できるよ。**Rect** は矩形を作り、**Shape** は透明な穴を除いたSVGの外周から2Dポリゴンまたは薄い3D形状を作るよ。

```gdscript
var picture := SVG2D.new()
picture.src = "res://picture.svg"
picture.scale = Vector2(2, 2)
add_child(picture)
```

既存SVGパスをアニメにするときは `SVGAnimate2D` / `SVGAnimate3D` を使おう。選択すると2D・3Dエディターへ番号付き接点とBezierハンドルが出るよ。接点またはハンドルをドラッグし、2DではShiftで縦横へ制限できる。`V`、`I`、`O`で接点・入ハンドル・出ハンドルを切り替え、Tab / Shift+Tabで接点番号を移動するよ。Inspectorには各接点が `paths/path_N/point_N` として出るため、Godot標準の鍵ボタンとAnimationPlayerの値トラックでキー編集できる。パス・接点・セグメントの追加削除はせず、円弧は円弧、直線は直線のまま保つよ。

`SpriteRope2D` と `SpriteRope3D` はPNG・WebP・GodotでインポートしたSVGなど、標準の `Texture2D` を受け取るPBD紐だよ。`SVGRope2D` と `SVGRope3D` は `src` 選択と高解像度SVG生成を持つ別のSVG専用クラスだよ。どちらも上から下の各段を粒子列へ追従させる。`line_mode` をONにすれば素材なしで `line_width` と `line_color` の普通の紐になるよ。`max_length` が0なら素材の高さから長さを自動算出するよ。

Verlet積分はARM64ならNEON、x86_64ならSSE2を使うよ。隣の補正結果へ依存する距離制約は順序を壊さない通常CPU計算のままだよ。非対応CPU・倍精度ビルド・`SVG2D_SCALAR=yes` では、同じ式のscalar経路へ自動で切り替わるよ。

```gdscript
var rope := SVGRope2D.new()
rope.src = "res://banner.svg"
rope.segments = 24
rope.max_length = 320.0
rope.elasticity = 0.85
add_child(rope)
```

```gdscript
var image_rope := SpriteRope2D.new()
image_rope.texture = preload("res://banner.png")
add_child(image_rope)
```

アニメーションは初めはOFFだよ。`animation_enabled` をONにすると、形全体は移動させず、`jitter_amount`（既定0.0008、最大0.3）を絵の縦横に対する輪郭の最大変形率として使うよ。seed 1〜4で固定した4枚だけを作り、`animation_interval`（既定10フレーム）ごとに順番に切り替えるよ。OFFに戻すとアニメ用3枚のキャッシュも解放するよ。

2D・3Dとも `flip_h`、`flip_v`、`offset` を使えるよ。色と透明度は `modulate` で変えよう（2DではCanvasItem共通のVisibility欄、3DではAppearance欄）。

`adaptive` は初めから有効だよ。2Dエディターではズームと画面倍率へ最低1.5倍の余裕を持って追従し、実行中のカメラと3Dエディターのカメラにも追従するよ。SVG3Dは投影されたローカル軸のうち高い方の密度を両軸に使うため、回転してもSVGの縦横比を崩さないよ。SVG文書の解像度に固定したいときは無効にしよう。この場合も各辺の上限は4096画素だよ。3Dは固定時も自然寸法の1.5倍で焼くよ。

自動解像度の画像は、RGBA画像1枚を64 MiB以内に収めるため、各辺を4096画素までにしているよ。画面上でとても大きくした場合は、この範囲で最も細かい画像を使うよ。

画素変換はx86_64ではSSE2、arm64ではNEONを使うよ。ほかのアーキテクチャー向けに組み立てた場合は、同じ結果になる通常のCPU処理へ切り替わるよ。

## 対応している SVG

四角、丸、パス、塗り、線、グラデーション、切り抜き、`use`、入れ子の `svg`、`viewBox`、基本的な CSS セレクターを描けるよ。

文字、フィルター、マスク、パターン、マーカー、SVG自身のSMILアニメーション、外部画像には対応していないよ。

## ライセンス

このフォルダーの `LICENSE` を見てね。

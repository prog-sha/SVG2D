# SVG2D

[English](README.md) | **日本語**

SVG2D は、SVG を Godot の 2D・3D シーンに表示するための軽量な GDExtension アドオンだよ。画面上の描画領域を見て解像度を更新し、同じ画素数では作った画像を使い回すよ。`SVG3D` は投影寸法の1.5倍以上で画像化し、ミップマップも作るよ。

## 対応環境

- Godot 4.7 以降
- Windows x86_64
- macOS Universal
- iOS arm64
- Linux x86_64・arm64
- Android arm64
- Web wasm32（スレッドなし）

配布ファイルには、上記すべてのデバッグ用・配布用バイナリーが入っているよ。英語版READMEを基準文書としているよ。

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

既存SVGパスをアニメにするときは `SVGAnimate2D` / `SVGAnimate3D` を使おう。選択すると2D・3Dエディターへ全パスの番号付き接点と、選択接点のBezierハンドルが出るよ。接点またはハンドルをドラッグし、Shiftで縦横へ制限できる。通常のハンドル移動は反対側の接線を滑らかに保ち、Altを押すと片側だけを折れる。`A`（または`V`）、`I`、`O`で接点・入ハンドル・出ハンドルを切り替え、Tab / Shift+Tabで接点、`[` / `]`でパス番号を移動するよ。Inspectorの **Path Editor** から番号を直接選べ、**Insert Point Key** または`K`で現在のAnimationPlayerへ接点の値トラックとキーを登録できる。Inspectorの各接点 `paths/path_N/point_N` にあるGodot標準の鍵ボタンも使える。パス・接点・セグメントの追加削除はせず、円弧は円弧、直線は直線のまま保つよ。

パス点のオーバーレイは、実描画と同じ `viewBox`、`preserveAspectRatio`、入れ子のグループとパスの `transform` を通して表示・逆変換する。ノードの移動、エディターのパン、2D/3Dのどちらでも絵と接点が一致するよ。

`SpriteRope2D` と `SpriteRope3D` はPNG・WebP・GodotでインポートしたSVGなど、標準の `Texture2D` を受け取るPBD紐だよ。`SVGRope2D` と `SVGRope3D` は `src` 選択と高解像度SVG生成を持つ別のSVG専用クラスだよ。どちらも上から下の各段を粒子列へ追従させる。`line_mode` をONにすれば素材なしで `line_width` と `line_color` の普通の紐になるよ。`max_length` が0なら素材の高さから長さを自動算出するよ。既定では所属するWorldのシステム重力を使い、`gravity_scale` で倍率を変えられるよ。独自のローカル重力を使う場合だけ `use_system_gravity` をOFFにして `gravity` を設定しよう。

`attachment_body` に `PhysicsBody2D` または `PhysicsBody3D` を指定すると、粒子を追う内部 `AnimatableBody` とGodot標準の `PinJoint` で紐へ接続するよ。`attachment_point` が接続する粒子番号で、`-1` は末端だよ。接続物の衝突・質量・回転は物理エンジンが扱い、パスを空に戻すと内部Body・Joint・更新処理を取り除くよ。

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

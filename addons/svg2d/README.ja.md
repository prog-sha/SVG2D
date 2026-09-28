# SVG2D

[English](README.md) | **日本語** · [リポジトリのガイド](https://github.com/prog-sha/SVG2D/blob/main/README.ja.md)

SVG2D は、Godotの2D・3DシーンでSVGを表示し、パスをアニメーションし、画像やSVG素材のロープを動かすGDExtensionアドオン。画面上の大きさに応じて解像度を更新し、表示条件が同じなら画像を使い回す。`SVG3D` は投影寸法の1.5倍以上で画像化し、ミップマップを作る。

## 対応環境

- Godot 4.7 以降
- Windows x86_64
- macOS Universal
- iOS arm64
- Linux x86_64・arm64
- Android arm64
- Web wasm32（スレッドなし）

配布ファイルには上記すべてのdebug/releaseバイナリを含む。

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

既存SVGパスをアニメーションするときは `SVGAnimate2D` / `SVGAnimate3D` を使う。選択すると2D・3Dエディターへ番号付き接点と、実際に存在する三次ベジェ曲線のハンドルが出る。ドラッグ中のShiftで縦横を制限し、Altで反対側の接線との連動を外せる。`A`（または`V`）、`I`、`O`で接点・入ハンドル・出ハンドルを選択し、Tab / Shift+Tabで接点、`[` / `]`でパスを切り替える。Inspectorの **Path Editor** で番号を選んで `+` ボタン、または `K` で選択中の値をキー登録できる。点の右クリックメニューからは接点、両ハンドル、パスの塗り・線・不透明度・線幅、ノードの `modulate` を個別または一括で登録できる。**Create AnimationPlayer (All SVG Properties)** はこれらの初期トラックを作る。既存のパス・接点・セグメントは増減せず、円弧は円弧、直線は直線として保つ。円弧や直線には三次ベジェハンドルを表示しない。

パスごとの単色の塗りと線は、Inspectorの `paths/path_N/fill_color` と `stroke_color` を変更してキー登録する。色はキー間で補間する。グラデーションや `none` には `fill_paint` / `stroke_paint` の文字列プロパティを使い、値を離散的に切り替える。`fill_opacity`、`stroke_opacity`、`stroke_width` もアニメーションできる。標準のInspector鍵ボタンからも登録できる。

パス点のオーバーレイは、実描画と同じ `viewBox`、`preserveAspectRatio`、入れ子のグループとパスの `transform` を通して表示・逆変換する。ノードの変形、`flip_h` / `flip_v`、エディターのパン、2D/3Dのカメラ移動にも追従する。うごメモ風の輪郭揺れは描画だけに作用し、編集点や保存座標は揺れない。

`SpriteRope2D` と `SpriteRope3D` はPNG・WebP・GodotでインポートしたSVGなど、標準の `Texture2D` を受け取るPBD紐だよ。`SVGRope2D` と `SVGRope3D` は `src` 選択と高解像度SVG生成を持つ別のSVG専用クラスだよ。どちらも上から下の各段を粒子列へ追従させる。`line_mode` をONにすれば素材なしで `line_width` と `line_color` の普通の紐になるよ。`max_length` が0なら素材の高さから長さを自動算出するよ。既定では所属するWorldのシステム重力を使い、`gravity_scale` で倍率を変えられるよ。独自のローカル重力を使う場合だけ `use_system_gravity` をOFFにして `gravity` を設定しよう。

`attachment_body` に `PhysicsBody2D` / `PhysicsBody3D` を指定すると、ロープの各区間も内部 `RigidBody` と `PinJoint` で同じ物理空間へ参加するよ。接続物の重さ・慣性・衝突の反力がロープへ戻り、ロープも接続物を引く。`rope_mass` はロープ全体の質量、`attachment_point` は接続粒子番号で `-1` が末端。内部区間は衝突せず、外界との接触は接続物のCollisionShapeが担当するよ。回転を止める場合は接続物の `lock_rotation` をONにしよう。

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

SVGとSVGAnimateのうごメモ風アニメーションは既定OFF。`animation_enabled` をONにすると、形全体は移動させず輪郭を変形する。`jitter_amount` は文書寸法に対する変形率（既定0.0008、最大0.3）。4種類の決定的な模様を `animation_interval`（既定10フレーム）ごとに切り替える。4枚の画像を保持するかは `cache_animation_frames` による。SVGAnimateはパスの連続変形向けに、画像1枚を更新する設定が既定。

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
| `adaptive` | SVG2D / 3D、SVGAnimate | 既定ON。エディターとカメラの倍率に追従。OFFで固定解像度。 |
| `deferred_updates` | SVGAnimate2D / 3D | 既定ON。同じ更新周期の接点編集をまとめ、SVGの再構築・再解析を1回にする。 |
| `keep_render_cache` | SVG2D / 3Dとその派生 | OFFで画像化後の中間バッファを解放。再描画時の再計算は増える。表示テクスチャは残る。 |
| `cache_animation_frames` | SVG2D / 3D、SVGAnimate | 形が変わらない場合の輪郭揺れ4枚を保持。SVGAnimateは既定OFF、SVG2D/3Dは既定ON。 |
| `animation_cache_mode` | SVGAnimate2D / 3D | Exact Framesは過去の同一パス状態を再利用。Disabledは履歴なし。 |
| `animation_cache_limit_mb` | SVGAnimate2D / 3D | 履歴上限1〜256 MiB。既定32 MiB、最大512枚。 |
| `dynamic_mesh` | SpriteRope3D / SVGRope3D | 既定ON。頂点と境界だけ更新し、UV・三角形の再生成と転送を省く。 |

接点の取得・シーン保存は常に最新の編集値を使う。遅延更新中に2Dテクスチャをすぐ取得する場合は `flush_paths()` を先に呼ぶ。3Dテクスチャの表示反映はidle時に行う。`get_render_cache_bytes()` で中間バッファの概算を確認できる。

`SVGAnimate2D` / `SVGAnimate3D` でも、Inspectorの `animation_enabled` をONにすると、通常のSVGと同じうごメモ風の輪郭揺れを使える。`jitter_amount` が揺れ幅、`animation_interval` が切り替え間隔。接点をAnimationPlayerで動かしていても揺れの周期は続く。エディターの接点・ハンドル・選択位置と保存値は、揺れを加える前の座標を使う。

`cache_animation_frames` は、ONなら4パターンを保持し、OFFなら画像1枚を更新する。SVGAnimateは連続変形向けにOFFが既定。通常のSVG2D / SVG3DはONが既定。静止した形を揺らし続ける場合はON、メモリを抑えて接点を頻繁に動かす場合はOFFを使う。どちらも同じ揺れを描く。

### 接点アニメーションの履歴キャッシュ

SVGAnimateの **Animation Cache → Animation Cache Mode** は **Exact Frames** が既定。以前と完全に同じ接点形状・解像度・揺れ条件へ戻ったとき、SVG解析・画像化・画像転送を省ける。座標や時間の丸めは行わないため、毎回異なる補間座標では再利用できない。過去フレームの保持が不要な場合は **Disabled** を使う。

**Animation Cache Limit Mb** は履歴の上限（既定32 MiB、1〜256）。最大512枚まで保持し、上限を超えたら最近使っていない画像から解放する。1枚だけで上限を超える画像は保持しない。表示中の画像や通常の描画用バッファはこの上限とは別。`src` の再設定、モード変更、`clear_animation_cache()` で履歴を消せる。

`get_animation_cache_hits()`、`get_animation_cache_misses()`、`get_animation_cache_bytes()`、`get_animation_cache_frame_count()` で利用状況を確認できる。`cache_animation_frames` は現在の形の揺れ4パターン、**Exact Frames** は過去の接点形状も含む履歴を扱う。どちらも編集点・ハンドルの位置には影響しない。

### ロープの切断と物理接続

`cut_segment(from, to)` は入力した**グローバル座標**の線分とロープの最初の交点で切る。交点に粒子を追加し、各切断片の現在位置・速度・元の長さ・質量・画像範囲を保つ。3D版では最近接点のワールド距離の許容値 `tolerance`（既定 `0.001`）も指定できる。交差なし・平行な重なり・ロープ端点・無効な入力では `null`。複数箇所を切る場合は両方の切断片へ再び適用する。[棒人間とロープのシーン](https://github.com/prog-sha/SVG2D/blob/main/tests/stickman_rope_swing.tscn)では棒人間をドラッグでき、背景をドラッグして切断線を引ける。棒人間の回転は固定。

`cut_at(point_index)` は途中の接点でロープを切り、同じクラスの新しいノードを `ClassDB.instantiate` で作って同じ親に追加し、返す。元のロープは上側、新しいロープは開始点が自由な下側になる。現在の形・速度・回転速度・素材の切れ目を引き継ぎ、長さと質量を分配する。切断点以降の接続物も下側へ移る。切れる範囲は `1` から `segments - 2` で、端点・範囲外・ツリー外では変更せず `null` を返す。実行中専用で、スクリプト・子ノード・シグナル接続は複製しない。衝突通知から呼ぶ場合は `call_deferred` を使おう。

```gdscript
var fallen_rope = $Rope.cut_segment(Vector2(200, 100), Vector2(450, 100))
# fallen_rope.get_parent() == $Rope.get_parent()
```

未接続のロープはSIMD Verlet計算、接続済みロープはGodotの剛体計算を使う。`elasticity` と `constraint_iterations` はVerlet用で、剛体経路の反復設定はプロジェクトの物理設定に従う。`damping` は60Hzの1ステップあたりの速度減衰率で、更新頻度に応じて換算する。接続物自身の減衰はRigidBody側で設定する。接続を外しても区間の運動を保ち、`reset_simulation()` で内部剛体を解放して初期形状へ戻す。

双方向接続は [Verlet Ropeの剛体方式](https://github.com/Tshmofen/verlet-rope-4/blob/master/addons/verlet_rope_4/Physics/VerletRopeRigid.cs)を参考に、C++で実装している。

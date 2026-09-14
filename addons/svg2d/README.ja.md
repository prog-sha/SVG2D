# SVG2D

[English](README.md) | **日本語**

SVG2D は、SVG を Godot の 2D・3D シーンに表示するための軽量な GDExtension アドオンだよ。指定した大きさが変わったときに SVG を画像へ変換し、作った画像を使い回すよ。

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

2Dシーンでは `SVG2D`、3Dシーンでは `SVG3D` ノードを追加し、インスペクターから `src` に SVG の文字列を設定しよう。画像の細かさを指定するときは `size` を設定し、ゼロのままなら SVG 文書の大きさを使うよ。`SVG3D` の空間内での大きさは、継承している `pixel_size` で調整しよう。

```gdscript
var picture := SVG2D.new()
picture.src = FileAccess.get_file_as_string("res://picture.svg")
picture.size = Vector2(320, 240)
add_child(picture)
```

どちらのノードも、インスペクターで `src` と `size` にマウスを重ねると説明を読めるよ。

## 対応している SVG

四角、丸、パス、塗り、線、グラデーション、切り抜き、`use`、入れ子の `svg`、`viewBox`、基本的な CSS セレクターを描けるよ。

文字、フィルター、マスク、パターン、マーカー、アニメーション、外部画像には対応していないよ。

## ライセンス

このフォルダーの `LICENSE` を見てね。

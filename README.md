# SVG2D

SVG を Godot の 2D 場面へ軽く置くための GDExtension アドオンだよ。SVG の文字列を `SVG2D` ノードへ渡すと、必要な大きさで一度画像にし、大きさが変わるまで使い回すよ。

## 使ってみよう

Godot 4.7 と C++17 のコンパイラ、SCons を用意しよう。リポジトリを取得したら、次のように組み立てるよ。

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=macos target=template_debug
```

別のプロジェクトで使うときは、`addons/svg2d` をそのプロジェクトへ移そう。使う環境向けに作った `bin/<環境>` も一緒に入れるよ。

場面へ `SVG2D` ノードを追加し、Inspector の `source` に SVG を入れよう。大きさを変えたいときは `size` を指定できるよ。

```gdscript
var picture := SVG2D.new()
picture.source = FileAccess.get_file_as_string("res://picture.svg")
picture.size = Vector2(320, 240)
add_child(picture)
```

画像として扱うときは `SVG` を使おう。

```gdscript
var document := SVG.new()
if document.parse(svg_text):
	var image := document.render(320, 240)
```

四角、丸、道、塗り、線、色の移り変わり、切り抜き、`use`、入れ子の `svg`、`viewBox`、`style` を描けるよ。文字、filter、mask、pattern、marker、animation、外部画像は扱わないよ。

## 確かめよう

macOS では Godot 4.7.1 の場所を自動で見つけるよ。

```sh
sh tests/test.sh
```

Godot を別の場所へ置いたときは `GODOT=/path/to/godot` を付けよう。

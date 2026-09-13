# SVG2D

SVG を Godot の 2D 場面へ軽く置くための GDExtension アドオンだよ。SVG の文字列を `SVG2D` ノードへ渡すと、必要な大きさで一度画像にし、大きさが変わるまで使い回すよ。

## 使ってみよう

Godot 4.7 と C++17 のコンパイラ、SCons を用意しよう。リポジトリを取得したら、次のように組み立てるよ。

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=macos target=template_debug
scons platform=macos target=template_release
```

Linux、Windows、Android、Web 向けでは `platform` を使う環境の名前へ替えよう。配布するときは `template_release`、開発中は `template_debug` の成果物を使うよ。

使うプロジェクトへ `addons` フォルダーをコピーしよう。Godot の「プロジェクト」→「プロジェクト設定」→「プラグイン」で SVG2D を有効にするよ。

場面へ `SVG2D` ノードを追加し、インスペクターの `src` に SVG を入れよう。大きさを変えたいときは `size` を指定できるよ。

```gdscript
var picture := SVG2D.new()
picture.src = FileAccess.get_file_as_string("res://picture.svg")
picture.size = Vector2(320, 240)
add_child(picture)
```

四角、丸、道、塗り、線、色の移り変わり、切り抜き、`use`、入れ子の `svg`、`viewBox`、`style` を描けるよ。文字、filter、mask、pattern、marker、animation、外部画像は扱わないよ。

## 確かめよう

macOS では Godot 4.7.1 の場所を自動で見つけるよ。

```sh
sh tests/test.sh
```

Godot を別の場所へ置いたときは `GODOT=/path/to/godot` を付けよう。

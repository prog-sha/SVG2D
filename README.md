# SVG2D

SVG2D is a lightweight GDExtension add-on that renders SVG markup in Godot 2D scenes. It rasterizes an SVG only when its requested size changes, then reuses the resulting texture.

The packaged add-on currently supports Godot 4.7 or later on Windows x86_64. See [`addons/svg2d/README.md`](addons/svg2d/README.md) for installation, usage, and supported SVG features.

## Building from source

Install Godot 4.7, a C++17 compiler, and SCons, then clone the repository with its build-only submodule:

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=windows target=template_debug
scons platform=windows target=template_release
```

Replace `platform` when building for another supported target. Use `template_release` for distribution and `template_debug` for development.

## Testing

On macOS, the test script automatically looks for Godot 4.7.1. Set `GODOT` when Godot is installed elsewhere.

```sh
GODOT=/path/to/godot sh tests/test.sh
```

## 日本語

SVG を Godot の 2D 場面へ軽く置くための GDExtension アドオンだよ。SVG の文字列を `SVG2D` ノードへ渡すと、必要な大きさで一度画像にし、大きさが変わるまで使い回すよ。

使うプロジェクトへ `addons/svg2d` フォルダーをコピーし、Godot の「プロジェクト」→「プロジェクト設定」→「プラグイン」で SVG2D を有効にしよう。

```gdscript
var picture := SVG2D.new()
picture.src = FileAccess.get_file_as_string("res://picture.svg")
picture.size = Vector2(320, 240)
add_child(picture)
```

四角、丸、道、塗り、線、色の移り変わり、切り抜き、`use`、入れ子の `svg`、`viewBox`、`style` を描けるよ。文字、filter、mask、pattern、marker、animation、外部画像は扱わないよ。

# GDExtension アドオンの構成

## 何のために調べたか

SVG2D を別の Godot プロジェクトへ移しやすくし、Godot 4.7 で同じ手順から組み立てられる形を決めるために調べたよ。

## 採用した形

- `godot-cpp` はサブモジュールにし、公式テンプレートと同じく SCons から読む。
- `.gdextension` と共有ライブラリは `addons/svg2d` の中へまとめる。
- `plugin.cfg` と EditorPlugin の入口を置き、プロジェクト設定から有効にできる形にする。
- 共有ライブラリの道は `.gdextension` からの相対指定にし、アドオンの置き場を変えても対応しやすくする。
- 対象 API は Godot 4.7 とし、古い Godot が誤って読むのを防ぐ。
- 組み立て対象は SVG2D が使う型へ絞る。`OS` は `godot-cpp` の共通処理が使うため残す。
- 画面なしの Godot では SubViewport の絵を取り出せないため、SVG2D が焼いた Texture2D を公開 API から検証する。

## 根拠

- Godot 公式の C++ テンプレートは、`godot-cpp`、`SConstruct`、試験用 Godot プロジェクトを一つのリポジトリに置いている。https://github.com/godotengine/godot-cpp-template
- 同テンプレートの絞り込み例も `OS` を有効な型へ含めている。https://github.com/godotengine/godot-cpp-template/blob/main/build_profile.json
- `godot-cpp` 公式説明は `api_version` で対象 Godot を明示する方法を勧めており、4.7 を指定できる。https://github.com/godotengine/godot-cpp
- Godot 公式資料では `.gdextension` の `entry_symbol` と環境別ライブラリを定め、`compatibility_minimum` で読める最小版を示す。https://docs.godotengine.org/en/4.5/tutorials/scripting/gdextension/gdextension_file.html
- Godot 公式の導入手順では、`addons` をプロジェクトへ移し、プロジェクト設定のプラグイン欄から有効にする。https://docs.godotengine.org/en/4.7/tutorials/plugins/editor/installing_plugins.html

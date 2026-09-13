# SVG2D をプロジェクト設定のプラグイン一覧へ知らせる入口。
# 責務: アドオンの有効・無効を Godot エディターから選べる形にすること。
# 設計思想: ノード本体は GDExtension が登録するため、編集画面固有の状態を持たない。
@tool
extends EditorPlugin

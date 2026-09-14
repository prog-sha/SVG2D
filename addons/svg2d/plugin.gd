# SVG2D のノードと SVG 素材用 Inspector を Godot エディターへ結ぶ入口。
# 責務: アドオンの有効・無効と、src のファイル選択・プレビューを提供する。
@tool
extends EditorPlugin

const SVGInspector = preload("editor/svg_inspector.gd")

var svg_inspector: EditorInspectorPlugin

func _enter_tree() -> void:
	svg_inspector = SVGInspector.new()
	add_inspector_plugin(svg_inspector)

func _exit_tree() -> void:
	if svg_inspector:
		remove_inspector_plugin(svg_inspector)
		svg_inspector = null

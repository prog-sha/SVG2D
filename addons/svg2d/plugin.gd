# SVG2D のノードと SVG 素材用 Inspector を Godot エディターへ結ぶ入口。
# 責務: アドオンの有効・無効と、src のファイル選択・プレビューを提供する。
@tool
extends EditorPlugin

const SVGInspector = preload("editor/svg_inspector.gd")

var svg_inspector: EditorInspectorPlugin
var drag_node: Node2D
var drag_start := Vector2.ZERO
var drag_offset := Vector2.ZERO

func _enter_tree() -> void:
	svg_inspector = SVGInspector.new()
	add_inspector_plugin(svg_inspector)
	add_to_group("svg2d_editor_plugin")
	EditorInterface.get_selection().selection_changed.connect(update_overlays)

func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(update_overlays):
		EditorInterface.get_selection().selection_changed.disconnect(update_overlays)
	if svg_inspector:
		remove_inspector_plugin(svg_inspector)
		svg_inspector = null

# SVG2Dが実際に描く左上原点の自然寸法を、編集用の矩形として返す。
func svg_rect(node: Node2D) -> Rect2:
	var size: Vector2 = node.call("get_svg_size")
	return Rect2(node.get("offset"), size)

func canvas_transform() -> Transform2D:
	var viewport := EditorInterface.get_editor_viewport_2d()
	return viewport.get_canvas_transform() if viewport else Transform2D.IDENTITY

func screen_transform(node: Node2D) -> Transform2D:
	return canvas_transform() * node.global_transform

func screen_to_parent(node: Node2D, point: Vector2) -> Vector2:
	var canvas_point := canvas_transform().affine_inverse() * point
	var parent := node.get_parent() as CanvasItem
	return parent.global_transform.affine_inverse() * canvas_point if parent else canvas_point

func collect_svg2d(node: Node, found: Array[Node2D]) -> void:
	if node.is_class("SVG2D") and node is Node2D and node.is_visible_in_tree():
		found.push_back(node)
	for child in node.get_children():
		collect_svg2d(child, found)

func pick_svg2d(screen_point: Vector2) -> Node2D:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return null
	var nodes: Array[Node2D] = []
	collect_svg2d(root, nodes)
	for index in range(nodes.size() - 1, -1, -1):
		var node := nodes[index]
		if svg_rect(node).has_point(screen_transform(node).affine_inverse() * screen_point):
			return node
	return null

# GodotがGDExtensionへ公開していない編集矩形を、2D編集画面の上へ描く。
func _forward_canvas_draw_over_viewport(viewport_control: Control) -> void:
	for selected in EditorInterface.get_selection().get_selected_nodes():
		if not selected.is_class("SVG2D") or not selected is Node2D:
			continue
		var rect := svg_rect(selected)
		if not rect.has_area():
			continue
		var transform := screen_transform(selected)
		var points := PackedVector2Array([
			transform * rect.position,
			transform * Vector2(rect.end.x, rect.position.y),
			transform * rect.end,
			transform * Vector2(rect.position.x, rect.end.y),
			transform * rect.position,
		])
		viewport_control.draw_polyline(points, Color("#5ba7ff"), 2.0, true)

# 絵の内側をつかめるようにし、移動をUndo/Redoへ記録する。
func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var picked := pick_svg2d(event.position)
			if picked == null:
				return false
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(picked)
			drag_node = picked
			drag_start = picked.position
			drag_offset = screen_to_parent(picked, event.position) - picked.position
			update_overlays()
			return true
		if drag_node:
			finish_drag()
			return true
	if event is InputEventMouseMotion and drag_node and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		drag_node.position = screen_to_parent(drag_node, event.position) - drag_offset
		update_overlays()
		return true
	return false

func finish_drag() -> void:
	var moved := drag_node
	var finish := moved.position
	drag_node = null
	if finish != drag_start:
		moved.position = drag_start
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("Move SVG2D")
		undo.add_do_property(moved, &"position", finish)
		undo.add_undo_property(moved, &"position", drag_start)
		undo.commit_action()
	update_overlays()

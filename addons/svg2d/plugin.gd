# SVG2D のノードと SVG 素材用 Inspector を Godot エディターへ結ぶ入口。
# 責務: アドオンの有効・無効と、src のファイル選択・プレビューを提供する。
@tool
extends EditorPlugin

const SVGInspector = preload("editor/svg_inspector.gd")
const ShapeUtils = preload("editor/svg_shape_utils.gd")

var svg_inspector: EditorInspectorPlugin
var drag_node: Node2D
var drag_start := Vector2.ZERO
var drag_offset := Vector2.ZERO
var drag_node_3d: Node3D
var drag_start_3d := Vector3.ZERO
var drag_plane_point := Vector3.ZERO
var drag_plane_normal := Vector3.FORWARD
var drag_hit_3d := Vector3.ZERO

func _enter_tree() -> void:
	svg_inspector = SVGInspector.new()
	add_inspector_plugin(svg_inspector)
	add_to_group("svg2d_editor_plugin")
	# 選択済みノードの種類に依存せず、透明画素を除いた独自判定へ入力を渡す。
	set_input_event_forwarding_always_enabled()
	EditorInterface.get_selection().selection_changed.connect(update_overlays)
	set_process(true)

func _handles(object: Object) -> bool:
	return object != null and (object.is_class("SVG2D") or object.is_class("SVG3D"))

func _exit_tree() -> void:
	set_process(false)
	update_svg3d_editor_camera(null)
	if EditorInterface.get_selection().selection_changed.is_connected(update_overlays):
		EditorInterface.get_selection().selection_changed.disconnect(update_overlays)
	if svg_inspector:
		remove_inspector_plugin(svg_inspector)
		svg_inspector = null

# シーン内Camera3Dとは別物の3D編集カメラをSVG3Dへ渡す。
# これが無いとエディターだけ自然寸法へフォールバックし、拡大表示が低解像度になる。
func _process(_delta: float) -> void:
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	update_svg3d_editor_camera(viewport.get_camera_3d() if viewport else null)

func update_svg3d_editor_camera(camera: Camera3D) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	# 全ノードを毎フレーム走査せず、SVG3Dが登録する非保存グループだけを見る。
	for node in get_tree().get_nodes_in_group(&"_svg3d_editor_nodes"):
		if node == root or root.is_ancestor_of(node):
			node.call("_set_editor_camera", camera)

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
		var local := screen_transform(node).affine_inverse() * screen_point
		var rect := svg_rect(node)
		if rect.has_point(local) and ShapeUtils.opaque_at(node, local - rect.position):
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

func collect_svg3d() -> Array[Node3D]:
	var found: Array[Node3D] = []
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return found
	for node in get_tree().get_nodes_in_group(&"_svg3d_editor_nodes"):
		if node is Node3D and node.is_visible_in_tree() and (node == root or root.is_ancestor_of(node)):
			found.append(node)
	return found

# カメラの線をSVG3DのローカルXY面へ交差させ、透明画素を除外する。
func ray_hit_svg3d(node: Node3D, camera: Camera3D, screen_point: Vector2) -> Dictionary:
	var size: Vector2 = node.call("get_svg_size")
	var pixel_size := float(node.get("pixel_size"))
	if size.x <= 0.0 or size.y <= 0.0 or pixel_size <= 0.0:
		return {}
	var ray_origin := camera.project_ray_origin(screen_point)
	var ray_direction := camera.project_ray_normal(screen_point)
	var inverse_basis := node.global_transform.basis.inverse()
	var local_origin := node.to_local(ray_origin)
	var local_direction := inverse_basis * ray_direction
	if absf(local_direction.z) < 0.000001:
		return {}
	var distance := -local_origin.z / local_direction.z
	if distance < 0.0:
		return {}
	var local_hit := local_origin + local_direction * distance
	var offset := Vector2(node.get("offset"))
	var svg_point := Vector2(
		local_hit.x / pixel_size + size.x * 0.5 - offset.x,
		-local_hit.y / pixel_size + size.y * 0.5 - offset.y
	)
	if not Rect2(Vector2.ZERO, size).has_point(svg_point):
		return {}
	if not ShapeUtils.opaque_at(node, svg_point):
		return {}
	var world_hit := node.to_global(local_hit)
	return {
		"node": node,
		"point": world_hit,
		"distance": ray_origin.distance_to(world_hit),
	}

func pick_svg3d(camera: Camera3D, screen_point: Vector2) -> Dictionary:
	var nearest: Dictionary = {}
	for node in collect_svg3d():
		var hit := ray_hit_svg3d(node, camera, screen_point)
		if not hit.is_empty() and (nearest.is_empty() or float(hit.distance) < float(nearest.distance)):
			nearest = hit
	return nearest

func intersect_drag_plane(camera: Camera3D, screen_point: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_point)
	var direction := camera.project_ray_normal(screen_point)
	var denominator := drag_plane_normal.dot(direction)
	if absf(denominator) < 0.000001:
		return null
	var distance := drag_plane_normal.dot(drag_plane_point - origin) / denominator
	return origin + direction * distance if distance >= 0.0 else null

func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var picked := pick_svg3d(camera, event.position)
			if picked.is_empty():
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			drag_node_3d = picked.node
			drag_start_3d = drag_node_3d.position
			drag_plane_point = drag_node_3d.global_position
			drag_plane_normal = drag_node_3d.global_transform.basis.z.normalized()
			drag_hit_3d = picked.point
			EditorInterface.get_selection().clear()
			EditorInterface.get_selection().add_node(drag_node_3d)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if drag_node_3d:
			finish_drag_3d()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion and drag_node_3d and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var hit := intersect_drag_plane(camera, event.position)
		if hit != null:
			drag_node_3d.global_position += Vector3(hit) - drag_hit_3d
			drag_hit_3d = hit
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func finish_drag_3d() -> void:
	var moved := drag_node_3d
	var finish := moved.position
	drag_node_3d = null
	if finish != drag_start_3d:
		moved.position = drag_start_3d
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("Move SVG3D")
		undo.add_do_property(moved, &"position", finish)
		undo.add_undo_property(moved, &"position", drag_start_3d)
		undo.commit_action()

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
var path_node: Node
var path_index := 0
var point_index := 0
var path_part := "point" # point / in / out。パス数と接点数は変更しない。
var path_drag_before := Vector2.ZERO
var path_dragging := false
const EDITOR_OVERSAMPLE := 1.5
const PATH_HANDLE_RADIUS := 7.0

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
	update_svg2d_editor_density(null)
	update_svg3d_editor_camera(null)
	if EditorInterface.get_selection().selection_changed.is_connected(update_overlays):
		EditorInterface.get_selection().selection_changed.disconnect(update_overlays)
	if svg_inspector:
		remove_inspector_plugin(svg_inspector)
		svg_inspector = null

# 2D編集画面のズームと画面倍率、3D編集カメラを各ノードへ渡す。
# どちらもシーンのViewport変換だけではエディター固有の表示密度を取得できない。
func _process(_delta: float) -> void:
	update_svg2d_editor_density(EditorInterface.get_editor_viewport_2d())
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	update_svg3d_editor_camera(viewport.get_camera_3d() if viewport else null)

func editor_pixel_ratio() -> float:
	var display_scale := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	return maxf(EDITOR_OVERSAMPLE, display_scale if is_finite(display_scale) else 1.0)

func svg2d_density(node: Node2D, editor_canvas: Transform2D, pixel_ratio: float) -> Vector2:
	var transform := editor_canvas * node.global_transform
	var ratio := maxf(EDITOR_OVERSAMPLE, pixel_ratio)
	return Vector2(transform.x.length(), transform.y.length()) * ratio

func update_svg2d_editor_density(viewport: SubViewport) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var valid := viewport != null and viewport.get_visible_rect().size.x >= 64.0 \
		and viewport.get_visible_rect().size.y >= 64.0
	var editor_canvas := viewport.get_canvas_transform() if valid else Transform2D.IDENTITY
	var pixel_ratio := editor_pixel_ratio()
	for node in get_tree().get_nodes_in_group(&"_svg2d_editor_nodes"):
		if node == root or root.is_ancestor_of(node):
			node.call("_set_editor_density",
				svg2d_density(node, editor_canvas, pixel_ratio) if valid else Vector2.ZERO)

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
		if selected.is_class("SVGAnimate2D"):
			draw_path_controls_2d(viewport_control, selected)

func path_screen_2d(node: Node2D, point: Vector2) -> Vector2:
	return screen_transform(node) * (point + Vector2(node.get("offset")))

func draw_path_controls_2d(control: Control, node: Node2D) -> void:
	var count := int(node.call("get_path_count"))
	if count == 0:
		return
	path_index = clampi(path_index, 0, count - 1)
	var points: PackedVector2Array = node.call("get_path_points", path_index)
	if points.is_empty():
		return
	point_index = clampi(point_index, 0, points.size() - 1)
	for i in points.size():
		var screen := path_screen_2d(node, points[i])
		control.draw_circle(screen, 5.0 if i == point_index else 3.5,
			Color("#ffb52e") if i == point_index else Color("#ffffff"))
		control.draw_string(ThemeDB.fallback_font, screen + Vector2(7, -7), "%d:%d" % [path_index, i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	var anchor := path_screen_2d(node, points[point_index])
	for part in ["in", "out"]:
		var handle: Vector2 = node.call("get_%s_handle" % part, path_index, point_index)
		if handle.is_equal_approx(points[point_index]):
			continue
		var screen := path_screen_2d(node, handle)
		control.draw_line(anchor, screen, Color("#62d7ff"), 1.5, true)
		control.draw_circle(screen, 4.0, Color("#62d7ff"))

func pick_path_control_2d(node: Node2D, screen_point: Vector2) -> Dictionary:
	var best := PATH_HANDLE_RADIUS
	var hit := {}
	for p in int(node.call("get_path_count")):
		for i in int(node.call("get_point_count", p)):
			var anchor: Vector2 = node.call("get_path_point", p, i)
			for part in ["point", "in", "out"]:
				var value := anchor if part == "point" else Vector2(node.call("get_%s_handle" % part, p, i))
				if part != "point" and value.is_equal_approx(anchor):
					continue
				var distance := path_screen_2d(node, value).distance_to(screen_point)
				if distance <= best:
					best = distance
					hit = {"path": p, "point": i, "part": part, "value": value}
	return hit

func set_path_control(node: Node, value: Vector2) -> void:
	if path_part == "point":
		node.call("set_path_point", path_index, point_index, value)
	else:
		node.call("set_%s_handle" % path_part, path_index, point_index, value)

func finish_path_drag() -> void:
	if not path_dragging or path_node == null:
		return
	var node := path_node
	var finish: Vector2 = node.call("get_path_point" if path_part == "point" else "get_%s_handle" % path_part,
		path_index, point_index)
	path_dragging = false
	if finish != path_drag_before:
		set_path_control(node, path_drag_before)
		var undo := EditorInterface.get_editor_undo_redo()
		undo.create_action("Edit SVG Path Point")
		var method := "set_path_point" if path_part == "point" else "set_%s_handle" % path_part
		undo.add_do_method(node, method, path_index, point_index, finish)
		undo.add_undo_method(node, method, path_index, point_index, path_drag_before)
		undo.commit_action()
	update_overlays()

# 絵の内側をつかめるようにし、移動をUndo/Redoへ記録する。
func _forward_canvas_gui_input(event: InputEvent) -> bool:
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var animate := selected[0] as Node2D if selected.size() == 1 and selected[0].is_class("SVGAnimate2D") else null
	if event is InputEventKey and event.pressed and not event.echo and animate:
		if event.keycode == KEY_V: path_part = "point"
		elif event.keycode == KEY_I: path_part = "in"
		elif event.keycode == KEY_O: path_part = "out"
		elif event.keycode == KEY_TAB:
			var n := int(animate.call("get_point_count", path_index))
			if n > 0: point_index = wrapi(point_index + (-1 if event.shift_pressed else 1), 0, n)
		else: return false
		update_overlays()
		return true
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if animate:
				var control := pick_path_control_2d(animate, event.position)
				if not control.is_empty():
					path_node = animate; path_index = control.path; point_index = control.point
					path_part = control.part; path_drag_before = control.value; path_dragging = true
					update_overlays(); return true
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
		if path_dragging:
			finish_path_drag(); return true
		if drag_node:
			finish_drag()
			return true
	if event is InputEventMouseMotion and path_dragging and path_node is Node2D \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var edit_node := path_node as Node2D
		var local: Vector2 = screen_transform(edit_node).affine_inverse() * event.position - Vector2(edit_node.get("offset"))
		if event.shift_pressed:
			var delta: Vector2 = local - path_drag_before
			local = path_drag_before + (Vector2(delta.x, 0) if absf(delta.x) >= absf(delta.y) else Vector2(0, delta.y))
		set_path_control(path_node, local); update_overlays(); return true
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
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var animate := selected[0] as Node3D if selected.size() == 1 and selected[0].is_class("SVGAnimate3D") else null
	if event is InputEventKey and event.pressed and not event.echo and animate:
		if event.keycode == KEY_V: path_part = "point"
		elif event.keycode == KEY_I: path_part = "in"
		elif event.keycode == KEY_O: path_part = "out"
		elif event.keycode == KEY_TAB:
			var n := int(animate.call("get_point_count", path_index))
			if n > 0: point_index = wrapi(point_index + (-1 if event.shift_pressed else 1), 0, n)
		else: return EditorPlugin.AFTER_GUI_INPUT_PASS
		update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if animate:
				var control := pick_path_control_3d(animate, camera, event.position)
				if not control.is_empty():
					path_node = animate; path_index = control.path; point_index = control.point
					path_part = control.part; path_drag_before = control.value; path_dragging = true
					drag_plane_point = animate.global_position
					drag_plane_normal = animate.global_transform.basis.z.normalized()
					return EditorPlugin.AFTER_GUI_INPUT_STOP
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
		if path_dragging:
			finish_path_drag(); return EditorPlugin.AFTER_GUI_INPUT_STOP
		if drag_node_3d:
			finish_drag_3d()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion and path_dragging and path_node is Node3D \
			and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var hit := intersect_drag_plane(camera, event.position)
		if hit != null:
			set_path_control(path_node, svg_point_from_world_3d(path_node, hit)); update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion and drag_node_3d and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		var hit := intersect_drag_plane(camera, event.position)
		if hit != null:
			drag_node_3d.global_position += Vector3(hit) - drag_hit_3d
			drag_hit_3d = hit
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func svg_world_3d(node: Node3D, point: Vector2) -> Vector3:
	var size: Vector2 = node.call("get_svg_size")
	var offset := Vector2(node.get("offset"))
	var pixel := float(node.get("pixel_size"))
	return node.to_global(Vector3((point.x + offset.x - size.x * 0.5) * pixel,
		-(point.y + offset.y - size.y * 0.5) * pixel, 0))

func svg_point_from_world_3d(node: Node3D, world: Vector3) -> Vector2:
	var local := node.to_local(world)
	var size: Vector2 = node.call("get_svg_size")
	var pixel := float(node.get("pixel_size"))
	return Vector2(local.x / pixel + size.x * 0.5, -local.y / pixel + size.y * 0.5) - Vector2(node.get("offset"))

func pick_path_control_3d(node: Node3D, camera: Camera3D, screen_point: Vector2) -> Dictionary:
	var best := PATH_HANDLE_RADIUS
	var hit := {}
	for p in int(node.call("get_path_count")):
		for i in int(node.call("get_point_count", p)):
			var anchor: Vector2 = node.call("get_path_point", p, i)
			for part in ["point", "in", "out"]:
				var value := anchor if part == "point" else Vector2(node.call("get_%s_handle" % part, p, i))
				if part != "point" and value.is_equal_approx(anchor): continue
				var distance := camera.unproject_position(svg_world_3d(node, value)).distance_to(screen_point)
				if distance <= best:
					best = distance; hit = {"path": p, "point": i, "part": part, "value": value}
	return hit

func _forward_3d_draw_over_viewport(control: Control) -> void:
	var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	if camera == null: return
	for selected in EditorInterface.get_selection().get_selected_nodes():
		if not selected.is_class("SVGAnimate3D"): continue
		var paths := int(selected.call("get_path_count"))
		if paths == 0: continue
		path_index = clampi(path_index, 0, paths - 1)
		var points: PackedVector2Array = selected.call("get_path_points", path_index)
		if points.is_empty(): continue
		point_index = clampi(point_index, 0, points.size() - 1)
		for i in points.size():
			var screen := camera.unproject_position(svg_world_3d(selected, points[i]))
			control.draw_circle(screen, 5.0 if i == point_index else 3.5,
				Color("#ffb52e") if i == point_index else Color.WHITE)
			control.draw_string(ThemeDB.fallback_font, screen + Vector2(7, -7), "%d:%d" % [path_index, i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
		var anchor := camera.unproject_position(svg_world_3d(selected, points[point_index]))
		for part in ["in", "out"]:
			var handle: Vector2 = selected.call("get_%s_handle" % part, path_index, point_index)
			if handle.is_equal_approx(points[point_index]): continue
			var screen := camera.unproject_position(svg_world_3d(selected, handle))
			control.draw_line(anchor, screen, Color("#62d7ff"), 1.5, true)
			control.draw_circle(screen, 4.0, Color("#62d7ff"))

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

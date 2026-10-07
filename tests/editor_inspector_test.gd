# 実エディター内で Inspector の src 選択とキャンバス選択面を確かめる。
@tool
extends EditorPlugin

const SVGSourceProperty = preload("res://addons/svg2d/editor/svg_source_property.gd")
const SVGHitboxControl = preload("res://addons/svg2d/editor/svg_hitbox_control.gd")
const SVGPathControl = preload("res://addons/svg2d/editor/svg_path_control.gd")
const ShapeUtils = preload("res://addons/svg2d/editor/svg_shape_utils.gd")
const TransformFixture = preload("res://tests/editor_transform_fixture.gd")

var failed := false

func check(ok: bool, message: String) -> void:
	if ok:
		return
	failed = true
	push_error(message)

# 編集済みの形・曲線・色・透明度を、自然寸法画像と当たり判定の輪郭へ渡す。
static func test_animated_shape_image(probe: Object, utils: GDScript = ShapeUtils) -> void:
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		var node: Node = ClassDB.instantiate(kind)
		node.set("src", "<svg width='100' height='100'><path d='M10 20 C20 10 40 10 50 20 L50 60 L10 60 Z' fill='red'/></svg>")
		var initial: Image = utils.natural_image(node)
		node.call("set_path_point", 0, 2, Vector2(75, 60))
		var pending: Image = utils.natural_image(node)
		probe.check(pending.get_data() != initial.get_data(), kind + " natural image ignored pending anchor edit")
		node.call("flush_paths")
		var moved: Image = utils.natural_image(node)
		probe.check(moved.get_data() == pending.get_data(), kind + " flushing changed pending natural image")
		probe.check(moved.get_data() != initial.get_data(), kind + " natural image ignored anchor edit")
		var polygons: Array[PackedVector2Array] = utils.outer_polygons(node)
		var right := 0.0
		for polygon in polygons:
			for point in polygon: right = maxf(right, point.x)
		probe.check(right > 70, kind + " collision outline ignored anchor edit")
		node.call("set_in_handle", 0, 1, Vector2(40, 45))
		node.call("flush_paths")
		var curved: Image = utils.natural_image(node)
		probe.check(curved.get_data() != moved.get_data(), kind + " natural image ignored handle edit")
		node.set("paths/path_0/fill_color", Color.BLUE)
		node.call("flush_paths")
		var blue: Image = utils.natural_image(node)
		probe.check(blue.get_pixel(25, 40).b > 0.9 and blue.get_pixel(25, 40).r < 0.1,
			kind + " natural image ignored fill color edit")
		node.set("paths/path_0/fill_opacity", 0.0)
		node.call("flush_paths")
		probe.check(utils.natural_image(node).get_used_rect().size == Vector2i.ZERO,
			kind + " natural image ignored fill opacity edit")
		probe.check(utils.outer_polygons(node).is_empty(), kind + " collision outline retained transparent fill")
		node.free()

# use側で継承した塗りと輪郭を保ち、明示したスタイル編集だけを反映する。
static func test_natural_use_style(probe: Object) -> void:
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		for style in ["fill='red'", "fill='none' stroke='red' stroke-width='10'"]:
			var node: Node = ClassDB.instantiate(kind)
			node.set("src", "<svg width='64' height='64'><defs><path id='s' d='M16 16H48V48H16Z'/></defs><use href='#s' %s/></svg>" % style)
			var outline: bool = style.begins_with("fill='none'")
			var initial := ShapeUtils.natural_image(node)
			probe.check(initial.get_pixel(32, 32).a < 0.01 if outline else initial.get_pixel(32, 32).r > 0.99,
				kind + " natural image changed inherited use fill: " + style)
			probe.check(initial.get_pixel(17, 32).r > 0.99, kind + " natural image lost inherited use paint")
			var polygons := ShapeUtils.outer_polygons(node)
			var left := 64.0
			for polygon in polygons:
				for point in polygon: left = minf(left, point.x)
			probe.check(left < 13.0 if outline else left >= 15.0,
				kind + " natural outline changed inherited stroke width")
			node.set("paths/path_0/fill_color", Color.BLUE)
			probe.check(ShapeUtils.natural_image(node).get_pixel(32, 32).b > 0.99,
				kind + " natural image ignored pending inherited fill edit")
			node.call("flush_paths")
			var edited := ShapeUtils.natural_image(node)
			probe.check(edited.get_pixel(32, 32).b > 0.99,
				kind + " explicit style edit did not override inherited use fill")
			if outline:
				probe.check(edited.get_pixel(12, 32).r > 0.99,
					kind + " explicit fill edit lost inherited use stroke")
			node.free()

# ShapeUtilsが保持する不透明度マスクを再利用し、画像更新時には古い判定を捨てる。
static func test_opaque_mask(probe: Object) -> void:
	var tree: SceneTree = probe as SceneTree if probe is SceneTree else probe.get_tree()
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		var node: Node = ClassDB.instantiate(kind)
		node.set("adaptive", false)
		node.set("animation_enabled", false)
		node.set("cache_animation_frames", false)
		node.set("animation_cache_mode", 0)
		node.set("src", "<svg width='64' height='64'><path fill='red' fill-rule='evenodd' d='M8 8H40V40H8Z M16 16H32V32H16Z'/></svg>")
		tree.root.add_child(node)
		await tree.process_frame
		var texture: Texture2D = node.call("get_texture")
		for repeat in 3:
			probe.check(ShapeUtils.opaque_at(node, Vector2(12, 12)), kind + " repeated opaque hit failed")
			probe.check(not ShapeUtils.opaque_at(node, Vector2(24, 24)), kind + " transparent hole became opaque")
			probe.check(not ShapeUtils.opaque_at(node, Vector2(56, 56)), kind + " empty background became opaque")
		node.set("flip_h", true)
		probe.check(ShapeUtils.opaque_at(node, Vector2(52, 12)), kind + " horizontal flip missed opaque hit")
		node.set("flip_v", true)
		probe.check(ShapeUtils.opaque_at(node, Vector2(52, 52)), kind + " both flips missed opaque hit")
		probe.check(not ShapeUtils.opaque_at(node, Vector2(40, 40)), kind + " flipped transparent hole became opaque")
		for opacity in [0.0, 1.0, 0.0, 1.0]:
			node.set("paths/path_0/fill_opacity", opacity)
			node.call("flush_paths")
			await tree.process_frame
			probe.check(node.call("get_texture") == texture, kind + " mask fixture replaced the texture")
			probe.check(ShapeUtils.opaque_at(node, Vector2(52, 52)) == (opacity > 0),
				kind + " same-texture update kept the old alpha mask at opacity " + str(opacity))
		var other: Node = ClassDB.instantiate("SVG2D")
		other.set("adaptive", false)
		other.set("animation_enabled", false)
		other.set("src", "<svg width='64' height='64'><rect width='64' height='64' fill='blue'/></svg>")
		probe.check(ShapeUtils.opaque_at(other, Vector2(12, 12)), kind + " switching to another texture lost its mask")
		var other_texture: Texture2D = other.call("get_texture")
		var other_mask := ShapeUtils._texture_mask(other_texture)
		probe.check(not texture.changed.is_connected(ShapeUtils._clear_mask),
			kind + " previous texture kept its mask invalidation connection")
		node.set("paths/path_0/fill_opacity", 0.0)
		node.call("flush_paths")
		await tree.process_frame
		node.call("get_texture")
		probe.check(ShapeUtils._texture_mask(other_texture) == other_mask,
			kind + " previous texture update invalidated the active texture mask")
		probe.check(not ShapeUtils.opaque_at(node, Vector2(52, 52)),
			kind + " returning to an updated texture reused its stale mask")
		other.free()
		node.free()

# 実エディターの四つの編集枠を、各枠のControlから対応カメラへ識別する。
func test_overlay_cameras(svg_plugin: Node) -> void:
	for index in 4:
		var viewport := EditorInterface.get_editor_viewport_3d(index)
		check(viewport != null, "3D editor viewport missing: " + str(index))
		if viewport == null: continue
		var control := viewport.get_parent() as Control
		check(control != null, "3D editor viewport control missing: " + str(index))
		if control:
			check(svg_plugin.call("camera_for_overlay", control) == viewport.get_camera_3d(),
				"3D overlay chose another viewport camera: " + str(index))
	var unrelated := Control.new()
	var orphan := Control.new()
	unrelated.add_child(orphan)
	check(svg_plugin.call("camera_for_overlay", orphan) == null,
		"unrelated overlay received an editor camera")
	unrelated.free()

func apply_inspector_change(
		property: StringName,
		value: Variant,
		_field: StringName,
		_changing: bool,
		node: Object
) -> void:
	node.set(property, value)

func test_nested_transforms_2d(scene_root: Node2D, svg_plugin: Node) -> void:
	var outer := Node2D.new()
	outer.position = Vector2(245, -83)
	outer.rotation = 0.31
	outer.scale = Vector2(1.3, 0.8)
	scene_root.add_child(outer)
	var middle := Node2D.new()
	middle.position = Vector2(45, 26)
	middle.rotation = -0.43
	middle.scale = Vector2(0.7, 1.5)
	outer.add_child(middle)
	var animate: Node2D = ClassDB.instantiate("SVGAnimate2D")
	animate.set("src", "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'>" \
		+ "<g transform='translate(7 9)'><g transform='rotate(20 50 50)'>" \
		+ "<path transform='scale(1.2 0.8)' d='M15 20 C28 8 52 8 65 20 L70 75 L10 75 Z' fill='#fff'/>" \
		+ "</g></g></svg>")
	animate.position = Vector2(26, 22)
	animate.rotation = 0.22
	animate.scale = Vector2(1.2, 0.75)
	animate.set("offset", Vector2(3, -2))
	middle.add_child(animate)
	var editor_canvas := EditorInterface.get_editor_viewport_2d().get_global_canvas_transform()
	var path_point := Vector2(65, 20)
	var local_svg := Vector2(7, 9) + Vector2(50, 50) \
		+ Vector2(65 * 1.2 - 50, 20 * 0.8 - 50).rotated(deg_to_rad(20.0))
	var scenarios := [
		{"move": Vector2(0, 0), "scale": Vector2(0.7, 1.5), "turn": -0.43},
		{"move": Vector2(32, -18), "scale": Vector2(0.7, 1.5), "turn": -0.43},
		{"move": Vector2(32, -18), "scale": Vector2(1.4, 0.65), "turn": -0.43},
		{"move": Vector2(32, -18), "scale": Vector2(1.4, 0.65), "turn": 0.57},
	]
	for scenario in scenarios:
		animate.position = Vector2(26, 22) + Vector2(scenario.move)
		middle.scale = Vector2(scenario.scale)
		middle.rotation = float(scenario.turn)
		var expected := editor_canvas * outer.transform * middle.transform * animate.transform \
			* (local_svg + Vector2(3, -2))
		var actual: Vector2 = svg_plugin.call("path_screen_2d", animate, path_point, 0)
		check(actual.distance_to(expected) < 0.2,
			"2D nested transforms misplaced path point: %s != %s" % [actual, expected])
		check(Vector2(svg_plugin.call("path_point_from_screen_2d", animate, expected, 0))
			.distance_to(path_point) < 0.2, "2D nested transforms failed inverse path mapping")
		var hit: Dictionary = svg_plugin.call("pick_path_control_2d", animate, expected)
		check(not hit.is_empty() and hit.path == 0 and hit.point == 1 and hit.part == "point",
			"2D nested transforms made the visible anchor unclickable: %s" % hit)
	# Exercise the actual editor drag path, not just the forward/inverse helper pair.
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(animate)
	var inner_document := Vector2(7, 9) + Vector2(50, 50) \
		+ Vector2(40 * 1.2 - 50, 50 * 0.8 - 50).rotated(deg_to_rad(20.0))
	var inner_screen: Vector2 = svg_plugin.call("screen_transform", animate) \
		* (inner_document + Vector2(3, -2))
	var node_before := animate.position
	var body_press := InputEventMouseButton.new()
	body_press.button_index = MOUSE_BUTTON_LEFT
	body_press.pressed = true
	body_press.position = inner_screen
	check(svg_plugin.call("_forward_canvas_gui_input", body_press),
		"2D nested transforms made the visible body unclickable")
	var body_motion := InputEventMouseMotion.new()
	body_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	body_motion.position = inner_screen + Vector2(22, 13)
	var parent_inverse := (editor_canvas * outer.transform * middle.transform).affine_inverse()
	var expected_node := node_before + parent_inverse * body_motion.position - parent_inverse * inner_screen
	svg_plugin.call("_forward_canvas_gui_input", body_motion)
	var body_release := InputEventMouseButton.new()
	body_release.button_index = MOUSE_BUTTON_LEFT
	body_release.position = body_motion.position
	svg_plugin.call("_forward_canvas_gui_input", body_release)
	check(animate.position.distance_to(expected_node) < 0.2,
		"2D nested transforms displaced the dragged node: %s != %s" %
		[animate.position, expected_node])
	var anchor_screen: Vector2 = svg_plugin.call("path_screen_2d", animate, path_point, 0)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = anchor_screen
	check(svg_plugin.call("_forward_canvas_gui_input", press),
		"2D transformed path point cannot start a viewport drag")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = anchor_screen + Vector2(17, -11)
	var expected_point: Vector2 = svg_plugin.call("path_point_from_screen_2d", animate, motion.position, 0)
	svg_plugin.call("_forward_canvas_gui_input", motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = motion.position
	svg_plugin.call("_forward_canvas_gui_input", release)
	check(Vector2(animate.call("get_path_point", 0, 1)).distance_to(expected_point) < 0.2,
		"2D nested transforms displaced a dragged path point")
	var in_handle: Vector2 = animate.call("get_in_handle", 0, 1)
	var handle_screen: Vector2 = svg_plugin.call("path_screen_2d", animate, in_handle, 0)
	var handle_hit: Dictionary = svg_plugin.call("pick_path_control_2d", animate, handle_screen)
	check(not handle_hit.is_empty() and handle_hit.part == "in" and handle_hit.point == 1,
		"2D nested transforms made the Bezier handle unclickable")
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = handle_screen
	check(svg_plugin.call("_forward_canvas_gui_input", right),
		"2D transformed handle right-click was not handled")
	svg_plugin.call("_context_key_selected", 0)
	var player2: AnimationPlayer = svg_plugin.call("_find_animation_player", animate)
	var relative2: NodePath = player2.get_node_or_null(player2.root_node).get_path_to(animate)
	check(player2.get_animation(player2.assigned_animation).find_track(
		NodePath(String(relative2) + ":paths/path_0/point_1/in_handle"), Animation.TYPE_VALUE) >= 0,
		"2D transformed handle right-click keyed the wrong node path")
	player2.free()
	outer.free()

func test_nested_transforms_3d(scene_root: Node2D, svg_plugin: Node, camera: Camera3D) -> void:
	var outer := Node3D.new()
	outer.position = Vector3(0.08, -0.06, 0.1)
	outer.rotation = Vector3(0.27, -0.35, 0.18)
	outer.scale = Vector3(1.2, 0.8, 1.3)
	scene_root.add_child(outer)
	var middle := Node3D.new()
	middle.position = Vector3(-0.06, 0.04, 0.03)
	middle.rotation = Vector3(-0.25, 0.41, -0.3)
	middle.scale = Vector3(0.7, 1.45, 0.9)
	outer.add_child(middle)
	var animate: Node3D = ClassDB.instantiate("SVGAnimate3D")
	animate.set("src", "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'>" \
		+ "<g transform='translate(7 9)'><g transform='rotate(20 50 50)'>" \
		+ "<path transform='scale(1.2 0.8)' d='M15 20 C28 8 52 8 65 20 L70 75 L10 75 Z' fill='#fff'/>" \
		+ "</g></g></svg>")
	animate.position = Vector3(0.03, 0.02, 0.04)
	animate.rotation = Vector3(0.13, -0.24, 0.28)
	animate.scale = Vector3(1.1, 0.75, 1.0)
	animate.set("offset", Vector2(3, -2))
	middle.add_child(animate)
	var path_point := Vector2(65, 20)
	var local_svg := Vector2(7, 9) + Vector2(50, 50) \
		+ Vector2(65 * 1.2 - 50, 20 * 0.8 - 50).rotated(deg_to_rad(20.0))
	var scenarios := [
		{"move": Vector3(0.0, 0.0, 0.0), "scale": Vector3(0.7, 1.45, 0.9), "turn": -0.3},
		{"move": Vector3(0.12, -0.08, 0.03), "scale": Vector3(0.7, 1.45, 0.9), "turn": -0.3},
		{"move": Vector3(0.12, -0.08, 0.03), "scale": Vector3(1.6, 0.65, 0.9), "turn": -0.3},
		{"move": Vector3(0.12, -0.08, 0.03), "scale": Vector3(1.6, 0.65, 0.9), "turn": 0.6},
	]
	for scenario in scenarios:
		animate.position = Vector3(0.03, 0.02, 0.04) + Vector3(scenario.move)
		middle.scale = Vector3(scenario.scale)
		middle.rotation.z = float(scenario.turn)
		var local_draw := Vector3((local_svg.x - 50 + 3) * float(animate.get("pixel_size")),
			(-(local_svg.y - 50) - 2) * float(animate.get("pixel_size")), 0)
		var expected := outer.transform * middle.transform * animate.transform * local_draw
		var actual: Vector3 = svg_plugin.call("svg_world_3d", animate, path_point, 0)
		check(actual.distance_to(expected) < 0.0002,
			"3D nested transforms misplaced path point: %s != %s" % [actual, expected])
		check(Vector2(svg_plugin.call("svg_point_from_world_3d", animate, expected, 0))
			.distance_to(path_point) < 0.2, "3D nested transforms failed inverse path mapping")
		var screen := camera.unproject_position(expected)
		var hit: Dictionary = svg_plugin.call("pick_path_control_3d", animate, camera, screen)
		check(not hit.is_empty() and hit.path == 0 and hit.point == 1 and hit.part == "point",
			"3D nested transforms made the visible anchor unclickable: %s" % hit)
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(animate)
	var before: Vector2 = animate.call("get_path_point", 0, 1)
	var point_world: Vector3 = svg_plugin.call("svg_world_3d", animate, before, 0)
	var point_screen := camera.unproject_position(point_world)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = point_screen
	check(svg_plugin.call("_forward_3d_gui_input", camera, press) == EditorPlugin.AFTER_GUI_INPUT_STOP,
		"3D transformed path point cannot start a viewport drag")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = point_screen + Vector2(17, -11)
	var normal := animate.global_transform.basis.x.cross(animate.global_transform.basis.y).normalized()
	var ray_origin := camera.project_ray_origin(motion.position)
	var ray_direction := camera.project_ray_normal(motion.position)
	var plane_distance := normal.dot(animate.global_position - ray_origin) / normal.dot(ray_direction)
	var expected_world := ray_origin + ray_direction * plane_distance
	var expected_point: Vector2 = svg_plugin.call("svg_point_from_world_3d", animate, expected_world, 0)
	svg_plugin.call("_forward_3d_gui_input", camera, motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = motion.position
	svg_plugin.call("_forward_3d_gui_input", camera, release)
	check(Vector2(animate.call("get_path_point", 0, 1)).distance_to(expected_point) < 0.2,
		"3D nested transforms displaced a dragged path point: %s != %s" %
		[animate.call("get_path_point", 0, 1), expected_point])
	var in_handle: Vector2 = animate.call("get_in_handle", 0, 1)
	var handle_screen := camera.unproject_position(
		Vector3(svg_plugin.call("svg_world_3d", animate, in_handle, 0)))
	var handle_hit: Dictionary = svg_plugin.call("pick_path_control_3d", animate, camera, handle_screen)
	check(not handle_hit.is_empty() and handle_hit.part == "in" and handle_hit.point == 1,
		"3D nested transforms made the Bezier handle unclickable")
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = handle_screen
	check(svg_plugin.call("_forward_3d_gui_input", camera, right) == EditorPlugin.AFTER_GUI_INPUT_STOP,
		"3D transformed handle right-click was not handled")
	svg_plugin.call("_context_key_selected", 0)
	var player3: AnimationPlayer = svg_plugin.call("_find_animation_player", animate)
	var relative3: NodePath = player3.get_node_or_null(player3.root_node).get_path_to(animate)
	check(player3.get_animation(player3.assigned_animation).find_track(
		NodePath(String(relative3) + ":paths/path_0/point_1/in_handle"), Animation.TYPE_VALUE) >= 0,
		"3D transformed handle right-click keyed the wrong node path")
	# A perspective editor camera must hit the same sheared SVG plane.
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.fov = 45.0
	camera.position = Vector3(0.15, -0.1, 2.5)
	var perspective_point: Vector2 = animate.call("get_path_point", 0, 1)
	var perspective_screen := camera.unproject_position(
		Vector3(svg_plugin.call("svg_world_3d", animate, perspective_point, 0)))
	var perspective_press := InputEventMouseButton.new()
	perspective_press.button_index = MOUSE_BUTTON_LEFT
	perspective_press.pressed = true
	perspective_press.position = perspective_screen
	check(svg_plugin.call("_forward_3d_gui_input", camera, perspective_press)
		== EditorPlugin.AFTER_GUI_INPUT_STOP,
		"3D perspective transformed path point cannot start a viewport drag")
	var perspective_motion := InputEventMouseMotion.new()
	perspective_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	perspective_motion.position = perspective_screen + Vector2(-14, 9)
	var perspective_ray_origin := camera.project_ray_origin(perspective_motion.position)
	var perspective_ray_direction := camera.project_ray_normal(perspective_motion.position)
	var perspective_distance := normal.dot(animate.global_position - perspective_ray_origin) \
		/ normal.dot(perspective_ray_direction)
	var perspective_world := perspective_ray_origin + perspective_ray_direction * perspective_distance
	var perspective_expected: Vector2 = svg_plugin.call("svg_point_from_world_3d", animate, perspective_world, 0)
	svg_plugin.call("_forward_3d_gui_input", camera, perspective_motion)
	var perspective_release := InputEventMouseButton.new()
	perspective_release.button_index = MOUSE_BUTTON_LEFT
	perspective_release.position = perspective_motion.position
	svg_plugin.call("_forward_3d_gui_input", camera, perspective_release)
	check(Vector2(animate.call("get_path_point", 0, 1)).distance_to(perspective_expected) < 0.2,
		"3D perspective nested transforms displaced a dragged path point")
	player3.free()
	outer.free()

# A second hierarchy deliberately changes the SVG node's own non-uniform scale,
# both flip flags, and the viewing camera. Expected positions are composed here
# from the SVG markup, independently of the editor's coordinate helpers.
func test_alternate_transform_stack_2d(scene_root: Node2D, svg_plugin: Node) -> void:
	var fixture: Dictionary = TransformFixture.create_2d(scene_root)
	var a: Node2D = fixture.a
	var b: Node2D = fixture.b
	var c: Node2D = fixture.c
	var svg: Node2D = fixture.svg
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(svg)
	await get_tree().process_frame
	check(svg.has_signal("path_changed") and svg_plugin.get("overlay_path_node") == svg
		and svg.is_connected(&"path_changed", Callable(svg_plugin, "update_overlays")),
		"2D editor overlay does not subscribe to generic animated path changes")
	var canvas := EditorInterface.get_editor_viewport_2d().get_global_canvas_transform()
	for scenario in [
		{"scale": Vector2(1.7, 0.55), "h": false, "v": false},
		{"scale": Vector2(0.65, 1.85), "h": true, "v": false},
		{"scale": Vector2(1.35, 0.8), "h": false, "v": true},
		{"scale": Vector2(0.8, 1.4), "h": true, "v": true},
		{"scale": Vector2(-0.9, 1.3), "h": true, "v": false},
	]:
		svg.scale = scenario.scale
		svg.set("flip_h", scenario.h)
		svg.set("flip_v", scenario.v)
		var document := Vector2(8 + 72 * 0.8, 5 + 20 * 1.1)
		if scenario.h: document.x = 100 - document.x
		if scenario.v: document.y = 100 - document.y
		var expected: Vector2 = canvas * a.transform * b.transform * c.transform * svg.transform \
			* (document + Vector2(4, -6))
		var actual: Vector2 = svg_plugin.call("path_screen_2d", svg, Vector2(72, 20), 0)
		check(actual.distance_to(expected) < 0.2, "2D alternate hierarchy/flip placed anchor incorrectly")
		var hit: Dictionary = svg_plugin.call("pick_path_control_2d", svg, expected)
		check(not hit.is_empty() and hit.point == 1 and hit.part == "point",
			"2D alternate hierarchy/flip made anchor unclickable: %s" % hit)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = expected
		check(svg_plugin.call("_forward_canvas_gui_input", press),
			"2D alternate hierarchy/flip did not accept point press")
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = expected + Vector2(8, -5)
		var target_document: Vector2 = (canvas * a.transform * b.transform * c.transform \
			* svg.transform).affine_inverse() * motion.position - Vector2(4, -6)
		if scenario.h: target_document.x = 100 - target_document.x
		if scenario.v: target_document.y = 100 - target_document.y
		var target := Vector2((target_document.x - 8) / 0.8, (target_document.y - 5) / 1.1)
		svg_plugin.call("_forward_canvas_gui_input", motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = motion.position
		svg_plugin.call("_forward_canvas_gui_input", release)
		check(Vector2(svg.call("get_path_point", 0, 1)).distance_to(target) < 0.2,
			"2D alternate hierarchy/flip dragged anchor to wrong path coordinate")
		svg.call("set_path_point", 0, 1, Vector2(72, 20))
	a.free()

func test_alternate_transform_stack_3d(scene_root: Node2D, svg_plugin: Node, camera: Camera3D) -> void:
	var fixture: Dictionary = TransformFixture.create_3d(scene_root)
	var a: Node3D = fixture.a
	var b: Node3D = fixture.b
	var c: Node3D = fixture.c
	var svg: Node3D = fixture.svg
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(svg)
	await get_tree().process_frame
	check(svg.has_signal("path_changed") and svg_plugin.get("overlay_path_node") == svg
		and svg.is_connected(&"path_changed", Callable(svg_plugin, "update_overlays")),
		"3D editor overlay does not subscribe to generic animated path changes")
	# Compare against Sprite3D's actual local quad, including its offset and
	# adaptive texture scale. This catches a shared but wrong forward/inverse map.
	var sprite := svg.get_node_or_null("SVG") as Sprite3D
	check(sprite != null, "3D visual fixture did not create the Sprite3D renderer")
	if sprite:
		var rendered_center: Vector3 = sprite.transform * sprite.get_aabb().get_center()
		var editor_center: Vector3 = ShapeUtils.displayed_point_3d(svg, Vector2(50, 50))
		check(rendered_center.distance_to(editor_center) < 0.0002,
			"3D editor coordinates disagree with Sprite3D's real offset/scale: %s != %s" %
			[editor_center, rendered_center])
	for scenario in [
		{"scale": Vector3(1.7, 0.55, 1.2), "h": false, "v": false, "ortho": true,
			"camera_offset": Vector3(0.8, 0.5, 2.2)},
		{"scale": Vector3(0.65, 1.85, 0.8), "h": true, "v": false, "ortho": false,
			"camera_offset": Vector3(-0.6, 0.35, 1.8)},
		{"scale": Vector3(1.35, 0.8, 1.3), "h": false, "v": true, "ortho": false,
			"camera_offset": Vector3(0.3, -0.6, 2.0)},
		{"scale": Vector3(0.8, 1.4, 0.7), "h": true, "v": true, "ortho": true,
			"camera_offset": Vector3(-0.75, -0.4, 2.4)},
		{"scale": Vector3(-1.1, 0.85, 1.0), "h": true, "v": false, "ortho": false,
			"camera_offset": Vector3(0.5, -0.35, 2.3)},
	]:
		svg.scale = scenario.scale
		svg.set("flip_h", scenario.h)
		svg.set("flip_v", scenario.v)
		var document := Vector2(8 + 72 * 0.8, 5 + 20 * 1.1)
		if scenario.h: document.x = 100 - document.x
		if scenario.v: document.y = 100 - document.y
		var pixel := float(svg.get("pixel_size"))
		var local := Vector3((document.x - 50 + 4) * pixel, (-(document.y - 50) - 6) * pixel, 0)
		var expected: Vector3 = a.transform * b.transform * c.transform * svg.transform * local
		check(Vector3(svg_plugin.call("svg_world_3d", svg, Vector2(72, 20), 0))
			.distance_to(expected) < 0.0002, "3D alternate hierarchy/flip placed anchor incorrectly")
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL if scenario.ortho \
			else Camera3D.PROJECTION_PERSPECTIVE
		camera.size = 1.5
		camera.fov = 48.0
		var focus := svg.global_position
		camera.position = focus + Vector3(scenario.camera_offset)
		camera.look_at(focus + Vector3(0.03, -0.02, 0.0), Vector3.UP)
		check(not camera.is_position_behind(expected), "3D alternate camera put anchor behind viewer")
		var interior_world := svg.to_global(ShapeUtils.displayed_point_3d(svg, Vector2(40, 50)))
		var body_hit: Dictionary = svg_plugin.call("ray_hit_svg3d", svg, camera,
			camera.unproject_position(interior_world))
		check(not body_hit.is_empty(), "3D alternate hierarchy/flip made the visible SVG body unclickable")
		var screen := camera.unproject_position(expected)
		var hit: Dictionary = svg_plugin.call("pick_path_control_3d", svg, camera, screen)
		check(not hit.is_empty() and hit.point == 1 and hit.part == "point",
			"3D moved/rotated camera and flip made anchor unclickable: %s" % hit)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = screen
		check(svg_plugin.call("_forward_3d_gui_input", camera, press) == EditorPlugin.AFTER_GUI_INPUT_STOP,
			"3D moved/rotated camera did not accept point press")
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = screen + Vector2(10, -7)
		var basis := svg.global_transform.basis
		var normal := basis.x.cross(basis.y).normalized()
		var ray_start := camera.project_ray_origin(motion.position)
		var ray_dir := camera.project_ray_normal(motion.position)
		var distance := normal.dot(svg.global_position - ray_start) / normal.dot(ray_dir)
		check(distance > 0, "3D moved/rotated camera ray missed the visible SVG plane")
		var point_local := svg.to_local(ray_start + ray_dir * distance)
		var target_document := Vector2(point_local.x / pixel + 50 - 4, -point_local.y / pixel + 50 - 6)
		if scenario.h: target_document.x = 100 - target_document.x
		if scenario.v: target_document.y = 100 - target_document.y
		var target := Vector2((target_document.x - 8) / 0.8, (target_document.y - 5) / 1.1)
		svg_plugin.call("_forward_3d_gui_input", camera, motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = motion.position
		svg_plugin.call("_forward_3d_gui_input", camera, release)
		check(Vector2(svg.call("get_path_point", 0, 1)).distance_to(target) < 0.2,
			"3D moved/rotated camera and flip dragged anchor to wrong path coordinate")
		svg.call("set_path_point", 0, 1, Vector2(72, 20))
	# Projecting a point behind the camera may produce plausible screen coordinates,
	# but those coordinates must never be considered an editable visible anchor.
	camera.position = svg.global_position + Vector3(0.3, 0.2, 2.0)
	camera.look_at(svg.global_position + Vector3(0.3, 0.2, 4.0), Vector3.UP)
	var hidden_world: Vector3 = svg_plugin.call("svg_world_3d", svg, Vector2(72, 20), 0)
	check(camera.is_position_behind(hidden_world), "3D rear-camera regression fixture is invalid")
	var hidden_screen := camera.unproject_position(hidden_world)
	check(Dictionary(svg_plugin.call("pick_path_control_3d", svg, camera, hidden_screen)).is_empty(),
		"3D camera incorrectly selected an SVG point behind the viewer")
	a.free()

# 保存・複製で未編集のuse継承と明示編集を区別する。
static func test_style_roundtrip(probe: Object) -> void:
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		for edit in [false, true]:
			var node: Node = ClassDB.instantiate(kind)
			node.set("src", "<svg width='64' height='64'><defs><path id='s' d='M16 16H48V48H16Z'/></defs><use href='#s' fill='none' stroke='red' stroke-width='10'/></svg>")
			if edit: node.set("paths/path_0/fill_color", Color.BLUE)
			node.name = "StyleFixture"
			var before := ShapeUtils.natural_image(node).get_data()
			var packed := PackedScene.new()
			probe.check(packed.pack(node) == OK, kind + " scene pack failed")
			var restored := packed.instantiate()
			probe.check(ShapeUtils.natural_image(restored).get_data() == before,
				kind + " PackedScene changed inherited style, edited=" + str(edit))
			var copy := node.duplicate()
			probe.check(ShapeUtils.natural_image(copy).get_data() == before,
				kind + " duplicate changed inherited style, edited=" + str(edit))
			restored.free()
			copy.free()
			node.free()

# キー・補間・トラック順を独立に読み、Undoの完全復元を比較する。
static func animation_state(animation: Animation) -> Array:
	var result: Array = []
	for track in animation.get_track_count():
		var keys: Array = []
		for key in animation.track_get_key_count(track):
			keys.append([animation.track_get_key_time(track, key),
				animation.track_get_key_value(track, key), animation.track_get_key_transition(track, key)])
		result.append([animation.track_get_path(track), animation.track_get_type(track),
			animation.track_get_interpolation_type(track), animation.track_is_enabled(track),
			animation.track_get_interpolation_loop_wrap(track), animation.value_track_get_update_mode(track), keys])
	return result

# キー操作全体を実シーン履歴の一操作として戻し、再実行できることを確認する。
func test_key_undo(root: Node, plugin: Node) -> void:
	var manager := EditorInterface.get_editor_undo_redo()
	var history_id := manager.get_object_history_id(root)
	var history := manager.get_history_undo_redo(history_id)
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		for mode in ["all_player", "new_player", "new_library", "new_animation", "new_track", "new_key", "overwrite", "unassigned_existing", "all_keys"]:
			manager.clear_history(history_id)
			var node: Node = ClassDB.instantiate(kind)
			node.name = "UndoSVG"
			node.set("src", "<svg width='64' height='64'><path d='M10 10 C20 10 40 10 50 20 L50 50Z' fill='red'/></svg>")
			root.add_child(node)
			node.owner = root
			var player: AnimationPlayer
			var library: AnimationLibrary
			var animation: Animation
			var property := "paths/path_0/point_0"
			var existing_name := &"svg_path" if mode == "unassigned_existing" else &"existing"
			if mode not in ["all_player", "new_player"]:
				player = AnimationPlayer.new()
				player.name = "UndoPlayer"
				root.add_child(player)
				player.owner = root
				if mode != "new_library":
					library = AnimationLibrary.new()
					player.add_animation_library(&"", library)
				if mode not in ["new_library", "new_animation"]:
					animation = Animation.new()
					library.add_animation(existing_name, animation)
					if mode != "unassigned_existing": player.assigned_animation = existing_name
					var track := animation.add_track(Animation.TYPE_VALUE)
					animation.track_set_path(track, NodePath("UndoSVG:" + (property if mode != "new_track" else "modulate")))
					animation.track_set_interpolation_type(track, Animation.INTERPOLATION_NEAREST)
					animation.track_set_interpolation_loop_wrap(track, false)
					animation.value_track_set_update_mode(track, Animation.UPDATE_DISCRETE)
					animation.track_insert_key(track, 0.0, Vector2(3, 4) if mode != "new_track" else Color.GREEN, 0.37)
					animation.track_insert_key(track, 0.8, Vector2(5, 6) if mode != "new_track" else Color.BLUE, 0.65)
			if mode == "new_key": player.seek(0.4, false)
			var before := animation_state(animation) if animation else []
			var old_name := player.assigned_animation if player else &""
			var version := history.get_version()
			var count := history.get_history_count()
			if mode == "all_player":
				player = plugin.call("create_all_point_animation_player", node)
			elif mode == "all_keys":
				plugin.set("path_node", node)
				plugin.set("context_properties", ["*"] as Array[String])
				plugin.call("_context_key_selected", 0)
			else:
				check(plugin.call("insert_svg_property_key", node, property), kind + " key insertion failed " + mode)
				if player == null:
					player = plugin.call("_find_animation_player", node)
			check(player != null, kind + " missing key player " + mode)
			if player == null:
				node.free()
				continue
			var added_animation := player.get_animation(player.assigned_animation)
			var after := animation_state(added_animation)
			var registered := history.get_history_count() == count + 1 and history.get_version() > version
			print("Undo case %s %s: history %d->%d version %d->%d" % [kind, mode, count, history.get_history_count(), version, history.get_version()])
			check(registered, kind + " key operation did not register one scene Undo action: " + mode)
			if registered:
				check(history.undo(), kind + " Undo failed " + mode)
				if mode in ["all_player", "new_player"]:
					check(player.get_parent() == null, kind + " Undo retained new player " + mode)
				else:
					# Godotは停止後も最後のassigned名を保持するため、空だった場合は実効状態を比較する。
					var assignment_ok := player.assigned_animation == old_name if old_name != &"" else \
						not player.is_animation_active() \
						and not player.is_playing() and player.current_animation == &""
					check(player.get_parent() == root and assignment_ok,
						kind + " Undo changed existing player assignment " + mode)
					if mode == "new_library":
						check(not player.has_animation_library(&""), kind + " Undo retained new library")
					elif mode == "new_animation":
						check(player.get_animation_library(&"") == library and library.get_animation_list().is_empty(),
							kind + " Undo retained new animation or replaced library")
					else:
						check(player.get_animation(existing_name) == animation and animation_state(animation) == before,
							kind + " Undo did not restore all original tracks/keys/transitions " + mode)
				check(history.redo(), kind + " Redo failed " + mode)
				check(player.get_parent() == root and player.owner == root,
					kind + " Redo lost player ownership " + mode)
				check(animation_state(player.get_animation(player.assigned_animation)) == after,
					kind + " Redo did not restore keyed data " + mode)
				# 未割当playerへUndo後に再登録しても、停止中の時刻getterを呼ばない。
				if mode == "unassigned_existing":
					check(history.undo(), kind + " repeated Undo failed")
					check(plugin.call("insert_svg_property_key", node, property), kind + " stopped player rejected reinsertion")
					check(animation_state(animation) == after, kind + " stopped player reinsertion used wrong key time")
					check(history.undo() and animation_state(animation) == before, kind + " reinsert Undo did not restore original data")
			manager.clear_history(history_id)
			if is_instance_valid(player): player.free()
			node.free()

# src確定後の無効な値を捨て、初回復元前の最新値だけを適用する。
static func test_pending_properties(probe: Object) -> void:
	var first := "<svg width='64' height='64'><path d='M10 10L40 10L40 40Z' fill='green'/></svg>"
	var paths := ""
	for index in 100: paths += "<path d='M10 10L40 10L40 40L10 40Z' fill='green'/>"
	var future := "<svg width='64' height='64'>" + paths + "</svg>"
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		var node: Node = ClassDB.instantiate(kind)
		node.set("src", first)
		for repeat in 32:
			node.set("paths/path_0/point_3", Vector2(90 + repeat, 91))
			node.set("paths/path_99/fill_color", Color.RED)
		node.set("src", future)
		probe.check(node.call("get_path_point", 0, 3) == Vector2(10, 40),
			kind + " invalid point leaked into later source")
		probe.check(node.get("paths/path_99/fill_color") == Color(0, 0.5019608, 0, 1),
			kind + " invalid style leaked into later source")
		node.free()
		var restored: Node = ClassDB.instantiate(kind)
		restored.set("paths/path_0/point_0", Vector2(1, 2))
		restored.set("paths/path_0/point_0", Vector2(3, 4))
		restored.set("paths/path_0/fill_color", Color.RED)
		restored.set("paths/path_0/fill_color", Color.BLUE)
		restored.set("src", first)
		probe.check(restored.call("get_path_point", 0, 0) == Vector2(3, 4),
			kind + " pre-source point restoration did not retain latest value")
		probe.check(restored.get("paths/path_0/fill_color") == Color.BLUE,
			kind + " pre-source style restoration did not retain latest value")
		restored.free()

# 反転4通りの実衝突面へ外からrayを当て、面の向きを独立に比較する。
func test_flipped_shape_rays() -> void:
	var space := PhysicsServer3D.space_create()
	PhysicsServer3D.space_set_active(space, true)
	for h in [false, true]:
		for v in [false, true]:
			var node: Node = ClassDB.instantiate("SVG3D")
			node.set("src", "<svg width='64' height='64'><rect width='64' height='64' fill='red'/></svg>")
			node.set("pixel_size", 0.01)
			node.set("flip_h", h)
			node.set("flip_v", v)
			var control := SVGHitboxControl.new()
			control.setup(node)
			var generated: StaticBody3D = control.call("_shape_3d", ShapeUtils.outer_polygons(node))
			var shape := (generated.get_child(0) as CollisionShape3D).shape as ConcavePolygonShape3D
			check(not shape.backface_collision, "Shape enabled backface collision instead of preserving winding")
			var body := PhysicsServer3D.body_create()
			PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
			PhysicsServer3D.body_add_shape(body, shape.get_rid())
			PhysicsServer3D.body_set_space(body, space)
			await get_tree().process_frame
			var state := PhysicsServer3D.space_get_direct_state(space)
			for direction in [Vector3(0, 0, 1), Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0)]:
				var query := PhysicsRayQueryParameters3D.create(direction, Vector3.ZERO)
				query.hit_back_faces = false
				var hit := state.intersect_ray(query)
				var expected: Vector3 = direction * (0.005 if direction.z != 0 else 0.32)
				check(not hit.is_empty(), "Shape external ray missed flip=%s,%s direction=%s" % [h, v, direction])
				if not hit.is_empty():
					check(Vector3(hit.position).distance_to(expected) < 0.011 and Vector3(hit.normal).dot(direction) > 0.99,
						"Shape external ray hit wrong face flip=%s,%s direction=%s" % [h, v, direction])
			PhysicsServer3D.free_rid(body)
			generated.free()
			control.free()
			node.free()
	PhysicsServer3D.free_rid(space)

# 標準ショートカットと編集ロックを尊重し、Shift本体選択を追加・除去する。
func test_editor_input_rules(root: Node, plugin: Node) -> void:
	var selection := EditorInterface.get_selection()
	var source := "<svg width='64' height='64'><path d='M0 0C20 0 44 0 64 0L64 64L0 64Z' fill='red'/></svg>"
	var point_node: Node2D = ClassDB.instantiate("SVGAnimate2D")
	point_node.set("src", source)
	point_node.position = Vector2(120, 120)
	root.add_child(point_node)
	var body_node: Node2D = ClassDB.instantiate("SVG2D")
	body_node.set("src", source)
	body_node.position = Vector2(260, 120)
	root.add_child(body_node)
	await get_tree().process_frame
	selection.clear()
	selection.add_node(point_node)
	for modifier in ["ctrl_pressed", "meta_pressed"]:
		for code in [KEY_A, KEY_I, KEY_O, KEY_K]:
			plugin.set("path_part", "out")
			var event := InputEventKey.new()
			event.pressed = true
			event.keycode = code
			event.set(modifier, true)
			check(not plugin.call("_forward_canvas_gui_input", event)
				and plugin.get("path_part") == "out" and not event.has_meta(&"svg2d_editor_handled"),
				"2D intercepted standard shortcut " + modifier + " " + str(code))
	point_node.set_meta(&"_edit_lock_", true)
	var anchor: Vector2 = point_node.call("get_path_point", 0, 0)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = plugin.call("path_screen_2d", point_node, anchor, 0)
	check(not plugin.call("_forward_canvas_gui_input", press), "2D locked anchor consumed drag press")
	var motion := InputEventMouseMotion.new()
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	motion.position = press.position + Vector2(12, 8)
	plugin.call("_forward_canvas_gui_input", motion)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = motion.position
	plugin.call("_forward_canvas_gui_input", release)
	check(point_node.call("get_path_point", 0, 0) == anchor and point_node.position == Vector2(120, 120),
		"2D locked anchor/body moved")
	point_node.remove_meta(&"_edit_lock_")
	body_node.set_meta(&"_edit_lock_", true)
	selection.clear()
	selection.add_node(body_node)
	press = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = plugin.call("screen_transform", body_node) * Vector2(32, 32)
	check(not plugin.call("_forward_canvas_gui_input", press), "2D locked body consumed drag press")
	motion.position = press.position + Vector2(12, 8)
	plugin.call("_forward_canvas_gui_input", motion)
	release.position = motion.position
	plugin.call("_forward_canvas_gui_input", release)
	check(body_node.position == Vector2(260, 120), "2D locked body moved")
	body_node.remove_meta(&"_edit_lock_")
	selection.clear()
	selection.add_node(point_node)
	for add in [true, false]:
		press = InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.shift_pressed = true
		press.position = plugin.call("screen_transform", body_node) * Vector2(32, 32)
		check(plugin.call("_forward_canvas_gui_input", press), "Shift body selection was ignored")
		check((body_node in selection.get_selected_nodes()) == add
			and point_node in selection.get_selected_nodes(), "Shift body selection replaced or retained wrong nodes")
		release = InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = press.position
		plugin.call("_forward_canvas_gui_input", release)
	selection.clear()
	var viewport := SubViewport.new()
	viewport.size = Vector2i(800, 600)
	root.add_child(viewport)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2.0
	camera.position = Vector3(0, 0, 10)
	viewport.add_child(camera)
	camera.current = true
	var point3: Node3D = ClassDB.instantiate("SVGAnimate3D")
	point3.set("src", source)
	viewport.add_child(point3)
	selection.add_node(point3)
	await get_tree().process_frame
	for modifier in ["ctrl_pressed", "meta_pressed"]:
		for code in [KEY_A, KEY_I, KEY_O, KEY_K]:
			plugin.set("path_part", "out")
			var event := InputEventKey.new()
			event.pressed = true
			event.keycode = code
			event.set(modifier, true)
			check(plugin.call("_forward_3d_gui_input", camera, event) == EditorPlugin.AFTER_GUI_INPUT_PASS
				and plugin.get("path_part") == "out", "3D intercepted standard shortcut " + modifier + " " + str(code))
	point3.set_meta(&"_edit_lock_", true)
	var anchor3: Vector2 = point3.call("get_path_point", 0, 0)
	press = InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = camera.unproject_position(plugin.call("svg_world_3d", point3, anchor3, 0))
	check(plugin.call("_forward_3d_gui_input", camera, press) == EditorPlugin.AFTER_GUI_INPUT_PASS,
		"3D locked anchor consumed drag press")
	motion.position = press.position + Vector2(12, 8)
	plugin.call("_forward_3d_gui_input", camera, motion)
	release.position = motion.position
	plugin.call("_forward_3d_gui_input", camera, release)
	check(point3.call("get_path_point", 0, 0) == anchor3, "3D locked anchor moved")
	selection.clear()
	viewport.free()
	point_node.free()
	body_node.free()

func _enter_tree() -> void:
	run_checks.call_deferred()

func run_checks() -> void:
	# EditorInterfaceの初期化と初回ファイル走査が終わってからUI部品を作る。
	await get_tree().create_timer(1.0).timeout
	var filesystem := EditorInterface.get_resource_filesystem()
	while filesystem.is_scanning():
		await get_tree().process_frame
	check(ClassDB.class_exists("SVG2D"), "エディターでSVG2Dが登録されていないよ")
	if failed:
		get_tree().quit(1)
		return
	test_animated_shape_image(self)
	test_natural_use_style(self)
	test_style_roundtrip(self)
	test_pending_properties(self)
	await test_flipped_shape_rays()
	# 同じGPU画像の更新はheadlessのダミー描画では読み戻せない。
	if DisplayServer.get_name() != "headless": await test_opaque_mask(self)
	var scene_root := Node2D.new()
	scene_root.name = "EditorTest"
	EditorInterface.add_root_node(scene_root)
	var node: Node2D = ClassDB.instantiate("SVG2D")
	scene_root.add_child(node)
	node.owner = scene_root
	var property: EditorProperty = SVGSourceProperty.new()
	property.set_object_and_property(node, &"src")
	property.property_changed.connect(apply_inspector_change.bind(node))

	# FileDialog が返す res:// パスを EditorProperty の本番経路から設定する。
	property.call("_file_selected", "res://tests/svg/hello.svg")
	check(node.get("src") == "res://tests/svg/hello.svg", "Inspectorからsrcを設定できないよ")
	var texture: Texture2D = node.call("get_texture")
	check(texture != null and texture.get_size() == Vector2(2048, 2048),
		"2D編集Viewport初期化前に高精細な暫定画像を作らないよ")

	# FILEヒントでシーン保存時に変換されるuid://も同じ素材として読めること。
	var uid := ResourceUID.path_to_uid("res://tests/svg/hello.svg")
	check(uid.begins_with("uid://"), "SVG素材のUIDを取得できないよ")
	node.set("src", uid)
	texture = node.call("get_texture")
	check(texture != null and texture.get_size() == Vector2(2048, 2048),
		"uid://のSVG素材を高精細な編集画像として表示できないよ")

	# 本番EditorPluginへマウス入力を渡し、絵の内側をつかんで移動できること。
	var svg_plugin := get_tree().get_first_node_in_group("svg2d_editor_plugin")
	check(svg_plugin != null, "SVG2Dの2D編集プラグインが動いていないよ")
	if svg_plugin:
		await get_tree().process_frame
		test_overlay_cameras(svg_plugin)
		test_key_undo(scene_root, svg_plugin)
		await test_editor_input_rules(scene_root, svg_plugin)
		var canvas_input := svg_plugin.get("canvas_input_control") as Control
		check(canvas_input != null,
			"未選択時のクリックを受ける2D編集Viewport入力面へ接続していないよ")
		var rope_editor: Node2D = ClassDB.instantiate("SVGRope2D")
		scene_root.add_child(rope_editor)
		rope_editor.owner = scene_root
		check(svg_plugin.get("svg_inspector").call("_can_handle", rope_editor),
			"SVGRope2DをSVG素材Inspectorの対象にしていないよ")
		var rope_property: EditorProperty = SVGSourceProperty.new()
		rope_property.set_object_and_property(rope_editor, &"src")
		rope_property.property_changed.connect(apply_inspector_change.bind(rope_editor))
		rope_property.call("_file_selected", "res://tests/svg/hello.svg")
		check(rope_editor.get("src") == "res://tests/svg/hello.svg"
			and rope_editor.call("get_svg_size") == Vector2(100, 100),
			"SVGRope2DへInspectorからSVG素材を設定できないよ")
		rope_property.free()
		rope_editor.free()
		var sprite_rope: Node2D = ClassDB.instantiate("SpriteRope2D")
		var imported_svg := load("res://tests/svg/hello.svg") as Texture2D
		sprite_rope.set("texture", imported_svg)
		var texture_hint_ok := false
		for info in sprite_rope.get_property_list():
			if info.name == "texture":
				texture_hint_ok = info.type == TYPE_OBJECT and info.hint == PROPERTY_HINT_RESOURCE_TYPE \
					and info.hint_string == "Texture2D"
		check(imported_svg != null and sprite_rope.get("texture") == imported_svg and texture_hint_ok,
			"SpriteRope2DへInspector相当のTexture2D素材を設定できないよ")
		sprite_rope.free()
		# 2D編集Canvasのズーム、ノード拡縮、Retina相当の画面倍率を合成する。
		var zoomed_canvas := Transform2D.IDENTITY.scaled(Vector2(2.0, 3.0))
		var editor_density: Vector2 = svg_plugin.call("svg2d_density", node, zoomed_canvas, 2.0)
		check(editor_density == Vector2(4.0, 6.0),
			"2Dエディターのズームまたは画面倍率を解像度へ反映できないよ: %s" % editor_density)
		node.call("_set_editor_density", editor_density)
		texture = node.call("get_texture")
		check(texture.get_size() == Vector2(400, 600),
			"SVG2Dの編集用画像が実画素密度へ更新されないよ: %s" % texture.get_size())
		node.call("_set_editor_density", Vector2.ZERO)
		texture = node.call("get_texture")
		check(texture.get_size() == Vector2(2048, 2048),
			"2D編集Viewportを失ったとき低解像度キャッシュへ戻ったよ")
		check(svg_plugin.call("svg_rect", node) == Rect2(0, 0, 100, 100), "SVGの編集矩形が自然寸法と違うよ")
		check(svg_plugin.call("_handles", node), "SVG2Dを編集対象として扱っていないよ")
		var transparent_hole: Vector2 = svg_plugin.call("screen_transform", node) * Vector2(70, 70)
		check(svg_plugin.call("pick_svg2d", transparent_hole) == null,
			"SVGの透明な穴までクリック判定になっているよ")
		var center: Vector2 = svg_plugin.call("screen_transform", node) * Vector2(20, 20)
		# EditorPluginの_handles対象になっていない未選択状態から、実際のControl信号で選ぶ。
		EditorInterface.get_selection().clear()
		var initial_press := InputEventMouseButton.new()
		initial_press.button_index = MOUSE_BUTTON_LEFT
		initial_press.pressed = true
		initial_press.position = center
		if canvas_input:
			canvas_input.gui_input.emit(initial_press)
		check(EditorInterface.get_selection().get_selected_nodes().has(node),
			"未選択のSVG2Dを2D編集Viewportのクリックで選択できないよ")
		var initial_release := InputEventMouseButton.new()
		initial_release.button_index = MOUSE_BUTTON_LEFT
		initial_release.position = center
		if canvas_input: canvas_input.gui_input.emit(initial_release)
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = center
		check(svg_plugin.call("_forward_canvas_gui_input", press), "SVGの絵をクリックして選択できないよ")
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = center + Vector2(36, 24)
		svg_plugin.call("_forward_canvas_gui_input", motion)
		var moved_to := node.position
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = motion.position
		svg_plugin.call("_forward_canvas_gui_input", release)
		check(moved_to != Vector2.ZERO and node.position == moved_to, "SVGノードを絵の内側からドラッグ移動できないよ")
		# SVGAnimateの実エディター入力経路で、接点とBezierハンドルを選択・移動する。
		var animate: Node2D = ClassDB.instantiate("SVGAnimate2D")
		animate.set("src", "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'>" \
			+ "<path d='M10 20 C20 5 50 5 60 20 C70 35 75 50 80 70 Z' fill='#fff' stroke='#fff' stroke-width='4'/></svg>")
		scene_root.add_child(animate)
		animate.owner = scene_root
		animate.position = Vector2(137, 83)
		var editor_view2 := EditorInterface.get_editor_viewport_2d()
		var editor_canvas := editor_view2.get_global_canvas_transform()
		check(Transform2D(svg_plugin.call("screen_transform", animate)).is_equal_approx(
			editor_canvas * animate.get_screen_transform()),
			"2Dパスオーバーレイが実描画Viewportのノード変換を使っていないよ")
		# Viewport.canvas_transformでは見えないCanvasItemEditorのパン・ズームを再現する。
		var saved_global_canvas := editor_view2.get_global_canvas_transform()
		var forced_global_canvas := Transform2D(
			Vector2(1.75, 0), Vector2(0, 1.75), Vector2(123, -57))
		editor_view2.set_global_canvas_transform(forced_global_canvas)
		check(Transform2D(svg_plugin.call("screen_transform", animate)).is_equal_approx(
			forced_global_canvas * animate.get_screen_transform()),
			"2Dエディターのパン／ズームをパス点へ反映していないよ")
		editor_view2.set_global_canvas_transform(saved_global_canvas)
		var animate_texture := animate.call("get_texture") as Texture2D
		check(animate_texture != null and animate_texture.get_image().get_used_rect().has_area(),
			"SVGAnimate2Dの編集用画像を描けないよ: size=%s src=%d" %
			[animate.call("get_svg_size"), String(animate.get("src")).length()])
		check(animate_texture.get_image().get_used_rect().size.x > 1000,
			"viewBoxなしSVGが編集用解像度全体へ拡大描画されていないよ: %s" %
			animate_texture.get_image().get_used_rect())
		EditorInterface.get_selection().clear()
		var animate_pick := InputEventMouseButton.new()
		animate_pick.button_index = MOUSE_BUTTON_LEFT
		animate_pick.pressed = true
		var animate_svg_point := Vector2(-1, -1)
		for y in range(0, 100, 5):
			for x in range(0, 100, 5):
				if ShapeUtils.opaque_at(animate, Vector2(x, y)):
					animate_svg_point = Vector2(x, y)
					break
			if animate_svg_point.x >= 0: break
		check(animate_svg_point.x >= 0, "SVGAnimate2Dの表示画素が見つからないよ: image=%s used=%s" %
			[animate_texture.get_size(), animate_texture.get_image().get_used_rect()])
		animate_pick.position = svg_plugin.call("path_screen_2d", animate, animate_svg_point)
		check(svg_plugin.call("pick_svg2d", animate_pick.position) == animate,
			"SVGAnimate2Dの表示画素クリック判定がノードを返さないよ")
		if canvas_input: canvas_input.gui_input.emit(animate_pick)
		check(EditorInterface.get_selection().get_selected_nodes().has(animate),
			"未選択のSVGAnimate2Dを絵のクリックで選択できないよ")
		var animate_pick_release := InputEventMouseButton.new()
		animate_pick_release.button_index = MOUSE_BUTTON_LEFT
		animate_pick_release.position = animate_pick.position
		if canvas_input: canvas_input.gui_input.emit(animate_pick_release)
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(animate)
		var anchor_screen: Vector2 = svg_plugin.call("path_screen_2d", animate, Vector2(60, 20))
		# 描画を4パターン変えても、接点とハンドルの表示・選択位置は固定する。
		var stable_handle2: Vector2 = animate.call("get_in_handle", 0, 1)
		animate.set("animation_interval", 1)
		animate.set("jitter_amount", 0.03)
		animate.set("animation_enabled", true)
		for tick in 4:
			await get_tree().process_frame
			# 選択時のViewport配置変更は追従し、文書内の点だけ固定する。
			var screen_transform2: Transform2D = svg_plugin.call("screen_transform", animate)
			var expected_anchor2 := screen_transform2 * ShapeUtils.displayed_point_2d(animate, Vector2(60, 20))
			var expected_handle2 := screen_transform2 * ShapeUtils.displayed_point_2d(animate, stable_handle2)
			check(Vector2(svg_plugin.call("path_screen_2d", animate, animate.call("get_path_point", 0, 1), 0)).is_equal_approx(expected_anchor2)
				and Vector2(svg_plugin.call("path_screen_2d", animate, animate.call("get_in_handle", 0, 1), 0)).is_equal_approx(expected_handle2),
				"2Dの編集点またはハンドルが揺れた輪郭へ追従したよ")
		animate.set("animation_enabled", false)
		anchor_screen = svg_plugin.call("path_screen_2d", animate, Vector2(60, 20), 0)
		var path_hit: Dictionary = svg_plugin.call("pick_path_control_2d", animate, anchor_screen)
		check(path_hit.path == 0 and path_hit.point == 1 and path_hit.part == "point",
			"2Dパスツールが接点番号を選択できないよ")
		var right_click2 := InputEventMouseButton.new()
		right_click2.button_index = MOUSE_BUTTON_RIGHT
		right_click2.pressed = true
		right_click2.position = anchor_screen
		check(svg_plugin.call("_forward_canvas_gui_input", right_click2)
			and svg_plugin.get("path_index") == 0 and svg_plugin.get("point_index") == 1,
			"2Dパス点の右クリックからキー登録対象を選べないよ")
		svg_plugin.call("_context_key_selected", 0)
		var right_player2 := scene_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		check(right_player2 != null and right_player2.has_animation("svg_path")
			and right_player2.get_animation("svg_path").get_track_count() == 1,
			"2D右クリックのキー登録でAnimationPlayerを自動生成できないよ")
		var decoy := AnimationPlayer.new()
		decoy.name = "CloserButUnrelatedPlayer"
		animate.add_child(decoy)
		decoy.owner = scene_root
		var decoy_library := AnimationLibrary.new()
		decoy_library.add_animation("idle", Animation.new())
		decoy.add_animation_library("", decoy_library)
		decoy.assigned_animation = &"idle"
		check(svg_plugin.call("_find_animation_player", animate) == right_player2,
			"SVG用トラックより近いだけの無関係なAnimationPlayerを選んだよ")
		decoy.free()
		var path_press := InputEventMouseButton.new()
		path_press.button_index = MOUSE_BUTTON_LEFT
		path_press.pressed = true
		path_press.position = anchor_screen
		check(svg_plugin.call("_forward_canvas_gui_input", path_press),
			"2Dパス接点のドラッグを開始できないよ")
		var path_motion := InputEventMouseMotion.new()
		path_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		path_motion.position = anchor_screen + Vector2(12, 8)
		var expected_path_point: Vector2 = svg_plugin.call("screen_transform", animate).affine_inverse() * path_motion.position
		svg_plugin.call("_forward_canvas_gui_input", path_motion)
		var path_release := InputEventMouseButton.new()
		path_release.button_index = MOUSE_BUTTON_LEFT
		path_release.position = path_motion.position
		svg_plugin.call("_forward_canvas_gui_input", path_release)
		check(animate.call("get_path_point", 0, 1).distance_to(expected_path_point) < 0.01
			and animate.call("get_point_count", 0) == 3,
			"接点ドラッグが座標を更新しないかトポロジーを変えたよ")
		var out_handle: Vector2 = animate.call("get_out_handle", 0, 0)
		check(not out_handle.is_equal_approx(Vector2(10, 20)),
			"CコマンドのBezierハンドルを保持していないよ")
		var in_handle: Vector2 = animate.call("get_in_handle", 0, 1)
		var opposite_before: Vector2 = animate.call("get_out_handle", 0, 1)
		var handle_screen: Vector2 = svg_plugin.call("path_screen_2d", animate, in_handle)
		var handle_hit: Dictionary = svg_plugin.call("pick_path_control_2d", animate, handle_screen)
		check(handle_hit.part == "in", "Bezier入ハンドルをクリック選択できないよ")
		var handle_press := InputEventMouseButton.new()
		handle_press.button_index = MOUSE_BUTTON_LEFT
		handle_press.pressed = true
		handle_press.position = handle_screen
		svg_plugin.call("_forward_canvas_gui_input", handle_press)
		var handle_motion := InputEventMouseMotion.new()
		handle_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		handle_motion.position = handle_screen + Vector2(8, -6)
		svg_plugin.call("_forward_canvas_gui_input", handle_motion)
		var handle_release := InputEventMouseButton.new()
		handle_release.button_index = MOUSE_BUTTON_LEFT
		handle_release.position = handle_motion.position
		svg_plugin.call("_forward_canvas_gui_input", handle_release)
		check(not animate.call("get_in_handle", 0, 1).is_equal_approx(in_handle),
			"Bezierハンドルをエディターで移動できないよ")
		var anchor_after: Vector2 = animate.call("get_path_point", 0, 1)
		var in_after: Vector2 = animate.call("get_in_handle", 0, 1)
		var opposite_after: Vector2 = animate.call("get_out_handle", 0, 1)
		check(not opposite_after.is_equal_approx(opposite_before)
			and (in_after - anchor_after).normalized().dot(
				(opposite_after - anchor_after).normalized()) < -0.999,
			"通常ハンドル編集で反対側の滑らかな接線を保っていないよ")
		animate.set("flip_h", true)
		var flipped_screen: Vector2 = svg_plugin.call("path_screen_2d", animate, anchor_after)
		check(Vector2(svg_plugin.call("path_point_from_screen_2d", animate, flipped_screen))
			.distance_to(anchor_after) < 0.01,
			"横反転したSVGAnimate2Dの接点表示とドラッグ座標が一致しないよ")
		animate.set("flip_h", false)
		# viewBox、親group、path自身のtransformが重なっても表示点と逆変換を一致させる。
		var transformed2: Node2D = ClassDB.instantiate("SVGAnimate2D")
		transformed2.set("src", "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='200' " \
			+ "viewBox='10 20 100 50' preserveAspectRatio='none'><g transform='translate(5 3)'>" \
			+ "<path transform='scale(2 1.5)' d='M10 20 L20 25' stroke='white'/></g></svg>")
		transformed2.position = Vector2(91, 47)
		scene_root.add_child(transformed2)
		transformed2.owner = scene_root
		var transformed_screen: Vector2 = svg_plugin.call("path_screen_2d", transformed2, Vector2(10, 20), 0)
		var expected_screen := editor_view2.get_global_canvas_transform() * transformed2.get_screen_transform() * Vector2(36, 52)
		check(transformed_screen.distance_to(expected_screen) < 0.01
			and Vector2(svg_plugin.call("path_point_from_screen_2d", transformed2, transformed_screen, 0))
				.distance_to(Vector2(10, 20)) < 0.01,
			"2DのviewBox/transform適用後の表示とパス点が一致しないよ: %s != %s" %
			[transformed_screen, expected_screen])
		transformed2.free()
		var path_control := SVGPathControl.new()
		# 本番Inspectorと同じく、SceneTreeへ追加される前にsetupされても
		# get_tree()を呼ばず、安全にUIを構築できること。
		path_control.setup(animate)
		check(path_control.call("_plugin") == null,
			"SceneTree追加前のPath EditorがEditorPluginを検索しているよ")
		add_child(path_control)
		check(path_control.get("path_select").item_count == 1
			and int(path_control.get("point_select").max_value) == 2,
			"Inspector Path Editorがパス番号と接点番号を列挙しないよ")
		var mini_key := path_control.find_child("KeySelectedControlButton", true, false) as Button
		var all_button := path_control.get_node_or_null("CreateAllPointsAnimationPlayerButton") as Button
		check(mini_key != null and all_button != null,
			"Inspectorに小型キー追加ボタンと全点AnimationPlayer作成ボタンがないよ")
		svg_plugin.call("select_path_control", animate, 0, 1, "point")
		check(int(path_control.get("point_select").value) == 1,
			"Viewportのパス点選択がInspectorのPoint番号へ同期されないよ")
		check(svg_plugin.call("insert_path_key", animate, 0, 1),
			"接点番号をAnimationPlayerへ登録できないよ")
		var key_player := scene_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var keyed := key_player.get_animation("svg_path") if key_player else null
		check(keyed != null and keyed.get_track_count() == 1
			and String(keyed.track_get_path(0)).ends_with(":paths/path_0/point_1"),
			"接点番号の値トラックがAnimationPlayerへ作られていないよ")
		path_control.get("point_select").value = 1
		path_control.call("_mode_pressed", "in")
		path_control.call("_insert_key")
		check(keyed != null and keyed.get_track_count() == 2
			and String(keyed.track_get_path(1)).ends_with(":paths/path_0/point_1/in_handle"),
			"InspectorのInハンドル選択から値トラックを作れないよ")
		path_control.get("point_select").value = 0
		path_control.call("_mode_pressed", "out")
		path_control.call("_insert_key")
		check(keyed != null and keyed.get_track_count() == 3
			and String(keyed.track_get_path(2)).ends_with(":paths/path_0/point_0/out_handle"),
			"InspectorのOutハンドル選択から値トラックを作れないよ")
		if mini_key: mini_key.pressed.emit()
		check(keyed != null and keyed.get_track_count() == 3,
			"小型キー追加ボタンが選択中のハンドルを登録できないよ")
		if all_button: all_button.pressed.emit()
		var all_player2 := scene_root.get_node_or_null("SVGAllPointsAnimationPlayer") as AnimationPlayer
		var all_animation2 := all_player2.get_animation("all_points") if all_player2 else null
		var expected2: Array = svg_plugin.call("_all_svg_key_properties", animate)
		check(all_player2 != null and all_player2.owner == scene_root
			and all_animation2 != null and all_animation2.get_track_count() == expected2.size(),
			"2D Inspectorから全SVG属性を持つ新規AnimationPlayerノードを作れないよ")
		if all_animation2:
			for property_name in expected2:
				check(all_animation2.find_track(NodePath("%s:%s" % [animate.name, property_name]),
					Animation.TYPE_VALUE) >= 0, "2Dの全属性トラックに%sがないよ" % property_name)
		if all_player2:
			animate.call("flush_paths")
			var before_all2 := hash((animate.call("get_texture") as Texture2D).get_image().get_data())
			all_player2.play("all_points")
			all_player2.pause()
			all_player2.seek(0.0, true)
			animate.call("flush_paths")
			check(before_all2 == hash((animate.call("get_texture") as Texture2D).get_image().get_data()),
				"2D全属性の初期キーが編集済みSVGの見た目を変えたよ")
		svg_plugin.call("_show_path_key_menu", animate,
			{"instance": 0, "path": 0, "point": 1, "part": "point"})
		var menu2: Array = svg_plugin.get("context_properties")
		check(menu2.has("paths/path_0/point_1/in_handle")
			and menu2.has("paths/path_0/fill_color") and menu2.has("paths/path_0/stroke_color")
			and menu2.has("paths/path_0/stroke_width") and menu2.has("modulate") and menu2.has("*"),
			"2D右クリックメニューから曲線・塗り・線・一括キーを選べないよ")
		if menu2.has("paths/path_0/fill_color"):
			svg_plugin.call("_context_key_selected", menu2.find("paths/path_0/fill_color"))
			check(keyed.find_track(NodePath("%s:paths/path_0/fill_color" % animate.name),
				Animation.TYPE_VALUE) >= 0, "2D右クリックで塗り色をキーにできないよ")
		if menu2.has("*"):
			svg_plugin.call("_context_key_selected", menu2.find("*"))
			check(keyed.get_track_count() == expected2.size(),
				"2D右クリックの一括キーで全SVG属性を登録できないよ")
		if all_player2: all_player2.free()
		path_control.free()
		if key_player: key_player.free()
		animate.free()
		# シーン切替でドラッグ対象が先に解放されても、遅い入力処理を安全に破棄する。
		var freed_drag: Node2D = ClassDB.instantiate("SVG2D")
		scene_root.add_child(freed_drag)
		svg_plugin.set("drag_node", freed_drag)
		freed_drag.free()
		svg_plugin.call("finish_drag")
		check(svg_plugin.get("drag_node") == null,
			"解放済みSVG2Dのドラッグ状態が残っているよ")
		var freed_path: Node2D = ClassDB.instantiate("SVGAnimate2D")
		scene_root.add_child(freed_path)
		svg_plugin.set("path_node", freed_path)
		svg_plugin.set("path_dragging", true)
		freed_path.free()
		svg_plugin.call("finish_path_drag")
		check(svg_plugin.get("path_node") == null and not svg_plugin.get("path_dragging"),
			"解放済みSVGAnimate2Dの接点ドラッグ状態が残っているよ")

		# 3D編集カメラはシーンのCamera3Dではない。プラグインがその投影寸法を渡し、
		# エディター表示も自然寸法へ落ちず1.5倍解像度になることを画面操作なしで確かめる。
	var editor_viewport := EditorInterface.get_editor_viewport_3d(0)
	check(editor_viewport != null and editor_viewport.get_camera_3d() != null,
		"3D編集カメラを取得できないよ")
	var test_view := SubViewport.new()
	test_view.size = Vector2i(800, 600)
	add_child(test_view)
	var test_camera := Camera3D.new()
	test_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	test_camera.size = 2.0
	test_camera.position = Vector3(0, 0, 10)
	test_view.add_child(test_camera)
	test_camera.current = true
	if svg_plugin:
		# 初回3D画面がまだ有効でない状態を再現する。
		svg_plugin.set_process(false)
	var node3: Node3D = ClassDB.instantiate("SVG3D")
	node3.set("jitter_amount", 0.0)
	node3.set("src", "res://tests/svg/hello.svg")
	scene_root.add_child(node3)
	node3.owner = scene_root
	node3.set_process(false)
	await get_tree().process_frame
	await get_tree().process_frame
	var initial_texture3: Texture2D = node3.call("get_texture")
	check(initial_texture3 != null and initial_texture3.get_size() == Vector2(2048, 2048),
		"3D編集カメラ初期化前に高精細な暫定画像を作らないよ: %s" %
		(initial_texture3.get_size() if initial_texture3 else Vector2.ZERO))
	if svg_plugin:
		svg_plugin.call("update_svg3d_editor_camera", null)
	await get_tree().process_frame
	check(node3.call("get_texture").get_size() == Vector2(2048, 2048),
		"カメラ未取得通知で暫定画像が低解像度へ戻ったよ")
	test_camera.position = Vector3.ZERO
	if svg_plugin:
		svg_plugin.call("update_svg3d_editor_camera", test_camera)
	await get_tree().process_frame
	await get_tree().process_frame
	check(node3.call("get_texture").get_size() == Vector2(2048, 2048),
		"未初期化の3D編集カメラを低解像度キャッシュとして採用したよ")
	test_camera.position = Vector3(0, 0, 10)
	if svg_plugin:
		svg_plugin.call("update_svg3d_editor_camera", test_camera)
		check(svg_plugin.call("_handles", node3), "SVG3Dを編集対象として扱っていないよ")
		var gizmo_plugin: Object = svg_plugin.get("svg_3d_gizmo")
		check(gizmo_plugin != null and gizmo_plugin.call("_has_gizmo", node3),
			"SVG3DがGodot標準3Dクリック選択用ギズモを持っていないよ")
		node3.update_gizmos()
		await get_tree().process_frame
		var registered_gizmo := false
		for gizmo in node3.get_gizmos():
			if gizmo.get_plugin() == gizmo_plugin:
				registered_gizmo = true
		check(registered_gizmo,
			"SVG3Dクリック選択ギズモが実ノードへ登録されていないよ")
	await get_tree().process_frame
	await get_tree().process_frame
	var texture3: Texture2D = node3.call("get_texture")
	check(texture3 != null and texture3.get_size() == Vector2(450, 450),
		"初回の暫定キャッシュが3Dエディター投影寸法の1.5倍へ更新されないよ: %s" % (texture3.get_size() if texture3 else Vector2.ZERO))
	test_camera.size = 1.0
	if svg_plugin:
		svg_plugin.call("update_svg3d_editor_camera", test_camera)
	await get_tree().process_frame
	await get_tree().process_frame
	texture3 = node3.call("get_texture")
	check(texture3 != null and texture3.get_size() == Vector2(900, 900),
		"3Dエディターで拡大しても解像度が追従しないよ: %s" % (texture3.get_size() if texture3 else Vector2.ZERO))

	# 実際の3D編集入力経路で、不透明画素だけを選び、カメラ面に沿って移動する。
	if svg_plugin:
		var transparent_3d := test_camera.unproject_position(node3.to_global(Vector3(0.2, -0.2, 0.0)))
		check(svg_plugin.call("pick_svg3d", test_camera, transparent_3d).is_empty(),
			"SVG3Dの透明な穴までクリック判定になっているよ")
		var opaque_3d := test_camera.unproject_position(node3.to_global(Vector3(-0.3, 0.3, 0.0)))
		var press3 := InputEventMouseButton.new()
		press3.button_index = MOUSE_BUTTON_LEFT
		press3.pressed = true
		press3.position = opaque_3d
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, press3) == EditorPlugin.AFTER_GUI_INPUT_PASS
			and node3.position == Vector3.ZERO,
			"SVG3Dノード移動を標準3Dギズモではなく独自ドラッグが奪っているよ")
		var animate3: Node3D = ClassDB.instantiate("SVGAnimate3D")
		animate3.set("src", "<svg xmlns='http://www.w3.org/2000/svg' width='240' height='200' " \
			+ "viewBox='10 20 100 50' preserveAspectRatio='none'><g transform='translate(5 3)'>" \
			+ "<path transform='scale(2 1.5)' d='M20 20 C30 5 60 5 70 20 C78 35 80 55 80 80 Z' fill='#fff'/></g></svg>")
		scene_root.add_child(animate3)
		animate3.owner = scene_root
		animate3.position.z = 0.2
		check(svg_plugin.get("svg_3d_gizmo").call("_has_gizmo", animate3),
			"SVGAnimate3Dが標準3D選択ギズモの対象でないよ")
		EditorInterface.get_selection().clear()
		var animate3_inside := test_camera.unproject_position(
			Vector3(svg_plugin.call("svg_world_3d", animate3, Vector2(50, 35), 0)))
		var animate3_press := InputEventMouseButton.new()
		animate3_press.button_index = MOUSE_BUTTON_LEFT
		animate3_press.pressed = true
		animate3_press.position = animate3_inside
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, animate3_press)
			== EditorPlugin.AFTER_GUI_INPUT_PASS,
			"未選択SVGAnimate3Dのクリックを標準選択ギズモへ渡していないよ")
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(animate3)
		var point_world: Vector3 = svg_plugin.call("svg_world_3d", animate3, Vector2(70, 20), 0)
		var stable_handle3: Vector2 = animate3.call("get_in_handle", 0, 1)
		var stable_world3: Vector3 = svg_plugin.call("svg_world_3d", animate3, stable_handle3, 0)
		animate3.set("animation_interval", 1)
		animate3.set("jitter_amount", 0.03)
		animate3.set("animation_enabled", true)
		for tick in 4:
			await get_tree().process_frame
			check(Vector3(svg_plugin.call("svg_world_3d", animate3, animate3.call("get_path_point", 0, 1), 0)).is_equal_approx(point_world)
				and Vector3(svg_plugin.call("svg_world_3d", animate3, animate3.call("get_in_handle", 0, 1), 0)).is_equal_approx(stable_world3),
				"3Dの編集点またはハンドルが揺れた輪郭へ追従したよ")
		animate3.set("animation_enabled", false)
		var transformed_document3 := Vector2(animate3.call("path_to_document", 0, Vector2(70, 20)))
		var expected_world3 := animate3.to_global(ShapeUtils.displayed_point_3d(animate3, transformed_document3))
		check(point_world.distance_to(expected_world3) < 0.0001
			and Vector2(svg_plugin.call("svg_point_from_world_3d", animate3, point_world, 0))
				.distance_to(Vector2(70, 20)) < 0.01,
			"3DのviewBox/transform適用後の表示とパス点が一致しないよ")
		var point_screen := test_camera.unproject_position(point_world)
		var path_hit3: Dictionary = svg_plugin.call("pick_path_control_3d", animate3, test_camera, point_screen)
		check(path_hit3.path == 0 and path_hit3.point == 1,
			"3Dパスツールが接点番号を選択できないよ")
		var right_click3 := InputEventMouseButton.new()
		right_click3.button_index = MOUSE_BUTTON_RIGHT
		right_click3.pressed = true
		right_click3.position = point_screen
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, right_click3)
			== EditorPlugin.AFTER_GUI_INPUT_STOP
			and svg_plugin.get("path_index") == 0 and svg_plugin.get("point_index") == 1,
			"3Dパス点の右クリックからキー登録対象を選べないよ")
		svg_plugin.call("_context_key_selected", 0)
		var right_player3 := scene_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		check(right_player3 != null and right_player3.has_animation("svg_path")
			and right_player3.get_animation("svg_path").get_track_count() == 1,
			"3D右クリックのキー登録でAnimationPlayerを自動生成できないよ")
		var path_press3 := InputEventMouseButton.new()
		path_press3.button_index = MOUSE_BUTTON_LEFT
		path_press3.pressed = true
		path_press3.position = point_screen
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, path_press3)
			== EditorPlugin.AFTER_GUI_INPUT_STOP, "3Dパス接点のドラッグを開始できないよ")
		var stationary_motion3 := InputEventMouseMotion.new()
		stationary_motion3.button_mask = MOUSE_BUTTON_MASK_LEFT
		stationary_motion3.position = point_screen
		svg_plugin.call("_forward_3d_gui_input", test_camera, stationary_motion3)
		check(Vector2(animate3.call("get_path_point", 0, 1)).distance_to(Vector2(70, 20)) < 0.001,
			"3Dパス接点を押しただけで表示位置からずれたよ")
		var path_motion3 := InputEventMouseMotion.new()
		path_motion3.button_mask = MOUSE_BUTTON_MASK_LEFT
		path_motion3.position = point_screen + Vector2(15, 10)
		svg_plugin.call("_forward_3d_gui_input", test_camera, path_motion3)
		var moved_path3: Vector2 = animate3.call("get_path_point", 0, 1)
		var path_release3 := InputEventMouseButton.new()
		path_release3.button_index = MOUSE_BUTTON_LEFT
		path_release3.position = path_motion3.position
		svg_plugin.call("_forward_3d_gui_input", test_camera, path_release3)
		check(not moved_path3.is_equal_approx(Vector2(70, 20))
			and animate3.call("get_point_count", 0) == 3,
			"3D接点ドラッグが座標を更新しないかトポロジーを変えたよ")
		var handle3_before: Vector2 = animate3.call("get_in_handle", 0, 1)
		var handle3_screen: Vector2 = test_camera.unproject_position(
			Vector3(svg_plugin.call("svg_world_3d", animate3, handle3_before, 0)))
		var handle3_press := InputEventMouseButton.new()
		handle3_press.button_index = MOUSE_BUTTON_LEFT
		handle3_press.pressed = true
		handle3_press.position = handle3_screen
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, handle3_press)
			== EditorPlugin.AFTER_GUI_INPUT_STOP, "3D Bezierハンドルをクリック選択できないよ")
		var handle3_motion := InputEventMouseMotion.new()
		handle3_motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		handle3_motion.position = handle3_screen + Vector2(9, -7)
		svg_plugin.call("_forward_3d_gui_input", test_camera, handle3_motion)
		var handle3_release := InputEventMouseButton.new()
		handle3_release.button_index = MOUSE_BUTTON_LEFT
		handle3_release.position = handle3_motion.position
		svg_plugin.call("_forward_3d_gui_input", test_camera, handle3_release)
		check(not animate3.call("get_in_handle", 0, 1).is_equal_approx(handle3_before),
			"SVGAnimate3DのBezierハンドルを移動できないよ")
		animate3.set("flip_v", true)
		var flipped_world3: Vector3 = svg_plugin.call("svg_world_3d", animate3, moved_path3, 0)
		check(Vector2(svg_plugin.call("svg_point_from_world_3d", animate3, flipped_world3, 0))
			.distance_to(moved_path3) < 0.01,
			"縦反転したSVGAnimate3Dの接点表示とドラッグ座標が一致しないよ")
		animate3.set("flip_v", false)
		check(svg_plugin.call("insert_path_key", animate3, 0, 1),
			"SVGAnimate3D接点をAnimationPlayerへ登録できないよ")
		var key_player3 := scene_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var keyed3 := key_player3.get_animation("svg_path") if key_player3 else null
		check(keyed3 != null and String(keyed3.track_get_path(0)).ends_with(":paths/path_0/point_1"),
			"SVGAnimate3D接点番号の値トラックが作られていないよ")
		var path_control3 := SVGPathControl.new()
		path_control3.setup(animate3)
		add_child(path_control3)
		path_control3.get("point_select").value = 1
		var mini_key3 := path_control3.find_child("KeySelectedControlButton", true, false) as Button
		var all_button3 := path_control3.get_node_or_null("CreateAllPointsAnimationPlayerButton") as Button
		if mini_key3: mini_key3.pressed.emit()
		check(mini_key3 != null and keyed3 != null and keyed3.get_track_count() == 1,
			"3D Inspectorの小型キー追加ボタンが接点を登録できないよ")
		if all_button3: all_button3.pressed.emit()
		var all_player3 := scene_root.get_node_or_null("SVGAllPointsAnimationPlayer") as AnimationPlayer
		var all_animation3 := all_player3.get_animation("all_points") if all_player3 else null
		var expected3: Array = svg_plugin.call("_all_svg_key_properties", animate3)
		check(all_button3 != null and all_player3 != null and all_animation3 != null
			and all_animation3.get_track_count() == expected3.size(),
			"3D Inspectorから全SVG属性を持つ新規AnimationPlayerノードを作れないよ")
		if all_animation3:
			for property_name in expected3:
				check(all_animation3.find_track(NodePath("%s:%s" % [animate3.name, property_name]),
					Animation.TYPE_VALUE) >= 0, "3Dの全属性トラックに%sがないよ" % property_name)
		if all_player3:
			animate3.call("flush_paths")
			var before_all3 := hash((animate3.call("get_texture") as Texture2D).get_image().get_data())
			all_player3.play("all_points")
			all_player3.pause()
			all_player3.seek(0.0, true)
			animate3.call("flush_paths")
			check(before_all3 == hash((animate3.call("get_texture") as Texture2D).get_image().get_data()),
				"3D全属性の初期キーがSVGの見た目を変えたよ")
		svg_plugin.call("_show_path_key_menu", animate3,
			{"instance": 0, "path": 0, "point": 1, "part": "point"})
		var menu3: Array = svg_plugin.get("context_properties")
		check(menu3.has("paths/path_0/point_1/in_handle")
			and menu3.has("paths/path_0/fill_color") and menu3.has("paths/path_0/stroke_paint")
			and menu3.has("paths/path_0/fill_opacity") and menu3.has("modulate") and menu3.has("*"),
			"3D右クリックメニューから曲線・塗り・線・一括キーを選べないよ")
		if menu3.has("paths/path_0/fill_color"):
			svg_plugin.call("_context_key_selected", menu3.find("paths/path_0/fill_color"))
			check(keyed3.find_track(NodePath("%s:paths/path_0/fill_color" % animate3.name),
					Animation.TYPE_VALUE) >= 0, "3D右クリックで塗り色をキーにできないよ")
		if menu3.has("*"):
			svg_plugin.call("_context_key_selected", menu3.find("*"))
			check(keyed3.get_track_count() == expected3.size(),
				"3D右クリックの一括キーで全SVG属性を登録できないよ")
		path_control3.free()
		if all_player3: all_player3.free()
		if key_player3: key_player3.free()
		animate3.free()
		# ファイル素材の基本図形も3D編集画面で接点を選べる。
		var shape3: Node3D = ClassDB.instantiate("SVGAnimate3D")
		scene_root.add_child(shape3)
		shape3.owner = scene_root
		var shape_source := SVGSourceProperty.new()
		shape_source.set_object_and_property(shape3, &"src")
		shape_source.property_changed.connect(apply_inspector_change.bind(shape3))
		shape_source.call("_file_selected", "res://tests/svg/hello.svg")
		var shape_paths := SVGPathControl.new()
		shape_paths.setup(shape3)
		check(shape3.get("src") == "res://tests/svg/hello.svg"
			and shape_paths.get("path_select").item_count == 2,
			"InspectorからSVGAnimate3Dへ基本図形SVGを設定しても接点一覧が出ないよ")
		var shape_screen := test_camera.unproject_position(
			Vector3(svg_plugin.call("svg_world_3d", shape3, Vector2(10, 10), 0)))
		var shape_hit: Dictionary = svg_plugin.call("pick_path_control_3d", shape3, test_camera, shape_screen)
		check(shape3.call("get_path_count") == 2 and shape_hit.get("path", -1) == 0
			and shape_hit.get("point", -1) == 0,
			"SVGAnimate3Dがファイル素材の矩形接点をエディターで選択できないよ")
		shape_paths.free()
		shape_source.free()
		shape3.free()

	# InspectorのRect / ShapeがSprite3D等と同じ標準のStaticBody + Collision子ノードを作る。
	# Shapeは穴を無視し、離れた2つの塗りを2つの外周として残す。
	var silhouette_svg := "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'>" \
		+ "<path fill='#fff' fill-rule='evenodd' d='M5 5H55V55H5Z M20 20H40V40H20Z'/>" \
		+ "<rect x='70' y='70' width='20' height='20' fill='#fff'/></svg>"
	var hit_node_2d: Node2D = ClassDB.instantiate("SVG2D")
	hit_node_2d.set("src", silhouette_svg)
	scene_root.add_child(hit_node_2d)
	hit_node_2d.owner = scene_root
	var hitbox_2d := SVGHitboxControl.new()
	add_child(hitbox_2d)
	hitbox_2d.setup(hit_node_2d)
	hitbox_2d.call("_create_rect")
	var rect_area_2d := hit_node_2d.get_node_or_null("SVGRectBody2D") as StaticBody2D
	check(rect_area_2d != null and rect_area_2d.get_child(0) is CollisionShape2D
		and (rect_area_2d.get_child(0) as CollisionShape2D).shape is RectangleShape2D,
		"SVG2D RectがStaticBody2D/CollisionShape2D構成を作らないよ")
	hitbox_2d.call("_create_shape")
	var shape_area_2d := hit_node_2d.get_node_or_null("SVGShapeBody2D") as StaticBody2D
	check(shape_area_2d != null and shape_area_2d.get_child_count() == 2,
		"SVG2D Shapeが穴を除いた2つの外周にならないよ")
	if shape_area_2d:
		for collision in shape_area_2d.get_children():
			check(collision is CollisionPolygon2D and collision.polygon.size() >= 4,
				"SVG2D Shapeの外周ポリゴンが壊れているよ")

	var hit_node_3d: Node3D = ClassDB.instantiate("SVG3D")
	hit_node_3d.set("src", silhouette_svg)
	hit_node_3d.set("offset", Vector2(4, -6))
	scene_root.add_child(hit_node_3d)
	hit_node_3d.owner = scene_root
	await get_tree().process_frame
	var hitbox_3d := SVGHitboxControl.new()
	add_child(hitbox_3d)
	hitbox_3d.setup(hit_node_3d)
	hitbox_3d.call("_create_rect")
	var rect_area_3d := hit_node_3d.get_node_or_null("SVGRectBody3D") as StaticBody3D
	check(rect_area_3d != null and rect_area_3d.get_child(0) is CollisionShape3D
		and (rect_area_3d.get_child(0) as CollisionShape3D).shape is BoxShape3D,
		"SVG3D RectがStaticBody3D/CollisionShape3D構成を作らないよ")
	if rect_area_3d:
		check((rect_area_3d.get_child(0) as CollisionShape3D).position.distance_to(
			Vector3(0.04, -0.06, 0.0)) < 0.0001,
			"SVG3D Rect collision does not follow Sprite3D's Y offset")
	hitbox_3d.call("_create_shape")
	var shape_area_3d := hit_node_3d.get_node_or_null("SVGShapeBody3D") as StaticBody3D
	var shape_collision_3d := shape_area_3d.get_child(0) as CollisionShape3D if shape_area_3d else null
	var concave := shape_collision_3d.shape as ConcavePolygonShape3D if shape_collision_3d else null
	check(concave != null and concave.get_faces().size() > 36,
		"SVG3D Shapeが外周から薄いConcavePolygonShape3Dを作らないよ")
	check(shape_area_3d != null and shape_area_3d.owner == scene_root
		and shape_collision_3d.owner == scene_root,
		"作った3D当たり判定がシーン保存対象になっていないよ")
	if svg_plugin:
		test_nested_transforms_2d(scene_root, svg_plugin)
		test_nested_transforms_3d(scene_root, svg_plugin, test_camera)
		await test_alternate_transform_stack_2d(scene_root, svg_plugin)
		await test_alternate_transform_stack_3d(scene_root, svg_plugin, test_camera)
	hitbox_2d.free()
	hitbox_3d.free()
	if svg_plugin:
		svg_plugin.set_process(true)
	test_view.free()

	property.free()
	if not failed:
		print("SVG Inspectorの試験に通ったよ")
	await get_tree().process_frame
	get_tree().quit(1 if failed else 0)

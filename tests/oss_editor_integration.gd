# symbol参照の描画位置と編集点を、実エディタ上の選択・ドラッグで検証する。
# 責務: Godotの画面変換と手計算した文書座標を独立した期待値にする。
@tool
extends EditorPlugin

var failed := false
var assertions := 0

func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failed = true
		push_error(message)

func _enter_tree() -> void:
	DisplayServer.window_set_position(Vector2i(10000, 10000))
	run.call_deferred()

# 本番プラグインへ画面上のマウスイベントを渡す。
func input(plugin: Node, camera: Camera3D, event: InputEvent) -> Variant:
	if camera: return plugin.call("_forward_3d_gui_input", camera, event)
	return plugin.call("_forward_canvas_gui_input", event)

func run() -> void:
	await get_tree().create_timer(1).timeout
	get_tree().create_timer(4.5).timeout.connect(func(): push_error("OSS editor timeout"); get_tree().quit(2))
	var plugin := get_tree().get_first_node_in_group("svg2d_editor_plugin")
	check(plugin != null, "SVG editor plugin missing")
	if not plugin:
		get_tree().quit(1)
		return
	var root := Node2D.new()
	root.name = "SymbolIntegration"
	EditorInterface.add_root_node(root)
	for dim in ["2D", "3D"]:
		var dim2: bool = dim == "2D"
		var node: Node = ClassDB.instantiate("SVGAnimate" + dim)
		node.name = "Artwork" + dim
		node.set("adaptive", false)
		node.set("animation_enabled", false)
		node.set("src", "res://tests/svg/integration/symbol.svg")
		root.add_child(node)
		node.owner = root
		if dim2:
			node.position = Vector2(400, 300)
			node.scale = Vector2(20, 20)
		else:
			node.set("pixel_size", 0.01)
		EditorInterface.set_main_screen_editor(dim)
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(node)
		await get_tree().process_frame
		var camera: Camera3D = null
		if not dim2: camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
		await capture(dim + "-before", camera)
		var screen: Vector2
		var target: Vector2
		# 元の点(12,0)へ、useの(8,8)、symbolの(4,0)、viewBoxの2倍を適用。
		if dim2:
			var canvas := EditorInterface.get_editor_viewport_2d().get_global_canvas_transform()
			var transform: Transform2D = canvas * node.transform
			screen = transform * Vector2(36, 8)
			target = transform * Vector2(32, 12)
			check(Vector2(plugin.call("path_screen_2d", node, Vector2(12, 0), 0)).distance_to(screen) < 0.2,
				"2D symbol point does not overlay rendered corner")
		else:
			camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
			camera.position = Vector3(0, 0, 0.9)
			camera.look_at(Vector3.ZERO)
			screen = camera.unproject_position(Vector3(0.04, 0.16, 0))
			target = camera.unproject_position(Vector3(0, 0.12, 0))
		var hit: Dictionary = plugin.call("pick_path_control_2d", node, screen) if dim2 else plugin.call("pick_path_control_3d", node, camera, screen)
		check(not hit.is_empty() and hit.point == 1 and hit.path == 0 and hit.part == "point",
			dim + " symbol corner is not selectable: " + str(hit))
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.position = screen
		var accepted = input(plugin, camera, press)
		check(bool(accepted) if dim2 else accepted == EditorPlugin.AFTER_GUI_INPUT_STOP, dim + " symbol press rejected")
		var motion := InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = screen
		input(plugin, camera, motion)
		check(Vector2(node.call("get_path_point", 0, 1)).distance_to(Vector2(12, 0)) < 0.01,
			dim + " stationary drag jumped")
		motion = InputEventMouseMotion.new()
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.position = target
		input(plugin, camera, motion)
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.position = target
		input(plugin, camera, release)
		check(Vector2(node.call("get_path_point", 0, 1)).distance_to(Vector2(10, 2)) < 0.01,
			dim + " symbol drag reached wrong source coordinate: " + str(node.call("get_path_point", 0, 1)))
		await capture(dim + "-after", camera)
	print("OSS editor integration: %d assertions, %s" % [assertions, "FAILED" if failed else "PASSED"])
	get_tree().quit(1 if failed else 0)

# 点の重なりと編集後の形を確認できるよう、実エディタの表示を保存する。
func capture(label: String, camera: Camera3D) -> void:
	if camera:
		RenderingServer.frame_pre_draw.connect(func():
			camera.position = Vector3(0, 0, 0.9)
			camera.look_at(Vector3.ZERO), CONNECT_ONE_SHOT)
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := EditorInterface.get_base_control().get_viewport().get_texture().get_image()
	check(image != null and not image.is_empty(), label + " editor image missing")
	if image:
		check(image.save_png(OS.get_environment("SVG2D_VISUAL_OUTPUT").path_join(label + ".png")) == OK,
			label + " editor capture failed")

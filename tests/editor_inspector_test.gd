# 実エディター内で Inspector の src 選択とキャンバス選択面を確かめる。
@tool
extends EditorPlugin

const SVGSourceProperty = preload("res://addons/svg2d/editor/svg_source_property.gd")

var failed := false

func check(ok: bool, message: String) -> void:
	if ok:
		return
	failed = true
	push_error(message)

func apply_inspector_change(
		property: StringName,
		value: Variant,
		_field: StringName,
		_changing: bool,
		node: Object
) -> void:
	node.set(property, value)

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
	check(texture != null and texture.get_size() == Vector2(100, 100), "Inspectorで選んだSVGが表示用画像にならないよ")

	# FILEヒントでシーン保存時に変換されるuid://も同じ素材として読めること。
	var uid := ResourceUID.path_to_uid("res://tests/svg/hello.svg")
	check(uid.begins_with("uid://"), "SVG素材のUIDを取得できないよ")
	node.set("src", uid)
	texture = node.call("get_texture")
	check(texture != null and texture.get_size() == Vector2(100, 100), "uid://のSVG素材を表示できないよ")

	# 本番EditorPluginへマウス入力を渡し、絵の内側をつかんで移動できること。
	var svg_plugin := get_tree().get_first_node_in_group("svg2d_editor_plugin")
	check(svg_plugin != null, "SVG2Dの2D編集プラグインが動いていないよ")
	if svg_plugin:
		check(svg_plugin.call("svg_rect", node) == Rect2(0, 0, 100, 100), "SVGの編集矩形が自然寸法と違うよ")
		var center: Vector2 = svg_plugin.call("screen_transform", node) * Vector2(50, 50)
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
	var node3: Node3D = ClassDB.instantiate("SVG3D")
	node3.set("jitter_amount", 0.0)
	node3.set("src", "res://tests/svg/hello.svg")
	scene_root.add_child(node3)
	node3.owner = scene_root
	if svg_plugin:
		svg_plugin.set_process(false)
		svg_plugin.call("update_svg3d_editor_camera", test_camera)
	await get_tree().process_frame
	await get_tree().process_frame
	var texture3: Texture2D = node3.call("get_texture")
	check(texture3 != null and texture3.get_size() == Vector2(450, 450),
		"3Dエディター投影寸法の1.5倍で画像化されないよ: %s" % (texture3.get_size() if texture3 else Vector2.ZERO))
	test_camera.size = 1.0
	if svg_plugin:
		svg_plugin.call("update_svg3d_editor_camera", test_camera)
	await get_tree().process_frame
	await get_tree().process_frame
	texture3 = node3.call("get_texture")
	check(texture3 != null and texture3.get_size() == Vector2(900, 900),
		"3Dエディターで拡大しても解像度が追従しないよ: %s" % (texture3.get_size() if texture3 else Vector2.ZERO))
	if svg_plugin:
		svg_plugin.set_process(true)
	test_view.free()

	property.free()
	if not failed:
		print("SVG Inspectorの試験に通ったよ")
	await get_tree().process_frame
	get_tree().quit(1 if failed else 0)

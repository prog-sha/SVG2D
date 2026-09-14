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

	property.free()
	if not failed:
		print("SVG Inspectorの試験に通ったよ")
	await get_tree().process_frame
	get_tree().quit(1 if failed else 0)

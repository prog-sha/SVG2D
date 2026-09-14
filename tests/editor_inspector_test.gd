# 実エディター内で Inspector の src 選択とキャンバス選択面を確かめる。
@tool
extends EditorPlugin

const SVGSourceProperty = preload("res://addons/svg2d/editor/svg_source_property.gd")
const SVGHitboxControl = preload("res://addons/svg2d/editor/svg_hitbox_control.gd")

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
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, press3) == EditorPlugin.AFTER_GUI_INPUT_STOP,
			"SVG3Dの絵をクリックして選択できないよ")
		var motion3 := InputEventMouseMotion.new()
		motion3.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion3.position = opaque_3d + Vector2(48, 30)
		svg_plugin.call("_forward_3d_gui_input", test_camera, motion3)
		var moved3 := node3.position
		var release3 := InputEventMouseButton.new()
		release3.button_index = MOUSE_BUTTON_LEFT
		release3.position = motion3.position
		svg_plugin.call("_forward_3d_gui_input", test_camera, release3)
		check(moved3 != Vector3.ZERO and node3.position == moved3,
			"SVG3Dを不透明画素からドラッグ移動できないよ")

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
	hitbox_3d.call("_create_shape")
	var shape_area_3d := hit_node_3d.get_node_or_null("SVGShapeBody3D") as StaticBody3D
	var shape_collision_3d := shape_area_3d.get_child(0) as CollisionShape3D if shape_area_3d else null
	var concave := shape_collision_3d.shape as ConcavePolygonShape3D if shape_collision_3d else null
	check(concave != null and concave.get_faces().size() > 36,
		"SVG3D Shapeが外周から薄いConcavePolygonShape3Dを作らないよ")
	check(shape_area_3d != null and shape_area_3d.owner == scene_root
		and shape_collision_3d.owner == scene_root,
		"作った3D当たり判定がシーン保存対象になっていないよ")
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

# 実エディター内で Inspector の src 選択とキャンバス選択面を確かめる。
@tool
extends EditorPlugin

const SVGSourceProperty = preload("res://addons/svg2d/editor/svg_source_property.gd")
const SVGHitboxControl = preload("res://addons/svg2d/editor/svg_hitbox_control.gd")
const SVGPathControl = preload("res://addons/svg2d/editor/svg_path_control.gd")
const ShapeUtils = preload("res://addons/svg2d/editor/svg_shape_utils.gd")

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
		await get_tree().process_frame
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
		check(Transform2D(svg_plugin.call("screen_transform", animate)).is_equal_approx(
			animate.get_global_transform_with_canvas()),
			"2Dパスオーバーレイが実描画Viewportのノード変換を使っていないよ")
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
		var path_hit: Dictionary = svg_plugin.call("pick_path_control_2d", animate, anchor_screen)
		check(path_hit.path == 0 and path_hit.point == 1 and path_hit.part == "point",
			"2Dパスツールが接点番号を選択できないよ")
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
		var expected_screen := transformed2.get_global_transform_with_canvas() * Vector2(36, 52)
		check(transformed_screen.distance_to(expected_screen) < 0.01
			and Vector2(svg_plugin.call("path_point_from_screen_2d", transformed2, transformed_screen, 0))
				.distance_to(Vector2(10, 20)) < 0.01,
			"2DのviewBox/transform適用後の表示とパス点が一致しないよ: %s != %s" %
			[transformed_screen, expected_screen])
		transformed2.free()
		var path_control := SVGPathControl.new()
		add_child(path_control)
		path_control.setup(animate)
		check(path_control.get("path_select").item_count == 1
			and int(path_control.get("point_select").max_value) == 2,
			"Inspector Path Editorがパス番号と接点番号を列挙しないよ")
		check(svg_plugin.call("insert_path_key", animate, 0, 1),
			"接点番号をAnimationPlayerへ登録できないよ")
		var key_player := scene_root.get_node_or_null("AnimationPlayer") as AnimationPlayer
		var keyed := key_player.get_animation("svg_path") if key_player else null
		check(keyed != null and keyed.get_track_count() == 1
			and String(keyed.track_get_path(0)).ends_with(":paths/path_0/point_1"),
			"接点番号の値トラックがAnimationPlayerへ作られていないよ")
		path_control.free()
		if key_player: key_player.free()
		animate.free()

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
			== EditorPlugin.AFTER_GUI_INPUT_STOP
			and EditorInterface.get_selection().get_selected_nodes().has(animate3),
			"未選択のSVGAnimate3Dを絵のクリックで選択できないよ")
		var animate3_release := InputEventMouseButton.new()
		animate3_release.button_index = MOUSE_BUTTON_LEFT
		animate3_release.position = animate3_inside
		svg_plugin.call("_forward_3d_gui_input", test_camera, animate3_release)
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(animate3)
		var point_world: Vector3 = svg_plugin.call("svg_world_3d", animate3, Vector2(70, 20), 0)
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
		var path_press3 := InputEventMouseButton.new()
		path_press3.button_index = MOUSE_BUTTON_LEFT
		path_press3.pressed = true
		path_press3.position = point_screen
		check(svg_plugin.call("_forward_3d_gui_input", test_camera, path_press3)
			== EditorPlugin.AFTER_GUI_INPUT_STOP, "3Dパス接点のドラッグを開始できないよ")
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
		if key_player3: key_player3.free()
		animate3.free()

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

# 実エディタでSVGの表示、編集点、アニメーション結果を保存・検証する。
# 責務: 素材の画素と選択中の画面を同じ時点で比較できる証拠を残す。
@tool
extends EditorPlugin
const TransformFixture = preload("res://tests/editor_transform_fixture.gd")
const STICKMAN := "res://examples/stickman/stickman.svg" # 多段変換とカメラ移動へ渡す実素材

# 隔離したエディタで素材を開き、接点の選択と再生位置の変更を撮影する。
func _enter_tree() -> void:
	_capture.call_deferred()

func _capture() -> void:
	await get_tree().create_timer(1.5).timeout
	var output_dir := OS.get_environment("SVG2D_VISUAL_OUTPUT")
	if output_dir.is_empty():
		push_error("SVG2D_VISUAL_OUTPUT is required")
		get_tree().quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	await _capture_transform_fixture(output_dir)
	await _capture_scene("res://examples/stickman/stickman_movie.tscn", "Stickman", "2D",
		[0.0, 0.5], "editor-2d", output_dir)
	await _capture_scene("res://examples/stickman/stickman_movie_3d.tscn", "Stickman3D", "3D",
		[0.0, 0.5], "editor-3d", output_dir)
	print("SVG editor visual capture complete: ", output_dir)
	get_tree().quit()

# 指定したパス値を再生時刻へ登録する。
func _track(animation: Animation, path: String, first: Variant, last: Variant) -> void:
	var index := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(index, NodePath(path))
	animation.track_insert_key(index, 0.0, first)
	animation.track_insert_key(index, 0.5, last)

# 腕の点、頭の2点の曲線ハンドル、頭の面色・線色を同時に動かす。
func _add_point_animation(root: Node, svg: Node, player_name: String) -> AnimationPlayer:
	var player := AnimationPlayer.new()
	player.name = player_name
	root.add_child(player)
	player.owner = root
	var animation := Animation.new()
	animation.length = 1.0
	var prefix := String(root.get_path_to(svg)) + ":paths/"
	_track(animation, prefix + "path_2/point_1", Vector2(91, 184), Vector2(72, 126))
	_track(animation, prefix + "path_0/point_1/in_handle", Vector2(198, 64), Vector2(188, 64))
	_track(animation, prefix + "path_0/point_1/out_handle", Vector2(198, 105), Vector2(208, 105))
	_track(animation, prefix + "path_0/point_3/in_handle", Vector2(122, 105), Vector2(132, 105))
	_track(animation, prefix + "path_0/point_3/out_handle", Vector2(122, 64), Vector2(112, 64))
	_track(animation, prefix + "path_0/fill_color", Color("#ffd166"), Color("#95e1ff"))
	_track(animation, prefix + "path_0/stroke_color", Color("#171a2b"), Color("#44236c"))
	var library := AnimationLibrary.new()
	library.add_animation("point_edit", animation)
	player.add_animation_library("", library)
	return player

# 実エディタの描画座標で接点・ハンドルを選べることを確かめる。
func _check_pick(plugin: Node, svg: Node, workspace: String, camera: Camera3D,
		path: int, point: int, part: String, value: Vector2) -> void:
	var screen: Vector2 = plugin.call("path_screen_2d", svg, value, path) if workspace == "2D" \
		else camera.unproject_position(plugin.call("svg_world_3d", svg, value, path))
	var hit: Dictionary = plugin.call("pick_path_control_2d", svg, screen) if workspace == "2D" \
		else plugin.call("pick_path_control_3d", svg, camera, screen)
	if hit.is_empty() or hit.path != path or hit.point != point or hit.part != part:
		push_error("Nested stickman %s %d:%d %s cannot be picked: %s" % [workspace, path, point, part, hit])

# 頭部の透明度だけを抽出し、色変更とは独立に輪郭変化を確認する。
func _head_alpha(image: Image) -> PackedByteArray:
	var ratio := Vector2(image.get_size()) / Vector2(320, 360)
	var head := image.get_region(Rect2i(Vector2i(Vector2(115, 25) * ratio),
		Vector2i(Vector2(110, 100) * ratio)))
	head.convert(Image.FORMAT_RGBA8)
	var pixels := head.get_data()
	var alpha := PackedByteArray()
	for index in range(3, pixels.size(), 4):
		alpha.append(pixels[index])
	return alpha

func _capture_transform_fixture(output_dir: String) -> void:
	var root := Node2D.new()
	root.name = "MultilevelTransformFixture"
	# 座標変換の階層を保ちながら、2D画面の見える位置へ置く。
	root.position = Vector2(490, -130)
	root.scale = Vector2(2.4, 2.4)
	EditorInterface.add_root_node(root)
	var fixture2: Dictionary = TransformFixture.create_2d(root, root, STICKMAN)
	var fixture3: Dictionary = TransformFixture.create_3d(root, root, STICKMAN)
	var svg2: Node2D = fixture2.svg
	var svg3: Node3D = fixture3.svg
	svg2.set("adaptive", false)
	svg3.set("adaptive", false)
	await get_tree().process_frame
	# 多段変換のノードに読み込まれた棒人間の色と透明部分を確かめる。
	for svg in [svg2, svg3]:
		var texture: Texture2D = svg.call("get_texture")
		if texture == null:
			push_error("Editor fixture SVG texture is missing: " + svg.name)
			continue
		var image := texture.get_image()
		if image.get_width() < 320 or image.get_height() < 360:
			push_error("Editor fixture SVG has wrong dimensions: " + str(image.get_size()))
			continue
		_inspect_stickman(image, svg.name)
		if svg == svg2:
			var preview := image.duplicate() as Image
			if preview.save_png(output_dir.path_join("fixture-source.png")) != OK:
				push_error("Cannot save editor fixture SVG preview")
	var player2 := _add_point_animation(root, svg2, "PointAnimation2D")
	var player3 := _add_point_animation(root, svg3, "PointAnimation3D")
	svg2.scale = Vector2(0.65, 1.85)
	svg2.set("flip_h", true)
	svg3.scale = Vector3(0.65, 1.85, 0.8)
	svg3.set("flip_h", true)
	for workspace in ["2D", "3D"]:
		EditorInterface.set_main_screen_editor(workspace)
		var svg: Node = svg2 if workspace == "2D" else svg3
		var player: AnimationPlayer = player2 if workspace == "2D" else player3
		var plugin := get_tree().get_first_node_in_group("svg2d_editor_plugin")
		if plugin == null or svg.get_parent().name != "Inner" + workspace:
			push_error("Stickman is not inside the editor transform hierarchy in " + workspace)
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(svg)
		var first_pixels := PackedByteArray()
		var first_head_alpha := PackedByteArray()
		var first_camera := Vector3.ZERO
		for index in 2:
			var camera: Camera3D = null
			if workspace == "3D":
				camera = EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
				var focus := svg3.global_position
				camera.position = focus + (Vector3(-3, 1.5, 7) if index == 0 else Vector3(2, -1, 6))
				camera.look_at(focus + Vector3(0, 0.1, 0), Vector3.UP)
				if index == 0:
					first_camera = camera.position
				elif camera.position.distance_to(first_camera) < 0.1:
					push_error("3D editor camera did not move between stickman frames")
			player.play("point_edit")
			player.seek(0.5 * index, true)
			player.pause()
			await get_tree().create_timer(0.6).timeout
			var want := Vector2(91, 184) if index == 0 else Vector2(72, 126)
			if Vector2(svg.call("get_path_point", 2, 1)).distance_to(want) > 0.01:
				push_error("Editor animation point did not reach frame %d in %s" % [index, workspace])
			var handles := [
				{"point": 1, "in": Vector2(198, 64) if index == 0 else Vector2(188, 64),
					"out": Vector2(198, 105) if index == 0 else Vector2(208, 105)},
				{"point": 3, "in": Vector2(122, 105) if index == 0 else Vector2(132, 105),
					"out": Vector2(122, 64) if index == 0 else Vector2(112, 64)},
			]
			for entry in handles:
				for part in ["in", "out"]:
					var value: Vector2 = entry[part]
					if Vector2(svg.call("get_%s_handle" % part, 0, entry.point)).distance_to(value) > 0.01:
						push_error("Stickman head %d %s handle missed frame %d in %s" % [entry.point, part, index, workspace])
			var fill := Color("#ffd166") if index == 0 else Color("#95e1ff")
			var stroke := Color("#171a2b") if index == 0 else Color("#44236c")
			if not Color(svg.get("paths/path_0/fill_color")).is_equal_approx(fill) \
					or not Color(svg.get("paths/path_0/stroke_color")).is_equal_approx(stroke):
				push_error("Stickman head fill/stroke missed frame %d in %s" % [index, workspace])
			if plugin:
				_check_pick(plugin, svg, workspace, camera, 2, 1, "point", want)
				for entry in handles:
					for part in ["in", "out"]:
						_check_pick(plugin, svg, workspace, camera, 0, entry.point, part, entry[part])
				plugin.call("select_path_control", svg, 0, 1 if index == 0 else 3, "in")
			var rendered: Image = svg.call("get_texture").get_image()
			var ratio := Vector2(rendered.get_size()) / Vector2(320, 360)
			var center := rendered.get_pixelv(Vector2i(Vector2(160, 80) * ratio))
			var border := rendered.get_pixelv(Vector2i(Vector2(160, 45) * ratio))
			if center.a < 0.98 or border.a < 0.98 \
					or maxf(absf(center.r - fill.r), maxf(absf(center.g - fill.g), absf(center.b - fill.b))) > 0.05 \
					or maxf(absf(border.r - stroke.r), maxf(absf(border.g - stroke.g), absf(border.b - stroke.b))) > 0.05:
				push_error("Stickman head fill/stroke pixels missed frame %d in %s: %s %s" % [index, workspace, center, border])
			var head_alpha := _head_alpha(rendered)
			if index == 0:
				first_pixels = rendered.get_data()
				first_head_alpha = head_alpha
			elif first_pixels == rendered.get_data():
				push_error("Editor animation did not change SVG pixels in " + workspace)
			elif first_head_alpha == head_alpha:
				push_error("Stickman head curve did not follow its animated handle in " + workspace)
			if rendered.save_png(output_dir.path_join("fixture-render-%s-%d.png" % [workspace.to_lower(), index])) != OK:
				push_error("Cannot save editor animation SVG preview")
			_save_editor_frame(output_dir.path_join("transform-%s-%d.png" % [workspace.to_lower(), index]))
			if index == 0:
				# 中間時刻では、色と複数点のハンドルが線形に変わることを調べる。
				player.seek(0.25, true)
				await get_tree().process_frame
				var middle_fill := Color("#ffd166").lerp(Color("#95e1ff"), 0.5)
				var middle_stroke := Color("#171a2b").lerp(Color("#44236c"), 0.5)
				var fill_value: Color = svg.get("paths/path_0/fill_color")
				var stroke_value: Color = svg.get("paths/path_0/stroke_color")
				if maxf(absf(fill_value.r - middle_fill.r),
						maxf(absf(fill_value.g - middle_fill.g), absf(fill_value.b - middle_fill.b))) > 0.02 \
						or maxf(absf(stroke_value.r - middle_stroke.r),
						maxf(absf(stroke_value.g - middle_stroke.g), absf(stroke_value.b - middle_stroke.b))) > 0.02 \
						or Vector2(svg.call("get_in_handle", 0, 1)).distance_to(Vector2(193, 64)) > 0.01 \
						or Vector2(svg.call("get_out_handle", 0, 3)).distance_to(Vector2(117, 64)) > 0.01:
					push_error("Stickman colors or multiple handles did not interpolate in " + workspace)
				var middle: Image = svg.call("get_texture").get_image()
				var middle_ratio := Vector2(middle.get_size()) / Vector2(320, 360)
				var middle_pixel := middle.get_pixelv(Vector2i(Vector2(160, 80) * middle_ratio))
				if maxf(absf(middle_pixel.r - middle_fill.r),
						maxf(absf(middle_pixel.g - middle_fill.g), absf(middle_pixel.b - middle_fill.b))) > 0.05:
					push_error("Stickman fill pixel did not interpolate in " + workspace)
		svg.set("flip_v", true)
		if workspace == "3D":
			var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
			var focus := svg3.global_position
			camera.position = focus + Vector3(-2, -2, 7)
			camera.look_at(focus + Vector3(-0.02, 0.03, 0), Vector3.UP)
		await get_tree().create_timer(0.6).timeout
		if not svg.get("flip_h") or not svg.get("flip_v"):
			push_error("Nested stickman did not retain both flips in " + workspace)
		if plugin:
			var camera: Camera3D = EditorInterface.get_editor_viewport_3d(0).get_camera_3d() if workspace == "3D" else null
			_check_pick(plugin, svg, workspace, camera, 2, 1, "point", Vector2(72, 126))
			for entry in [
				{"point": 1, "in": Vector2(188, 64), "out": Vector2(208, 105)},
				{"point": 3, "in": Vector2(132, 105), "out": Vector2(112, 64)},
			]:
				for part in ["in", "out"]:
					_check_pick(plugin, svg, workspace, camera, 0, entry.point, part, entry[part])
		_save_editor_frame(output_dir.path_join("transform-%s-both-flips.png" % workspace.to_lower()))
	print("Nested stickman 2D/3D: two handle points, fill/stroke, camera move and flips passed")

func _capture_scene(scene_path: String, node_name: String, workspace: String,
		times: Array, prefix: String, output_dir: String) -> void:
	EditorInterface.open_scene_from_path(scene_path)
	await get_tree().create_timer(1.0).timeout
	EditorInterface.set_main_screen_editor(workspace)
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_error("Cannot open editor scene: " + scene_path)
		return
	var svg := root.get_node_or_null(node_name)
	var player := root.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if svg == null or player == null:
		push_error("Editor scene is missing SVG or AnimationPlayer: " + scene_path)
		return
	if svg.get("src") != "res://examples/stickman/stickman.svg" or svg.call("get_path_count") != 6:
		push_error("Editor scene did not load the six-path stickman SVG: " + scene_path)
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(svg)
	if workspace == "3D":
		var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
		if camera:
			camera.position = Vector3(0.9, 0.25, 3.8)
			camera.look_at(Vector3(0, 0.35, 0), Vector3.UP)
	var first_pixels := PackedByteArray()
	for index in times.size():
		player.play(player.autoplay)
		player.seek(float(times[index]), true)
		player.pause()
		await get_tree().create_timer(0.6).timeout
		var want := Vector2(91, 184) if index == 0 else (Vector2(72, 126) if workspace == "2D" else Vector2(75, 139))
		if Vector2(svg.call("get_path_point", 2, 1)).distance_to(want) > 0.01:
			push_error("Stickman arm did not reach frame %d in %s" % [index, workspace])
		var texture: Texture2D = svg.call("get_texture")
		if texture == null:
			push_error("Stickman SVG texture is missing in " + workspace)
			continue
		var rendered := texture.get_image()
		if index == 0:
			_inspect_stickman(rendered, workspace)
			first_pixels = rendered.get_data()
		elif first_pixels == rendered.get_data():
			push_error("Stickman SVG pixels did not animate in " + workspace)
		if rendered.save_png(output_dir.path_join("stickman-render-%s-%d.png" % [workspace.to_lower(), index])) != OK:
			push_error("Cannot save stickman SVG pixels in " + workspace)
		_save_editor_frame(output_dir.path_join("%s-%d.png" % [prefix, index]))

# 頭・胴・左右の手足を別々の色として読み、白い単純図形だけでは通らないようにする。
func _inspect_stickman(image: Image, workspace: String) -> void:
	var scale := Vector2(image.get_size()) / Vector2(320, 360)
	for sample in [
		{"point": Vector2(160, 80), "color": Color("#ffd166")},
		{"point": Vector2(160, 175), "color": Color("#f7f7ff")},
		{"point": Vector2(126, 158), "color": Color("#54d6ff")},
		{"point": Vector2(195, 158), "color": Color("#ff5d8f")},
	]:
		var point := Vector2i(Vector2(sample.point) * scale)
		var actual := image.get_pixelv(point)
		if maxf(absf(actual.r - sample.color.r), maxf(absf(actual.g - sample.color.g), absf(actual.b - sample.color.b))) > 0.08 or actual.a < 0.98:
			push_error("Stickman %s SVG pixel %s: expected %s, got %s" % [workspace, point, sample.color, actual])
	if image.get_pixelv(Vector2i(Vector2(10, 10) * scale)).a > 0.01:
		push_error("Stickman SVG transparent margin is missing in " + workspace)

func _save_editor_frame(path: String) -> void:
	var viewport := EditorInterface.get_base_control().get_viewport()
	var image := viewport.get_texture().get_image() if viewport.get_texture() else null
	if image == null or image.is_empty():
		image = DisplayServer.screen_get_image()
	if image == null or image.is_empty():
		push_error("Cannot capture editor image: " + path)
		return
	var error := image.save_png(path)
	if error != OK:
		push_error("Cannot save editor image: " + path)
	else:
		print("Captured ", path, " size=", image.get_size())

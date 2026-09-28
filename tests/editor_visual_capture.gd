@tool
extends EditorPlugin
const TransformFixture = preload("res://tests/editor_transform_fixture.gd")

# Run only in an isolated editor project. Capture the real editor window after
# opening a scene, selecting its SVG path node and seeking its AnimationPlayer.
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
	if OS.get_environment("SVG2D_VISUAL_TRANSFORM_ONLY") != "1":
		await _capture_scene("res://examples/stickman/stickman_movie.tscn", "Stickman", "2D",
			[0.0, 0.5], "editor-2d", output_dir)
		await _capture_scene("res://examples/stickman/stickman_movie_3d.tscn", "Stickman3D", "3D",
			[0.0, 0.5], "editor-3d", output_dir)
	print("SVG editor visual capture complete: ", output_dir)
	get_tree().quit()

func _add_point_animation(root: Node, svg: Node, player_name: String) -> AnimationPlayer:
	var player := AnimationPlayer.new()
	player.name = player_name
	root.add_child(player)
	player.owner = root
	var animation := Animation.new()
	animation.length = 1.0
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track,
		NodePath(String(root.get_path_to(svg)) + ":paths/path_0/point_1"))
	animation.track_insert_key(track, 0.0, Vector2(72, 20))
	animation.track_insert_key(track, 0.5, Vector2(56, 36))
	var library := AnimationLibrary.new()
	library.add_animation("point_edit", animation)
	player.add_animation_library("", library)
	return player

func _capture_transform_fixture(output_dir: String) -> void:
	var root := Node2D.new()
	root.name = "MultilevelTransformFixture"
	# Keep the exact test hierarchy; this extra root transform only frames it in 2D.
	root.position = Vector2(490, -130)
	root.scale = Vector2(2.4, 2.4)
	EditorInterface.add_root_node(root)
	var fixture2: Dictionary = TransformFixture.create_2d(root, root)
	var fixture3: Dictionary = TransformFixture.create_3d(root, root)
	var svg2: Node2D = fixture2.svg
	var svg3: Node3D = fixture3.svg
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
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(svg)
		if workspace == "3D":
			var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
			var focus := svg3.global_position
			camera.position = focus + Vector3(-0.6, 0.35, 1.8)
			camera.look_at(focus + Vector3(0.03, -0.02, 0), Vector3.UP)
		for index in 2:
			player.play("point_edit")
			player.seek(0.5 * index, true)
			player.pause()
			await get_tree().create_timer(0.6).timeout
			_save_editor_frame(output_dir.path_join("transform-%s-%d.png" % [workspace.to_lower(), index]))
		svg.set("flip_v", true)
		if workspace == "3D":
			var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
			var focus := svg3.global_position
			camera.position = focus + Vector3(0.3, -0.6, 2.0)
			camera.look_at(focus + Vector3(-0.02, 0.03, 0), Vector3.UP)
		await get_tree().create_timer(0.6).timeout
		_save_editor_frame(output_dir.path_join("transform-%s-both-flips.png" % workspace.to_lower()))

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
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(svg)
	if workspace == "3D":
		var camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
		if camera:
			camera.position = Vector3(0.9, 0.25, 3.8)
			camera.look_at(Vector3(0, 0.35, 0), Vector3.UP)
	for index in times.size():
		player.play(player.autoplay)
		player.seek(float(times[index]), true)
		player.pause()
		await get_tree().create_timer(0.6).timeout
		_save_editor_frame(output_dir.path_join("%s-%d.png" % [prefix, index]))

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

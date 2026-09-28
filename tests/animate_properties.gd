# SVGAnimate の曲線・塗り・線が標準 AnimationPlayer で補間されることを検証する。
extends SceneTree

var failed := false

func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error(message)

func _initialize() -> void:
	run.call_deferred()

func add_track(animation: Animation, name: String, first: Variant, last: Variant) -> void:
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(".:" + name))
	animation.track_insert_key(track, 0.0, first)
	animation.track_insert_key(track, 1.0, last)

func test_kind(kind: String) -> void:
	var node: Node = ClassDB.instantiate(kind)
	node.set("src", "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'>" \
		+ "<defs><linearGradient id='g'><stop stop-color='#ff0000'/>" \
		+ "<stop offset='1' stop-color='#0000ff'/></linearGradient></defs>" \
		+ "<style>.paint{fill:#ff0000;stroke:#0000ff;stroke-width:2}</style>" \
		+ "<path class='paint' d='M5 50 C25 5 65 5 85 50 L85 90 L5 90 Z'/>" \
		+ "<rect x='86' y='5' width='10' height='80' fill='url(#g)'/></svg>")
	root.add_child(node)
	check(node.call("has_out_handle", 0, 0) and node.call("has_in_handle", 0, 1)
		and not node.call("has_in_handle", 0, 0), kind + " cubic handle topology is wrong")
	check(Color(node.get("paths/path_0/fill_color")).is_equal_approx(Color.RED),
		kind + " failed to resolve CSS fill color")
	check(String(node.get("paths/path_1/fill_paint")) == "url(#g)",
		kind + " gradient was lost before keying")
	await process_frame
	var original_texture := node.call("get_texture") as Texture2D
	check(original_texture != null, kind + " texture is null: paths=" + str(node.call("get_path_count")))
	if original_texture == null:
		node.free()
		return
	var original_hash := hash(original_texture.get_image().get_data())
	# AnimationPlayer の初期キーを適用してもグラデーションを単色化しない。
	node.set("paths/path_1/fill_paint", "url(#g)")
	for property_name in ["fill_color", "stroke_color", "fill_opacity", "stroke_opacity", "stroke_width"]:
		var key := "paths/path_0/" + String(property_name)
		node.set(key, node.get(key))
	node.call("flush_paths")
	var unchanged_hash := hash((node.call("get_texture") as Texture2D).get_image().get_data())
	check(original_hash == unchanged_hash, kind + " initial paint keys changed the image: " \
		+ str(original_hash) + " != " + str(unchanged_hash))
	var original_handle: Vector2 = node.get("paths/path_0/point_1/in_handle")
	var player := AnimationPlayer.new()
	node.add_child(player)
	player.root_node = NodePath("..")
	var animation := Animation.new()
	animation.length = 1.0
	add_track(animation, "paths/path_0/point_1/in_handle", original_handle, original_handle + Vector2(0, 25))
	add_track(animation, "paths/path_0/fill_color", Color.RED, Color.GREEN)
	add_track(animation, "paths/path_0/stroke_color", Color.BLUE, Color.YELLOW)
	add_track(animation, "paths/path_0/stroke_width", 2.0, 8.0)
	add_track(animation, "paths/path_0/fill_opacity", 1.0, 0.5)
	var library := AnimationLibrary.new()
	library.add_animation("all", animation)
	player.add_animation_library("", library)
	player.play("all")
	player.pause()
	var hashes := []
	for time in [0.0, 0.5, 1.0]:
		player.seek(time, true)
		node.call("flush_paths")
		await process_frame
		var image := (node.call("get_texture") as Texture2D).get_image()
		hashes.append(hash(image.get_data()))
		check(Vector2(node.get("paths/path_0/point_1/in_handle")).distance_to(
			original_handle + Vector2(0, 25 * time)) < 0.1,
			kind + " handle did not interpolate at " + str(time))
		var fill: Color = node.get("paths/path_0/fill_color")
		var expected_fill := Color.RED.lerp(Color.GREEN, time)
		check(absf(fill.r - expected_fill.r) < 0.02 and absf(fill.g - expected_fill.g) < 0.02,
			kind + " fill color did not interpolate at " + str(time))
		var stroke: Color = node.get("paths/path_0/stroke_color")
		var expected_stroke := Color.BLUE.lerp(Color.YELLOW, time)
		check(absf(stroke.r - expected_stroke.r) < 0.02
			and absf(stroke.b - expected_stroke.b) < 0.02,
			kind + " stroke color did not interpolate at " + str(time))
		check(absf(float(node.get("paths/path_0/stroke_width")) - lerpf(2.0, 8.0, time)) < 0.05,
			kind + " stroke width did not interpolate at " + str(time))
		check(absf(float(node.get("paths/path_0/fill_opacity")) - lerpf(1.0, 0.5, time)) < 0.01,
			kind + " fill opacity did not interpolate at " + str(time))
	check(hashes[0] != hashes[1] and hashes[1] != hashes[2],
		kind + " raster did not change between animation frames")
	check(String(node.get("paths/path_1/fill_paint")) == "url(#g)",
		kind + " gradient changed while another path was animated")
	node.free()

func run() -> void:
	await test_kind("SVGAnimate2D")
	await test_kind("SVGAnimate3D")
	print("SVG animation properties test passed" if not failed else "SVG animation properties test failed")
	quit(1 if failed else 0)

# 線分切断と試験シーンのマウス操作を検証する。
# 責務: 交点・不均等区間・剛体の状態保存と、ドラッグの反力を確かめる。
# 設計思想: 静止状態と合成入力から始め、短い物理更新で差を測る。
extends RefCounted
const Steps = preload("res://tests/rope_cut.gd")

static func run(tree: SceneTree) -> void:
	for kind in ["SpriteRope2D", "SVGRope2D", "SpriteRope3D", "SVGRope3D"]:
		var dim2: bool = kind.ends_with("2D")
		for count in [2, 7, 256]:
			var rope: Node = ClassDB.instantiate(kind)
			rope.set("line_mode", true)
			rope.set("segments", count)
			rope.set("max_length", 12.0)
			rope.set("gravity_scale", 0.0)
			rope.set("rope_mass", 3.0)
			rope.position = Vector2(30, 15) if dim2 else Vector3(30, 15, 2)
			rope.rotation = 0.4 if dim2 else Vector3(0.1, 0.2, 0.3)
			tree.root.add_child(rope)
			var a = rope.to_global(Vector2(-3, 5.25) if dim2 else Vector3(-3, -5.25, 0))
			var b = rope.to_global(Vector2(3, 5.25) if dim2 else Vector3(3, -5.25, 0))
			var expected = a.lerp(b, 0.5)
			tree.check(rope.call("cut_segment", a, a) == null, "長さ0の切断線を受け入れたよ")
			var points = rope.call("get_rope_points")
			var start = rope.to_global(points[0])
			var end = rope.to_global(points[-1])
			tree.check(rope.call("cut_segment", start, end) == null, "重なる線で切れたよ")
			var tail: Node = rope.call("cut_segment", a, b)
			tree.check(tail != null, "区間途中で切れないよ: %s %d" % [kind, count])
			if tail == null:
				rope.free()
				continue
			tree.check(tail.get_parent() == rope.get_parent() and tail.get_class() == kind,
				"同型の兄弟ノードにならないよ")
			tree.check(rope.to_global(rope.call("get_rope_points")[-1]).distance_to(expected) < 0.0001
				and tail.to_global(tail.call("get_rope_points")[0]).distance_to(expected) < 0.0001,
				"切断点が線分の交点と違うよ")
			tree.check(absf(rope.get("max_length") - 5.25) < 0.0001
				and absf(rope.get("rope_mass") - 1.3125) < 0.0001
				and absf(rope.get("uv_range").y - 0.4375) < 0.00001, "素材に沿って分割されないよ")
			tree.check(rope.call("cut_segment", a, b) == null and tail.call("cut_segment", a, b) == null,
				"同じ交点を二度切ったよ: %s %d" % [kind, count])
			var before = rope.call("get_rope_points")
			await Steps.tick(tree)
			var after = rope.call("get_rope_points")
			for i in before.size():
				tree.check(before[i].distance_to(after[i]) < 0.0001, "不均等区間が更新時に縮んだよ")
			# 新しい端を含む不均等区間を再切断しても素材比率を保つ。
			a = rope.to_global(Vector2(-3, 4.75) if dim2 else Vector3(-3, -4.75, 0))
			b = rope.to_global(Vector2(3, 4.75) if dim2 else Vector3(3, -4.75, 0))
			var second: Node = rope.call("cut_segment", a, b)
			tree.check(second != null and absf(rope.get("max_length") - 4.75) < 0.0001
				and absf(second.get("max_length") - 0.5) < 0.0001, "不均等区間の再切断で長さが変わったよ")
			if second: second.free()
			tail.free()
			rope.free()
	await native_cut(tree)
	await input_scene(tree)
	print("Rope segment cuts: exact intersections, unequal lengths, rigid velocities and mouse input passed")

# 回転中の剛体を切り、並進速度と角速度から各片の速度が得られることを確認する。
static func native_cut(tree: SceneTree) -> void:
	for dim in ["2D", "3D"]:
		var dim2: bool = dim == "2D"
		var rope: Node = ClassDB.instantiate("SpriteRope" + dim)
		var body: Node = ClassDB.instantiate("RigidBody" + dim)
		rope.set("line_mode", true)
		rope.set("segments", 3)
		rope.set("max_length", 8.0)
		rope.set("pin_start", false)
		rope.set("gravity_scale", 0.0)
		rope.set("damping", 0.0)
		body.set("gravity_scale", 0.0)
		tree.root.add_child(body)
		tree.root.add_child(rope)
		rope.set("attachment_body", rope.get_path_to(body))
		var segments := rope.get_children(true).filter(func(child): return child.is_class("RigidBody" + dim))
		var old: Node = segments[0]
		old.linear_velocity = Vector2(5, 2) if dim2 else Vector3(5, 2, 0)
		old.angular_velocity = 0.8 if dim2 else Vector3(0, 0, 0.8)
		var velocity = old.linear_velocity
		var angular = old.angular_velocity
		var center = old.global_position
		var mass: float = old.mass
		var a = Vector2(-2, 1.5) if dim2 else Vector3(-2, -1.5, 0)
		var b = Vector2(2, 1.5) if dim2 else Vector3(2, -1.5, 0)
		var tail: Node = rope.call("cut_segment", a, b)
		tree.check(tail != null, "剛体区間の途中で切れないよ")
		if tail == null:
			rope.free()
			body.free()
			continue
		var pieces := rope.get_children(true).filter(func(child): return child.is_class("RigidBody" + dim))
		pieces.append_array(tail.get_children(true).filter(func(child): return child.is_class("RigidBody" + dim) and child != segments[1]))
		var momentum = Vector2.ZERO if dim2 else Vector3.ZERO
		for piece in pieces:
			var offset = piece.global_position - center
			var expected = velocity + (Vector2(-offset.y, offset.x) * angular if dim2 else angular.cross(offset))
			tree.check(piece.linear_velocity.distance_to(expected) < 0.0001, "切断片の重心速度が回転を引き継がないよ")
			momentum += piece.mass * piece.linear_velocity
		tree.check(momentum.distance_to(mass * velocity) < 0.0001, "区間切断で運動量が変わったよ")
		tree.check(tail.get_node(tail.get("attachment_body")) == body, "末端の接続を引き継がないよ")
		var masses := pieces.map(func(piece): return piece.mass)
		await Steps.tick(tree)
		for i in pieces.size():
			tree.check(absf(pieces[i].mass - masses[i]) < 0.00001, "物理更新で不均等な区間質量が変わったよ")
		rope.free()
		tail.free()
		body.free()

# 入力イベントを直接渡し、ウィンドウ操作なしでドラッグと背景切断を確認する。
static func mouse(scene: Node2D, position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = scene.get_canvas_transform() * position
	event.pressed = pressed
	scene._unhandled_input(event)

static func input_scene(tree: SceneTree) -> void:
	var scene := preload("res://tests/stickman_rope_swing.tscn").instantiate() as Node2D
	tree.root.add_child(scene)
	await Steps.tick(tree, 2)
	var body := scene.get_node("StickmanBody") as RigidBody2D
	var start := body.global_position
	mouse(scene, start, true)
	tree.check(is_instance_valid(scene.get("_grab")), "棒人間をクリックして掴めないよ")
	var motion := InputEventMouseMotion.new()
	motion.position = scene.get_canvas_transform() * (start + Vector2(-90, 0))
	scene._unhandled_input(motion)
	await Steps.tick(tree, 10)
	tree.check(body.global_position.x < start.x - 5 and absf(body.rotation) < 0.0001,
		"ドラッグで棒人間が動かない、または回転したよ")
	mouse(scene, start, false)
	tree.check(not is_instance_valid(scene.get("_grab")), "ボタンを離しても掴んだままだよ")
	var rope := scene.get_node("Rope") as SpriteRope2D
	var points := rope.get_rope_points()
	var middle := rope.to_global(points[1].lerp(points[2], 0.37))
	var side := (rope.to_global(points[2]) - rope.to_global(points[1])).orthogonal().normalized() * 20
	mouse(scene, middle - side, true)
	motion.position = scene.get_canvas_transform() * (middle + side)
	scene._unhandled_input(motion)
	tree.check(scene.get_node("CutGuide").get_point_count() == 2, "背景ドラッグの線を表示できないよ")
	mouse(scene, middle + side, false)
	var ropes := scene.get_children().filter(func(child): return child is SpriteRope2D)
	tree.check(ropes.size() == 2 and scene.get_node("CutGuide").get_point_count() == 0,
		"背景ドラッグでロープが切れないよ")
	scene.free()

# Ropeと実剛体・Joint・親ノードの結合を検証する。
# 責務: 移動・停止・再接続・切断を物理空間で実行し、反力と状態の保存を確認する。
# 設計思想: Box2Dのworld試験とVerlet Ropeの移動デモを、短い再現可能な操作へまとめる。
extends RefCounted

static func tick(tree: SceneTree, count: int = 1) -> void:
	for i in count: await tree.physics_frame
	await tree.process_frame

static func run(tree: SceneTree) -> void:
	for dim in ["2D", "3D"]:
		var dim2: bool = dim == "2D"
		var zero = Vector2.ZERO if dim2 else Vector3.ZERO
		var force = Vector2(4, 0) if dim2 else Vector3(4, 0, 0)
		var host: Node = ClassDB.instantiate("Node" + dim)
		var rope: Node = ClassDB.instantiate("SVGRope" + dim)
		var load: Node = ClassDB.instantiate("RigidBody" + dim)
		var holder: Node = ClassDB.instantiate("Node" + dim)
		rope.set("line_mode", true)
		rope.set("pin_start", false)
		rope.set("segments", 4)
		rope.set("max_length", 6)
		rope.set("gravity_scale", 0)
		rope.set("damping", 0)
		load.name = "Load"
		load.set("gravity_scale", 0)
		load.set("linear_damp_mode", 1)
		load.set("linear_damp", 0)
		load.set("angular_damp_mode", 1)
		load.set("angular_damp", 0)
		load.set("lock_rotation", true)
		tree.root.add_child(host)
		host.add_child(rope)
		host.add_child(load)
		host.add_child(holder)
		load.position = rope.call("get_rope_points")[-1]
		rope.set("attachment_body", rope.get_path_to(load))
		await tick(tree, 2)
		# 接続先の親変更・改名後も実際の力がロープへ伝わる。
		load.reparent(holder)
		load.name = "MovedLoad"
		await tick(tree, 2)
		load.call("apply_central_impulse", force)
		await tick(tree, 8)
		var bodies := rope.get_children(true).filter(func(child): return child.is_class("RigidBody" + dim))
		var momentum = zero
		for body in bodies: momentum += body.mass * body.linear_velocity
		tree.check(momentum.length() > 0.05, dim + " reparented load lost rope reaction: " + str(momentum))
		tree.check((momentum + load.mass * load.linear_velocity).distance_to(force) < 0.05,
			dim + " system momentum changed")
		# 同じ親・名前へ戻しても、離脱で解除されたJointを復旧する。
		for body in bodies: body.linear_velocity = zero
		load.linear_velocity = zero
		holder.remove_child(load)
		holder.add_child(load)
		await tick(tree, 2)
		load.call("apply_central_impulse", force)
		await tick(tree, 8)
		momentum = zero
		for body in bodies: momentum += body.mass * body.linear_velocity
		tree.check(momentum.length() > 0.05, dim + " same-path reentry lost rope reaction: " + str(momentum))
		# 停止から再開するときも、内部剛体と公開粒子列が一致する。
		rope.set("simulation_enabled", false)
		await tick(tree, 2)
		var stopped = rope.call("get_rope_points")
		await tick(tree, 2)
		tree.check(rope.call("get_rope_points") == stopped, dim + " paused rope moved")
		rope.set("simulation_enabled", true)
		await tick(tree, 2)
		var points = rope.call("get_rope_points")
		var mid = rope.to_global(points[1].lerp(points[2], 0.37))
		var side = Vector2(10, 0) if dim2 else Vector3(10, 0, 0)
		var before = zero
		for body in bodies: before += body.mass * body.linear_velocity
		var mass: float = rope.get("rope_mass")
		var tail: Node = rope.call("cut_segment", mid - side, mid + side)
		tree.check(tail != null and tail.get_parent() == host, dim + " sibling cut failed")
		if tail:
			var after = zero
			var parts := rope.get_children(true) + tail.get_children(true)
			for body in parts:
				if body.is_class("RigidBody" + dim): after += body.mass * body.linear_velocity
			tree.check(before.distance_to(after) < 0.02, dim + " cut momentum changed")
			tree.check(absf(rope.get("rope_mass") + tail.get("rope_mass") - mass) < 0.00001,
				dim + " cut mass changed")
			load.free()
			await tick(tree, 2)
			tree.check(tail.call("get_rope_points")[0].is_finite(), dim + " deleting load corrupted rope")
		host.free()

	await textured_cut(tree)

# SVG素材から描いた帯が、切断によって伸びたり画像範囲を繰り返したりしないことを調べる。
static func textured_cut(tree: SceneTree) -> void:
	for dim in ["2D", "3D"]:
		var dim2: bool = dim == "2D"
		var view := SubViewport.new()
		view.size = Vector2i(64, 48)
		view.transparent_bg = true
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var rope: Node = ClassDB.instantiate("SVGRope" + dim)
		rope.set("src", "<svg width='8' height='48'><path fill='red' d='M0 0H8V24H0Z'/>"
			+ "<path fill='blue' d='M0 24H8V48H0Z'/></svg>")
		rope.set("segments", 5)
		rope.set("simulation_enabled", false)
		rope.set("max_length", 48 if dim2 else 0.48)
		rope.position = Vector2(32, 0) if dim2 else Vector3(0, 0.24, 0)
		if not dim2:
			view.own_world_3d = true
			var camera := Camera3D.new()
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = 0.48
			camera.position.z = 2
			view.add_child(camera)
		view.add_child(rope)
		tree.root.add_child(view)
		await preload("res://tests/oss_svg_integration.gd").frame(tree)
		var before := view.get_texture().get_image()
		tree.check(before.get_pixel(32, 8).r > 0.9 and before.get_pixel(32, 40).b > 0.9,
			dim + " SVG material did not reach rope renderer")
		var a = Vector2(20, 17.25) if dim2 else Vector3(-0.2, 0.0675, 0)
		var b = Vector2(44, 17.25) if dim2 else Vector3(0.2, 0.0675, 0)
		var tail: Node = rope.call("cut_segment", a, b)
		tree.check(tail != null and tail.get_parent() == view, dim + " textured cut missing")
		await preload("res://tests/oss_svg_integration.gd").frame(tree)
		var after := view.get_texture().get_image()
		tree.check(before.get_data() == after.get_data(), dim + " cut changed visible material/geometry")
		after.save_png("res://tmp/oss_rope_%s.png" % dim)
		view.free()

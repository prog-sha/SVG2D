# 双方向の物理接続とロープ切断を検証する。
# 責務: 運動量の伝達、切断直後の状態、自由落下と接続先の引継ぎを確認する。
# 設計思想: 外力のない短い試験で、ロープと接続物を合わせた量を比べる。
extends RefCounted

# 物理更新が描画用座標へ反映されたタイミングに揃える。
static func tick(tree: SceneTree, count: int = 1) -> void:
	for i in count:
		await tree.physics_frame
	await tree.process_frame

static func run(tree: SceneTree) -> void:
	# Verletの現在位置と前フレーム位置を分割し、同じ親・素材範囲を保つ。
	for kind in ["SpriteRope2D", "SVGRope2D", "SpriteRope3D", "SVGRope3D"]:
		var dim2: bool = kind.ends_with("2D")
		var rope: Node = ClassDB.instantiate(kind)
		rope.set("line_mode", true)
		rope.set("segments", 7)
		rope.set("max_length", 12.0)
		rope.set("rope_mass", 3.0)
		rope.set("use_system_gravity", false)
		rope.set("gravity", Vector2(9, 8) if dim2 else Vector3(9, -8, 2))
		if dim2:
			rope.position = Vector2(30, 15)
			rope.rotation = 0.4
		else:
			rope.position = Vector3(30, 15, 3)
			rope.rotation = Vector3(0.1, 0.2, 0.3)
		tree.root.add_child(rope)
		await tick(tree, 3)
		var before = rope.call("get_rope_points")
		var velocity = rope.call("get_rope_velocities")
		tree.check(rope.call("cut_at", 0) == null and rope.call("cut_at", 6) == null
			and rope.call("cut_at", -1) == null and rope.call("cut_at", 999) == null,
			"端点または範囲外の切断を受け入れたよ")
		var tail: Node = rope.call("cut_at", 3)
		tree.check(tail != null and tail.get_class() == kind and tail.get_parent() == rope.get_parent(),
			"切断で同型の兄弟ノードを生成できないよ: " + kind)
		if tail == null:
			rope.free()
			continue
		tree.check(rope.call("get_rope_points") == before.slice(0, 4)
			and tail.call("get_rope_points") == before.slice(3), "切断直後の形が変わったよ: " + kind)
		tree.check(rope.call("get_rope_velocities") == velocity.slice(0, 4)
			and tail.call("get_rope_velocities") == velocity.slice(3), "切断で速度が消えたよ: " + kind)
		tree.check(tail.get("global_transform").is_equal_approx(rope.get("global_transform"))
			and not tail.get("pin_start") and rope.get("pin_start"), "切断片の座標または固定端が違うよ")
		tree.check(is_equal_approx(rope.get("max_length") + tail.get("max_length"), 12.0)
			and is_equal_approx(rope.get("rope_mass") + tail.get("rope_mass"), 3.0)
			and rope.get("uv_range") == Vector2(0, 0.5) and tail.get("uv_range") == Vector2(0.5, 1),
			"切断で長さ・質量・画像範囲が保存されないよ")
		var tip = tail.call("get_rope_points")[0]
		await tick(tree, 2)
		tree.check(tail.call("get_rope_points")[0].distance_to(tip) > 0.00001, "切断片の新しい端が固定されたままだよ")
		var second: Node = tail.call("cut_at", 1)
		tree.check(second != null and second.get("uv_range").x > 0.5, "切断片を再び切断できないよ")
		if second: second.free()
		tail.free()
		rope.free()

	# 外力のない自由なロープへ接続物から力を加え、逆向きにも運動量が伝わる。
	for dim2 in [true, false]:
		var dim := "2D" if dim2 else "3D"
		var rope: Node = ClassDB.instantiate("SpriteRope" + dim)
		var body: Node = ClassDB.instantiate("RigidBody" + dim)
		var zero = Vector2.ZERO if dim2 else Vector3.ZERO
		var force = Vector2(4, 0) if dim2 else Vector3(4, 0, 0)
		rope.set("line_mode", true)
		rope.set("segments", 5)
		rope.set("max_length", 8.0)
		rope.set("pin_start", false)
		rope.set("damping", 0.0)
		rope.set("use_system_gravity", false)
		rope.set("gravity", zero)
		rope.set("rope_mass", 1.0)
		body.set("mass", 1.0)
		body.set("gravity_scale", 0.0)
		body.set("linear_damp_mode", 1)
		body.set("linear_damp", 0.0)
		body.set("angular_damp_mode", 1)
		body.set("angular_damp", 0.0)
		body.set("lock_rotation", true)
		var collision: Node = ClassDB.instantiate("CollisionShape" + dim)
		var shape: Resource = ClassDB.instantiate("CircleShape2D" if dim2 else "SphereShape3D")
		shape.set("radius", 0.2)
		collision.set("shape", shape)
		body.add_child(collision)
		tree.root.add_child(body)
		tree.root.add_child(rope)
		body.position = rope.call("get_rope_points")[-1]
		rope.set("attachment_body", rope.get_path_to(body))
		await tick(tree, 2)
		var segments := rope.get_children(true).filter(func(child): return child.is_class("RigidBody" + dim))
		tree.check(segments.size() == 4, "双方向用の区間剛体が不足しているよ")
		body.call("apply_central_impulse", force)
		await tick(tree, 8)
		var momentum = body.get("linear_velocity") * body.get("mass")
		var rope_momentum = zero
		for segment in segments:
			rope_momentum += segment.linear_velocity * segment.mass
		momentum += rope_momentum
		print("Rope reaction ", dim, ": ", rope_momentum, " load velocity ", body.get("linear_velocity"))
		tree.check(rope_momentum.length() > 0.02 and body.get("linear_velocity").distance_to(force) > 0.02,
			"接続物からロープへの反力がないよ: " + dim)
		tree.check(momentum.distance_to(force) < 0.08, "双方向接続で運動量が増減したよ: %s %s" % [dim, momentum])
		# 切断は既存の剛体を移し、姿勢・速度をその場で保存する。
		tree.check(rope.get_child_count() == 0, "内部剛体が通常の子ノードに露出したよ")
		var transforms := []
		var velocities := []
		var angular := []
		for segment in segments:
			transforms.append(segment.global_transform)
			velocities.append(segment.linear_velocity)
			angular.append(segment.angular_velocity)
		var tail: Node = rope.call("cut_at", 2)
		tree.check(tail != null and rope.get("attachment_body").is_empty()
			and tail.get_node(tail.get("attachment_body")) == body, "切断片へ接続物を渡せないよ")
		for i in segments.size():
			tree.check(segments[i].global_transform.is_equal_approx(transforms[i])
				and segments[i].linear_velocity.is_equal_approx(velocities[i])
				and is_equal_approx(segments[i].angular_velocity, angular[i]) if dim2 else
				segments[i].global_transform.is_equal_approx(transforms[i])
				and segments[i].linear_velocity.is_equal_approx(velocities[i])
				and segments[i].angular_velocity.is_equal_approx(angular[i]), "切断で区間剛体の運動が変わったよ")
		var old_momentum = segments[0].linear_velocity * segments[0].mass + segments[1].linear_velocity * segments[1].mass
		body.call("apply_central_impulse", force)
		await tick(tree, 6)
		var kept_momentum = segments[0].linear_velocity * segments[0].mass + segments[1].linear_velocity * segments[1].mass
		tree.check(kept_momentum.distance_to(old_momentum) < 0.08,
			"切断後も反対側へJointの力が伝わったよ: " + dim)
		var end_momentum = body.get("linear_velocity") * body.get("mass")
		for segment in segments: end_momentum += segment.linear_velocity * segment.mass
		tree.check(end_momentum.distance_to(force * 2) < 0.16, "切断後に質量か速度が失われたよ")
		print("Rope coupling %s: momentum %s, cut momentum %s" % [dim, momentum, end_momentum])
		# treeへ戻した後も残る区間の接点を保持し、接続物の削除に耐える。
		tree.root.remove_child(tail)
		tree.root.add_child(tail)
		await tick(tree, 2)
		tree.check(tail.get_child_count() == 0, "切断で内部剛体の指定が消えたよ")
		var remaining := tail.get_children(true).filter(func(child): return child.is_class("RigidBody" + dim))
		var a: Node = remaining[0]
		var b: Node = remaining[1]
		var length_a: float = a.get_child(0, true).shape.height * 0.5
		var length_b: float = b.get_child(0, true).shape.height * 0.5
		var point_a = a.to_global(Vector2(0, length_a) if dim2 else Vector3(0, length_a, 0))
		var point_b = b.to_global(Vector2(0, -length_b) if dim2 else Vector3(0, -length_b, 0))
		tree.check(point_a.distance_to(point_b) < 0.1, "切断・tree再入場後に区間のJointが外れたよ")
		body.free()
		await tick(tree)
		tail.free()
		rope.free()
	await timestep(tree)
	print("Rope cuts: state, sibling type, UV, mass and two-way momentum passed")

# 物理更新頻度を変更しても、公開速度と減衰時間が一致することを確かめる。
static func timestep(tree: SceneTree) -> void:
	var ticks := Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = 10
	var rope: Node2D = ClassDB.instantiate("SpriteRope2D")
	rope.set("line_mode", true)
	rope.set("pin_start", false)
	rope.set("segments", 3)
	rope.set("max_length", 20.0)
	rope.set("damping", 0.0)
	rope.set("gravity_scale", 0.0)
	var body := RigidBody2D.new()
	body.gravity_scale = 0.0
	body.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	body.linear_damp = 0.0
	tree.root.add_child(rope)
	tree.root.add_child(body)
	rope.set("attachment_body", rope.get_path_to(body))
	var segments := rope.get_children(true).filter(func(child): return child is RigidBody2D)
	for segment in segments: segment.linear_velocity = Vector2(10, 0)
	body.linear_velocity = Vector2(10, 0)
	await tick(tree, 2)
	tree.check(rope.call("get_rope_velocities")[0].distance_to(Vector2(10, 0)) < 0.01,
		"低い物理更新頻度で公開速度が増幅されたよ")
	Engine.physics_ticks_per_second = 60
	rope.set("damping", 0.5)
	await tick(tree, 2)
	tree.check(is_equal_approx(segments[0].linear_damp, 30.0), "60Hzの減衰係数が違うよ")
	Engine.physics_ticks_per_second = 120
	await tick(tree, 2)
	tree.check(absf(segments[0].linear_damp - (1.0 - sqrt(0.5)) * 120.0) < 0.001,
		"更新頻度を変えても減衰係数が更新されないよ")
	rope.free()
	body.free()
	Engine.physics_ticks_per_second = ticks

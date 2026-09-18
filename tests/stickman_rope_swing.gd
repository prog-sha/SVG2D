# 棒人間を掴んで動かし、背景に引いた線でロープを切る試験シーン。
# 責務: マウス座標の変換、物理的なドラッグ、切断線の表示。
# 設計思想: 剛体を直接移動せず、掴んだ位置へバネの力を加える。
extends Node2D

var _grab: StaticBody2D
var _joint: DampedSpringJoint2D
var _cutting := false
var _start := Vector2.ZERO
@onready var _guide: Line2D = $CutGuide
@onready var _body: RigidBody2D = $StickmanBody

# ビューポート座標をカメラや拡大率に依存しない世界座標へ戻す。
func _world(position: Vector2) -> Vector2:
	return get_canvas_transform().affine_inverse() * position

# 掴んだ場所を共通の接点にし、クリック直後の飛びを防ぐ。
func _begin_grab(position: Vector2) -> void:
	_grab = StaticBody2D.new()
	_grab.collision_layer = 0
	_grab.collision_mask = 0
	add_child(_grab)
	_grab.global_position = position
	_joint = DampedSpringJoint2D.new()
	_joint.length = 0
	_joint.rest_length = 0
	_joint.stiffness = 120.0 # 手に追従する強さ
	_joint.damping = 2.0 # 引き寄せ時の振動を抑える
	_grab.add_child(_joint)
	_grab.force_update_transform()
	_body.force_update_transform()
	_joint.node_a = _joint.get_path_to(_grab)
	_joint.node_b = _joint.get_path_to(_body)
	_body.sleeping = false

# Jointを先に外し、解放待ちのノードから力が加わらないようにする。
func _end_grab() -> void:
	if is_instance_valid(_joint):
		_joint.node_a = NodePath()
		_joint.node_b = NodePath()
		_joint = null
	if is_instance_valid(_grab):
		_grab.queue_free()
		_grab = null

# 複数回交差するロープも、生成した兄弟ノードを順に調べて切る。
func _cut(from: Vector2, to: Vector2) -> void:
	var pending: Array[SpriteRope2D] = []
	for child in get_children():
		if child is SpriteRope2D:
			pending.append(child)
	while not pending.is_empty():
		var rope := pending.pop_back() as SpriteRope2D
		var tail := rope.cut_segment(from, to)
		if tail:
			pending.append(rope)
			pending.append(tail)

# 棒人間の実際の衝突形状でドラッグと背景切断を振り分ける。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var position := _world(event.position)
		if event.pressed:
			var query := PhysicsPointQueryParameters2D.new()
			query.position = position
			query.collision_mask = _body.collision_layer
			var on_body := false
			for hit in get_world_2d().direct_space_state.intersect_point(query):
				on_body = on_body or hit.collider == _body
			if on_body:
				_begin_grab(position)
			else:
				_cutting = true
				_start = position
				_guide.points = PackedVector2Array([to_local(position), to_local(position)])
		else:
			_end_grab()
			if _cutting:
				_cutting = false
				_guide.clear_points()
				_cut(_start, position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var position := _world(event.position)
		if is_instance_valid(_grab):
			_grab.global_position = position
		elif _cutting:
			_guide.set_point_position(1, to_local(position))

# ウィンドウ外でボタンを離した場合も掴み状態を残さない。
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_end_grab()
		_cutting = false
		if is_instance_valid(_guide):
			_guide.clear_points()

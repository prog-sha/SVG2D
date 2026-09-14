# InspectorのRect / Shapeボタンから標準のStaticBody + Collisionノード構成を作る。
@tool
extends VBoxContainer

const ShapeUtils = preload("svg_shape_utils.gd")

var target: Object
var status: Label

func _init() -> void:
	add_theme_constant_override("separation", 5)
	var title := Label.new()
	title.text = "Create Hitbox"
	title.tooltip_text = "Create an editable Godot collision hierarchy as children of this SVG node"
	add_child(title)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	add_child(actions)
	var rect_button := Button.new()
	rect_button.text = "Rect"
	rect_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect_button.tooltip_text = "Create a rectangular StaticBody and CollisionShape"
	rect_button.pressed.connect(_create_rect)
	actions.add_child(rect_button)
	var shape_button := Button.new()
	shape_button.text = "Shape"
	shape_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shape_button.tooltip_text = "Trace only the SVG's visible outer silhouette and create collision geometry"
	shape_button.pressed.connect(_create_shape)
	actions.add_child(shape_button)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.add_theme_color_override("font_color", Color("#aeb3bd"))
	add_child(status)

func setup(object: Object) -> void:
	target = object

func _create_rect() -> void:
	if not _is_valid_target():
		_set_error("Load a valid SVG before creating a hitbox.")
		return
	var body: Node
	if target.is_class("SVG2D"):
		body = _rect_2d()
	else:
		body = _rect_3d()
	_commit_body(body, "Create SVG Rect Hitbox")

func _create_shape() -> void:
	if not _is_valid_target():
		_set_error("Load a valid SVG before creating a hitbox.")
		return
	var polygons := ShapeUtils.outer_polygons(target)
	if polygons.is_empty():
		_set_error("The SVG has no visible outer silhouette.")
		return
	var body: Node
	if target.is_class("SVG2D"):
		body = _shape_2d(polygons)
	else:
		body = _shape_3d(polygons)
	_commit_body(body, "Create SVG Shape Hitbox")

func _is_valid_target() -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var size: Vector2 = target.call("get_svg_size")
	return size.x > 0.0 and size.y > 0.0

func _rect_2d() -> StaticBody2D:
	var size: Vector2 = target.call("get_svg_size")
	var body := StaticBody2D.new()
	body.name = "SVGRectBody2D"
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	collision.position = Vector2(target.get("offset")) + size * 0.5
	body.add_child(collision)
	return body

func _shape_2d(polygons: Array[PackedVector2Array]) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = "SVGShapeBody2D"
	for index in polygons.size():
		var collision := CollisionPolygon2D.new()
		collision.name = "CollisionPolygon2D" if index == 0 else "CollisionPolygon2D%d" % (index + 1)
		var displayed := PackedVector2Array()
		for point in polygons[index]:
			displayed.append(ShapeUtils.displayed_point_2d(target, point))
		collision.polygon = displayed
		body.add_child(collision)
	return body

func _rect_3d() -> StaticBody3D:
	var size: Vector2 = target.call("get_svg_size")
	var pixel_size := float(target.get("pixel_size"))
	var body := StaticBody3D.new()
	body.name = "SVGRectBody3D"
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := BoxShape3D.new()
	shape.size = Vector3(size.x * pixel_size, size.y * pixel_size, _depth_3d(size, pixel_size))
	collision.shape = shape
	var offset := Vector2(target.get("offset")) * pixel_size
	collision.position = Vector3(offset.x, -offset.y, 0.0)
	body.add_child(collision)
	return body

func _shape_3d(polygons: Array[PackedVector2Array]) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "SVGShapeBody3D"
	var collision := CollisionShape3D.new()
	collision.name = "CollisionShape3D"
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(_extruded_faces(polygons))
	collision.shape = shape
	body.add_child(collision)
	return body

func _extruded_faces(polygons: Array[PackedVector2Array]) -> PackedVector3Array:
	var faces := PackedVector3Array()
	var size: Vector2 = target.call("get_svg_size")
	var depth := _depth_3d(size, float(target.get("pixel_size")))
	var half := depth * 0.5
	for polygon in polygons:
		var triangles := Geometry2D.triangulate_polygon(polygon)
		for i in range(0, triangles.size(), 3):
			var a := ShapeUtils.displayed_point_3d(target, polygon[triangles[i]])
			var b := ShapeUtils.displayed_point_3d(target, polygon[triangles[i + 1]])
			var c := ShapeUtils.displayed_point_3d(target, polygon[triangles[i + 2]])
			faces.append_array(PackedVector3Array([
				Vector3(a.x, a.y, half), Vector3(b.x, b.y, half), Vector3(c.x, c.y, half),
				Vector3(c.x, c.y, -half), Vector3(b.x, b.y, -half), Vector3(a.x, a.y, -half),
			]))
		for i in polygon.size():
			var a := ShapeUtils.displayed_point_3d(target, polygon[i])
			var b := ShapeUtils.displayed_point_3d(target, polygon[(i + 1) % polygon.size()])
			faces.append_array(PackedVector3Array([
				Vector3(a.x, a.y, -half), Vector3(b.x, b.y, -half), Vector3(b.x, b.y, half),
				Vector3(a.x, a.y, -half), Vector3(b.x, b.y, half), Vector3(a.x, a.y, half),
			]))
	return faces

func _depth_3d(size: Vector2, pixel_size: float) -> float:
	return maxf(pixel_size, minf(size.x, size.y) * pixel_size * 0.002)

func _commit_body(body: Node, action: String) -> void:
	var parent := target as Node
	var scene_root := EditorInterface.get_edited_scene_root()
	var undo := EditorInterface.get_editor_undo_redo()
	undo.create_action(action)
	undo.add_do_method(parent, "add_child", body, true)
	undo.add_do_method(body, "set_owner", scene_root)
	for child in body.get_children():
		undo.add_do_method(child, "set_owner", scene_root)
	undo.add_undo_method(parent, "remove_child", body)
	undo.add_do_reference(body)
	undo.commit_action()
	status.remove_theme_color_override("font_color")
	status.text = "%s created with %d collision node(s)." % [body.name, body.get_child_count()]

func _set_error(message: String) -> void:
	status.add_theme_color_override("font_color", Color("#ff8b82"))
	status.text = message

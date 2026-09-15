# SVG3D系ノードをGodot標準の3D選択機構へ参加させるギズモ。
@tool
extends EditorNode3DGizmoPlugin

func _init() -> void:
	create_material("svg_outline", Color("5ba7ff"), false, true)

func _has_gizmo(node: Node3D) -> bool:
	return node != null and node.is_class("SVG3D")

func _get_gizmo_name() -> String:
	return "SVG3D"

func _redraw(gizmo: EditorNode3DGizmo) -> void:
	gizmo.clear()
	var node := gizmo.get_node_3d()
	if node == null:
		return
	var size: Vector2 = node.call("get_svg_size")
	var pixel := float(node.get("pixel_size"))
	if size.x <= 0.0 or size.y <= 0.0 or pixel <= 0.0:
		return
	var offset := Vector2(node.get("offset")) * pixel
	var half := size * pixel * 0.5
	var left := -half.x + offset.x
	var right := half.x + offset.x
	var top := half.y - offset.y
	var bottom := -half.y - offset.y
	var outline := PackedVector3Array([
		Vector3(left, top, 0), Vector3(right, top, 0),
		Vector3(right, top, 0), Vector3(right, bottom, 0),
		Vector3(right, bottom, 0), Vector3(left, bottom, 0),
		Vector3(left, bottom, 0), Vector3(left, top, 0),
	])
	gizmo.add_lines(outline, get_material("svg_outline", gizmo), false)
	# 枠線付近だけでなくSVG面のどこからでもGodot標準選択を開始できるようにする。
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
		Vector3(left, top, 0), Vector3(right, top, 0), Vector3(right, bottom, 0),
		Vector3(left, top, 0), Vector3(right, bottom, 0), Vector3(left, bottom, 0),
	])
	var collision_mesh := ArrayMesh.new()
	collision_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	gizmo.add_collision_triangles(collision_mesh.generate_triangle_mesh())

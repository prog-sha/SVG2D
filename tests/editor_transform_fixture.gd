@tool
extends RefCounted

# 編集点の位置と、複数色の図形が正しく描かれることを同じ素材で確かめる。
const SOURCE := "<svg xmlns='http://www.w3.org/2000/svg' width='100' height='100'>" \
	+ "<g transform='translate(8 5)'><path transform='scale(0.8 1.1)' " \
	+ "d='M14 18 L72 20 L70 83 L10 81 Z' fill='#1684d6'/>" \
	+ "<path d='M26 42 H58 V68 H26 Z' fill='#f4b942'/>" \
	+ "<path d='M40 50 L50 64 L30 64 Z' fill='#ca2652'/></g></svg>"

static func create_2d(root: Node, scene_owner: Node = null, source: String = SOURCE) -> Dictionary:
	var a := Node2D.new()
	a.name = "Outer2D"
	a.position = Vector2(-105, 73)
	a.rotation = -0.38
	a.scale = Vector2(0.9, 1.6)
	root.add_child(a)
	if scene_owner: a.owner = scene_owner
	var b := Node2D.new()
	b.name = "Middle2D"
	b.position = Vector2(91, -41)
	b.rotation = 0.65
	b.scale = Vector2(1.45, 0.7)
	a.add_child(b)
	if scene_owner: b.owner = scene_owner
	var c := Node2D.new()
	c.name = "Inner2D"
	c.position = Vector2(-32, 88)
	c.rotation = -0.27
	c.scale = Vector2(0.8, 1.25)
	b.add_child(c)
	if scene_owner: c.owner = scene_owner
	var svg: Node2D = ClassDB.instantiate("SVGAnimate2D")
	svg.name = "SVGAnimate2D"
	svg.set("src", source)
	svg.position = Vector2(37, 19)
	svg.rotation = 0.43
	svg.set("offset", Vector2(4, -6))
	c.add_child(svg)
	if scene_owner: svg.owner = scene_owner
	return {"a": a, "b": b, "c": c, "svg": svg}

static func create_3d(root: Node, scene_owner: Node = null, source: String = SOURCE) -> Dictionary:
	var a := Node3D.new()
	a.name = "Outer3D"
	a.position = Vector3(-0.11, 0.07, 0.12)
	a.rotation = Vector3(-0.31, 0.28, 0.15)
	a.scale = Vector3(1.5, 0.8, 1.2)
	root.add_child(a)
	if scene_owner: a.owner = scene_owner
	var b := Node3D.new()
	b.name = "Middle3D"
	b.position = Vector3(0.08, -0.04, -0.03)
	b.rotation = Vector3(0.24, -0.36, -0.18)
	b.scale = Vector3(0.75, 1.4, 0.9)
	a.add_child(b)
	if scene_owner: b.owner = scene_owner
	var c := Node3D.new()
	c.name = "Inner3D"
	c.position = Vector3(0.03, 0.09, 0.02)
	c.rotation = Vector3(0.16, 0.21, -0.34)
	c.scale = Vector3(1.2, 0.65, 1.1)
	b.add_child(c)
	if scene_owner: c.owner = scene_owner
	var svg: Node3D = ClassDB.instantiate("SVGAnimate3D")
	svg.name = "SVGAnimate3D"
	svg.set("src", source)
	svg.position = Vector3(0.06, -0.02, 0.04)
	svg.rotation = Vector3(-0.2, 0.17, 0.39)
	svg.set("offset", Vector2(4, -6))
	c.add_child(svg)
	if scene_owner: svg.owner = scene_owner
	return {"a": a, "b": b, "c": c, "svg": svg}

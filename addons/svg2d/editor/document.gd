# SVG/XML文書を編集画面から操作できる木として保持する。
# 責務: SVGの読み書き、要素検索、階層操作、概算境界を提供すること。
# 設計思想: 未知のSVG要素も木に残し、専用形式へ変換せずSVGのまま保存する。
@tool
extends RefCounted

var root: Dictionary = {} # SVG文書の最上位要素
var path := "" # 上書き保存先
var dirty := false # 保存後に編集されたか
var _next_uid := 1 # 画面内で要素を識別する番号

# 編集を始められる最小のSVG文書を作る。
func create(width := 800.0, height := 600.0) -> void:
	_next_uid = 1
	root = _element("svg", {
		"xmlns": "http://www.w3.org/2000/svg",
		"width": _number(width),
		"height": _number(height),
		"viewBox": "0 0 %s %s" % [_number(width), _number(height)],
	})
	path = ""
	dirty = false

# SVG文字列を木に読み込む。
func load_text(text: String) -> Error:
	var xml := XMLParser.new()
	var error := xml.open_buffer(text.to_utf8_buffer())
	if error != OK:
		return error
	var stack: Array[Dictionary] = []
	var found: Dictionary = {}
	_next_uid = 1
	while true:
		error = xml.read()
		if error == ERR_FILE_EOF:
			break
		if error != OK:
			return error
		match xml.get_node_type():
			XMLParser.NODE_ELEMENT:
				var attrs := {}
				for i in xml.get_attribute_count():
					attrs[xml.get_attribute_name(i)] = xml.get_attribute_value(i)
				var node := _element(xml.get_node_name(), attrs)
				if stack.is_empty():
					found = node
				else:
					stack.back().children.append(node)
				if not xml.is_empty():
					stack.append(node)
			XMLParser.NODE_ELEMENT_END:
				if not stack.is_empty():
					stack.pop_back()
			XMLParser.NODE_TEXT:
				if not stack.is_empty() and not xml.get_node_data().strip_edges().is_empty():
					stack.back().children.append({"kind": "text", "text": xml.get_node_data()})
			XMLParser.NODE_CDATA:
				if not stack.is_empty():
					stack.back().children.append({"kind": "cdata", "text": xml.get_node_data()})
			XMLParser.NODE_COMMENT:
				if not stack.is_empty():
					stack.back().children.append({"kind": "comment", "text": xml.get_node_data()})
	if found.is_empty() or found.name != "svg":
		return ERR_PARSE_ERROR
	root = found
	dirty = false
	return OK

# ファイルからSVGを読み込む。
func load_file(file_path: String) -> Error:
	if not FileAccess.file_exists(file_path):
		return ERR_FILE_NOT_FOUND
	var error := load_text(FileAccess.get_file_as_string(file_path))
	if error == OK:
		path = file_path
	return error

# 現在の木をSVG文字列にする。
func to_svg() -> String:
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n%s\n" % _serialize(root, 0)

# 現在のSVGをファイルへ保存する。
func save(file_path := "") -> Error:
	var target := file_path if not file_path.is_empty() else path
	if target.is_empty():
		return ERR_INVALID_PARAMETER
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(to_svg())
	path = target
	dirty = false
	return OK

# 指定種類のSVG要素を木の末尾へ追加する。
func add(name: String, attrs: Dictionary, parent_uid := 0) -> Dictionary:
	var parent := root if parent_uid == 0 else find(parent_uid)
	if parent.is_empty() or parent.kind != "element":
		parent = root
	var node := _element(name, attrs)
	parent.children.append(node)
	dirty = true
	return node

# 画面用番号で要素を探す。
func find(uid: int, node := {}) -> Dictionary:
	var at: Dictionary = root if node.is_empty() else node
	if at.get("uid", 0) == uid:
		return at
	for child in at.get("children", []):
		if child.get("kind", "") != "element":
			continue
		var found := find(uid, child)
		if not found.is_empty():
			return found
	return {}

# 子の親と並び順を探す。
func locate(uid: int, node := {}) -> Dictionary:
	var at: Dictionary = root if node.is_empty() else node
	for i in at.get("children", []).size():
		var child: Dictionary = at.children[i]
		if child.get("uid", 0) == uid:
			return {"parent": at, "index": i}
		if child.get("kind", "") == "element":
			var found := locate(uid, child)
			if not found.is_empty():
				return found
	return {}

# 要素の属性を更新する。空文字は属性を外す。
func set_attr(uid: int, key: String, value: String) -> void:
	var node := find(uid)
	if node.is_empty():
		return
	if value.is_empty():
		node.attrs.erase(key)
	else:
		node.attrs[key] = value
	dirty = true

# text要素の直接な文字を置き換える。
func set_text(uid: int, value: String) -> void:
	var node := find(uid)
	if node.is_empty() or node.name != "text":
		return
	node.children = node.children.filter(func(child: Dictionary) -> bool: return child.get("kind", "") not in ["text", "cdata"])
	node.children.push_front({"kind": "text", "text": value})
	dirty = true

# 要素を木から外す。
func remove(uid: int) -> void:
	var place := locate(uid)
	if place.is_empty():
		return
	place.parent.children.remove_at(place.index)
	dirty = true

# 要素を複製し、元の直後に置く。
func duplicate_element(uid: int) -> Dictionary:
	var place := locate(uid)
	if place.is_empty():
		return {}
	var node: Dictionary = place.parent.children[place.index].duplicate(true)
	_refresh_uids(node)
	place.parent.children.insert(place.index + 1, node)
	dirty = true
	return node

# 同じ親の要素をグループにまとめる。
func group(uids: Array) -> Dictionary:
	if uids.is_empty():
		return {}
	var places: Array[Dictionary] = []
	for uid in uids:
		var place := locate(uid)
		if place.is_empty() or (not places.is_empty() and place.parent != places[0].parent):
			return {}
		places.append(place)
	places.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.index < b.index)
	var parent: Dictionary = places[0].parent
	var group_node := _element("g", {"id": "group%d" % _next_uid})
	for place in places:
		group_node.children.append(parent.children[place.index])
	for i in range(places.size() - 1, -1, -1):
		parent.children.remove_at(places[i].index)
	parent.children.insert(places[0].index, group_node)
	dirty = true
	return group_node

# グループの中身を親の同じ位置へ戻す。
func ungroup(uid: int) -> Array[int]:
	var place := locate(uid)
	if place.is_empty():
		return []
	var node: Dictionary = place.parent.children[place.index]
	if node.name != "g":
		return []
	place.parent.children.remove_at(place.index)
	var selected: Array[int] = []
	for i in node.children.size():
		var child: Dictionary = node.children[i]
		place.parent.children.insert(place.index + i, child)
		if child.get("kind", "") == "element":
			selected.append(child.uid)
	dirty = true
	return selected

# 同じ親の中で描画順を1段階変える。
func reorder(uid: int, offset: int) -> void:
	var place := locate(uid)
	if place.is_empty():
		return
	var next: int = clampi(place.index + offset, 0, place.parent.children.size() - 1)
	if next == place.index:
		return
	var node: Dictionary = place.parent.children.pop_at(place.index)
	place.parent.children.insert(next, node)
	dirty = true

# 要素を文書座標で移動する。
func translate(uid: int, delta: Vector2) -> void:
	var node := find(uid)
	if node.is_empty() or delta.is_zero_approx():
		return
	var old: String = node.attrs.get("transform", "")
	var move := "translate(%s %s)" % [_number(delta.x), _number(delta.y)]
	node.attrs.transform = "%s %s" % [move, old] if not old.is_empty() else move
	dirty = true

# 要素の境界を基準に拡大縮小する。
func scale_around(uid: int, factor: Vector2, origin: Vector2) -> void:
	var node := find(uid)
	if node.is_empty() or factor.x == 0.0 or factor.y == 0.0:
		return
	var old: String = node.attrs.get("transform", "")
	var tx := origin.x * (1.0 - factor.x)
	var ty := origin.y * (1.0 - factor.y)
	var matrix := "matrix(%s 0 0 %s %s %s)" % [_number(factor.x), _number(factor.y), _number(tx), _number(ty)]
	node.attrs.transform = "%s %s" % [matrix, old] if not old.is_empty() else matrix
	dirty = true

# 要素の中心を基準に回転する。
func rotate_around(uid: int, degrees: float, origin: Vector2) -> void:
	var node := find(uid)
	if node.is_empty():
		return
	var old: String = node.attrs.get("transform", "")
	var rotate := "rotate(%s %s %s)" % [_number(degrees), _number(origin.x), _number(origin.y)]
	node.attrs.transform = "%s %s" % [rotate, old] if not old.is_empty() else rotate
	dirty = true

# 直線点で構成されたパスまたは多角形の編集点を返す。
func edit_points(uid: int) -> PackedVector2Array:
	var node := find(uid)
	if node.is_empty() or node.name not in ["path", "polygon", "polyline"]:
		return PackedVector2Array()
	var text: String = node.attrs.get("d", "") if node.name == "path" else node.attrs.get("points", "")
	if node.name == "path":
		var commands := RegEx.new()
		commands.compile("[A-Za-z]")
		for found in commands.search_all(text):
			if found.get_string().to_upper() not in ["M", "L", "Z"]:
				return PackedVector2Array()
	var values := _numbers(text)
	var points := PackedVector2Array()
	for i in range(0, values.size() - 1, 2):
		points.append(Vector2(values[i], values[i + 1]))
	return points

# 直線パスまたは多角形の編集点を置き換える。
func set_edit_point(uid: int, index: int, point: Vector2) -> void:
	var node := find(uid)
	var points := edit_points(uid)
	if node.is_empty() or index < 0 or index >= points.size():
		return
	points[index] = point
	var pairs: Array[String] = []
	for value in points:
		pairs.append("%s %s" % [_number(value.x), _number(value.y)])
	if node.name == "path":
		var closed: bool = str(node.attrs.get("d", "")).strip_edges().to_upper().ends_with("Z")
		node.attrs.d = "M %s%s" % [" L ".join(pairs), " Z" if closed else ""]
	else:
		node.attrs.points = " ".join(pairs)
	dirty = true

# 基本図形とグループの概算境界を返す。
func bounds(uid: int) -> Rect2:
	return _bounds(find(uid))

# 文書の表示領域を返す。
func document_rect() -> Rect2:
	var view := _numbers(root.attrs.get("viewBox", ""))
	if view.size() >= 4:
		return Rect2(view[0], view[1], maxf(view[2], 1.0), maxf(view[3], 1.0))
	return Rect2(0, 0, maxf(_value(root.attrs.get("width", "800")), 1.0), maxf(_value(root.attrs.get("height", "600")), 1.0))

# 木の要素に画面用番号を付け直す。
func _refresh_uids(node: Dictionary) -> void:
	if node.get("kind", "") != "element":
		return
	node.uid = _next_uid
	_next_uid += 1
	for child in node.children:
		_refresh_uids(child)

# 内部表現のSVG要素を作る。
func _element(name: String, attrs: Dictionary) -> Dictionary:
	var node := {"kind": "element", "name": name, "attrs": attrs, "children": [], "uid": _next_uid}
	_next_uid += 1
	return node

# SVG要素を読みやすいXMLに書き出す。
func _serialize(node: Dictionary, depth: int) -> String:
	var kind: String = node.get("kind", "")
	if kind == "text":
		return _escape_text(node.text)
	if kind == "cdata":
		return "<![CDATA[%s]]>" % node.text.replace("]]>", "]]]]><![CDATA[>")
	if kind == "comment":
		return "<!--%s-->" % node.text.replace("--", "- -")
	var indent := "\t".repeat(depth)
	var out := "%s<%s" % [indent, node.name]
	for key in node.attrs:
		out += " %s=\"%s\"" % [key, _escape_attr(str(node.attrs[key]))]
	if node.children.is_empty():
		return out + "/>"
	out += ">"
	var only_text: bool = node.children.all(func(child: Dictionary) -> bool: return child.kind in ["text", "cdata"])
	if only_text:
		for child in node.children:
			out += _serialize(child, 0)
		return out + "</%s>" % node.name
	out += "\n"
	for child in node.children:
		out += _serialize(child, depth + 1) + "\n"
	return out + "%s</%s>" % [indent, node.name]

# 基本図形の数値から概算境界を求める。
func _bounds(node: Dictionary) -> Rect2:
	if node.is_empty() or node.get("kind", "") != "element":
		return Rect2()
	var a: Dictionary = node.attrs
	var rect := Rect2()
	match node.name:
		"rect", "image", "use", "svg":
			rect = Rect2(_value(a.get("x", "0")), _value(a.get("y", "0")), _value(a.get("width", "0")), _value(a.get("height", "0")))
		"circle":
			var r := _value(a.get("r", "0"))
			rect = Rect2(_value(a.get("cx", "0")) - r, _value(a.get("cy", "0")) - r, r * 2, r * 2)
		"ellipse":
			var rx := _value(a.get("rx", "0"))
			var ry := _value(a.get("ry", "0"))
			rect = Rect2(_value(a.get("cx", "0")) - rx, _value(a.get("cy", "0")) - ry, rx * 2, ry * 2)
		"line":
			var p1 := Vector2(_value(a.get("x1", "0")), _value(a.get("y1", "0")))
			var p2 := Vector2(_value(a.get("x2", "0")), _value(a.get("y2", "0")))
			rect = Rect2(p1.min(p2), (p2 - p1).abs())
		"polygon", "polyline", "path":
			var values := _numbers(a.get("points", "") if node.name != "path" else a.get("d", ""))
			for i in range(0, values.size() - 1, 2):
				var point := Vector2(values[i], values[i + 1])
				rect = Rect2(point, Vector2()) if rect == Rect2() else rect.expand(point)
		"text":
			var x := _value(a.get("x", "0"))
			var y := _value(a.get("y", "0"))
			var size := _value(a.get("font-size", "16"))
			var count := _plain_text(node).length()
			rect = Rect2(x, y - size, maxf(size * count * 0.6, size * 0.5), size * 1.2)
		_:
			for child in node.children:
				if child.get("kind", "") != "element":
					continue
				var child_rect := _bounds(child)
				if child_rect.has_area():
					rect = child_rect if not rect.has_area() else rect.merge(child_rect)
	return _transform_rect(rect, a.get("transform", ""))

# 要素の直接な文字をつなぐ。
func _plain_text(node: Dictionary) -> String:
	var out := ""
	for child in node.get("children", []):
		if child.get("kind", "") in ["text", "cdata"]:
			out += child.text
	return out

# SVGの変形一覧を境界の四隅へ適用する。
func _transform_rect(rect: Rect2, text: String) -> Rect2:
	if text.is_empty() or not rect.has_area():
		return rect
	var regex := RegEx.new()
	regex.compile("(matrix|translate|scale|rotate)\\s*\\(([^)]*)\\)")
	var transform := Transform2D.IDENTITY
	for found in regex.search_all(text):
		var values := _numbers(found.get_string(2))
		var next := Transform2D.IDENTITY
		match found.get_string(1):
			"matrix":
				if values.size() >= 6:
					next = Transform2D(Vector2(values[0], values[1]), Vector2(values[2], values[3]), Vector2(values[4], values[5]))
			"translate":
				if not values.is_empty():
					next.origin = Vector2(values[0], values[1] if values.size() > 1 else 0.0)
			"scale":
				if not values.is_empty():
					next = next.scaled(Vector2(values[0], values[1] if values.size() > 1 else values[0]))
			"rotate":
				if not values.is_empty():
					var center := Vector2(values[1], values[2]) if values.size() >= 3 else Vector2.ZERO
					next = Transform2D(0.0, center) * Transform2D(deg_to_rad(values[0]), Vector2.ZERO) * Transform2D(0.0, -center)
		transform *= next
	var points := PackedVector2Array([transform * rect.position, transform * Vector2(rect.end.x, rect.position.y), transform * rect.end, transform * Vector2(rect.position.x, rect.end.y)])
	var out := Rect2(points[0], Vector2.ZERO)
	for point in points:
		out = out.expand(point)
	return out

# 文字列からSVG内の数値を順番に拾う。
func _numbers(text: String) -> PackedFloat64Array:
	var regex := RegEx.new()
	regex.compile("[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?")
	var out := PackedFloat64Array()
	for found in regex.search_all(text):
		out.append(found.get_string().to_float())
	return out

# 単位付きの数値先頭を読む。
func _value(value: Variant) -> float:
	var values := _numbers(str(value))
	return values[0] if not values.is_empty() else 0.0

# 不要な小数を持たないSVG数値にする。
func _number(value: float) -> String:
	return ("%.4f" % value).trim_suffix("0").trim_suffix("0").trim_suffix("0").trim_suffix("0").trim_suffix(".")

# XML文字と属性を壊さない文字列にする。
func _escape_text(text: String) -> String:
	return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

func _escape_attr(text: String) -> String:
	return _escape_text(text).replace("\"", "&quot;")

# SVG文書を鮮明に表示し、選択・描画・ズームの入力を受け取る。
# 責務: 文書座標と画面座標の変換、ツール操作、選択表示を担うこと。
# 設計思想: SVGの更新は文書側へ依頼し、ここに別のSVGデータを持たない。
@tool
extends Control

signal selection_requested(uid: int, additive: bool)
signal create_requested(tag: String, attrs: Dictionary)
signal move_requested(uids: Array[int], delta: Vector2)
signal scale_requested(uid: int, factor: Vector2, origin: Vector2)
signal node_move_requested(uid: int, index: int, point: Vector2)
signal status_changed(text: String)

const MIN_ZOOM := 0.05 # 全体を見渡せる最小倍率
const MAX_ZOOM := 64.0 # ノードを詳しく見られる最大倍率
const HANDLE := 5.0 # 選択ハンドルの画面上の半径

var document: RefCounted # 編集中のSVG文書
var selected: Array[int] = [] # 選択中の要素番号
var tool := "select" # 現在の操作ツール
var zoom := 1.0 # 文書座標から画面への表示倍率
var pan := Vector2.ZERO # 画面中心からの表示ずらし
var grid := true # キャンバス上の格子表示
var snap := true # 作図座標を格子へ合わせるか
var grid_size := 10.0 # SVG座標での格子間隔
var _renderer: Node2D # 既存GDExtensionでSVGを画像化する係
var _texture: Texture2D # 現在のSVG表示画像
var _dragging := false # 画面操作中か
var _panning := false # 表示位置を移動中か
var _start := Vector2.ZERO # 操作開始の文書座標
var _last_screen := Vector2.ZERO # パンの直前画面座標
var _preview := Vector2.ZERO # 選択移動の未確定量
var _points := PackedVector2Array() # ペン・鉛筆で描いている点
var _mode := "" # 選択移動・拡大・点編集のどれを進めているか
var _node_at := -1 # 移動中の編集点番号
var _base_bounds := Rect2() # 拡大操作を始めたときの境界

# 入力を受け取れる編集面を初期化する。
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true
	if ClassDB.class_exists("SVG2D"):
		_renderer = ClassDB.instantiate("SVG2D")
		_renderer.visible = false
		add_child(_renderer)
	resized.connect(queue_redraw)

# 編集文書を差し替えて全体表示する。
func set_document(value: RefCounted) -> void:
	document = value
	selected.clear()
	fit_document()
	refresh()

# 文書の変更をGDExtensionの表示へ反映する。
func refresh() -> void:
	if document == null or _renderer == null:
		_texture = null
		queue_redraw()
		return
	_renderer.scale = Vector2(zoom, zoom)
	_renderer.set("src", document.to_svg())
	_texture = _renderer.call("get_texture")
	queue_redraw()

# ツールを切り替え、進行中の作図を閉じる。
func set_tool(value: String) -> void:
	tool = value
	_points.clear()
	_dragging = false
	_preview = Vector2.ZERO
	mouse_default_cursor_shape = Control.CURSOR_DRAG if tool == "hand" else Control.CURSOR_CROSS if tool in ["pen", "pencil", "rect", "ellipse", "line", "text"] else Control.CURSOR_ARROW
	status_changed.emit(tool.capitalize())
	queue_redraw()

# 選択状態をパネルと同期する。
func set_selection(value: Array[int]) -> void:
	selected = value.duplicate()
	queue_redraw()

# 文書全体が中央に収まる表示倍率にする。
func fit_document() -> void:
	if document == null or size.x <= 0 or size.y <= 0:
		return
	var rect: Rect2 = document.document_rect()
	zoom = clampf(minf((size.x - 80.0) / rect.size.x, (size.y - 80.0) / rect.size.y), MIN_ZOOM, MAX_ZOOM)
	pan = Vector2.ZERO
	refresh()

# 文書を100%で中央に表示する。
func actual_size() -> void:
	zoom = 1.0
	pan = Vector2.ZERO
	refresh()

# キャンバス、SVG、選択ハンドルの順に描く。
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("202228"))
	if document == null:
		return
	var page := _page_rect()
	_draw_grid(page)
	draw_rect(page, Color.WHITE)
	if _texture:
		draw_texture_rect(_texture, page, false)
	draw_rect(page, Color("687080"), false, 1.0)
	for uid in selected:
		var bounds: Rect2 = document.bounds(uid)
		if not bounds.has_area():
			continue
		var shown := Rect2(to_screen(bounds.position), bounds.size * zoom)
		if _mode == "scale":
			shown.size += _preview
		else:
			shown.position += _preview
		draw_rect(shown, Color("61a8ff"), false, 1.5)
		for point in [shown.position, shown.end, Vector2(shown.end.x, shown.position.y), Vector2(shown.position.x, shown.end.y)]:
			draw_rect(Rect2(point - Vector2.ONE * HANDLE, Vector2.ONE * HANDLE * 2.0), Color.WHITE)
			draw_rect(Rect2(point - Vector2.ONE * HANDLE, Vector2.ONE * HANDLE * 2.0), Color("2878d0"), false, 1.0)
		if tool == "node" and selected.size() == 1:
			for point in document.edit_points(uid):
				var at := to_screen(point)
				draw_circle(at, HANDLE, Color.WHITE)
				draw_circle(at, HANDLE, Color("ef7f32"), false, 1.5)
	if _dragging and tool in ["rect", "ellipse", "line"]:
		var from := to_screen(_start)
		var to := get_local_mouse_position()
		draw_rect(Rect2(from, to - from).abs(), Color("61a8ff"), false, 1.5)
	if _points.size() > 1:
		var shown := PackedVector2Array()
		for point in _points:
			shown.append(to_screen(point))
		draw_polyline(shown, Color("61a8ff"), 1.5)

# マウスとキーの操作を現在のツールへ渡す。
func _gui_input(event: InputEvent) -> void:
	if document == null:
		return
	if event is InputEventMouseButton:
		_mouse_button(event)
	elif event is InputEventMouseMotion:
		_mouse_motion(event)
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_points.clear()
			_dragging = false
			queue_redraw()
		elif event.keycode in [KEY_ENTER, KEY_KP_ENTER] and tool == "pen":
			_finish_pen()

# ボタンの開始・終了とホイールズームを判断する。
func _mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and event.pressed:
		var factor := 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.15
		_zoom_at(event.position, factor)
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_MIDDLE or (event.button_index == MOUSE_BUTTON_LEFT and tool == "hand"):
		_panning = event.pressed
		_last_screen = event.position
		accept_event()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return
	grab_focus()
	var point := _snap(to_document(event.position))
	if event.pressed:
		_start = point
		_dragging = true
		if tool == "node" and selected.size() == 1:
			_node_at = _hit_node(event.position)
			if _node_at >= 0:
				_mode = "node"
			else:
				selection_requested.emit(_hit(point), event.shift_pressed)
				_mode = "move"
		elif tool == "select":
			if selected.size() == 1 and _hit_corner(event.position):
				_mode = "scale"
				_base_bounds = document.bounds(selected[0])
			else:
				selection_requested.emit(_hit(point), event.shift_pressed)
				_mode = "move"
		elif tool == "pen":
			_points.append(point)
			_dragging = false
			if event.double_click:
				_finish_pen()
		elif tool == "pencil":
			_points = PackedVector2Array([point])
		elif tool == "text":
			create_requested.emit("text", {"x": _number(point.x), "y": _number(point.y), "fill": "#202020", "font-size": "24", "text": "Text"})
			_dragging = false
	else:
		if _mode == "node" and _dragging and selected.size() == 1:
			node_move_requested.emit(selected[0], _node_at, point)
		elif _mode == "scale" and _dragging and selected.size() == 1:
			var size := point - _base_bounds.position
			var factor := Vector2(size.x / maxf(_base_bounds.size.x, 0.001), size.y / maxf(_base_bounds.size.y, 0.001))
			if event.shift_pressed:
				factor = Vector2.ONE * maxf(factor.x, factor.y)
			scale_requested.emit(selected[0], factor, _base_bounds.position)
		elif tool in ["select", "node"] and _dragging and not selected.is_empty():
			var delta := _snap(to_document(event.position)) - _start
			if not delta.is_zero_approx():
				move_requested.emit(selected, delta)
		elif tool in ["rect", "ellipse", "line"] and _dragging:
			_create_shape(tool, _start, point)
		elif tool == "pencil" and _points.size() > 1:
			create_requested.emit("path", {"d": _path_data(_points), "fill": "none", "stroke": "#202020", "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round"})
			_points.clear()
		_dragging = false
		_mode = ""
		_node_at = -1
		_preview = Vector2.ZERO
	queue_redraw()
	accept_event()

# ドラッグ中のパン、選択移動、自由線を更新する。
func _mouse_motion(event: InputEventMouseMotion) -> void:
	if _panning:
		pan += event.position - _last_screen
		_last_screen = event.position
		queue_redraw()
		return
	if not _dragging:
		return
	var point := _snap(to_document(event.position))
	if _mode in ["move", "scale", "node"]:
		_preview = (point - _start) * zoom
	elif tool == "pencil" and (_points.is_empty() or _points[-1].distance_to(point) >= 1.5 / zoom):
		_points.append(point)
	queue_redraw()

# 文書の基本図形に合わせた属性を作る。
func _create_shape(kind: String, a: Vector2, b: Vector2) -> void:
	var rect := Rect2(a, b - a).abs()
	if kind == "rect" and rect.size.length() > 0:
		create_requested.emit("rect", {"x": _number(rect.position.x), "y": _number(rect.position.y), "width": _number(rect.size.x), "height": _number(rect.size.y), "rx": "0", "fill": "#4c8dff"})
	elif kind == "ellipse" and rect.size.length() > 0:
		create_requested.emit("ellipse", {"cx": _number(rect.get_center().x), "cy": _number(rect.get_center().y), "rx": _number(rect.size.x * 0.5), "ry": _number(rect.size.y * 0.5), "fill": "#4c8dff"})
	elif kind == "line" and a != b:
		create_requested.emit("line", {"x1": _number(a.x), "y1": _number(a.y), "x2": _number(b.x), "y2": _number(b.y), "stroke": "#202020", "stroke-width": "2"})

# ペンで置いた点を開いたパスにする。
func _finish_pen() -> void:
	if _points.size() > 1:
		create_requested.emit("path", {"d": _path_data(_points), "fill": "none", "stroke": "#202020", "stroke-width": "2"})
	_points.clear()
	queue_redraw()

# 表示中心を保ったまま指定位置の周りを拡大縮小する。
func _zoom_at(at: Vector2, factor: float) -> void:
	var before := to_document(at)
	zoom = clampf(zoom * factor, MIN_ZOOM, MAX_ZOOM)
	var after := to_document(at)
	pan += (after - before) * zoom
	refresh()
	status_changed.emit("Zoom %.0f%%" % (zoom * 100.0))

# 最上面の編集対象を概算境界で拾う。
func _hit(point: Vector2) -> int:
	var nodes: Array[Dictionary] = []
	_collect(document.root, nodes)
	for i in range(nodes.size() - 1, -1, -1):
		if document.bounds(nodes[i].uid).grow(4.0 / zoom).has_point(point):
			return nodes[i].uid
	return 0

# 選択枠の右下ハンドルに触れたか判断する。
func _hit_corner(point: Vector2) -> bool:
	var box: Rect2 = document.bounds(selected[0])
	return to_screen(box.end).distance_to(point) <= HANDLE * 2.0

# 選択中の直線パスから画面位置に近い編集点を探す。
func _hit_node(point: Vector2) -> int:
	var points: PackedVector2Array = document.edit_points(selected[0])
	for i in points.size():
		if to_screen(points[i]).distance_to(point) <= HANDLE * 2.0:
			return i
	return -1

# 描画対象をSVGの描画順に集める。
func _collect(node: Dictionary, out: Array[Dictionary]) -> void:
	for child in node.get("children", []):
		if child.get("kind", "") != "element":
			continue
		if child.name not in ["defs", "style", "title", "desc", "metadata"]:
			out.append(child)
		_collect(child, out)

# 格子が有効なら文書座標を最寄りの交点に合わせる。
func _snap(point: Vector2) -> Vector2:
	if not snap or grid_size <= 0:
		return point
	return Vector2(round(point.x / grid_size), round(point.y / grid_size)) * grid_size

# キャンバス内の文書表示枠を求める。
func _page_rect() -> Rect2:
	var rect: Rect2 = document.document_rect()
	var scaled := rect.size * zoom
	return Rect2((size - scaled) * 0.5 + pan, scaled)

# 文書座標と画面座標を相互に変換する。
func to_screen(point: Vector2) -> Vector2:
	return _page_rect().position + (point - document.document_rect().position) * zoom

func to_document(point: Vector2) -> Vector2:
	return document.document_rect().position + (point - _page_rect().position) / zoom

# 拡大時にも線の目安になる格子を描く。
func _draw_grid(page: Rect2) -> void:
	if not grid or grid_size * zoom < 6.0:
		return
	var step := grid_size * zoom
	var color := Color(0.18, 0.2, 0.24, 0.65)
	var x := page.position.x
	while x <= page.end.x:
		draw_line(Vector2(x, page.position.y), Vector2(x, page.end.y), color)
		x += step
	var y := page.position.y
	while y <= page.end.y:
		draw_line(Vector2(page.position.x, y), Vector2(page.end.x, y), color)
		y += step

# 点列をSVGのM/Lパス文字列にする。
func _path_data(points: PackedVector2Array) -> String:
	var out := "M %s %s" % [_number(points[0].x), _number(points[0].y)]
	for i in range(1, points.size()):
		out += " L %s %s" % [_number(points[i].x), _number(points[i].y)]
	return out

# SVG属性向けの短い数値にする。
func _number(value: float) -> String:
	return str(snappedf(value, 0.001))

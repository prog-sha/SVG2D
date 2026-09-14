# SVGの作図ツール、キャンバス、パーツ階層、見た目、保存をひとつの編集画面にまとめる。
# 責務: 操作をSVG文書へ適用し、履歴・パネル・ファイルを同期すること。
# 設計思想: Affinity型の左ツール・中央文書・右Studioとし、編集状態を実行時ノードから分離する。
@tool
extends Control

const Document = preload("document.gd") # SVG/XML文書モデル
const Canvas = preload("canvas.gd") # 中央の作図面
const UiStyle = preload("skin.gd") # 編集画面で共有する色と部品の見た目

const TOOLS := {
	"select": ["↖", "Move", "V"],
	"node": ["◈", "Node", "N"],
	"pen": ["✒", "Pen", "P"],
	"pencil": ["╱", "Pencil", "B"],
	"rect": ["□", "Rectangle", "R"],
	"ellipse": ["○", "Ellipse", "E"],
	"line": ["╲", "Line", "L"],
	"text": ["T", "Art Text", "T"],
	"hand": ["✥", "View", "H"],
} # 左の道具列に出す記号、名称、キー

var document: RefCounted # 編集中のSVG
var target_node: Object # シーンから開いたSVG2DまたはSVG3D
var canvas: Control # 図形と選択を表示する面
var layers: Tree # パーツとグループの階層
var source: CodeEdit # SVG文字列の直接編集
var status: Label # 現在の操作と表示倍率
var title_label: Label # ファイル名と未保存状態
var tool_title: Label # Context Toolbarに出す道具名
var selection_label: Label # 下端に出す選択数
var history_list: ItemList # 操作を行き来する履歴Studio
var open_dialog: FileDialog # SVGを開く選択画面
var save_dialog: FileDialog # SVGを保存する選択画面
var fields := {} # 選択要素の属性入力
var fill_color: ColorPickerButton # 塗り色の入力
var stroke_color: ColorPickerButton # 線色の入力
var width_field: LineEdit # Context Toolbarの線幅入力
var tool_buttons := {} # 選択状態を塗り分ける道具ボタン
var selected: Array[int] = [] # キャンバスと階層で共有する選択
var history: Array[String] = [] # 操作後のSVGスナップショット
var history_names: Array[String] = [] # 状態に移る操作名
var history_at := -1 # 現在表示している履歴位置
var saved_at := -1 # 最後に保存した履歴位置
var _syncing := false # UI反映が新しい操作として戻るのを防ぐ

# Affinity型のツール・文書・Studioレイアウトを作る。
func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	focus_mode = Control.FOCUS_ALL
	var root_panel := PanelContainer.new()
	root_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UiStyle.panel(root_panel, UiStyle.BAR)
	add_child(root_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 1)
	root_panel.add_child(column)
	column.add_child(_build_toolbar())
	column.add_child(_build_context())
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 1)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(body)
	body.add_child(_build_tools())
	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = -310
	body.add_child(split)
	canvas = Canvas.new()
	canvas.custom_minimum_size = Vector2(300, 240)
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(canvas)
	split.add_child(_build_studio())
	column.add_child(_build_status())
	canvas.selection_requested.connect(_select)
	canvas.create_requested.connect(_create)
	canvas.move_requested.connect(_move)
	canvas.scale_requested.connect(_scale)
	canvas.node_move_requested.connect(_move_node)
	canvas.status_changed.connect(_canvas_status)
	_build_dialogs()
	_new_document()
	_select_tool("select")

# 上部の文書操作とコンテキス操作を作る。
func _build_toolbar() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 48
	UiStyle.panel(panel, UiStyle.BAR)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 8)
	panel.add_child(margin)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 4)
	margin.add_child(bar)
	var brand := Label.new()
	brand.text = "SVG  DESIGNER"
	brand.add_theme_color_override("font_color", UiStyle.ACCENT)
	brand.add_theme_font_size_override("font_size", 15)
	brand.custom_minimum_size.x = 126
	bar.add_child(brand)
	_add_button(bar, "＋ New", _new_document, "New document · Ctrl+N")
	_add_button(bar, "Open", func() -> void: open_dialog.popup_centered_ratio(0.65), "Open SVG · Ctrl+O")
	_add_button(bar, "Save", _save, "Save SVG · Ctrl+S", true)
	bar.add_child(VSeparator.new())
	_add_button(bar, "↶", _undo, "Undo · Ctrl+Z")
	_add_button(bar, "↷", _redo, "Redo · Ctrl+Y")
	_add_button(bar, "Duplicate", _duplicate, "Duplicate · Ctrl+D")
	_add_button(bar, "Delete", _delete, "Delete selection")
	bar.add_child(VSeparator.new())
	_add_button(bar, "Group", _group, "Group · Ctrl+G")
	_add_button(bar, "Ungroup", _ungroup, "Ungroup · Ctrl+Shift+G")
	var arrange := MenuButton.new()
	arrange.text = "Arrange"
	UiStyle.button(arrange)
	var menu := arrange.get_popup()
	var actions := ["Move Back", "Move Front", "Align Left", "Align Right", "Align Top",
		"Align Bottom", "Center Horizontally", "Center Vertically", "Distribute Horizontally",
		"Distribute Vertically", "Rotate Left", "Rotate Right", "Flip Horizontally", "Flip Vertically"]
	for label in actions:
		menu.add_item(label)
	menu.id_pressed.connect(_arrange)
	bar.add_child(arrange)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	title_label = Label.new()
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.custom_minimum_size.x = 120
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_label.add_theme_color_override("font_color", UiStyle.MUTED)
	bar.add_child(title_label)
	return panel

# 道具に応じて頻繁に触る値を共通操作とは別の帯へ置く。
func _build_context() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 42
	UiStyle.panel(panel, UiStyle.PANEL)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 7)
	panel.add_child(bar)
	tool_title = Label.new()
	tool_title.text = "MOVE"
	tool_title.add_theme_color_override("font_color", UiStyle.TEXT)
	tool_title.add_theme_font_size_override("font_size", 13)
	tool_title.custom_minimum_size.x = 100
	tool_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bar.add_child(tool_title)
	bar.add_child(VSeparator.new())
	bar.add_child(_small_label("Fill"))
	fill_color = ColorPickerButton.new()
	fill_color.custom_minimum_size = Vector2(46, 28)
	fill_color.color = Color("4c8dff")
	fill_color.color_changed.connect(_context_color.bind("fill"))
	bar.add_child(fill_color)
	bar.add_child(_small_label("Stroke"))
	stroke_color = ColorPickerButton.new()
	stroke_color.custom_minimum_size = Vector2(46, 28)
	stroke_color.color_changed.connect(_context_color.bind("stroke"))
	bar.add_child(stroke_color)
	bar.add_child(_small_label("Width"))
	width_field = LineEdit.new()
	width_field.custom_minimum_size = Vector2(64, 28)
	width_field.placeholder_text = "2"
	UiStyle.input(width_field)
	width_field.text_submitted.connect(func(value: String) -> void:
		canvas.stroke_width = maxf(value.to_float(), 0.0)
		if fields.has("stroke-width"):
			fields["stroke-width"].text = value
			_apply_field("stroke-width"))
	bar.add_child(width_field)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	var grid_toggle := CheckButton.new()
	grid_toggle.text = "Grid"
	grid_toggle.button_pressed = false
	grid_toggle.toggled.connect(func(on: bool) -> void: canvas.grid = on; canvas.queue_redraw())
	bar.add_child(grid_toggle)
	var snap_toggle := CheckButton.new()
	snap_toggle.text = "Snap"
	snap_toggle.button_pressed = true
	snap_toggle.toggled.connect(func(on: bool) -> void: canvas.snap = on)
	bar.add_child(snap_toggle)
	_add_button(bar, "Fit", func() -> void: canvas.fit_document(), "Fit document · F")
	_add_button(bar, "100%", func() -> void: canvas.actual_size(), "Actual size · 1")
	return panel

# 左端の道具選択パネルを作る。
func _build_tools() -> Control:
	var shell := PanelContainer.new()
	shell.custom_minimum_size.x = 54
	UiStyle.panel(shell, UiStyle.PANEL)
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 2)
	shell.add_child(panel)
	var gap := Control.new()
	gap.custom_minimum_size.y = 5
	panel.add_child(gap)
	for key in TOOLS:
		var button := Button.new()
		button.text = TOOLS[key][0]
		button.tooltip_text = "%s · %s" % [TOOLS[key][1], TOOLS[key][2]]
		button.custom_minimum_size = Vector2(48, 36)
		button.pressed.connect(_select_tool.bind(key))
		UiStyle.button(button)
		button.add_theme_font_size_override("font_size", 18)
		tool_buttons[key] = button
		panel.add_child(button)
	return shell

# 右端のパーツ階層、見た目、SVGコードを作る。
func _build_studio() -> Control:
	var shell := PanelContainer.new()
	shell.custom_minimum_size.x = 310
	UiStyle.panel(shell, UiStyle.PANEL)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	shell.add_child(column)
	var head := Label.new()
	head.text = "  STUDIO"
	head.add_theme_color_override("font_color", UiStyle.MUTED)
	head.add_theme_font_size_override("font_size", 11)
	head.custom_minimum_size.y = 28
	column.add_child(head)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tabs.add_theme_color_override("font_selected_color", UiStyle.ACCENT)
	column.add_child(tabs)
	var layer_panel := VBoxContainer.new()
	layer_panel.name = "Layers"
	var layer_actions := HBoxContainer.new()
	layer_actions.add_theme_constant_override("separation", 4)
	_add_button(layer_actions, "＋", _new_layer_hint, "Add objects with a drawing tool")
	_add_button(layer_actions, "Group", _group, "Group selection")
	_add_button(layer_actions, "Ungroup", _ungroup, "Ungroup selection")
	var layer_space := Control.new()
	layer_space.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layer_actions.add_child(layer_space)
	_add_button(layer_actions, "⌫", _delete, "Delete selection")
	layer_panel.add_child(layer_actions)
	layers = Tree.new()
	layers.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layers.hide_root = true
	layers.select_mode = Tree.SELECT_SINGLE
	layers.add_theme_color_override("font_selected_color", UiStyle.TEXT)
	layers.add_theme_stylebox_override("selected", UiStyle.box(UiStyle.ACCENT_D, 5))
	layers.add_theme_stylebox_override("selected_focus", UiStyle.box(UiStyle.ACCENT, 5))
	layers.item_selected.connect(_tree_selected)
	layer_panel.add_child(layers)
	tabs.add_child(layer_panel)
	var transform := VBoxContainer.new()
	transform.name = "Transform"
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	transform.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)
	content.add_child(_section("GEOMETRY"))
	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 8)
	form.add_theme_constant_override("v_separation", 6)
	for key in ["x", "y", "width", "height", "rx", "ry", "cx", "cy", "r", "transform"]:
		var label := Label.new()
		label.text = key.to_upper()
		label.add_theme_color_override("font_color", UiStyle.MUTED)
		label.custom_minimum_size.x = 78
		form.add_child(label)
		var field := LineEdit.new()
		field.placeholder_text = "—"
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UiStyle.input(field)
		field.text_submitted.connect(func(_value: String) -> void: _apply_field(key))
		field.focus_exited.connect(func() -> void: _apply_field(key))
		fields[key] = field
		form.add_child(field)
	content.add_child(form)
	content.add_child(_section("APPEARANCE"))
	var look := GridContainer.new()
	look.columns = 2
	look.add_theme_constant_override("h_separation", 8)
	look.add_theme_constant_override("v_separation", 6)
	var look_fields := ["id", "fill", "fill-opacity", "stroke", "stroke-width",
		"stroke-opacity", "stroke-linecap", "stroke-linejoin", "stroke-dasharray", "opacity",
		"font-family", "font-size", "text"]
	for key in look_fields:
		var label := Label.new()
		label.text = key.replace("stroke-", "").replace("fill-", "").capitalize()
		label.add_theme_color_override("font_color", UiStyle.MUTED)
		label.custom_minimum_size.x = 78
		look.add_child(label)
		var field := LineEdit.new()
		field.placeholder_text = "—"
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UiStyle.input(field)
		field.text_submitted.connect(func(_value: String) -> void: _apply_field(key))
		field.focus_exited.connect(func() -> void: _apply_field(key))
		fields[key] = field
		look.add_child(field)
	content.add_child(look)
	tabs.add_child(transform)
	var history_panel := VBoxContainer.new()
	history_panel.name = "History"
	history_list = ItemList.new()
	history_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	history_list.add_theme_stylebox_override("selected", UiStyle.box(UiStyle.ACCENT_D, 5))
	history_list.item_selected.connect(_history_selected)
	history_panel.add_child(history_list)
	tabs.add_child(history_panel)
	var code := VBoxContainer.new()
	code.name = "SVG"
	source = CodeEdit.new()
	source.size_flags_vertical = Control.SIZE_EXPAND_FILL
	source.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	source.add_theme_stylebox_override("normal", UiStyle.box(UiStyle.DARK, 5))
	source.add_theme_color_override("font_color", UiStyle.TEXT)
	code.add_child(source)
	_add_button(code, "Apply SVG source", _apply_source, "Apply source · Ctrl+Enter", true)
	tabs.add_child(code)
	return shell

# 下端へ現在の操作と選択数を出し、作図面を覆わず手がかりを残す。
func _build_status() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 28
	UiStyle.panel(panel, UiStyle.BAR)
	var bar := HBoxContainer.new()
	panel.add_child(bar)
	status = Label.new()
	status.text = "Drag to select or move · Shift adds to selection"
	status.add_theme_color_override("font_color", UiStyle.MUTED)
	status.add_theme_font_size_override("font_size", 12)
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(status)
	selection_label = Label.new()
	selection_label.text = "No selection"
	selection_label.add_theme_color_override("font_color", UiStyle.MUTED)
	selection_label.add_theme_font_size_override("font_size", 12)
	bar.add_child(selection_label)
	return panel

# SVGでは描いた要素が層になることをLayersから知らせる。
func _new_layer_hint() -> void:
	status.text = "Draw an object to add a layer"

# Studio内の区切り見出しを同じ形で作る。
func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", UiStyle.ACCENT)
	label.add_theme_font_size_override("font_size", 11)
	label.custom_minimum_size.y = 26
	return label

# Context Toolbarに置く短い補助名を作る。
func _small_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", UiStyle.MUTED)
	label.add_theme_font_size_override("font_size", 12)
	return label

# 道具の状態をキャンバス、左列、Context Toolbarへまとめて反映する。
func _select_tool(key: String) -> void:
	if canvas == null or not TOOLS.has(key):
		return
	canvas.set_tool(key)
	tool_title.text = str(TOOLS[key][1]).to_upper()
	for name in tool_buttons:
		UiStyle.button(tool_buttons[name], name == key)
	status.text = _tool_hint(key)

# 道具ごとの次の操作を下端へ示す。
func _tool_hint(key: String) -> String:
	match key:
		"select": return "Drag to move · lower-right handle scales · Shift adds to selection"
		"node": return "Select a straight path, then drag its nodes"
		"pen": return "Click to place nodes · Enter or double-click finishes the path"
		"pencil": return "Drag to draw a freehand path"
		"rect", "ellipse", "line": return "Drag across the page to create a shape"
		"text": return "Click the page to create artistic text"
		_: return "Drag to pan · mouse wheel zooms around the pointer"

# キャンバスの倍率通知を下端へ流す。
func _canvas_status(text: String) -> void:
	status.text = text if text.begins_with("Zoom") else _tool_hint(canvas.tool)

# ファイルを開く・保存するダイアログを用意する。
func _build_dialogs() -> void:
	open_dialog = FileDialog.new()
	open_dialog.access = FileDialog.ACCESS_RESOURCES
	open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	open_dialog.filters = PackedStringArray(["*.svg ; SVG files"])
	open_dialog.file_selected.connect(_open)
	add_child(open_dialog)
	save_dialog = FileDialog.new()
	save_dialog.access = FileDialog.ACCESS_RESOURCES
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.filters = PackedStringArray(["*.svg ; SVG files"])
	save_dialog.file_selected.connect(_save_as)
	add_child(save_dialog)

# 空のSVGを作り、履歴と選択を初期化する。
func _new_document() -> void:
	document = Document.new()
	document.create()
	target_node = null
	selected.clear()
	_reset_history()
	if canvas:
		canvas.set_document(document)
	_sync()

# SVGファイルを読み込んで編集を始める。
func _open(file_path: String) -> void:
	var next: RefCounted = Document.new()
	var error: Error = next.load_file(file_path)
	if error != OK:
		_show_error("SVG could not be opened: %s" % error_string(error))
		return
	document = next
	target_node = null
	selected.clear()
	_reset_history()
	canvas.set_document(document)
	_sync()
	status.text = "Opened %s" % file_path

# シーンで選択されたSVG2D・SVG3Dのsrcを編集画面へ開く。
func edit_node(node: Object) -> void:
	if node == null or not node.has_method("get_src"):
		return
	var next: RefCounted = Document.new()
	var text: String = node.call("get_src")
	if text.is_empty():
		next.create()
	elif next.load_text(text) != OK:
		_show_error("The selected node does not contain editable SVG XML.")
		return
	document = next
	target_node = node
	selected.clear()
	_reset_history()
	canvas.set_document(document)
	_sync(false)
	status.text = "Editing scene node %s" % node.name

# 現在の保存先へ上書きし、未指定なら選択画面を開く。
func _save() -> void:
	if document.path.is_empty():
		save_dialog.popup_centered_ratio(0.65)
		return
	_save_as(document.path)

# 指定された場所へSVGのまま保存する。
func _save_as(file_path: String) -> void:
	var target := file_path if file_path.get_extension().to_lower() == "svg" else file_path + ".svg"
	var error: Error = document.save(target)
	if error != OK:
		_show_error("SVG could not be saved: %s" % error_string(error))
		return
	saved_at = history_at
	_sync_title()
	status.text = "Saved %s" % target

# 操作前後のSVGをひとつの履歴として記録する。
func _commit(label: String, change: Callable) -> Variant:
	var before: String = document.to_svg()
	var result: Variant = change.call()
	var after: String = document.to_svg()
	if before == after:
		return result
	if history_at + 1 < history.size():
		history.resize(history_at + 1)
		history_names.resize(history_at + 1)
	history.append(after)
	history_names.append(label)
	history_at += 1
	document.dirty = history_at != saved_at
	_sync()
	status.text = label
	return result

# 履歴を1つ前・後ろへ進め、SVG文書を復元する。
func _undo() -> void:
	if history_at <= 0:
		return
	_restore_history(history_at - 1)

func _redo() -> void:
	if history_at + 1 >= history.size():
		return
	_restore_history(history_at + 1)

func _restore_history(at: int) -> void:
	var file_path: String = document.path
	document.load_text(history[at])
	document.path = file_path
	history_at = at
	document.dirty = history_at != saved_at
	selected.clear()
	_sync()
	status.text = history_names[at]

# History Studioから選んだ時点へ戻る。
func _history_selected(at: int) -> void:
	if _syncing or at == history_at:
		return
	_restore_history(at)

# 新しい文書の先頭状態を履歴に入れる。
func _reset_history() -> void:
	history = [document.to_svg()]
	history_names = ["Open document"]
	history_at = 0
	saved_at = 0
	document.dirty = false

# キャンバスからの選択を追加・置き換えする。
func _select(uid: int, additive: bool) -> void:
	if uid == 0:
		if not additive:
			selected.clear()
	elif additive:
		if uid in selected:
			selected.erase(uid)
		else:
			selected.append(uid)
	else:
		selected = [uid]
	_sync_selection()

# 新しい図形をSVG木の最上面に追加する。
func _create(tag: String, attrs: Dictionary) -> void:
	var made: Dictionary = _commit("Create %s" % tag, func() -> Dictionary:
		var values := attrs.duplicate()
		var text: String = values.get("text", "")
		values.erase("text")
		var node: Dictionary = document.add(tag, values)
		if tag == "text":
			document.set_text(node.uid, text)
		return node
	)
	if not made.is_empty():
		selected = [made.uid]
		_sync_selection()

# 選択要素をひとつの操作で移動する。
func _move(uids: Array[int], delta: Vector2) -> void:
	_commit("Move selection", func() -> void:
		for uid in uids:
			document.translate(uid, delta)
	)

# 選択ハンドルの拡大と直線パスの点移動を履歴へ記録する。
func _scale(uid: int, factor: Vector2, origin: Vector2) -> void:
	_commit("Scale selection", func() -> void: document.scale_around(uid, factor, origin))

func _move_node(uid: int, index: int, point: Vector2) -> void:
	_commit("Move path node", func() -> void: document.set_edit_point(uid, index, point))

# 選択要素の複製、削除、グループ、描画順を操作する。
func _duplicate() -> void:
	var next: Array[int] = []
	_commit("Duplicate selection", func() -> void:
		for uid in selected:
			var node: Dictionary = document.duplicate_element(uid)
			if not node.is_empty():
				document.translate(node.uid, Vector2(10, 10))
				next.append(node.uid)
	)
	selected = next
	_sync_selection()

func _delete() -> void:
	if selected.is_empty():
		return
	_commit("Delete selection", func() -> void:
		for uid in selected.duplicate():
			document.remove(uid)
	)
	selected.clear()
	_sync_selection()

func _group() -> void:
	if selected.size() < 1:
		return
	var made: Dictionary = _commit("Group selection", func() -> Dictionary: return document.group(selected))
	if not made.is_empty():
		selected = [made.uid]
		_sync_selection()

func _ungroup() -> void:
	if selected.size() != 1:
		return
	var next: Array[int] = _commit("Ungroup selection", func() -> Array[int]: return document.ungroup(selected[0]))
	selected = next
	_sync_selection()

func _reorder(offset: int) -> void:
	if selected.size() != 1:
		return
	_commit("Change stacking order", func() -> void: document.reorder(selected[0], offset))

# 配置メニューの操作を選択要素へ振り分ける。
func _arrange(id: int) -> void:
	match id:
		0: _reorder(-1)
		1: _reorder(1)
		2: _align("left")
		3: _align("right")
		4: _align("top")
		5: _align("bottom")
		6: _align("center_x")
		7: _align("center_y")
		8: _distribute(true)
		9: _distribute(false)
		10: _rotate(-90.0)
		11: _rotate(90.0)
		12: _flip(true)
		13: _flip(false)

# 複数要素の辺または中心を基準に揃える。
func _align(side: String) -> void:
	if selected.size() < 2:
		return
	var boxes: Array[Rect2] = []
	for uid in selected:
		boxes.append(document.bounds(uid))
	var target: float
	match side:
		"left": target = boxes.map(func(rect: Rect2) -> float: return rect.position.x).min()
		"right": target = boxes.map(func(rect: Rect2) -> float: return rect.end.x).max()
		"top": target = boxes.map(func(rect: Rect2) -> float: return rect.position.y).min()
		"bottom": target = boxes.map(func(rect: Rect2) -> float: return rect.end.y).max()
		"center_x": target = boxes[0].get_center().x
		_: target = boxes[0].get_center().y
	_commit("Align %s" % side, func() -> void:
		for i in selected.size():
			var current: float
			if side == "left": current = boxes[i].position.x
			elif side == "right": current = boxes[i].end.x
			elif side == "top": current = boxes[i].position.y
			elif side == "bottom": current = boxes[i].end.y
			elif side == "center_x": current = boxes[i].get_center().x
			else: current = boxes[i].get_center().y
			var delta := Vector2(target - current, 0) if side in ["left", "right", "center_x"] else Vector2(0, target - current)
			document.translate(selected[i], delta)
	)

# 選択要素の中心を両端の間へ等間隔に並べる。
func _distribute(horizontal: bool) -> void:
	if selected.size() < 3:
		return
	var order: Array[int] = selected.duplicate()
	order.sort_custom(func(a: int, b: int) -> bool:
		return document.bounds(a).get_center().x < document.bounds(b).get_center().x if horizontal else document.bounds(a).get_center().y < document.bounds(b).get_center().y)
	var first: Vector2 = document.bounds(order[0]).get_center()
	var last: Vector2 = document.bounds(order[-1]).get_center()
	_commit("Distribute selection", func() -> void:
		for i in range(1, order.size() - 1):
			var ratio := float(i) / float(order.size() - 1)
			var wanted := first.lerp(last, ratio)
			var current: Vector2 = document.bounds(order[i]).get_center()
			var delta := Vector2(wanted.x - current.x, 0) if horizontal else Vector2(0, wanted.y - current.y)
			document.translate(order[i], delta)
	)

# 選択要素を個別の中心で回転または反転する。
func _rotate(degrees: float) -> void:
	_commit("Rotate selection", func() -> void:
		for uid in selected:
			document.rotate_around(uid, degrees, document.bounds(uid).get_center())
	)

func _flip(horizontal: bool) -> void:
	_commit("Flip selection", func() -> void:
		for uid in selected:
			var box: Rect2 = document.bounds(uid)
			var factor := Vector2(-1, 1) if horizontal else Vector2(1, -1)
			document.scale_around(uid, factor, box.get_center())
	)

# 階層ツリーの選択をキャンバスへ反映する。
func _tree_selected() -> void:
	if _syncing:
		return
	var item := layers.get_selected()
	selected = [int(item.get_metadata(0))] if item else []
	_sync_selection(false)

# 見た目パネルの値を選択要素へ適用する。
func _apply_field(key: String) -> void:
	if _syncing or selected.is_empty():
		return
	var value: String = fields[key].text
	_commit("Set %s" % key, func() -> void:
		for uid in selected:
			if key == "text":
				document.set_text(uid, value)
			else:
				document.set_attr(uid, key, value)
	)

func _apply_color(key: String, color: Color) -> void:
	if _syncing or selected.is_empty():
		return
	var value := color.to_html(color.a < 1.0)
	_commit("Set %s color" % key, func() -> void:
		for uid in selected:
			document.set_attr(uid, key, "#" + value)
	)

# Context Toolbarの色を新規図形と選択要素の両方へ反映する。
func _context_color(color: Color, key: String) -> void:
	if canvas != null:
		canvas.set(key, color)
	_apply_color(key, color)

# コードパネルのSVGを解析し、正しいとき文書全体を置き換える。
func _apply_source() -> void:
	var probe: RefCounted = Document.new()
	var error: Error = probe.load_text(source.text)
	if error != OK:
		_show_error("SVG has an XML error: %s" % error_string(error))
		return
	_commit("Apply SVG source", func() -> void: document.load_text(source.text))
	selected.clear()
	_sync_selection()

# 文書・階層・見た目・タイトルをまとめて同期する。
func _sync(update_target := true) -> void:
	_syncing = true
	canvas.refresh()
	canvas.set_selection(selected)
	_rebuild_layers()
	source.text = document.to_svg()
	_sync_fields()
	_sync_history()
	_sync_title()
	if update_target and is_instance_valid(target_node):
		target_node.call("set_src", document.to_svg())
		EditorInterface.mark_scene_as_unsaved()
	_syncing = false

func _sync_selection(select_tree := true) -> void:
	_syncing = true
	canvas.set_selection(selected)
	_sync_fields()
	if select_tree and not selected.is_empty():
		_select_tree_uid(layers.get_root(), selected[0])
	selection_label.text = "No selection" if selected.is_empty() else "%d selected" % selected.size()
	_syncing = false

# SVGの木からパーツ・グループツリーを作り直す。
func _rebuild_layers() -> void:
	layers.clear()
	var root_item := layers.create_item()
	_add_layer_items(document.root, root_item)

func _add_layer_items(node: Dictionary, parent: TreeItem) -> void:
	for i in range(node.get("children", []).size() - 1, -1, -1):
		var child: Dictionary = node.children[i]
		if child.get("kind", "") != "element":
			continue
		var item := layers.create_item(parent)
		var label: String = child.attrs.get("id", "")
		item.set_text(0, "%s%s" % [child.name, "  #" + label if not label.is_empty() else ""])
		item.set_metadata(0, child.uid)
		item.set_tooltip_text(0, "<%s>" % child.name)
		_add_layer_items(child, item)

func _select_tree_uid(item: TreeItem, uid: int) -> bool:
	if item == null:
		return false
	var meta: Variant = item.get_metadata(0)
	if meta != null and int(meta) == uid:
		item.select(0)
		layers.scroll_to_item(item)
		return true
	var child := item.get_first_child()
	while child:
		if _select_tree_uid(child, uid):
			return true
		child = child.get_next()
	return false

# 選択要素の属性と色を見た目パネルに反映する。
func _sync_fields() -> void:
	for field in fields.values():
		field.editable = selected.size() == 1
		field.text = ""
	if selected.size() != 1:
		return
	var node: Dictionary = document.find(selected[0])
	if node.is_empty():
		return
	for key in fields:
		fields[key].text = _node_text(node) if key == "text" else str(node.attrs.get(key, ""))
	fill_color.color = Color.from_string(node.attrs.get("fill", "#000000"), Color.BLACK)
	stroke_color.color = Color.from_string(node.attrs.get("stroke", "#000000"), Color.BLACK)
	width_field.text = str(node.attrs.get("stroke-width", ""))
	if not width_field.text.is_empty():
		canvas.stroke_width = maxf(width_field.text.to_float(), 0.0)

# 操作履歴を古い順に並べ、現在位置を緑の選択面で示す。
func _sync_history() -> void:
	if history_list == null:
		return
	history_list.clear()
	for label in history_names:
		history_list.add_item(label)
	if history_at >= 0:
		history_list.select(history_at)
		history_list.ensure_current_is_visible()
	selection_label.text = "No selection" if selected.is_empty() else "%d selected" % selected.size()

# タイトルにファイル名と未保存印を表示する。
func _sync_title() -> void:
	var name: String
	if is_instance_valid(target_node):
		name = target_node.name
	elif document.path.is_empty():
		name = "Untitled.svg"
	else:
		name = document.path.get_file()
	title_label.text = "%s%s" % [name, " *" if document.dirty else ""]
	title_label.tooltip_text = document.path

# text要素の直接な文字を読む。
func _node_text(node: Dictionary) -> String:
	var out := ""
	for child in node.get("children", []):
		if child.get("kind", "") in ["text", "cdata"]:
			out += child.text
	return out

# ツールバーの共通ボタンを作る。
func _add_button(parent: Control, text: String, action: Callable, tooltip := "", primary := false) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(action)
	UiStyle.button(button, primary)
	parent.add_child(button)
	return button

# 読み書きの問題をエディター内のダイアログで知らせる。
func _show_error(message: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "SVG Editor"
	dialog.dialog_text = message
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()

# よく使うキー操作をキャンバスとパネルのどこからでも使えるようにする。
func _shortcut_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.ctrl_pressed:
		match event.keycode:
			KEY_N: _new_document()
			KEY_O: open_dialog.popup_centered_ratio(0.65)
			KEY_S:
				if event.shift_pressed: save_dialog.popup_centered_ratio(0.65)
				else: _save()
			KEY_Z: _redo() if event.shift_pressed else _undo()
			KEY_Y: _redo()
			KEY_D: _duplicate()
			KEY_G: _ungroup() if event.shift_pressed else _group()
		get_viewport().set_input_as_handled()
		return
	match event.keycode:
		KEY_DELETE, KEY_BACKSPACE: _delete()
		KEY_V: _select_tool("select")
		KEY_N: _select_tool("node")
		KEY_P: _select_tool("pen")
		KEY_B: _select_tool("pencil")
		KEY_R: _select_tool("rect")
		KEY_E: _select_tool("ellipse")
		KEY_L: _select_tool("line")
		KEY_T: _select_tool("text")
		KEY_H: _select_tool("hand")
		KEY_F: canvas.fit_document()
		KEY_1: canvas.actual_size()
		_: return
	get_viewport().set_input_as_handled()

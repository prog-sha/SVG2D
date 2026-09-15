# SVGAnimateの固定トポロジー接点を選び、AnimationPlayerへキー登録するInspector UI。
@tool
extends VBoxContainer

var target: Node
var path_select: OptionButton
var point_select: SpinBox
var mode_buttons: Array[Button] = []

func setup(node: Node) -> void:
	target = node
	var title := Label.new()
	title.text = "Path Editor"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)
	var chooser := HBoxContainer.new()
	add_child(chooser)
	path_select = OptionButton.new()
	path_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for path in int(target.call("get_path_count")):
		path_select.add_item("Path %d" % path, path)
	path_select.item_selected.connect(_path_changed)
	chooser.add_child(path_select)
	point_select = SpinBox.new()
	point_select.min_value = 0
	point_select.step = 1
	point_select.custom_arrow_step = 1
	point_select.value_changed.connect(_point_changed)
	chooser.add_child(point_select)
	var modes := HBoxContainer.new()
	add_child(modes)
	for spec in [["Anchor (A)", "point"], ["In (I)", "in"], ["Out (O)", "out"]]:
		var button := Button.new()
		button.text = spec[0]
		button.toggle_mode = true
		button.pressed.connect(_mode_pressed.bind(spec[1]))
		modes.add_child(button)
		mode_buttons.append(button)
	var key := Button.new()
	key.text = "Insert Point Key (K)"
	key.tooltip_text = "選択中の接点番号をAnimationPlayerの値トラックへ登録します"
	key.pressed.connect(_insert_key)
	add_child(key)
	_refresh_point_range()
	_sync_plugin("point")

func _plugin() -> Node:
	return get_tree().get_first_node_in_group("svg2d_editor_plugin")

func _refresh_point_range() -> void:
	var path := path_select.get_selected_id() if path_select.item_count > 0 else 0
	point_select.max_value = maxi(0, int(target.call("get_point_count", path)) - 1)
	point_select.value = mini(int(point_select.value), int(point_select.max_value))

func _path_changed(_index: int) -> void:
	_refresh_point_range()
	_sync_plugin("point")

func _point_changed(_value: float) -> void:
	_sync_plugin("")

func _mode_pressed(mode: String) -> void:
	_sync_plugin(mode)

func _sync_plugin(mode: String) -> void:
	var plugin := _plugin()
	if plugin == null or path_select.item_count == 0:
		return
	plugin.call("select_path_control", target, path_select.get_selected_id(), int(point_select.value), mode)
	var active := String(plugin.get("path_part"))
	for index in mode_buttons.size():
		mode_buttons[index].button_pressed = ["point", "in", "out"][index] == active

func _insert_key() -> void:
	var plugin := _plugin()
	if plugin != null and path_select.item_count > 0:
		plugin.call("insert_path_key", target, path_select.get_selected_id(), int(point_select.value))

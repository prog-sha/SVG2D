# SVGAnimateの固定トポロジー接点を選び、AnimationPlayerへキー登録するInspector UI。
@tool
extends VBoxContainer

var target: Node
var path_select: OptionButton
var point_select: SpinBox
var mode_buttons: Array[Button] = []
var key_button: Button
var syncing_from_plugin := false

func _ready() -> void:
	if key_button != null and has_theme_icon("Key", "EditorIcons"):
		key_button.icon = get_theme_icon("Key", "EditorIcons")
	# InspectorPluginはsetup後にControlをSceneTreeへ追加する。
	# 追加済みになった時点で初めてEditorPluginと状態を同期する。
	if is_instance_valid(target):
		_sync_plugin("point")
	var plugin := _plugin()
	if plugin != null and not plugin.path_control_selected.is_connected(_on_plugin_selected):
		plugin.path_control_selected.connect(_on_plugin_selected)

func _exit_tree() -> void:
	var plugin := _plugin()
	if plugin != null and plugin.path_control_selected.is_connected(_on_plugin_selected):
		plugin.path_control_selected.disconnect(_on_plugin_selected)

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
	if path_select.item_count == 0:
		var notice := Label.new()
		notice.text = "No editable geometry. Use SVG paths or basic shapes."
		add_child(notice)
	path_select.item_selected.connect(_path_changed)
	chooser.add_child(path_select)
	point_select = SpinBox.new()
	point_select.min_value = 0
	point_select.step = 1
	point_select.custom_arrow_step = 1
	point_select.value_changed.connect(_point_changed)
	chooser.add_child(point_select)
	key_button = Button.new()
	key_button.name = "KeySelectedControlButton"
	key_button.text = "+"
	key_button.flat = true
	key_button.tooltip_text = "Insert a key for this anchor or handle in AnimationPlayer."
	key_button.pressed.connect(_insert_key)
	chooser.add_child(key_button)
	var modes := HBoxContainer.new()
	add_child(modes)
	for spec in [["Anchor (A)", "point"], ["In (I)", "in"], ["Out (O)", "out"]]:
		var button := Button.new()
		button.text = spec[0]
		button.toggle_mode = true
		button.pressed.connect(_mode_pressed.bind(spec[1]))
		modes.add_child(button)
		mode_buttons.append(button)
	var all_points := Button.new()
	all_points.name = "CreateAllPointsAnimationPlayerButton"
	all_points.text = "Create AnimationPlayer (All SVG Properties)"
	all_points.tooltip_text = "Create tracks for anchors, cubic handles, per-path paint and stroke settings, and node modulate."
	all_points.pressed.connect(_create_all_points_player)
	add_child(all_points)
	_refresh_point_range()
	if is_inside_tree():
		_sync_plugin("point")

func _on_plugin_selected(node: Node, path: int, point: int, part: String) -> void:
	if node != target or path_select == null or point_select == null:
		return
	syncing_from_plugin = true
	path_select.select(path)
	_refresh_point_range()
	point_select.value = point
	for index in mode_buttons.size():
		mode_buttons[index].button_pressed = ["point", "in", "out"][index] == part
	_refresh_modes()
	syncing_from_plugin = false

func _plugin() -> Node:
	# Inspectorの構築中と破棄中はControlがSceneTreeを持たない。
	# get_tree()自体がその状態をエラーとして報告するため、先に判定する。
	if not is_inside_tree():
		return null
	var tree := get_tree()
	return tree.get_first_node_in_group("svg2d_editor_plugin") if tree != null else null

func _refresh_point_range() -> void:
	if not is_instance_valid(target) or path_select == null or point_select == null:
		return
	var path := path_select.get_selected_id() if path_select.item_count > 0 else 0
	point_select.max_value = maxi(0, int(target.call("get_point_count", path)) - 1)
	point_select.value = mini(int(point_select.value), int(point_select.max_value))
	_refresh_modes()

func _refresh_modes() -> void:
	if mode_buttons.size() < 3 or not is_instance_valid(target) or path_select.item_count == 0:
		return
	var path := path_select.get_selected_id()
	var point := int(point_select.value)
	mode_buttons[1].disabled = not target.call("has_in_handle", path, point)
	mode_buttons[2].disabled = not target.call("has_out_handle", path, point)

func _path_changed(_index: int) -> void:
	if syncing_from_plugin: return
	_refresh_point_range()
	_sync_plugin("point")

func _point_changed(_value: float) -> void:
	if syncing_from_plugin: return
	_refresh_modes()
	var plugin := _plugin()
	var active := String(plugin.get("path_part")) if plugin != null else "point"
	_sync_plugin("point" if (active == "in" and mode_buttons[1].disabled)
		or (active == "out" and mode_buttons[2].disabled) else "")

func _mode_pressed(mode: String) -> void:
	if mode == "in" and mode_buttons[1].disabled: return
	if mode == "out" and mode_buttons[2].disabled: return
	_sync_plugin(mode)

func _sync_plugin(mode: String) -> void:
	if not is_instance_valid(target) or path_select == null or point_select == null:
		return
	var plugin := _plugin()
	if plugin == null or path_select.item_count == 0:
		return
	plugin.call("select_path_control", target, path_select.get_selected_id(), int(point_select.value), mode)
	var active := String(plugin.get("path_part"))
	for index in mode_buttons.size():
		mode_buttons[index].button_pressed = ["point", "in", "out"][index] == active

func _insert_key() -> void:
	if not is_instance_valid(target) or path_select == null or point_select == null:
		return
	var plugin := _plugin()
	if plugin != null and path_select.item_count > 0:
		plugin.call("insert_path_key", target, path_select.get_selected_id(), int(point_select.value),
			String(plugin.get("path_part")))

func _create_all_points_player() -> void:
	var plugin := _plugin()
	if plugin != null and is_instance_valid(target):
		plugin.call("create_all_point_animation_player", target)

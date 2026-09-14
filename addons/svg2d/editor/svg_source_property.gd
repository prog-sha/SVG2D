# src を文字列入力ではなく、SVG 素材の選択と絵のプレビューとして見せる。
@tool
extends EditorProperty

const SVGPreview = preload("svg_preview.gd")

var preview: Control
var path_label: Label
var detail_label: Label
var error_label: Label
var open_button: Button
var clear_button: Button
var dialog: FileDialog

func _init() -> void:
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	add_child(content)
	set_bottom_editor(content)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	content.add_child(toolbar)

	open_button = Button.new()
	open_button.text = "Open SVG…"
	open_button.tooltip_text = "Choose an SVG file from this project"
	open_button.pressed.connect(_open_file)
	toolbar.add_child(open_button)
	add_focusable(open_button)

	clear_button = Button.new()
	clear_button.text = "Clear"
	clear_button.tooltip_text = "Remove the SVG from this node"
	clear_button.pressed.connect(_clear)
	toolbar.add_child(clear_button)
	add_focusable(clear_button)

	path_label = Label.new()
	path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	path_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	toolbar.add_child(path_label)

	preview = SVGPreview.new()
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(preview)

	detail_label = Label.new()
	detail_label.add_theme_color_override("font_color", Color("#aeb3bd"))
	content.add_child(detail_label)

	error_label = Label.new()
	error_label.add_theme_color_override("font_color", Color("#ff8b82"))
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(error_label)

	dialog = FileDialog.new()
	dialog.title = "Open SVG"
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_RESOURCES
	dialog.filters = PackedStringArray(["*.svg ; SVG files"])
	dialog.file_selected.connect(_file_selected)
	add_child(dialog)

func _update_property() -> void:
	var object := get_edited_object()
	if object == null:
		return
	var value: String = object.get(get_edited_property())
	_render_value(value)

func _open_file() -> void:
	var current := _current_path()
	if not current.is_empty():
		dialog.current_path = current
	dialog.popup_centered_ratio(0.72)

func _file_selected(path: String) -> void:
	emit_changed(get_edited_property(), path, "", false)
	_render_value(path)

func _clear() -> void:
	emit_changed(get_edited_property(), "", "", false)
	_render_value("")

func _current_path() -> String:
	var object := get_edited_object()
	if object == null:
		return ""
	var value := String(object.get(get_edited_property())).strip_edges()
	return value if value.begins_with("res://") and value.get_extension().to_lower() == "svg" else ""

func _render_value(value: String) -> void:
	var clean := value.strip_edges()
	var is_path := clean.begins_with("res://") or clean.begins_with("user://")
	path_label.text = clean if is_path else ("Embedded SVG" if not clean.is_empty() else "No SVG selected")
	path_label.tooltip_text = path_label.text
	clear_button.disabled = clean.is_empty()
	open_button.text = "Replace SVG…" if not clean.is_empty() else "Open SVG…"
	error_label.text = ""
	detail_label.text = ""
	preview.set_texture(null)
	if clean.is_empty():
		detail_label.text = "Choose a .svg file to preview it here."
		return
	if is_path and not FileAccess.file_exists(clean):
		error_label.text = "SVG file not found: %s" % clean
		return

	# 本体と同じラスタライザで描くため、プレビューとシーンの結果がずれない。
	var renderer: Node2D = ClassDB.instantiate("SVG2D")
	renderer.set("src", clean if is_path else value)
	var rendered: Texture2D = renderer.call("get_texture")
	renderer.free()
	if rendered == null:
		error_label.text = "This file could not be rendered as a supported SVG."
		return
	preview.set_texture(rendered)
	var dimensions := rendered.get_size()
	detail_label.text = "%d × %d px  •  SVG" % [roundi(dimensions.x), roundi(dimensions.y)]

# SVG2D / SVG3D の src だけを素材向けの表示に差し替える。
@tool
extends EditorInspectorPlugin

const SVGSourceProperty = preload("svg_source_property.gd")
const SVGHitboxControl = preload("svg_hitbox_control.gd")

func _can_handle(object: Object) -> bool:
	return object != null and (object.is_class("SVG2D") or object.is_class("SVG3D"))

func _parse_property(
		_object: Object,
		_type: Variant.Type,
		name: String,
		_hint_type: PropertyHint,
		_hint_string: String,
		_usage_flags: int,
		_wide: bool
) -> bool:
	if name != "src":
		return false
	add_property_editor(name, SVGSourceProperty.new())
	return true

func _parse_end(object: Object) -> void:
	var hitbox := SVGHitboxControl.new()
	hitbox.setup(object)
	add_custom_control(hitbox)

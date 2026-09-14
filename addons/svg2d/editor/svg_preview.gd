# 透明部分が分かる盤の上に、SVG を縦横比を保って収める。
@tool
extends Control

var texture: Texture2D

func _ready() -> void:
	custom_minimum_size = Vector2(0, 180)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_texture(value: Texture2D) -> void:
	texture = value
	queue_redraw()

func _draw() -> void:
	var tile := 12.0
	var light := Color("#34373d")
	var dark := Color("#2b2e33")
	for y in range(ceili(size.y / tile)):
		for x in range(ceili(size.x / tile)):
			draw_rect(Rect2(x * tile, y * tile, tile, tile), light if (x + y) % 2 == 0 else dark)
	draw_rect(Rect2(Vector2.ZERO, size), Color("#50545c"), false, 1.0)
	if texture == null:
		return
	var source := texture.get_size()
	if source.x <= 0.0 or source.y <= 0.0:
		return
	var available := (size - Vector2(28, 28)).max(Vector2.ONE)
	var scale := min(available.x / source.x, available.y / source.y, 1.0)
	var target_size: Vector2 = source * scale
	var target := Rect2((size - target_size) * 0.5, target_size)
	draw_texture_rect(texture, target, false)

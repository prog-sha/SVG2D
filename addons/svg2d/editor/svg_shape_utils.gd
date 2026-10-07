# SVGの表示画素を、選択判定と当たり判定で共有するための小道具。
@tool
extends RefCounted

const ALPHA_THRESHOLD := 0.1

static var _mask_texture: WeakRef
static var _mask: BitMap

static func _clear_mask() -> void:
	_mask = null

static func _texture_mask(texture: Texture2D) -> BitMap:
	var previous := _mask_texture.get_ref() as Texture2D if _mask_texture else null
	if previous != texture:
		if previous and previous.changed.is_connected(_clear_mask):
			previous.changed.disconnect(_clear_mask)
		_mask_texture = weakref(texture)
		texture.changed.connect(_clear_mask)
		_mask = null
	if _mask == null:
		var image := texture.get_image()
		if image == null or image.is_empty():
			return null
		_mask = BitMap.new()
		_mask.create_from_image_alpha(image, ALPHA_THRESHOLD)
	return _mask

static func natural_image(node: Object) -> Image:
	if node == null:
		return null
	# 編集カメラやズームに依存した巨大テクスチャを輪郭抽出へ使わない。
	# 同じC++ラスタライザを自然寸法で一度だけ描き、呼び出し側で結果を使い切る。
	var animated := node.is_class("SVGAnimate2D") or node.is_class("SVGAnimate3D")
	var renderer := ClassDB.instantiate("SVG2D") as Node2D
	if renderer == null:
		return null
	renderer.set("adaptive", false)
	renderer.set("animation_enabled", false)
	# 変更済みマークアップを使い、useの継承スタイルも保持する。
	renderer.set("src", node.call("get_edited_svg") if animated else node.get("src"))
	var texture := renderer.call("get_texture") as Texture2D
	var image := texture.get_image() if texture else null
	renderer.free()
	return image

static func opaque_at(node: Object, svg_point: Vector2) -> bool:
	var size: Vector2 = node.call("get_svg_size")
	if size.x <= 0.0 or size.y <= 0.0:
		return false
	# 最後の画像のマスクだけ保持し、変更通知が来るまでGPU読戻しを省く。
	var texture := node.call("get_texture") as Texture2D
	var mask: BitMap
	if texture:
		mask = _texture_mask(texture)
	else:
		var image := natural_image(node)
		if image and not image.is_empty():
			mask = BitMap.new()
			mask.create_from_image_alpha(image, ALPHA_THRESHOLD)
	if mask == null:
		return false
	var pixels := mask.get_size()
	if pixels.x <= 0.0 or pixels.y <= 0.0:
		return false
	var point := svg_point
	if bool(node.get("flip_h")):
		point.x = size.x - point.x
	if bool(node.get("flip_v")):
		point.y = size.y - point.y
	var pixel := Vector2i(
		clampi(floori(point.x * pixels.x / size.x), 0, int(pixels.x) - 1),
		clampi(floori(point.y * pixels.y / size.y), 0, int(pixels.y) - 1)
	)
	# 細い線も編集時につかめるよう、自然画像の周囲1pxを許容する。
	for y in range(maxi(0, pixel.y - 1), mini(int(pixels.y), pixel.y + 2)):
		for x in range(maxi(0, pixel.x - 1), mini(int(pixels.x), pixel.x + 2)):
			if mask.get_bit(x, y):
				return true
	return false

static func outer_polygons(node: Object, epsilon := 1.0) -> Array[PackedVector2Array]:
	var result: Array[PackedVector2Array] = []
	var image := natural_image(node)
	if image == null or image.is_empty():
		return result
	var bitmap := BitMap.new()
	bitmap.create_from_image_alpha(image, ALPHA_THRESHOLD)
	# Godotのmarching squaresは透明な穴を外周として列挙せず、塗られた島の
	# 外輪郭だけを返す。RDP簡略化は自然寸法の約1pxまでに留める。
	var raw: Array[PackedVector2Array] = bitmap.opaque_to_polygons(
		Rect2i(Vector2i.ZERO, image.get_size()), epsilon)
	var natural: Vector2 = node.call("get_svg_size")
	var image_size := Vector2(image.get_size())
	for polygon in raw:
		if polygon.size() < 3:
			continue
		var scaled := PackedVector2Array()
		for point in polygon:
			scaled.append(point * natural / image_size)
		result.append(scaled)
	return result

static func displayed_point_2d(node: Object, point: Vector2) -> Vector2:
	var size: Vector2 = node.call("get_svg_size")
	if bool(node.get("flip_h")):
		point.x = size.x - point.x
	if bool(node.get("flip_v")):
		point.y = size.y - point.y
	return point + Vector2(node.get("offset"))

static func displayed_point_3d(node: Object, point: Vector2) -> Vector3:
	var size: Vector2 = node.call("get_svg_size")
	if bool(node.get("flip_h")):
		point.x = size.x - point.x
	if bool(node.get("flip_v")):
		point.y = size.y - point.y
	var offset := Vector2(node.get("offset"))
	var pixel_size := float(node.get("pixel_size"))
	return Vector3(
		(point.x - size.x * 0.5 + offset.x) * pixel_size,
		(-(point.y - size.y * 0.5) + offset.y) * pixel_size,
		0.0
	)

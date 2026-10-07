# 参照SVGがファイル・アニメーション・キャッシュ・ノード表示を通る結果を検証する。
# 責務: 合成した最終画素と保存復元の確認。期待色は手計算し、描画APIから逆算しない。
# 設計思想: resvgの画像比較とCairoSVGの入力経路比較を独自の小さな図形へ適用する。
extends RefCounted
const SOURCE := "res://tests/svg/integration/symbol.svg" # 同じ意味を全公開ノードへ渡す素材

static func frame(tree: SceneTree) -> void:
	await tree.process_frame
	await RenderingServer.frame_post_draw

# 整数座標の内部画素を調べ、半透明図形の重なりを1回だけ合成したことを確認する。
static func inspect(tree: SceneTree, image: Image, label: String, red: bool = true, premultiplied: bool = true) -> void:
	var expected := Color(1, 0, 0, 0.25) if red else Color(0, 1, 0, 0.25)
	for point in [Vector2i(15, 11), Vector2i(25, 21), Vector2i(41, 37)]:
		var sample := Vector2i(Vector2(point) * Vector2(image.get_size()) / Vector2(64, 48))
		var color := image.get_pixelv(sample)
		if premultiplied and color.a > 0:
			color.r /= color.a; color.g /= color.a; color.b /= color.a
		# アニメーションで先頭パスだけ色を変えると、後ろの重なりは赤のまま。
		var want := expected if point == Vector2i(15, 11) else Color(1, 0, 0, 0.25)
		tree.check(absf(color.r - want.r) < 0.02 and absf(color.g - want.g) < 0.02
			and absf(color.b - want.b) < 0.02 and absf(color.a - want.a) < 0.02,
			"%s pixel %s: expected %s, got %s" % [label, point, want, color])
	tree.check(image.get_pixelv(Vector2i(Vector2(9, 15) * Vector2(image.get_size()) / Vector2(64, 48))).a < 0.01, label + " symbol transform missing")

static func run(tree: SceneTree) -> void:
	closed_path_inputs(tree)
	clip_cache_inputs(tree)
	var source := FileAccess.get_file_as_string(SOURCE)
	for kind in ["SVG2D", "SVG3D", "SVGAnimate2D", "SVGAnimate3D"]:
		var node: Node = ClassDB.instantiate(kind)
		node.name = "Artwork"
		node.set("adaptive", false)
		node.set("animation_enabled", false)
		node.set("src", SOURCE)
		# 実Viewportへ配置し、テクスチャ取得による強制再描画の前に表示を読む。
		var view := SubViewport.new()
		view.size = Vector2i(64, 48)
		view.transparent_bg = true
		view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		var dim2: bool = kind.ends_with("2D")
		if not dim2:
			view.own_world_3d = true
			var camera := Camera3D.new()
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = 0.48
			camera.position = Vector3(0, 0, 2)
			view.add_child(camera)
			# ピクセル値比較にはライティングと色調整が入らない材質を使う。
			node.set("pixel_size", 0.01)
		view.add_child(node)
		tree.root.add_child(view)
		await frame(tree)
		var screen := view.get_texture().get_image()
		screen.save_png("res://tmp/oss_%s.png" % kind)
		inspect(tree, screen, kind + " viewport")
		var from_file: Image = node.call("get_texture").get_image()
		inspect(tree, from_file, kind + " texture", true, false)
		node.set("src", source)
		await frame(tree)
		tree.check(node.call("get_texture").get_image().get_data() == from_file.get_data(),
			kind + " file/text input mismatch")
		# 手計算した矩形の和集合を期待画像とし、全画素を比較する。
		var actual := from_file.duplicate() as Image
		actual.clear_mipmaps()
		actual.resize(64, 48, Image.INTERPOLATE_NEAREST)
		var expected := Image.create(64, 48, false, Image.FORMAT_RGBA8)
		expected.fill(Color(0, 0, 0, 0))
		for y in range(8, 40):
			for x in range(12, 44):
				if (x < 36 and y < 32) or (x >= 20 and y >= 16):
					expected.set_pixel(x, y, Color(1, 0, 0, 0.25))
		actual.save_png("res://tmp/oss_actual_%s.png" % kind)
		var maximum := 0
		var bytes := actual.get_data()
		var reference := expected.get_data()
		for i in bytes.size(): maximum = maxi(maximum, absi(int(bytes[i]) - int(reference[i])))
		print(kind, " full image max channel error ", maximum)
		tree.check(maximum <= 1, kind + " full image differs from analytic reference")
		if kind == "SVG2D": expected.save_png("res://tmp/oss_expected.png")
		# 参照先がsvgでも同じ表示になり、display指定は参照時にも有効。
		for tag in ["symbol", "svg"]:
			var variant := source.replace("<symbol ", "<" + tag + " ").replace("</symbol>", "</" + tag + ">")
			node.set("src", variant)
			await frame(tree)
			inspect(tree, view.get_texture().get_image(), kind + " referenced " + tag)
			node.set("src", variant.replace('id="tile"', 'id="tile" display="none"'))
			await frame(tree)
			tree.check(view.get_texture().get_image().get_used_rect().size == Vector2i.ZERO,
				kind + " hidden reference rendered")
		# viewBoxで拡大したsymbolの切り抜きは、元の図形座標を基準にする。
		for units in ["objectBoundingBox", "userSpaceOnUse"]:
			var width := "0.5" if units == "objectBoundingBox" else "8"
			var height := "1" if units == "objectBoundingBox" else "16"
			node.set("src", '<svg width="64" height="48"><defs><clipPath id="clip" clipPathUnits="%s"><rect width="%s" height="%s"/></clipPath><symbol id="s" viewBox="0 0 16 16" clip-path="url(#clip)"><path fill="red" d="M0 0H16V16H0Z"/></symbol></defs><use href="#s" width="32" height="32"/></svg>' % [units, width, height])
			await frame(tree)
			var clipped := view.get_texture().get_image()
			tree.check(clipped.get_pixel(12, 20).r > 0.98 and clipped.get_pixel(20, 20).a < 0.01,
				kind + " scaled symbol clip " + units)
		node.set("src", source)
		await frame(tree)
		if kind.begins_with("SVGAnimate"):
			# 実際のAnimationPlayerから色を変え、deferred更新とキャッシュ復帰も表示まで確認する。
			var player := AnimationPlayer.new()
			node.add_child(player)
			var animation := Animation.new()
			animation.length = 1
			var track := animation.add_track(Animation.TYPE_VALUE)
			animation.track_set_path(track, NodePath(".:paths/path_0/fill_color"))
			animation.track_insert_key(track, 0, Color.RED)
			animation.track_insert_key(track, 1, Color.GREEN)
			var library := AnimationLibrary.new()
			library.add_animation("paint", animation)
			player.add_animation_library("", library)
			player.play("paint")
			player.pause()
			player.seek(1, true)
			await frame(tree)
			inspect(tree, view.get_texture().get_image(), kind + " animation", false)
			player.seek(0, true)
			await frame(tree)
			inspect(tree, view.get_texture().get_image(), kind + " restored frame")
			# キャッシュ無効でも同じ意味の文書になる。
			node.set("animation_cache_mode", 0)
			node.set("keep_render_cache", false)
			await frame(tree)
			inspect(tree, view.get_texture().get_image(), kind + " no cache")
			var packed := PackedScene.new()
			tree.check(packed.pack(node) == OK, kind + " pack failed")
			var restored := packed.instantiate()
			node.free()
			view.add_child(restored)
			await frame(tree)
			inspect(tree, view.get_texture().get_image(), kind + " packed scene")
		view.free()

# 終了しない不正入力を避け、有効な先頭部分と各命令の描画を保つ。
static func closed_path_inputs(tree: SceneTree) -> void:
	var prefix := "M8 8 L24 8 L24 24 L8 24"
	var reference := path_image(prefix + "Z")
	for close in ["Z", "z"]:
		for suffix in [" 1", " -1.5", " ,1 2", " ?", " 1 M40 40 L56 40 L56 56 Z"]:
			tree.check(path_image(prefix + close + suffix).get_data() == reference.get_data(),
				"closed path did not preserve valid prefix: " + close + suffix)
		var next := " M40 40 L56 40 L56 56 L40 56 Z"
		var moved := path_image(prefix + close + next)
		tree.check(moved.get_pixel(48, 48).a > 0.99 and moved.get_pixel(12, 12).a > 0.99,
			"explicit M after close lost a subpath: " + close)
		var line := " L40 8 L40 24 L8 24 Z"
		tree.check(path_image(prefix + close + line).get_data()
			== path_image(prefix + "Z M8 8" + line).get_data(),
			"explicit L after close lost the current point: " + close)
	# 円弧の連続フラグを各組合せで分離表記と照合する。
	for flags in ["00", "01", "10", "11"]:
		var compact := "M16 32 A16 16 0 %s48 32 A16 16 0 %s16 32 Z" % [flags, flags]
		var separated := "M16 32 A16 16 0 %s %s 48 32 A16 16 0 %s %s 16 32 Z" \
			% [flags[0], flags[1], flags[0], flags[1]]
		tree.check(path_image(compact).get_data() == path_image(separated).get_data(),
			"adjacent arc flags changed pixels: " + flags)
	var circle := path_image("M16 32 A16 16 0 0148 32 A16 16 0 0116 32 Z")
	tree.check(circle.get_pixel(32, 32).a > 0.99 and circle.get_pixel(8, 32).a < 0.01,
		"compact arc flags lost circle pixels")
	# 固定個数の数値読取りへ替えても省略命令と符号区切りを保持する。
	for pair in [
		["M8 8 24 8 24 24 8 24Z", "M8 8L24 8L24 24L8 24Z"],
		["M8 8h16v16h-16z", "M8 8H24V24H8Z"],
		["M8 32C16 8 24 8 32 32S48 56 56 32L56 56H8Z", "M8 32C16 8 24 8 32 32C40 56 48 56 56 32L56 56H8Z"],
		["M8 32Q20 8 32 32T56 32L56 56H8Z", "M8 32Q20 8 32 32Q44 56 56 32L56 56H8Z"],
	]:
		tree.check(path_image(pair[0]).get_data() == path_image(pair[1]).get_data(),
			"valid path command changed pixels: " + pair[0])

# 自然寸法へ揃えた塗り画像を返し、画面や描画更新の待機を不要にする。
static func path_image(data: String) -> Image:
	var node: Node = ClassDB.instantiate("SVG2D")
	node.set("adaptive", false)
	node.set("animation_enabled", false)
	node.set("src", "<svg width='64' height='64'><path fill='red' d='%s'/></svg>" % data)
	var image: Image = node.call("get_texture").get_image()
	node.free()
	image.resize(64, 64, Image.INTERPOLATE_NEAREST)
	return image

# 同じ変換でも割合の基準寸法や描画面積が異なる切り抜きを共有しない。
static func clip_cache_inputs(tree: SceneTree) -> void:
	var node: Node2D = ClassDB.instantiate("SVG2D")
	node.set("animation_enabled", false)
	node.set("src", "<svg width='200' height='100'><defs><clipPath id='c'><rect width='50%' height='100%'/></clipPath></defs>"
		+ "<svg width='100' height='100' overflow='visible'><rect width='100' height='100' fill='red' clip-path='url(#c)'/></svg>"
		+ "<svg width='200' height='100' overflow='visible'><rect width='200' height='100' fill='blue' clip-path='url(#c)'/></svg></svg>")
	var nested: Image = node.call("get_texture").get_image()
	tree.check(nested.get_pixel(75, 50).b > 0.99 and nested.get_pixel(125, 50).a < 0.01,
		"percentage clip reused a different nested viewport size")
	node.set("src", "<svg width='100' height='100' viewBox='0 0 100 100' preserveAspectRatio='xMinYMin meet'>"
		+ "<defs><clipPath id='c'><rect width='200' height='100'/></clipPath></defs>"
		+ "<rect width='200' height='100' fill='red' clip-path='url(#c)'/></svg>")
	tree.root.add_child(node)
	var small: Image = node.call("get_texture").get_image()
	tree.check(small.get_size() == Vector2i(100, 100), "clip resize fixture had unexpected initial density")
	node.scale = Vector2(2, 1)
	var wide: Image = node.call("get_texture").get_image()
	tree.check(wide.get_size() == Vector2i(200, 100) and wide.get_pixel(150, 50).r > 0.99,
		"clip cache retained old canvas bounds after density change")
	node.free()
	# 完全透明の深いまとまりに、可視図形用の中間画面を追加確保しない。
	var plain: Node = ClassDB.instantiate("SVG2D")
	var hidden: Node = ClassDB.instantiate("SVG2D")
	for item in [plain, hidden]: item.set("animation_enabled", false)
	var visible := "<rect x='8' y='8' width='16' height='16' fill='red'/>"
	plain.set("src", "<svg width='64' height='64'>" + visible + "</svg>")
	hidden.set("src", "<svg width='64' height='64'>" + visible + "<g opacity='0'>".repeat(10)
		+ "<rect width='64' height='64' fill='blue'/>" + "</g>".repeat(10) + "</svg>")
	var baseline: Image = plain.call("get_texture").get_image()
	var transparent: Image = hidden.call("get_texture").get_image()
	tree.check(transparent.get_data() == baseline.get_data(), "transparent groups changed visible pixels")
	var extra := int(hidden.call("get_render_cache_bytes")) - int(plain.call("get_render_cache_bytes"))
	tree.check(extra <= 1024, "transparent groups retained unnecessary canvas bytes: " + str(extra))
	plain.free()
	hidden.free()

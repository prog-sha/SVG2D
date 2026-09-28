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

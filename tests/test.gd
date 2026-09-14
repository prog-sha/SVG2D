# SVG2D と SVG3D の公開 API と基本の描画結果を短時間で確かめるテスト。
# 責務: クラス登録、説明、読み取り、画像化、2Dと3Dの一致を一括で検証すること。
# 設計思想: 1回の起動でデータと3D画面を確かめ、失敗を終了コードと短い文で返す。
extends SceneTree

const W := 64 # 比較画像の横幅
const H := 48 # 比較画像の縦幅

var failed := false

# 条件が外れたときに、後続の確認を続けながら失敗を覚える。
func check(ok: bool, message: String) -> void:
	if ok:
		return
	failed = true
	push_error(message)

# 2枚の絵が画素ごとにどの程度離れているかを0〜255の値で測る。
func image_rmse(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return INF
	var aa := a.get_data()
	var bb := b.get_data()
	var sum := 0.0
	for i in aa.size():
		var d := float(aa[i]) - float(bb[i])
		sum += d * d
	return sqrt(sum / aa.size())

# クラス参照に利用者向けのプロパティ説明が入っているか確かめる。
func check_docs(name: String) -> void:
	var xml := FileAccess.get_file_as_string("res://doc_classes/%s.xml" % name)
	check(xml.contains('<member name="src"'), "%s の src 説明がないよ" % name)
	check(xml.contains('<member name="size"'), "%s の size 説明がないよ" % name)
	check(xml.contains('<member name="adaptive"'), "%s の adaptive 説明がないよ" % name)

# 2Dの拡大率に応じて解像度が段階的に上がり、同じ段階では画像を使い回すか確かめる。
func check_adaptive_2d(sample: String) -> void:
	var svg: Node2D = ClassDB.instantiate("SVG2D")
	svg.set("src", sample)
	svg.set("size", Vector2(W, H))
	svg.scale = Vector2(4, 4)
	root.add_child(svg)
	await process_frame
	var large: Texture2D = svg.call("get_texture")
	check(large.get_size() == Vector2(W * 4, H * 4), "SVG2Dが拡大時の解像度へ変わらないよ")
	var rid := large.get_rid()
	check(svg.call("get_texture").get_rid() == rid, "SVG2Dが同じ領域で画像を使い回していないよ")
	# 段階の境界付近では高い側を保ち、わずかな揺れで描き直さない。
	svg.scale = Vector2(4.01, 4.01)
	await process_frame
	var upper: Texture2D = svg.call("get_texture")
	check(upper.get_size() == Vector2(W * 8, H * 8), "SVG2Dの解像度段階が違うよ")
	svg.scale = Vector2(3.99, 3.99)
	await process_frame
	check(svg.call("get_texture").get_rid() == upper.get_rid(), "SVG2Dが境界の揺れで描き直しているよ")
	# 極端な拡大でも片辺4096画素を越えず、画像の使用量を抑える。
	svg.set("size", Vector2(4096, 1))
	svg.scale = Vector2(2, 2)
	await process_frame
	check(svg.call("get_texture").get_size() == Vector2(4096, 1), "SVG2Dの解像度上限が違うよ")
	svg.set("adaptive", false)
	check(not svg.is_processing(), "SVG2Dが固定解像度でも監視を続けているよ")
	svg.set("size", Vector2(W, H))
	var base: Texture2D = svg.call("get_texture")
	check(base.get_size() == Vector2(W, H), "SVG2Dの固定解像度が違うよ")
	svg.free()

# SVG3Dを正面から等倍で描き、元画像との画素差を確かめる。
func check_view(sample: String) -> void:
	var flat: Node2D = ClassDB.instantiate("SVG2D")
	flat.set("src", sample)
	flat.set("size", Vector2(W, H))
	var expected: Image = flat.call("get_texture").get_image()
	# 3Dの描画先は透明度を色へ掛けた値を返すため、比較元も同じ形へそろえる。
	expected.premultiply_alpha()

	var view := SubViewport.new()
	view.size = Vector2i(W, H)
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	root.add_child(view)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = H
	camera.position = Vector3(0, 0, 10)
	view.add_child(camera)
	camera.current = true

	var svg: Node3D = ClassDB.instantiate("SVG3D")
	svg.set("src", sample)
	svg.set("size", Vector2(W, H))
	svg.set("pixel_size", 1.0)
	view.add_child(svg)

	# カメラの拡大を反映した画像を作り、同じ領域では使い回す。
	camera.size = H / 4.0
	await process_frame
	var large: Texture2D = svg.call("get_texture")
	check(large.get_size() == Vector2(W * 4, H * 4), "SVG3Dが拡大時の解像度へ変わらないよ")
	var rid := large.get_rid()
	check(svg.call("get_texture").get_rid() == rid, "SVG3Dが同じ領域で画像を使い回していないよ")
	# 端数を切り上げた画像でも、3D空間では指定した縦横比を保つ。
	var fraction: Node3D = ClassDB.instantiate("SVG3D")
	fraction.set("src", sample)
	fraction.set("size", Vector2(1.1, 100))
	fraction.set("pixel_size", 1.0)
	view.add_child(fraction)
	await process_frame
	var sprite: Sprite3D = fraction.get_child(0, true)
	check(is_equal_approx(sprite.scale.x, 1.1 / fraction.call("get_texture").get_width()), "SVG3Dの端数幅が違うよ")
	check(is_equal_approx(sprite.scale.y, 100.0 / fraction.call("get_texture").get_height()), "SVG3Dの端数高さが違うよ")
	fraction.free()

	# 元の画角へ戻した処理後に描画完了の通知を受け、早取りを防ぐ。
	camera.size = H
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await process_frame
	var normal: Texture2D = svg.call("get_texture")
	check(normal.get_size() == Vector2(W, H), "SVG3Dが元の解像度へ戻らないよ")
	await RenderingServer.frame_post_draw
	var actual := view.get_texture().get_image()
	var error := image_rmse(expected, actual)
	print("SVG3D view RMSE: %.3f" % error)
	if error >= 8.0:
		expected.save_png("res://tmp/svg3d_expected.png")
		actual.save_png("res://tmp/svg3d_actual.png")
	check(error < 8.0, "SVG3D view RMSE が %.3f だよ" % error)
	svg.set("adaptive", false)
	check(not svg.is_processing(), "SVG3Dが固定解像度でも監視を続けているよ")
	view.free()
	flat.free()

# 場面の準備が終わった次のコマから、利用者が触る入口をまとめて確かめる。
func _initialize() -> void:
	DisplayServer.window_set_position(Vector2i(10000, 10000))
	_run.call_deferred()

# 小さなSVGを通し、API・説明・2D画像・3D画像を一括で判断する。
func _run() -> void:
	if not ClassDB.class_exists("SVG2D"):
		var status: GDExtensionManager.LoadStatus = GDExtensionManager.load_extension(
				"res://addons/svg2d/svg2d.gdextension")
		check(status == GDExtensionManager.LOAD_STATUS_OK,
				"GDExtension を読み込めなかったよ: %s" % status)
	check(ClassDB.class_exists("SVG2D"), "SVG2D が登録されていないよ")
	check(ClassDB.class_exists("SVG3D"), "SVG3D が登録されていないよ")
	check(not ClassDB.class_exists("SVG"), "内部の SVG が公開されているよ")
	if failed:
		quit(1)
		return

	check_docs("SVG2D")
	check_docs("SVG3D")
	for path in ["hello.svg", "spec.svg", "spec2.svg"]:
		var sample := FileAccess.get_file_as_string("res://tests/svg/" + path)
		var node: Node2D = ClassDB.instantiate("SVG2D")
		node.set("src", sample)
		node.set("size", Vector2(W, H))
		check(node.get("src") == sample, "%s の src が戻らないよ" % path)
		check(node.get("size") == Vector2(W, H), "%s の大きさが戻らないよ" % path)
		var texture: Texture2D = node.call("get_texture")
		check(texture != null, "%s の画像を作れなかったよ" % path)
		if texture != null:
			var image := texture.get_image()
			check(image.get_size() == Vector2i(W, H), "%s の画像の大きさが違うよ" % path)
			check(image.get_used_rect().has_area(), "%s の画像が空だよ" % path)
		var node3: Node3D = ClassDB.instantiate("SVG3D")
		node3.set("src", sample)
		node3.set("size", Vector2(W, H))
		await process_frame
		check(node3 is Node3D, "%s の SVG3D が3Dノードではないよ" % path)
		check(node3.get("src") == sample, "%s の SVG3D src が戻らないよ" % path)
		check(node3.get("size") == Vector2(W, H), "%s の SVG3D の大きさが戻らないよ" % path)
		var texture3: Texture2D = node3.call("get_texture")
		check(texture3 != null, "%s の3D画像を作れなかったよ" % path)
		if texture != null and texture3 != null:
			var error := image_rmse(texture.get_image(), texture3.get_image())
			check(error < 8.0, "%s の SVG3D RMSE が %.3f だよ" % [path, error])
			print("%s SVG3D RMSE: %.3f" % [path, error])
		node.free()
		node3.free()
	await check_adaptive_2d(FileAccess.get_file_as_string("res://tests/svg/spec.svg"))
	await check_view(FileAccess.get_file_as_string("res://tests/svg/spec.svg"))

	var config := ConfigFile.new()
	check(config.load("res://addons/svg2d/plugin.cfg") == OK, "plugin.cfg を読めなかったよ")
	check(config.get_value("plugin", "script") == "plugin.gd", "プラグインの入口が違うよ")
	check(load("res://addons/svg2d/plugin.gd") != null, "プラグインの入口を読めなかったよ")
	if not failed:
		print("SVG2D / SVG3D の試験に通ったよ")
	quit(1 if failed else 0)

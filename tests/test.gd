# SVG2DとSVG3Dの公開API・拡大描画・速度を一度に確かめるテスト。
# 責務: 文書寸法、画面密度、画素差、キャッシュ、処理時間を短時間で検証すること。
# 設計思想: 同じ図を直接の目標寸法でも描き、実表示との画素差を大きさごとに比べる。
extends SceneTree

const W := 64 # 試験SVGの自然な横幅
const H := 48 # 試験SVGの自然な縦幅
const LIMIT_US := 5_000 # 256×192以下の画像化に許す時間
const FRAME_US := 16_667 # 1024×1024の画像化に許す1コマの時間
const CACHE_US := 5.0 # 画像を使い回す1回に許す時間
const RMSE_LIMIT := 5.0 # 直接画像化した比較元との許容平均誤差
const SUPERSAMPLE_RMSE_LIMIT := 10.0 # 1.5倍画像を縮小したときの縁の許容差
const THREED_RMSE_LIMIT := 15.0 # 3Dサンプラーを通した表示との許容差
const SCALES := [0.5, 0.75, 1.0, 1.0625, 1.125, 1.1875, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.25, 3.5, 3.75, 4.0]

var failed := false
var digest := HashingContext.new()

# 同じ図を指定した自然寸法で作り、直接画像化した比較元に使う。
func sample(w: int = W, h: int = H) -> String:
	return """<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 64 48">
	<defs><linearGradient id="g"><stop stop-color="#246bfd"/><stop offset="1" stop-color="#f04b73"/></linearGradient></defs>
	<rect x="1.25" y="1.5" width="61.5" height="45" rx="7" fill="url(#g)"/>
	<circle cx="19.5" cy="24" r="11.25" fill="#31d17c" fill-opacity=".72"/>
	<path d="M31 37 C35 8 52 8 58 36" fill="none" stroke="#fff" stroke-width="3.5"/>
</svg>""" % [w, h]

# 条件が外れたときに後続の確認を続けながら失敗を覚える。
func check(ok: bool, message: String) -> void:
	if ok:
		return
	failed = true
	push_error(message)

# 2枚の絵が画素ごとにどの程度離れているかを0〜255で測る。
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

# 2枚の絵で最も大きい1成分の差を測り、局所的なずれを見落とさないようにする。
func image_max_delta(a: Image, b: Image) -> int:
	if a.get_size() != b.get_size():
		return 255
	var aa := a.get_data()
	var bb := b.get_data()
	var found := 0
	for i in aa.size():
		found = max(found, absi(aa[i] - bb[i]))
	return found

# 指定領域にある不透明度の重心と、重心からの二乗平均半径を返す。
# 形全体の移動と、輪郭だけが暴れる変形を分けて検査するために使う。
func alpha_stats(image: Image, region: Rect2i) -> Vector3:
	var data := image.get_data()
	var width := image.get_width()
	var weight := 0.0
	var sx := 0.0
	var sy := 0.0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var alpha := float(data[(y * width + x) * 4 + 3])
			weight += alpha
			sx += x * alpha
			sy += y * alpha
	if weight <= 0.0:
		return Vector3.ZERO
	var center := Vector2(sx / weight, sy / weight)
	var moment := 0.0
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var alpha := float(data[(y * width + x) * 4 + 3])
			moment += Vector2(x, y).distance_squared_to(center) * alpha
	return Vector3(center.x, center.y, sqrt(moment / weight))

# 直接その寸法で画像化し、表示先と同じ掛け合わせ済み透明色へそろえる。
func expected_at(w: int, h: int) -> Image:
	var node: Node2D = ClassDB.instantiate("SVG2D")
	node.set("src", sample(w, h))
	node.set("jitter_amount", 0.0)
	var image: Image = node.call("get_texture").get_image()
	image.premultiply_alpha()
	node.free()
	return image

# 公開プロパティに指定名があるかを返す。
func has_property(node: Object, name: String) -> bool:
	for property in node.get_property_list():
		if property.name == name:
			return true
	return false

# クラス参照に説明があり、廃止した寸法プロパティが残っていないか確かめる。
func check_docs(name: String) -> void:
	var xml := FileAccess.get_file_as_string("res://doc_classes/%s.xml" % name)
	check(xml.contains('<member name="src"'), "%sのsrc説明がないよ" % name)
	check(xml.contains('<member name="adaptive"'), "%sのadaptive説明がないよ" % name)
	check(xml.contains('<member name="jitter_amount"'), "%sのjitter_amount説明がないよ" % name)
	check(xml.contains('<member name="animation_enabled"'), "%sのanimation_enabled説明がないよ" % name)
	check(xml.contains('<member name="animation_interval"'), "%sのanimation_interval説明がないよ" % name)
	check(xml.contains('<member name="flip_h"'), "%sのflip_h説明がないよ" % name)
	check(xml.contains('<member name="offset"'), "%sのoffset説明がないよ" % name)
	check(not xml.contains('<member name="size"'), "%sにsize説明が残っているよ" % name)

# 徐々に拡大し、直接画像化した結果との画素差と画像化時間を測る。
func check_zoom_2d() -> void:
	var view := SubViewport.new()
	view.transparent_bg = true
	root.add_child(view)
	var svg: Node2D = ClassDB.instantiate("SVG2D")
	svg.set("src", sample())
	svg.set("jitter_amount", 0.0)
	view.add_child(svg)
	var max_error := 0.0
	var max_raster := 0
	var last := RID()
	for scale in SCALES:
		var w := roundi(W * scale)
		var h := roundi(H * scale)
		view.size = Vector2i(w, h)
		svg.scale = Vector2(scale, scale)
		var start := Time.get_ticks_usec()
		var texture: Texture2D = svg.call("get_texture")
		var elapsed := Time.get_ticks_usec() - start
		if texture.get_rid() != last:
			max_raster = max(max_raster, elapsed)
			last = texture.get_rid()
		view.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await RenderingServer.frame_post_draw
		var actual := view.get_texture().get_image()
		var expected := expected_at(w, h)
		var error := image_rmse(expected, actual)
		max_error = max(max_error, error)
		print("SVG2D scale %.2f texture %s RMSE %.3f raster %d us" % [scale, texture.get_size(), error, elapsed])
		check(error < RMSE_LIMIT, "SVG2D scale %.2f RMSEが%.3fだよ" % [scale, error])
		if is_equal_approx(scale, 1.0):
			check(texture.get_size() == Vector2(W, H), "SVG2Dが等倍の画素数にならないよ")
			var dot := image_max_delta(expected, actual)
			print("SVG2D dot max delta %d" % dot)
			check(dot <= 1, "SVG2Dの等倍表示に1を越える色差があるよ")
	var start := Time.get_ticks_usec()
	for i in 10_000:
		svg.call("get_texture")
	var cache_us := (Time.get_ticks_usec() - start) / 10_000.0
	print("SVG2D profile max RMSE %.3f, raster %d us, cache %.3f us/call" % [max_error, max_raster, cache_us])
	check(max_raster < LIMIT_US, "SVG2Dの画像化が遅いよ: %d us" % max_raster)
	check(cache_us < CACHE_US, "SVG2Dのキャッシュ取得が遅いよ: %.3f us" % cache_us)
	view.free()

# カメラへ出る大きさを変え、3D表示も各寸法の直接画像化と比べる。
func check_zoom_3d() -> void:
	var view := SubViewport.new()
	view.transparent_bg = true
	root.add_child(view)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = H
	camera.position = Vector3(0, 0, 10)
	view.add_child(camera)
	camera.current = true
	var svg: Node3D = ClassDB.instantiate("SVG3D")
	svg.set("src", sample())
	svg.set("jitter_amount", 0.0)
	svg.set("pixel_size", 1.0)
	view.add_child(svg)
	var max_error := 0.0
	for scale in [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]:
		var w := roundi(W * scale)
		var h := roundi(H * scale)
		view.size = Vector2i(w, h)
		view.render_target_update_mode = SubViewport.UPDATE_ONCE
		await process_frame
		await process_frame
		await RenderingServer.frame_post_draw
		var texture: Texture2D = svg.call("get_texture")
		var actual := view.get_texture().get_image()
		var expected := expected_at(w, h)
		var error := image_rmse(expected, actual)
		max_error = max(max_error, error)
		print("SVG3D camera %.2f texture %s RMSE %.3f" % [scale, texture.get_size(), error])
		check(error < THREED_RMSE_LIMIT, "SVG3D camera %.2f RMSEが%.3fだよ" % [scale, error])
		check(texture.get_size() == Vector2(ceili(w * 1.5), ceili(h * 1.5)),
			"SVG3Dが投影寸法の1.5倍で画像化されないよ: %.2f" % scale)
		check(texture.get_image().has_mipmaps(), "SVG3Dの画像にミップマップがないよ")
	print("SVG3D profile max RMSE %.3f" % max_error)
	view.free()

# 斜めの3D板でも、透視投影により大きく見える近い辺の画素数を使うか確かめる。
func check_perspective_3d() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(800, 600)
	root.add_child(view)
	var camera := Camera3D.new()
	camera.position = Vector3(0, 0, 10)
	view.add_child(camera)
	camera.current = true
	var svg: Node3D = ClassDB.instantiate("SVG3D")
	svg.set("src", sample())
	svg.set("jitter_amount", 0.0)
	svg.set("pixel_size", 0.1)
	svg.rotation.y = deg_to_rad(50)
	view.add_child(svg)
	await process_frame
	await process_frame
	var hw := W * 0.1 * 0.5
	var hh := H * 0.1 * 0.5
	var points := [
		svg.global_transform * Vector3(-hw, -hh, 0),
		svg.global_transform * Vector3(hw, -hh, 0),
		svg.global_transform * Vector3(-hw, hh, 0),
		svg.global_transform * Vector3(hw, hh, 0),
	]
	var screen := points.map(func(point: Vector3) -> Vector2: return camera.unproject_position(point))
	var w: float = max(screen[0].distance_to(screen[1]), screen[2].distance_to(screen[3]))
	var h: float = max(screen[0].distance_to(screen[2]), screen[1].distance_to(screen[3]))
	var density: float = max(w / W, h / H) * 1.5
	var expected := Vector2(ceili(W * density - 0.000001), ceili(H * density - 0.000001))
	var texture: Texture2D = svg.call("get_texture")
	check(texture.get_size() == expected, "透視投影の近い辺に解像度が合っていないよ")
	# 正面向きで奥行きを保った左右移動は投影寸法が変わらないため、同じ画像を使い回す。
	svg.rotation = Vector3.ZERO
	await process_frame
	await process_frame
	var cached: RID = svg.call("get_texture").get_rid()
	for x in [-3.0, -1.5, 0.0, 1.5, 3.0]:
		svg.position.x = x
		await process_frame
		await process_frame
		texture = svg.call("get_texture")
		check(texture.get_rid() == cached, "SVG3Dの左右移動で画像を再生成しているよ: x=%.1f" % x)
	print("SVG3D horizontal cache: 5 moves, RID unchanged")
	# カメラの後ろに移動した板が不要な最大画像を作らないか確かめる。
	svg.position = Vector3(0, 0, 20)
	await process_frame
	await process_frame
	check(svg.call("get_texture").get_size() == Vector2(ceili(W * 1.5), ceili(H * 1.5)), "カメラ背面のSVG3Dが基準1.5倍解像度になっていないよ")
	view.free()

# 非等方な投影寸法をそのままSVGの出力縦横へ渡すとpreserveAspectRatioの余白が
# Sprite3D上で伸縮され、中身だけが回転軸と直交する方向へつぶれることを防ぐ。
func check_rotation_3d() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(800, 600)
	root.add_child(view)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	camera.position = Vector3(0, 0, 10)
	view.add_child(camera)
	camera.current = true
	var svg: Node3D = ClassDB.instantiate("SVG3D")
	svg.set("src", '<svg width="64" height="32" viewBox="0 0 64 32"><rect width="64" height="32" fill="white"/></svg>')
	svg.set("jitter_amount", 0.0)
	svg.set("pixel_size", 0.1)
	view.add_child(svg)
	for rotation in [
		Vector3.ZERO,
		Vector3(deg_to_rad(60.0), 0, 0),
		Vector3(0, deg_to_rad(60.0), 0),
		Vector3(0, 0, deg_to_rad(90.0)),
	]:
		svg.rotation = rotation
		await process_frame
		await process_frame
		var texture: Texture2D = svg.call("get_texture")
		check(texture.get_size() == Vector2(576, 288),
			"SVG3D回転時にテクスチャの縦横比が変わったよ: rotation=%s size=%s" % [rotation, texture.get_size()])
		var used := texture.get_image().get_used_rect()
		check(used.position.x <= 1 and used.position.y <= 1
			and used.end.x >= texture.get_width() - 1 and used.end.y >= texture.get_height() - 1,
			"SVG3D回転時にpreserveAspectRatioの余白で中身がつぶれているよ: rotation=%s used=%s" % [rotation, used])
	view.free()

# 整数画素への追従、使い回し、上限、固定解像度を共通の画像管理で確かめる。
func check_cache() -> void:
	# 等倍付近は必要な整数画素数とし、2倍画像へ飛ばないことを確かめる。
	var fine: Node2D = ClassDB.instantiate("SVG2D")
	fine.set("src", sample())
	fine.set("jitter_amount", 0.0)
	root.add_child(fine)
	fine.scale = Vector2(1.01, 1.01)
	await process_frame
	var near: Texture2D = fine.call("get_texture")
	check(near.get_size() == Vector2(65, 49), "1.01倍の整数画素数が違うよ")
	var stable := near.get_rid()
	fine.scale = Vector2(1.011, 1.011)
	await process_frame
	check(fine.call("get_texture").get_rid() == stable, "整数画素数が同じなのに再生成しているよ")
	fine.scale = Vector2(0.99, 0.99)
	await process_frame
	check(fine.call("get_texture").get_rid() != stable, "整数画素数が変わっても再生成しないよ")
	fine.scale = Vector2(2.0, 0.5)
	await process_frame
	check(fine.call("get_texture").get_size() == Vector2(128, 24), "縦横別の描画領域に合っていないよ")
	fine.free()

	var svg: Node2D = ClassDB.instantiate("SVG2D")
	svg.set("src", sample())
	svg.set("jitter_amount", 0.0)
	svg.scale = Vector2(4, 4)
	root.add_child(svg)
	await process_frame
	var large: Texture2D = svg.call("get_texture")
	check(large.get_size() == Vector2(W * 4, H * 4), "拡大時の解像度が違うよ")
	check(svg.call("get_texture").get_rid() == large.get_rid(), "同じ領域で画像を使い回していないよ")
	svg.scale = Vector2(4.01, 4.01)
	await process_frame
	var upper: Texture2D = svg.call("get_texture")
	svg.scale = Vector2(3.99, 3.99)
	await process_frame
	var lower: Texture2D = svg.call("get_texture")
	check(lower.get_rid() != upper.get_rid(), "整数画素数が変わっても再生成しないよ")
	svg.scale = Vector2(3.991, 3.991)
	await process_frame
	check(svg.call("get_texture").get_rid() == lower.get_rid(), "整数画素数が同じなのに再生成しているよ")
	svg.set("src", '<svg width="4096" height="1"><rect width="4096" height="1"/></svg>')
	svg.scale = Vector2(2, 2)
	await process_frame
	check(svg.call("get_texture").get_size() == Vector2(4096, 2), "解像度上限が違うよ")
	svg.set("src", sample())
	svg.set("adaptive", false)
	check(not svg.is_processing(), "固定解像度でも監視を続けているよ")
	check(svg.call("get_texture").get_size() == Vector2(W, H), "文書の固定解像度が違うよ")
	svg.free()

# 大きな不透明画像を作り、画素変換を含む処理が1コマの時間に収まるか測る。
func check_large_profile() -> void:
	var svg: Node2D = ClassDB.instantiate("SVG2D")
	svg.set("src", '<svg width="1024" height="1024"><rect width="1024" height="1024" fill="#48a9e6"/></svg>')
	svg.set("jitter_amount", 0.0)
	var start := Time.get_ticks_usec()
	var texture: Texture2D = svg.call("get_texture")
	var elapsed := Time.get_ticks_usec() - start
	print("SVG2D 1024x1024 profile %d us" % elapsed)
	check(texture.get_size() == Vector2(1024, 1024), "1024x1024を画像化できないよ")
	check(elapsed < FRAME_US, "1024x1024の画像化が1コマを越えたよ: %d us" % elapsed)
	svg.free()

# seed 1〜4の4枚だけが作られ、5枚目から同じRIDを循環利用することを確かめる。
func check_jitter_animation() -> void:
	var markup := '<svg width="64" height="48" viewBox="0 0 64 48"><path d="M5 39 L13 8 L31 32 L48 6 L59 40 Z" fill="#111" stroke="#f34" stroke-width="3"/></svg>'
	var svg: Node2D = ClassDB.instantiate("SVG2D")
	check(is_equal_approx(svg.get("jitter_amount"), 0.0008), "既定のぶれ量が0.0008でないよ")
	check(not svg.get("animation_enabled"), "アニメーションが既定でOFFでないよ")
	check(svg.get("animation_interval") == 10, "既定のアニメ間隔が10フレームでないよ")
	var jitter_hint := ""
	for info in svg.get_property_list():
		if info.name == &"jitter_amount":
			jitter_hint = info.hint_string
	check(jitter_hint == "0,0.3,0.0001", "Inspectorのjitter_amount範囲が0〜0.3でないよ: %s" % jitter_hint)
	svg.set("src", markup)
	svg.set("adaptive", false)
	svg.set("jitter_amount", 0.03)
	root.add_child(svg)
	await process_frame # Nodeの仮想_process自動有効化後、自身で不要な監視を止める。
	check(not svg.is_processing(), "Animation OFF・adaptive OFFなのに処理を続けているよ")
	var plain: Texture2D = svg.call("get_texture")
	var plain_rid := plain.get_rid()
	var plain_hash := hash(plain.get_image().get_data())
	for i in 12:
		await process_frame
		check(svg.call("get_texture").get_rid() == plain_rid, "Animation OFFなのに画像が切り替わるよ")
	check(hash(svg.call("get_texture").get_image().get_data()) == plain_hash,
		"Animation OFFなのにパスへぶれが掛かるよ")
	svg.set("jitter_amount", 0.9)
	check(is_equal_approx(svg.get("jitter_amount"), 0.3), "jitter_amountが最大0.3で制限されないよ")
	svg.set("jitter_amount", 0.03)
	svg.set("animation_enabled", true)
	check(svg.is_processing(), "Animation ONなのに処理が始まらないよ")
	var held_texture: Texture2D = svg.call("get_texture")
	var held: RID = held_texture.get_rid()
	check(hash(held_texture.get_image().get_data()) != plain_hash, "Animation ONでもパスがぶれないよ")
	for i in 9:
		await process_frame
		check(svg.call("get_texture").get_rid() == held, "既定10フレームより前にパターンが変わるよ")
	await process_frame
	check(svg.call("get_texture").get_rid() != held, "10フレーム目でパターンが変わらないよ")
	# 同じ入力を再設定してseed 1へ戻し、1フレーム間隔で全キャッシュを観察する。
	svg.set("src", markup)
	svg.set("animation_interval", 1)
	var rids: Array[RID] = [svg.call("get_texture").get_rid()]
	var hashes: Array[int] = [hash(svg.call("get_texture").get_image().get_data())]
	for i in 4:
		await process_frame
		var texture: Texture2D = svg.call("get_texture")
		rids.push_back(texture.get_rid())
		hashes.push_back(hash(texture.get_image().get_data()))
	check(rids[0] == rids[4], "4パターン後に最初の画像キャッシュへ戻らないよ")
	check(rids.slice(0, 4).duplicate().all(func(rid: RID) -> bool: return rids.slice(0, 4).count(rid) == 1),
		"4パターンが別々の画像キャッシュになっていないよ")
	for i in 4:
		check(hashes[i] != hashes[(i + 1) % 4], "隣り合う揺れパターンの絵が同じだよ: %d" % i)
	# 別ノードでもseed 1の絵が一致し、実行時乱数に依存しないことを確かめる。
	var again: Node2D = ClassDB.instantiate("SVG2D")
	again.set("src", markup)
	again.set("adaptive", false)
	again.set("jitter_amount", 0.03)
	again.set("animation_enabled", true)
	var again_hash: int = hash(again.call("get_texture").get_image().get_data())
	check(again_hash == hashes[0], "固定seed 1の揺れが再生成時に変わるよ")
	again.free()
	# 同じviewBoxを2倍の画像へ焼くと、ぶれを含む使用矩形もほぼ2倍になる。
	var large: Node2D = ClassDB.instantiate("SVG2D")
	large.set("src", markup.replace('width="64" height="48"', 'width="128" height="96"'))
	large.set("adaptive", false)
	large.set("jitter_amount", 0.03)
	large.set("animation_enabled", true)
	var small_rect: Rect2i = svg.call("get_texture").get_image().get_used_rect()
	var large_rect: Rect2i = large.call("get_texture").get_image().get_used_rect()
	check(Vector2(large_rect.position).distance_to(Vector2(small_rect.position) * 2.0) <= 3.0,
		"画像を2倍にしたときぶれ位置が寸法比で拡大されないよ")
	check(Vector2(large_rect.size).distance_to(Vector2(small_rect.size) * 2.0) <= 3.0,
		"画像を2倍にしたときぶれ量が寸法比で保たれないよ")
	large.free()
	# 単色円も輪郭変形だけでなく重心が動くこと、穴あきリングは指定量以上に
	# 外周と内周がばらばらにならないことを実際の4枚の画像から測る。
	var motion: Node2D = ClassDB.instantiate("SVG2D")
	motion.set("src", '<svg width="1024" height="768" viewBox="0 0 64 48"><circle cx="16" cy="24" r="8" fill="red"/><path d="M48 15 A9 9 0 1 1 47.99 15 Z M48 19 A5 5 0 1 0 47.99 19 Z" fill="blue" fill-rule="evenodd"/></svg>')
	motion.set("adaptive", false)
	motion.set("animation_enabled", true)
	motion.set("animation_interval", 1)
	root.add_child(motion)
	var circle_stats: Array[Vector3] = []
	var ring_stats: Array[Vector3] = []
	var circle_shape_hashes: Dictionary = {}
	var ring_shape_hashes: Dictionary = {}
	for i in 4:
		var image: Image = motion.call("get_texture").get_image()
		circle_stats.push_back(alpha_stats(image, Rect2i(0, 0, 512, 768)))
		ring_stats.push_back(alpha_stats(image, Rect2i(512, 0, 512, 768)))
		circle_shape_hashes[hash(image.get_region(Rect2i(0, 0, 512, 768)).get_data())] = true
		ring_shape_hashes[hash(image.get_region(Rect2i(512, 0, 512, 768)).get_data())] = true
		await process_frame
	var circle_motion := 0.0
	var ring_motion := 0.0
	var ring_min_radius := INF
	var ring_max_radius := 0.0
	for i in 4:
		for j in range(i + 1, 4):
			circle_motion = max(circle_motion, Vector2(circle_stats[i].x, circle_stats[i].y).distance_to(Vector2(circle_stats[j].x, circle_stats[j].y)))
			ring_motion = max(ring_motion, Vector2(ring_stats[i].x, ring_stats[i].y).distance_to(Vector2(ring_stats[j].x, ring_stats[j].y)))
		ring_min_radius = min(ring_min_radius, ring_stats[i].z)
		ring_max_radius = max(ring_max_radius, ring_stats[i].z)
	check(circle_motion <= 0.08, "単色円が輪郭変形ではなく移動しているよ: %.3f px" % circle_motion)
	check(ring_motion <= 0.08, "穴あきリングが輪郭変形ではなく移動しているよ: %.3f px" % ring_motion)
	check(circle_shape_hashes.size() == 4, "単色円の輪郭が4パターンに変形していないよ")
	check(ring_shape_hashes.size() == 4, "穴あきリングの輪郭が4パターンに変形していないよ")
	check(ring_max_radius - ring_min_radius <= 0.75,
		"穴あきリングの外周と内周が別々に暴れているよ: %.3f px" % (ring_max_radius - ring_min_radius))
	print("SVG shape motion: circle %.3f px, ring %.3f px, ring radius delta %.3f px" % [circle_motion, ring_motion, ring_max_radius - ring_min_radius])
	motion.free()
	# spec.svg の黒い極小円と同じ、直径より線幅が太い閉路を高解像度で焼く。
	# 中心線を先に乱すと法線が反転し、マイターが本来の倍以上まで棘状に伸びる。
	var thick_ring: Node2D = ClassDB.instantiate("SVG2D")
	thick_ring.set("src", '<svg width="1024" height="1024" viewBox="0 0 400 400"><circle cx="200" cy="200" r="3" fill="none" stroke="black" stroke-width="9"/></svg>')
	thick_ring.set("adaptive", false)
	thick_ring.set("animation_enabled", true)
	thick_ring.set("animation_interval", 1)
	thick_ring.set("jitter_amount", 0.0022)
	root.add_child(thick_ring)
	var thick_hashes: Dictionary = {}
	var thick_largest := 0
	for i in 4:
		var thick_image: Image = thick_ring.call("get_texture").get_image()
		var thick_used := thick_image.get_used_rect()
		thick_largest = max(thick_largest, thick_used.size.x, thick_used.size.y)
		thick_hashes[hash(thick_image.get_data())] = true
		await process_frame
	check(thick_largest <= 48,
		"線幅が直径以上の閉路でマイターが棘状に突出しているよ: %d px" % thick_largest)
	check(thick_hashes.size() == 4,
		"太い閉路を安全に外周化したあと4パターンへ変形できていないよ")
	print("SVG overwide closed stroke: max %d px, 4 unique patterns" % thick_largest)
	thick_ring.free()
	svg.set("animation_enabled", false)
	check(not svg.is_processing(), "AnimationをOFFに戻しても処理を続けているよ")
	var flag3: Node3D = ClassDB.instantiate("SVG3D")
	check(not flag3.get("animation_enabled") and is_equal_approx(flag3.get("jitter_amount"), 0.0008),
		"SVG3DのAnimationまたはjitter_amount既定値が違うよ")
	flag3.set("src", markup)
	flag3.set("adaptive", false)
	root.add_child(flag3)
	await process_frame
	check(not flag3.is_processing(), "SVG3DのAnimation OFF・adaptive OFFで処理を続けているよ")
	flag3.set("animation_enabled", true)
	check(flag3.is_processing(), "SVG3DのAnimation ONで処理が始まらないよ")
	flag3.set("animation_enabled", false)
	check(not flag3.is_processing(), "SVG3DのAnimation OFFで処理が止まらないよ")
	flag3.free()
	print("SVG jitter cache: 4 unique patterns, pattern 5 reused pattern 1 RID")
	svg.free()

# 2Dの反転・offsetと、3Dのmodulate・反転・自然寸法offsetを実描画ノードで確かめる。
func check_appearance() -> void:
	var view := SubViewport.new()
	view.size = Vector2i(96, 64)
	view.transparent_bg = true
	root.add_child(view)
	var svg: Node2D = ClassDB.instantiate("SVG2D")
	svg.set("src", '<svg width="64" height="48"><rect width="16" height="48" fill="white"/></svg>')
	svg.set("jitter_amount", 0.0)
	svg.set("adaptive", false)
	svg.set("offset", Vector2(8, 4))
	svg.set("flip_h", true)
	svg.modulate = Color(0.5, 0.25, 1.0, 0.5)
	view.add_child(svg)
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await RenderingServer.frame_post_draw
	var used := view.get_texture().get_image().get_used_rect()
	check(used.position.x >= 55 and used.end.x <= 73, "SVG2Dの横反転またはoffsetが描画へ反映されないよ: %s" % used)
	check(svg.modulate.is_equal_approx(Color(0.5, 0.25, 1.0, 0.5)), "SVG2Dのmodulateを保持できないよ")
	view.free()

	var svg3: Node3D = ClassDB.instantiate("SVG3D")
	svg3.set("src", sample())
	svg3.set("jitter_amount", 0.0)
	svg3.set("adaptive", false)
	svg3.set("offset", Vector2(3, 4))
	svg3.set("flip_h", true)
	svg3.set("flip_v", true)
	svg3.set("modulate", Color(0.25, 0.5, 0.75, 0.6))
	root.add_child(svg3)
	await process_frame
	await process_frame
	var children := svg3.get_children(true)
	check(children.size() == 1 and children[0] is Sprite3D, "SVG3Dの内部Sprite3Dがないよ")
	if children.size() == 1 and children[0] is Sprite3D:
		var sprite := children[0] as Sprite3D
		check(sprite.flip_h and sprite.flip_v, "SVG3Dの反転が内部Sprite3Dへ反映されないよ")
		check(sprite.modulate.is_equal_approx(Color(0.25, 0.5, 0.75, 0.6)), "SVG3Dのmodulateが反映されないよ")
		check(sprite.offset.is_equal_approx(Vector2(4.5, 6.0)), "SVG3Dのoffsetが1.5倍画像へ換算されないよ: %s" % sprite.offset)
		var texture: Texture2D = sprite.texture
		check(texture.get_size() == Vector2(96, 72), "固定SVG3Dが自然寸法の1.5倍でないよ")
		check(texture.get_image().has_mipmaps(), "固定SVG3Dにミップマップがないよ")
	svg3.free()

func check_ropes() -> void:
	check(ClassDB.class_exists("SpriteRope2D"), "SpriteRope2Dが登録されていないよ")
	check(ClassDB.class_exists("SpriteRope3D"), "SpriteRope3Dが登録されていないよ")
	check(ClassDB.class_exists("SVGRope2D"), "SVGRope2Dが登録されていないよ")
	check(ClassDB.class_exists("SVGRope3D"), "SVGRope3Dが登録されていないよ")
	if not ClassDB.class_exists("SpriteRope2D") or not ClassDB.class_exists("SpriteRope3D") \
			or not ClassDB.class_exists("SVGRope2D") or not ClassDB.class_exists("SVGRope3D"):
		return
	# SpriteRopeはSVG文字列ではなく、標準Texture2Dを素材として受け取る。
	var image := Image.create(32, 24, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.9, 0.2, 0.5, 1.0))
	var image_texture := ImageTexture.create_from_image(image)
	var sprite_rope2: Node2D = ClassDB.instantiate("SpriteRope2D")
	sprite_rope2.set("texture", image_texture)
	sprite_rope2.set("simulation_enabled", false)
	check(sprite_rope2.get("texture") == image_texture and not has_property(sprite_rope2, "src"),
		"SpriteRope2Dが標準Texture2D専用になっていないよ")
	var sprite_points2: PackedVector2Array = sprite_rope2.call("get_rope_points")
	check(sprite_points2[-1].is_equal_approx(Vector2(0, 24)),
		"SpriteRope2Dが画像高を自動長として扱わないよ")
	sprite_rope2.free()
	var sprite_rope3: Node3D = ClassDB.instantiate("SpriteRope3D")
	sprite_rope3.set("texture", image_texture)
	sprite_rope3.set("simulation_enabled", false)
	root.add_child(sprite_rope3)
	await process_frame
	var sprite_points3: PackedVector3Array = sprite_rope3.call("get_rope_points")
	check(is_equal_approx(sprite_points3[-1].y, -0.24) and not has_property(sprite_rope3, "src"),
		"SpriteRope3Dが画像高とpixel_sizeから自動長を作らないよ")
	check(sprite_rope3.get_child(0, true).mesh.surface_get_material(0)
			.get_texture(BaseMaterial3D.TEXTURE_ALBEDO) == image_texture,
		"SpriteRope3Dの帯へTexture2Dが設定されないよ")
	sprite_rope3.free()
	var view := SubViewport.new()
	view.size = Vector2i(256, 128)
	view.transparent_bg = true
	root.add_child(view)
	var rope2: Node2D = ClassDB.instantiate("SpriteRope2D")
	rope2.set("line_mode", true)
	rope2.set("line_width", 6.0)
	rope2.set("line_color", Color(0.2, 0.8, 1.0, 1.0))
	rope2.set("segments", 9)
	rope2.set("max_length", 80.0)
	rope2.set("elasticity", 1.0)
	rope2.set("gravity", Vector2(800, 0))
	rope2.set("simulation_enabled", false)
	rope2.position = Vector2(128, 8)
	view.add_child(rope2)
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await RenderingServer.frame_post_draw
	check(view.get_texture().get_image().get_used_rect().has_area(),
		"SVGRope2DのLine ModeがSVGなしで描画されないよ")
	rope2.set("simulation_enabled", true)
	for i in 12:
		await physics_frame
	var points2: PackedVector2Array = rope2.call("get_rope_points")
	var rope_backend: String = rope2.call("get_simulation_backend")
	check(rope_backend in ["neon", "sse2", "scalar"],
		"未知のロープ計算バックエンドだよ: %s" % rope_backend)
	check(points2.size() == 9 and points2[0].distance_to(Vector2.ZERO) < 0.001,
		"SVGRope2Dの粒子数または上端固定が違うよ")
	var max_link2 := 0.0
	for i in points2.size() - 1:
		max_link2 = max(max_link2, points2[i].distance_to(points2[i + 1]))
	check(max_link2 <= 10.01, "SVGRope2DがPBD最大長を越えたよ: %.4f" % max_link2)
	check(points2[-1].x > 1.0, "SVGRope2Dが横重力で変形しないよ")
	rope2.set("simulation_enabled", false)
	var stopped2: PackedVector2Array = rope2.call("get_rope_points")
	for i in 3:
		await physics_frame
	check(rope2.call("get_rope_points") == stopped2, "SVGRope2Dを停止しても計算を続けているよ")
	view.free()

	var svg_view := SubViewport.new()
	svg_view.size = Vector2i(256, 160)
	svg_view.transparent_bg = true
	root.add_child(svg_view)
	var svg_rope2: Node2D = ClassDB.instantiate("SVGRope2D")
	svg_rope2.set("src", sample())
	svg_rope2.set("gravity", Vector2(500, 200))
	svg_rope2.position = Vector2(128, 8)
	svg_view.add_child(svg_rope2)
	for i in 8:
		await physics_frame
	var svg_points2: PackedVector2Array = svg_rope2.call("get_rope_points")
	check(svg_points2[-1].x > 0.1 and svg_points2[-1].length() <= float(H) + 0.01,
		"SVGRope2DがSVG上端から下端を自動長として扱わないよ")
	svg_view.render_target_update_mode = SubViewport.UPDATE_ONCE
	await process_frame
	await RenderingServer.frame_post_draw
	check(svg_view.get_texture().get_image().get_used_rect().has_area(),
		"SVGRope2DがSVGを粒子中心線に沿って変形描画しないよ")
	svg_view.free()

	var rope3: Node3D = ClassDB.instantiate("SpriteRope3D")
	rope3.set("line_mode", true)
	rope3.set("line_width", 0.08)
	rope3.set("line_color", Color(1.0, 0.4, 0.2, 0.8))
	rope3.set("segments", 9)
	rope3.set("max_length", 2.0)
	rope3.set("elasticity", 1.0)
	rope3.set("gravity", Vector3(10, 0, 0))
	root.add_child(rope3)
	for i in 12:
		await physics_frame
	var points3: PackedVector3Array = rope3.call("get_rope_points")
	var max_link3 := 0.0
	for i in points3.size() - 1:
		max_link3 = max(max_link3, points3[i].distance_to(points3[i + 1]))
	check(points3.size() == 9 and points3[0].distance_to(Vector3.ZERO) < 0.0001,
		"SVGRope3Dの粒子数または上端固定が違うよ")
	check(max_link3 <= 0.2501, "SVGRope3DがPBD最大長を越えたよ: %.5f" % max_link3)
	check(points3[-1].x > 0.01, "SVGRope3Dが横重力で変形しないよ")
	check(rope3.get_child_count(true) == 1 and rope3.get_child(0, true) is MeshInstance3D
		and rope3.get_child(0, true).mesh.get_surface_count() == 1,
		"SVGRope3DのLine Modeメッシュが作られないよ")
	rope3.free()

	var svg_rope3: Node3D = ClassDB.instantiate("SVGRope3D")
	svg_rope3.set("src", sample())
	svg_rope3.set("simulation_enabled", false)
	root.add_child(svg_rope3)
	await process_frame
	var svg_points3: PackedVector3Array = svg_rope3.call("get_rope_points")
	check(is_equal_approx(svg_points3[-1].y, -float(H) * 0.01),
		"SVGRope3DがSVG上端から下端をpixel_size込みの自動長として扱わないよ")
	var svg_mesh: Mesh = svg_rope3.get_child(0, true).mesh
	var svg_material: StandardMaterial3D = svg_mesh.surface_get_material(0)
	var rope_texture: Texture2D = svg_material.get_texture(BaseMaterial3D.TEXTURE_ALBEDO)
	check(rope_texture != null and rope_texture.get_size() == Vector2(W * 1.5, H * 1.5),
		"SVGRope3Dの帯メッシュへ1.5倍SVGテクスチャが設定されないよ")
	svg_rope3.free()
	print("Rope simulation backend: %s" % rope_backend)
	print("SVG rope PBD: 2D %.3f px/link, 3D %.4f units/link" % [max_link2, max_link3])

# 場面の準備が終わった次のコマから試験を始める。
func _initialize() -> void:
	DisplayServer.window_set_position(Vector2i(10000, 10000))
	_run.call_deferred()

# 公開APIと描画をまとめて判断する。
func _run() -> void:
	digest.start(HashingContext.HASH_SHA256)
	if not ClassDB.class_exists("SVG2D"):
		var status := GDExtensionManager.load_extension("res://addons/svg2d/svg2d.gdextension")
		check(status == GDExtensionManager.LOAD_STATUS_OK, "GDExtensionを読み込めなかったよ: %s" % status)
	check(ClassDB.class_exists("SVG2D"), "SVG2Dが登録されていないよ")
	check(ClassDB.class_exists("SVG3D"), "SVG3Dが登録されていないよ")
	check(not ClassDB.class_exists("SVG"), "内部のSVGが公開されているよ")
	if failed:
		quit(1)
		return
	check_docs("SVG2D")
	check_docs("SVG3D")
	# 空入力や壊れた参照は XMLParser へ渡さず、絵なしとして扱う。
	var empty: Node2D = ClassDB.instantiate("SVG2D")
	empty.set("src", "res://tests/svg/not_found.svg")
	check(empty.call("get_texture") == null, "存在しないSVG素材が空画像にならないよ")
	empty.set("src", "")
	check(empty.call("get_texture") == null, "srcを消したとき空画像にならないよ")
	empty.free()
	for path in ["hello.svg", "spec.svg", "spec2.svg"]:
		var node: Node2D = ClassDB.instantiate("SVG2D")
		# SVG2D と SVG3D が同じファイル素材を直接読めることを保証する。
		node.set("src", "res://tests/svg/" + path)
		node.set("jitter_amount", 0.0)
		check(not has_property(node, "size"), "%sのSVG2Dにsizeが残っているよ" % path)
		var texture: Texture2D = node.call("get_texture")
		check(texture != null and texture.get_image().get_used_rect().has_area(), "%sを画像化できないよ" % path)
		if texture != null:
			digest.update(texture.get_image().get_data())
		var node3: Node3D = ClassDB.instantiate("SVG3D")
		node3.set("src", "res://tests/svg/" + path)
		node3.set("jitter_amount", 0.0)
		root.add_child(node3)
		await process_frame
		check(not has_property(node3, "size"), "%sのSVG3Dにsizeが残っているよ" % path)
		var texture3: Texture2D = node3.call("get_texture")
		check(texture3 != null, "%sを3D画像化できないよ" % path)
		if texture != null and texture3 != null:
			var image3 := texture3.get_image()
			image3.resize(texture.get_width(), texture.get_height(), Image.INTERPOLATE_LANCZOS)
			var error := image_rmse(texture.get_image(), image3)
			check(error < SUPERSAMPLE_RMSE_LIMIT, "%sの2D・3D RMSEが%.3fだよ" % [path, error])
		node.free()
		node3.free()
	await check_cache()
	await check_zoom_2d()
	await check_zoom_3d()
	await check_perspective_3d()
	await check_rotation_3d()
	await check_jitter_animation()
	await check_appearance()
	await check_ropes()
	check_large_profile()
	var config := ConfigFile.new()
	check(config.load("res://addons/svg2d/plugin.cfg") == OK, "plugin.cfgを読めなかったよ")
	check(config.get_value("plugin", "script") == "plugin.gd", "プラグインの入口が違うよ")
	if not failed:
		print("SVG pixel SHA256: %s" % digest.finish().hex_encode())
		print("SVG2D / SVG3Dの試験に通ったよ")
	quit(1 if failed else 0)

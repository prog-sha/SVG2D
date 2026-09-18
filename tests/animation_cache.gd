# 接点アニメーションの描画履歴を検証する。
# 責務: 通常描画との一致、再利用、追い出し、保存する設定を確認する。
# 設計思想: 同一形状への復帰はRIDも一致させ、再描画の省略を直接確認する。
extends RefCounted

# 固定寸法のSVGを作り、接点だけ変える。
static func source(size: int = 64) -> String:
	return "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 64 64'><path fill='#f34' stroke='white' stroke-width='2' d='M8 8 C16 2 32 2 40 12 L48 48 L8 48 Z'/></svg>" % [size, size]

# 同じ座標を正確に反復して、既知の形状へ戻る。
static func pose(node: Node, index: int) -> void:
	node.set("paths/path_0/point_1", Vector2(41 + index, 13 + index))
	node.call("flush_paths")

# 3Dの遅延反映も終わってから表示テクスチャを読む。
static func frame(tree: SceneTree) -> void:
	await tree.process_frame
	await RenderingServer.frame_post_draw

# キャッシュが効く繰り返し描画の費用だけを測る。
static func benchmark(node: Node, mode: int) -> int:
	node.set("animation_cache_mode", mode)
	for i in 8:
		pose(node, i)
		node.call("get_texture")
	var start := Time.get_ticks_usec()
	for i in 128:
		pose(node, i % 8)
		node.call("get_texture")
	return Time.get_ticks_usec() - start

static func run(tree: SceneTree) -> void:
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		var normal: Node = ClassDB.instantiate(kind)
		var cached: Node = ClassDB.instantiate(kind)
		tree.check(cached.get("animation_cache_mode") == 1,
			"%sのAnimation Cache Mode既定値がExact Framesでないよ" % kind)
		normal.set("animation_cache_mode", 0)
		for node in [normal, cached]:
			node.set("src", source())
			node.set("adaptive", false)
			tree.root.add_child(node)
		var rids: Array[RID] = []
		var pixels: Array[PackedByteArray] = []
		for i in 4:
			pose(normal, i)
			pose(cached, i)
			await frame(tree)
			var actual: Texture2D = cached.call("get_texture")
			rids.append(actual.get_rid())
			pixels.append(actual.get_image().get_data())
			tree.check(pixels[-1] == normal.call("get_texture").get_image().get_data(), "履歴ON/OFFの描画が違うよ: " + kind)
		for i in 4:
			pose(cached, i)
			await frame(tree)
			var actual: Texture2D = cached.call("get_texture")
			tree.check(actual.get_rid() == rids[i] and actual.get_image().get_data() == pixels[i],
				"同じ形へ戻っても画像を再利用しない、または過去画像を上書きしたよ: " + kind)
		tree.check(cached.call("get_animation_cache_hits") >= 4, "繰り返し形状のヒットを計数できないよ")
		# 揺れの位相と量が変わると異なる絵。OFFへ戻すと元の絵を再利用する。
		cached.set("animation_interval", 1000)
		cached.set("jitter_amount", 0.03)
		cached.set("animation_enabled", true)
		pose(cached, 0)
		await frame(tree)
		var jitter: PackedByteArray = cached.call("get_texture").get_image().get_data()
		tree.check(jitter != pixels[0], "通常画像の履歴を揺れ画像へ誤使用したよ")
		cached.set("animation_enabled", false)
		await frame(tree)
		tree.check(cached.call("get_texture").get_image().get_data() == pixels[0], "揺れOFFで元の姿勢画像へ戻らないよ")
		# 保持を止めた時に、最後にキャッシュヒットした形を解析して描ける。
		cached.set("animation_cache_mode", 0)
		cached.set("jitter_amount", 0.07)
		cached.set("animation_enabled", true)
		pose(normal, 0)
		normal.set("jitter_amount", 0.07)
		normal.set("animation_interval", 1000)
		normal.set("animation_enabled", true)
		await frame(tree)
		tree.check(cached.call("get_texture").get_image().get_data() == normal.call("get_texture").get_image().get_data(),
			"履歴停止時に古い解析文書を描いたよ")
		tree.check(cached.call("get_animation_cache_bytes") == 0, "履歴OFFでも保持が残ったよ")
		normal.free()
		cached.free()

	var node: Node2D = ClassDB.instantiate("SVGAnimate2D")
	node.set("src", source(256))
	node.set("adaptive", false)
	var cold_us := benchmark(node, 0)
	var warm_us := benchmark(node, 1)
	tree.check(node.call("get_animation_cache_hits") >= 128, "描画済み8姿勢のループが履歴を使わないよ")
	print("Animation cache 128 renders: disabled %d us, exact frames %d us" % [cold_us, warm_us])
	# 容量を縮めると即座に削除。1MiBに256角RGBAは管理情報込みで3枚まで。
	node.set("animation_cache_limit_mb", 1)
	tree.check(node.call("get_animation_cache_bytes") <= 1024 * 1024
		and node.call("get_animation_cache_frame_count") <= 3, "上限縮小後に履歴容量が超過したよ")
	for i in 6:
		pose(node, i)
		node.call("get_texture")
	var misses: int = node.call("get_animation_cache_misses")
	pose(node, 0)
	node.call("get_texture")
	tree.check(node.call("get_animation_cache_misses") == misses + 1, "最も古い姿勢が追い出されていないよ")
	# 拡大率も鍵へ含め、元サイズへ戻れば元画像へ戻す。
	node.set("animation_cache_limit_mb", 32)
	tree.root.add_child(node)
	node.set("adaptive", true)
	node.scale = Vector2.ONE
	pose(node, 2)
	var small: Texture2D = node.call("get_texture")
	node.scale = Vector2(2, 2)
	var large: Texture2D = node.call("get_texture")
	tree.check(large.get_size() == small.get_size() * 2, "違う解像度の履歴を流用したよ")
	node.scale = Vector2.ONE
	tree.check(node.call("get_texture").get_rid() == small.get_rid(), "元の解像度の履歴へ戻らないよ")
	# 上限を超える1枚は保持しない。
	node.set("adaptive", false)
	node.set("animation_cache_limit_mb", 1)
	node.set("src", source(512))
	pose(node, 1)
	node.call("get_texture")
	tree.check(node.call("get_animation_cache_frame_count") == 0, "大きすぎる画像を履歴へ保持したよ")
	node.set("src", source())
	pose(node, 1)
	node.call("get_texture")
	node.call("clear_animation_cache")
	tree.check(node.call("get_animation_cache_bytes") == 0 and node.call("get_animation_cache_hits") == 0,
		"明示クリアで履歴と計数を消せないよ")
	# 設定は保存するが画像履歴はシーンへ埋め込まない。
	var packed := PackedScene.new()
	tree.check(packed.pack(node) == OK, "キャッシュ設定をシーンへ保存できないよ")
	var loaded := packed.instantiate()
	tree.check(loaded.get("animation_cache_mode") == 1 and loaded.get("animation_cache_limit_mb") == 1
		and loaded.call("get_animation_cache_frame_count") == 0, "キャッシュ設定の復元が違うよ")
	loaded.free()
	node.free()
	print("Animation cache: exact pixels, immutable frames, LRU limits and settings passed")

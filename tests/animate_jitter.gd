# SVGAnimateの接点編集と揺れ再生を同時に検証する。
# 責務: 再生周期、保持画像数、編集座標、通常SVGとの画素一致を確かめる。
# 設計思想: 変形の往復で最終形を一定に保ち、揺れの位相だけを独立して比較する。
extends RefCounted

const SOURCE := "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='48'><path fill='#f34' stroke='#fff' stroke-width='2' d='M8 12 C16 2 32 2 40 12 L52 36 L8 36 Z'/></svg>" # 小さな塗りと曲線の試験素材

# 表示結果が確定してから比較し、2Dと3Dで同じ判定を使う。
static func frame(tree: SceneTree) -> void:
	await tree.process_frame
	await RenderingServer.frame_post_draw

# ノードの継承する標準揺れ設定を揃える。
static func configure(node: Node) -> void:
	node.set("src", SOURCE)
	node.set("adaptive", false)
	node.set("jitter_amount", 0.04)
	node.set("animation_interval", 3)

# 揺れの画像だけ変化し、接点・ハンドルは往復後の元座標を保つ。
static func run(tree: SceneTree) -> void:
	for dimension in ["2D", "3D"]:
		var reference: Node = ClassDB.instantiate("SVG" + dimension)
		configure(reference)
		tree.root.add_child(reference)
		var nodes: Array[Node] = []
		for cached in [false, true]:
			var node: Node = ClassDB.instantiate("SVGAnimate" + dimension)
			tree.check(not node.get("cache_animation_frames"), "SVGAnimateの既定保持枚数が1枚でないよ")
			configure(node)
			node.set("cache_animation_frames", cached)
			tree.root.add_child(node)
			nodes.append(node)
		await frame(tree)
		var plain: PackedByteArray = reference.call("get_texture").get_image().get_data()
		reference.set("animation_enabled", true)
		for node in nodes: node.set("animation_enabled", true)
		var seen := {}
		var rids: Array[Dictionary] = [{}, {}]
		for tick in 24:
			for node in nodes:
				# 即時更新とまとめ更新のどちらでも、揺れを先頭に戻さない。
				node.set("deferred_updates", tick % 2 == 0)
				node.call("set_path_point", 0, 1, Vector2(42, 14))
				node.call("set_path_point", 0, 1, Vector2(40, 12))
				node.call("set_in_handle", 0, 1, Vector2(31, 3))
				node.call("set_in_handle", 0, 1, Vector2(32, 2))
				node.set("jitter_amount", 0.04)
			await frame(tree)
			var expected: PackedByteArray = reference.call("get_texture").get_image().get_data()
			seen[hash(expected)] = true
			for index in nodes.size():
				var node := nodes[index]
				var texture: Texture2D = node.call("get_texture")
				rids[index][texture.get_rid()] = true
				tree.check(texture.get_image().get_data() == expected,
					"SVGAnimate%sの接点編集で揺れの位相または画素がずれたよ: %d" % [dimension, tick])
				tree.check(node.call("get_path_point", 0, 1) == Vector2(40, 12)
					and node.call("get_in_handle", 0, 1) == Vector2(32, 2)
					and node.call("path_to_document", 0, Vector2(40, 12)) == Vector2(40, 12),
					"揺れが編集用の接点またはハンドルへ混ざったよ")
			tree.check(expected != plain, "揺れを有効にしても通常画像のままだよ")
		tree.check(seen.size() == 4, "接点編集中に揺れの4パターンが再生されないよ")
		tree.check(rids[0].size() == 1 and rids[1].size() == 4, "揺れの画像1枚／4枚の保持が違うよ")
		# 保持方式を途中で交換しても、古いseedの画像を流用しない。
		nodes[0].set("cache_animation_frames", true)
		nodes[1].set("cache_animation_frames", false)
		for tick in 12:
			await frame(tree)
			var expected: PackedByteArray = reference.call("get_texture").get_image().get_data()
			for node in nodes:
				tree.check(node.call("get_texture").get_image().get_data() == expected,
					"保持枚数の切り替えで揺れの絵が変わったよ")
		# srcの再設定は明示的な巻き戻しとして扱う。
		for node in nodes + [reference]: node.set("src", SOURCE)
		await frame(tree)
		for node in nodes:
			tree.check(node.call("get_texture").get_image().get_data() == reference.call("get_texture").get_image().get_data(),
				"src再設定で揺れが先頭へ戻らないよ")
		# ゼロ量と無効化は、編集座標を保ったまま通常画像に戻す。
		for node in nodes: node.set("jitter_amount", 0.0)
		await frame(tree)
		for node in nodes:
			tree.check(node.call("get_texture").get_image().get_data() == plain, "揺れ量ゼロでも変形が残ったよ")
			node.set("jitter_amount", 0.04)
			node.set("animation_enabled", false)
		await frame(tree)
		for node in nodes:
			tree.check(node.call("get_texture").get_image().get_data() == plain and not node.is_processing(),
				"揺れOFFで変形または不要な処理が残ったよ")
			node.free()
		reference.free()
	print("SVGAnimate jitter: phase preserved, 1/4 texture parity, editor coordinates unchanged")

# 接点更新のまとめ処理とロープの頂点転送を検証する。
# 責務: 高速経路と通常経路の画素・頂点を比較し、入力の境界条件を確かめる。
# 設計思想: 同じ入力の結果を比較し、端末依存の速度は測定値として報告する。
extends RefCounted

# SVG本文を小さい固定サイズへ包む。
static func svg(body: String) -> String:
	return "<svg xmlns='http://www.w3.org/2000/svg' width='64' height='48'>%s</svg>" % body

# 編集処理だけを測り、画像化の費用は最後の1回へ揃える。
static func edit_time(node: Node, deferred: bool) -> int:
	node.set("deferred_updates", deferred)
	var start := Time.get_ticks_usec()
	for frame in 12:
		for point in 32:
			node.call("set_path_point", 0, point, Vector2(point, 8 + frame % 2))
		node.call("flush_paths")
	return Time.get_ticks_usec() - start

# 2D/3D共通のパス保存とバッファ解放を検証する。
static func run(tree: SceneTree) -> void:
	var body := "<?probe > <path d='M1 1L2 2'/> ?><!-- <path d='M1 1 L2 2'/> --><g transform='translate(3 4)'>" \
		+ "<path data-note='x > y d=bad' fill='red' d='M8 8 A4 4 0 0116 16 L24 8 Z'/></g>"
	for kind in ["SVGAnimate2D", "SVGAnimate3D"]:
		var node: Node = ClassDB.instantiate(kind)
		node.set("animation_cache_mode", 0)
		node.set("adaptive", false)
		node.set("src", svg(body))
		tree.root.add_child(node)
		tree.check(node.call("get_path_count") == 1 and node.call("get_point_count", 0) == 3,
			"%sがコメント、引用符内の>、連続円弧フラグを誤読したよ" % kind)
		tree.check(node.call("path_to_document", 0, Vector2(8, 8)) == Vector2(11, 12),
			"コメント内の偽パスで表示座標がずれたよ")
		node.call("set_path_point", 0, 0, Vector2(9, 9))
		node.call("set_path_point", 0, 1, Vector2(18, 18))
		node.call("flush_paths")
		await tree.process_frame
		var edited: Image = node.call("get_texture").get_image()
		var expected: Node = ClassDB.instantiate("SVG3D" if kind == "SVGAnimate3D" else "SVG2D")
		expected.set("adaptive", false)
		expected.set("src", svg("<g transform='translate(3 4)'><path fill='red' d='M9 9 A4 4 0 0 1 18 18 L24 8 Z'/></g>"))
		tree.root.add_child(expected)
		await tree.process_frame
		tree.check(edited.get_data() == expected.call("get_texture").get_image().get_data(),
			"%sのまとめ更新または閉じたパスの始点移動で画素が変わったよ" % kind)
		expected.free()
		var bytes: int = node.call("get_render_cache_bytes")
		tree.check(bytes > 0, "描画キャッシュの使用量を取得できないよ")
		node.set("keep_render_cache", false)
		tree.check(node.call("get_render_cache_bytes") == 0, "保持OFFで中間キャッシュが残ったよ")
		node.set("src", svg(body))
		await tree.process_frame
		node.call("get_texture")
		tree.check(node.call("get_render_cache_bytes") == 0, "再描画後に中間キャッシュが残ったよ")
		# 反映待ちの変更より、新しい入力を優先する。
		node.call("set_path_point", 0, 0, Vector2(30, 30))
		node.set("src", svg("<path d='M2 3 L4 5'/>"))
		await tree.process_frame
		tree.check(node.call("get_path_point", 0, 0) == Vector2(2, 3), "反映待ちが新しいsrcを上書きしたよ")
		node.call("set_path_point", 0, 0, Vector2(NAN, INF))
		tree.check(node.call("get_path_point", 0, 0) == Vector2(2, 3), "非有限な接点を受け入れたよ")
		for invalid in ["C1 2 3 4 5 6", "S1 2 3 4", "Z", "M1e999 2", "L2 3"]:
			node.set("src", svg("<path d='%s'/>" % invalid))
			tree.check(node.call("get_path_count") == 0, "始点のないパスを編集対象にしたよ")
		node.set("src", svg("<path d='M3e38 0 l3e38 0'/>"))
		tree.check(node.call("get_point_count", 0) == 1, "相対座標の加算で接点が無限大になったよ")
		node.set("src", "")
		tree.check(node.call("get_path_count") == 0, "空のsrcに接点が残ったよ")
		node.free()

	var bench: Node = ClassDB.instantiate("SVGAnimate2D")
	bench.set("animation_cache_mode", 0)
	var path := "M0 8"
	for point in range(1, 32): path += " L%d 8" % point
	bench.set("src", svg("<path d='%s'/>" % path))
	var immediate_us := edit_time(bench, false)
	var batched_us := edit_time(bench, true)
	var before: Image = bench.call("get_texture").get_image()
	bench.set("keep_render_cache", false)
	bench.set("deferred_updates", false)
	bench.call("set_path_point", 0, 0, Vector2(0, 10))
	bench.call("set_path_point", 0, 0, Vector2(0, 9))
	tree.check(before.get_data() == bench.call("get_texture").get_image().get_data(), "保持OFFで画素が変わったよ")
	bench.free()
	print("Path edits 384: immediate %d us, deferred %d us" % [immediate_us, batched_us])

	var rope: Node3D = ClassDB.instantiate("SpriteRope3D")
	rope.set("line_mode", true)
	rope.set("simulation_enabled", false)
	rope.set("segments", 256)
	tree.root.add_child(rope)
	var mesh: ArrayMesh = rope.get_child(0, true).mesh
	var times: Array[int] = []
	for dynamic in [false, true]:
		rope.set("dynamic_mesh", dynamic)
		var start := Time.get_ticks_usec()
		for i in 64: rope.set("line_width", 0.1 + i * 0.001)
		times.append(Time.get_ticks_usec() - start)
		var arrays := mesh.surface_get_arrays(0)
		tree.check(arrays[Mesh.ARRAY_VERTEX].size() == 512 and arrays[Mesh.ARRAY_INDEX].size() == 1530,
			"ロープの帯の頂点数または接続順が変わったよ")
		tree.check(mesh.custom_aabb.size.x > 0.162, "動的な帯の境界が更新されないよ")
		rope.set("segments", 7)
		tree.check(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() == 14, "粒子数変更で面を再構成できないよ")
		rope.set("segments", 256)
	rope.set("gravity", Vector3(NAN, INF, 0))
	tree.check(rope.get("gravity").is_finite(), "無効な重力を受け入れたよ")
	rope.set("line_mode", false)
	tree.check(mesh.get_surface_count() == 0, "画像なしへ切り替えたロープの古い面が残ったよ")
	rope.set("line_mode", true)
	tree.check(mesh.get_surface_count() == 1, "表示を戻しても面が再生成されないよ")
	rope.free()
	print("Rope mesh 64 updates: rebuild %d us, vertex-only %d us" % times)

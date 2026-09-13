# SVG2D の公開 API と基本の描画結果を短時間で確かめるテスト。
# 責務: クラス登録、読み取り、画像化、ノードの設定を一括で検証すること。
# 設計思想: 画面を開かず、失敗した条件を終了コードと短い文で返す。
extends SceneTree

var failed := false

# 条件が外れたときに、後続の確認を続けながら失敗を覚える。
func check(ok: bool, message: String) -> void:
	if ok:
		return
	failed = true
	push_error(message)

# 小さな SVG を通して、利用者が触る入口をまとめて確かめる。
func _initialize() -> void:
	if not ClassDB.class_exists("SVG2D"):
		var status: GDExtensionManager.LoadStatus = GDExtensionManager.load_extension(
				"res://addons/svg2d/svg2d.gdextension")
		check(status == GDExtensionManager.LOAD_STATUS_OK,
				"GDExtension を読み込めなかったよ: %s" % status)
	check(ClassDB.class_exists("SVG"), "SVG が登録されていないよ")
	check(ClassDB.class_exists("SVG2D"), "SVG2D が登録されていないよ")
	if failed:
		quit(1)
		return

	var text := FileAccess.get_file_as_string("res://tests/svg/hello.svg")
	for path in ["hello.svg", "spec.svg", "spec2.svg"]:
		var doc: Object = ClassDB.instantiate("SVG")
		var sample := FileAccess.get_file_as_string("res://tests/svg/" + path)
		check(doc.call("parse", sample), "%s を読み取れなかったよ: %s" % [path, doc.call("get_error")])
		var image: Image = doc.call("render", 64, 48)
		check(image != null, "%s の画像を作れなかったよ" % path)
		if image != null:
			check(image.get_size() == Vector2i(64, 48), "%s の画像の大きさが違うよ" % path)
			check(image.get_used_rect().has_area(), "%s の絵が空だよ" % path)

	var sized: Object = ClassDB.instantiate("SVG")
	check(sized.call("parse", text), "大きさ確認用の SVG を読み取れなかったよ")
	check(sized.call("doc_size") == Vector2(100, 100), "文書の大きさが違うよ")

	var node: Node2D = ClassDB.instantiate("SVG2D")
	node.set("source", text)
	node.set("size", Vector2(40, 30))
	check(node.get("source") == text, "SVG2D の source が戻らないよ")
	check(node.get("size") == Vector2(40, 30), "SVG2D の size が戻らないよ")
	var texture: Texture2D = node.call("get_texture")
	check(texture != null, "SVG2D の画像を作れなかったよ")
	if texture != null:
		check(texture.get_image().get_used_rect().has_area(), "SVG2D の画像が空だよ")
	node.free()
	if not failed:
		print("SVG2D の試験に通ったよ")
	quit(1 if failed else 0)

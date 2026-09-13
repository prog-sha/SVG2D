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
	check(ClassDB.class_exists("SVG2D"), "SVG2D が登録されていないよ")
	check(not ClassDB.class_exists("SVG"), "内部の SVG が公開されているよ")
	if failed:
		quit(1)
		return

	for path in ["hello.svg", "spec.svg", "spec2.svg"]:
		var sample := FileAccess.get_file_as_string("res://tests/svg/" + path)
		var node: Node2D = ClassDB.instantiate("SVG2D")
		node.set("src", sample)
		node.set("size", Vector2(64, 48))
		check(node.get("src") == sample, "%s の src が戻らないよ" % path)
		check(node.get("size") == Vector2(64, 48), "%s の大きさが戻らないよ" % path)
		var texture: Texture2D = node.call("get_texture")
		check(texture != null, "%s の画像を作れなかったよ" % path)
		if texture != null:
			var image := texture.get_image()
			check(image.get_size() == Vector2i(64, 48), "%s の画像の大きさが違うよ" % path)
			check(image.get_used_rect().has_area(), "%s の画像が空だよ" % path)
		node.free()

	var config := ConfigFile.new()
	check(config.load("res://addons/svg2d/plugin.cfg") == OK, "plugin.cfg を読めなかったよ")
	check(config.get_value("plugin", "script") == "plugin.gd", "プラグインの入口が違うよ")
	check(load("res://addons/svg2d/plugin.gd") != null, "プラグインの入口を読めなかったよ")
	if not failed:
		print("SVG2D の試験に通ったよ")
	quit(1 if failed else 0)

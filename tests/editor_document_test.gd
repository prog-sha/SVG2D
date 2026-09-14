# SVG編集文書の読み書き、階層操作、属性更新を画面なしで確かめる。
# 責務: 編集UIの核がSVGを壊さず、実行時ルーチンと無関係に動くことを判断する。
# 設計思想: 文書操作を短い一括試験にし、UI試験と重複させない。
extends SceneTree

const Document = preload("res://addons/svg2d/editor/document.gd") # 試験するSVG文書モデル

var failed := false

# 条件が外れたら失敗を覚えて後続確認を続ける。
func check(ok: bool, message: String) -> void:
	if ok:
		return
	failed = true
	push_error(message)

# パーツの作成から保存形式までをまとめて確かめる。
func _initialize() -> void:
	var doc: RefCounted = Document.new()
	doc.create(320, 240)
	var rect: Dictionary = doc.add("rect", {"id": "box", "x": "10", "y": "20", "width": "40", "height": "30", "fill": "#f00"})
	var circle: Dictionary = doc.add("circle", {"id": "dot", "cx": "80", "cy": "40", "r": "12", "fill": "#0f0"})
	check(doc.bounds(rect.uid) == Rect2(10, 20, 40, 30), "長方形の境界が違うよ")
	var group: Dictionary = doc.group([rect.uid, circle.uid])
	check(not group.is_empty() and group.children.size() == 2, "グループ化できないよ")
	doc.translate(group.uid, Vector2(5, -3))
	var copy: Dictionary = doc.duplicate_element(group.uid)
	check(not copy.is_empty(), "複製できないよ")
	var ids: Array[int] = doc.ungroup(copy.uid)
	check(ids.size() == 2, "グループ解除できないよ")
	var text: Dictionary = doc.add("text", {"x": "20", "y": "100", "font-size": "18"})
	doc.set_text(text.uid, "A&B <C>")
	var path: Dictionary = doc.add("path", {"d": "M 0 0 L 20 10 L 30 40 Z"})
	doc.set_edit_point(path.uid, 1, Vector2(25, 15))
	check(doc.edit_points(path.uid)[1] == Vector2(25, 15), "直線パスの点を編集できないよ")
	doc.scale_around(rect.uid, Vector2(2, 3), Vector2(10, 20))
	check(str(doc.find(rect.uid).attrs.transform).begins_with("matrix(2 0 0 3"), "選択要素を拡大縮小できないよ")
	var svg: String = doc.to_svg()
	check(svg.contains("A&amp;B &lt;C&gt;"), "文字のXMLエスケープが違うよ")
	var loaded: RefCounted = Document.new()
	check(loaded.load_text(svg) == OK, "保存したSVGを読み戻せないよ")
	check(loaded.document_rect() == Rect2(0, 0, 320, 240), "viewBoxを保てないよ")
	check(svg.contains("<g") and svg.contains("<circle"), "未変換のSVG要素が消えたよ")
	if not failed:
		print("SVG editor document tests passed")
	quit(1 if failed else 0)

# SVG編集画面を実ウィンドウへ組み立て、主要パネルと描画結果を確かめる。
# 責務: エディター用UIが実行時に崩れず、目視確認用画像を残せるか判断する。
# 設計思想: 画面外の小さなウィンドウで一度描画し、毎フレームの監視を行わない。
extends SceneTree

const Workspace = preload("res://addons/svg2d/editor/workspace.gd") # 確認するSVG編集画面

var workspace: Control # 画面へ追加した編集領域

# 画面外へ移してから編集領域を構築する。
func _initialize() -> void:
	DisplayServer.window_set_position(Vector2i(10000, 10000))
	workspace = Workspace.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(workspace)
	workspace.call_deferred("grab_focus")
	_capture.call_deferred()

# レイアウト確定後の画像と主要部品を一括確認する。
func _capture() -> void:
	await process_frame
	await process_frame
	workspace.call("_create", "rect", {"x": "100", "y": "100", "width": "240", "height": "160", "fill": "#4c8dff"})
	workspace.call("_select", 0, false)
	workspace.call("_context_color", Color("f7476e"), "fill")
	workspace.call("_create", "ellipse", {"cx": "470", "cy": "180", "rx": "90", "ry": "90", "fill": "#f7476e"})
	await process_frame
	var tree_root: TreeItem = workspace.layers.get_root()
	var ok := workspace.canvas != null and workspace.source != null and tree_root != null and tree_root.get_child_count() == 2
	ok = ok and workspace.tool_buttons.size() == 9 and workspace.history_list != null
	ok = ok and workspace.canvas.size.x >= 300 and workspace.selection_label.is_visible_in_tree()
	ok = ok and workspace.canvas.fill == Color("f7476e") and workspace.selected.size() == 1
	var image := root.get_texture().get_image()
	var output := "res://tmp/editor-ui-%d.png" % DisplayServer.window_get_size().x
	var error := image.save_png(output)
	if not ok or error != OK:
		push_error("SVG編集画面を描画できないよ")
		quit(1)
		return
	print("SVG editor UI test passed")
	quit()

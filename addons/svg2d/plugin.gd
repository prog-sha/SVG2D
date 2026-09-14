# SVG2Dのノード登録とSVG編集ワークスペースをGodotエディターへ接続する。
# 責務: 中央編集画面と書き出し除外を有効化し、無効時に安全に外すこと。
# 設計思想: 編集UIはeditorフォルダーに閉じ、実行時GDExtensionから参照しない。
@tool
extends EditorPlugin

const Workspace = preload("editor/workspace.gd") # 中央のSVG編集画面
const ExportFilter = preload("editor/export_filter.gd") # ゲームから編集ファイルを外す係

var workspace: Control # 表示中のSVG編集ワークスペース
var export_filter: EditorExportPlugin # 書き出し中の編集ファイル除外

# SVG編集画面をメインスクリーンに追加する。
func _enter_tree() -> void:
	workspace = Workspace.new()
	workspace.name = "SVG"
	workspace.setup(self)
	EditorInterface.get_editor_main_screen().add_child(workspace)
	export_filter = ExportFilter.new()
	add_export_plugin(export_filter)
	_make_visible(false)

# 追加した編集画面と書き出しフィルターを外す。
func _exit_tree() -> void:
	if export_filter:
		remove_export_plugin(export_filter)
		export_filter = null
	if workspace:
		workspace.queue_free()
		workspace = null

# 2D・3Dと同じ中央領域を使うSVG編集画面であることを知らせる。
func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "SVG"

func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon("Node2D", "EditorIcons")

# エディター上部のSVGボタンに合わせて画面を表示する。
func _make_visible(visible: bool) -> void:
	if workspace:
		workspace.visible = visible

# SVG2D・SVG3Dを選択したとき、同じ編集画面でsrcを開けるようにする。
func _handles(object: Object) -> bool:
	return object != null and (object.is_class("SVG2D") or object.is_class("SVG3D"))

func _edit(object: Object) -> void:
	if workspace and object:
		workspace.edit_node(object)

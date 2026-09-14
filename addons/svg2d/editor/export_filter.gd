# SVG編集用のUIと資料をゲームの書き出しから外す。
# 責務: 実行時に必要なGDExtension・バイナリと編集拡張を分離すること。
# 設計思想: プロジェクト内に編集スクリプトがあっても、配布ゲームに含めない。
@tool
extends EditorExportPlugin

const EDITOR_PREFIX := "res://addons/svg2d/editor/" # 編集専用ファイルの場所
const EDITOR_FILES := [
	"res://addons/svg2d/plugin.gd",
	"res://addons/svg2d/plugin.cfg",
	"res://addons/svg2d/README.md",
	"res://addons/svg2d/README.ja.md",
	"res://addons/svg2d/LICENSE",
	"res://addons/svg2d/THIRD_PARTY_NOTICES.md",
] # 編集時と配布説明に使うファイル

# 書き出し対象ごとに編集専用か判断し、対象から外す。
func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with(EDITOR_PREFIX) or path in EDITOR_FILES:
		skip()

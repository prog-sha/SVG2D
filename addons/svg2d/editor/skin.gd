# SVG編集画面の色、余白、丸みを一か所で揃える。
# 責務: 道具、帯、Studio、入力欄へ同じ視覚規則を適用すること。
# 設計思想: YuruttoPictの緑と暖かな中間色を、長時間使える暗い作業台へ展開する。
@tool
extends RefCounted

const ACCENT := Color("1abc9c") # 選択中と主要操作を示す緑
const ACCENT_D := Color("128d78") # 押している間の緑
const BAR := Color("343436") # 共通操作を置く最上部
const PANEL := Color("414044") # 道具とStudioの地
const PANEL_2 := Color("4b4a4e") # 入力欄と選択前の面
const CANVAS := Color("68676c") # 白い紙を見分ける作業台
const BORDER := Color("5d5a59") # 面どうしの境
const TEXT := Color("fdfcfb") # 暗い面の本文
const MUTED := Color("c3bbb4") # 補助情報
const PAPER := Color("ffffff") # SVG文書の紙
const DARK := Color("2a292c") # コード欄と深い溝

# 丸角、背景、枠線をまとめた面を作る。
static func box(color: Color, radius := 6, border := 0, border_color := BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	if border > 0:
		style.set_border_width_all(border)
		style.border_color = border_color
	return style

# 帯やStudioの背景を役割に合う色へ揃える。
static func panel(node: Control, color := PANEL, radius := 0) -> void:
	node.add_theme_stylebox_override("panel", box(color, radius))

# 押しボタンへ通常、選択、マウス重なりの違いを付ける。
static func button(node: Button, active := false) -> void:
	var normal := ACCENT if active else Color.TRANSPARENT
	node.add_theme_stylebox_override("normal", box(normal, 7))
	node.add_theme_stylebox_override("hover", box(ACCENT_D if active else PANEL_2, 7))
	node.add_theme_stylebox_override("pressed", box(ACCENT_D, 7))
	node.add_theme_stylebox_override("focus", box(Color.TRANSPARENT, 7, 1, ACCENT))
	node.add_theme_color_override("font_color", TEXT)
	node.add_theme_color_override("font_hover_color", TEXT)
	node.add_theme_color_override("font_pressed_color", TEXT)
	node.add_theme_font_size_override("font_size", 13)

# 入力欄を暗い溝として揃え、値と背景の境界を明確にする。
static func input(node: LineEdit) -> void:
	node.add_theme_stylebox_override("normal", box(DARK, 6, 1, BORDER))
	node.add_theme_stylebox_override("focus", box(DARK, 6, 1, ACCENT))
	node.add_theme_color_override("font_color", TEXT)
	node.add_theme_color_override("font_placeholder_color", MUTED)
	node.add_theme_constant_override("minimum_character_width", 5)

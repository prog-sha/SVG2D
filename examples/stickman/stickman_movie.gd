extends Node2D

const MOVIE_LENGTH := 2.0
const KEY_TIMES := [0.0, 0.5, 1.0, 1.5, 2.0]

var stickman: Node2D
var animation_player: AnimationPlayer


func _ready() -> void:
	stickman = ClassDB.instantiate("SVGAnimate2D")
	stickman.name = "Stickman"
	# SVG2Dの原点は素材の左上。640x360の中央へ320x360素材を置く。
	stickman.position = Vector2(160, 0)
	stickman.set("src", "res://examples/stickman/stickman.svg")
	stickman.set("adaptive", false)
	add_child(stickman)

	animation_player = AnimationPlayer.new()
	animation_player.name = "AnimationPlayer"
	stickman.add_child(animation_player)
	var library := AnimationLibrary.new()
	var dance := Animation.new()
	dance.length = MOVIE_LENGTH
	dance.loop_mode = Animation.LOOP_LINEAR

	# SVGのトポロジーは固定したまま、手足の終点番号だけをキー化する。
	_add_point_track(dance, 2, 1, [
		Vector2(91, 184), Vector2(72, 126), Vector2(101, 199),
		Vector2(65, 158), Vector2(91, 184),
	])
	_add_point_track(dance, 3, 1, [
		Vector2(229, 184), Vector2(219, 205), Vector2(248, 128),
		Vector2(223, 151), Vector2(229, 184),
	])
	_add_point_track(dance, 4, 1, [
		Vector2(108, 326), Vector2(126, 315), Vector2(91, 310),
		Vector2(119, 326), Vector2(108, 326),
	])
	_add_point_track(dance, 5, 1, [
		Vector2(212, 326), Vector2(237, 302), Vector2(221, 326),
		Vector2(194, 304), Vector2(212, 326),
	])

	library.add_animation("dance", dance)
	animation_player.add_animation_library("", library)
	animation_player.play("dance")
	print("Stickman MovieWriter demo: AnimationPlayer is animating 4 SVG point tracks")


func _add_point_track(animation: Animation, path_index: int, point_index: int, values: Array) -> void:
	var track := animation.add_track(Animation.TYPE_VALUE)
	animation.track_set_path(track, NodePath(".:paths/path_%d/point_%d" % [path_index, point_index]))
	animation.track_set_interpolation_type(track, Animation.INTERPOLATION_CUBIC)
	for index in KEY_TIMES.size():
		animation.track_insert_key(track, KEY_TIMES[index], values[index])


func _draw() -> void:
	draw_rect(Rect2(0, 0, 640, 360), Color("101426"))
	draw_circle(Vector2(320, 334), 260.0, Color("18203a"))
	draw_line(Vector2(76, 340), Vector2(564, 340), Color("7582a8"), 2.0)

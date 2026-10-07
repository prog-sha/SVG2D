# 同じ画像のGPU更新と不透明度マスクを、実描画環境で短時間に検証する。
extends SceneTree
var failed := false
func check(ok: bool, message: String) -> void:
	if not ok:
		failed = true
		push_error(message)
func _initialize() -> void:
	DisplayServer.window_set_position(Vector2i(10000, 10000))
	run.call_deferred()
func run() -> void:
	var probe = preload("res://tests/editor_inspector_test.gd")
	await probe.test_opaque_mask(self)
	print("SVG editor alpha mask: ", "FAILED" if failed else "PASSED")
	quit(1 if failed else 0)

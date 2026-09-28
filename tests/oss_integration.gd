# SVG表示とロープ接続の結合試験を、同じGodot実行で検証する。
# 責務: 失敗の集約、時間上限、独立した期待値と実際の描画・物理の比較。
# 設計思想: tests/oss_sources.jsonの観点を独自シーンで再現し、内部計算の往復値に頼らない。
extends SceneTree
var failed := false
var assertions := 0

func check(ok: bool, message: String) -> void:
	assertions += 1
	if not ok:
		failed = true
		push_error(message)

func _initialize() -> void:
	DisplayServer.window_set_position(Vector2i(10000, 10000))
	run.call_deferred()

func run() -> void:
	create_timer(4.5).timeout.connect(func(): push_error("OSS integration timeout"); quit(2))
	await preload("res://tests/oss_svg_integration.gd").run(self)
	await preload("res://tests/oss_rope_integration.gd").run(self)
	print("OSS integration: %d assertions, %s" % [assertions, "FAILED" if failed else "PASSED"])
	quit(1 if failed else 0)

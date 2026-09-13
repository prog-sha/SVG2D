// SVG2D 拡張を Godot へ登録する入口。
// 責務: SVG2D を場面の読み込み前に使える状態へすること。
// 設計思想: 登録処理を描画本体から分け、拡張の入口を短く保つ。
#include "svg.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

// SVG2D を場面で使える型として知らせる。
static void initialize_svg2d(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
	GDREGISTER_CLASS(svg2d::SVG2D);
}

// 拡張を外す段階を受け取る。解放が必要な共有資源は持たない。
static void uninitialize_svg2d(ModuleInitializationLevel level) {
	if (level != MODULE_INITIALIZATION_LEVEL_SCENE) return;
}

extern "C" {
// Godot と C++ の結び付きを作り、登録処理を渡す。
GDExtensionBool GDE_EXPORT svg2d_init(GDExtensionInterfaceGetProcAddress get_proc,
		const GDExtensionClassLibraryPtr library, GDExtensionInitialization *initialization) {
	GDExtensionBinding::InitObject init(get_proc, library, initialization);
	init.register_initializer(initialize_svg2d);
	init.register_terminator(uninitialize_svg2d);
	init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
	return init.init();
}
}

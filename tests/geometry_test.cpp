// 大きな有限座標を、小さな画面へ安全に描画するための部品試験。
// 責務: 曲線分割と辺の切り詰めで、整数化前の範囲制限を検証する。
#include "svg/raster.h"
#include "svg/paint.h"
#include <cassert>
#include <cstdio>

int main() {
	using namespace svg2d::svg;
	godot::Vector2 a, b(1e30f, 1e30f), c, d(-1e30f, -1e30f);
	assert(arc_n(1e30, 6.28, 1e-30) == 64);
	assert(quad_steps(a, b, c, 0.05) == 300);
	assert(cubic_steps(a, b, c, d, 0.05) == 300);
	Mask mask;
	mask.make(0, 0, 16, 16);
	// 左右とも画面外にある縦辺でも、その間の全画素を覆う。
	mask_line(mask, {-1e12f, -1e12f}, {-1e12f, 1e12f});
	mask_line(mask, {1e12f, 1e12f}, {1e12f, -1e12f});
	mask_resolve(mask, false);
	for (int y = 0; y < mask.h; y++)
		for (int x = 0; x < mask.w; x++)
			assert(mask.a[(size_t)y * (mask.w + 2) + x] == 1.0f);
	// 色の位置が数値域を越えても、3種の折返し方すべてで端の色を返す。
	Paint paint;
	paint.kind = Paint::LINEAR;
	paint.x1 = -1e308;
	paint.x2 = 1e308;
	paint.lut = build_lut({{0, godot::Color(1, 0, 0, 1)}, {1, godot::Color(0, 0, 1, 1)}});
	for (Spread spread : {SPREAD_PAD, SPREAD_REPEAT, SPREAD_REFLECT}) {
		paint.spread = spread;
		auto color = paint_at_q(paint, 8, 8, 8, 8);
		assert(color.b > 0.99f && color.r < 0.01f && color.a == 1.0f);
	}
	std::puts("SVG geometry range checks passed");
}

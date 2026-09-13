// 形を画素の濃さに変えるところ。
//
// 責務: 閉じた形の並びを受けて、画素ごとの「どれだけ覆われているか」を出すこと。
// そして、その覆いを使って色を重ねること。何の形かも、何色かも知らない。
//
// 設計思想: 覆いは面積そのものとして数える。1 画素を何回か細かく見て数える
// やり方だと、斜めの縁に段が出て、Chromium の縁と食い違う。
// 辺が 1 画素を横切るときの面積を式で出して足し込み、横に足し合わせて濃さにする。
// FreeType の smooth と font-rs、Skia の解析的なアンチエイリアスが同じ考え方。
//
// 元にした場所:
//   Skia src/core/SkScan_AAAPath.cpp … 走査線を「辺の端と交わり」で切り、面積で数える
//   font-rs（Raph Levien）… 面積の足し込みと、横に足し合わせて濃さにする組み方
#ifndef SVG2D_SVG_RASTER_H
#define SVG2D_SVG_RASTER_H

#include "geom.h"

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/transform2d.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace svg2d {
namespace svg {

// 画素ごとの覆い。形の入る四角ぶんだけ持つ。
// 画面ぜんぶを持つと、小さな形 1 つのために画面まるごとの入れ物を作ることになる。
struct Mask {
	int x0 = 0, y0 = 0, w = 0, h = 0;
	std::vector<float> a;   // (w+2) * h。横に足し合わせる前の、面積の足し込み
	// 段ごとに、辺が触れた左右の端。触れていない所は必ず覆いが 0 なので、
	// ここだけ見れば済む。細い線を大きな四角の中に引いたとき、
	// 中身のほとんどが空なのに全部なめることになるのを避ける
	std::vector<int> lo, hi;

	// 入れ物は使い回す。assign は、前より小さければ取り直さない。
	// 札ごとに取り直すと、小さな形 789 個で 2000 回以上の取り直しになる
	void make(int px, int py, int pw, int ph) {
		x0 = px; y0 = py; w = pw; h = ph;
		a.assign((size_t)(w + 2) * (size_t)h, 0.0f);
		lo.assign((size_t)h, w);
		hi.assign((size_t)h, -1);
	}
	void drop() { w = h = 0; }
	bool empty() const { return w <= 0 || h <= 0; }
	void touch(int y, int i0, int i1) {
		if (i0 < lo[(size_t)y]) lo[(size_t)y] = i0;
		if (i1 > hi[(size_t)y]) hi[(size_t)y] = i1;
	}
};

// 切り抜きの覆い。Mask と同じく、入る四角ぶんだけ持つ。
// 四角の外は覆い 0、つまり出ない。大きさ 0 の覆いは「どこも出ない」を表す。
struct Cover {
	int x0 = 0, y0 = 0, w = 0, h = 0;
	std::vector<float> a;   // w * h

	float at(int px, int py) const {
		int x = px - x0, y = py - y0;
		if (x < 0 || y < 0 || x >= w || y >= h) return 0.0f;
		return a[(size_t)y * (size_t)w + (size_t)x];
	}
};

// 辺を 1 本足し込む。上から下へ、1 段ずつ横切った面積を置いていく。
inline void mask_line(Mask &m, godot::Vector2 p0, godot::Vector2 p1) {
	if (p0.y == p1.y) return;
	float dir = 1.0f;
	if (p0.y > p1.y) {
		std::swap(p0, p1);
		dir = -1.0f;
	}
	p0.x -= (float)m.x0; p0.y -= (float)m.y0;
	p1.x -= (float)m.x0; p1.y -= (float)m.y0;
	double dxdy = (double)(p1.x - p0.x) / (double)(p1.y - p0.y);
	int ylo = std::max((int)std::floor(p0.y), 0);
	int yhi = std::min((int)std::ceil(p1.y), m.h);
	for (int y = ylo; y < yhi; y++) {
		float *row = &m.a[(size_t)y * (size_t)(m.w + 2)];
		double ytop = std::max((double)y, (double)p0.y);
		double ybot = std::min((double)(y + 1), (double)p1.y);
		double dy = ybot - ytop;
		if (dy <= 0.0) continue;
		double xa = p0.x + (ytop - p0.y) * dxdy;
		double xb = p0.x + (ybot - p0.y) * dxdy;
		double d = dy * dir;
		double lo = std::min(xa, xb), hi = std::max(xa, xb);
		// 入れ物の外へ出たぶんは端へ寄せる。左の外は「ずっと覆っている」ので端の桁へ、
		// 右の外は画面に出ないので落ちてよい
		lo = std::clamp(lo, 0.0, (double)m.w);
		hi = std::clamp(hi, 0.0, (double)m.w);
		int i0 = (int)lo;
		int i1 = (int)hi;
		if (i0 >= m.w) i0 = m.w - 1;
		if (i1 >= m.w) i1 = m.w - 1;
		m.touch(y, i0, std::min(i1 + 1, m.w - 1));
		if (i0 == i1) {
			// 1 つの桁の中で済むとき。真ん中の位置で左右へ分ける
			double xm = (lo + hi) * 0.5 - (double)i0;
			row[i0] += (float)(d * (1.0 - xm));
			row[i0 + 1] += (float)(d * xm);
			continue;
		}
		// またぐとき。桁ごとに、その桁を通る割合で分ける
		double s = 1.0 / (hi - lo);
		double f0 = (double)(i0 + 1) - lo;
		double a0 = 0.5 * s * f0 * f0;
		double f1 = hi - (double)i1;
		double am = 0.5 * s * f1 * f1;
		row[i0] += (float)(d * a0);
		if (i1 == i0 + 1) {
			row[i0 + 1] += (float)(d * (1.0 - a0 - am));
		} else {
			double a1 = s * (f0 + 0.5);
			row[i0 + 1] += (float)(d * (a1 - a0));
			for (int i = i0 + 2; i < i1; i++) row[i] += (float)(d * s);
			double a2 = a1 + (double)(i1 - i0 - 2) * s;
			row[i1] += (float)(d * (1.0 - a2 - am));
		}
		row[i1 + 1] += (float)(d * am);
	}
}

// 覆いを切り抜きの形へ移す。段ごとの詰めものを外して、素直な並びにする。
inline Cover mask_cover(const Mask &m) {
	Cover c;
	if (m.w <= 0 || m.h <= 0) return c;
	c.x0 = m.x0; c.y0 = m.y0; c.w = m.w; c.h = m.h;
	c.a.assign((size_t)m.w * (size_t)m.h, 0.0f);
	for (int y = 0; y < m.h; y++)
		std::copy(&m.a[(size_t)y * (size_t)(m.w + 2)],
				&m.a[(size_t)y * (size_t)(m.w + 2)] + m.w, &c.a[(size_t)y * (size_t)m.w]);
	return c;
}

// 形をまるごと足し込む。閉じていないひと続きは、始めと終わりをつないで閉じる。
// 置きかたはここで掛ける。先に写して動かした形を作ると、札ごとに点の数だけ
// 入れ物を取り直すことになる
inline void mask_add(Mask &m, const Path &path, const godot::Transform2D &at) {
	for (const Sub &s : path) {
		if (s.p.size() < 2) continue;
		godot::Vector2 a = at.xform(s.p[0]), first = a;
		for (size_t i = 1; i < s.p.size(); i++) {
			godot::Vector2 b = at.xform(s.p[i]);
			mask_line(m, a, b);
			a = b;
		}
		if (!a.is_equal_approx(first)) mask_line(m, a, first);
	}
}

// 横に足し合わせて濃さにする。巻き数の見かたを渡す（偶奇か、0 でないか）。
// 出したものは 0〜1 の濃さで、そのまま入れ物へ書き戻す。
inline void mask_resolve(Mask &m, bool even_odd) {
	for (int y = 0; y < m.h; y++) {
		float *row = &m.a[(size_t)y * (size_t)(m.w + 2)];
		double acc = 0.0;
		int x1 = std::min(m.hi[(size_t)y] + 1, m.w);
		for (int x = m.lo[(size_t)y]; x < x1; x++) {
			acc += row[x];
			double v;
			if (even_odd) {
				// 2 で割った余り。行って戻る形にすると、重なった所も正しく抜ける
				double t = std::fmod(std::abs(acc), 2.0);
				v = t <= 1.0 ? t : 2.0 - t;
			} else {
				v = std::min(std::abs(acc), 1.0);
			}
			row[x] = (float)v;
		}
	}
}

// 形の入る四角。足し込む前に、どれだけの入れ物が要るかを知るのに使う。
inline godot::Rect2 path_box(const Path &path, const godot::Transform2D &at) {
	bool got = false;
	double x0 = 0, y0 = 0, x1 = 0, y1 = 0;
	for (const Sub &s : path)
		for (const godot::Vector2 &raw : s.p) {
			godot::Vector2 v = at.xform(raw);
			if (!got) {
				x0 = x1 = v.x; y0 = y1 = v.y; got = true;
				continue;
			}
			x0 = std::min(x0, (double)v.x); x1 = std::max(x1, (double)v.x);
			y0 = std::min(y0, (double)v.y); y1 = std::max(y1, (double)v.y);
		}
	if (!got) return godot::Rect2();
	return godot::Rect2((float)x0, (float)y0, (float)(x1 - x0), (float)(y1 - y0));
}

inline godot::Rect2 path_box(const Path &path) {
	return path_box(path, godot::Transform2D());
}

// 描く先。色は掛け合わせ済み（premultiplied）の 8 bit で持つ。
// 掛け合わせ済みで持つと、まとまりごとの薄さを重ねるときにそのまま掛けるだけで済む。
// 8 bit で持つのは、Chromium が同じ持ちかたをしているからと、実数で持つと
// 800x800 で 10 MB になり、その置き場を用意するだけで 4 ミリ秒かかるため。
struct Canvas {
	int w = 0, h = 0;
	std::vector<uint8_t> px;   // w * h * 4
	// 触った範囲。まとまりの薄さを重ねるときに、ここだけ見れば済む
	int dx0 = 0, dy0 = 0, dx1 = -1, dy1 = -1;

	void make(int pw, int ph) {
		w = pw; h = ph;
		px.assign((size_t)w * (size_t)h * 4, 0);
		dx0 = w; dy0 = h; dx1 = -1; dy1 = -1;
	}
	// 触った範囲だけ 0 へ戻す。深さごとに紙を使い回すのに使う。
	// 札ごとに作り直すと、800x800 で 2.5 MB を用意して埋めるのが札の数だけ起きる
	void clear() {
		for (int y = dy0; y <= dy1; y++) {
			size_t i = ((size_t)y * (size_t)w + (size_t)dx0) * 4;
			std::fill(px.begin() + i, px.begin() + i + (size_t)(dx1 - dx0 + 1) * 4, (uint8_t)0);
		}
		dx0 = w; dy0 = h; dx1 = -1; dy1 = -1;
	}
	void mark(int x, int y) {
		if (x < dx0) dx0 = x;
		if (x > dx1) dx1 = x;
		if (y < dy0) dy0 = y;
		if (y > dy1) dy1 = y;
	}
	// 1 画素へ色を重ねる。cov は覆い、col は掛け合わせる前の色。
	// 計算は実数でして、置くときだけ 8 bit へ丸める（Skia と同じ）
	void over(int x, int y, const godot::Color &col, double cov) {
		float sa = (float)((double)col.a * cov);
		if (sa <= 0.0f) return;
		mark(x, y);
		uint8_t *d = &px[((size_t)y * (size_t)w + (size_t)x) * 4];
		float ia = 1.0f - sa;
		float s = sa * 255.0f;
		d[0] = (uint8_t)(col.r * s + (float)d[0] * ia + 0.5f);
		d[1] = (uint8_t)(col.g * s + (float)d[1] * ia + 0.5f);
		d[2] = (uint8_t)(col.b * s + (float)d[2] * ia + 0.5f);
		d[3] = (uint8_t)(s + (float)d[3] * ia + 0.5f);
	}
	// 別の描き先をまるごと重ねる。まとまりの薄さ（opacity）に使う。
	void over(const Canvas &src, double alpha) {
		float a = (float)alpha;
		for (int y = src.dy0; y <= src.dy1; y++)
			for (int x = src.dx0; x <= src.dx1; x++) {
				size_t i = ((size_t)y * (size_t)w + (size_t)x) * 4;
				const uint8_t *s = &src.px[i];
				if (s[3] == 0) continue;
				float ia = 1.0f - (float)s[3] / 255.0f * a;
				uint8_t *d = &px[i];
				for (int j = 0; j < 4; j++)
					d[j] = (uint8_t)((float)s[j] * a + (float)d[j] * ia + 0.5f);
				mark(x, y);
			}
	}
};

} // namespace svg
} // namespace svg2d

#endif // SVG2D_SVG_RASTER_H

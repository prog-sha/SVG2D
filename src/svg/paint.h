// SVG の「色」を扱うところ。
//
// 責務: 色の書きかたを色に直すことと、色の移り変わり（グラデーション）の
// その場所の色を出すこと。どこへ描くかも、何の形かも知らない。
//
// 設計思想: 色の移り変わりは、画素ごとにその場で出す。あらかじめ 1 本の帯に焼いて
// 貼るやり方だと、焦点をずらした丸い移り変わりが表せない。
//
// 元にした場所:
//   SVG 1.1 13.2.3 … 丸い移り変わりの焦点が円の外に出たときは、円のふちへ寄せる
//   SVG 1.1 4.1 / CSS Color … 色の書きかたと、名前つきの色 148 個
#ifndef SVG2D_SVG_PAINT_H
#define SVG2D_SVG_PAINT_H

#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/transform2d.hpp>

#include <algorithm>
#include <cmath>
#include <memory>
#include <cstdint>
#include <cstring>
#include <vector>

namespace svg2d {
namespace svg {

// CSS の色の名前ぜんぶ（SVG 1.1 が使うのと同じ 148 個）。
// 名前で色を書けるようにするために持つ。並びは名前順で、探すときは二分探索。
static const struct { const char *name; uint32_t rgb; } NAMED[] = {
	{ "aliceblue", 0xf0f8ffu },
	{ "antiquewhite", 0xfaebd7u },
	{ "aqua", 0x00ffffu },
	{ "aquamarine", 0x7fffd4u },
	{ "azure", 0xf0ffffu },
	{ "beige", 0xf5f5dcu },
	{ "bisque", 0xffe4c4u },
	{ "black", 0x000000u },
	{ "blanchedalmond", 0xffebcdu },
	{ "blue", 0x0000ffu },
	{ "blueviolet", 0x8a2be2u },
	{ "brown", 0xa52a2au },
	{ "burlywood", 0xdeb887u },
	{ "cadetblue", 0x5f9ea0u },
	{ "chartreuse", 0x7fff00u },
	{ "chocolate", 0xd2691eu },
	{ "coral", 0xff7f50u },
	{ "cornflowerblue", 0x6495edu },
	{ "cornsilk", 0xfff8dcu },
	{ "crimson", 0xdc143cu },
	{ "cyan", 0x00ffffu },
	{ "darkblue", 0x00008bu },
	{ "darkcyan", 0x008b8bu },
	{ "darkgoldenrod", 0xb8860bu },
	{ "darkgray", 0xa9a9a9u },
	{ "darkgreen", 0x006400u },
	{ "darkgrey", 0xa9a9a9u },
	{ "darkkhaki", 0xbdb76bu },
	{ "darkmagenta", 0x8b008bu },
	{ "darkolivegreen", 0x556b2fu },
	{ "darkorange", 0xff8c00u },
	{ "darkorchid", 0x9932ccu },
	{ "darkred", 0x8b0000u },
	{ "darksalmon", 0xe9967au },
	{ "darkseagreen", 0x8fbc8fu },
	{ "darkslateblue", 0x483d8bu },
	{ "darkslategray", 0x2f4f4fu },
	{ "darkslategrey", 0x2f4f4fu },
	{ "darkturquoise", 0x00ced1u },
	{ "darkviolet", 0x9400d3u },
	{ "deeppink", 0xff1493u },
	{ "deepskyblue", 0x00bfffu },
	{ "dimgray", 0x696969u },
	{ "dimgrey", 0x696969u },
	{ "dodgerblue", 0x1e90ffu },
	{ "firebrick", 0xb22222u },
	{ "floralwhite", 0xfffaf0u },
	{ "forestgreen", 0x228b22u },
	{ "fuchsia", 0xff00ffu },
	{ "gainsboro", 0xdcdcdcu },
	{ "ghostwhite", 0xf8f8ffu },
	{ "gold", 0xffd700u },
	{ "goldenrod", 0xdaa520u },
	{ "gray", 0x808080u },
	{ "green", 0x008000u },
	{ "greenyellow", 0xadff2fu },
	{ "grey", 0x808080u },
	{ "honeydew", 0xf0fff0u },
	{ "hotpink", 0xff69b4u },
	{ "indianred", 0xcd5c5cu },
	{ "indigo", 0x4b0082u },
	{ "ivory", 0xfffff0u },
	{ "khaki", 0xf0e68cu },
	{ "lavender", 0xe6e6fau },
	{ "lavenderblush", 0xfff0f5u },
	{ "lawngreen", 0x7cfc00u },
	{ "lemonchiffon", 0xfffacdu },
	{ "lightblue", 0xadd8e6u },
	{ "lightcoral", 0xf08080u },
	{ "lightcyan", 0xe0ffffu },
	{ "lightgoldenrodyellow", 0xfafad2u },
	{ "lightgray", 0xd3d3d3u },
	{ "lightgreen", 0x90ee90u },
	{ "lightgrey", 0xd3d3d3u },
	{ "lightpink", 0xffb6c1u },
	{ "lightsalmon", 0xffa07au },
	{ "lightseagreen", 0x20b2aau },
	{ "lightskyblue", 0x87cefau },
	{ "lightslategray", 0x778899u },
	{ "lightslategrey", 0x778899u },
	{ "lightsteelblue", 0xb0c4deu },
	{ "lightyellow", 0xffffe0u },
	{ "lime", 0x00ff00u },
	{ "limegreen", 0x32cd32u },
	{ "linen", 0xfaf0e6u },
	{ "magenta", 0xff00ffu },
	{ "maroon", 0x800000u },
	{ "mediumaquamarine", 0x66cdaau },
	{ "mediumblue", 0x0000cdu },
	{ "mediumorchid", 0xba55d3u },
	{ "mediumpurple", 0x9370dbu },
	{ "mediumseagreen", 0x3cb371u },
	{ "mediumslateblue", 0x7b68eeu },
	{ "mediumspringgreen", 0x00fa9au },
	{ "mediumturquoise", 0x48d1ccu },
	{ "mediumvioletred", 0xc71585u },
	{ "midnightblue", 0x191970u },
	{ "mintcream", 0xf5fffau },
	{ "mistyrose", 0xffe4e1u },
	{ "moccasin", 0xffe4b5u },
	{ "navajowhite", 0xffdeadu },
	{ "navy", 0x000080u },
	{ "oldlace", 0xfdf5e6u },
	{ "olive", 0x808000u },
	{ "olivedrab", 0x6b8e23u },
	{ "orange", 0xffa500u },
	{ "orangered", 0xff4500u },
	{ "orchid", 0xda70d6u },
	{ "palegoldenrod", 0xeee8aau },
	{ "palegreen", 0x98fb98u },
	{ "paleturquoise", 0xafeeeeu },
	{ "palevioletred", 0xdb7093u },
	{ "papayawhip", 0xffefd5u },
	{ "peachpuff", 0xffdab9u },
	{ "peru", 0xcd853fu },
	{ "pink", 0xffc0cbu },
	{ "plum", 0xdda0ddu },
	{ "powderblue", 0xb0e0e6u },
	{ "purple", 0x800080u },
	{ "rebeccapurple", 0x663399u },
	{ "red", 0xff0000u },
	{ "rosybrown", 0xbc8f8fu },
	{ "royalblue", 0x4169e1u },
	{ "saddlebrown", 0x8b4513u },
	{ "salmon", 0xfa8072u },
	{ "sandybrown", 0xf4a460u },
	{ "seagreen", 0x2e8b57u },
	{ "seashell", 0xfff5eeu },
	{ "sienna", 0xa0522du },
	{ "silver", 0xc0c0c0u },
	{ "skyblue", 0x87ceebu },
	{ "slateblue", 0x6a5acdu },
	{ "slategray", 0x708090u },
	{ "slategrey", 0x708090u },
	{ "snow", 0xfffafau },
	{ "springgreen", 0x00ff7fu },
	{ "steelblue", 0x4682b4u },
	{ "tan", 0xd2b48cu },
	{ "teal", 0x008080u },
	{ "thistle", 0xd8bfd8u },
	{ "tomato", 0xff6347u },
	{ "turquoise", 0x40e0d0u },
	{ "violet", 0xee82eeu },
	{ "wheat", 0xf5deb3u },
	{ "white", 0xffffffu },
	{ "whitesmoke", 0xf5f5f5u },
	{ "yellow", 0xffff00u },
	{ "yellowgreen", 0x9acd32u },
};
static const int NAMED_N = 148;

// 名前から色を探す。無ければ false。
inline bool named_color(const godot::String &name, godot::Color &out) {
	godot::CharString cs = name.to_lower().utf8();
	const char *k = cs.get_data();
	int lo = 0, hi = NAMED_N - 1;
	while (lo <= hi) {
		int mid = (lo + hi) / 2;
		int c = std::strcmp(k, NAMED[mid].name);
		if (c == 0) {
			uint32_t v = NAMED[mid].rgb;
			out = godot::Color((float)((v >> 16) & 0xff) / 255.0f,
					(float)((v >> 8) & 0xff) / 255.0f, (float)(v & 0xff) / 255.0f, 1.0f);
			return true;
		}
		if (c < 0) hi = mid - 1;
		else lo = mid + 1;
	}
	return false;
}

// 「rgb(...)」の中の 1 つぶんを読む。% が付いていれば割合として読む。
inline double chan(const godot::String &s, double full) {
	godot::String t = s.strip_edges();
	if (t.ends_with("%")) return t.substr(0, t.length() - 1).to_float() * 0.01 * full;
	return t.to_float();
}

// 色の書きかたを色に直す。読めなければ false を返して、呼ぶ側に決めてもらう。
// 読めない色を黒として描くと、書き間違いが「黒い形」として絵に残る。
inline bool parse_color(const godot::String &raw, godot::Color &out) {
	godot::String s = raw.strip_edges();
	if (s.is_empty()) return false;
	if (s.begins_with("#")) {
		godot::String h = s.substr(1);
		// 3 桁と 4 桁は 1 文字を 2 文字ぶんに伸ばす
		if (h.length() == 3 || h.length() == 4) {
			godot::String w;
			for (int i = 0; i < h.length(); i++)
				w += godot::String::chr(h[i]) + godot::String::chr(h[i]);
			h = w;
		}
		if (h.length() != 6 && h.length() != 8) return false;
		int64_t v = h.hex_to_int();
		if (h.length() == 6) {
			out = godot::Color((float)((v >> 16) & 0xff) / 255.0f,
					(float)((v >> 8) & 0xff) / 255.0f, (float)(v & 0xff) / 255.0f, 1.0f);
		} else {
			out = godot::Color((float)((v >> 24) & 0xff) / 255.0f,
					(float)((v >> 16) & 0xff) / 255.0f, (float)((v >> 8) & 0xff) / 255.0f,
					(float)(v & 0xff) / 255.0f);
		}
		return true;
	}
	godot::String low = s.to_lower();
	if (low.begins_with("rgb")) {
		int lp = low.find("(");
		int rp = low.rfind(")");
		if (lp < 0 || rp < lp) return false;
		// 点で区切る古い書きかたと、空白で区切る新しい書きかたの両方を読む。
		// 新しいほうは薄さを / で分ける（CSS Color 4）
		godot::String inner = low.substr(lp + 1, rp - lp - 1).replace("/", " ").replace(",", " ");
		godot::PackedStringArray parts = inner.split(" ", false);
		if (parts.size() < 3) return false;
		out = godot::Color((float)std::clamp(chan(parts[0], 255.0) / 255.0, 0.0, 1.0),
				(float)std::clamp(chan(parts[1], 255.0) / 255.0, 0.0, 1.0),
				(float)std::clamp(chan(parts[2], 255.0) / 255.0, 0.0, 1.0),
				parts.size() > 3 ? (float)std::clamp(chan(parts[3], 1.0), 0.0, 1.0) : 1.0f);
		return true;
	}
	return named_color(low, out);
}

// --- 色の移り変わり ---

// 移り変わりの区切り。どのあたりで何色になるか。
struct Stop {
	double at = 0.0;
	godot::Color col;
};

// 端まで行ったあとの続けかた。SVG の spreadMethod と同じ並び。
enum Spread { SPREAD_PAD = 0, SPREAD_REFLECT = 1, SPREAD_REPEAT = 2 };

// 塗るもの。単色か、まっすぐな移り変わりか、丸い移り変わりか。
struct Paint {
	enum Kind { NONE = 0, SOLID = 1, LINEAR = 2, RADIAL = 3 };
	Kind kind = NONE;
	godot::Color col;                 // 単色のとき
	godot::Transform2D inv;           // 画面の座標 → 移り変わりを決める座標
	double x1 = 0, y1 = 0, x2 = 1, y2 = 0;          // まっすぐなとき
	double cx = 0.5, cy = 0.5, r = 0.5, fx = 0.5, fy = 0.5;   // 丸いとき
	Spread spread = SPREAD_PAD;
	double opacity = 1.0;             // fill-opacity / stroke-opacity
	// 0〜1 を等間隔に割った色の表。画素ごとに区切りを探し直さずに済ませるため。
	// Skia も同じように、先に表を作ってから引いている。
	// 表そのものではなく指し先で持つ。同じ移り変わりで形をいくつも塗るとき、
	// 表は 1 つで足りる
	std::shared_ptr<const std::vector<godot::Color>> lut;
};

static const int LUT_N = 512;   // 色の表の目の数。512 あれば 8 bit の色で段差が出ない

// 区切りの並びから、その位置の色を出す。
inline godot::Color stop_at(const std::vector<Stop> &st, double t) {
	if (st.empty()) return godot::Color(0, 0, 0, 0);
	if (t <= st.front().at) return st.front().col;
	if (t >= st.back().at) return st.back().col;
	for (size_t i = 1; i < st.size(); i++) {
		if (t > st[i].at) continue;
		double span = st[i].at - st[i - 1].at;
		if (span <= 1e-12) return st[i].col;
		double f = (t - st[i - 1].at) / span;
		const godot::Color &a = st[i - 1].col, &b = st[i].col;
		return godot::Color((float)(a.r + (b.r - a.r) * f), (float)(a.g + (b.g - a.g) * f),
				(float)(a.b + (b.b - a.b) * f), (float)(a.a + (b.a - a.a) * f));
	}
	return st.back().col;
}

// 色の表を作る。区切りが決まったあと、一度通す。
inline std::shared_ptr<const std::vector<godot::Color>> build_lut(const std::vector<Stop> &st) {
	auto out = std::make_shared<std::vector<godot::Color>>((size_t)LUT_N);
	for (int i = 0; i < LUT_N; i++)
		(*out)[(size_t)i] = stop_at(st, (double)i / (double)(LUT_N - 1));
	return out;
}

// 端まで行ったあとの続けかたを当てはめる。
inline double spread_at(double t, Spread s) {
	if (s == SPREAD_PAD) return std::clamp(t, 0.0, 1.0);
	if (s == SPREAD_REPEAT) {
		double v = std::fmod(t, 1.0);
		return v < 0.0 ? v + 1.0 : v;
	}
	double v = std::fmod(std::abs(t), 2.0);
	return v <= 1.0 ? v : 2.0 - v;
}

// 色の移り変わりに混ぜる、ごく細かいばらつき。
// Chromium は移り変わりを塗るとき必ずこれを混ぜる（Skia の dither）。
// 8x8 の決まった型で ±0.49/255 ほど色をずらすもので、混ぜないと、
// 色の変わりめに階段が見えるところが向こうと食い違う。
inline double dither_at(int x, int y) {
	int yy = y ^ x;
	int m = ((yy & 1) << 5) | ((x & 1) << 4) | ((yy & 2) << 2) | ((x & 2) << 1)
			| ((yy & 4) >> 1) | ((x & 4) >> 2);
	return (double)m * (2.0 / 128.0) - 63.0 / 128.0;
}

inline godot::Color paint_at_q(const Paint &p, double qx, double qy, int px, int py);

// 画面のその場所で塗る色。掛け合わせる前の色を返す。
inline godot::Color paint_at(const Paint &p, double x, double y) {
	if (p.kind == Paint::SOLID) {
		godot::Color c = p.col;
		c.a = (float)(c.a * p.opacity);
		return c;
	}
	godot::Vector2 q = p.inv.xform(godot::Vector2((float)x, (float)y));
	return paint_at_q(p, q.x, q.y, (int)std::floor(x), (int)std::floor(y));
}

// 移り変わりを決める座標が分かっているときの色。画素ごとに変形を掛け直さずに済む。
inline godot::Color paint_at_q(const Paint &p, double qx, double qy, int px, int py) {
	godot::Vector2 q((float)qx, (float)qy);
	double t = 0.0;
	if (p.kind == Paint::LINEAR) {
		double dx = p.x2 - p.x1, dy = p.y2 - p.y1;
		double den = dx * dx + dy * dy;
		if (den <= 1e-12) t = 1.0;   // 長さが無いときは終わりの色で塗る決まり
		else t = ((q.x - p.x1) * dx + (q.y - p.y1) * dy) / den;
	} else {
		// 焦点から見て、その向きで円のふちまで行くうちのどこにいるか
		double dx = q.x - p.fx, dy = q.y - p.fy;
		double fcx = p.fx - p.cx, fcy = p.fy - p.cy;
		double a = dx * dx + dy * dy;
		if (a <= 1e-18 || p.r <= 1e-12) {
			t = 0.0;
		} else {
			double b = 2.0 * (dx * fcx + dy * fcy);
			double c = fcx * fcx + fcy * fcy - p.r * p.r;
			double disc = b * b - 4.0 * a * c;
			if (disc < 0.0) disc = 0.0;
			double s = (-b + std::sqrt(disc)) / (2.0 * a);
			t = s > 1e-12 ? 1.0 / s : 1.0;
		}
	}
	double u = spread_at(t, p.spread);
	godot::Color c = (*p.lut)[(size_t)std::clamp((int)(u * (LUT_N - 1) + 0.5), 0, LUT_N - 1)];
	// 薄さは表に焼き込まない。表は移り変わりごとに 1 つで、薄さは札ごとに変わる
	c.a = (float)(c.a * p.opacity);
	// ばらつきを混ぜる。混ぜる先は掛け合わせる前の色でよい（塗りはほぼ透けないため）
	double d = dither_at(px, py) / 255.0;
	c.r = (float)std::clamp((double)c.r + d, 0.0, 1.0);
	c.g = (float)std::clamp((double)c.g + d, 0.0, 1.0);
	c.b = (float)std::clamp((double)c.b + d, 0.0, 1.0);
	return c;
}

} // namespace svg
} // namespace svg2d

#endif // SVG2D_SVG_PAINT_H

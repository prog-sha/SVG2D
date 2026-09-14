// svg.h の読み取りと組み立てを実装する。
// 責務: 札を上から順にたどり、受け継ぐ見た目と変形を重ねながら、形を覆いに変えて色を乗せること。
// 設計思想: 受け継ぐもの（塗り・線・破線）と、その札固有のもの（薄さ・切り抜き）を
// はっきり分ける。SVG はこの 2 つが混ざると、入れ子の深い絵で色が合わなくなる。
#include "svg.h"

#include "cache.h"

#include "svg/geom.h"
#include "svg/paint.h"
#include "svg/raster.h"

#include <godot_cpp/classes/camera3d.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/resource_uid.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/xml_parser.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/memory.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>

#if !defined(SVG2D_SCALAR) && (defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64))
#define SVG2D_SSE2
#include <emmintrin.h>
#elif !defined(SVG2D_SCALAR) && defined(__aarch64__) && defined(__ARM_NEON)
#define SVG2D_NEON
#include <arm_neon.h>
#endif

using namespace godot;
using namespace svg2d::svg;

namespace svg2d {

// 曲線を折れ線に開くときに許す食い違い（画面の画素）。
// Skia が塗りで使う細かさ（1/16 画素ほど）に合わせてある。粗いと、丸みの縁が
// 内がわへ寄って、絵が少しやせて出る。
// これ以上細かくしても絵は良くならない。8 倍で焼いて縮めた真値と比べると、
// この細かさで Chromium より真値に近い（曲線中心の絵で 0.96 と 2.06）
static const double FLAT = 0.05;

// --- 読みかたの小道具 ---

// 空白と点でつながった数の並びを読む。SVG は「10,20 30 40」も「10-20」も同じ意味。
static std::vector<double> numbers(const String &s) {
	std::vector<double> out;
	CharString cs = s.utf8();
	const char *p = cs.get_data();
	while (*p) {
		while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
		if (!*p) break;
		char *end = nullptr;
		double v = std::strtod(p, &end);
		if (end == p) break;
		out.push_back(v);
		p = end;
	}
	return out;
}

// 長さを読む。単位が付いていても、画面の座標として読む（px と同じ扱い）。
// 割合は base に対する割合。SVG 1.1 7.10 のとおり、横向きの長さは viewport の幅、
// 縦向きは高さ、向きの無いもの（半径や線の太さ）は対角に対する割合になる。
// base に 1 を渡せば「0〜1 の数」として読む（色の移り変わりの座標と、薄さがこれ）。
// 長さの単位。画素に直す割合。CSS の決まりで 1 インチ = 96 画素
static const struct { const char *tag; double px; } UNITS[] = {
	{ "px", 1.0 }, { "pt", 96.0 / 72.0 }, { "pc", 16.0 }, { "mm", 96.0 / 25.4 },
	{ "cm", 96.0 / 2.54 }, { "in", 96.0 }, { "Q", 96.0 / 25.4 / 4.0 },
};

static double length_of(const String &t, double def, double base) {
	if (t.is_empty()) return def;
	double v;
	if (t.ends_with("%")) {
		v = t.substr(0, t.length() - 1).to_float() * 0.01 * base;
	} else {
		v = (double)t.to_float();
		for (const auto &u : UNITS)
			if (t.ends_with(u.tag)) {
				v *= u.px;
				break;
			}
	}
	// 読めない値や、けたが外れた値は既定に落とす。そのまま通すと、
	// あとで整数に直すところで何が起きるか決まっていない
	return std::isfinite(v) ? v : def;
}

// style="a:b;c:d" を分けて持つ。
// style="fill:red;stroke:none" を、ふつうの決めごとと同じ棚へ溶かす。
// 読み取りのときに 1 度やる。引くたびに読み直すと、札 1 つで 20 回読み直すことになる。
// style のほうが強いので、上書きで正しい（CSS の決まりと同じ）
static void melt_style(std::unordered_map<std::string, String> &attr, const String &s) {
	for (const String &one : s.split(";", false)) {
		int c = one.find(":");
		if (c < 0) continue;
		attr[std::string(one.substr(0, c).strip_edges().utf8().get_data())] =
				one.substr(c + 1).strip_edges();
	}
}

// 札からその決めごとを読む。style= のほうが、じかに書いた決めごとより強い。
static const String &attr_of(const SVG::Elem &e, const char *name) {
	static const String NONE;
	auto it = e.attr.find(name);
	return it == e.attr.end() ? NONE : it->second;
}

// <style> に書いた 1 つぶんの決まり。selector { 中身 } の形。
// 見るのは「札の名前・.組・#名札」まで。入れ子で指す書きかたは見ない
struct Rule {
	std::string tag;
	String cls, id;
	int rank = 0;   // 強さ。#名札 100・.組 10・札の名前 1（CSS の決まり）
	String body;
};

// selector を 1 つ読む。読めなければ false（見ない書きかた）。
static bool read_sel(const String &raw, Rule &r) {
	String s = raw.strip_edges();
	if (s.is_empty() || s.find(" ") >= 0 || s.find(">") >= 0 || s.find(":") >= 0
			|| s.find("[") >= 0)
		return false;
	if (s == "*") return true;
	int c = s.find(".");
	int h = s.find("#");
	int cut = c >= 0 ? c : h;
	if (cut != 0) {
		r.tag = std::string((cut < 0 ? s : s.substr(0, cut)).utf8().get_data());
		r.rank += 1;
	}
	if (c >= 0) {
		int end = h > c ? h : s.length();
		r.cls = s.substr(c + 1, end - c - 1);
		r.rank += 10;
		if (r.cls.is_empty()) return false;
	}
	if (h >= 0) {
		int end = c > h ? c : s.length();
		r.id = s.substr(h + 1, end - h - 1);
		r.rank += 100;
		if (r.id.is_empty()) return false;
	}
	return true;
}

// 木の中の <style> をぜんぶ読んで、決まりを集める。
static void read_css(const SVG::Elem &e, std::vector<Rule> &out) {
	if (e.tag == "style") {
		String t = e.text;
		// 注釈を外す。中に { } があると区切りを取り違える
		for (int a = t.find("/*"); a >= 0; a = t.find("/*")) {
			int b = t.find("*/", a);
			t = t.substr(0, a) + (b < 0 ? String() : t.substr(b + 2));
		}
		int at = 0;
		while (true) {
			int open = t.find("{", at);
			if (open < 0) break;
			int close = t.find("}", open);
			if (close < 0) break;
			String sels = t.substr(at, open - at);
			String body = t.substr(open + 1, close - open - 1);
			for (const String &one : sels.split(",", false)) {
				Rule r;
				r.body = body;
				if (read_sel(one, r)) out.push_back(r);
			}
			at = close + 1;
		}
	}
	for (const auto &k : e.kids) read_css(*k, out);
}

// 決まりと style="" を、ふつうの決めごとと同じ棚へ溶かす。
// 読み取りのときに 1 度やる。強さの順は 札の決めごと → <style> → style=""
static void dress(SVG::Elem &e, const std::vector<Rule> &rules) {
	// 前後の空きは読み取り時に一度落とす。使うたびに落とすと、
	// 長さや色を読むたびに字を写し直すことになる
	for (auto &kv : e.attr) kv.second = kv.second.strip_edges();
	if (!rules.empty()) {
		const String &id = attr_of(e, "id");
		PackedStringArray cls = attr_of(e, "class").split(" ", false);
		for (const Rule &r : rules) {
			if (!r.tag.empty() && r.tag != e.tag) continue;
			if (!r.id.is_empty() && r.id != id) continue;
			if (!r.cls.is_empty() && cls.find(r.cls) < 0) continue;
			melt_style(e.attr, r.body);
		}
	}
	{
		const String &own = attr_of(e, "style");
		if (!own.is_empty()) melt_style(e.attr, own);
	}
	for (const auto &k : e.kids) dress(*k, rules);
}

// 指し先。新しい書きかたが無ければ古い xlink: のほうを見る。
static const String &href_of(const SVG::Elem &e) {
	const String &v = attr_of(e, "href");
	return v.is_empty() ? attr_of(e, "xlink:href") : v;
}

// 変形の指図を読む。translate / scale / rotate / skewX / skewY / matrix を左から重ねる。
static Transform2D transform_of(const String &s) {
	Transform2D m;
	int i = 0;
	while (i < s.length()) {
		int lp = s.find("(", i);
		if (lp < 0) break;
		int rp = s.find(")", lp);
		if (rp < 0) break;
		String name = s.substr(i, lp - i).strip_edges();
		// 前の指図との区切りに残る点や空白を落とす
		while (!name.is_empty() && (name[0] == ',' || name[0] == ' ')) name = name.substr(1);
		std::vector<double> v = numbers(s.substr(lp + 1, rp - lp - 1));
		Transform2D t;
		if (name == "translate" && v.size() >= 1) {
			t.set_origin(Vector2((float)v[0], (float)(v.size() > 1 ? v[1] : 0.0)));
		} else if (name == "scale" && v.size() >= 1) {
			double sy = v.size() > 1 ? v[1] : v[0];
			t = Transform2D((float)v[0], 0, 0, (float)sy, 0, 0);
		} else if (name == "rotate" && v.size() >= 1) {
			double a = v[0] * Math::PI / 180.0;
			Transform2D r((float)std::cos(a), (float)std::sin(a), (float)-std::sin(a),
					(float)std::cos(a), 0, 0);
			if (v.size() >= 3) {
				Transform2D to, back;
				to.set_origin(Vector2((float)v[1], (float)v[2]));
				back.set_origin(Vector2((float)-v[1], (float)-v[2]));
				t = to * r * back;
			} else {
				t = r;
			}
		} else if (name == "skewx" || name == "skewX") {
			if (!v.empty()) t = Transform2D(1, 0, (float)std::tan(v[0] * Math::PI / 180.0), 1, 0, 0);
		} else if (name == "skewy" || name == "skewY") {
			if (!v.empty()) t = Transform2D(1, (float)std::tan(v[0] * Math::PI / 180.0), 0, 1, 0, 0);
		} else if (name == "matrix" && v.size() >= 6) {
			t = Transform2D((float)v[0], (float)v[1], (float)v[2], (float)v[3], (float)v[4],
					(float)v[5]);
		}
		m = m * t;
		i = rp + 1;
	}
	return m;
}

// --- 道（path）の指図を折れ線に開く ---
// 大文字はそのままの場所、小文字はいまの場所からの動き。
// S と T は、1 つ前の control 点をいまの点で折り返して使う。
static Path parse_path(const String &d, double tol) {
	Path out;
	Sub cur;
	Vector2 at(0, 0), start(0, 0), c_prev(0, 0), q_prev(0, 0);
	char last = 0;
	CharString cs = d.utf8();
	const char *p = cs.get_data();
	// ひと続きを 1 本ぶんとして納める。点が 1 つのものは、閉じた場合に残す。
	// 「M 単独」は何も描かない決まり、「M のあと Z」は端の形で点を打つ決まり。
	// 閉じていない 1 点を残すと、Z の次に M が来たときに余計な点が打たれる
	auto flush = [&](bool closed) {
		if (cur.p.size() >= 2 || (closed && cur.p.size() == 1)) {
			cur.closed = closed;
			out.push_back(cur);
		}
		cur.p.clear();
	};
	auto take = [&](int n) {
		std::vector<double> v;
		for (int i = 0; i < n; i++) {
			while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
			char *end = nullptr;
			double x = std::strtod(p, &end);
			if (end == p) return std::vector<double>();
			v.push_back(x);
			p = end;
		}
		return v;
	};
	// 円弧の 4 つ目と 5 つ目は 0 か 1 の 1 文字で、続けて書かれることがある
	auto take_flag = [&]() -> int {
		while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
		if (*p == '0' || *p == '1') return *p++ - '0';
		return -1;
	};
	while (*p) {
		while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n' || *p == '\r')) p++;
		if (!*p) break;
		char cmd = *p;
		if (std::isalpha((unsigned char)cmd)) {
			p++;
		} else {
			// 指図が省かれたときは前のものを繰り返す。M のあとは L 扱い
			cmd = last == 'M' ? 'L' : (last == 'm' ? 'l' : last);
			if (!cmd) break;
		}
		bool rel = std::islower((unsigned char)cmd);
		char up = (char)std::toupper((unsigned char)cmd);
		Vector2 base = rel ? at : Vector2(0, 0);
		if (up == 'M') {
			std::vector<double> v = take(2);
			if (v.size() < 2) break;
			flush(false);
			at = base + Vector2((float)v[0], (float)v[1]);
			start = at;
			cur.p.push_back(at);
		} else if (up == 'L') {
			std::vector<double> v = take(2);
			if (v.size() < 2) break;
			at = base + Vector2((float)v[0], (float)v[1]);
			cur.p.push_back(at);
		} else if (up == 'H') {
			std::vector<double> v = take(1);
			if (v.empty()) break;
			at.x = (float)(rel ? at.x + v[0] : v[0]);
			cur.p.push_back(at);
		} else if (up == 'V') {
			std::vector<double> v = take(1);
			if (v.empty()) break;
			at.y = (float)(rel ? at.y + v[0] : v[0]);
			cur.p.push_back(at);
		} else if (up == 'C' || up == 'S') {
			std::vector<double> v = take(up == 'C' ? 6 : 4);
			if (v.size() < (size_t)(up == 'C' ? 6 : 4)) break;
			Vector2 c1, c2, e;
			if (up == 'C') {
				c1 = base + Vector2((float)v[0], (float)v[1]);
				c2 = base + Vector2((float)v[2], (float)v[3]);
				e = base + Vector2((float)v[4], (float)v[5]);
			} else {
				char pl = (char)std::toupper((unsigned char)last);
				c1 = (pl == 'C' || pl == 'S') ? at * 2.0f - c_prev : at;
				c2 = base + Vector2((float)v[0], (float)v[1]);
				e = base + Vector2((float)v[2], (float)v[3]);
			}
			if (cur.p.empty()) cur.p.push_back(at);
			add_cubic(cur.p, at, c1, c2, e, tol);
			c_prev = c2;
			at = e;
		} else if (up == 'Q' || up == 'T') {
			std::vector<double> v = take(up == 'Q' ? 4 : 2);
			if (v.size() < (size_t)(up == 'Q' ? 4 : 2)) break;
			Vector2 c1, e;
			if (up == 'Q') {
				c1 = base + Vector2((float)v[0], (float)v[1]);
				e = base + Vector2((float)v[2], (float)v[3]);
			} else {
				char pl = (char)std::toupper((unsigned char)last);
				c1 = (pl == 'Q' || pl == 'T') ? at * 2.0f - q_prev : at;
				e = base + Vector2((float)v[0], (float)v[1]);
			}
			if (cur.p.empty()) cur.p.push_back(at);
			add_quad(cur.p, at, c1, e, tol);
			q_prev = c1;
			at = e;
		} else if (up == 'A') {
			std::vector<double> r = take(3);
			if (r.size() < 3) break;
			int fa = take_flag(), fs = take_flag();
			if (fa < 0 || fs < 0) break;
			std::vector<double> v = take(2);
			if (v.size() < 2) break;
			Vector2 e = base + Vector2((float)v[0], (float)v[1]);
			if (cur.p.empty()) cur.p.push_back(at);
			add_arc(cur.p, at, r[0], r[1], r[2] * Math::PI / 180.0, fa != 0, fs != 0, e, tol);
			at = e;
		} else if (up == 'Z') {
			flush(true);
			at = start;
			cur.p.push_back(at);
		} else {
			break;
		}
		last = cmd;
	}
	flush(false);
	return out;
}

// 受け継ぐ見た目。SVG では塗りと線は下の札へ受け継がれ、薄さと切り抜きは受け継がれない。
struct State {
	Transform2D m;
	String fill = "black";
	String stroke = "none";
	double fill_op = 1.0, stroke_op = 1.0;
	double width = 1.0;
	Cap cap = CAP_BUTT;
	Join join = JOIN_MITER;
	double miter = 4.0;
	std::vector<double> dash;
	double dash_off = 0.0;
	bool fill_evenodd = false;
	bool clip_evenodd = false;
	Color current = Color(0, 0, 0, 1);   // currentColor が指す色
	// いまの viewport の広さ（元の座標）。割合の長さはここに対する割合になる
	double vw = 0.0, vh = 0.0;
	// 横向き・縦向き・向きの無い長さの、割合のときの基準
	double bx() const { return vw; }
	double by() const { return vh; }
	double bd() const { return std::sqrt((vw * vw + vh * vh) * 0.5); }
};

// --- 形を作る ---

// 四角。角を丸める指定があれば、四すみを楕円の弧にする。
static Path rect_path(const SVG::Elem &e, double tol, const State &st) {
	double x = length_of(attr_of(e, "x"), 0, st.bx()), y = length_of(attr_of(e, "y"), 0, st.by());
	double w = length_of(attr_of(e, "width"), 0, st.bx());
	double h = length_of(attr_of(e, "height"), 0, st.by());
	if (w <= 0.0 || h <= 0.0) return Path();
	String rxs = attr_of(e, "rx"), rys = attr_of(e, "ry");
	// 片方しか書いていなければ、もう片方も同じにする決まり
	double rx = rxs.is_empty() ? -1.0 : length_of(rxs, 0, st.bx());
	double ry = rys.is_empty() ? -1.0 : length_of(rys, 0, st.by());
	if (rx < 0.0 && ry < 0.0) { rx = ry = 0.0; }
	else if (rx < 0.0) rx = ry;
	else if (ry < 0.0) ry = rx;
	rx = std::min(std::max(rx, 0.0), w * 0.5);
	ry = std::min(std::max(ry, 0.0), h * 0.5);
	Sub s;
	s.closed = true;
	if (rx <= 0.0 || ry <= 0.0) {
		s.p.push_back(Vector2((float)x, (float)y));
		s.p.push_back(Vector2((float)(x + w), (float)y));
		s.p.push_back(Vector2((float)(x + w), (float)(y + h)));
		s.p.push_back(Vector2((float)x, (float)(y + h)));
		return { s };
	}
	// 四すみは 4 分の 1 の楕円。中心と、始めの角度を渡してなぞる
	int n = arc_n(std::max(rx, ry), Math::PI * 0.5, tol, 2, 180);
	auto corner = [&](double ox, double oy, double a0) {
		for (int i = 0; i <= n; i++) {
			double a = a0 + Math::PI * 0.5 * ((double)i / (double)n);
			s.p.push_back(Vector2((float)(ox + rx * std::cos(a)), (float)(oy + ry * std::sin(a))));
		}
	};
	corner(x + w - rx, y + ry, -Math::PI * 0.5);          // 右上
	corner(x + w - rx, y + h - ry, 0.0);                  // 右下
	corner(x + rx, y + h - ry, Math::PI * 0.5);           // 左下
	corner(x + rx, y + ry, Math::PI);                     // 左上
	return { s };
}

// 楕円（丸も同じ道を通る）。
static Path ellipse_path(double cx, double cy, double rx, double ry, double tol) {
	if (rx <= 0.0 || ry <= 0.0) return Path();
	Sub s;
	s.closed = true;
	int n = arc_n(std::max(rx, ry), Math::TAU, tol, 8, 720);
	for (int i = 0; i < n; i++) {
		double a = Math::TAU * ((double)i / (double)n);
		s.p.push_back(Vector2((float)(cx + rx * std::cos(a)), (float)(cy + ry * std::sin(a))));
	}
	return { s };
}

// 折れ線と多角形。
static Path points_path(const String &s, bool closed) {
	std::vector<double> v = numbers(s);
	Sub sub;
	sub.closed = closed;
	for (size_t i = 0; i + 1 < v.size(); i += 2)
		sub.p.push_back(Vector2((float)v[i], (float)v[i + 1]));
	if (sub.p.size() < 2) return Path();
	return { sub };
}

// --- 描くときに持ち回るもの ---

// 色の移り変わりの、札ごとに変わらないところ。
// 同じ移り変わりで 2000 個の形を塗ると、512 目の表をそのたびに作り直すことになる
struct GradHit {
	std::shared_ptr<const std::vector<Color>> lut;   // 空なら区切りが無い
	bool one = false;   // 区切りが 1 つしかない。べた塗りでよい
	Color col;
};

// 組んだ形。札の字を読んで折れ線に開いたもの。
// 毎コマ描くとき、ここを組み直すのがいちばん重い（札 1 つで 20 マイクロ秒ほど）
struct Built {
	Path fill;         // 塗る形
	Rect2 box;         // その形が入る四角（元の座標）
	Path ring;         // 線を塗りに直したもの
	Rect2 rbox;        // 線の形が入る四角（元の座標）
	uint64_t rkey = 0;   // 線の条件の鍵。太さや破線が変わったら組み直す
	bool ringed = false;
};

// 描くたびに変わらないものを控えておく入れ物。
// 3 つとも同じ仕組み（量で区切って、古いものから捨てる）で持つ。
struct SVG::Store {
	// 上限。1 枚の絵が抱えてよい量。毎コマ描くつもりなので、組み直すより抱えるほうが安い
	static const size_t GEO = 4 * 1024 * 1024;
	static const size_t GRAD = 1 * 1024 * 1024;
	static const size_t CLIP = 2 * 1024 * 1024;

	Cache<Built> geo{ GEO };
	Cache<GradHit> grad{ GRAD };
	Cache<std::shared_ptr<const Cover>> clip{ CLIP };
	Canvas cv;            // 描く先。大きさが同じなら取り直さず、触った所を 0 へ戻す
	// まとまりの薄さで使う紙。深さごとに使い回す。札ごとに作り直すと、
	// 800x800 で 2.5 MB を用意して 0 で埋めるのが、薄いまとまりの数に応じて起きる
	std::vector<std::unique_ptr<Canvas>> pool;
	int pw = 0, ph = 0;   // 紙の大きさ。変わったら作り直す
	uint64_t turn = 0;

	void begin(int w, int h) {
		turn++;
		geo.turn(turn);
		grad.turn(turn);
		clip.turn(turn);
		if (pw != w || ph != h) {
			pool.clear();
			cv.make(w, h);
			pw = w;
			ph = h;
		} else {
			cv.clear();
		}
	}
	size_t bytes() const {
		size_t n = geo.bytes() + grad.bytes() + clip.bytes() + cv.px.size();
		for (const auto &p : pool) n += p->px.size();
		return n;
	}
};

// 1 枚描くあいだ持ち回るもの。
struct Ctx {
	Canvas *cv = nullptr;
	const std::unordered_map<std::string, SVG::Elem *> *ids = nullptr;
	const SVG::Elem *root = nullptr;   // いちばん外の svg。入れ子の svg と見分けるのに使う
	SVG::Store *store = nullptr;
	// いま掛かっている切り抜き。空なら切り抜き無し。
	// 覆いそのものではなく指し先で持ち回る。大きな切り抜きを 200 個の札に掛けると、
	// 札ごとに 1.4 MB を写すことになる
	std::shared_ptr<const Cover> clip;
	Mask scratch;              // 覆いの入れ物。札ごとに取り直さず、いちばん要る大きさまで太らせて使い回す
	int lv = 0;                // いま使っている紙の深さ
	int depth = 0;             // 入れ子の深さ。輪になった指し先で止まらなくなるのを防ぐ
	int uses = 0;              // 使い回しをたどった深さ。輪になっていたらここで止まる
	double jitter = 0.0;       // 文書寸法に対する揺れ量
	int jitter_seed = 1;       // 1〜4だけを使う固定パターン
	Vector2 jitter_span;       // SVG座標で見た文書の縦横
};

// 形が抱えている量。
static size_t path_bytes(const Path &p) {
	size_t n = 0;
	for (const Sub &s : p) n += s.p.size() * sizeof(Vector2) + sizeof(Sub);
	return n;
}

// うごメモの線のような「沸き」を、毎回同じ4枚だけ作る。
// 時刻やOSの乱数は使わず、seed 1〜4と図形内座標だけから値を決めるため、再読込しても
// 同じ絵になり、焼いた4枚をそのまま循環利用できる。
// 閉じた輪郭は面積重心、開いた線は頂点平均を返す。
static Vector2 sub_center(const Sub &sub) {
	if (sub.closed && sub.p.size() >= 3) {
		double twice_area = 0.0, sx = 0.0, sy = 0.0;
		for (size_t i = 0; i < sub.p.size(); i++) {
			const Vector2 &a = sub.p[i];
			const Vector2 &b = sub.p[(i + 1) % sub.p.size()];
			double cross = (double)a.x * b.y - (double)b.x * a.y;
			twice_area += cross;
			sx += ((double)a.x + b.x) * cross;
			sy += ((double)a.y + b.y) * cross;
		}
		if (std::abs(twice_area) > 1e-9)
			return Vector2((float)(sx / (3.0 * twice_area)), (float)(sy / (3.0 * twice_area)));
	}
	Vector2 center;
	for (const Vector2 &point : sub.p) center += point;
	return sub.p.empty() ? center : center / (float)sub.p.size();
}

static Path jitter_path(const Path &path, const Ctx &c) {
	if (c.jitter <= 0.0) return path;
	Path out = path;
	Vector2 amount((float)(c.jitter_span.x * c.jitter),
			(float)(c.jitter_span.y * c.jitter));
	// 全体移動は加えず、中心を固定した輪郭変形だけを作る。座標反転に対して変位も
	// 反転する奇関数なので、円やドーナツのような点対称図形は重心が動かない。
	Rect2 box = path_box(path);
	Vector2 center = box.position + box.size * 0.5f;
	double bw = std::max((double)box.size.x, 1e-6);
	double bh = std::max((double)box.size.y, 1e-6);
	double phase = (double)(c.jitter_seed - 1) * Math::TAU * 0.25;
	for (size_t si = 0; si < out.size(); si++) {
		Vector2 fixed_center = sub_center(out[si]);
		for (size_t pi = 0; pi < out[si].p.size(); pi++) {
			const Vector2 &original = out[si].p[pi];
			// 中心から外向きの低周波波形で輪郭を膨張・収縮させる。4周波と6周波は
			// どちらも偶数なので、反対側の点は必ず逆向きに同量動き、中心は動かない。
			double x = ((double)original.x - center.x) / bw;
			double y = ((double)original.y - center.y) / bh;
			Vector2 radial((float)x, (float)y);
			if (radial.length_squared() <= 1e-12f) continue;
			radial.normalize();
			double angle = std::atan2(y, x);
			float wave = (float)(0.72 * std::sin(angle * 4.0 + phase) +
					0.28 * std::sin(angle * 6.0 - phase));
			out[si].p[pi].x += amount.x * 0.40f * wave * radial.x;
			out[si].p[pi].y += amount.y * 0.40f * wave * radial.y;
		}
		// 輪郭変形で生じた面積重心のずれを戻す。これはアニメ用の移動ではなく、
		// 元の位置を保つための補正で、外周と穴の各subpathへ別々に適用する。
		Vector2 correction = fixed_center - sub_center(out[si]);
		for (Vector2 &point : out[si].p) point += correction;
	}
	return out;
}

// id を指す書きかた（url(#name) や #name）から札を探す。
static SVG::Elem *find_ref(const Ctx &c, const String &raw) {
	String s = raw.strip_edges();
	if (s.begins_with("url(")) {
		int rp = s.rfind(")");
		s = s.substr(4, rp > 4 ? rp - 4 : s.length() - 4).strip_edges();
	}
	s = s.trim_prefix("\"").trim_suffix("\"").trim_prefix("'").trim_suffix("'");
	if (!s.begins_with("#")) return nullptr;
	auto it = c.ids->find(std::string(s.substr(1).utf8().get_data()));
	return it == c.ids->end() ? nullptr : it->second;
}

// 色の移り変わりの区切りを読む。href でつながっているときは、たどった先のものも使う。
static void read_stops(const Ctx &c, const SVG::Elem &e, std::vector<Stop> &out, int depth) {
	for (const auto &k : e.kids) {
		if (k->tag != "stop") continue;
		Stop s;
		s.at = std::clamp(length_of(attr_of(*k, "offset"), 0.0, 1.0), 0.0, 1.0);
		Color col(0, 0, 0, 1);
		parse_color(attr_of(*k, "stop-color"), col);
		String so = attr_of(*k, "stop-opacity");
		col.a = (float)(col.a
				* (so.is_empty() ? 1.0 : std::clamp(length_of(so, 1.0, 1.0), 0.0, 1.0)));
		s.col = col;
		if (!out.empty() && s.at < out.back().at) s.at = out.back().at;   // 戻る並びは前へそろえる
		out.push_back(s);
	}
	if (!out.empty() || depth > 4) return;
	String href = href_of(e);
	SVG::Elem *up = href.is_empty() ? nullptr : find_ref(c, href);
	if (up) read_stops(c, *up, out, depth + 1);
}

// つながった先も見て、決めごとを 1 つ読む。
static String grad_attr(const Ctx &c, const SVG::Elem &e, const char *name, int depth) {
	String v = attr_of(e, name);
	if (!v.is_empty() || depth > 4) return v;
	String href = href_of(e);
	SVG::Elem *up = href.is_empty() ? nullptr : find_ref(c, href);
	return up ? grad_attr(c, *up, name, depth + 1) : String();
}

// 色の移り変わりの表を用意する。同じ札のものは控えたものを返す。
static const GradHit &lut_of(Ctx &c, const SVG::Elem &g) {
	const void *ep = &g;
	uint64_t key = mix(SEED, &ep, sizeof(ep));
	GradHit *got = c.store->grad.find(key);
	if (got != nullptr) return *got;
	GradHit h;
	std::vector<Stop> st;
	read_stops(c, g, st, 0);
	if (!st.empty()) {
		// 最初と最後の区切りが端に無ければ、端まで同じ色を伸ばす（SVG の決まり）
		if (st.front().at > 0.0) {
			Stop one = st.front();
			one.at = 0.0;
			st.insert(st.begin(), one);
		}
		if (st.back().at < 1.0) {
			Stop one = st.back();
			one.at = 1.0;
			st.push_back(one);
		}
		if (st.size() == 1) {
			h.one = true;
			h.col = st[0].col;
		} else {
			h.lut = build_lut(st);
		}
	}
	size_t n = sizeof(GradHit) + (h.lut ? h.lut->size() * sizeof(Color) : 0);
	return c.store->grad.keep(key, std::move(h), n);
}

// 塗るものを決める。単色か、色の移り変わりか、塗らないか。
// box は、その形を囲む四角（元の座標）。objectBoundingBox の指定に使う。
static Paint make_paint(Ctx &c, const String &s, double opacity, const State &st,
		const Rect2 &box) {
	// 見比べる字は最初に作る。作り直すと、札ごとに 4 回ぶん字を組み立てることになる
	static const String NONE = "none", CUR = "currentColor", URL = "url(";
	Paint p;
	if (s.is_empty() || s == NONE) return p;
	p.opacity = std::clamp(opacity, 0.0, 1.0);
	if (s == CUR) {
		p.kind = Paint::SOLID;
		p.col = st.current;
		return p;
	}
	if (s.begins_with(URL)) {
		SVG::Elem *g = find_ref(c, s);
		if (g == nullptr) return p;
		bool linear = g->tag == "linearGradient";
		if (!linear && g->tag != "radialGradient") return p;
		const GradHit &gh = lut_of(c, *g);
		if (gh.one) {   // 区切りが 1 つしか無ければ、その色でべた塗り
			p.kind = Paint::SOLID;
			p.col = gh.col;
			return p;
		}
		if (gh.lut == nullptr) return p;
		p.lut = gh.lut;
		String sp = grad_attr(c, *g, "spreadMethod", 0);
		p.spread = sp == "reflect" ? SPREAD_REFLECT : (sp == "repeat" ? SPREAD_REPEAT : SPREAD_PAD);
		bool user = grad_attr(c, *g, "gradientUnits", 0) == "userSpaceOnUse";
		Transform2D gm = transform_of(grad_attr(c, *g, "gradientTransform", 0));
		// 色を決める座標 → 元の座標。objectBoundingBox のときは形を囲む四角が単位になる
		Transform2D to_user = gm;
		if (!user) {
			Transform2D bt(box.size.x, 0, 0, box.size.y, box.position.x, box.position.y);
			to_user = bt * gm;
		}
		p.inv = (st.m * to_user).affine_inverse();
		// 移り変わりの座標。囲み四角を単位にするときは 0〜1、元の座標で書くときは viewport
		double bw = user ? st.bx() : 1.0, bh = user ? st.by() : 1.0;
		double bd = user ? st.bd() : 1.0;
		auto num = [&](const char *k, double def, double base) {
			String v = grad_attr(c, *g, k, 0);
			return v.is_empty() ? def : length_of(v, def, base);
		};
		if (linear) {
			p.kind = Paint::LINEAR;
			p.x1 = num("x1", 0.0, bw); p.y1 = num("y1", 0.0, bh);
			p.x2 = num("x2", user ? bw : 1.0, bw); p.y2 = num("y2", 0.0, bh);
		} else {
			p.kind = Paint::RADIAL;
			p.cx = num("cx", 0.5 * bw, bw); p.cy = num("cy", 0.5 * bh, bh);
			p.r = num("r", 0.5 * bd, bd);
			String fxs = grad_attr(c, *g, "fx", 0), fys = grad_attr(c, *g, "fy", 0);
			p.fx = fxs.is_empty() ? p.cx : length_of(fxs, p.cx, bw);
			p.fy = fys.is_empty() ? p.cy : length_of(fys, p.cy, bh);
			// 焦点が円の外に出たら、円のふちのすぐ内がわへ寄せる（SVG 13.2.3）
			double dx = p.fx - p.cx, dy = p.fy - p.cy;
			double d = std::sqrt(dx * dx + dy * dy);
			if (d > p.r * 0.999 && d > 1e-12) {
				double k = p.r * 0.999 / d;
				p.fx = p.cx + dx * k;
				p.fy = p.cy + dy * k;
			}
		}
		return p;
	}
	Color col;
	if (!parse_color(s, col)) return p;
	p.kind = Paint::SOLID;
	p.col = col;
	return p;
}

// 覆いを画面へ乗せる。切り抜きがあれば、そのぶんを掛けてから乗せる。
static void paint_mask(Ctx &c, const Mask &mk, const Paint &p) {
	if (p.kind == Paint::NONE || mk.empty()) return;
	bool flat = p.kind == Paint::SOLID;
	Color solid = flat ? paint_at(p, 0, 0) : Color();
	// 移り変わりのときは、段の始めで一度変形を掛け、あとは横に足していく。
	// 画素ごとに変形を掛け直すと、その処理で塗りの半分ほどを使う
	Vector2 step = p.inv.columns[0];
	for (int y = 0; y < mk.h; y++) {
		int py = mk.y0 + y;
		if (py < 0 || py >= c.cv->h) continue;
		int x1 = std::min(mk.hi[(size_t)y] + 1, mk.w);
		int xs = std::max(mk.lo[(size_t)y], 0);
		if (xs >= x1) continue;
		const float *row = &mk.a[(size_t)y * (size_t)(mk.w + 2)];
		Vector2 q = flat ? Vector2()
						 : p.inv.xform(Vector2((float)(mk.x0 + xs) + 0.5f, (float)py + 0.5f));
		for (int x = xs; x < x1; x++, q += step) {
			double cov = row[x];
			if (cov <= 0.0009) continue;
			int px = mk.x0 + x;
			if (px < 0 || px >= c.cv->w) continue;
			if (c.clip) {
				cov *= c.clip->at(px, py);
				if (cov <= 0.0009) continue;
			}
			// 色は画素の真ん中で決める。Chromium も真ん中で拾っている
			c.cv->over(px, py, flat ? solid : paint_at_q(p, q.x, q.y, px, py), cov);
		}
	}
}

// 形を覆いにする。画面から出たぶんは切り落とす。
// box は、その形が入る四角（元の座標）。ここから入れ物の大きさを決めるので、
// 点をもう 1 周して四角を出し直さずに済む。回っているときは少し大きめに出るが、
// 大きめの入れ物は絵を変えない
static void rasterize(const Ctx &c, Mask &m, const Path &pa, const Rect2 &box,
		const Transform2D &at, bool even_odd) {
	m.drop();
	Rect2 b = at.xform(box);
	if (b.size.x < 0.0f || b.size.y < 0.0f) return;
	int x0 = std::max((int)std::floor(b.position.x) - 1, 0);
	int y0 = std::max((int)std::floor(b.position.y) - 1, 0);
	int x1 = std::min((int)std::ceil(b.position.x + b.size.x) + 1, c.cv->w);
	int y1 = std::min((int)std::ceil(b.position.y + b.size.y) + 1, c.cv->h);
	if (x1 <= x0 || y1 <= y0) return;
	m.make(x0, y0, x1 - x0, y1 - y0);
	mask_add(m, pa, at);
	mask_resolve(m, even_odd);
}

static Mask rasterize(const Ctx &c, const Path &pa, const Transform2D &at, bool even_odd) {
	Mask m;
	rasterize(c, m, pa, path_box(pa), at, even_odd);
	return m;
}

// viewBox を、出す大きさへ合わせる変形。preserveAspectRatio のとおりに寄せる。
// 入れ子の svg も同じ式を通る。
static Transform2D view_fit(const Rect2 &view, const String &par, double w, double h) {
	double sx = w / view.size.x, sy = h / view.size.y;
	PackedStringArray p = par.strip_edges().split(" ", false);
	String align = p.size() > 0 ? p[0] : String("xMidYMid");
	bool slice = p.size() > 1 && p[1] == "slice";
	if (align != "none") {
		double s = slice ? std::max(sx, sy) : std::min(sx, sy);
		sx = sy = s;
	}
	double tx = -view.position.x * sx, ty = -view.position.y * sy;
	double rest_x = w - view.size.x * sx, rest_y = h - view.size.y * sy;
	if (align.contains("xMid")) tx += rest_x * 0.5;
	else if (align.contains("xMax")) tx += rest_x;
	if (align.contains("YMid")) ty += rest_y * 0.5;
	else if (align.contains("YMax")) ty += rest_y;
	return Transform2D((float)sx, 0, 0, (float)sy, (float)tx, (float)ty);
}

// --- 札をたどる ---

static void draw_elem(Ctx &c, const SVG::Elem &e, State st);

// その札の中身をぜんぶ描く。
static void draw_kids(Ctx &c, const SVG::Elem &e, const State &st) {
	for (const auto &k : e.kids) draw_elem(c, *k, st);
}

// 受け継ぐ見た目を、その札の書きかたで塗り替える。
static void inherit(const SVG::Elem &e, State &st) {
	auto get = [&](const char *k) { return attr_of(e, k); };
	String v;
	if (!(v = get("fill")).is_empty()) st.fill = v;
	if (!(v = get("stroke")).is_empty()) st.stroke = v;
	if (!(v = get("fill-opacity")).is_empty())
		st.fill_op = std::clamp(length_of(v, 1.0, 1.0), 0.0, 1.0);
	if (!(v = get("stroke-opacity")).is_empty())
		st.stroke_op = std::clamp(length_of(v, 1.0, 1.0), 0.0, 1.0);
	if (!(v = get("stroke-width")).is_empty())
		st.width = std::max(length_of(v, 1.0, st.bd()), 0.0);
	if (!(v = get("stroke-linecap")).is_empty())
		st.cap = v == "round" ? CAP_ROUND : (v == "square" ? CAP_SQUARE : CAP_BUTT);
	if (!(v = get("stroke-linejoin")).is_empty())
		st.join = v == "round" ? JOIN_ROUND : (v == "bevel" ? JOIN_BEVEL : JOIN_MITER);
	if (!(v = get("stroke-miterlimit")).is_empty())
		st.miter = std::max(length_of(v, 4.0, 1.0), 1.0);
	if (!(v = get("fill-rule")).is_empty()) st.fill_evenodd = v == "evenodd";
	if (!(v = get("clip-rule")).is_empty()) st.clip_evenodd = v == "evenodd";
	if (!(v = get("color")).is_empty()) parse_color(v, st.current);
	if (!(v = get("stroke-dasharray")).is_empty()) {
		st.dash.clear();
		if (v.strip_edges() != "none") {
			bool ok = true;
			for (double d : numbers(v)) {
				if (d < 0.0) ok = false;
				st.dash.push_back(d);
			}
			double sum = 0.0;
			for (double d : st.dash) sum += d;
			if (!ok || sum <= 0.0) st.dash.clear();
		}
	}
	if (!(v = get("stroke-dashoffset")).is_empty()) st.dash_off = length_of(v, 0.0, st.bd());
	if (!(v = get("transform")).is_empty()) st.m = st.m * transform_of(v);
}

// その札の形。形を持たない札なら空。
static Path shape_of(const SVG::Elem &e, double tol, const State &st) {
	const std::string &t = e.tag;
	if (t == "rect") return rect_path(e, tol, st);
	if (t == "circle") {
		double r = length_of(attr_of(e, "r"), 0, st.bd());
		return ellipse_path(length_of(attr_of(e, "cx"), 0, st.bx()),
				length_of(attr_of(e, "cy"), 0, st.by()), r, r, tol);
	}
	if (t == "ellipse") {
		return ellipse_path(length_of(attr_of(e, "cx"), 0, st.bx()),
				length_of(attr_of(e, "cy"), 0, st.by()),
				length_of(attr_of(e, "rx"), 0, st.bx()),
				length_of(attr_of(e, "ry"), 0, st.by()), tol);
	}
	if (t == "line") {
		Sub s;
		s.p.push_back(Vector2((float)length_of(attr_of(e, "x1"), 0, st.bx()),
				(float)length_of(attr_of(e, "y1"), 0, st.by())));
		s.p.push_back(Vector2((float)length_of(attr_of(e, "x2"), 0, st.bx()),
				(float)length_of(attr_of(e, "y2"), 0, st.by())));
		return { s };
	}
	if (t == "polyline") return points_path(attr_of(e, "points"), false);
	if (t == "polygon") return points_path(attr_of(e, "points"), true);
	if (t == "path") return parse_path(attr_of(e, "d"), tol);
	return Path();
}

// 切り抜きの覆いを作る。中の形をぜんぶ足して、重なりも「中」として数える。
// 入る四角ぶんを持つ。画面ぜんぶぶんを札ごとに用意すると、
// 小さな丸 1 つの切り抜きでも 800x800 の入れ物を毎回埋めることになる
static Cover clip_cover(Ctx &c, const SVG::Elem &clip, const State &st) {
	State cs = st;
	inherit(clip, cs);
	double sc = std::max((double)cs.m.get_scale().length() * 0.7071, 1e-6);
	std::vector<Mask> ms;
	int x0 = c.cv->w, y0 = c.cv->h, x1 = 0, y1 = 0;
	for (const auto &k : clip.kids) {
		State ks = cs;
		inherit(*k, ks);
		Path pa = shape_of(*k, FLAT / sc, ks);
		if (pa.empty()) continue;
		Mask m = rasterize(c, pa, ks.m, ks.clip_evenodd);
		if (m.empty()) continue;
		x0 = std::min(x0, m.x0); y0 = std::min(y0, m.y0);
		x1 = std::max(x1, m.x0 + m.w); y1 = std::max(y1, m.y0 + m.h);
		ms.push_back(std::move(m));
	}
	Cover out;
	if (x1 <= x0 || y1 <= y0) return out;   // 中身が無い切り抜きは、何も出ない
	out.x0 = x0; out.y0 = y0; out.w = x1 - x0; out.h = y1 - y0;
	out.a.assign((size_t)out.w * (size_t)out.h, 0.0f);
	for (const Mask &m : ms)
		for (int y = 0; y < m.h; y++) {
			const float *row = &m.a[(size_t)y * (size_t)(m.w + 2)];
			float *dst = &out.a[(size_t)(m.y0 + y - y0) * (size_t)out.w + (size_t)(m.x0 - x0)];
			for (int x = 0; x < m.w; x++)
				if (row[x] > dst[x]) dst[x] = row[x];
		}
	return out;
}

// 札とその中身が入る四角。objectBoundingBox の下じきに使う。
// 線の太さは数えない（SVG の決まり）。渡す置きかたは、その札の座標を元にしたもの
static void box_walk(const Ctx &c, const SVG::Elem &e, State st, Rect2 &out, bool &got,
		int depth) {
	if (depth > 24) return;
	Transform2D keep = st.m;
	inherit(e, st);
	// いちばん外の札が持つ置きかたは数えない。四角はその札の座標で測るもので、
	// 置きかたは切り抜きの形にも同じように掛かる
	if (depth == 0) st.m = keep;
	const std::string &t = e.tag;
	if (t == "g" || t == "a" || t == "svg") {
		for (const auto &k : e.kids) box_walk(c, *k, st, out, got, depth + 1);
		return;
	}
	if (t == "use") {
		SVG::Elem *src = find_ref(c, href_of(e));
		if (src == nullptr) return;
		Transform2D mv;
		mv.set_origin(Vector2((float)length_of(attr_of(e, "x"), 0, st.bx()),
				(float)length_of(attr_of(e, "y"), 0, st.by())));
		st.m = st.m * mv;
		box_walk(c, *src, st, out, got, depth + 1);
		return;
	}
	Path pa = shape_of(e, FLAT, st);
	if (pa.empty()) return;
	Rect2 b = path_box(pa, st.m);
	out = got ? out.merge(b) : b;
	got = true;
}

// 切り抜きを 1 つ用意する。同じ札を同じ置きかたで使うなら、控えたものを返す。
static std::shared_ptr<const Cover> clip_of(Ctx &c, const SVG::Elem &clip, const State &st) {
	const void *ep = &clip;
	const float look[] = { st.m.columns[0].x, st.m.columns[0].y, st.m.columns[1].x,
		st.m.columns[1].y, st.m.columns[2].x, st.m.columns[2].y,
		st.clip_evenodd ? 1.0f : 0.0f };
	uint64_t key = mix(mix(SEED, &ep, sizeof(ep)), look, sizeof(look));
	auto *got = c.store->clip.find(key);
	if (got != nullptr) return *got;
	auto cov = std::make_shared<const Cover>(clip_cover(c, clip, st));
	size_t n = sizeof(Cover) + cov->a.size() * sizeof(float);
	return c.store->clip.keep(key, std::move(cov), n);
}

// 2 つの切り抜きを掛け合わせる。重なった四角のぶんが残る。
static std::shared_ptr<const Cover> clip_and(const Cover &a, const Cover &b) {
	Cover out;
	int x0 = std::max(a.x0, b.x0), y0 = std::max(a.y0, b.y0);
	int x1 = std::min(a.x0 + a.w, b.x0 + b.w), y1 = std::min(a.y0 + a.h, b.y0 + b.h);
	if (x1 <= x0 || y1 <= y0) return std::make_shared<const Cover>(out);
	out.x0 = x0; out.y0 = y0; out.w = x1 - x0; out.h = y1 - y0;
	out.a.assign((size_t)out.w * (size_t)out.h, 0.0f);
	for (int y = 0; y < out.h; y++)
		for (int x = 0; x < out.w; x++)
			out.a[(size_t)y * (size_t)out.w + (size_t)x] = a.at(x0 + x, y0 + y)
					* b.at(x0 + x, y0 + y);
	return std::make_shared<const Cover>(std::move(out));
}

// svg と symbol の viewport を作る。中の viewBox をその大きさへ合わせ、
// はみ出したぶんは隠す。隠したときは、元の切り抜きを keep へ控える。
static void enter_view(Ctx &c, const SVG::Elem &e, const State &st, State &in, double x,
		double y, double w, double h, std::shared_ptr<const Cover> &keep, bool &viewed) {
	Transform2D mv;
	mv.set_origin(Vector2((float)x, (float)y));
	in.m = st.m * mv;
	in.vw = w;
	in.vh = h;
	std::vector<double> vb = numbers(attr_of(e, "viewBox"));
	if (vb.size() >= 4 && vb[2] > 0.0 && vb[3] > 0.0) {
		Rect2 view((float)vb[0], (float)vb[1], (float)vb[2], (float)vb[3]);
		String par = attr_of(e, "preserveAspectRatio");
		in.m = in.m * view_fit(view, par.is_empty() ? String("xMidYMid meet") : par, w, h);
		in.vw = vb[2];
		in.vh = vb[3];
	}
	if (attr_of(e, "overflow") == "visible") return;
	Sub q;
	q.closed = true;
	q.p.push_back(Vector2((float)x, (float)y));
	q.p.push_back(Vector2((float)(x + w), (float)y));
	q.p.push_back(Vector2((float)(x + w), (float)(y + h)));
	q.p.push_back(Vector2((float)x, (float)(y + h)));
	auto vc = std::make_shared<const Cover>(
			mask_cover(rasterize(c, Path{ q }, st.m, false)));
	keep = std::move(c.clip);
	c.clip = keep ? clip_and(*keep, *vc) : vc;
	viewed = true;
}

// 札を 1 つ描く。中身のある札はたどる。
static void draw_elem(Ctx &c, const SVG::Elem &e, State st) {
	const std::string &t = e.tag;
	if (t == "defs" || t == "symbol" || t == "title" || t == "desc" || t == "style"
			|| t == "linearGradient" || t == "radialGradient" || t == "clipPath"
			|| t == "mask" || t == "pattern" || t == "filter" || t == "marker")
		return;
	// 深すぎるところで止める。輪になった指し先でいつまでも下りていかないため。
	// 数える先を分ける。入れ子の札そのものは深くても描くもので、
	// 止める上限は指し先をたどった回数のほうに掛ける
	if (c.depth > 256 || c.uses > 12) return;
	String disp = attr_of(e, "display");
	if (disp == "none") return;
	inherit(e, st);

	// その札固有のもの。受け継がない
	String op_s = attr_of(e, "opacity");
	double op = op_s.is_empty() ? 1.0 : std::clamp(length_of(op_s, 1.0, 1.0), 0.0, 1.0);
	String clip_s = attr_of(e, "clip-path");

	// 薄さが掛かっているまとまりは、別の紙へ描いてから重ねる。
	// じかに重ねると、中で重なり合っているところが 2 度薄くなって濃く出る
	Canvas *layer = nullptr;
	Canvas *keep_cv = c.cv;
	std::shared_ptr<const Cover> keep_clip;
	bool layered = op < 1.0;
	if (layered) {
		auto &pool = c.store->pool;
		if ((size_t)c.lv >= pool.size()) {
			pool.push_back(std::unique_ptr<Canvas>(new Canvas()));
			pool.back()->make(c.cv->w, c.cv->h);
		}
		layer = pool[(size_t)c.lv].get();
		layer->clear();
		c.lv++;
		c.cv = layer;
	}
	bool clipped = false;
	if (!clip_s.is_empty() && clip_s != "none") {
		SVG::Elem *cp = find_ref(c, clip_s);
		if (cp != nullptr && cp->tag == "clipPath") {
			State cst = st;
			bool ok = true;
			if (attr_of(*cp, "clipPathUnits") == "objectBoundingBox") {
				// 切り抜きの形を 0〜1 で書く決めかた。その札が入る四角を下じきにする。
				// 四角が無いなら何も出ない（SVG の決まり）
				Rect2 bb;
				ok = false;
				State bs;
				bs.vw = st.vw;
				bs.vh = st.vh;
				box_walk(c, e, bs, bb, ok, 0);
				Transform2D bt(bb.size.x, 0, 0, bb.size.y, bb.position.x, bb.position.y);
				cst.m = st.m * bt;
			}
			// 上から掛かっている切り抜きがあれば、掛け合わせる。
			// 控えるのは切り抜きを掛ける場合に
			keep_clip = std::move(c.clip);
			auto add = ok ? clip_of(c, *cp, cst) : std::make_shared<const Cover>();
			c.clip = keep_clip ? clip_and(*keep_clip, *add) : add;
			clipped = true;
		}
	}

	if (t == "svg" || t == "g" || t == "a") {
		State inner = st;
		std::shared_ptr<const Cover> keep_view;
		bool viewed = false;
		if (t == "svg" && &e != c.root)
			enter_view(c, e, st, inner, length_of(attr_of(e, "x"), 0, st.bx()),
					length_of(attr_of(e, "y"), 0, st.by()),
					length_of(attr_of(e, "width"), st.vw, st.bx()),
					length_of(attr_of(e, "height"), st.vh, st.by()), keep_view, viewed);
		c.depth++;
		draw_kids(c, e, inner);
		c.depth--;
		if (viewed) c.clip = std::move(keep_view);
	} else if (t == "use") {
		SVG::Elem *src = find_ref(c, href_of(e));
		if (src != nullptr) {
			double x = length_of(attr_of(e, "x"), 0, st.bx());
			double y = length_of(attr_of(e, "y"), 0, st.by());
			State us = st;
			std::shared_ptr<const Cover> keep_view;
			bool viewed = false;
			bool box = src->tag == "symbol" || src->tag == "svg";
			if (box) {
				// symbol と svg を呼び出すと、そこが新しい viewport になる。
				// 大きさは呼ぶ側が決めてよく、無ければ呼ばれる側、それも無ければ丸ごと
				String uw = attr_of(e, "width"), uh = attr_of(e, "height");
				if (uw.is_empty()) uw = attr_of(*src, "width");
				if (uh.is_empty()) uh = attr_of(*src, "height");
				enter_view(c, *src, st, us, x, y, length_of(uw, st.vw, st.bx()),
						length_of(uh, st.vh, st.by()), keep_view, viewed);
			} else {
				Transform2D mv;
				mv.set_origin(Vector2((float)x, (float)y));
				us.m = st.m * mv;
			}
			c.depth++;
			c.uses++;
			if (box) draw_kids(c, *src, us);
			else draw_elem(c, *src, us);
			c.uses--;
			c.depth--;
			if (viewed) c.clip = std::move(keep_view);
		}
	} else {
		// 曲線をどの程度細かく開くかは、画面での大きさから決める
		double sc = std::max((double)st.m.get_scale().length() * 0.7071, 1e-6);
		double tol = FLAT / sc;
		// 組んだ形は控えから引く。同じ大きさで描き続けるかぎり、組むのは 1 度きり
		const void *ep = &e;
		const double look[] = { tol, st.vw, st.vh, c.jitter, (double)c.jitter_seed,
			c.jitter_span.x, c.jitter_span.y };
		uint64_t key = mix(mix(SEED, &ep, sizeof(ep)), look, sizeof(look));
		Built *b = c.store->geo.find(key);
		if (b == nullptr) {
			Built made;
			made.fill = jitter_path(shape_of(e, tol, st), c);
			made.box = path_box(made.fill);
			size_t n = path_bytes(made.fill);
			b = &c.store->geo.keep(key, std::move(made), n);
		}
		if (!b->fill.empty()) {
			Paint fp = make_paint(c, st.fill, st.fill_op, st, b->box);
			if (fp.kind != Paint::NONE) {
				rasterize(c, c.scratch, b->fill, b->box, st.m, st.fill_evenodd);
				paint_mask(c, c.scratch, fp);
			}
			Paint sp = make_paint(c, st.stroke, st.stroke_op, st, b->box);
			if (sp.kind != Paint::NONE && st.width > 0.0) {
				// 線を引くと外周は太さのぶん外へ広がる。同じ角度で曲線を割ると、
				// 広がった先では折れが粗く出る。小さい形に太い線を引くほど響くので、
				// 形の大きさと太さの比に応じて細かく開き直す
				double ext = std::max(b->box.size.x, b->box.size.y);
				double tight = tol * ext / std::max(ext + st.width, 1e-6);
				const double rlook[] = { tight, st.width, (double)st.cap, (double)st.join,
					st.miter, st.dash_off, (double)st.dash.size() };
				uint64_t rk = mix(mix(SEED, rlook, sizeof(rlook)), st.dash.data(),
						st.dash.size() * sizeof(double));
				if (!b->ringed || b->rkey != rk) {
					Path fine = tight < tol * 0.9 ? jitter_path(shape_of(e, tight, st), c) : b->fill;
					Path src = st.dash.empty() ? fine : dashed(fine, st.dash, st.dash_off);
					b->ring = outline(src, st.width, st.cap, st.join, st.miter, tol);
					b->rbox = path_box(b->ring);
					b->rkey = rk;
					b->ringed = true;
					c.store->geo.grew(key, path_bytes(b->ring));
				}
				rasterize(c, c.scratch, b->ring, b->rbox, st.m, false);
				paint_mask(c, c.scratch, sp);
			}
		}
	}

	if (clipped) c.clip = std::move(keep_clip);
	if (layered) {
		c.lv--;
		c.cv = keep_cv;
		c.cv->over(*layer, op);
	}
}

// --- 読み取り ---

SVG::SVG() :
		_store(new Store()) {}

SVG::~SVG() = default;

void SVG::clear_cache() {
	_store->geo.clear();
	_store->grad.clear();
	_store->clip.clear();
	_store->pool.clear();
	_store->cv = Canvas();
	_store->pw = _store->ph = 0;
}

int SVG::cache_bytes() const {
	return (int)_store->bytes();
}

void SVG::_index(const std::shared_ptr<Elem> &e) {
	auto it = e->attr.find("id");
	if (it != e->attr.end()) _ids[std::string(it->second.utf8().get_data())] = e.get();
	for (const auto &k : e->kids) _index(k);
}

bool SVG::parse(const String &text) {
	// 控えは札の置き場所を鍵にしている。読み直したら指す先が変わるので、先に空ける
	clear_cache();
	_root.reset();
	_ids.clear();
	_error = "";
	Ref<XMLParser> xp;
	xp.instantiate();
	if (xp->open_buffer(text.to_utf8_buffer()) != OK) {
		_error = "読み取れなかったよ";
		return false;
	}
	std::vector<std::shared_ptr<Elem>> stack;
	while (xp->read() == OK) {
		int nt = xp->get_node_type();
		if (nt == XMLParser::NODE_ELEMENT) {
			auto e = std::make_shared<Elem>();
			e->tag = std::string(String(xp->get_node_name()).utf8().get_data());
			for (int i = 0; i < (int)xp->get_attribute_count(); i++)
				e->attr[std::string(String(xp->get_attribute_name(i)).utf8().get_data())] =
						xp->get_attribute_value(i);

			bool empty = xp->is_empty();
			if (stack.empty()) {
				if (e->tag != "svg") continue;
				_root = e;
			} else {
				stack.back()->kids.push_back(e);
			}
			if (!empty) stack.push_back(e);
		} else if (nt == XMLParser::NODE_ELEMENT_END) {
			if (!stack.empty()) stack.pop_back();
		} else if ((nt == XMLParser::NODE_TEXT || nt == XMLParser::NODE_CDATA)
				&& !stack.empty() && stack.back()->tag == "style") {
			// CDATA も拾う。CSS に < や & を書くために囲む書きかたで、
			// 拾わないと色の決まりが丸ごと落ちる。中身の在りかは字のときと違って名前のほう
			stack.back()->text += nt == XMLParser::NODE_CDATA ? xp->get_node_name()
															 : xp->get_node_data();
		}
	}
	if (_root == nullptr) {
		_error = "svg の札が見つからなかったよ";
		return false;
	}
	_index(_root);
	std::vector<Rule> rules;
	read_css(*_root, rules);
	// 強さの弱い順に掛ける。同じ強さなら書いてある順（CSS の決まり）
	std::stable_sort(rules.begin(), rules.end(),
			[](const Rule &a, const Rule &b) { return a.rank < b.rank; });
	dress(*_root, rules);
	_size = Vector2((float)length_of(attr_of(*_root, "width"), 0, 0),
			(float)length_of(attr_of(*_root, "height"), 0, 0));
	std::vector<double> vb = numbers(attr_of(*_root, "viewBox"));
	_view = vb.size() >= 4 ? Rect2((float)vb[0], (float)vb[1], (float)vb[2], (float)vb[3]) : Rect2();
	String par = attr_of(*_root, "preserveAspectRatio");
	if (!par.is_empty()) _par = par;
	return true;
}

Vector2 SVG::doc_size() const {
	if (_size.x > 0.0f && _size.y > 0.0f) return _size;
	if (_view.size.x > 0.0f && _view.size.y > 0.0f) return _view.size;
	return Vector2(300, 150);   // SVG の決まりの既定
}

Ref<Image> SVG::render(int w, int h, double jitter, int seed) const {
	Ref<Image> img;
	if (w <= 0 || h <= 0 || _root == nullptr) return img;
	_store->begin(w, h);
	Canvas &cv = _store->cv;
	Ctx c;
	c.cv = &cv;
	c.ids = &_ids;
	c.root = _root.get();
	c.store = _store.get();
	c.jitter = std::clamp(jitter, 0.0, 1.0);
	c.jitter_seed = std::clamp(seed, 1, 4);
	State st;
	st.vw = (double)w;
	st.vh = (double)h;
	if (_view.size.x > 0.0f && _view.size.y > 0.0f) {
		st.m = view_fit(_view, _par, (double)w, (double)h);
		st.vw = _view.size.x;
		st.vh = _view.size.y;
	}
	c.jitter_span = Vector2((float)st.vw, (float)st.vh);
	draw_elem(c, *_root, st);
	// 掛け合わせ済みの色を、ふつうの色へ戻して絵にする。
	// resize は 0 で埋めてくれるので、触っていない所はそのまま透けた色でよい。
	// 割り算は 256 目の表に置き換える。1 枚ぶん割り算すると、その処理で 2 ミリ秒かかる
	static const std::array<uint32_t, 256> recip = [] {
		std::array<uint32_t, 256> out{};
		for (int i = 1; i < 256; i++) out[(size_t)i] = 255u * 65536u / (uint32_t)i;
		return out;
	}();
	PackedByteArray buf;
	buf.resize((int64_t)w * (int64_t)h * 4);
	uint8_t *out = buf.ptrw();
	for (int y = cv.dy0; y <= cv.dy1; y++) {
		const uint8_t *src = &cv.px[((size_t)y * (size_t)w + (size_t)cv.dx0) * 4];
		uint8_t *dst = out + ((size_t)y * (size_t)w + (size_t)cv.dx0) * 4;
		int x = cv.dx0;
		// 完全透明・完全不透明な4画素をCPUのベクトル命令でまとめ、半透明は同じ整数計算へ戻す。
		for (; x + 3 <= cv.dx1; x += 4, src += 16, dst += 16) {
			bool clear = false, opaque = false;
#if defined(SVG2D_SSE2)
			__m128i px = _mm_loadu_si128((const __m128i *)src);
			__m128i alpha = _mm_srli_epi32(px, 24);
			clear = _mm_movemask_epi8(_mm_cmpeq_epi32(alpha, _mm_setzero_si128())) == 0xffff;
			opaque = _mm_movemask_epi8(_mm_cmpeq_epi32(alpha, _mm_set1_epi32(255))) == 0xffff;
			if (opaque) _mm_storeu_si128((__m128i *)dst, px);
#elif defined(SVG2D_NEON)
			uint8x16_t px = vld1q_u8(src);
			uint32x4_t alpha = vshrq_n_u32(vreinterpretq_u32_u8(px), 24);
			clear = vmaxvq_u32(alpha) == 0;
			opaque = vminvq_u32(alpha) == 255;
			if (opaque) vst1q_u8(dst, px);
#endif
			if (clear || opaque) continue;
			for (int i = 0; i < 4; i++) {
				const uint8_t *s = src + i * 4;
				uint8_t *d = dst + i * 4;
				uint8_t a = s[3];
				if (a == 0) continue;
				if (a == 255) {
					d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255;
					continue;
				}
				uint32_t k = recip[(size_t)a];
				for (int j = 0; j < 3; j++) {
					uint32_t v = ((uint32_t)s[j] * k + 32768u) >> 16;
					d[j] = (uint8_t)(v > 255u ? 255u : v);
				}
				d[3] = a;
			}
		}
		for (; x <= cv.dx1; x++, src += 4, dst += 4) {
			uint8_t a = src[3];
			if (a == 0) continue;
			if (a == 255) {   // まるごと乗った所はそのまま写す
				dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2]; dst[3] = 255;
				continue;
			}
			uint32_t k = recip[(size_t)a];
			for (int j = 0; j < 3; j++) {
				uint32_t v = ((uint32_t)src[j] * k + 32768u) >> 16;
				dst[j] = (uint8_t)(v > 255u ? 255u : v);
			}
			dst[3] = a;
		}
	}
	return Image::create_from_data(w, h, false, Image::FORMAT_RGBA8, buf);
}

// --- 画像を2D・3Dへ置くノード ---

static const double MAX_TEX = 4096.0;   // 1枚の画像が占めるメモリーを最大64 MiBに抑える

void SVGTexture::set_src(const String &s) {
	if (_src == s) return;
	_src = s;
	String text = s;
	String path = s.strip_edges();
	if (path.begins_with("uid://")) path = ResourceUID::ensure_path(path);
	// Inspector では SVG を素材として選ぶ。従来どおり SVG 本文を直接渡す API も
	// 壊さないため、Godot のファイルパスだけを読み替える。
	if ((path.begins_with("res://") || path.begins_with("user://")) &&
			path.get_extension().to_lower() == "svg") {
		text = FileAccess::file_exists(path) ? FileAccess::get_file_as_string(path) : String();
	}
	// 未設定・空ファイル・見つからない素材は「絵なし」。空の XML を読ませると
	// XMLParser 自身が ERR_INVALID_DATA を出すため、ここで静かに止める。
	if (text.strip_edges().is_empty()) {
		_doc.reset();
		for (Frame &frame : _frames) frame = Frame();
		return;
	}
	_doc = std::make_unique<SVG>();
	if (!_doc->parse(text)) {
		_doc.reset();
		for (Frame &frame : _frames) frame = Frame();
		return;
	}
	for (Frame &frame : _frames) frame.dirty = true;
}

Vector2 SVGTexture::draw_size() const {
	return _doc == nullptr ? Vector2() : _doc->doc_size();
}

// 画面で見える大きさへ直接合わせ、補間によるぼやけを避ける。
Vector2 SVGTexture::_target(const Vector2 &density) const {
	Vector2 base = draw_size();
	if (_doc == nullptr || base.x <= 0.0f || base.y <= 0.0f) return Vector2();
	double x = std::isfinite(density.x) ? std::max((double)density.x, 1.0 / MAX_TEX) : 1.0;
	double y = std::isfinite(density.y) ? std::max((double)density.y, 1.0 / MAX_TEX) : 1.0;
	return Vector2((float)std::min(MAX_TEX, std::max(1.0, std::ceil(base.x * x - 1e-6))),
			(float)std::min(MAX_TEX, std::max(1.0, std::ceil(base.y * y - 1e-6))));
}

bool SVGTexture::needs(const Vector2 &density, int pattern, bool mipmaps) const {
	Vector2 target = _target(density);
	const Frame &frame = _frames[(size_t)((pattern % 4 + 4) % 4)];
	return frame.dirty || target != frame.baked || mipmaps != frame.mipmaps;
}

void SVGTexture::set_jitter_amount(double amount) {
	double value = std::isfinite(amount) ? std::clamp(amount, 0.0, 0.3) : 0.0008;
	if (_jitter_amount == value) return;
	_jitter_amount = value;
	if (!_jitter_enabled) return;
	_frames[0].dirty = true;
	if (value <= 0.0) {
		for (size_t i = 1; i < _frames.size(); i++) _frames[i] = Frame();
	} else {
		for (Frame &frame : _frames) frame.dirty = true;
	}
}

void SVGTexture::set_jitter_enabled(bool enabled) {
	if (_jitter_enabled == enabled) return;
	_jitter_enabled = enabled;
	_frames[0].dirty = true;
	if (enabled && _jitter_amount > 0.0) {
		for (Frame &frame : _frames) frame.dirty = true;
	} else {
		// OFFでは通常画像1枚だけに戻し、アニメ用3枚のGPUメモリーを解放する。
		for (size_t i = 1; i < _frames.size(); i++) _frames[i] = Frame();
	}
}

// いまの画面密度で焼く。固定seed 1〜4の各画像は別々に控え、5枚目を作らない。
Ref<Texture2D> SVGTexture::get_texture(const Vector2 &density, int pattern, bool mipmaps) {
	Frame &frame = _frames[(size_t)((pattern % 4 + 4) % 4)];
	if (_doc == nullptr) {
		frame = Frame();
		frame.dirty = false;
		return frame.texture;
	}
	Vector2 target = _target(density);
	if (!frame.dirty && frame.texture.is_valid() && frame.baked == target &&
			frame.mipmaps == mipmaps)
		return frame.texture;
	Ref<Image> img = _doc->render((int)target.x, (int)target.y,
			_jitter_enabled ? _jitter_amount : 0.0,
			((pattern % 4 + 4) % 4) + 1);
	if (img.is_null()) {
		frame.texture.unref();
		return frame.texture;
	}
	if (mipmaps) img->generate_mipmaps();
	if (frame.texture.is_valid() && frame.baked == target && frame.mipmaps == mipmaps) {
		frame.texture->update(img);
	} else {
		frame.texture = ImageTexture::create_from_image(img);
	}
	frame.baked = target;
	frame.mipmaps = mipmaps;
	frame.dirty = false;
	return frame.texture;
}

SVG2D::SVG2D() {
	_update_processing();
}

Vector2 SVG2D::_density() const {
	if (!_adaptive || !is_inside_tree()) return Vector2(1, 1);
	Transform2D t = get_global_transform_with_canvas();
	return Vector2(t[0].length(), t[1].length());
}

void SVG2D::set_src(const String &s) {
	_svg.set_src(s);
	_animation_tick = 0;
	_animation_pattern = 0;
	queue_redraw();
}

void SVG2D::set_adaptive(bool enabled) {
	if (_adaptive == enabled) return;
	_adaptive = enabled;
	_update_processing();
	queue_redraw();
}

void SVG2D::_process(double) {
	if (!_adaptive && (!_animation_enabled || _svg.get_jitter_amount() <= 0.0)) {
		set_process(false);
		return;
	}
	if (!is_visible_in_tree()) return;
	if (_advance_animation() || _svg.needs(_density(), _animation_pattern)) queue_redraw();
}

void SVG2D::_draw() {
	Ref<Texture2D> tex = get_texture();
	Vector2 size = _svg.draw_size();
	if (tex.is_valid() && size.x > 0.0f && size.y > 0.0f) {
		Vector2 center = _offset + size * 0.5f;
		draw_set_transform(center, 0.0f,
				Vector2(_flip_h ? -1.0f : 1.0f, _flip_v ? -1.0f : 1.0f));
		draw_texture_rect(tex, Rect2(size * -0.5f, size), false);
	}
}

// いまの設定で焼いた画像を、ほかの 2D 描画でも使える形で返す。
Ref<Texture2D> SVG2D::get_texture() {
	return _svg.get_texture(_density(), _animation_pattern);
}

void SVG2D::_update_processing() {
	set_process(_adaptive || (_animation_enabled && _svg.get_jitter_amount() > 0.0));
}

bool SVG2D::_advance_animation() {
	if (!_animation_enabled || _svg.get_jitter_amount() <= 0.0) return false;
	if (++_animation_tick < _animation_interval) return false;
	_animation_tick = 0;
	_animation_pattern = (_animation_pattern + 1) % 4;
	return true;
}

void SVG2D::set_jitter_amount(double amount) {
	_svg.set_jitter_amount(amount);
	_animation_tick = 0;
	_animation_pattern = 0;
	_update_processing();
	queue_redraw();
}

void SVG2D::set_animation_interval(int frames) {
	int value = std::max(1, frames);
	if (_animation_interval == value) return;
	_animation_interval = value;
	_animation_tick = 0;
}

void SVG2D::set_animation_enabled(bool enabled) {
	if (_animation_enabled == enabled) return;
	_animation_enabled = enabled;
	_svg.set_jitter_enabled(enabled);
	_animation_tick = 0;
	_animation_pattern = 0;
	_update_processing();
	queue_redraw();
}

void SVG2D::set_flip_h(bool enabled) {
	if (_flip_h == enabled) return;
	_flip_h = enabled;
	queue_redraw();
}

void SVG2D::set_flip_v(bool enabled) {
	if (_flip_v == enabled) return;
	_flip_v = enabled;
	queue_redraw();
}

void SVG2D::set_offset(const Vector2 &offset) {
	if (_offset == offset) return;
	_offset = offset;
	queue_redraw();
}

void SVG2D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_src", "text"), &SVG2D::set_src);
	ClassDB::bind_method(D_METHOD("get_src"), &SVG2D::get_src);
	ClassDB::bind_method(D_METHOD("set_adaptive", "enabled"), &SVG2D::set_adaptive);
	ClassDB::bind_method(D_METHOD("is_adaptive"), &SVG2D::is_adaptive);
	ClassDB::bind_method(D_METHOD("get_texture"), &SVG2D::get_texture);
	ClassDB::bind_method(D_METHOD("get_svg_size"), &SVG2D::get_svg_size);
	ClassDB::bind_method(D_METHOD("set_jitter_amount", "amount"), &SVG2D::set_jitter_amount);
	ClassDB::bind_method(D_METHOD("get_jitter_amount"), &SVG2D::get_jitter_amount);
	ClassDB::bind_method(D_METHOD("set_animation_interval", "frames"), &SVG2D::set_animation_interval);
	ClassDB::bind_method(D_METHOD("get_animation_interval"), &SVG2D::get_animation_interval);
	ClassDB::bind_method(D_METHOD("set_animation_enabled", "enabled"), &SVG2D::set_animation_enabled);
	ClassDB::bind_method(D_METHOD("is_animation_enabled"), &SVG2D::is_animation_enabled);
	ClassDB::bind_method(D_METHOD("set_flip_h", "enabled"), &SVG2D::set_flip_h);
	ClassDB::bind_method(D_METHOD("is_flipped_h"), &SVG2D::is_flipped_h);
	ClassDB::bind_method(D_METHOD("set_flip_v", "enabled"), &SVG2D::set_flip_v);
	ClassDB::bind_method(D_METHOD("is_flipped_v"), &SVG2D::is_flipped_v);
	ClassDB::bind_method(D_METHOD("set_offset", "offset"), &SVG2D::set_offset);
	ClassDB::bind_method(D_METHOD("get_offset"), &SVG2D::get_offset);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "src", PROPERTY_HINT_FILE, "*.svg"),
			"set_src", "get_src");
	ADD_GROUP("Animation", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "animation_enabled"),
			"set_animation_enabled", "is_animation_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "jitter_amount", PROPERTY_HINT_RANGE,
			"0,0.3,0.0001"), "set_jitter_amount", "get_jitter_amount");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "animation_interval", PROPERTY_HINT_RANGE,
			"1,120,1,or_greater"), "set_animation_interval", "get_animation_interval");
	ADD_GROUP("Appearance", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "flip_h"), "set_flip_h", "is_flipped_h");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "flip_v"), "set_flip_v", "is_flipped_v");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "offset"), "set_offset", "get_offset");
	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "adaptive"), "set_adaptive", "is_adaptive");
}

SVG3D::SVG3D() {
	add_to_group("_svg3d_editor_nodes");
	_update_processing();
}

void SVG3D::_ensure_sprite() {
	if (_sprite != nullptr) return;
	_sprite = memnew(Sprite3D);
	_sprite->set_name("SVG");
	_sprite->set_draw_flag(SpriteBase3D::FLAG_SHADED, false);
	_sprite->set_flip_h(_flip_h);
	_sprite->set_flip_v(_flip_v);
	_sprite->set_modulate(_modulate);
	add_child(_sprite, false, Node::INTERNAL_MODE_BACK);
}

Vector2 SVG3D::_density() const {
	if (!_adaptive || !is_inside_tree()) return Vector2(1.5f, 1.5f);
	if (_editor_density_active) return _editor_density;
	Viewport *view = get_viewport();
	Camera3D *camera = view == nullptr ? nullptr : view->get_camera_3d();
	return _density_for_camera(camera);
}

Vector2 SVG3D::_density_for_camera(Camera3D *camera) const {
	Vector2 size = _svg.draw_size();
	if (camera == nullptr || size.x <= 0.0f || size.y <= 0.0f) return Vector2(1.5f, 1.5f);
	Transform3D t = get_global_transform();
	double hw = size.x * _pixel_size * 0.5;
	double hh = size.y * _pixel_size * 0.5;
	Vector3 world[4] = {
		t.xform(Vector3((float)-hw, (float)-hh, 0)),
		t.xform(Vector3((float)hw, (float)-hh, 0)),
		t.xform(Vector3((float)-hw, (float)hh, 0)),
		t.xform(Vector3((float)hw, (float)hh, 0)),
	};
	// 透視投影でカメラをまたぐ板は上限画素で保護する。
	int behind = 0;
	for (const Vector3 &p : world) behind += camera->is_position_behind(p) ? 1 : 0;
	if (behind == 4) return Vector2(1.5f, 1.5f);
	if (behind > 0) return Vector2((float)(MAX_TEX / size.x), (float)(MAX_TEX / size.y));
	Vector2 screen[4];
	for (int i = 0; i < 4; i++) screen[i] = camera->unproject_position(world[i]);
	// 斜めの板は近い辺ほど大きく見えるため、対向する辺の長い方を使う。
	double w = std::max(screen[0].distance_to(screen[1]), screen[2].distance_to(screen[3]));
	double h = std::max(screen[0].distance_to(screen[2]), screen[1].distance_to(screen[3]));
	return Vector2((float)(w * 1.5 / size.x), (float)(h * 1.5 / size.y));
}

void SVG3D::_refresh() {
	_queued = false;
	_ensure_sprite();
	Ref<Texture2D> tex = _svg.get_texture(_density(), _animation_pattern, true);
	_sprite->set_texture(tex);
	_sprite->set_pixel_size((float)_pixel_size);
	_sprite->set_flip_h(_flip_h);
	_sprite->set_flip_v(_flip_v);
	_sprite->set_modulate(_modulate);
	// 焼いた画像の縦横を別々に縮め、切り上げや上限があっても空間内の大きさを保つ。
	Vector2 base = _svg.draw_size();
	Vector2 baked = tex.is_valid() ? tex->get_size() : Vector2();
	Vector3 scale(1, 1, 1);
	if (base.x > 0.0f && base.y > 0.0f && baked.x > 0.0f && baked.y > 0.0f)
		scale = Vector3(base.x / baked.x, base.y / baked.y, 1);
	_sprite->set_scale(scale);
	// offsetは焼いた画素数ではなくSVGの自然寸法で指定する。
	Vector2 baked_offset(base.x > 0.0f ? _offset.x * baked.x / base.x : 0.0f,
			base.y > 0.0f ? _offset.y * baked.y / base.y : 0.0f);
	_sprite->set_offset(baked_offset);
}

void SVG3D::_queue_refresh() {
	if (_queued) return;
	_queued = true;
	callable_mp(this, &SVG3D::_refresh).call_deferred();
}

void SVG3D::set_src(const String &s) {
	_svg.set_src(s);
	_animation_tick = 0;
	_animation_pattern = 0;
	_queue_refresh();
}

void SVG3D::set_pixel_size(double size) {
	double value = std::isfinite(size) ? std::max(0.0001, size) : 0.01;
	if (_pixel_size == value) return;
	_pixel_size = value;
	_queue_refresh();
}

void SVG3D::set_adaptive(bool enabled) {
	if (_adaptive == enabled) return;
	_adaptive = enabled;
	_update_processing();
	_queue_refresh();
}

void SVG3D::_update_processing() {
	set_process(_adaptive || (_animation_enabled && _svg.get_jitter_amount() > 0.0));
}

bool SVG3D::_advance_animation() {
	if (!_animation_enabled || _svg.get_jitter_amount() <= 0.0) return false;
	if (++_animation_tick < _animation_interval) return false;
	_animation_tick = 0;
	_animation_pattern = (_animation_pattern + 1) % 4;
	return true;
}

void SVG3D::set_jitter_amount(double amount) {
	_svg.set_jitter_amount(amount);
	_animation_tick = 0;
	_animation_pattern = 0;
	_update_processing();
	_queue_refresh();
}

void SVG3D::set_animation_interval(int frames) {
	int value = std::max(1, frames);
	if (_animation_interval == value) return;
	_animation_interval = value;
	_animation_tick = 0;
}

void SVG3D::set_animation_enabled(bool enabled) {
	if (_animation_enabled == enabled) return;
	_animation_enabled = enabled;
	_svg.set_jitter_enabled(enabled);
	_animation_tick = 0;
	_animation_pattern = 0;
	_update_processing();
	_queue_refresh();
}

void SVG3D::set_flip_h(bool enabled) {
	if (_flip_h == enabled) return;
	_flip_h = enabled;
	_queue_refresh();
}

void SVG3D::set_flip_v(bool enabled) {
	if (_flip_v == enabled) return;
	_flip_v = enabled;
	_queue_refresh();
}

void SVG3D::set_offset(const Vector2 &offset) {
	if (_offset == offset) return;
	_offset = offset;
	_queue_refresh();
}

void SVG3D::set_modulate(const Color &color) {
	if (_modulate == color) return;
	_modulate = color;
	_queue_refresh();
}

void SVG3D::set_editor_camera(Camera3D *camera) {
	if (camera == nullptr) {
		_editor_density_active = false;
		return;
	}
	Vector2 density = _density_for_camera(camera);
	bool changed = !_editor_density_active || density != _editor_density;
	_editor_density = density;
	_editor_density_active = true;
	// エディター起動直後は、SVGのdeferred refreshが3D viewport/cameraの初期化より
	// 先に走ることがある。その低い暫定画像をキャッシュしたままにせず、カメラの
	// 投影寸法が届いた時点で自発的に更新する。Node::_processの実行順には依存しない。
	if (_adaptive && changed && _svg.needs(_editor_density, _animation_pattern, true))
		_queue_refresh();
}

Ref<Texture2D> SVG3D::get_texture() const {
	return _sprite == nullptr ? Ref<Texture2D>() : _sprite->get_texture();
}

void SVG3D::_process(double) {
	if (!_adaptive && (!_animation_enabled || _svg.get_jitter_amount() <= 0.0)) {
		set_process(false);
		return;
	}
	if (is_visible_in_tree() && (_advance_animation() ||
			_svg.needs(_density(), _animation_pattern, true))) _queue_refresh();
}

void SVG3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_src", "text"), &SVG3D::set_src);
	ClassDB::bind_method(D_METHOD("get_src"), &SVG3D::get_src);
	ClassDB::bind_method(D_METHOD("set_pixel_size", "size"), &SVG3D::set_pixel_size);
	ClassDB::bind_method(D_METHOD("get_pixel_size"), &SVG3D::get_pixel_size);
	ClassDB::bind_method(D_METHOD("set_adaptive", "enabled"), &SVG3D::set_adaptive);
	ClassDB::bind_method(D_METHOD("is_adaptive"), &SVG3D::is_adaptive);
	ClassDB::bind_method(D_METHOD("get_texture"), &SVG3D::get_texture);
	ClassDB::bind_method(D_METHOD("get_svg_size"), &SVG3D::get_svg_size);
	ClassDB::bind_method(D_METHOD("set_jitter_amount", "amount"), &SVG3D::set_jitter_amount);
	ClassDB::bind_method(D_METHOD("get_jitter_amount"), &SVG3D::get_jitter_amount);
	ClassDB::bind_method(D_METHOD("set_animation_interval", "frames"), &SVG3D::set_animation_interval);
	ClassDB::bind_method(D_METHOD("get_animation_interval"), &SVG3D::get_animation_interval);
	ClassDB::bind_method(D_METHOD("set_animation_enabled", "enabled"), &SVG3D::set_animation_enabled);
	ClassDB::bind_method(D_METHOD("is_animation_enabled"), &SVG3D::is_animation_enabled);
	ClassDB::bind_method(D_METHOD("set_flip_h", "enabled"), &SVG3D::set_flip_h);
	ClassDB::bind_method(D_METHOD("is_flipped_h"), &SVG3D::is_flipped_h);
	ClassDB::bind_method(D_METHOD("set_flip_v", "enabled"), &SVG3D::set_flip_v);
	ClassDB::bind_method(D_METHOD("is_flipped_v"), &SVG3D::is_flipped_v);
	ClassDB::bind_method(D_METHOD("set_offset", "offset"), &SVG3D::set_offset);
	ClassDB::bind_method(D_METHOD("get_offset"), &SVG3D::get_offset);
	ClassDB::bind_method(D_METHOD("set_modulate", "color"), &SVG3D::set_modulate);
	ClassDB::bind_method(D_METHOD("get_modulate"), &SVG3D::get_modulate);
	ClassDB::bind_method(D_METHOD("_set_editor_camera", "camera"), &SVG3D::set_editor_camera);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "src", PROPERTY_HINT_FILE, "*.svg"),
			"set_src", "get_src");
	ADD_GROUP("Animation", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "animation_enabled"),
			"set_animation_enabled", "is_animation_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "jitter_amount", PROPERTY_HINT_RANGE,
			"0,0.3,0.0001"), "set_jitter_amount", "get_jitter_amount");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "animation_interval", PROPERTY_HINT_RANGE,
			"1,120,1,or_greater"), "set_animation_interval", "get_animation_interval");
	ADD_GROUP("Appearance", "");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "modulate"), "set_modulate", "get_modulate");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "flip_h"), "set_flip_h", "is_flipped_h");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "flip_v"), "set_flip_v", "is_flipped_v");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "offset"), "set_offset", "get_offset");
	ADD_GROUP("Rendering", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "pixel_size", PROPERTY_HINT_RANGE,
			"0.0001,128,0.0001,or_greater,exp"), "set_pixel_size", "get_pixel_size");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "adaptive"), "set_adaptive", "is_adaptive");
}

} // namespace svg2d

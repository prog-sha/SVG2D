// SVG の「形」を扱うところ。
//
// 責務: 道（path）の指図を点の並びに開き、太さのある線をその外周の形に変えること。
// 色のことも、どこへ描くかも知らない。
//
// 設計思想: 曲線はここで折れ線に開いてしまい、この先は折れ線しか扱わない。
// 太さのある線も「外周を囲む閉じた形」に変えてしまえば、塗りと同じ道で描ける。
// Skia も Qt も同じやり方で、線を塗りに直してから 1 つの塗りつぶしに通している。
//
// 元にした場所:
//   SVG 1.1 付録 F.6.5 … 円弧の指図を中心と角度に直す式
//   Skia src/core/SkStroke.cpp … 外周を「外まわり＋端＋内まわりの逆順＋端」で閉じる組み方
//   Skia src/core/SkStrokerPriv.cpp … 角の 3 種類と、マイターの上限の見かた
#ifndef SVG2D_SVG_GEOM_H
#define SVG2D_SVG_GEOM_H

#include <godot_cpp/core/math_defs.hpp>
#include <godot_cpp/variant/transform2d.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cmath>
#include <vector>

namespace svg2d {
namespace svg {

// ひと続きの折れ線。閉じているかどうかを持つ。
struct Sub {
	std::vector<godot::Vector2> p;
	bool closed = false;
};

// 形ぜんぶ。ひと続きの折れ線がいくつか集まったもの。
using Path = std::vector<Sub>;

// 端の形と角の形。SVG の stroke-linecap / stroke-linejoin と同じ並び。
enum Cap { CAP_BUTT = 0, CAP_ROUND = 1, CAP_SQUARE = 2 };
enum Join { JOIN_MITER = 0, JOIN_ROUND = 1, JOIN_BEVEL = 2 };

// --- 曲線を折れ線に開く ---

// 丸みを何本の折れ線で表すか。弦の真ん中と弧の離れは r(1-cos(θ/2)) なので、
// これを許す食い違い tol と置くと、1 本ぶんの角度は 2*acos(1 - tol/r) になる。
// 少なすぎても多すぎても困るので、上限と下限を渡す。
inline int arc_n(double r, double span, double tol, int lo = 1, int hi = 64) {
	if (r <= tol) return lo;
	double step = 2.0 * std::acos(std::max(1.0 - tol / r, -1.0));
	return std::min(std::max((int)std::ceil(span / std::max(step, 1e-4)), lo), hi);
}

// 曲線を何本の折れ線で表すか。ふくらみの大きさから決める（Wang の式）。
// tol は許す食い違い。画面の座標で 0.1 画素ぶんを渡す。
inline int quad_steps(const godot::Vector2 &a, const godot::Vector2 &b,
		const godot::Vector2 &c, double tol) {
	godot::Vector2 d = a - b * 2.0f + c;
	double n = std::sqrt(d.length() / (8.0 * tol));
	return std::min(std::max((int)std::ceil(n), 1), 300);
}

inline int cubic_steps(const godot::Vector2 &a, const godot::Vector2 &b,
		const godot::Vector2 &c, const godot::Vector2 &d, double tol) {
	double l = std::max((a - b * 2.0f + c).length(), (b - c * 2.0f + d).length());
	double n = std::sqrt(0.75 * l / tol);
	return std::min(std::max((int)std::ceil(n), 1), 300);
}

// 3 次ベジエを折れ線にして足す。始点はすでに入っているものとする。
inline void add_cubic(std::vector<godot::Vector2> &out, const godot::Vector2 &p0,
		const godot::Vector2 &p1, const godot::Vector2 &p2, const godot::Vector2 &p3,
		double tol) {
	int n = cubic_steps(p0, p1, p2, p3, tol);
	for (int i = 1; i <= n; i++) {
		double t = (double)i / (double)n, u = 1.0 - t;
		out.push_back(p0 * (float)(u * u * u) + p1 * (float)(3 * u * u * t)
				+ p2 * (float)(3 * u * t * t) + p3 * (float)(t * t * t));
	}
}

// 2 次ベジエ。
inline void add_quad(std::vector<godot::Vector2> &out, const godot::Vector2 &p0,
		const godot::Vector2 &p1, const godot::Vector2 &p2, double tol) {
	int n = quad_steps(p0, p1, p2, tol);
	for (int i = 1; i <= n; i++) {
		double t = (double)i / (double)n, u = 1.0 - t;
		out.push_back(p0 * (float)(u * u) + p1 * (float)(2 * u * t) + p2 * (float)(t * t));
	}
}

// 円弧の指図（A）を折れ線にして足す。
// SVG 1.1 付録 F.6.5 のとおり、端から端の書きかたを中心と角度に直してから回す。
// 半径が足りないときは、ちょうど届く大きさまで広げる（F.6.6）。
inline void add_arc(std::vector<godot::Vector2> &out, const godot::Vector2 &p0,
		double rx, double ry, double rot, bool large, bool sweep,
		const godot::Vector2 &p1, double tol) {
	if (p0.is_equal_approx(p1)) return;
	rx = std::abs(rx);
	ry = std::abs(ry);
	if (rx < 1e-9 || ry < 1e-9) {   // 半径が無いときはまっすぐつなぐ
		out.push_back(p1);
		return;
	}
	double cs = std::cos(rot), sn = std::sin(rot);
	double dx = (p0.x - p1.x) * 0.5, dy = (p0.y - p1.y) * 0.5;
	double x1 = cs * dx + sn * dy;
	double y1 = -sn * dx + cs * dy;
	double lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
	if (lam > 1.0) {   // 端から端に届かない半径は、ちょうど届く大きさへ広げる
		double s = std::sqrt(lam);
		rx *= s;
		ry *= s;
	}
	double den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
	double num = rx * rx * ry * ry - den;
	double co = std::sqrt(std::max(num / std::max(den, 1e-12), 0.0));
	if (large == sweep) co = -co;
	double cxp = co * rx * y1 / ry;
	double cyp = -co * ry * x1 / rx;
	godot::Vector2 c((float)(cs * cxp - sn * cyp + (p0.x + p1.x) * 0.5),
			(float)(sn * cxp + cs * cyp + (p0.y + p1.y) * 0.5));
	double ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry;
	double vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry;
	double th0 = std::atan2(uy, ux);
	double dth = std::atan2(ux * vy - uy * vx, ux * vx + uy * vy);
	if (!sweep && dth > 0.0) dth -= godot::Math::TAU;
	if (sweep && dth < 0.0) dth += godot::Math::TAU;
	int n = arc_n(std::max(rx, ry), std::abs(dth), tol, 1, 400);
	for (int i = 1; i <= n; i++) {
		double th = th0 + dth * ((double)i / (double)n);
		double a = rx * std::cos(th), b = ry * std::sin(th);
		out.push_back(godot::Vector2((float)(c.x + cs * a - sn * b),
				(float)(c.y + sn * a + cs * b)));
	}
}

// --- 形をまるごと動かす ---
inline Path moved(const Path &in, const godot::Transform2D &m) {
	Path out = in;
	for (Sub &s : out)
		for (godot::Vector2 &v : s.p) v = m.xform(v);
	return out;
}

// --- 破線 ---
// ひと続きの折れ線を、型のとおりに切り分ける。描かれるところを返す。
// 型の数が奇数のときは 2 回つないで偶数にする（SVG の決まり）。
inline Path dashed(const Path &in, const std::vector<double> &pat, double offset) {
	std::vector<double> d = pat;
	if (d.size() % 2 == 1) d.insert(d.end(), pat.begin(), pat.end());
	double cycle = 0.0;
	for (double v : d) cycle += v;
	if (cycle <= 0.0) return in;
	// 刻みが細かすぎるときは何も引かない。長さ 800 の線を 0.00002 の型で切ると
	// 2000 万本になり、描き終わらない（実測 3.5 秒）。Skia も同じ頭打ちで道ごと落とす
	double total = 0.0;
	for (const Sub &s : in)
		for (size_t i = 0; i + 1 < s.p.size(); i++) total += s.p[i].distance_to(s.p[i + 1]);
	if (total / cycle > 100000.0) return Path();
	Path out;
	for (const Sub &s : in) {
		if (s.p.size() < 2) {
			out.push_back(s);
			continue;
		}
		std::vector<godot::Vector2> pts = s.p;
		if (s.closed && !pts.front().is_equal_approx(pts.back())) pts.push_back(pts.front());
		// 型のどこから始めるか。負のずらしも 1 周ぶんずつ足して前へ回す
		double at = std::fmod(offset, cycle);
		if (at < 0.0) at += cycle;
		size_t k = 0;
		while (at >= d[k]) {
			at -= d[k];
			k = (k + 1) % d.size();
		}
		bool on = (k % 2) == 0;
		double left = d[k] - at;
		Sub cur;
		if (on) cur.p.push_back(pts[0]);
		for (size_t i = 0; i + 1 < pts.size(); i++) {
			godot::Vector2 a = pts[i], b = pts[i + 1];
			double len = a.distance_to(b);
			double done = 0.0;
			while (len - done > left) {
				done += left;
				godot::Vector2 at_p = a.lerp(b, (float)(done / len));
				if (on) {
					cur.p.push_back(at_p);
					out.push_back(cur);
					cur.p.clear();
				} else {
					cur.p.clear();
					cur.p.push_back(at_p);
				}
				on = !on;
				k = (k + 1) % d.size();
				left = d[k];
			}
			left -= (len - done);
			if (on) cur.p.push_back(b);
		}
		if (on && cur.p.size() >= 1) out.push_back(cur);
	}
	return out;
}

// --- 太さのある線を、外周の形に変える ---



// 中心のまわりを、ある向きから別の向きまで回してなぞる。
inline void arc_to(std::vector<godot::Vector2> &out, const godot::Vector2 &c, double r,
		double a0, double a1, double tol) {
	double span = a1 - a0;
	int n = arc_n(r, std::abs(span), tol);
	for (int i = 1; i <= n; i++) {
		double a = a0 + span * ((double)i / (double)n);
		out.push_back(c + godot::Vector2((float)(std::cos(a) * r), (float)(std::sin(a) * r)));
	}
}

// 角を 1 つ足す。外まわりの側へ形を置き、内まわりは中心の点を通す。
// 内まわりをわざと交わらせるのは Skia と Qt が同じで、巻き数で塗るから正しく片付く。
inline void add_join(std::vector<godot::Vector2> &out, const godot::Vector2 &pivot,
		const godot::Vector2 &n0, const godot::Vector2 &n1, double r, Join join,
		double miter, double tol) {
	double cross = n0.x * n1.y - n0.y * n1.x;
	double dot = n0.dot(n1);
	if (std::abs(cross) < 1e-9 && dot > 0.0) return;   // まっすぐなら何も足さない
	if (join == JOIN_ROUND) {
		double a0 = std::atan2(n0.y, n0.x), a1 = std::atan2(n1.y, n1.x);
		// 短いほうの回りかたを選ぶ。長いほうへ回すと、線の反対がわへ丸がはみ出す
		while (a1 - a0 > godot::Math::PI) a1 -= godot::Math::TAU;
		while (a0 - a1 > godot::Math::PI) a1 += godot::Math::TAU;
		arc_to(out, pivot, r, a0, a1, tol);
		return;
	}
	if (join == JOIN_MITER) {
		// マイターの長さは 1/sin(半角)。上限を超えたら角を落とす（SVG と同じ）
		double sin_half = std::sqrt(std::max((1.0 + dot) * 0.5, 0.0));
		if (sin_half > 1e-6 && 1.0 / sin_half <= miter) {
			godot::Vector2 mid = n0 + n1;
			double ml = mid.length();
			if (ml > 1e-9) {
				out.push_back(pivot + mid * (float)(r / (sin_half * ml)));
				out.push_back(pivot + n1 * (float)r);
				return;
			}
		}
	}
	out.push_back(pivot + n1 * (float)r);   // 角を落とした形（ベベル）
}

// 端を 1 つ足す。at が端の点、dir が外へ向かう向き、n は片がわの法線。
inline void add_cap(std::vector<godot::Vector2> &out, const godot::Vector2 &at,
		const godot::Vector2 &dir, const godot::Vector2 &n, double r, Cap cap, double tol) {
	if (cap == CAP_ROUND) {
		// 法線から外向き（dir）を通って、反対がわの法線まで。回る向きは -90 度が外向き
		// （法線 (-dy, dx) を -90 度回すと (dx, dy) になる）。逆に回すと線の内がわへ
		// 半円がめり込み、端がくびれて見える
		double a0 = std::atan2(n.y, n.x);
		arc_to(out, at, r, a0, a0 - godot::Math::PI, tol);
		return;
	}
	if (cap == CAP_SQUARE) {
		out.push_back(at + (n + dir) * (float)r);
		out.push_back(at + (dir - n) * (float)r);
	}
	out.push_back(at - n * (float)r);
}

// 太さのある線を、外周を囲む閉じた形に変える。
// 開いた線は「外まわり → 端 → 内まわりの逆順 → 端」でひと回りする（Skia と同じ組み方）。
// 閉じた線は外まわりと内まわりを別々の輪にして、巻き数で中を抜く。
inline Path outline(const Path &in, double w, Cap cap, Join join, double miter, double tol) {
	double r = w * 0.5;
	Path out;
	if (r <= 0.0) return out;
	for (const Sub &s : in) {
		// 同じ場所の点は落とす。向きが決められず、法線が出せないため
		std::vector<godot::Vector2> p;
		for (const godot::Vector2 &v : s.p)
			if (p.empty() || !v.is_equal_approx(p.back())) p.push_back(v);
		bool closed = s.closed;
		if (closed && p.size() > 1 && p.front().is_equal_approx(p.back())) p.pop_back();
		if (p.size() < 2) {
			// 長さの無いひと続き。丸と角の端は点を打つ決まり（SVG 1.1 の 11.4）
			if (p.size() == 1 && cap != CAP_BUTT) {
				Sub dot;
				if (cap == CAP_ROUND) {
					arc_to(dot.p, p[0], r, 0.0, godot::Math::TAU, tol);
				} else {
					dot.p.push_back(p[0] + godot::Vector2((float)-r, (float)-r));
					dot.p.push_back(p[0] + godot::Vector2((float)r, (float)-r));
					dot.p.push_back(p[0] + godot::Vector2((float)r, (float)r));
					dot.p.push_back(p[0] + godot::Vector2((float)-r, (float)r));
				}
				dot.closed = true;
				out.push_back(dot);
			}
			continue;
		}
		int n = (int)p.size();
		int segs = closed ? n : n - 1;
		// 区切りごとの法線。左がわを正にとる
		std::vector<godot::Vector2> nm((size_t)segs);
		for (int i = 0; i < segs; i++) {
			godot::Vector2 d = (p[(i + 1) % n] - p[i]).normalized();
			nm[(size_t)i] = godot::Vector2(-d.y, d.x);
		}
		Sub side[2];
		for (int k = 0; k < 2; k++) {
			double sg = k == 0 ? 1.0 : -1.0;
			std::vector<godot::Vector2> &o = side[k].p;
			int first = k == 0 ? 0 : segs - 1;
			int step = k == 0 ? 1 : -1;
			for (int c = 0; c < segs; c++) {
				int i = first + step * c;
				godot::Vector2 a = p[k == 0 ? i : (i + 1) % n];
				godot::Vector2 b = p[k == 0 ? (i + 1) % n : i];
				godot::Vector2 nv = nm[(size_t)i] * (float)sg;
				if (c == 0) o.push_back(a + nv * (float)r);
				o.push_back(b + nv * (float)r);
				int j = i + step;
				bool has_next = closed ? true : (k == 0 ? j < segs : j >= 0);
				if (!has_next) continue;
				int jj = ((j % segs) + segs) % segs;
				godot::Vector2 nx = nm[(size_t)jj] * (float)sg;
				// 内がわへ折れる角は、中心の点を通してから次へ。巻き数で片付く。
				// 見分けは左右で同じ式でよい。反対がわは道を逆にたどっていて、
				// 法線も向きも両方ひっくり返るので、回る向きの符号はそろう
				double cr = nv.x * nx.y - nv.y * nx.x;
				if (cr > 0.0) {
					o.push_back(b + nx * (float)r);
				} else {
					add_join(o, b, nv, nx, r, join, miter, tol);
				}
			}
		}
		if (closed) {
			side[0].closed = true;
			side[1].closed = true;
			out.push_back(side[0]);
			out.push_back(side[1]);
			continue;
		}
		// 開いた線はひと回りにする。終わりと始まりに端の形を挟む
		Sub ring;
		ring.p = side[0].p;
		godot::Vector2 tail_dir = (p[n - 1] - p[n - 2]).normalized();
		add_cap(ring.p, p[n - 1], tail_dir, nm[(size_t)(segs - 1)] * 1.0f, r, cap, tol);
		ring.p.insert(ring.p.end(), side[1].p.begin(), side[1].p.end());
		godot::Vector2 head_dir = (p[0] - p[1]).normalized();
		add_cap(ring.p, p[0], head_dir, nm[0] * -1.0f, r, cap, tol);
		ring.closed = true;
		out.push_back(ring);
	}
	return out;
}

} // namespace svg
} // namespace svg2d

#endif // SVG2D_SVG_GEOM_H

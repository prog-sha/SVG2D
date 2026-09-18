// 入力線分とロープの交差位置を求める。
// 責務: 次元ごとの交点計算と、入力始点に近い交点の選択。
// 設計思想: 区間を一度走査し、作業配列や並べ替えを使わない。
#ifndef SVG2D_ROPE_CUT_H
#define SVG2D_ROPE_CUT_H
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>
namespace svg2d {
struct RopeCut { int edge = -1; double fraction = 0; };
// 平行・重なりには一意の交点がないため切らない。
inline bool rope_intersection(godot::Vector2 a, godot::Vector2 b, godot::Vector2 c,
		godot::Vector2 d, double, double &t, double &u) {
	auto r = b - a, s = d - c;
	double cross = r.cross(s);
	if (std::abs(cross) <= 1e-4 * std::sqrt((double)r.length_squared() * s.length_squared())) return false;
	t = (c - a).cross(s) / cross; u = (c - a).cross(r) / cross;
	return t >= 0 && t <= 1 && u >= 0 && u <= 1;
}
// 3Dは有限線分同士の最近接位置を求め、世界座標での許容距離を使う。
inline bool rope_intersection(godot::Vector3 a, godot::Vector3 b, godot::Vector3 c,
		godot::Vector3 d, double tolerance, double &t, double &u) {
	auto r = b - a, s = d - c, offset = a - c;
	auto dot = [](godot::Vector3 x, godot::Vector3 y) {
		return (double)x.x * y.x + (double)x.y * y.y + (double)x.z * y.z;
	};
	double rr = dot(r, r), ss = dot(s, s), rs = dot(r, s), ro = dot(r, offset), so = dot(s, offset);
	double denominator = rr * ss - rs * rs;
	if (rr <= 1e-18 || ss <= 1e-18 || denominator <= 1e-8 * rr * ss) return false;
	t = std::clamp((rs * so - ro * ss) / denominator, 0.0, 1.0);
	u = (rs * t + so) / ss;
	if (u < 0) { u = 0; t = std::clamp(-ro / rr, 0.0, 1.0); }
	else if (u > 1) { u = 1; t = std::clamp((rs - ro) / rr, 0.0, 1.0); }
	return (a + r * t).distance_squared_to(c + s * u) <= tolerance * tolerance;
}
// 両端は除外し、同じ線で切断片をもう一度切る際の微小な端片も防ぐ。
template <typename V, typename Transform>
RopeCut find_rope_cut(const std::vector<V> &points, V from, V to, Transform world, double tolerance) {
	RopeCut hit;
	if (points.size() < 2 || from.distance_squared_to(to) <= 1e-18) return hit;
	double nearest = 2;
	V a = world(points.front());
	for (size_t i = 0; i + 1 < points.size(); i++) {
		V b = world(points[i + 1]);
		double t, u;
		if (rope_intersection(from, to, a, b, tolerance, t, u) && t < nearest) {
			// 世界座標の丸め誤差を、短い区間の比率へ換算して端点に揃える。
			double epsilon = 4 * std::numeric_limits<real_t>::epsilon() *
					std::max({1.0, (double)a.length(), (double)b.length(), (double)from.length(), (double)to.length()});
			double length = a.distance_to(b);
			if (u * length <= epsilon) u = 0;
			else if ((1 - u) * length <= epsilon) u = 1;
			if ((i == 0 && u == 0) || (i + 2 == points.size() && u == 1)) { a = b; continue; }
			nearest = t; hit = {(int)i, u};
		}
		a = b;
	}
	return hit;
}
} // namespace svg2d
#endif

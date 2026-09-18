// ロープの数値計算をノードなしで検証する。
// 責務: 粒子数・固定端・端数処理を変えてSIMDと通常処理を比較する。
// 設計思想: 初期条件を固定し、実装の経路が違っても物理結果が揃うことを確かめる。
#include "rope_math.h"
#include "rope_cut.h"
#include <cassert>
#include <cstdio>

using namespace svg2d;

// 座標の全成分を使い、メモリ境界近くの端数も通す。
template <typename V>
static void check_rope(const V &gravity, const V &step) {
	for (int n : {2, 3, 4, 5, 7, 8, 9, 16, 255, 256}) {
		for (size_t begin : {0u, 1u}) {
			std::vector<V> fast((size_t)n), old((size_t)n);
			for (int i = 0; i < n; i++) {
				fast[(size_t)i] = step * (float)i;
				old[(size_t)i] = fast[(size_t)i] - gravity * (float)(i % 3);
			}
			auto plain = fast, previous = old;
			for (int frame = 0; frame < 32; frame++) {
				integrate_rope(fast, old, gravity, 0.98f, begin);
				integrate_scalar(plain, previous, gravity, 0.98f, begin);
				for (int i = 0; i < n; i++) {
					assert((fast[(size_t)i] - plain[(size_t)i]).length_squared() < 1e-8);
					assert((old[(size_t)i] - previous[(size_t)i]).length_squared() < 1e-8);
				}
			}
			V anchor = fast[0];
			solve_rope(fast, anchor, true, 8, 0.9, 2.0);
			assert(fast[0] == anchor);
			double link = 2.0 / (n - 1);
			for (int i = 1; i < n; i++)
				assert((fast[(size_t)i] - fast[(size_t)i - 1]).length() <= link + 1e-5);
			// 緩んだロープは反復しても動かない。
			std::fill(fast.begin(), fast.end(), V());
			solve_rope(fast, V(), false, 64, 1.0, 2.0);
			for (const V &point : fast) assert(point == V());
		}
	}
}

// 配列順とは逆向きの切断線でも、入力始点から最初の交点を選ぶ。
static void check_intersections() {
	std::vector<Vector2> zigzag = {{0, -1}, {0, 1}, {2, -1}, {2, 1}};
	auto identity = [](Vector2 p) { return p; };
	auto hit = find_rope_cut(zigzag, Vector2(3, 0), Vector2(-1, 0), identity, 0);
	assert(hit.edge == 2 && std::abs(hit.fraction - 0.5) < 1e-6);
	hit = find_rope_cut(zigzag, Vector2(-1, 0), Vector2(3, 0), identity, 0);
	assert(hit.edge == 0);
	double t, u;
	assert(!rope_intersection(Vector2(3, 0), Vector2(4, 0), Vector2(0, -1), Vector2(0, 1), 0, t, u));
	assert(rope_intersection(Vector3(-1, 0, 0.0005), Vector3(1, 0, 0.0005),
			Vector3(0, -1, 0), Vector3(0, 1, 0), 0.001, t, u));
	assert(!rope_intersection(Vector3(-1, 0, 0.01), Vector3(1, 0, 0.01),
			Vector3(0, -1, 0), Vector3(0, 1, 0), 0.001, t, u));
	std::vector<Vector2> points = {{0, 0}, {0, 8}, {0, 16}};
	double coords[] = {0, 0.25, 1};
	solve_rope(points, Vector2(), true, 8, 1, 8, coords);
	assert(points[1].length() <= 2.00001 && points[2].distance_to(points[1]) <= 6.00001);
}

// 両方の次元で重力の全軸を使う。
int main() {
	check_intersections();
	check_rope(Vector2(0.0003f, -0.0007f), Vector2(0.01f, -0.02f));
	check_rope(Vector3(0.0003f, -0.0007f, 0.0009f), Vector3(0.01f, -0.02f, 0.005f));
	std::printf("Rope math scalar parity: %s, 40 cases x 32 steps\n", rope_backend_name());
}

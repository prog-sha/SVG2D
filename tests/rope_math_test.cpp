// ロープの数値計算をノードなしで検証する。
// 責務: 粒子数・固定端・端数処理を変えてSIMDと通常処理を比較する。
// 設計思想: 初期条件を固定し、実装の経路が違っても物理結果が揃うことを確かめる。
#include "rope_math.h"
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

// 両方の次元で重力の全軸を使う。
int main() {
	check_rope(Vector2(0.0003f, -0.0007f), Vector2(0.01f, -0.02f));
	check_rope(Vector3(0.0003f, -0.0007f, 0.0009f), Vector3(0.01f, -0.02f, 0.005f));
	std::printf("Rope math scalar parity: %s, 40 cases x 32 steps\n", rope_backend_name());
}

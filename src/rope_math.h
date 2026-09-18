// ロープの速度積分と距離制約を計算する部品。
// 責務: Godotのノードや描画に依存せず、SIMDと通常処理の結果を揃える。
// 設計思想: 連続した粒子配列をその場で更新し、補助配列を作らない。
#ifndef SVG2D_ROPE_MATH_H
#define SVG2D_ROPE_MATH_H
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <algorithm>
#include <cmath>
#include <vector>

#if !defined(SVG2D_SCALAR) && !defined(REAL_T_IS_DOUBLE) && \
		(defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64))
#define SVG2D_ROPE_SSE2
#include <emmintrin.h>
#elif !defined(SVG2D_SCALAR) && !defined(REAL_T_IS_DOUBLE) && \
		defined(__aarch64__) && defined(__ARM_NEON)
#define SVG2D_ROPE_NEON
#include <arm_neon.h>
#endif

namespace svg2d {
using godot::Vector2;
using godot::Vector3;

// 残りの粒子とSIMDを使えない環境を同じ式で積分する。
template <typename V>
static void integrate_scalar(std::vector<V> &points, std::vector<V> &previous,
		const V &gravity_step, float keep, size_t begin) {
	for (size_t i = begin; i < points.size(); i++) {
		V current = points[i];
		points[i] += (points[i] - previous[i]) * keep + gravity_step;
		previous[i] = current;
	}
}

// 2Dの連続したxy成分をまとめて積分する。
static void integrate_rope(std::vector<Vector2> &points, std::vector<Vector2> &previous,
		const Vector2 &gravity_step, float keep, size_t begin) {
	size_t i = begin;
#if defined(SVG2D_ROPE_SSE2)
	const __m128 k = _mm_set1_ps(keep);
	const __m128 g = _mm_set_ps(gravity_step.y, gravity_step.x,
			gravity_step.y, gravity_step.x);
	for (; i + 1 < points.size(); i += 2) {
		__m128 p = _mm_loadu_ps(&points[i].x);
		__m128 old = _mm_loadu_ps(&previous[i].x);
		__m128 next = _mm_add_ps(p, _mm_add_ps(_mm_mul_ps(_mm_sub_ps(p, old), k), g));
		_mm_storeu_ps(&previous[i].x, p);
		_mm_storeu_ps(&points[i].x, next);
	}
#elif defined(SVG2D_ROPE_NEON)
	const float32x4_t k = vdupq_n_f32(keep);
	const float32_t gv[4] = { gravity_step.x, gravity_step.y,
			gravity_step.x, gravity_step.y };
	const float32x4_t g = vld1q_f32(gv);
	for (; i + 1 < points.size(); i += 2) {
		float32x4_t p = vld1q_f32(&points[i].x);
		float32x4_t old = vld1q_f32(&previous[i].x);
		float32x4_t next = vaddq_f32(p, vaddq_f32(vmulq_f32(vsubq_f32(p, old), k), g));
		vst1q_f32(&previous[i].x, p);
		vst1q_f32(&points[i].x, next);
	}
#endif
	integrate_scalar(points, previous, gravity_step, keep, i);
}

// 3Dの連続したxyz成分をまとめて積分する。
static void integrate_rope(std::vector<Vector3> &points, std::vector<Vector3> &previous,
		const Vector3 &gravity_step, float keep, size_t begin) {
	size_t i = begin;
#if defined(SVG2D_ROPE_NEON) || defined(SVG2D_ROPE_SSE2)
	// 4点のxyzを連続した12成分として処理し、軸ごとの並べ替えを省く。
	static_assert(sizeof(Vector3) == 3 * sizeof(float));
	const float g[12] = {gravity_step.x, gravity_step.y, gravity_step.z,
		gravity_step.x, gravity_step.y, gravity_step.z, gravity_step.x,
		gravity_step.y, gravity_step.z, gravity_step.x, gravity_step.y, gravity_step.z};
#if defined(SVG2D_ROPE_NEON)
	const float32x4_t k = vdupq_n_f32(keep);
#else
	const __m128 k = _mm_set1_ps(keep);
#endif
	for (; i + 3 < points.size(); i += 4) {
		float *p = &points[i].x, *old = &previous[i].x;
		for (int at = 0; at < 12; at += 4) {
#if defined(SVG2D_ROPE_NEON)
			float32x4_t v = vld1q_f32(p + at), prev = vld1q_f32(old + at);
			float32x4_t next = vaddq_f32(v, vaddq_f32(vmulq_f32(vsubq_f32(v, prev), k), vld1q_f32(g + at)));
			vst1q_f32(old + at, v); vst1q_f32(p + at, next);
#else
			__m128 v = _mm_loadu_ps(p + at), prev = _mm_loadu_ps(old + at);
			__m128 next = _mm_add_ps(v, _mm_add_ps(_mm_mul_ps(_mm_sub_ps(v, prev), k), _mm_loadu_ps(g + at)));
			_mm_storeu_ps(old + at, v); _mm_storeu_ps(p + at, next);
#endif
		}
	}
#endif
	integrate_scalar(points, previous, gravity_step, keep, i);
}

// 実際に使う積分経路を検証と診断へ返す。
static const char *rope_backend_name() {
#if defined(SVG2D_ROPE_NEON)
	return "neon";
#elif defined(SVG2D_ROPE_SSE2)
	return "sse2";
#else
	return "scalar";
#endif
}

// 伸びた辺だけ補正し、固定端から最大長を保証する。
template <typename V>
static void solve_rope(std::vector<V> &points, const V &anchor, bool pin_start,
		int iterations, double elasticity, double length, const double *coords = nullptr) {
	if (points.size() < 2) return;
	double uniform = length / (double)(points.size() - 1);
	float stiffness = (float)std::clamp(elasticity, 0.0, 1.0);
	for (int pass = 0; stiffness > 0.0f && pass < iterations; pass++) {
		bool changed = false; // 制約を全て満たしたら反復を終える
		if (pin_start) points[0] = anchor;
		for (size_t i = 0; i + 1 < points.size(); i++) {
			double link = coords ? length * (coords[i + 1] - coords[i]) : uniform;
			double link_squared = link * link; // 伸びていない辺の平方根を省く
			V delta_p = points[i + 1] - points[i];
			double squared = delta_p.length_squared();
			if (squared <= link_squared || squared <= 1e-18) continue;
			double distance = std::sqrt(squared);
			changed = true;
			V correction = delta_p * (float)(((distance - link) / distance) * stiffness);
			if (pin_start && i == 0) {
				points[i + 1] -= correction;
			} else {
				points[i] += correction * 0.5f;
				points[i + 1] -= correction * 0.5f;
			}
		}
		if (!changed) break;
	}
	// 弾性補正の反復誤差が残っても「最大長」だけは越えないよう、固定端から
	// 各子を順にクランプする。前のリンクを再び伸ばさない順序なので1回で確定する。
	if (pin_start) {
		points[0] = anchor;
		for (size_t i = 0; i + 1 < points.size(); i++) {
			double link = coords ? length * (coords[i + 1] - coords[i]) : uniform;
			double link_squared = link * link; // 伸びていない辺の平方根を省く
			V delta_p = points[i + 1] - points[i];
			double squared = delta_p.length_squared();
			if (squared > link_squared && squared > 1e-18)
				points[i + 1] = points[i] + delta_p * (float)(link / std::sqrt(squared));
		}
	}
}

} // namespace svg2d
#endif

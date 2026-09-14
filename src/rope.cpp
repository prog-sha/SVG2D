#include "rope.h"

#include <godot_cpp/classes/base_material3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <algorithm>
#include <cmath>

#if !defined(SVG2D_SCALAR) && !defined(REAL_T_IS_DOUBLE) && \
		(defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64))
#define SVG2D_ROPE_SSE2
#include <emmintrin.h>
#elif !defined(SVG2D_SCALAR) && !defined(REAL_T_IS_DOUBLE) && \
		defined(__aarch64__) && defined(__ARM_NEON)
#define SVG2D_ROPE_NEON
#include <arm_neon.h>
#endif

using namespace godot;

namespace svg2d {

template <typename V>
static void integrate_scalar(std::vector<V> &points, std::vector<V> &previous,
		const V &gravity_step, float keep, size_t begin) {
	for (size_t i = begin; i < points.size(); i++) {
		V current = points[i];
		points[i] += (points[i] - previous[i]) * keep + gravity_step;
		previous[i] = current;
	}
}

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

static void integrate_rope(std::vector<Vector3> &points, std::vector<Vector3> &previous,
		const Vector3 &gravity_step, float keep, size_t begin) {
	size_t i = begin;
#if defined(SVG2D_ROPE_NEON)
	const float32x4_t k = vdupq_n_f32(keep);
	const float32x4_t gx = vdupq_n_f32(gravity_step.x);
	const float32x4_t gy = vdupq_n_f32(gravity_step.y);
	const float32x4_t gz = vdupq_n_f32(gravity_step.z);
	for (; i + 3 < points.size(); i += 4) {
		float32x4x3_t p = vld3q_f32(&points[i].x);
		float32x4x3_t old = vld3q_f32(&previous[i].x);
		float32x4x3_t next;
		next.val[0] = vaddq_f32(p.val[0], vaddq_f32(vmulq_f32(vsubq_f32(p.val[0], old.val[0]), k), gx));
		next.val[1] = vaddq_f32(p.val[1], vaddq_f32(vmulq_f32(vsubq_f32(p.val[1], old.val[1]), k), gy));
		next.val[2] = vaddq_f32(p.val[2], vaddq_f32(vmulq_f32(vsubq_f32(p.val[2], old.val[2]), k), gz));
		vst3q_f32(&previous[i].x, p);
		vst3q_f32(&points[i].x, next);
	}
#elif defined(SVG2D_ROPE_SSE2)
	const __m128 k = _mm_set1_ps(keep);
	const __m128 gx = _mm_set1_ps(gravity_step.x), gy = _mm_set1_ps(gravity_step.y);
	const __m128 gz = _mm_set1_ps(gravity_step.z);
	for (; i + 3 < points.size(); i += 4) {
		__m128 px = _mm_set_ps(points[i + 3].x, points[i + 2].x, points[i + 1].x, points[i].x);
		__m128 py = _mm_set_ps(points[i + 3].y, points[i + 2].y, points[i + 1].y, points[i].y);
		__m128 pz = _mm_set_ps(points[i + 3].z, points[i + 2].z, points[i + 1].z, points[i].z);
		__m128 ox = _mm_set_ps(previous[i + 3].x, previous[i + 2].x, previous[i + 1].x, previous[i].x);
		__m128 oy = _mm_set_ps(previous[i + 3].y, previous[i + 2].y, previous[i + 1].y, previous[i].y);
		__m128 oz = _mm_set_ps(previous[i + 3].z, previous[i + 2].z, previous[i + 1].z, previous[i].z);
		__m128 nx = _mm_add_ps(px, _mm_add_ps(_mm_mul_ps(_mm_sub_ps(px, ox), k), gx));
		__m128 ny = _mm_add_ps(py, _mm_add_ps(_mm_mul_ps(_mm_sub_ps(py, oy), k), gy));
		__m128 nz = _mm_add_ps(pz, _mm_add_ps(_mm_mul_ps(_mm_sub_ps(pz, oz), k), gz));
		float xs[4], ys[4], zs[4];
		_mm_storeu_ps(xs, nx); _mm_storeu_ps(ys, ny); _mm_storeu_ps(zs, nz);
		for (int lane = 0; lane < 4; lane++) {
			previous[i + (size_t)lane] = points[i + (size_t)lane];
			points[i + (size_t)lane] = Vector3(xs[lane], ys[lane], zs[lane]);
		}
	}
#endif
	integrate_scalar(points, previous, gravity_step, keep, i);
}

static const char *rope_backend_name() {
#if defined(SVG2D_ROPE_NEON)
	return "neon";
#elif defined(SVG2D_ROPE_SSE2)
	return "sse2";
#else
	return "scalar";
#endif
}

template <typename V>
static void solve_rope(std::vector<V> &points, const V &anchor, bool pin_start,
		int iterations, double elasticity, double length) {
	if (points.size() < 2) return;
	double link = length / (double)(points.size() - 1);
	float stiffness = (float)std::clamp(elasticity, 0.0, 1.0);
	for (int pass = 0; pass < iterations; pass++) {
		if (pin_start) points[0] = anchor;
		for (size_t i = 0; i + 1 < points.size(); i++) {
			V delta_p = points[i + 1] - points[i];
			double distance = delta_p.length();
			if (distance <= link || distance <= 1e-9) continue;
			V correction = delta_p * (float)(((distance - link) / distance) * stiffness);
			if (pin_start && i == 0) {
				points[i + 1] -= correction;
			} else {
				points[i] += correction * 0.5f;
				points[i + 1] -= correction * 0.5f;
			}
		}
	}
	// 弾性補正の反復誤差が残っても「最大長」だけは越えないよう、固定端から
	// 各子を順にクランプする。前のリンクを再び伸ばさない順序なので1回で確定する。
	if (pin_start) {
		points[0] = anchor;
		for (size_t i = 0; i + 1 < points.size(); i++) {
			V delta_p = points[i + 1] - points[i];
			double distance = delta_p.length();
			if (distance > link && distance > 1e-9)
				points[i + 1] = points[i] + delta_p * (float)(link / distance);
		}
	}
}

static Vector2 rope_side_2d(const std::vector<Vector2> &points, size_t i) {
	Vector2 tangent;
	if (i == 0) tangent = points[1] - points[0];
	else if (i + 1 == points.size()) tangent = points[i] - points[i - 1];
	else tangent = points[i + 1] - points[i - 1];
	if (tangent.length_squared() <= 1e-12f) return Vector2(-1, 0);
	tangent.normalize();
	return Vector2(-tangent.y, tangent.x);
}

static Vector3 rope_side_3d(const std::vector<Vector3> &points, size_t i) {
	Vector3 tangent;
	if (i == 0) tangent = points[1] - points[0];
	else if (i + 1 == points.size()) tangent = points[i] - points[i - 1];
	else tangent = points[i + 1] - points[i - 1];
	if (tangent.length_squared() <= 1e-12f) return Vector3(-1, 0, 0);
	tangent.normalize();
	Vector3 side = tangent.cross(Vector3(0, 0, 1));
	if (side.length_squared() <= 1e-12f) side = tangent.cross(Vector3(0, 1, 0));
	return side.normalized();
}

SpriteRope2D::SpriteRope2D() { set_physics_process(true); }

Vector2 SpriteRope2D::_visual_size() const { return _texture.is_valid() ? _texture->get_size() : Vector2(); }

double SpriteRope2D::_effective_length() const {
	if (_max_length > 0.0) return _max_length;
	Vector2 size = _visual_size();
	return size.y > 0.0f ? size.y : 200.0;
}

void SpriteRope2D::reset_simulation() {
	_points.resize((size_t)_segments);
	_previous.resize((size_t)_segments);
	double length = _effective_length();
	for (int i = 0; i < _segments; i++) {
		float t = (float)i / (float)(_segments - 1);
		_points[(size_t)i] = Vector2(0, (float)(length * t));
		_previous[(size_t)i] = _points[(size_t)i];
	}
	queue_redraw();
}

void SpriteRope2D::_ready() { reset_simulation(); }

void SpriteRope2D::_simulate(double delta) {
	if (_points.size() != (size_t)_segments) reset_simulation();
	if (_previous.size() != _points.size()) reset_simulation();
	Vector2 anchor = _points[0];
	double dt = std::min(std::max(delta, 0.0), 1.0 / 30.0);
	float keep = (float)(1.0 - _damping);
	integrate_rope(_points, _previous, _gravity * (float)(dt * dt), keep,
			_pin_start ? 1u : 0u);
	solve_rope(_points, anchor, _pin_start, _constraint_iterations, _elasticity,
			_effective_length());
}

void SpriteRope2D::_physics_process(double delta) {
	if (!_simulation_enabled || Engine::get_singleton()->is_editor_hint()) return;
	if (!_line_mode && _texture.is_null()) return;
	_simulate(delta);
	queue_redraw();
}

void SpriteRope2D::_draw() {
	if (_points.size() < 2) reset_simulation();
	PackedVector2Array center;
	center.resize((int)_points.size());
	for (int i = 0; i < (int)_points.size(); i++) center.set(i, _points[(size_t)i]);
	if (_line_mode) {
		draw_polyline(center, _line_color, (float)_line_width, true);
		return;
	}
	Vector2 size = _visual_size();
	Ref<Texture2D> texture = _texture;
	if (texture.is_null() || size.x <= 0.0f || size.y <= 0.0f) return;
	float half = size.x * 0.5f;
	PackedColorArray colors;
	colors.push_back(Color(1, 1, 1, 1));
	for (size_t i = 0; i + 1 < _points.size(); i++) {
		float v0 = (float)i / (float)(_points.size() - 1);
		float v1 = (float)(i + 1) / (float)(_points.size() - 1);
		Vector2 s0 = rope_side_2d(_points, i) * half;
		Vector2 s1 = rope_side_2d(_points, i + 1) * half;
		Vector2 left0 = _points[i] + s0, right0 = _points[i] - s0;
		Vector2 left1 = _points[i + 1] + s1, right1 = _points[i + 1] - s1;
		PackedVector2Array triangle, uv;
		triangle.push_back(left0); triangle.push_back(right0); triangle.push_back(left1);
		uv.push_back(Vector2(0, v0)); uv.push_back(Vector2(1, v0)); uv.push_back(Vector2(0, v1));
		draw_primitive(triangle, colors, uv, texture);
		triangle.clear(); uv.clear();
		triangle.push_back(right0); triangle.push_back(right1); triangle.push_back(left1);
		uv.push_back(Vector2(1, v0)); uv.push_back(Vector2(1, v1)); uv.push_back(Vector2(0, v1));
		draw_primitive(triangle, colors, uv, texture);
	}
}

void SpriteRope2D::set_texture(const Ref<Texture2D> &texture) { if (_texture != texture) { _texture = texture; reset_simulation(); } }
void SpriteRope2D::set_line_mode(bool enabled) { if (_line_mode != enabled) { _line_mode = enabled; reset_simulation(); } }
void SpriteRope2D::set_simulation_enabled(bool enabled) { _simulation_enabled = enabled; set_physics_process(enabled); }
void SpriteRope2D::set_pin_start(bool enabled) { if (_pin_start != enabled) { _pin_start = enabled; reset_simulation(); } }
void SpriteRope2D::set_segments(int value) { value = std::clamp(value, 2, 256); if (_segments != value) { _segments = value; reset_simulation(); } }
void SpriteRope2D::set_constraint_iterations(int value) { _constraint_iterations = std::clamp(value, 1, 64); }
void SpriteRope2D::set_max_length(double value) { value = std::isfinite(value) ? std::max(0.0, value) : 0.0; if (_max_length != value) { _max_length = value; reset_simulation(); } }
void SpriteRope2D::set_elasticity(double value) { _elasticity = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.9; }
void SpriteRope2D::set_damping(double value) { _damping = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.02; }
void SpriteRope2D::set_gravity(const Vector2 &value) { _gravity = value; }
void SpriteRope2D::set_line_width(double value) { _line_width = std::isfinite(value) ? std::max(0.1, value) : 4.0; queue_redraw(); }
void SpriteRope2D::set_line_color(const Color &value) { _line_color = value; queue_redraw(); }

PackedVector2Array SpriteRope2D::get_rope_points() const {
	PackedVector2Array out;
	out.resize((int)_points.size());
	for (int i = 0; i < (int)_points.size(); i++) out.set(i, _points[(size_t)i]);
	return out;
}

String SpriteRope2D::get_simulation_backend() const { return rope_backend_name(); }

void SpriteRope2D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_texture", "texture"), &SpriteRope2D::set_texture);
	ClassDB::bind_method(D_METHOD("get_texture"), &SpriteRope2D::get_texture);
	ClassDB::bind_method(D_METHOD("set_line_mode", "enabled"), &SpriteRope2D::set_line_mode);
	ClassDB::bind_method(D_METHOD("is_line_mode"), &SpriteRope2D::is_line_mode);
	ClassDB::bind_method(D_METHOD("set_simulation_enabled", "enabled"), &SpriteRope2D::set_simulation_enabled);
	ClassDB::bind_method(D_METHOD("is_simulation_enabled"), &SpriteRope2D::is_simulation_enabled);
	ClassDB::bind_method(D_METHOD("set_pin_start", "enabled"), &SpriteRope2D::set_pin_start);
	ClassDB::bind_method(D_METHOD("is_pin_start"), &SpriteRope2D::is_pin_start);
	ClassDB::bind_method(D_METHOD("set_segments", "segments"), &SpriteRope2D::set_segments);
	ClassDB::bind_method(D_METHOD("get_segments"), &SpriteRope2D::get_segments);
	ClassDB::bind_method(D_METHOD("set_constraint_iterations", "iterations"), &SpriteRope2D::set_constraint_iterations);
	ClassDB::bind_method(D_METHOD("get_constraint_iterations"), &SpriteRope2D::get_constraint_iterations);
	ClassDB::bind_method(D_METHOD("set_max_length", "length"), &SpriteRope2D::set_max_length);
	ClassDB::bind_method(D_METHOD("get_max_length"), &SpriteRope2D::get_max_length);
	ClassDB::bind_method(D_METHOD("set_elasticity", "elasticity"), &SpriteRope2D::set_elasticity);
	ClassDB::bind_method(D_METHOD("get_elasticity"), &SpriteRope2D::get_elasticity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &SpriteRope2D::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &SpriteRope2D::get_damping);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &SpriteRope2D::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &SpriteRope2D::get_gravity);
	ClassDB::bind_method(D_METHOD("set_line_width", "width"), &SpriteRope2D::set_line_width);
	ClassDB::bind_method(D_METHOD("get_line_width"), &SpriteRope2D::get_line_width);
	ClassDB::bind_method(D_METHOD("set_line_color", "color"), &SpriteRope2D::set_line_color);
	ClassDB::bind_method(D_METHOD("get_line_color"), &SpriteRope2D::get_line_color);
	ClassDB::bind_method(D_METHOD("reset_simulation"), &SpriteRope2D::reset_simulation);
	ClassDB::bind_method(D_METHOD("get_rope_points"), &SpriteRope2D::get_rope_points);
	ClassDB::bind_method(D_METHOD("get_simulation_backend"), &SpriteRope2D::get_simulation_backend);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "texture", PROPERTY_HINT_RESOURCE_TYPE, "Texture2D"), "set_texture", "get_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "line_mode"), "set_line_mode", "is_line_mode");
	ADD_GROUP("Simulation", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "simulation_enabled"), "set_simulation_enabled", "is_simulation_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "pin_start"), "set_pin_start", "is_pin_start");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "segments", PROPERTY_HINT_RANGE, "2,256,1"), "set_segments", "get_segments");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_length", PROPERTY_HINT_RANGE, "0,100000,0.1,or_greater"), "set_max_length", "get_max_length");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "elasticity", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_elasticity", "get_elasticity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping", PROPERTY_HINT_RANGE, "0,1,0.001"), "set_damping", "get_damping");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "gravity"), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "constraint_iterations", PROPERTY_HINT_RANGE, "1,64,1"), "set_constraint_iterations", "get_constraint_iterations");
	ADD_GROUP("Line", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "line_width", PROPERTY_HINT_RANGE, "0.1,1000,0.1,or_greater"), "set_line_width", "get_line_width");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "line_color"), "set_line_color", "get_line_color");
}

Vector2 SVGRope2D::_visual_size() const { return _svg.draw_size(); }

void SVGRope2D::_validate_property(PropertyInfo &property) const {
	// SVG専用ノードでは生成物のtextureを編集させず、srcだけを素材入口にする。
	if (property.name == StringName("texture")) property.usage = PROPERTY_USAGE_NONE;
}

void SVGRope2D::set_src(const String &src) {
	_svg.set_src(src);
	// SVGは原寸の1.5倍で一度だけラスタ化する。PBD更新中は同じ素材を再利用する。
	SpriteRope2D::set_texture(_svg.get_texture(Vector2(1.5f, 1.5f)));
}

void SVGRope2D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_src", "src"), &SVGRope2D::set_src);
	ClassDB::bind_method(D_METHOD("get_src"), &SVGRope2D::get_src);
	ClassDB::bind_method(D_METHOD("get_svg_size"), &SVGRope2D::get_svg_size);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "src", PROPERTY_HINT_FILE, "*.svg"), "set_src", "get_src");
}

SpriteRope3D::SpriteRope3D() { set_physics_process(true); }

Vector2 SpriteRope3D::_visual_size() const { return _texture.is_valid() ? _texture->get_size() : Vector2(); }

double SpriteRope3D::_effective_length() const {
	if (_max_length > 0.0) return _max_length;
	Vector2 size = _visual_size();
	return size.y > 0.0f ? size.y * _pixel_size : 2.0;
}

void SpriteRope3D::_ensure_mesh() {
	if (_mesh_instance != nullptr) return;
	_mesh.instantiate();
	_material.instantiate();
	_material->set_shading_mode(BaseMaterial3D::SHADING_MODE_UNSHADED);
	_material->set_transparency(BaseMaterial3D::TRANSPARENCY_ALPHA);
	_material->set_cull_mode(BaseMaterial3D::CULL_DISABLED);
	_material->set_texture_filter(BaseMaterial3D::TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC);
	_mesh_instance = memnew(MeshInstance3D);
	_mesh_instance->set_name("RopeMesh");
	_mesh_instance->set_mesh(_mesh);
	add_child(_mesh_instance, false, Node::INTERNAL_MODE_BACK);
}

void SpriteRope3D::reset_simulation() {
	_points.resize((size_t)_segments);
	_previous.resize((size_t)_segments);
	double length = _effective_length();
	for (int i = 0; i < _segments; i++) {
		float t = (float)i / (float)(_segments - 1);
		_points[(size_t)i] = Vector3(0, (float)(-length * t), 0);
		_previous[(size_t)i] = _points[(size_t)i];
	}
	if (is_inside_tree()) _update_mesh();
}

void SpriteRope3D::_ready() { reset_simulation(); }

void SpriteRope3D::_simulate(double delta) {
	if (_points.size() != (size_t)_segments) reset_simulation();
	if (_previous.size() != _points.size()) reset_simulation();
	Vector3 anchor = _points[0];
	double dt = std::min(std::max(delta, 0.0), 1.0 / 30.0);
	float keep = (float)(1.0 - _damping);
	integrate_rope(_points, _previous, _gravity * (float)(dt * dt), keep,
			_pin_start ? 1u : 0u);
	solve_rope(_points, anchor, _pin_start, _constraint_iterations, _elasticity,
			_effective_length());
}

void SpriteRope3D::_update_mesh() {
	_ensure_mesh();
	_mesh->clear_surfaces();
	if (_points.size() < 2) return;
	Vector2 visual_size = _visual_size();
	Ref<Texture2D> texture;
	float half;
	if (_line_mode) {
		half = (float)(_line_width * 0.5);
		_material->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, Ref<Texture2D>());
		_material->set_albedo(_line_color);
	} else {
		texture = _texture;
		if (texture.is_null() || visual_size.x <= 0.0f || visual_size.y <= 0.0f) return;
		half = (float)(visual_size.x * _pixel_size * 0.5);
		_material->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, texture);
		_material->set_albedo(_modulate);
	}
	PackedVector3Array vertices;
	PackedVector2Array uvs;
	vertices.resize((int)_points.size() * 2);
	uvs.resize((int)_points.size() * 2);
	for (int i = 0; i < (int)_points.size(); i++) {
		Vector3 side = rope_side_3d(_points, (size_t)i) * half;
		float v = (float)i / (float)(_points.size() - 1);
		vertices.set(i * 2, _points[(size_t)i] + side);
		vertices.set(i * 2 + 1, _points[(size_t)i] - side);
		uvs.set(i * 2, Vector2(0, v));
		uvs.set(i * 2 + 1, Vector2(1, v));
	}
	PackedInt32Array indices;
	indices.resize(((int)_points.size() - 1) * 6);
	for (int i = 0; i + 1 < (int)_points.size(); i++) {
		int at = i * 6, row = i * 2;
		indices.set(at, row); indices.set(at + 1, row + 1); indices.set(at + 2, row + 2);
		indices.set(at + 3, row + 1); indices.set(at + 4, row + 3); indices.set(at + 5, row + 2);
	}
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = vertices;
	arrays[Mesh::ARRAY_TEX_UV] = uvs;
	arrays[Mesh::ARRAY_INDEX] = indices;
	_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
	_mesh->surface_set_material(0, _material);
}

void SpriteRope3D::_physics_process(double delta) {
	if (!_simulation_enabled || Engine::get_singleton()->is_editor_hint()) return;
	if (!_line_mode && _texture.is_null()) return;
	_simulate(delta);
	_update_mesh();
}

void SpriteRope3D::set_texture(const Ref<Texture2D> &texture) { if (_texture != texture) { _texture = texture; reset_simulation(); } }
void SpriteRope3D::set_line_mode(bool enabled) { if (_line_mode != enabled) { _line_mode = enabled; reset_simulation(); } }
void SpriteRope3D::set_simulation_enabled(bool enabled) { _simulation_enabled = enabled; set_physics_process(enabled); }
void SpriteRope3D::set_pin_start(bool enabled) { if (_pin_start != enabled) { _pin_start = enabled; reset_simulation(); } }
void SpriteRope3D::set_segments(int value) { value = std::clamp(value, 2, 256); if (_segments != value) { _segments = value; reset_simulation(); } }
void SpriteRope3D::set_constraint_iterations(int value) { _constraint_iterations = std::clamp(value, 1, 64); }
void SpriteRope3D::set_max_length(double value) { value = std::isfinite(value) ? std::max(0.0, value) : 0.0; if (_max_length != value) { _max_length = value; reset_simulation(); } }
void SpriteRope3D::set_elasticity(double value) { _elasticity = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.9; }
void SpriteRope3D::set_damping(double value) { _damping = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.02; }
void SpriteRope3D::set_gravity(const Vector3 &value) { _gravity = value; }
void SpriteRope3D::set_line_width(double value) { _line_width = std::isfinite(value) ? std::max(0.0001, value) : 0.04; _update_mesh(); }
void SpriteRope3D::set_line_color(const Color &value) { _line_color = value; _update_mesh(); }
void SpriteRope3D::set_pixel_size(double value) { value = std::isfinite(value) ? std::max(0.0001, value) : 0.01; if (_pixel_size != value) { _pixel_size = value; reset_simulation(); } }
void SpriteRope3D::set_modulate(const Color &value) { _modulate = value; _update_mesh(); }

PackedVector3Array SpriteRope3D::get_rope_points() const {
	PackedVector3Array out;
	out.resize((int)_points.size());
	for (int i = 0; i < (int)_points.size(); i++) out.set(i, _points[(size_t)i]);
	return out;
}

String SpriteRope3D::get_simulation_backend() const { return rope_backend_name(); }

void SpriteRope3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_texture", "texture"), &SpriteRope3D::set_texture);
	ClassDB::bind_method(D_METHOD("get_texture"), &SpriteRope3D::get_texture);
	ClassDB::bind_method(D_METHOD("set_line_mode", "enabled"), &SpriteRope3D::set_line_mode);
	ClassDB::bind_method(D_METHOD("is_line_mode"), &SpriteRope3D::is_line_mode);
	ClassDB::bind_method(D_METHOD("set_simulation_enabled", "enabled"), &SpriteRope3D::set_simulation_enabled);
	ClassDB::bind_method(D_METHOD("is_simulation_enabled"), &SpriteRope3D::is_simulation_enabled);
	ClassDB::bind_method(D_METHOD("set_pin_start", "enabled"), &SpriteRope3D::set_pin_start);
	ClassDB::bind_method(D_METHOD("is_pin_start"), &SpriteRope3D::is_pin_start);
	ClassDB::bind_method(D_METHOD("set_segments", "segments"), &SpriteRope3D::set_segments);
	ClassDB::bind_method(D_METHOD("get_segments"), &SpriteRope3D::get_segments);
	ClassDB::bind_method(D_METHOD("set_constraint_iterations", "iterations"), &SpriteRope3D::set_constraint_iterations);
	ClassDB::bind_method(D_METHOD("get_constraint_iterations"), &SpriteRope3D::get_constraint_iterations);
	ClassDB::bind_method(D_METHOD("set_max_length", "length"), &SpriteRope3D::set_max_length);
	ClassDB::bind_method(D_METHOD("get_max_length"), &SpriteRope3D::get_max_length);
	ClassDB::bind_method(D_METHOD("set_elasticity", "elasticity"), &SpriteRope3D::set_elasticity);
	ClassDB::bind_method(D_METHOD("get_elasticity"), &SpriteRope3D::get_elasticity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &SpriteRope3D::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &SpriteRope3D::get_damping);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &SpriteRope3D::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &SpriteRope3D::get_gravity);
	ClassDB::bind_method(D_METHOD("set_line_width", "width"), &SpriteRope3D::set_line_width);
	ClassDB::bind_method(D_METHOD("get_line_width"), &SpriteRope3D::get_line_width);
	ClassDB::bind_method(D_METHOD("set_line_color", "color"), &SpriteRope3D::set_line_color);
	ClassDB::bind_method(D_METHOD("get_line_color"), &SpriteRope3D::get_line_color);
	ClassDB::bind_method(D_METHOD("set_pixel_size", "size"), &SpriteRope3D::set_pixel_size);
	ClassDB::bind_method(D_METHOD("get_pixel_size"), &SpriteRope3D::get_pixel_size);
	ClassDB::bind_method(D_METHOD("set_modulate", "color"), &SpriteRope3D::set_modulate);
	ClassDB::bind_method(D_METHOD("get_modulate"), &SpriteRope3D::get_modulate);
	ClassDB::bind_method(D_METHOD("reset_simulation"), &SpriteRope3D::reset_simulation);
	ClassDB::bind_method(D_METHOD("get_rope_points"), &SpriteRope3D::get_rope_points);
	ClassDB::bind_method(D_METHOD("get_simulation_backend"), &SpriteRope3D::get_simulation_backend);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "texture", PROPERTY_HINT_RESOURCE_TYPE, "Texture2D"), "set_texture", "get_texture");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "line_mode"), "set_line_mode", "is_line_mode");
	ADD_GROUP("Simulation", "");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "simulation_enabled"), "set_simulation_enabled", "is_simulation_enabled");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "pin_start"), "set_pin_start", "is_pin_start");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "segments", PROPERTY_HINT_RANGE, "2,256,1"), "set_segments", "get_segments");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "max_length", PROPERTY_HINT_RANGE, "0,100000,0.01,or_greater"), "set_max_length", "get_max_length");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "elasticity", PROPERTY_HINT_RANGE, "0,1,0.01"), "set_elasticity", "get_elasticity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "damping", PROPERTY_HINT_RANGE, "0,1,0.001"), "set_damping", "get_damping");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "constraint_iterations", PROPERTY_HINT_RANGE, "1,64,1"), "set_constraint_iterations", "get_constraint_iterations");
	ADD_GROUP("Appearance", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "pixel_size", PROPERTY_HINT_RANGE, "0.0001,10,0.0001,or_greater"), "set_pixel_size", "get_pixel_size");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "modulate"), "set_modulate", "get_modulate");
	ADD_GROUP("Line", "");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "line_width", PROPERTY_HINT_RANGE, "0.0001,100,0.001,or_greater"), "set_line_width", "get_line_width");
	ADD_PROPERTY(PropertyInfo(Variant::COLOR, "line_color"), "set_line_color", "get_line_color");
}

Vector2 SVGRope3D::_visual_size() const { return _svg.draw_size(); }

void SVGRope3D::_validate_property(PropertyInfo &property) const {
	if (property.name == StringName("texture")) property.usage = PROPERTY_USAGE_NONE;
}

void SVGRope3D::set_src(const String &src) {
	_svg.set_src(src);
	SpriteRope3D::set_texture(_svg.get_texture(Vector2(1.5f, 1.5f), 0, true));
}

void SVGRope3D::set_pixel_size(double value) {
	SpriteRope3D::set_pixel_size(value);
}

void SVGRope3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_src", "src"), &SVGRope3D::set_src);
	ClassDB::bind_method(D_METHOD("get_src"), &SVGRope3D::get_src);
	ClassDB::bind_method(D_METHOD("get_svg_size"), &SVGRope3D::get_svg_size);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "src", PROPERTY_HINT_FILE, "*.svg"), "set_src", "get_src");
}

} // namespace svg2d

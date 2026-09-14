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

using namespace godot;

namespace svg2d {

template <typename V>
static void solve_rope(std::vector<V> &points, std::vector<V> &previous, const V &gravity,
		double delta, bool pin_start, int iterations, double elasticity, double length) {
	if (points.size() < 2 || previous.size() != points.size()) return;
	double dt = std::min(std::max(delta, 0.0), 1.0 / 30.0);
	for (size_t i = pin_start ? 1 : 0; i < points.size(); i++) {
		V current = points[i];
		points[i] += (points[i] - previous[i]) + gravity * (float)(dt * dt);
		previous[i] = current;
	}
	V anchor = points[0];
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

SVGRope2D::SVGRope2D() { set_physics_process(true); }

double SVGRope2D::_effective_length() const {
	if (_max_length > 0.0) return _max_length;
	Vector2 size = _svg.draw_size();
	return size.y > 0.0f ? size.y : 200.0;
}

void SVGRope2D::reset_simulation() {
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

void SVGRope2D::_ready() { reset_simulation(); }

void SVGRope2D::_simulate(double delta) {
	if (_points.size() != (size_t)_segments) reset_simulation();
	// Verletの速度を減衰してからPBD距離制約へ渡す。
	float keep = (float)(1.0 - _damping);
	for (size_t i = _pin_start ? 1 : 0; i < _points.size(); i++)
		_previous[i] = _points[i] - (_points[i] - _previous[i]) * keep;
	solve_rope(_points, _previous, _gravity, delta, _pin_start, _constraint_iterations,
			_elasticity, _effective_length());
}

void SVGRope2D::_physics_process(double delta) {
	if (!_simulation_enabled || Engine::get_singleton()->is_editor_hint()) return;
	if (!_line_mode && _svg.draw_size().x <= 0.0f) return;
	_simulate(delta);
	queue_redraw();
}

void SVGRope2D::_draw() {
	if (_points.size() < 2) reset_simulation();
	PackedVector2Array center;
	center.resize((int)_points.size());
	for (int i = 0; i < (int)_points.size(); i++) center.set(i, _points[(size_t)i]);
	if (_line_mode) {
		draw_polyline(center, _line_color, (float)_line_width, true);
		return;
	}
	Vector2 size = _svg.draw_size();
	Ref<Texture2D> texture = _svg.get_texture(Vector2(1.5f, 1.5f));
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

void SVGRope2D::set_src(const String &src) { _svg.set_src(src); reset_simulation(); }
void SVGRope2D::set_line_mode(bool enabled) { if (_line_mode != enabled) { _line_mode = enabled; reset_simulation(); } }
void SVGRope2D::set_simulation_enabled(bool enabled) { _simulation_enabled = enabled; set_physics_process(enabled); }
void SVGRope2D::set_pin_start(bool enabled) { if (_pin_start != enabled) { _pin_start = enabled; reset_simulation(); } }
void SVGRope2D::set_segments(int value) { value = std::clamp(value, 2, 256); if (_segments != value) { _segments = value; reset_simulation(); } }
void SVGRope2D::set_constraint_iterations(int value) { _constraint_iterations = std::clamp(value, 1, 64); }
void SVGRope2D::set_max_length(double value) { value = std::isfinite(value) ? std::max(0.0, value) : 0.0; if (_max_length != value) { _max_length = value; reset_simulation(); } }
void SVGRope2D::set_elasticity(double value) { _elasticity = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.9; }
void SVGRope2D::set_damping(double value) { _damping = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.02; }
void SVGRope2D::set_gravity(const Vector2 &value) { _gravity = value; }
void SVGRope2D::set_line_width(double value) { _line_width = std::isfinite(value) ? std::max(0.1, value) : 4.0; queue_redraw(); }
void SVGRope2D::set_line_color(const Color &value) { _line_color = value; queue_redraw(); }

PackedVector2Array SVGRope2D::get_rope_points() const {
	PackedVector2Array out;
	out.resize((int)_points.size());
	for (int i = 0; i < (int)_points.size(); i++) out.set(i, _points[(size_t)i]);
	return out;
}

void SVGRope2D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_src", "src"), &SVGRope2D::set_src);
	ClassDB::bind_method(D_METHOD("get_src"), &SVGRope2D::get_src);
	ClassDB::bind_method(D_METHOD("set_line_mode", "enabled"), &SVGRope2D::set_line_mode);
	ClassDB::bind_method(D_METHOD("is_line_mode"), &SVGRope2D::is_line_mode);
	ClassDB::bind_method(D_METHOD("set_simulation_enabled", "enabled"), &SVGRope2D::set_simulation_enabled);
	ClassDB::bind_method(D_METHOD("is_simulation_enabled"), &SVGRope2D::is_simulation_enabled);
	ClassDB::bind_method(D_METHOD("set_pin_start", "enabled"), &SVGRope2D::set_pin_start);
	ClassDB::bind_method(D_METHOD("is_pin_start"), &SVGRope2D::is_pin_start);
	ClassDB::bind_method(D_METHOD("set_segments", "segments"), &SVGRope2D::set_segments);
	ClassDB::bind_method(D_METHOD("get_segments"), &SVGRope2D::get_segments);
	ClassDB::bind_method(D_METHOD("set_constraint_iterations", "iterations"), &SVGRope2D::set_constraint_iterations);
	ClassDB::bind_method(D_METHOD("get_constraint_iterations"), &SVGRope2D::get_constraint_iterations);
	ClassDB::bind_method(D_METHOD("set_max_length", "length"), &SVGRope2D::set_max_length);
	ClassDB::bind_method(D_METHOD("get_max_length"), &SVGRope2D::get_max_length);
	ClassDB::bind_method(D_METHOD("set_elasticity", "elasticity"), &SVGRope2D::set_elasticity);
	ClassDB::bind_method(D_METHOD("get_elasticity"), &SVGRope2D::get_elasticity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &SVGRope2D::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &SVGRope2D::get_damping);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &SVGRope2D::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &SVGRope2D::get_gravity);
	ClassDB::bind_method(D_METHOD("set_line_width", "width"), &SVGRope2D::set_line_width);
	ClassDB::bind_method(D_METHOD("get_line_width"), &SVGRope2D::get_line_width);
	ClassDB::bind_method(D_METHOD("set_line_color", "color"), &SVGRope2D::set_line_color);
	ClassDB::bind_method(D_METHOD("get_line_color"), &SVGRope2D::get_line_color);
	ClassDB::bind_method(D_METHOD("reset_simulation"), &SVGRope2D::reset_simulation);
	ClassDB::bind_method(D_METHOD("get_rope_points"), &SVGRope2D::get_rope_points);
	ClassDB::bind_method(D_METHOD("get_svg_size"), &SVGRope2D::get_svg_size);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "src", PROPERTY_HINT_FILE, "*.svg"), "set_src", "get_src");
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

SVGRope3D::SVGRope3D() { set_physics_process(true); }

double SVGRope3D::_effective_length() const {
	if (_max_length > 0.0) return _max_length;
	Vector2 size = _svg.draw_size();
	return size.y > 0.0f ? size.y * _pixel_size : 2.0;
}

void SVGRope3D::_ensure_mesh() {
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

void SVGRope3D::reset_simulation() {
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

void SVGRope3D::_ready() { reset_simulation(); }

void SVGRope3D::_simulate(double delta) {
	if (_points.size() != (size_t)_segments) reset_simulation();
	float keep = (float)(1.0 - _damping);
	for (size_t i = _pin_start ? 1 : 0; i < _points.size(); i++)
		_previous[i] = _points[i] - (_points[i] - _previous[i]) * keep;
	solve_rope(_points, _previous, _gravity, delta, _pin_start, _constraint_iterations,
			_elasticity, _effective_length());
}

void SVGRope3D::_update_mesh() {
	_ensure_mesh();
	_mesh->clear_surfaces();
	if (_points.size() < 2) return;
	Vector2 svg_size = _svg.draw_size();
	Ref<Texture2D> texture;
	float half;
	if (_line_mode) {
		half = (float)(_line_width * 0.5);
		_material->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, Ref<Texture2D>());
		_material->set_albedo(_line_color);
	} else {
		texture = _svg.get_texture(Vector2(1.5f, 1.5f), 0, true);
		if (texture.is_null() || svg_size.x <= 0.0f || svg_size.y <= 0.0f) return;
		half = (float)(svg_size.x * _pixel_size * 0.5);
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

void SVGRope3D::_physics_process(double delta) {
	if (!_simulation_enabled || Engine::get_singleton()->is_editor_hint()) return;
	if (!_line_mode && _svg.draw_size().x <= 0.0f) return;
	_simulate(delta);
	_update_mesh();
}

void SVGRope3D::set_src(const String &src) { _svg.set_src(src); reset_simulation(); }
void SVGRope3D::set_line_mode(bool enabled) { if (_line_mode != enabled) { _line_mode = enabled; reset_simulation(); } }
void SVGRope3D::set_simulation_enabled(bool enabled) { _simulation_enabled = enabled; set_physics_process(enabled); }
void SVGRope3D::set_pin_start(bool enabled) { if (_pin_start != enabled) { _pin_start = enabled; reset_simulation(); } }
void SVGRope3D::set_segments(int value) { value = std::clamp(value, 2, 256); if (_segments != value) { _segments = value; reset_simulation(); } }
void SVGRope3D::set_constraint_iterations(int value) { _constraint_iterations = std::clamp(value, 1, 64); }
void SVGRope3D::set_max_length(double value) { value = std::isfinite(value) ? std::max(0.0, value) : 0.0; if (_max_length != value) { _max_length = value; reset_simulation(); } }
void SVGRope3D::set_elasticity(double value) { _elasticity = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.9; }
void SVGRope3D::set_damping(double value) { _damping = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.02; }
void SVGRope3D::set_gravity(const Vector3 &value) { _gravity = value; }
void SVGRope3D::set_line_width(double value) { _line_width = std::isfinite(value) ? std::max(0.0001, value) : 0.04; _update_mesh(); }
void SVGRope3D::set_line_color(const Color &value) { _line_color = value; _update_mesh(); }
void SVGRope3D::set_pixel_size(double value) { value = std::isfinite(value) ? std::max(0.0001, value) : 0.01; if (_pixel_size != value) { _pixel_size = value; reset_simulation(); } }
void SVGRope3D::set_modulate(const Color &value) { _modulate = value; _update_mesh(); }

PackedVector3Array SVGRope3D::get_rope_points() const {
	PackedVector3Array out;
	out.resize((int)_points.size());
	for (int i = 0; i < (int)_points.size(); i++) out.set(i, _points[(size_t)i]);
	return out;
}

void SVGRope3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_src", "src"), &SVGRope3D::set_src);
	ClassDB::bind_method(D_METHOD("get_src"), &SVGRope3D::get_src);
	ClassDB::bind_method(D_METHOD("set_line_mode", "enabled"), &SVGRope3D::set_line_mode);
	ClassDB::bind_method(D_METHOD("is_line_mode"), &SVGRope3D::is_line_mode);
	ClassDB::bind_method(D_METHOD("set_simulation_enabled", "enabled"), &SVGRope3D::set_simulation_enabled);
	ClassDB::bind_method(D_METHOD("is_simulation_enabled"), &SVGRope3D::is_simulation_enabled);
	ClassDB::bind_method(D_METHOD("set_pin_start", "enabled"), &SVGRope3D::set_pin_start);
	ClassDB::bind_method(D_METHOD("is_pin_start"), &SVGRope3D::is_pin_start);
	ClassDB::bind_method(D_METHOD("set_segments", "segments"), &SVGRope3D::set_segments);
	ClassDB::bind_method(D_METHOD("get_segments"), &SVGRope3D::get_segments);
	ClassDB::bind_method(D_METHOD("set_constraint_iterations", "iterations"), &SVGRope3D::set_constraint_iterations);
	ClassDB::bind_method(D_METHOD("get_constraint_iterations"), &SVGRope3D::get_constraint_iterations);
	ClassDB::bind_method(D_METHOD("set_max_length", "length"), &SVGRope3D::set_max_length);
	ClassDB::bind_method(D_METHOD("get_max_length"), &SVGRope3D::get_max_length);
	ClassDB::bind_method(D_METHOD("set_elasticity", "elasticity"), &SVGRope3D::set_elasticity);
	ClassDB::bind_method(D_METHOD("get_elasticity"), &SVGRope3D::get_elasticity);
	ClassDB::bind_method(D_METHOD("set_damping", "damping"), &SVGRope3D::set_damping);
	ClassDB::bind_method(D_METHOD("get_damping"), &SVGRope3D::get_damping);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &SVGRope3D::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &SVGRope3D::get_gravity);
	ClassDB::bind_method(D_METHOD("set_line_width", "width"), &SVGRope3D::set_line_width);
	ClassDB::bind_method(D_METHOD("get_line_width"), &SVGRope3D::get_line_width);
	ClassDB::bind_method(D_METHOD("set_line_color", "color"), &SVGRope3D::set_line_color);
	ClassDB::bind_method(D_METHOD("get_line_color"), &SVGRope3D::get_line_color);
	ClassDB::bind_method(D_METHOD("set_pixel_size", "size"), &SVGRope3D::set_pixel_size);
	ClassDB::bind_method(D_METHOD("get_pixel_size"), &SVGRope3D::get_pixel_size);
	ClassDB::bind_method(D_METHOD("set_modulate", "color"), &SVGRope3D::set_modulate);
	ClassDB::bind_method(D_METHOD("get_modulate"), &SVGRope3D::get_modulate);
	ClassDB::bind_method(D_METHOD("reset_simulation"), &SVGRope3D::reset_simulation);
	ClassDB::bind_method(D_METHOD("get_rope_points"), &SVGRope3D::get_rope_points);
	ClassDB::bind_method(D_METHOD("get_svg_size"), &SVGRope3D::get_svg_size);
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "src", PROPERTY_HINT_FILE, "*.svg"), "set_src", "get_src");
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

} // namespace svg2d

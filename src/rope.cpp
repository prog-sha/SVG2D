// 粒子列でロープを動かし、帯として描く実装。
// 責務: 連続した座標をSIMDで更新し、描画側には必要な頂点だけ渡す。
#include "rope.h"
#include "rope_math.h"
#include "rope_cut.h"
#include <godot_cpp/classes/class_db_singleton.hpp>

#include <godot_cpp/classes/base_material3d.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/mesh.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/physics_server2d.hpp>
#include <godot_cpp/classes/physics_server3d.hpp>
#include <godot_cpp/classes/physics_body2d.hpp>
#include <godot_cpp/classes/physics_body3d.hpp>
#include <godot_cpp/classes/world2d.hpp>
#include <godot_cpp/classes/world3d.hpp>
#include <godot_cpp/core/object.hpp>
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

Vector2 SpriteRope2D::_effective_gravity() const {
	Vector2 world_gravity(0, 980);
	if (_use_system_gravity && is_inside_tree()) {
		Ref<World2D> world = get_world_2d();
		PhysicsServer2D *server = PhysicsServer2D::get_singleton();
		if (world.is_valid() && server != nullptr) {
			double amount = server->area_get_param(world->get_space(), PhysicsServer2D::AREA_PARAM_GRAVITY);
			Vector2 direction = server->area_get_param(world->get_space(), PhysicsServer2D::AREA_PARAM_GRAVITY_VECTOR);
			world_gravity = direction * (float)amount;
		}
	} else if (!_use_system_gravity) {
		return _gravity * (float)_gravity_scale;
	}
	Transform2D transform = get_global_transform();
	if (std::abs(transform.determinant()) > 1e-9)
		world_gravity = transform.affine_inverse().basis_xform(world_gravity);
	return world_gravity * (float)_gravity_scale;
}

void SpriteRope2D::reset_simulation() {
	_clear_attachment();
	_points.resize((size_t)_segments);
	_previous.resize((size_t)_segments);
	_coords.resize((size_t)_segments);
	double length = _effective_length();
	for (int i = 0; i < _segments; i++) {
		float t = (float)i / (float)(_segments - 1);
		_coords[i] = (double)i / (_segments - 1);
		_points[(size_t)i] = Vector2(0, (float)(length * t));
		_previous[(size_t)i] = _points[(size_t)i];
	}
	queue_redraw();
}

void SpriteRope2D::_ready() { if (!_preserve_state) reset_simulation(); _preserve_state = false; }

// 作り直すときだけ内部剛体を解放する。
void SpriteRope2D::_clear_attachment() {
	_attachment_target_id = 0;
	if (_physics) { _physics->clear_nodes(); _physics.reset(); }
}

// 接続物があるとき、ロープも質量を持つ剛体として同じソルバーへ参加する。
void SpriteRope2D::_sync_attachment() {
	if (!is_inside_tree() || Engine::get_singleton()->is_editor_hint() || _points.size() < 2) return;
	PhysicsBody2D *body = Object::cast_to<PhysicsBody2D>(ObjectDB::get_instance(_attachment_target_id));
	if (!_attachment_body.is_empty() && (body == nullptr || !body->is_inside_tree()))
		body = Object::cast_to<PhysicsBody2D>(get_node_or_null(_attachment_body));
	if (_attachment_body.is_empty() || (body && (!body->is_inside_tree() || body->is_queued_for_deletion()))) body = nullptr;
	_attachment_target_id = body ? body->get_instance_id() : 0;
	int point = _attachment_point < 0 ? (int)_points.size() - 1 : std::min(_attachment_point, (int)_points.size() - 1);
	if (body && !_physics) {
		_physics = std::make_unique<RopePhysics2D>();
		_physics->build(this, _points, _previous, _last_delta, _pin_start, _rope_mass, _coords);
	}
	if (_physics) _physics->connect(this, body, point, _points);
}

void SpriteRope2D::_simulate(double delta) {
	if (!std::isfinite(delta) || delta <= 0.0) return;
	if (_points.size() != (size_t)_segments) reset_simulation();
	if (_previous.size() != _points.size()) reset_simulation();
	Vector2 anchor = _points[0];
	double dt = std::min(std::max(delta, 0.0), 1.0 / 30.0);
	float keep = (float)std::pow(1.0 - _damping, dt * 60.0);
	integrate_rope(_points, _previous, _effective_gravity() * (float)(dt * dt), keep,
			_pin_start ? 1u : 0u);
	solve_rope(_points, anchor, _pin_start, _constraint_iterations, _elasticity,
			_effective_length(), _coords.data());
}

void SpriteRope2D::_physics_process(double delta) {
	if (Engine::get_singleton()->is_editor_hint() || !std::isfinite(delta) || delta <= 0.0) return;
	_sync_attachment();
	if (_physics) {
		Vector2 world_gravity = to_global(_effective_gravity()) - to_global(Vector2());
		_physics->configure(_rope_mass, _damping, world_gravity, _simulation_enabled, delta, _coords);
		_physics->read(this, _points, _previous, delta);
		queue_redraw();
	} else if (_simulation_enabled && (_line_mode || _texture.is_valid())) {
		_simulate(delta);
		queue_redraw();
	}
	_last_delta = _physics ? delta : std::min(delta, 1.0 / 30.0);
}

// 隣接する帯の三角形を1回の描画命令へまとめる。
static PackedInt32Array rope_indices(int count) {
	PackedInt32Array indices;
	indices.resize((count - 1) * 6);
	int32_t *data = indices.ptrw();
	for (int i = 0; i + 1 < count; i++) {
		int at = i * 6, row = i * 2;
		data[at] = row; data[at + 1] = row + 1; data[at + 2] = row + 2;
		data[at + 3] = row + 1; data[at + 4] = row + 3; data[at + 5] = row + 2;
	}
	return indices;
}

void SpriteRope2D::_draw() {
	if (_points.size() < 2) reset_simulation();
	if (_line_mode) {
		draw_polyline(get_rope_points(), _line_color, (float)_line_width, true);
		return;
	}
	Vector2 size = _visual_size();
	if (_texture.is_null() || size.x <= 0.0f || size.y <= 0.0f) return;
	float half = size.x * 0.5f;
	int count = (int)_points.size();
	PackedVector2Array vertices, uvs;
	vertices.resize(count * 2); uvs.resize(count * 2);
	Vector2 *v = vertices.ptrw(), *uv = uvs.ptrw();
	for (int i = 0; i < count; i++) {
		Vector2 side = rope_side_2d(_points, (size_t)i) * half;
		v[i * 2] = _points[(size_t)i] + side;
		v[i * 2 + 1] = _points[(size_t)i] - side;
		float t = _uv_range.x + (_uv_range.y - _uv_range.x) * _coords[i];
		uv[i * 2] = Vector2(0, t); uv[i * 2 + 1] = Vector2(1, t);
	}
	PackedColorArray colors;
	colors.push_back(Color(1, 1, 1, 1));
	RenderingServer::get_singleton()->canvas_item_add_triangle_array(get_canvas_item(),
			rope_indices(count), vertices, colors, uvs, PackedInt32Array(), PackedFloat32Array(), _texture->get_rid());
}

void SpriteRope2D::set_texture(const Ref<Texture2D> &texture) { if (_texture != texture) { _texture = texture; reset_simulation(); } }
void SpriteRope2D::set_line_mode(bool enabled) { if (_line_mode != enabled) { _line_mode = enabled; reset_simulation(); } }
void SpriteRope2D::set_simulation_enabled(bool enabled) { _simulation_enabled = enabled; set_physics_process(enabled || !_attachment_body.is_empty() || _physics != nullptr); }
void SpriteRope2D::set_pin_start(bool enabled) { if (_pin_start != enabled) { _pin_start = enabled; reset_simulation(); } }
void SpriteRope2D::set_segments(int value) { value = std::clamp(value, 2, 256); if (_segments != value) { _segments = value; reset_simulation(); } }
void SpriteRope2D::set_constraint_iterations(int value) { _constraint_iterations = std::clamp(value, 1, 64); }
void SpriteRope2D::set_max_length(double value) { value = std::isfinite(value) ? std::max(0.0, value) : 0.0; if (_max_length != value) { _max_length = value; reset_simulation(); } }
void SpriteRope2D::set_elasticity(double value) { _elasticity = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.9; }
void SpriteRope2D::set_damping(double value) { _damping = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.02; }
void SpriteRope2D::set_use_system_gravity(bool enabled) { _use_system_gravity = enabled; }
void SpriteRope2D::set_gravity_scale(double value) { _gravity_scale = std::isfinite(value) ? value : 1.0; }
void SpriteRope2D::set_gravity(const Vector2 &value) { if (value.is_finite()) _gravity = value; }
void SpriteRope2D::set_line_width(double value) { _line_width = std::isfinite(value) ? std::max(0.1, value) : 4.0; queue_redraw(); }
void SpriteRope2D::set_line_color(const Color &value) { _line_color = value; queue_redraw(); }
void SpriteRope2D::set_attachment_body(const NodePath &path) {
	if (_attachment_body == path) return;
	_attachment_target_id = 0;
	_attachment_body = path;
	set_physics_process(_simulation_enabled || !_attachment_body.is_empty() || _physics != nullptr);
	_sync_attachment();
}
void SpriteRope2D::set_attachment_point(int value) {
	value = std::clamp(value, -1, 255);
	if (_attachment_point == value) return;
	_attachment_point = value;
	_attachment_target_id = 0;
	_sync_attachment();
}

// 質量は素材の長さで配分し、切断後も合計を保存する。
void SpriteRope2D::set_rope_mass(double value) { _rope_mass = std::isfinite(value) ? std::max(0.001, value) : 1.0; }
void SpriteRope2D::set_uv_range(const Vector2 &value) {
	if (!value.is_finite()) return;
	_uv_range = value;

	queue_redraw();
}

// 現在の粒子速度をロープのローカル座標で返す。
PackedVector2Array SpriteRope2D::get_rope_velocities() const {
	PackedVector2Array out; out.resize((int)_points.size());
	auto *data = out.ptrw();
	for (size_t i = 0; i < _points.size(); i++) data[i] = (_points[i] - _previous[i]) / _last_delta;
	return out;
}

// 接点で二分し、新しい同型ノードを同じ親へ置く。位置・速度は初期化しない。
SpriteRope2D *SpriteRope2D::cut_at(int point) {
	if (!is_inside_tree() || get_parent() == nullptr || point <= 0 || point >= (int)_points.size() - 1 ||
			Engine::get_singleton()->is_editor_hint()) return nullptr;
	if (_physics) _physics->read(this, _points, _previous, _last_delta);
	Object *object = ClassDBSingleton::get_singleton()->instantiate(get_class());
	auto *tail = Object::cast_to<SpriteRope2D>(object);
	if (!tail) return nullptr;
	TypedArray<Dictionary> properties = get_property_list();
	for (int i = 0; i < properties.size(); i++) {
		Dictionary property = properties[i];
		StringName name = property["name"];
		if (((int64_t)property["usage"] & PROPERTY_USAGE_STORAGE) && name != StringName("attachment_body") &&
				name != StringName("script")) tail->set(name, get(name));
	}
	tail->set_name(String(get_name()) + "Cut");
	int count = (int)_points.size();
	double ratio = _coords[point];
	tail->_coords.assign(_coords.begin() + point, _coords.end());
	for (auto &coord : tail->_coords) coord = (coord - ratio) / (1.0 - ratio);
	_coords.resize(point + 1);
	for (auto &coord : _coords) coord /= ratio;
	double length = _effective_length();
	int attached = _attachment_point < 0 ? count - 1 : std::min(_attachment_point, count - 1);
	Node *target = _attachment_body.is_empty() ? nullptr : get_node_or_null(_attachment_body);
	tail->_points.assign(_points.begin() + point, _points.end());
	tail->_previous.assign(_previous.begin() + point, _previous.end());
	tail->_segments = count - point; tail->_max_length = length * (1.0 - ratio);
	tail->_rope_mass = _rope_mass * (1.0 - ratio); tail->_last_delta = _last_delta;
	tail->_pin_start = false; tail->_preserve_state = true;
	float uv_cut = _uv_range.x + (_uv_range.y - _uv_range.x) * ratio;
	tail->_uv_range = Vector2(uv_cut, _uv_range.y); _uv_range.y = uv_cut;
	_points.resize(point + 1); _previous.resize(point + 1);
	_segments = point + 1; _max_length = length * ratio; _rope_mass *= ratio;
	get_parent()->add_child(tail, true);
	if (get_owner()) tail->set_owner(get_owner());
	if (_physics) tail->_physics = _physics->split(point, tail);
	if (attached >= point && !_attachment_body.is_empty()) {
		tail->_attachment_body = target ? tail->get_path_to(target) : _attachment_body;
		tail->_attachment_point = _attachment_point < 0 ? -1 : attached - point;
		tail->_attachment_target_id = _attachment_target_id;
		_attachment_body = NodePath(); _attachment_target_id = 0;
	}
	_sync_attachment(); tail->_sync_attachment();
	tail->set_physics_process(_simulation_enabled || tail->_physics != nullptr || !tail->_attachment_body.is_empty());

	queue_redraw();
	tail->queue_redraw();
	return tail;
}

// 線分に沿って最初の交点を探し、区間内なら速度と素材座標も補間する。
SpriteRope2D *SpriteRope2D::cut_segment(const Vector2 &from, const Vector2 &to) {
	if (!is_inside_tree() || !get_parent() || Engine::get_singleton()->is_editor_hint() ||
			!from.is_finite() || !to.is_finite()) return nullptr;
	if (_physics) _physics->read(this, _points, _previous, _last_delta);
	auto hit = find_rope_cut(_points, from, to, [this](const Vector2 &p) { return to_global(p); }, 0.0);
	if (hit.edge < 0) return nullptr;
	int point = hit.edge + 1;
	if (hit.fraction == 0) return cut_at(hit.edge);
	if (hit.fraction == 1) return cut_at(point);
	Vector2 position = _points[hit.edge].lerp(_points[point], hit.fraction);
	Vector2 previous = _previous[hit.edge].lerp(_previous[point], hit.fraction);
	double coord = _coords[hit.edge] + (_coords[point] - _coords[hit.edge]) * hit.fraction;
	if (_physics) _physics->insert_cut(this, hit.edge, to_global(position), hit.fraction);
	_points.insert(_points.begin() + point, position);
	_previous.insert(_previous.begin() + point, previous);
	_coords.insert(_coords.begin() + point, coord);
	_segments++;
	if (_attachment_point >= point) _attachment_point++;
	return cut_at(point);
}

PackedVector2Array SpriteRope2D::get_rope_points() const {
	PackedVector2Array out;
	out.resize((int)_points.size());
	std::copy(_points.begin(), _points.end(), out.ptrw());
	return out;
}

String SpriteRope2D::get_simulation_backend() const { return rope_backend_name(); }

void SpriteRope2D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("cut_segment", "from", "to"), &SpriteRope2D::cut_segment);
	ClassDB::bind_method(D_METHOD("cut_at", "point"), &SpriteRope2D::cut_at);
	ClassDB::bind_method(D_METHOD("get_rope_velocities"), &SpriteRope2D::get_rope_velocities);
	ClassDB::bind_method(D_METHOD("set_rope_mass", "mass"), &SpriteRope2D::set_rope_mass);
	ClassDB::bind_method(D_METHOD("get_rope_mass"), &SpriteRope2D::get_rope_mass);
	ClassDB::bind_method(D_METHOD("set_uv_range", "range"), &SpriteRope2D::set_uv_range);
	ClassDB::bind_method(D_METHOD("get_uv_range"), &SpriteRope2D::get_uv_range);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rope_mass", PROPERTY_HINT_RANGE, "0.001,1000,0.001,or_greater"), "set_rope_mass", "get_rope_mass");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "uv_range"), "set_uv_range", "get_uv_range");
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
	ClassDB::bind_method(D_METHOD("set_use_system_gravity", "enabled"), &SpriteRope2D::set_use_system_gravity);
	ClassDB::bind_method(D_METHOD("is_using_system_gravity"), &SpriteRope2D::is_using_system_gravity);
	ClassDB::bind_method(D_METHOD("set_gravity_scale", "scale"), &SpriteRope2D::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("get_gravity_scale"), &SpriteRope2D::get_gravity_scale);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &SpriteRope2D::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &SpriteRope2D::get_gravity);
	ClassDB::bind_method(D_METHOD("get_effective_gravity"), &SpriteRope2D::get_effective_gravity);
	ClassDB::bind_method(D_METHOD("set_line_width", "width"), &SpriteRope2D::set_line_width);
	ClassDB::bind_method(D_METHOD("get_line_width"), &SpriteRope2D::get_line_width);
	ClassDB::bind_method(D_METHOD("set_line_color", "color"), &SpriteRope2D::set_line_color);
	ClassDB::bind_method(D_METHOD("get_line_color"), &SpriteRope2D::get_line_color);
	ClassDB::bind_method(D_METHOD("set_attachment_body", "path"), &SpriteRope2D::set_attachment_body);
	ClassDB::bind_method(D_METHOD("get_attachment_body"), &SpriteRope2D::get_attachment_body);
	ClassDB::bind_method(D_METHOD("set_attachment_point", "point"), &SpriteRope2D::set_attachment_point);
	ClassDB::bind_method(D_METHOD("get_attachment_point"), &SpriteRope2D::get_attachment_point);
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_system_gravity"), "set_use_system_gravity", "is_using_system_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gravity_scale", PROPERTY_HINT_RANGE, "-100,100,0.01,or_less,or_greater"), "set_gravity_scale", "get_gravity_scale");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "gravity"), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "constraint_iterations", PROPERTY_HINT_RANGE, "1,64,1"), "set_constraint_iterations", "get_constraint_iterations");
	ADD_GROUP("Attachment", "attachment_");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "attachment_body", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "PhysicsBody2D"), "set_attachment_body", "get_attachment_body");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "attachment_point", PROPERTY_HINT_RANGE, "-1,255,1"), "set_attachment_point", "get_attachment_point");
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

Vector3 SpriteRope3D::_effective_gravity() const {
	Vector3 world_gravity(0, -9.8f, 0);
	if (_use_system_gravity && is_inside_tree()) {
		Ref<World3D> world = get_world_3d();
		PhysicsServer3D *server = PhysicsServer3D::get_singleton();
		if (world.is_valid() && server != nullptr) {
			double amount = server->area_get_param(world->get_space(), PhysicsServer3D::AREA_PARAM_GRAVITY);
			Vector3 direction = server->area_get_param(world->get_space(), PhysicsServer3D::AREA_PARAM_GRAVITY_VECTOR);
			world_gravity = direction * (float)amount;
		}
	} else if (!_use_system_gravity) {
		return _gravity * (float)_gravity_scale;
	}
	Basis basis = get_global_transform().basis;
	if (std::abs(basis.determinant()) > 1e-9)
		world_gravity = basis.inverse().xform(world_gravity);
	return world_gravity * (float)_gravity_scale;
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
	_clear_attachment();
	_points.resize((size_t)_segments);
	_previous.resize((size_t)_segments);
	_coords.resize((size_t)_segments);
	double length = _effective_length();
	for (int i = 0; i < _segments; i++) {
		float t = (float)i / (float)(_segments - 1);
		_coords[i] = (double)i / (_segments - 1);
		_points[(size_t)i] = Vector3(0, (float)(-length * t), 0);
		_previous[(size_t)i] = _points[(size_t)i];
	}
	if (is_inside_tree()) _update_mesh();
}

void SpriteRope3D::_ready() { if (!_preserve_state) reset_simulation(); _preserve_state = false; }

// 作り直すときだけ内部剛体を解放する。
void SpriteRope3D::_clear_attachment() {
	_attachment_target_id = 0;
	if (_physics) { _physics->clear_nodes(); _physics.reset(); }
}

// 接続物があるとき、ロープも質量を持つ剛体として同じソルバーへ参加する。
void SpriteRope3D::_sync_attachment() {
	if (!is_inside_tree() || Engine::get_singleton()->is_editor_hint() || _points.size() < 2) return;
	PhysicsBody3D *body = Object::cast_to<PhysicsBody3D>(ObjectDB::get_instance(_attachment_target_id));
	if (!_attachment_body.is_empty() && (body == nullptr || !body->is_inside_tree()))
		body = Object::cast_to<PhysicsBody3D>(get_node_or_null(_attachment_body));
	if (_attachment_body.is_empty() || (body && (!body->is_inside_tree() || body->is_queued_for_deletion()))) body = nullptr;
	_attachment_target_id = body ? body->get_instance_id() : 0;
	int point = _attachment_point < 0 ? (int)_points.size() - 1 : std::min(_attachment_point, (int)_points.size() - 1);
	if (body && !_physics) {
		_physics = std::make_unique<RopePhysics3D>();
		_physics->build(this, _points, _previous, _last_delta, _pin_start, _rope_mass, _coords);
	}
	if (_physics) _physics->connect(this, body, point, _points);
}

void SpriteRope3D::_simulate(double delta) {
	if (!std::isfinite(delta) || delta <= 0.0) return;
	if (_points.size() != (size_t)_segments) reset_simulation();
	if (_previous.size() != _points.size()) reset_simulation();
	Vector3 anchor = _points[0];
	double dt = std::min(std::max(delta, 0.0), 1.0 / 30.0);
	float keep = (float)std::pow(1.0 - _damping, dt * 60.0);
	integrate_rope(_points, _previous, _effective_gravity() * (float)(dt * dt), keep,
			_pin_start ? 1u : 0u);
	solve_rope(_points, anchor, _pin_start, _constraint_iterations, _elasticity,
			_effective_length(), _coords.data());
}

void SpriteRope3D::_update_mesh() {
	_ensure_mesh();
	if (_points.size() < 2) { _mesh->clear_surfaces(); _mesh_points = 0; return; }
	Vector2 visual_size = _visual_size();
	Ref<Texture2D> texture;
	float half;
	if (_line_mode) {
		half = (float)(_line_width * 0.5);
		_material->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, Ref<Texture2D>());
		_material->set_albedo(_line_color);
	} else {
		texture = _texture;
		if (texture.is_null() || visual_size.x <= 0.0f || visual_size.y <= 0.0f) { _mesh->clear_surfaces(); _mesh_points = 0; return; }
		half = (float)(visual_size.x * _pixel_size * 0.5);
		_material->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, texture);
		_material->set_albedo(_modulate);
	}
	int count = (int)_points.size();
	PackedVector3Array vertices;
	vertices.resize(count * 2);
	Vector3 *v = vertices.ptrw();
	for (int i = 0; i < count; i++) {
		Vector3 side = rope_side_3d(_points, (size_t)i) * half;
		v[i * 2] = _points[(size_t)i] + side;
		v[i * 2 + 1] = _points[(size_t)i] - side;
	}
	// 頂点領域の更新では境界が再計算されないため、自分で現在の範囲を渡す。
	AABB bounds(v[0], Vector3());
	for (int i = 1; i < count * 2; i++) bounds.expand_to(v[i]);
	_mesh->set_custom_aabb(bounds.grow(0.00001f));
	if (_dynamic_mesh && _mesh_points == count && _mesh->get_surface_count() == 1) {
#ifdef REAL_T_IS_DOUBLE
		// GPUの位置形式はdouble精度ビルドでもfloat32のxyz。
		PackedFloat32Array packed;
		packed.resize(count * 6);
		float *data = packed.ptrw();
		for (int i = 0; i < count * 2; i++) {
			data[i * 3] = (float)v[i].x; data[i * 3 + 1] = (float)v[i].y; data[i * 3 + 2] = (float)v[i].z;
		}
		_mesh->surface_update_vertex_region(0, 0, packed.to_byte_array());
#else
		_mesh->surface_update_vertex_region(0, 0, vertices.to_byte_array());
#endif
		return;
	}
	PackedVector2Array uvs;
	uvs.resize(count * 2);
	Vector2 *uv = uvs.ptrw();
	for (int i = 0; i < count; i++) {
		float t = _uv_range.x + (_uv_range.y - _uv_range.x) * _coords[i];
		uv[i * 2] = Vector2(0, t); uv[i * 2 + 1] = Vector2(1, t);
	}
	Array arrays;
	arrays.resize(Mesh::ARRAY_MAX);
	arrays[Mesh::ARRAY_VERTEX] = vertices;
	arrays[Mesh::ARRAY_TEX_UV] = uvs;
	arrays[Mesh::ARRAY_INDEX] = rope_indices(count);
	_mesh->clear_surfaces();
	_mesh->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays, Array(), Dictionary(), Mesh::ARRAY_FLAG_USE_DYNAMIC_UPDATE);
	_mesh->surface_set_material(0, _material);
	_mesh_points = count;
}

void SpriteRope3D::_physics_process(double delta) {
	if (Engine::get_singleton()->is_editor_hint() || !std::isfinite(delta) || delta <= 0.0) return;
	_sync_attachment();
	if (_physics) {
		Vector3 world_gravity = to_global(_effective_gravity()) - to_global(Vector3());
		_physics->configure(_rope_mass, _damping, world_gravity, _simulation_enabled, delta, _coords);
		_physics->read(this, _points, _previous, delta);
		if (is_inside_tree()) _update_mesh();
	} else if (_simulation_enabled && (_line_mode || _texture.is_valid())) {
		_simulate(delta);
		if (is_inside_tree()) _update_mesh();
	}
	_last_delta = _physics ? delta : std::min(delta, 1.0 / 30.0);
}

// 動的更新の切り替え時は面を作り直し、GPUと設定を揃える。
void SpriteRope3D::set_dynamic_mesh(bool enabled) {
	if (_dynamic_mesh == enabled) return;
	_dynamic_mesh = enabled; _mesh_points = 0;
	if (is_inside_tree()) _update_mesh();
}

void SpriteRope3D::set_texture(const Ref<Texture2D> &texture) { if (_texture != texture) { _texture = texture; reset_simulation(); } }
void SpriteRope3D::set_line_mode(bool enabled) { if (_line_mode != enabled) { _line_mode = enabled; reset_simulation(); } }
void SpriteRope3D::set_simulation_enabled(bool enabled) { _simulation_enabled = enabled; set_physics_process(enabled || !_attachment_body.is_empty() || _physics != nullptr); }
void SpriteRope3D::set_pin_start(bool enabled) { if (_pin_start != enabled) { _pin_start = enabled; reset_simulation(); } }
void SpriteRope3D::set_segments(int value) { value = std::clamp(value, 2, 256); if (_segments != value) { _segments = value; reset_simulation(); } }
void SpriteRope3D::set_constraint_iterations(int value) { _constraint_iterations = std::clamp(value, 1, 64); }
void SpriteRope3D::set_max_length(double value) { value = std::isfinite(value) ? std::max(0.0, value) : 0.0; if (_max_length != value) { _max_length = value; reset_simulation(); } }
void SpriteRope3D::set_elasticity(double value) { _elasticity = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.9; }
void SpriteRope3D::set_damping(double value) { _damping = std::isfinite(value) ? std::clamp(value, 0.0, 1.0) : 0.02; }
void SpriteRope3D::set_use_system_gravity(bool enabled) { _use_system_gravity = enabled; }
void SpriteRope3D::set_gravity_scale(double value) { _gravity_scale = std::isfinite(value) ? value : 1.0; }
void SpriteRope3D::set_gravity(const Vector3 &value) { if (value.is_finite()) _gravity = value; }
void SpriteRope3D::set_line_width(double value) { _line_width = std::isfinite(value) ? std::max(0.0001, value) : 0.04; _update_mesh(); }
void SpriteRope3D::set_line_color(const Color &value) { _line_color = value; _update_mesh(); }
void SpriteRope3D::set_pixel_size(double value) { value = std::isfinite(value) ? std::max(0.0001, value) : 0.01; if (_pixel_size != value) { _pixel_size = value; reset_simulation(); } }
void SpriteRope3D::set_modulate(const Color &value) { _modulate = value; _update_mesh(); }
void SpriteRope3D::set_attachment_body(const NodePath &path) {
	if (_attachment_body == path) return;
	_attachment_target_id = 0;
	_attachment_body = path;
	set_physics_process(_simulation_enabled || !_attachment_body.is_empty() || _physics != nullptr);
	_sync_attachment();
}
void SpriteRope3D::set_attachment_point(int value) {
	value = std::clamp(value, -1, 255);
	if (_attachment_point == value) return;
	_attachment_point = value;
	_attachment_target_id = 0;
	_sync_attachment();
}

// 質量は素材の長さで配分し、切断後も合計を保存する。
void SpriteRope3D::set_rope_mass(double value) { _rope_mass = std::isfinite(value) ? std::max(0.001, value) : 1.0; }
void SpriteRope3D::set_uv_range(const Vector2 &value) {
	if (!value.is_finite()) return;
	_uv_range = value;
	_mesh_points = 0;
	if (is_inside_tree()) _update_mesh();
}

// 現在の粒子速度をロープのローカル座標で返す。
PackedVector3Array SpriteRope3D::get_rope_velocities() const {
	PackedVector3Array out; out.resize((int)_points.size());
	auto *data = out.ptrw();
	for (size_t i = 0; i < _points.size(); i++) data[i] = (_points[i] - _previous[i]) / _last_delta;
	return out;
}

// 接点で二分し、新しい同型ノードを同じ親へ置く。位置・速度は初期化しない。
SpriteRope3D *SpriteRope3D::cut_at(int point) {
	if (!is_inside_tree() || get_parent() == nullptr || point <= 0 || point >= (int)_points.size() - 1 ||
			Engine::get_singleton()->is_editor_hint()) return nullptr;
	if (_physics) _physics->read(this, _points, _previous, _last_delta);
	Object *object = ClassDBSingleton::get_singleton()->instantiate(get_class());
	auto *tail = Object::cast_to<SpriteRope3D>(object);
	if (!tail) return nullptr;
	TypedArray<Dictionary> properties = get_property_list();
	for (int i = 0; i < properties.size(); i++) {
		Dictionary property = properties[i];
		StringName name = property["name"];
		if (((int64_t)property["usage"] & PROPERTY_USAGE_STORAGE) && name != StringName("attachment_body") &&
				name != StringName("script")) tail->set(name, get(name));
	}
	tail->set_name(String(get_name()) + "Cut");
	int count = (int)_points.size();
	double ratio = _coords[point];
	tail->_coords.assign(_coords.begin() + point, _coords.end());
	for (auto &coord : tail->_coords) coord = (coord - ratio) / (1.0 - ratio);
	_coords.resize(point + 1);
	for (auto &coord : _coords) coord /= ratio;
	double length = _effective_length();
	int attached = _attachment_point < 0 ? count - 1 : std::min(_attachment_point, count - 1);
	Node *target = _attachment_body.is_empty() ? nullptr : get_node_or_null(_attachment_body);
	tail->_points.assign(_points.begin() + point, _points.end());
	tail->_previous.assign(_previous.begin() + point, _previous.end());
	tail->_segments = count - point; tail->_max_length = length * (1.0 - ratio);
	tail->_rope_mass = _rope_mass * (1.0 - ratio); tail->_last_delta = _last_delta;
	tail->_pin_start = false; tail->_preserve_state = true;
	float uv_cut = _uv_range.x + (_uv_range.y - _uv_range.x) * ratio;
	tail->_uv_range = Vector2(uv_cut, _uv_range.y); _uv_range.y = uv_cut;
	_points.resize(point + 1); _previous.resize(point + 1);
	_segments = point + 1; _max_length = length * ratio; _rope_mass *= ratio;
	get_parent()->add_child(tail, true);
	if (get_owner()) tail->set_owner(get_owner());
	if (_physics) tail->_physics = _physics->split(point, tail);
	if (attached >= point && !_attachment_body.is_empty()) {
		tail->_attachment_body = target ? tail->get_path_to(target) : _attachment_body;
		tail->_attachment_point = _attachment_point < 0 ? -1 : attached - point;
		tail->_attachment_target_id = _attachment_target_id;
		_attachment_body = NodePath(); _attachment_target_id = 0;
	}
	_sync_attachment(); tail->_sync_attachment();
	tail->set_physics_process(_simulation_enabled || tail->_physics != nullptr || !tail->_attachment_body.is_empty());
	_mesh_points = 0; tail->_mesh_points = 0;
	if (is_inside_tree()) _update_mesh();
	tail->_update_mesh();
	return tail;
}

// 線分に沿って最初の交点を探し、区間内なら速度と素材座標も補間する。
SpriteRope3D *SpriteRope3D::cut_segment(const Vector3 &from, const Vector3 &to, double tolerance) {
	if (!is_inside_tree() || !get_parent() || Engine::get_singleton()->is_editor_hint() ||
			!from.is_finite() || !to.is_finite() || !std::isfinite(tolerance) || tolerance < 0) return nullptr;
	if (_physics) _physics->read(this, _points, _previous, _last_delta);
	auto hit = find_rope_cut(_points, from, to, [this](const Vector3 &p) { return to_global(p); }, tolerance);
	if (hit.edge < 0) return nullptr;
	int point = hit.edge + 1;
	if (hit.fraction == 0) return cut_at(hit.edge);
	if (hit.fraction == 1) return cut_at(point);
	Vector3 position = _points[hit.edge].lerp(_points[point], hit.fraction);
	Vector3 previous = _previous[hit.edge].lerp(_previous[point], hit.fraction);
	double coord = _coords[hit.edge] + (_coords[point] - _coords[hit.edge]) * hit.fraction;
	if (_physics) _physics->insert_cut(this, hit.edge, to_global(position), hit.fraction);
	_points.insert(_points.begin() + point, position);
	_previous.insert(_previous.begin() + point, previous);
	_coords.insert(_coords.begin() + point, coord);
	_segments++;
	if (_attachment_point >= point) _attachment_point++;
	return cut_at(point);
}

PackedVector3Array SpriteRope3D::get_rope_points() const {
	PackedVector3Array out;
	out.resize((int)_points.size());
	std::copy(_points.begin(), _points.end(), out.ptrw());
	return out;
}

String SpriteRope3D::get_simulation_backend() const { return rope_backend_name(); }

void SpriteRope3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("cut_segment", "from", "to", "tolerance"), &SpriteRope3D::cut_segment, DEFVAL(0.001));
	ClassDB::bind_method(D_METHOD("cut_at", "point"), &SpriteRope3D::cut_at);
	ClassDB::bind_method(D_METHOD("get_rope_velocities"), &SpriteRope3D::get_rope_velocities);
	ClassDB::bind_method(D_METHOD("set_rope_mass", "mass"), &SpriteRope3D::set_rope_mass);
	ClassDB::bind_method(D_METHOD("get_rope_mass"), &SpriteRope3D::get_rope_mass);
	ClassDB::bind_method(D_METHOD("set_uv_range", "range"), &SpriteRope3D::set_uv_range);
	ClassDB::bind_method(D_METHOD("get_uv_range"), &SpriteRope3D::get_uv_range);
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "rope_mass", PROPERTY_HINT_RANGE, "0.001,1000,0.001,or_greater"), "set_rope_mass", "get_rope_mass");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR2, "uv_range"), "set_uv_range", "get_uv_range");
	ClassDB::bind_method(D_METHOD("set_dynamic_mesh", "enabled"), &SpriteRope3D::set_dynamic_mesh);
	ClassDB::bind_method(D_METHOD("is_dynamic_mesh"), &SpriteRope3D::is_dynamic_mesh);
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "dynamic_mesh"), "set_dynamic_mesh", "is_dynamic_mesh");
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
	ClassDB::bind_method(D_METHOD("set_use_system_gravity", "enabled"), &SpriteRope3D::set_use_system_gravity);
	ClassDB::bind_method(D_METHOD("is_using_system_gravity"), &SpriteRope3D::is_using_system_gravity);
	ClassDB::bind_method(D_METHOD("set_gravity_scale", "scale"), &SpriteRope3D::set_gravity_scale);
	ClassDB::bind_method(D_METHOD("get_gravity_scale"), &SpriteRope3D::get_gravity_scale);
	ClassDB::bind_method(D_METHOD("set_gravity", "gravity"), &SpriteRope3D::set_gravity);
	ClassDB::bind_method(D_METHOD("get_gravity"), &SpriteRope3D::get_gravity);
	ClassDB::bind_method(D_METHOD("get_effective_gravity"), &SpriteRope3D::get_effective_gravity);
	ClassDB::bind_method(D_METHOD("set_line_width", "width"), &SpriteRope3D::set_line_width);
	ClassDB::bind_method(D_METHOD("get_line_width"), &SpriteRope3D::get_line_width);
	ClassDB::bind_method(D_METHOD("set_line_color", "color"), &SpriteRope3D::set_line_color);
	ClassDB::bind_method(D_METHOD("get_line_color"), &SpriteRope3D::get_line_color);
	ClassDB::bind_method(D_METHOD("set_pixel_size", "size"), &SpriteRope3D::set_pixel_size);
	ClassDB::bind_method(D_METHOD("get_pixel_size"), &SpriteRope3D::get_pixel_size);
	ClassDB::bind_method(D_METHOD("set_modulate", "color"), &SpriteRope3D::set_modulate);
	ClassDB::bind_method(D_METHOD("get_modulate"), &SpriteRope3D::get_modulate);
	ClassDB::bind_method(D_METHOD("set_attachment_body", "path"), &SpriteRope3D::set_attachment_body);
	ClassDB::bind_method(D_METHOD("get_attachment_body"), &SpriteRope3D::get_attachment_body);
	ClassDB::bind_method(D_METHOD("set_attachment_point", "point"), &SpriteRope3D::set_attachment_point);
	ClassDB::bind_method(D_METHOD("get_attachment_point"), &SpriteRope3D::get_attachment_point);
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "use_system_gravity"), "set_use_system_gravity", "is_using_system_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "gravity_scale", PROPERTY_HINT_RANGE, "-100,100,0.01,or_less,or_greater"), "set_gravity_scale", "get_gravity_scale");
	ADD_PROPERTY(PropertyInfo(Variant::VECTOR3, "gravity"), "set_gravity", "get_gravity");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "constraint_iterations", PROPERTY_HINT_RANGE, "1,64,1"), "set_constraint_iterations", "get_constraint_iterations");
	ADD_GROUP("Attachment", "attachment_");
	ADD_PROPERTY(PropertyInfo(Variant::NODE_PATH, "attachment_body", PROPERTY_HINT_NODE_PATH_VALID_TYPES, "PhysicsBody3D"), "set_attachment_body", "get_attachment_body");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "attachment_point", PROPERTY_HINT_RANGE, "-1,255,1"), "set_attachment_point", "get_attachment_point");
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

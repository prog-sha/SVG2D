// 2D・3Dのロープ設定と粒子を保持する宣言。
// 責務: 物理と表示の状態を分け、同じ設定をSVGと通常画像へ提供する。
#ifndef SVG2D_ROPE_H
#define SVG2D_ROPE_H

#include "svg.h"
#include "rope_physics.h"
#include <godot_cpp/classes/animatable_body2d.hpp>
#include <godot_cpp/classes/animatable_body3d.hpp>
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/pin_joint2d.hpp>
#include <godot_cpp/classes/pin_joint3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/core/property_info.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <vector>

namespace svg2d {

class SpriteRope2D : public godot::Node2D {
	GDCLASS(SpriteRope2D, godot::Node2D)
protected:
	godot::Ref<godot::Texture2D> _texture;
	std::vector<godot::Vector2> _points, _previous;
	std::vector<double> _coords; // 素材に沿った位置。区間長・質量・UVの配分を共有する
	std::unique_ptr<RopePhysics2D> _physics; // 接続物と同じ物理空間で解く区間剛体
	double _rope_mass = 1.0, _last_delta = 1.0 / 60.0; // 合計質量と速度換算時間
	godot::Vector2 _uv_range = godot::Vector2(0, 1); // 切断後も素材の対応範囲を保つ
	bool _preserve_state = false; // 切断ノードのreadyで粒子を初期化しない
	godot::NodePath _attachment_body;
	uint64_t _attachment_target_id = 0;
	bool _line_mode = false, _simulation_enabled = true, _pin_start = true;
	bool _use_system_gravity = true;
	int _segments = 16, _constraint_iterations = 8, _attachment_point = -1;
	double _max_length = 0.0, _elasticity = 0.9, _damping = 0.02, _gravity_scale = 1.0, _line_width = 4.0;
	godot::Vector2 _gravity = godot::Vector2(0, 980);
	godot::Color _line_color = godot::Color(1, 1, 1, 1);
	double _effective_length() const;
	godot::Vector2 _effective_gravity() const;
	void _simulate(double delta);
	void _sync_attachment();
	void _clear_attachment();
	virtual godot::Vector2 _visual_size() const;
	static void _bind_methods();
public:
	SpriteRope2D();
	SpriteRope2D *cut_at(int point);
	SpriteRope2D *cut_segment(const godot::Vector2 &from, const godot::Vector2 &to);
	void set_rope_mass(double value); double get_rope_mass() const { return _rope_mass; }
	void set_uv_range(const godot::Vector2 &value); godot::Vector2 get_uv_range() const { return _uv_range; }
	godot::PackedVector2Array get_rope_velocities() const;
	void _ready() override;
	void _draw() override;
	void _physics_process(double delta) override;
	void reset_simulation();
	virtual void set_texture(const godot::Ref<godot::Texture2D> &texture);
	godot::Ref<godot::Texture2D> get_texture() const { return _texture; }
	void set_line_mode(bool enabled); bool is_line_mode() const { return _line_mode; }
	void set_simulation_enabled(bool enabled); bool is_simulation_enabled() const { return _simulation_enabled; }
	void set_pin_start(bool enabled); bool is_pin_start() const { return _pin_start; }
	void set_segments(int value); int get_segments() const { return _segments; }
	void set_constraint_iterations(int value); int get_constraint_iterations() const { return _constraint_iterations; }
	void set_max_length(double value); double get_max_length() const { return _max_length; }
	void set_elasticity(double value); double get_elasticity() const { return _elasticity; }
	void set_damping(double value); double get_damping() const { return _damping; }
	void set_use_system_gravity(bool enabled); bool is_using_system_gravity() const { return _use_system_gravity; }
	void set_gravity_scale(double value); double get_gravity_scale() const { return _gravity_scale; }
	void set_gravity(const godot::Vector2 &value); godot::Vector2 get_gravity() const { return _gravity; }
	godot::Vector2 get_effective_gravity() const { return _effective_gravity(); }
	void set_line_width(double value); double get_line_width() const { return _line_width; }
	void set_line_color(const godot::Color &value); godot::Color get_line_color() const { return _line_color; }
	void set_attachment_body(const godot::NodePath &path); godot::NodePath get_attachment_body() const { return _attachment_body; }
	void set_attachment_point(int value); int get_attachment_point() const { return _attachment_point; }
	godot::PackedVector2Array get_rope_points() const;
	godot::String get_simulation_backend() const;
};

class SVGRope2D : public SpriteRope2D {
	GDCLASS(SVGRope2D, SpriteRope2D)
	SVGTexture _svg;
protected:
	static void _bind_methods();
	godot::Vector2 _visual_size() const override;
	void _validate_property(godot::PropertyInfo &property) const;
public:
	void set_src(const godot::String &src);
	godot::String get_src() const { return _svg.get_src(); }
	godot::Vector2 get_svg_size() const { return _svg.draw_size(); }
};

class SpriteRope3D : public godot::Node3D {
	GDCLASS(SpriteRope3D, godot::Node3D)
protected:
	godot::Ref<godot::Texture2D> _texture;
	std::vector<godot::Vector3> _points, _previous;
	godot::MeshInstance3D *_mesh_instance = nullptr;
	std::vector<double> _coords; // 素材に沿った位置。区間長・質量・UVの配分を共有する
	std::unique_ptr<RopePhysics3D> _physics; // 接続物と同じ物理空間で解く区間剛体
	double _rope_mass = 1.0, _last_delta = 1.0 / 60.0; // 合計質量と速度換算時間
	godot::Vector2 _uv_range = godot::Vector2(0, 1); // 切断後も素材の対応範囲を保つ
	bool _preserve_state = false; // 切断ノードのreadyで粒子を初期化しない
	godot::NodePath _attachment_body;
	uint64_t _attachment_target_id = 0;
	godot::Ref<godot::ArrayMesh> _mesh;
	int _mesh_points = 0; // GPUへ登録済みの粒子数
	bool _dynamic_mesh = true; // UVと接続順を再生成せず頂点だけ転送する
	godot::Ref<godot::StandardMaterial3D> _material;
	bool _line_mode = false, _simulation_enabled = true, _pin_start = true;
	bool _use_system_gravity = true;
	int _segments = 16, _constraint_iterations = 8, _attachment_point = -1;
	double _max_length = 0.0, _elasticity = 0.9, _damping = 0.02, _gravity_scale = 1.0;
	double _line_width = 0.04, _pixel_size = 0.01;
	godot::Vector3 _gravity = godot::Vector3(0, -9.8, 0);
	godot::Color _line_color = godot::Color(1, 1, 1, 1), _modulate = godot::Color(1, 1, 1, 1);
	double _effective_length() const;
	godot::Vector3 _effective_gravity() const;
	void _ensure_mesh(); void _update_mesh(); void _simulate(double delta);
	void _sync_attachment(); void _clear_attachment();
	virtual godot::Vector2 _visual_size() const;
	static void _bind_methods();
public:
	SpriteRope3D();
	SpriteRope3D *cut_at(int point);
	SpriteRope3D *cut_segment(const godot::Vector3 &from, const godot::Vector3 &to, double tolerance = 0.001);
	void set_rope_mass(double value); double get_rope_mass() const { return _rope_mass; }
	void set_uv_range(const godot::Vector2 &value); godot::Vector2 get_uv_range() const { return _uv_range; }
	godot::PackedVector3Array get_rope_velocities() const;
	void set_dynamic_mesh(bool enabled);
	bool is_dynamic_mesh() const { return _dynamic_mesh; }
	void _ready() override;
	void _physics_process(double delta) override;
	void reset_simulation();
	virtual void set_texture(const godot::Ref<godot::Texture2D> &texture);
	godot::Ref<godot::Texture2D> get_texture() const { return _texture; }
	void set_line_mode(bool enabled); bool is_line_mode() const { return _line_mode; }
	void set_simulation_enabled(bool enabled); bool is_simulation_enabled() const { return _simulation_enabled; }
	void set_pin_start(bool enabled); bool is_pin_start() const { return _pin_start; }
	void set_segments(int value); int get_segments() const { return _segments; }
	void set_constraint_iterations(int value); int get_constraint_iterations() const { return _constraint_iterations; }
	void set_max_length(double value); double get_max_length() const { return _max_length; }
	void set_elasticity(double value); double get_elasticity() const { return _elasticity; }
	void set_damping(double value); double get_damping() const { return _damping; }
	void set_use_system_gravity(bool enabled); bool is_using_system_gravity() const { return _use_system_gravity; }
	void set_gravity_scale(double value); double get_gravity_scale() const { return _gravity_scale; }
	void set_gravity(const godot::Vector3 &value); godot::Vector3 get_gravity() const { return _gravity; }
	godot::Vector3 get_effective_gravity() const { return _effective_gravity(); }
	void set_line_width(double value); double get_line_width() const { return _line_width; }
	void set_line_color(const godot::Color &value); godot::Color get_line_color() const { return _line_color; }
	virtual void set_pixel_size(double value); double get_pixel_size() const { return _pixel_size; }
	void set_modulate(const godot::Color &value); godot::Color get_modulate() const { return _modulate; }
	void set_attachment_body(const godot::NodePath &path); godot::NodePath get_attachment_body() const { return _attachment_body; }
	void set_attachment_point(int value); int get_attachment_point() const { return _attachment_point; }
	godot::PackedVector3Array get_rope_points() const;
	godot::String get_simulation_backend() const;
};

class SVGRope3D : public SpriteRope3D {
	GDCLASS(SVGRope3D, SpriteRope3D)
	SVGTexture _svg;
protected:
	static void _bind_methods();
	godot::Vector2 _visual_size() const override;
	void _validate_property(godot::PropertyInfo &property) const;
public:
	void set_src(const godot::String &src);
	godot::String get_src() const { return _svg.get_src(); }
	godot::Vector2 get_svg_size() const { return _svg.draw_size(); }
	void set_pixel_size(double value) override;
};

} // namespace svg2d
#endif

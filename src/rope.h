#ifndef SVG2D_ROPE_H
#define SVG2D_ROPE_H

#include "svg.h"
#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
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
	bool _line_mode = false, _simulation_enabled = true, _pin_start = true;
	bool _use_system_gravity = true;
	int _segments = 16, _constraint_iterations = 8;
	double _max_length = 0.0, _elasticity = 0.9, _damping = 0.02, _gravity_scale = 1.0, _line_width = 4.0;
	godot::Vector2 _gravity = godot::Vector2(0, 980);
	godot::Color _line_color = godot::Color(1, 1, 1, 1);
	double _effective_length() const;
	godot::Vector2 _effective_gravity() const;
	void _simulate(double delta);
	virtual godot::Vector2 _visual_size() const;
	static void _bind_methods();
public:
	SpriteRope2D();
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
	godot::Ref<godot::ArrayMesh> _mesh;
	godot::Ref<godot::StandardMaterial3D> _material;
	bool _line_mode = false, _simulation_enabled = true, _pin_start = true;
	bool _use_system_gravity = true;
	int _segments = 16, _constraint_iterations = 8;
	double _max_length = 0.0, _elasticity = 0.9, _damping = 0.02, _gravity_scale = 1.0;
	double _line_width = 0.04, _pixel_size = 0.01;
	godot::Vector3 _gravity = godot::Vector3(0, -9.8, 0);
	godot::Color _line_color = godot::Color(1, 1, 1, 1), _modulate = godot::Color(1, 1, 1, 1);
	double _effective_length() const;
	godot::Vector3 _effective_gravity() const;
	void _ensure_mesh(); void _update_mesh(); void _simulate(double delta);
	virtual godot::Vector2 _visual_size() const;
	static void _bind_methods();
public:
	SpriteRope3D();
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

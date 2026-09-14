#ifndef SVG2D_ROPE_H
#define SVG2D_ROPE_H

#include "svg.h"

#include <godot_cpp/classes/array_mesh.hpp>
#include <godot_cpp/classes/mesh_instance3d.hpp>
#include <godot_cpp/classes/standard_material3d.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>

#include <vector>

namespace svg2d {

class SVGRope2D : public godot::Node2D {
	GDCLASS(SVGRope2D, godot::Node2D)

	SVGTexture _svg;
	std::vector<godot::Vector2> _points;
	std::vector<godot::Vector2> _previous;
	bool _line_mode = false;
	bool _simulation_enabled = true;
	bool _pin_start = true;
	int _segments = 16;
	int _constraint_iterations = 8;
	double _max_length = 0.0;
	double _elasticity = 0.9;
	double _damping = 0.02;
	double _line_width = 4.0;
	godot::Vector2 _gravity = godot::Vector2(0, 980);
	godot::Color _line_color = godot::Color(1, 1, 1, 1);

	double _effective_length() const;
	void _simulate(double delta);

protected:
	static void _bind_methods();

public:
	SVGRope2D();
	void _ready() override;
	void _draw() override;
	void _physics_process(double delta) override;
	void reset_simulation();

	void set_src(const godot::String &src);
	godot::String get_src() const { return _svg.get_src(); }
	void set_line_mode(bool enabled);
	bool is_line_mode() const { return _line_mode; }
	void set_simulation_enabled(bool enabled);
	bool is_simulation_enabled() const { return _simulation_enabled; }
	void set_pin_start(bool enabled);
	bool is_pin_start() const { return _pin_start; }
	void set_segments(int segments);
	int get_segments() const { return _segments; }
	void set_constraint_iterations(int iterations);
	int get_constraint_iterations() const { return _constraint_iterations; }
	void set_max_length(double length);
	double get_max_length() const { return _max_length; }
	void set_elasticity(double elasticity);
	double get_elasticity() const { return _elasticity; }
	void set_damping(double damping);
	double get_damping() const { return _damping; }
	void set_gravity(const godot::Vector2 &gravity);
	godot::Vector2 get_gravity() const { return _gravity; }
	void set_line_width(double width);
	double get_line_width() const { return _line_width; }
	void set_line_color(const godot::Color &color);
	godot::Color get_line_color() const { return _line_color; }
	godot::PackedVector2Array get_rope_points() const;
	godot::Vector2 get_svg_size() const { return _svg.draw_size(); }
};

class SVGRope3D : public godot::Node3D {
	GDCLASS(SVGRope3D, godot::Node3D)

	SVGTexture _svg;
	std::vector<godot::Vector3> _points;
	std::vector<godot::Vector3> _previous;
	godot::MeshInstance3D *_mesh_instance = nullptr;
	godot::Ref<godot::ArrayMesh> _mesh;
	godot::Ref<godot::StandardMaterial3D> _material;
	bool _line_mode = false;
	bool _simulation_enabled = true;
	bool _pin_start = true;
	int _segments = 16;
	int _constraint_iterations = 8;
	double _max_length = 0.0;
	double _elasticity = 0.9;
	double _damping = 0.02;
	double _line_width = 0.04;
	double _pixel_size = 0.01;
	godot::Vector3 _gravity = godot::Vector3(0, -9.8, 0);
	godot::Color _line_color = godot::Color(1, 1, 1, 1);
	godot::Color _modulate = godot::Color(1, 1, 1, 1);

	double _effective_length() const;
	void _ensure_mesh();
	void _update_mesh();
	void _simulate(double delta);

protected:
	static void _bind_methods();

public:
	SVGRope3D();
	void _ready() override;
	void _physics_process(double delta) override;
	void reset_simulation();

	void set_src(const godot::String &src);
	godot::String get_src() const { return _svg.get_src(); }
	void set_line_mode(bool enabled);
	bool is_line_mode() const { return _line_mode; }
	void set_simulation_enabled(bool enabled);
	bool is_simulation_enabled() const { return _simulation_enabled; }
	void set_pin_start(bool enabled);
	bool is_pin_start() const { return _pin_start; }
	void set_segments(int segments);
	int get_segments() const { return _segments; }
	void set_constraint_iterations(int iterations);
	int get_constraint_iterations() const { return _constraint_iterations; }
	void set_max_length(double length);
	double get_max_length() const { return _max_length; }
	void set_elasticity(double elasticity);
	double get_elasticity() const { return _elasticity; }
	void set_damping(double damping);
	double get_damping() const { return _damping; }
	void set_gravity(const godot::Vector3 &gravity);
	godot::Vector3 get_gravity() const { return _gravity; }
	void set_line_width(double width);
	double get_line_width() const { return _line_width; }
	void set_line_color(const godot::Color &color);
	godot::Color get_line_color() const { return _line_color; }
	void set_pixel_size(double size);
	double get_pixel_size() const { return _pixel_size; }
	void set_modulate(const godot::Color &color);
	godot::Color get_modulate() const { return _modulate; }
	godot::PackedVector3Array get_rope_points() const;
	godot::Vector2 get_svg_size() const { return _svg.draw_size(); }
};

} // namespace svg2d

#endif

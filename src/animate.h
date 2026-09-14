#ifndef SVG2D_ANIMATE_H
#define SVG2D_ANIMATE_H

#include "svg.h"

#include <godot_cpp/templates/list.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <memory>

namespace svg2d {

class SVGPathAnimationData;

class SVGAnimate2D : public SVG2D {
	GDCLASS(SVGAnimate2D, SVG2D)
	std::unique_ptr<SVGPathAnimationData> _paths;
protected:
	static void _bind_methods();
public:
	SVGAnimate2D();
	~SVGAnimate2D();
	void set_src(const godot::String &src) override;
	godot::String get_src() const override;
	int get_path_count() const;
	int get_point_count(int path) const;
	godot::Vector2 get_path_point(int path, int point) const;
	void set_path_point(int path, int point, const godot::Vector2 &value);
	godot::Vector2 get_in_handle(int path, int point) const;
	void set_in_handle(int path, int point, const godot::Vector2 &value);
	godot::Vector2 get_out_handle(int path, int point) const;
	void set_out_handle(int path, int point, const godot::Vector2 &value);
	godot::PackedVector2Array get_path_points(int path) const;
	bool _set(const godot::StringName &name, const godot::Variant &value);
	bool _get(const godot::StringName &name, godot::Variant &value) const;
	void _get_property_list(godot::List<godot::PropertyInfo> *list) const;
};

class SVGAnimate3D : public SVG3D {
	GDCLASS(SVGAnimate3D, SVG3D)
	std::unique_ptr<SVGPathAnimationData> _paths;
protected:
	static void _bind_methods();
public:
	SVGAnimate3D();
	~SVGAnimate3D();
	void set_src(const godot::String &src) override;
	godot::String get_src() const override;
	int get_path_count() const;
	int get_point_count(int path) const;
	godot::Vector2 get_path_point(int path, int point) const;
	void set_path_point(int path, int point, const godot::Vector2 &value);
	godot::Vector2 get_in_handle(int path, int point) const;
	void set_in_handle(int path, int point, const godot::Vector2 &value);
	godot::Vector2 get_out_handle(int path, int point) const;
	void set_out_handle(int path, int point, const godot::Vector2 &value);
	godot::PackedVector2Array get_path_points(int path) const;
	bool _set(const godot::StringName &name, const godot::Variant &value);
	bool _get(const godot::StringName &name, godot::Variant &value) const;
	void _get_property_list(godot::List<godot::PropertyInfo> *list) const;
};

} // namespace svg2d
#endif

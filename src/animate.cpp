// SVGの接点と曲線ハンドルを編集する実装。
// 責務: パス構造を保ち、変更した道だけ文字列化して表示更新をまとめる。
#include "animate.h"
#include "svg/xml.h"
#include "svg/paint.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/resource_uid.hpp>
#include <godot_cpp/classes/global_constants.hpp>
#include <godot_cpp/classes/xml_parser.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/callable_method_pointer.hpp>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cmath>
#include <functional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace godot;

namespace svg2d {

struct EditSegment {
	char kind = 'L';
	Vector2 end, c1, c2;
	double rx = 0, ry = 0, rotation = 0;
	bool large_arc = false, sweep = false;
	int from = -1, point = -1;
};

struct EditPoint {
	Vector2 anchor, in_handle, out_handle;
	int incoming = -1, outgoing = -1, move = -1; // 接続先と始点命令を直接引く
};

struct EditPath {
	std::vector<EditSegment> segments;
	std::vector<EditPoint> points;
};

struct PathSlot {
	size_t begin = 0, end = 0;
	EditPath path;
	std::string text; // 編集済みパスの文字列。未編集なら元の範囲を使う
	bool dirty = false; // 再文字列化が必要な道
	bool geometry_changed = false; // 色だけを再生成しても編集済み d を残す
	bool shape = false; // 基本図形の札を保ったまま編集後の道を内部属性で渡す
	std::string opening; // 元の色・線・変換属性を残すための開始タグ
	size_t d_begin = 0, d_end = 0; // path の開始タグ内にある d の相対範囲
	String fill = "black", stroke = "none";
	double fill_opacity = 1.0, stroke_opacity = 1.0, stroke_width = 1.0;
	bool style_dirty = false;
	bool fill_changed = false, stroke_changed = false;
	bool fill_opacity_changed = false, stroke_opacity_changed = false, stroke_width_changed = false;
	// path自身の座標から、実際に描かれるSVG文書座標への変換。
	std::vector<Transform2D> displays; // use による複数の表示実体
};

static std::vector<double> edit_numbers(const String &text) {
	std::vector<double> out;
	CharString bytes = text.utf8();
	const char *p = bytes.get_data();
	while (*p) {
		while (*p && (std::isspace((unsigned char)*p) || *p == ',')) p++;
		if (!*p) break;
		char *end = nullptr;
		double value = std::strtod(p, &end);
		if (end == p) break;
		out.push_back(value);
		p = end;
	}
	return out;
}

static Transform2D edit_transform(const String &text) {
	Transform2D result;
	int at = 0;
	while (at < text.length()) {
		int lp = text.find("(", at), rp = lp < 0 ? -1 : text.find(")", lp);
		if (lp < 0 || rp < 0) break;
		String name = text.substr(at, lp - at).strip_edges();
		while (!name.is_empty() && (name[0] == ',' || std::isspace((unsigned char)name[0])))
			name = name.substr(1);
		std::vector<double> v = edit_numbers(text.substr(lp + 1, rp - lp - 1));
		Transform2D one;
		if (name == "translate" && !v.empty()) {
			one.set_origin(Vector2((float)v[0], (float)(v.size() > 1 ? v[1] : 0.0)));
		} else if (name == "scale" && !v.empty()) {
			one = Transform2D((float)v[0], 0, 0, (float)(v.size() > 1 ? v[1] : v[0]), 0, 0);
		} else if (name == "rotate" && !v.empty()) {
			double a = v[0] * Math::PI / 180.0;
			Transform2D rotation((float)std::cos(a), (float)std::sin(a),
					(float)-std::sin(a), (float)std::cos(a), 0, 0);
			if (v.size() >= 3) {
				Transform2D to, back;
				to.set_origin(Vector2((float)v[1], (float)v[2]));
				back.set_origin(Vector2((float)-v[1], (float)-v[2]));
				one = to * rotation * back;
			} else one = rotation;
		} else if ((name == "skewX" || name == "skewx") && !v.empty()) {
			one = Transform2D(1, 0, (float)std::tan(v[0] * Math::PI / 180.0), 1, 0, 0);
		} else if ((name == "skewY" || name == "skewy") && !v.empty()) {
			one = Transform2D(1, (float)std::tan(v[0] * Math::PI / 180.0), 0, 1, 0, 0);
		} else if (name == "matrix" && v.size() >= 6) {
			one = Transform2D((float)v[0], (float)v[1], (float)v[2], (float)v[3],
					(float)v[4], (float)v[5]);
		}
		result = result * one;
		at = rp + 1;
	}
	return result;
}

static Transform2D edit_view_fit(const Rect2 &view, const String &par, double width, double height) {
	double sx = width / view.size.x, sy = height / view.size.y;
	PackedStringArray words = par.strip_edges().split(" ", false);
	String align = words.is_empty() ? String("xMidYMid") : words[0];
	bool slice = words.size() > 1 && words[1] == "slice";
	if (align != "none") sx = sy = slice ? std::max(sx, sy) : std::min(sx, sy);
	double tx = -view.position.x * sx, ty = -view.position.y * sy;
	double rx = width - view.size.x * sx, ry = height - view.size.y * sy;
	if (align.contains("xMid")) tx += rx * 0.5;
	else if (align.contains("xMax")) tx += rx;
	if (align.contains("YMid")) ty += ry * 0.5;
	else if (align.contains("YMax")) ty += ry;
	return Transform2D((float)sx, 0, 0, (float)sy, (float)tx, (float)ty);
}

static double edit_length(const String &text, double fallback, double base) {
	if (text.is_empty()) return fallback;
	double value = text.to_float();
	if (text.ends_with("%")) value = value * 0.01 * base;
	else if (text.ends_with("pt")) value *= 96.0 / 72.0;
	else if (text.ends_with("pc")) value *= 16.0;
	else if (text.ends_with("mm")) value *= 96.0 / 25.4;
	else if (text.ends_with("cm")) value *= 96.0 / 2.54;
	else if (text.ends_with("in")) value *= 96.0;
	else if (text.ends_with("Q")) value *= 96.0 / 25.4 / 4.0;
	return std::isfinite(value) ? value : fallback;
}

struct EditTransformState {
	Transform2D transform;
	double width = 300.0;
	double height = 150.0;
	String fill = "black", stroke = "none";
	double fill_opacity = 1.0, stroke_opacity = 1.0;
	double stroke_width = 1.0;
};

// CSS と style 属性を解決済みの SVG 木から、文書順の実効ペイントを得る。
// 元のグラデーションや none を初期キーで単色に潰さないために必要。
static std::vector<EditTransformState> path_paints(const String &markup) {
	std::vector<EditTransformState> result;
	SVG document;
	if (!document.parse(markup) || document.get_root() == nullptr) return result;
	std::function<void(const SVG::Elem &, EditTransformState)> visit =
			[&](const SVG::Elem &element, EditTransformState state) {
			auto attr = [&](const char *name) {
				auto found = element.attr.find(name);
				return found == element.attr.end() ? String() : found->second;
			};
			String value;
			if (element.tag == "svg") {
				state.width = edit_length(attr("width"), state.width, state.width);
				state.height = edit_length(attr("height"), state.height, state.height);
				std::vector<double> view = edit_numbers(attr("viewBox"));
				if (view.size() >= 4 && view[2] > 0 && view[3] > 0) {
					state.width = view[2]; state.height = view[3];
				}
			}
			if (!(value = attr("fill")).is_empty()) state.fill = value;
			if (!(value = attr("stroke")).is_empty()) state.stroke = value;
			if (!(value = attr("fill-opacity")).is_empty()) state.fill_opacity = edit_length(value, 1, 1);
			if (!(value = attr("stroke-opacity")).is_empty()) state.stroke_opacity = edit_length(value, 1, 1);
			if (!(value = attr("stroke-width")).is_empty())
				state.stroke_width = edit_length(value, 1, std::hypot(state.width, state.height) / std::sqrt(2.0));
			const std::string &tag = element.tag;
			if (tag == "path" || tag == "rect" || tag == "circle" || tag == "ellipse"
					|| tag == "line" || tag == "polyline" || tag == "polygon") result.push_back(state);
			for (const auto &child : element.kids) visit(*child, state);
		};
	visit(*document.get_root(), EditTransformState());
	return result;
}

static std::string xml_escape(const String &value) {
	std::string out;
	for (char c : std::string(value.utf8().get_data())) {
		switch (c) {
			case '&': out += "&amp;"; break;
			case '<': out += "&lt;"; break;
			case '"': out += "&quot;"; break;
			case '\'': out += "&apos;"; break;
			default: out += c; break;
		}
	}
	return out;
}

static std::string color_paint(const Color &color) { return std::string(color.to_html(true).utf8().get_data()).insert(0, "#"); }

static void append_style(std::string &tag, const std::string &declarations) {
	if (declarations.empty()) return;
	// style="" は presentation 属性や <style> 規則より強い。既存 style の末尾へ追加する。
	size_t at = 1;
	while (at < tag.size()) {
		while (at < tag.size() && std::isspace((unsigned char)tag[at])) at++;
		if (at >= tag.size() || tag[at] == '/' || tag[at] == '>') break;
		size_t begin = at;
		while (at < tag.size() && !std::isspace((unsigned char)tag[at]) && tag[at] != '=' && tag[at] != '>') at++;
		std::string name = tag.substr(begin, at - begin);
		while (at < tag.size() && std::isspace((unsigned char)tag[at])) at++;
		if (at >= tag.size() || tag[at] != '=') continue;
		at++;
		while (at < tag.size() && std::isspace((unsigned char)tag[at])) at++;
		if (at >= tag.size() || (tag[at] != '\'' && tag[at] != '"')) continue;
		char quote = tag[at++];
		size_t end = tag.find(quote, at);
		if (end == std::string::npos) break;
		if (name == "style") { tag.insert(end, ";" + declarations); return; }
		at = end + 1;
	}
	size_t end = tag.rfind('>');
	if (end == std::string::npos) return;
	if (end > 0 && tag[end - 1] == '/') end--;
	tag.insert(end, " style=\"" + declarations + "\"");
}

static std::string edit_local_tag(const std::string &tag, const std::string &markup) {
	size_t colon = tag.find(':');
	if (colon == std::string::npos) return tag;
	std::string declaration = "xmlns:" + tag.substr(0, colon);
	size_t at = markup.find(declaration);
	while (at != std::string::npos) {
		at += declaration.size();
		while (at < markup.size() && std::isspace((unsigned char)markup[at])) at++;
		if (at < markup.size() && markup[at++] == '=') {
			while (at < markup.size() && std::isspace((unsigned char)markup[at])) at++;
			if (at < markup.size() && (markup[at] == '\'' || markup[at] == '"')) {
				char quote = markup[at++];
				if (markup.compare(at, 26, "http://www.w3.org/2000/svg") == 0
						&& at + 26 < markup.size() && markup[at + 26] == quote)
					return tag.substr(colon + 1);
			}
		}
		at = markup.find(declaration, at);
	}
	return tag;
}

static std::vector<EditTransformState> path_display_transforms(const String &markup) {
	std::vector<EditTransformState> result;
	std::string source(markup.utf8().get_data());
	Ref<XMLParser> parser;
	parser.instantiate();
	PackedByteArray buffer = markup.to_utf8_buffer();
	if (parser->open_buffer(buffer) != OK) return result;
	std::vector<EditTransformState> stack;
	while (read_svg_node(parser, buffer) == OK) {
		int type = parser->get_node_type();
		if (type == XMLParser::NODE_ELEMENT_END) {
			if (!stack.empty()) stack.pop_back();
			continue;
		}
		if (type != XMLParser::NODE_ELEMENT) continue;
		String tag = String::utf8(edit_local_tag(std::string(String(parser->get_node_name()).utf8().get_data()), source).c_str());
		auto attr = [&](const char *name) {
			for (int i = 0; i < parser->get_attribute_count(); i++)
				if (parser->get_attribute_name(i) == name) return parser->get_attribute_value(i);
			return String();
		};
		EditTransformState state = stack.empty() ? EditTransformState() : stack.back();
		bool root = stack.empty() && tag == "svg";
		if (root) {
			std::vector<double> vb = edit_numbers(attr("viewBox"));
			double declared_w = edit_length(attr("width"), 0, 0);
			double declared_h = edit_length(attr("height"), 0, 0);
			if (declared_w > 0 && declared_h > 0) {
				state.width = declared_w;
				state.height = declared_h;
			} else if (vb.size() >= 4 && vb[2] > 0 && vb[3] > 0) {
				state.width = vb[2];
				state.height = vb[3];
			}
			if (vb.size() >= 4 && vb[2] > 0 && vb[3] > 0) {
				String par = attr("preserveAspectRatio");
				state.transform = edit_view_fit(Rect2((float)vb[0], (float)vb[1],
						(float)vb[2], (float)vb[3]), par.is_empty() ? "xMidYMid meet" : par,
						state.width, state.height);
				state.width = vb[2]; state.height = vb[3];
			}
			state.transform = state.transform * edit_transform(attr("transform"));
		} else {
			state.transform = state.transform * edit_transform(attr("transform"));
			if (tag == "svg") {
				double width = edit_length(attr("width"), state.width, state.width);
				double height = edit_length(attr("height"), state.height, state.height);
				Transform2D move;
				move.set_origin(Vector2((float)edit_length(attr("x"), 0, state.width),
						(float)edit_length(attr("y"), 0, state.height)));
				state.transform = state.transform * move;
				std::vector<double> vb = edit_numbers(attr("viewBox"));
				if (vb.size() >= 4 && vb[2] > 0 && vb[3] > 0) {
					String par = attr("preserveAspectRatio");
					state.transform = state.transform * edit_view_fit(Rect2((float)vb[0], (float)vb[1],
							(float)vb[2], (float)vb[3]), par.is_empty() ? "xMidYMid meet" : par,
							width, height);
					state.width = vb[2]; state.height = vb[3];
				} else { state.width = width; state.height = height; }
			}
		}
		if (tag == "path" || tag == "rect" || tag == "circle" || tag == "ellipse"
				|| tag == "line" || tag == "polyline" || tag == "polygon")
			result.push_back(state);
		if (!parser->is_empty()) stack.push_back(state);
	}
	return result;
}

// 文書内の定義は直接表示しない。use が作る各実体を描画と同じ順・変換で列挙する。
static std::vector<std::vector<Transform2D>> path_render_instances(const String &markup) {
	SVG document;
	if (!document.parse(markup) || document.get_root() == nullptr) return {};
	using Elem = SVG::Elem;
	const Elem *root = document.get_root();
	std::vector<std::vector<Transform2D>> result;
	std::unordered_map<const Elem *, size_t> indexes;
	std::unordered_map<std::string, const Elem *> ids;
	auto attr = [](const Elem &e, const char *key) -> String {
		auto found = e.attr.find(key);
		return found == e.attr.end() ? String() : found->second;
	};
	auto geometry = [](const std::string &tag) {
		return tag == "path" || tag == "rect" || tag == "circle" || tag == "ellipse"
				|| tag == "line" || tag == "polyline" || tag == "polygon";
	};
	std::function<void(const Elem &)> index = [&](const Elem &e) {
		if (geometry(e.tag)) { indexes[&e] = result.size(); result.emplace_back(); }
		String id = attr(e, "id");
		if (!id.is_empty()) ids[std::string(id.utf8().get_data())] = &e;
		for (const auto &child : e.kids) index(*child);
	};
	index(*root);
	EditTransformState initial;
	std::vector<double> root_view = edit_numbers(attr(*root, "viewBox"));
	double width = edit_length(attr(*root, "width"), 0, 0);
	double height = edit_length(attr(*root, "height"), 0, 0);
	if (width > 0 && height > 0) { initial.width = width; initial.height = height; }
	else if (root_view.size() >= 4 && root_view[2] > 0 && root_view[3] > 0) {
		initial.width = root_view[2]; initial.height = root_view[3];
	}
	if (root_view.size() >= 4 && root_view[2] > 0 && root_view[3] > 0) {
		String par = attr(*root, "preserveAspectRatio");
		initial.transform = edit_view_fit(Rect2((float)root_view[0], (float)root_view[1],
				(float)root_view[2], (float)root_view[3]),
				par.is_empty() ? "xMidYMid meet" : par, initial.width, initial.height);
		initial.width = root_view[2]; initial.height = root_view[3];
	}
	std::function<void(const Elem &, EditTransformState, int, int)> walk;
	walk = [&](const Elem &e, EditTransformState state, int depth, int uses) {
		if (depth > 256 || uses > 12) return;
		const std::string &tag = e.tag;
		if (tag == "defs" || tag == "symbol" || tag == "title" || tag == "desc"
				|| tag == "style" || tag == "linearGradient" || tag == "radialGradient"
				|| tag == "clipPath" || tag == "mask" || tag == "pattern"
				|| tag == "filter" || tag == "marker" || attr(e, "display") == "none") return;
		state.transform = state.transform * edit_transform(attr(e, "transform"));
		String fill = attr(e, "fill"), stroke = attr(e, "stroke");
		if (!fill.is_empty()) state.fill = fill;
		if (!stroke.is_empty()) state.stroke = stroke;
		String fill_opacity = attr(e, "fill-opacity"), stroke_opacity = attr(e, "stroke-opacity");
		if (!fill_opacity.is_empty()) state.fill_opacity = edit_length(fill_opacity, 1, 1);
		if (!stroke_opacity.is_empty()) state.stroke_opacity = edit_length(stroke_opacity, 1, 1);
		if (edit_length(attr(e, "opacity"), 1, 1) <= 0) return;
		if (tag == "svg" && &e != root) {
			double parent_w = state.width, parent_h = state.height;
			double w = edit_length(attr(e, "width"), parent_w, parent_w);
			double h = edit_length(attr(e, "height"), parent_h, parent_h);
			Transform2D move;
			move.set_origin(Vector2((float)edit_length(attr(e, "x"), 0, parent_w),
					(float)edit_length(attr(e, "y"), 0, parent_h)));
			state.transform = state.transform * move;
			std::vector<double> vb = edit_numbers(attr(e, "viewBox"));
			if (vb.size() >= 4 && vb[2] > 0 && vb[3] > 0) {
				String par = attr(e, "preserveAspectRatio");
				state.transform = state.transform * edit_view_fit(Rect2((float)vb[0], (float)vb[1],
						(float)vb[2], (float)vb[3]), par.is_empty() ? "xMidYMid meet" : par, w, h);
				state.width = vb[2]; state.height = vb[3];
			} else { state.width = w; state.height = h; }
		}
		if (geometry(tag)) {
			// 透明な補助パスは編集点として重ねない。実表示できる要素だけを対象にする。
			bool fill_visible = state.fill != "none" && state.fill_opacity > 0;
			bool stroke_visible = state.stroke != "none" && state.stroke_opacity > 0;
			if (!fill_visible && !stroke_visible) return;
			auto found = indexes.find(&e);
			if (found != indexes.end()) result[found->second].push_back(state.transform);
			return;
		}
		if (tag == "use") {
			String href = attr(e, "href");
			if (href.is_empty()) href = attr(e, "xlink:href");
			if (!href.begins_with("#")) return;
			auto ref = ids.find(std::string(href.substr(1).utf8().get_data()));
			if (ref == ids.end()) return;
			const Elem &target = *ref->second;
			double x = edit_length(attr(e, "x"), 0, state.width);
			double y = edit_length(attr(e, "y"), 0, state.height);
			if (target.tag == "symbol" || target.tag == "svg") {
				String sw = attr(e, "width"), sh = attr(e, "height");
				if (sw.is_empty()) sw = attr(target, "width");
				if (sh.is_empty()) sh = attr(target, "height");
				double w = edit_length(sw, state.width, state.width);
				double h = edit_length(sh, state.height, state.height);
				Transform2D move; move.set_origin(Vector2((float)x, (float)y));
				state.transform = state.transform * move;
				std::vector<double> vb = edit_numbers(attr(target, "viewBox"));
				if (vb.size() >= 4 && vb[2] > 0 && vb[3] > 0) {
					String par = attr(target, "preserveAspectRatio");
					state.transform = state.transform * edit_view_fit(Rect2((float)vb[0], (float)vb[1],
							(float)vb[2], (float)vb[3]), par.is_empty() ? "xMidYMid meet" : par, w, h);
					state.width = vb[2]; state.height = vb[3];
				} else { state.width = w; state.height = h; }
				for (const auto &child : target.kids) walk(*child, state, depth + 1, uses + 1);
			} else {
				Transform2D move; move.set_origin(Vector2((float)x, (float)y));
				state.transform = state.transform * move;
				walk(target, state, depth + 1, uses + 1);
			}
			return;
		}
		for (const auto &child : e.kids) walk(*child, state, depth + 1, uses);
	};
	walk(*root, initial, 0, 0);
	return result;
}

class SVGPathAnimationData {
public:
	String source;
	std::string markup;
	std::vector<PathSlot> slots;
	// PackedSceneは動的プロパティをsrcより先に復元するため、解析前の値を順序付きで待機する。
	std::vector<std::pair<StringName, Vector2>> pending;
	std::vector<std::pair<StringName, Variant>> style_pending;

	// 基本図形の接点を固定したパスとして扱い、編集前は元のSVGを描く。
	static std::string shape_path(const std::string &name,
			const std::vector<std::pair<std::string, String>> &attrs, const EditTransformState &state) {
		auto attr = [&](const char *key) -> String {
			for (const auto &entry : attrs) if (entry.first == key) return entry.second;
			return String();
		};
		auto length = [&](const char *key, double base, double fallback = 0.0) {
			return edit_length(attr(key), fallback, base);
		};
		double wbase = state.width, hbase = state.height;
		auto n = [](double value) { return std::string(String::num_real(value).utf8().get_data()); };
		auto xy = [&](double x, double y) { return n(x) + " " + n(y); };
		if (name == "line")
			return "M" + xy(length("x1", wbase), length("y1", hbase))
					+ " L" + xy(length("x2", wbase), length("y2", hbase));
		if (name == "polyline" || name == "polygon") {
			std::vector<double> values = edit_numbers(attr("points"));
			if (values.size() < (name == "polygon" ? 6u : 4u) || values.size() % 2) return {};
			std::string d = "M" + xy(values[0], values[1]);
			for (size_t i = 2; i < values.size(); i += 2) d += " L" + xy(values[i], values[i + 1]);
			return d + (name == "polygon" ? " Z" : "");
		}
		if (name == "circle" || name == "ellipse") {
			double cx = length("cx", wbase), cy = length("cy", hbase);
			double rx = name == "circle" ? length("r", std::hypot(wbase, hbase) / std::sqrt(2.0)) : length("rx", wbase);
			double ry = name == "circle" ? rx : length("ry", hbase);
			if (rx <= 0 || ry <= 0) return {};
			return "M" + xy(cx + rx, cy) + " A" + xy(rx, ry) + " 0 0 1 " + xy(cx - rx, cy)
					+ " A" + xy(rx, ry) + " 0 0 1 " + xy(cx + rx, cy) + " Z";
		}
		if (name != "rect") return {};
		double x = length("x", wbase), y = length("y", hbase);
		double w = length("width", wbase), h = length("height", hbase);
		if (w <= 0 || h <= 0) return {};
		String rx_text = attr("rx"), ry_text = attr("ry");
		double rx = rx_text.is_empty() ? length("ry", hbase) : length("rx", wbase);
		double ry = ry_text.is_empty() ? rx : length("ry", hbase);
		rx = std::clamp(rx, 0.0, w * 0.5); ry = std::clamp(ry, 0.0, h * 0.5);
		if (rx == 0 || ry == 0)
			return "M" + xy(x, y) + " L" + xy(x + w, y) + " L" + xy(x + w, y + h)
					+ " L" + xy(x, y + h) + " Z";
		return "M" + xy(x + rx, y) + " L" + xy(x + w - rx, y)
					+ " A" + xy(rx, ry) + " 0 0 1 " + xy(x + w, y + ry)
					+ " L" + xy(x + w, y + h - ry)
					+ " A" + xy(rx, ry) + " 0 0 1 " + xy(x + w - rx, y + h)
					+ " L" + xy(x + rx, y + h)
					+ " A" + xy(rx, ry) + " 0 0 1 " + xy(x, y + h - ry)
					+ " L" + xy(x, y + ry)
					+ " A" + xy(rx, ry) + " 0 0 1 " + xy(x + rx, y) + " Z";
	}

	static void skip(const char *&p) {
		while (*p && (std::isspace((unsigned char)*p) || *p == ',')) p++;
	}
	static bool number(const char *&p, double &out) {
		skip(p);
		char *end = nullptr;
		out = std::strtod(p, &end);
		if (end == p || !std::isfinite(out) || !std::isfinite((real_t)out)) return false;
		p = end;
		return true;
	}
	static Vector2 pair(const double *v, int at, bool relative, const Vector2 &base) {
		Vector2 q((float)v[(size_t)at], (float)v[(size_t)at + 1]);
		return relative ? base + q : q;
	}

	static EditPath parse_path(const std::string &text) {
		EditPath out;
		const char *p = text.c_str();
		char command = 0, previous_kind = 0;
		Vector2 current, sub_start, previous_quad;
		int current_point = -1, sub_point = -1;
		auto add_point = [&](const Vector2 &anchor) {
			EditPoint point;
			point.anchor = point.in_handle = point.out_handle = anchor;
			out.points.push_back(point);
			return (int)out.points.size() - 1;
		};
		auto add_segment = [&](EditSegment segment) {
			int index = (int)out.segments.size();
			if (segment.from >= 0) out.points[(size_t)segment.from].outgoing = index;
			if (segment.point >= 0) out.points[(size_t)segment.point].incoming = index;
			out.segments.push_back(segment);
		};
		while (*p) {
			skip(p);
			if (!*p) break;
			if (std::isalpha((unsigned char)*p)) command = *p++;
			else if (!command) break;
			bool relative = std::islower((unsigned char)command);
			char kind = (char)std::toupper((unsigned char)command);
			if (current_point < 0 && kind != 'M') break; // 始点なしの曲線は参照できない
			if (kind == 'Z') {
				EditSegment z; z.kind = 'Z'; z.from = current_point; z.point = sub_point; z.end = sub_start;
				add_segment(z); current = sub_start; current_point = sub_point; previous_kind = kind; command = 0; continue;
			}
			int count = kind == 'H' || kind == 'V' ? 1 : kind == 'M' || kind == 'L' || kind == 'T' ? 2
					: kind == 'S' || kind == 'Q' ? 4 : kind == 'C' ? 6 : kind == 'A' ? 7 : 0;
			if (!count) break;
			double v[7]; // SVGの1命令は最大7値。命令ごとの動的確保を避ける
			bool ok = true;
			for (int i = 0; i < count; i++) {
				if (kind == 'A' && (i == 3 || i == 4)) {
					skip(p);
					if (*p != '0' && *p != '1') { ok = false; break; }
					v[i] = *p++ - '0'; // 隣り合う円弧フラグも1文字ずつ読む
				} else if (!number(p, v[i])) { ok = false; break; }
			}
			if (!ok) break;
			Vector2 base = current, end;
			if (kind == 'H') end = Vector2((float)(relative ? current.x + v[0] : v[0]), current.y);
			else if (kind == 'V') end = Vector2(current.x, (float)(relative ? current.y + v[0] : v[0]));
			else end = pair(v, count - 2, relative, base);
			if (!end.is_finite()) break;
			if (kind == 'M') {
				current_point = add_point(end); sub_point = current_point; sub_start = end;
				out.points[(size_t)current_point].move = (int)out.segments.size();
				EditSegment m; m.kind = 'M'; m.end = end; m.point = current_point; add_segment(m);
				command = relative ? 'l' : 'L';
			} else {
				int next_point = add_point(end);
				EditSegment segment; segment.from = current_point; segment.point = next_point; segment.end = end;
				if (kind == 'C' || kind == 'S' || kind == 'Q' || kind == 'T') {
					segment.kind = 'C';
					if (kind == 'C') { segment.c1 = pair(v, 0, relative, base); segment.c2 = pair(v, 2, relative, base); }
					else if (kind == 'S') {
						segment.c1 = previous_kind == 'C' || previous_kind == 'S'
								? current * 2.0f - out.points[(size_t)current_point].in_handle : current;
						segment.c2 = pair(v, 0, relative, base);
					} else {
						Vector2 q = kind == 'Q' ? pair(v, 0, relative, base)
								: ((previous_kind == 'Q' || previous_kind == 'T') ? current * 2.0f - previous_quad : current);
						segment.c1 = current + (q - current) * (2.0f / 3.0f);
						segment.c2 = end + (q - end) * (2.0f / 3.0f);
						previous_quad = q;
					}
					if (!segment.c1.is_finite() || !segment.c2.is_finite()) { out.points.pop_back(); break; }
					out.points[(size_t)current_point].out_handle = segment.c1;
					out.points[(size_t)next_point].in_handle = segment.c2;
				} else if (kind == 'A') {
					segment.kind = 'A'; segment.rx = std::abs(v[0]); segment.ry = std::abs(v[1]);
					segment.rotation = v[2]; segment.large_arc = v[3] != 0; segment.sweep = v[4] != 0;
				} else segment.kind = 'L';
				add_segment(segment); current_point = next_point;
			}
			current = end; previous_kind = kind;
		}
		return out;
	}

	static std::string num(double value) { return std::string(String::num_real(value).utf8().get_data()); }
	static std::string serialize(const EditPath &path) {
		std::string out;
		for (const EditSegment &s : path.segments) {
			if (!out.empty()) out += ' ';
			out += s.kind;
			if (s.kind == 'Z') continue;
			if (s.kind == 'C') out += num(s.c1.x) + " " + num(s.c1.y) + " " + num(s.c2.x) + " " + num(s.c2.y) + " ";
			else if (s.kind == 'A') out += num(s.rx) + " " + num(s.ry) + " " + num(s.rotation) + " "
					+ (s.large_arc ? "1 " : "0 ") + (s.sweep ? "1 " : "0 ");
			out += num(s.end.x) + " " + num(s.end.y);
		}
		return out;
	}

	void parse(const String &src) {
		source = src; slots.clear();
		String path = src.strip_edges();
		if (path.begins_with("uid://")) path = ResourceUID::ensure_path(path);
		String text = src;
		if ((path.begins_with("res://") || path.begins_with("user://")) && path.get_extension().to_lower() == "svg")
			text = FileAccess::file_exists(path) ? FileAccess::get_file_as_string(path) : String();
		markup = std::string(text.utf8().get_data());
		if (text.strip_edges().is_empty()) return;
		std::vector<EditTransformState> displays = path_display_transforms(text);
		std::vector<EditTransformState> paints = path_paints(text);
		std::vector<std::vector<Transform2D>> instances = path_render_instances(text);
		size_t display_index = 0;
		// 引用符・コメント・CDATA内のpath文字列を編集対象へ混ぜない。
		size_t at = 0;
		while ((at = markup.find('<', at)) != std::string::npos) {
			const char *closing = markup.compare(at, 4, "<!--") == 0 ? "-->"
					: markup.compare(at, 9, "<![CDATA[") == 0 ? "]]>" : nullptr;
			if (markup.compare(at, 2, "<?") == 0) {
				size_t end = markup.find("?>", at + 2);
				if (end == std::string::npos) break;
				at = end + 2; continue;
			}
			if (!closing && markup.compare(at, 2, "<!") == 0) {
				int depth = 0; char quote = 0; // 文書宣言の内部集合と引用符を飛ばす
				for (at += 2; at < markup.size(); at++) {
					char c = markup[at];
					if (quote) { if (c == quote) quote = 0; continue; }
					if (c == '\'' || c == '"') quote = c;
					else if (c == '[') depth++;
					else if (c == ']') depth = std::max(0, depth - 1);
					else if (c == '>' && depth == 0) { at++; break; }
				}
				continue;
			}
			if (closing) {
				size_t end = markup.find(closing, at + 1);
				if (end == std::string::npos) break;
				at = end + 3; continue;
			}
			size_t name = ++at;
			while (at < markup.size() && !std::isspace((unsigned char)markup[at]) && markup[at] != '/' && markup[at] != '>') at++;
			std::string original_tag = markup.substr(name, at - name);
			std::string tag = edit_local_tag(original_tag, markup);
			bool is_path = tag == "path";
			bool is_shape = tag == "rect" || tag == "circle" || tag == "ellipse"
					|| tag == "line" || tag == "polyline" || tag == "polygon";
			EditTransformState display;
			EditTransformState paint;
			std::vector<Transform2D> visible;
			if (is_path || is_shape) {
				if (display_index < displays.size()) display = displays[display_index];
				if (display_index < paints.size()) paint = paints[display_index];
				if (display_index < instances.size()) visible = instances[display_index];
				display_index++;
			}
			std::vector<std::pair<std::string, String>> attrs;
			PathSlot path_slot;
			bool found_path = false;
			while (at < markup.size() && markup[at] != '>') {
				if (std::isspace((unsigned char)markup[at]) || markup[at] == '/') { at++; continue; }
				size_t key = at;
				while (at < markup.size() && !std::isspace((unsigned char)markup[at]) && markup[at] != '=' && markup[at] != '>') at++;
				std::string key_name = markup.substr(key, at - key);
				while (at < markup.size() && std::isspace((unsigned char)markup[at])) at++;
				if (at >= markup.size() || markup[at] == '>') break;
				if (markup[at++] != '=') continue;
				while (at < markup.size() && std::isspace((unsigned char)markup[at])) at++;
				if (at >= markup.size()) break;
				char quote = markup[at++];
				if (quote != '\'' && quote != '"') continue;
				size_t end = markup.find(quote, at);
				if (end == std::string::npos) { at = markup.size(); break; }
				if (is_shape) attrs.push_back({key_name, String::utf8(markup.substr(at, end - at).c_str())});
				if (is_path && key_name == "d" && !visible.empty()) {
					path_slot.d_begin = at - (name - 1); path_slot.d_end = end - (name - 1);
					path_slot.path = parse_path(markup.substr(at, end - at));
					found_path = !path_slot.path.points.empty();
				}
				at = end + 1;
			}
			if (at >= markup.size()) break;
			size_t opening_end = ++at;
			if (is_path && found_path) {
				path_slot.begin = name - 1; path_slot.end = opening_end;
				path_slot.opening = markup.substr(path_slot.begin, opening_end - path_slot.begin);
				path_slot.displays = visible;
				path_slot.fill = paint.fill; path_slot.stroke = paint.stroke;
				path_slot.fill_opacity = paint.fill_opacity;
				path_slot.stroke_opacity = paint.stroke_opacity;
				path_slot.stroke_width = paint.stroke_width;
				slots.push_back(std::move(path_slot));
			}
			if (!is_shape || visible.empty()) continue;
			std::string d = shape_path(tag, attrs, display);
			if (d.empty()) continue;
			PathSlot slot; slot.begin = name - 1; slot.end = opening_end;
			slot.opening = markup.substr(slot.begin, opening_end - slot.begin);
			if (slot.opening.find_last_not_of(" \t\r\n", slot.opening.size() - 2) != std::string::npos
					&& slot.opening[slot.opening.find_last_not_of(" \t\r\n", slot.opening.size() - 2)] != '/') {
				std::string close = "</" + original_tag + ">";
				size_t closing = markup.find(close, opening_end);
				if (closing == std::string::npos || !String::utf8(markup.substr(opening_end, closing - opening_end).c_str()).strip_edges().is_empty())
					continue;
				slot.end = closing + close.size();
				at = slot.end;
			}
			slot.shape = true; slot.displays = visible; slot.path = parse_path(d);
			slot.fill = paint.fill; slot.stroke = paint.stroke;
			slot.fill_opacity = paint.fill_opacity;
			slot.stroke_opacity = paint.stroke_opacity;
			slot.stroke_width = paint.stroke_width;
			if (!slot.path.points.empty()) slots.push_back(std::move(slot));
		}
	}

	// 未編集の道は元の文字列を使い、変更した道だけ組み直す。
	String rebuilt() {
		std::string out; out.reserve(markup.size()); size_t at = 0;
		for (PathSlot &slot : slots) {
			out.append(markup, at, slot.begin - at);
			if (slot.dirty || slot.style_dirty) {
				std::string tag = slot.opening;
				std::string d = slot.geometry_changed ? serialize(slot.path) : std::string();
				if (slot.shape) {
					if (slot.geometry_changed) {
						// 元タグと全属性を保つ。型セレクタ・clip・use の参照を変えない。
						size_t insert = tag.rfind('>');
						if (insert != std::string::npos) {
							insert = tag.rfind('/', insert) == insert - 1 ? insert - 1 : insert;
							tag.insert(insert, " data-svg2d-path=\"" + d + "\"");
						}
					}
				} else if (slot.geometry_changed) tag.replace(slot.d_begin, slot.d_end - slot.d_begin, d);
				std::string style;
				if (slot.fill_changed) style += "fill:" + xml_escape(slot.fill) + ";";
				if (slot.stroke_changed) style += "stroke:" + xml_escape(slot.stroke) + ";";
				if (slot.fill_opacity_changed) style += "fill-opacity:" + std::string(String::num_real(slot.fill_opacity).utf8().get_data()) + ";";
				if (slot.stroke_opacity_changed) style += "stroke-opacity:" + std::string(String::num_real(slot.stroke_opacity).utf8().get_data()) + ";";
				if (slot.stroke_width_changed) style += "stroke-width:" + std::string(String::num_real(slot.stroke_width).utf8().get_data()) + ";";
				append_style(tag, style);
				slot.text = tag + (slot.shape ? markup.substr(slot.begin + slot.opening.size(),
							slot.end - slot.begin - slot.opening.size()) : std::string());
				slot.dirty = false;
				slot.style_dirty = false;
			}
			if (slot.text.empty()) out.append(markup, slot.begin, slot.end - slot.begin);
			else out += slot.text;
			at = slot.end;
		}
		out.append(markup, at, std::string::npos);
		return String::utf8(out.c_str());
	}
	bool valid(int path, int point) const { return path >= 0 && path < (int)slots.size() && point >= 0 && point < (int)slots[(size_t)path].path.points.size(); }
	bool valid_path(int path) const { return path >= 0 && path < (int)slots.size(); }
	bool has_handle(int path, int index, bool incoming) const {
		const EditPoint *p = point(path, index);
		if (!p) return false;
		int segment = incoming ? p->incoming : p->outgoing;
		return segment >= 0 && slots[(size_t)path].path.segments[(size_t)segment].kind == 'C';
	}
	bool set_style(int path, const String &part, const Variant &value) {
		if (!valid_path(path)) return false;
		PathSlot &slot = slots[(size_t)path];
		if ((part == "fill_color" || part == "stroke_color") && value.get_type() == Variant::COLOR) {
			Color color = value;
			if (!std::isfinite(color.r) || !std::isfinite(color.g) || !std::isfinite(color.b) || !std::isfinite(color.a)) return false;
			String paint = String::utf8(color_paint(color).c_str());
			String &target = part == "fill_color" ? slot.fill : slot.stroke;
			bool &changed = part == "fill_color" ? slot.fill_changed : slot.stroke_changed;
			if (target != paint || !changed) { target = paint; changed = slot.style_dirty = true; }
			return true;
		}
		if ((part == "fill_paint" || part == "stroke_paint") && value.get_type() == Variant::STRING) {
			String paint = value;
			if (paint.is_empty() || paint.contains(";") || paint.contains("<")) return false;
			String &target = part == "fill_paint" ? slot.fill : slot.stroke;
			bool &changed = part == "fill_paint" ? slot.fill_changed : slot.stroke_changed;
			if (target != paint || !changed) { target = paint; changed = slot.style_dirty = true; }
			return true;
		}
		if (value.get_type() != Variant::FLOAT && value.get_type() != Variant::INT) return false;
		double number = value;
		if (!std::isfinite(number)) return false;
		double *target = nullptr; bool *changed = nullptr;
		if (part == "fill_opacity") { target = &slot.fill_opacity; changed = &slot.fill_opacity_changed; }
		else if (part == "stroke_opacity") { target = &slot.stroke_opacity; changed = &slot.stroke_opacity_changed; }
		else if (part == "stroke_width") { target = &slot.stroke_width; changed = &slot.stroke_width_changed; }
		if (!target || (part == "stroke_width" ? number < 0.0 : number < 0.0 || number > 1.0)) return false;
		if (*target != number || !*changed) { *target = number; *changed = slot.style_dirty = true; }
		return true;
	}
	bool get_style(int path, const String &part, Variant &value) const {
		if (!valid_path(path)) return false;
		const PathSlot &slot = slots[(size_t)path];
		if (part == "fill_paint") { value = slot.fill; return true; }
		if (part == "stroke_paint") { value = slot.stroke; return true; }
		if (part == "fill_color" || part == "stroke_color") {
			Color color;
			if (!svg::parse_color(part == "fill_color" ? slot.fill : slot.stroke, color)) return false;
			value = color; return true;
		}
		if (part == "fill_opacity") { value = slot.fill_opacity; return true; }
		if (part == "stroke_opacity") { value = slot.stroke_opacity; return true; }
		if (part == "stroke_width") { value = slot.stroke_width; return true; }
		return false;
	}
	int instance_count(int path) const { return path >= 0 && path < (int)slots.size() ? (int)slots[(size_t)path].displays.size() : 0; }
	Vector2 to_document(int path, const Vector2 &point, int instance = 0) const {
		return instance >= 0 && instance < instance_count(path) ? slots[(size_t)path].displays[(size_t)instance].xform(point) : point;
	}
	Vector2 from_document(int path, const Vector2 &point, int instance = 0) const {
		return instance >= 0 && instance < instance_count(path) ? slots[(size_t)path].displays[(size_t)instance].affine_inverse().xform(point) : point;
	}
	EditPoint *point(int path, int point) { return valid(path, point) ? &slots[(size_t)path].path.points[(size_t)point] : nullptr; }
	const EditPoint *point(int path, int point) const { return valid(path, point) ? &slots[(size_t)path].path.points[(size_t)point] : nullptr; }
	bool move_point(int path, int index, Vector2 value) {
		EditPoint *p = point(path, index);
		if (!p || !value.is_finite() || p->anchor == value) return false;
		Vector2 delta = value - p->anchor;
		if (!delta.is_finite() || !(p->in_handle + delta).is_finite() || !(p->out_handle + delta).is_finite()) return false;
		slots[(size_t)path].dirty = true;
		slots[(size_t)path].geometry_changed = true;
		p->anchor = value; p->in_handle += delta; p->out_handle += delta;
		EditPath &ep = slots[(size_t)path].path;
		if (p->incoming >= 0) { EditSegment &s = ep.segments[(size_t)p->incoming]; s.end = value; if (s.kind == 'C') s.c2 = p->in_handle; }
		if (p->move >= 0) ep.segments[(size_t)p->move].end = value;
		if (p->outgoing >= 0 && ep.segments[(size_t)p->outgoing].kind == 'C') ep.segments[(size_t)p->outgoing].c1 = p->out_handle;
		return true;
	}
	bool set_handle(int path, int index, Vector2 value, bool incoming) {
		EditPoint *p = point(path, index);
		if (!p || !value.is_finite() || (incoming ? p->in_handle : p->out_handle) == value) return false;
		EditPath &ep = slots[(size_t)path].path; int si = incoming ? p->incoming : p->outgoing;
		if (si < 0) return false; EditSegment &s = ep.segments[(size_t)si];
		if (s.kind != 'C') return false; // 円弧・直線を曲線へ変えてトポロジーを変えない。
		if (incoming) { p->in_handle = value; s.c2 = value; } else { p->out_handle = value; s.c1 = value; }
		slots[(size_t)path].dirty = true;
		slots[(size_t)path].geometry_changed = true;
		return true;
	}
};

enum PathPropertyPart { PATH_ANCHOR, PATH_IN_HANDLE, PATH_OUT_HANDLE };

// AnimationPlayerのプロパティ名を直接読み、分割文字列の確保を避ける。
static bool property_indices(const StringName &name, int &path, int &point, PathPropertyPart &part) {
	String text = name;
	const char32_t *at = text.ptr(), *end = at + text.length();
	auto literal = [&](const char32_t *value) {
		while (*value) { if (at == end || *at++ != *value++) return false; }
		return true;
	};
	auto index = [&](int &value) {
		value = 0;
		const char32_t *begin = at;
		while (at < end && *at >= '0' && *at <= '9') {
			if (at - begin >= 9) return false;
			value = value * 10 + (int)(*at++ - '0');
		}
		return at != begin;
	};
	if (!literal(U"paths/path_") || !index(path) || !literal(U"/point_") || !index(point)) return false;
	part = PATH_ANCHOR;
	if (at == end) return true;
	if (*at++ != '/' || at == end) return false;
	if (*at == 'i') { if (!literal(U"in_handle")) return false; part = PATH_IN_HANDLE; }
	else { if (!literal(U"out_handle")) return false; part = PATH_OUT_HANDLE; }
	return at == end;
}

static bool style_indices(const StringName &name, int &path, String &part) {
	String text = name;
	if (!text.begins_with("paths/path_")) return false;
	int slash = text.find("/", 11);
	if (slash < 0) return false;
	String index = text.substr(11, slash - 11);
	if (index.is_empty() || !index.is_valid_int()) return false;
	path = index.to_int();
	part = text.substr(slash + 1);
	return part == "fill_color" || part == "stroke_color" || part == "fill_paint"
			|| part == "stroke_paint" || part == "fill_opacity" || part == "stroke_opacity"
			|| part == "stroke_width";
}

#define ANIMATE_IMPL(CLASS, BASE) \
CLASS::CLASS() : _paths(new SVGPathAnimationData()) { set_cache_animation_frames(false); set_animation_cache_mode(1); } \
CLASS::~CLASS() = default; \
void CLASS::set_animation_cache_mode(int mode) { BASE::_path_texture().set_animation_cache_mode(mode); } \
int CLASS::get_animation_cache_mode() const { return BASE::_path_texture().get_animation_cache_mode(); } \
void CLASS::set_animation_cache_limit_mb(int limit) { BASE::_path_texture().set_animation_cache_limit_mb(limit); } \
int CLASS::get_animation_cache_limit_mb() const { return BASE::_path_texture().get_animation_cache_limit_mb(); } \
void CLASS::clear_animation_cache() { BASE::_path_texture().clear_animation_cache(); } \
int64_t CLASS::get_animation_cache_bytes() const { return BASE::_path_texture().get_animation_cache_bytes(); } \
int CLASS::get_animation_cache_frame_count() const { return BASE::_path_texture().get_animation_cache_frame_count(); } \
int64_t CLASS::get_animation_cache_hits() const { return BASE::_path_texture().get_animation_cache_hits(); } \
int64_t CLASS::get_animation_cache_misses() const { return BASE::_path_texture().get_animation_cache_misses(); } \
void CLASS::_queue_paths() { _path_dirty = true; if (!_deferred_updates) { flush_paths(); return; } if (_path_queued) return; _path_queued = true; callable_mp(this, &CLASS::_flush_paths).call_deferred(); } \
void CLASS::_flush_paths() { _path_queued = false; flush_paths(); } \
void CLASS::flush_paths() { if (!_path_dirty) return; _path_dirty = false; BASE::_set_path_src(_paths->rebuilt()); emit_signal("path_changed"); } \
void CLASS::set_deferred_updates(bool enabled) { _deferred_updates = enabled; if (!enabled) flush_paths(); } \
void CLASS::set_src(const String &src) { _path_dirty = false; _paths->parse(src); bool restored = false; for (const auto &entry : _paths->pending) { int path, point; PathPropertyPart part; if (!property_indices(entry.first, path, point, part) || !_paths->valid(path, point)) continue; if (part == PATH_ANCHOR) _paths->move_point(path, point, entry.second); else _paths->set_handle(path, point, entry.second, part == PATH_IN_HANDLE); restored = true; } _paths->pending.clear(); for (const auto &entry : _paths->style_pending) { int path; String part; if (style_indices(entry.first, path, part) && _paths->set_style(path, part, entry.second)) restored = true; } _paths->style_pending.clear(); BASE::set_src(restored ? _paths->rebuilt() : src); notify_property_list_changed(); emit_signal("path_changed"); } \
String CLASS::get_src() const { return _paths->source; } \
int CLASS::get_path_count() const { return (int)_paths->slots.size(); } \
int CLASS::get_path_instance_count(int path) const { return _paths->instance_count(path); } \
int CLASS::get_point_count(int path) const { return path >= 0 && path < get_path_count() ? (int)_paths->slots[(size_t)path].path.points.size() : 0; } \
Vector2 CLASS::get_path_point(int path, int point) const { const EditPoint *p = _paths->point(path, point); return p ? p->anchor : Vector2(); } \
Vector2 CLASS::get_in_handle(int path, int point) const { const EditPoint *p = _paths->point(path, point); return p ? p->in_handle : Vector2(); } \
Vector2 CLASS::get_out_handle(int path, int point) const { const EditPoint *p = _paths->point(path, point); return p ? p->out_handle : Vector2(); } \
void CLASS::set_path_point(int path, int point, const Vector2 &value) { if (_paths->move_point(path, point, value)) _queue_paths(); } \
void CLASS::set_in_handle(int path, int point, const Vector2 &value) { if (_paths->set_handle(path, point, value, true)) _queue_paths(); } \
void CLASS::set_out_handle(int path, int point, const Vector2 &value) { if (_paths->set_handle(path, point, value, false)) _queue_paths(); } \
bool CLASS::has_in_handle(int path, int point) const { return _paths->has_handle(path, point, true); } \
bool CLASS::has_out_handle(int path, int point) const { return _paths->has_handle(path, point, false); } \
PackedVector2Array CLASS::get_path_points(int path) const { PackedVector2Array out; int n = get_point_count(path); out.resize(n); Vector2 *data = out.ptrw(); for (int i = 0; i < n; i++) data[i] = _paths->slots[(size_t)path].path.points[(size_t)i].anchor; return out; } \
Vector2 CLASS::path_to_document(int path, const Vector2 &point) const { return _paths->to_document(path, point); } \
Vector2 CLASS::document_to_path(int path, const Vector2 &point) const { return _paths->from_document(path, point); } \
Vector2 CLASS::path_to_document_instance(int path, const Vector2 &point, int instance) const { return _paths->to_document(path, point, instance); } \
Vector2 CLASS::document_to_path_instance(int path, const Vector2 &point, int instance) const { return _paths->from_document(path, point, instance); } \
bool CLASS::_set(const StringName &name, const Variant &value) { int path, point; PathPropertyPart part; if (property_indices(name, path, point, part)) { if (value.get_type() != Variant::VECTOR2) return false; Vector2 v = value; if (!_paths->valid(path, point)) { _paths->pending.push_back({name, v}); return true; } if (part == PATH_ANCHOR) set_path_point(path, point, v); else if (part == PATH_IN_HANDLE) set_in_handle(path, point, v); else set_out_handle(path, point, v); return true; } String style; if (!style_indices(name, path, style)) return false; if (!_paths->valid_path(path)) { _paths->style_pending.push_back({name, value}); return true; } if (!_paths->set_style(path, style, value)) return false; if (_paths->slots[(size_t)path].style_dirty) _queue_paths(); return true; } \
bool CLASS::_get(const StringName &name, Variant &value) const { int path, point; PathPropertyPart part; if (property_indices(name, path, point, part)) { if (!_paths->valid(path, point)) return false; value = part == PATH_ANCHOR ? get_path_point(path, point) : part == PATH_IN_HANDLE ? get_in_handle(path, point) : get_out_handle(path, point); return true; } String style; return style_indices(name, path, style) && _paths->get_style(path, style, value); } \
void CLASS::_get_property_list(List<PropertyInfo> *list) const { for (int p = 0; p < get_path_count(); p++) { for (int i = 0; i < get_point_count(p); i++) { String base = "paths/path_" + itos(p) + "/point_" + itos(i); list->push_back(PropertyInfo(Variant::VECTOR2, base, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_KEYING_INCREMENTS)); if (has_in_handle(p, i)) list->push_back(PropertyInfo(Variant::VECTOR2, base + "/in_handle", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT)); if (has_out_handle(p, i)) list->push_back(PropertyInfo(Variant::VECTOR2, base + "/out_handle", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT)); } String base = "paths/path_" + itos(p) + "/"; Variant v; bool fill_solid = _paths->get_style(p, "fill_color", v); bool stroke_solid = _paths->get_style(p, "stroke_color", v); list->push_back(PropertyInfo(fill_solid ? Variant::COLOR : Variant::STRING, base + (fill_solid ? "fill_color" : "fill_paint"))); list->push_back(PropertyInfo(stroke_solid ? Variant::COLOR : Variant::STRING, base + (stroke_solid ? "stroke_color" : "stroke_paint"))); list->push_back(PropertyInfo(Variant::FLOAT, base + "fill_opacity", PROPERTY_HINT_RANGE, "0,1,0.001")); list->push_back(PropertyInfo(Variant::FLOAT, base + "stroke_opacity", PROPERTY_HINT_RANGE, "0,1,0.001")); list->push_back(PropertyInfo(Variant::FLOAT, base + "stroke_width", PROPERTY_HINT_RANGE, "0,1000,0.01,or_greater")); } } \
void CLASS::_bind_methods() { \
	ADD_SIGNAL(MethodInfo("path_changed")); \
	ClassDB::bind_method(D_METHOD("set_animation_cache_mode", "mode"), &CLASS::set_animation_cache_mode); \
	ClassDB::bind_method(D_METHOD("get_animation_cache_mode"), &CLASS::get_animation_cache_mode); \
	ClassDB::bind_method(D_METHOD("set_animation_cache_limit_mb", "limit"), &CLASS::set_animation_cache_limit_mb); \
	ClassDB::bind_method(D_METHOD("get_animation_cache_limit_mb"), &CLASS::get_animation_cache_limit_mb); \
	ClassDB::bind_method(D_METHOD("clear_animation_cache"), &CLASS::clear_animation_cache); \
	ClassDB::bind_method(D_METHOD("get_animation_cache_bytes"), &CLASS::get_animation_cache_bytes); \
	ClassDB::bind_method(D_METHOD("get_animation_cache_frame_count"), &CLASS::get_animation_cache_frame_count); \
	ClassDB::bind_method(D_METHOD("get_animation_cache_hits"), &CLASS::get_animation_cache_hits); \
	ClassDB::bind_method(D_METHOD("get_animation_cache_misses"), &CLASS::get_animation_cache_misses); \
	ADD_GROUP("Animation Cache", ""); \
	ADD_PROPERTY(PropertyInfo(Variant::INT, "animation_cache_mode", PROPERTY_HINT_ENUM, "Disabled,Exact Frames"), "set_animation_cache_mode", "get_animation_cache_mode"); \
	ADD_PROPERTY(PropertyInfo(Variant::INT, "animation_cache_limit_mb", PROPERTY_HINT_RANGE, "1,256,1,suffix:MiB"), "set_animation_cache_limit_mb", "get_animation_cache_limit_mb"); \
	ClassDB::bind_method(D_METHOD("set_deferred_updates", "enabled"), &CLASS::set_deferred_updates); \
	ClassDB::bind_method(D_METHOD("is_deferred_updates"), &CLASS::is_deferred_updates); \
	ClassDB::bind_method(D_METHOD("flush_paths"), &CLASS::flush_paths); \
	ADD_GROUP("Path Updates", ""); \
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "deferred_updates"), "set_deferred_updates", "is_deferred_updates"); \
	ClassDB::bind_method(D_METHOD("get_path_count"), &CLASS::get_path_count); ClassDB::bind_method(D_METHOD("get_point_count", "path"), &CLASS::get_point_count); \
	ClassDB::bind_method(D_METHOD("get_path_instance_count", "path"), &CLASS::get_path_instance_count); \
	ClassDB::bind_method(D_METHOD("get_path_point", "path", "point"), &CLASS::get_path_point); ClassDB::bind_method(D_METHOD("set_path_point", "path", "point", "value"), &CLASS::set_path_point); \
	ClassDB::bind_method(D_METHOD("get_in_handle", "path", "point"), &CLASS::get_in_handle); ClassDB::bind_method(D_METHOD("set_in_handle", "path", "point", "value"), &CLASS::set_in_handle); \
	ClassDB::bind_method(D_METHOD("get_out_handle", "path", "point"), &CLASS::get_out_handle); ClassDB::bind_method(D_METHOD("set_out_handle", "path", "point", "value"), &CLASS::set_out_handle); \
	ClassDB::bind_method(D_METHOD("has_in_handle", "path", "point"), &CLASS::has_in_handle); ClassDB::bind_method(D_METHOD("has_out_handle", "path", "point"), &CLASS::has_out_handle); \
	ClassDB::bind_method(D_METHOD("get_path_points", "path"), &CLASS::get_path_points); \
	ClassDB::bind_method(D_METHOD("path_to_document", "path", "point"), &CLASS::path_to_document); \
	ClassDB::bind_method(D_METHOD("document_to_path", "path", "point"), &CLASS::document_to_path); \
	ClassDB::bind_method(D_METHOD("path_to_document_instance", "path", "point", "instance"), &CLASS::path_to_document_instance); \
	ClassDB::bind_method(D_METHOD("document_to_path_instance", "path", "point", "instance"), &CLASS::document_to_path_instance); \
}

ANIMATE_IMPL(SVGAnimate2D, SVG2D)
ANIMATE_IMPL(SVGAnimate3D, SVG3D)

} // namespace svg2d

// SVGの接点と曲線ハンドルを編集する実装。
// 責務: パス構造を保ち、変更した道だけ文字列化して表示更新をまとめる。
#include "animate.h"
#include "svg/xml.h"

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
#include <string>
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
	// path自身の座標から、実際に描かれるSVG文書座標への変換。
	Transform2D display;
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
};

static std::vector<Transform2D> path_display_transforms(const String &markup) {
	std::vector<Transform2D> result;
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
		String tag = parser->get_node_name();
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
		if (tag == "path") result.push_back(state.transform);
		if (!parser->is_empty()) stack.push_back(state);
	}
	return result;
}

class SVGPathAnimationData {
public:
	String source;
	std::string markup;
	std::vector<PathSlot> slots;
	// PackedSceneは動的プロパティをsrcより先に復元するため、解析前の値を順序付きで待機する。
	std::vector<std::pair<StringName, Vector2>> pending;

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
		std::vector<Transform2D> displays = path_display_transforms(text);
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
			bool is_path = markup.compare(name, at - name, "path") == 0;
			Transform2D display;
			if (is_path) {
				if (display_index < displays.size()) display = displays[display_index];
				display_index++;
			}
			while (at < markup.size() && markup[at] != '>') {
				if (std::isspace((unsigned char)markup[at]) || markup[at] == '/') { at++; continue; }
				size_t key = at;
				while (at < markup.size() && !std::isspace((unsigned char)markup[at]) && markup[at] != '=' && markup[at] != '>') at++;
				bool is_d = at - key == 1 && markup[key] == 'd';
				while (at < markup.size() && std::isspace((unsigned char)markup[at])) at++;
				if (at >= markup.size() || markup[at] == '>') break;
				if (markup[at++] != '=') continue;
				while (at < markup.size() && std::isspace((unsigned char)markup[at])) at++;
				if (at >= markup.size()) break;
				char quote = markup[at++];
				if (quote != '\'' && quote != '"') continue;
				size_t end = markup.find(quote, at);
				if (end == std::string::npos) { at = markup.size(); break; }
				if (is_path && is_d) {
					PathSlot slot; slot.begin = at; slot.end = end; slot.display = display;
					slot.path = parse_path(markup.substr(at, end - at));
					if (!slot.path.points.empty()) slots.push_back(std::move(slot));
				}
				at = end + 1;
			}
			if (at < markup.size()) at++;
		}
	}

	// 未編集の道は元の文字列を使い、変更した道だけ組み直す。
	String rebuilt() {
		std::string out; out.reserve(markup.size()); size_t at = 0;
		for (PathSlot &slot : slots) {
			out.append(markup, at, slot.begin - at);
			if (slot.dirty) { slot.text = serialize(slot.path); slot.dirty = false; }
			if (slot.text.empty()) out.append(markup, slot.begin, slot.end - slot.begin);
			else out += slot.text;
			at = slot.end;
		}
		out.append(markup, at, std::string::npos);
		return String::utf8(out.c_str());
	}
	bool valid(int path, int point) const { return path >= 0 && path < (int)slots.size() && point >= 0 && point < (int)slots[(size_t)path].path.points.size(); }
	Vector2 to_document(int path, const Vector2 &point) const { return path >= 0 && path < (int)slots.size() ? slots[(size_t)path].display.xform(point) : point; }
	Vector2 from_document(int path, const Vector2 &point) const { return path >= 0 && path < (int)slots.size() ? slots[(size_t)path].display.affine_inverse().xform(point) : point; }
	EditPoint *point(int path, int point) { return valid(path, point) ? &slots[(size_t)path].path.points[(size_t)point] : nullptr; }
	const EditPoint *point(int path, int point) const { return valid(path, point) ? &slots[(size_t)path].path.points[(size_t)point] : nullptr; }
	bool move_point(int path, int index, Vector2 value) {
		EditPoint *p = point(path, index);
		if (!p || !value.is_finite() || p->anchor == value) return false;
		Vector2 delta = value - p->anchor;
		if (!delta.is_finite() || !(p->in_handle + delta).is_finite() || !(p->out_handle + delta).is_finite()) return false;
		slots[(size_t)path].dirty = true;
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
		return true;
	}
};

enum PathPropertyPart { PATH_ANCHOR, PATH_IN_HANDLE, PATH_OUT_HANDLE };

static bool property_indices(const StringName &name, int &path, int &point, PathPropertyPart &part) {
	String s = name;
	if (!s.begins_with("paths/path_")) return false;
	PackedStringArray parts = s.split("/");
	if ((parts.size() != 3 && parts.size() != 4) || !parts[1].begins_with("path_") || !parts[2].begins_with("point_")) return false;
	String p = parts[1].trim_prefix("path_"), i = parts[2].trim_prefix("point_");
	if (p.is_empty() || i.is_empty()) return false;
	for (int n = 0; n < p.length(); n++) if (p[n] < '0' || p[n] > '9') return false;
	for (int n = 0; n < i.length(); n++) if (i[n] < '0' || i[n] > '9') return false;
	if (p.length() > 9 || i.length() > 9) return false;
	path = p.to_int(); point = i.to_int();
	part = PATH_ANCHOR;
	if (parts.size() == 4) {
		if (parts[3] == "in_handle") part = PATH_IN_HANDLE;
		else if (parts[3] == "out_handle") part = PATH_OUT_HANDLE;
		else return false;
	}
	return true;
}

#define ANIMATE_IMPL(CLASS, BASE) \
CLASS::CLASS() : _paths(new SVGPathAnimationData()) { set_cache_animation_frames(false); } \
CLASS::~CLASS() = default; \
void CLASS::_queue_paths() { _path_dirty = true; if (!_deferred_updates) { flush_paths(); return; } if (_path_queued) return; _path_queued = true; callable_mp(this, &CLASS::_flush_paths).call_deferred(); } \
void CLASS::_flush_paths() { _path_queued = false; flush_paths(); } \
void CLASS::flush_paths() { if (!_path_dirty) return; _path_dirty = false; BASE::_set_path_src(_paths->rebuilt()); } \
void CLASS::set_deferred_updates(bool enabled) { _deferred_updates = enabled; if (!enabled) flush_paths(); } \
void CLASS::set_src(const String &src) { _path_dirty = false; _paths->parse(src); bool restored = false; for (const auto &entry : _paths->pending) { int path, point; PathPropertyPart part; if (!property_indices(entry.first, path, point, part) || !_paths->valid(path, point)) continue; if (part == PATH_ANCHOR) _paths->move_point(path, point, entry.second); else _paths->set_handle(path, point, entry.second, part == PATH_IN_HANDLE); restored = true; } _paths->pending.clear(); BASE::set_src(restored ? _paths->rebuilt() : src); notify_property_list_changed(); } \
String CLASS::get_src() const { return _paths->source; } \
int CLASS::get_path_count() const { return (int)_paths->slots.size(); } \
int CLASS::get_point_count(int path) const { return path >= 0 && path < get_path_count() ? (int)_paths->slots[(size_t)path].path.points.size() : 0; } \
Vector2 CLASS::get_path_point(int path, int point) const { const EditPoint *p = _paths->point(path, point); return p ? p->anchor : Vector2(); } \
Vector2 CLASS::get_in_handle(int path, int point) const { const EditPoint *p = _paths->point(path, point); return p ? p->in_handle : Vector2(); } \
Vector2 CLASS::get_out_handle(int path, int point) const { const EditPoint *p = _paths->point(path, point); return p ? p->out_handle : Vector2(); } \
void CLASS::set_path_point(int path, int point, const Vector2 &value) { if (_paths->move_point(path, point, value)) _queue_paths(); } \
void CLASS::set_in_handle(int path, int point, const Vector2 &value) { if (_paths->set_handle(path, point, value, true)) _queue_paths(); } \
void CLASS::set_out_handle(int path, int point, const Vector2 &value) { if (_paths->set_handle(path, point, value, false)) _queue_paths(); } \
PackedVector2Array CLASS::get_path_points(int path) const { PackedVector2Array out; int n = get_point_count(path); out.resize(n); Vector2 *data = out.ptrw(); for (int i = 0; i < n; i++) data[i] = _paths->slots[(size_t)path].path.points[(size_t)i].anchor; return out; } \
Vector2 CLASS::path_to_document(int path, const Vector2 &point) const { return _paths->to_document(path, point); } \
Vector2 CLASS::document_to_path(int path, const Vector2 &point) const { return _paths->from_document(path, point); } \
bool CLASS::_set(const StringName &name, const Variant &value) { int path, point; PathPropertyPart part; if (!property_indices(name, path, point, part) || value.get_type() != Variant::VECTOR2) return false; Vector2 v = value; if (!_paths->valid(path, point)) { _paths->pending.push_back({name, v}); return true; } if (part == PATH_ANCHOR) set_path_point(path, point, v); else if (part == PATH_IN_HANDLE) set_in_handle(path, point, v); else set_out_handle(path, point, v); return true; } \
bool CLASS::_get(const StringName &name, Variant &value) const { int path, point; PathPropertyPart part; if (!property_indices(name, path, point, part) || !_paths->valid(path, point)) return false; value = part == PATH_ANCHOR ? get_path_point(path, point) : part == PATH_IN_HANDLE ? get_in_handle(path, point) : get_out_handle(path, point); return true; } \
void CLASS::_get_property_list(List<PropertyInfo> *list) const { for (int p = 0; p < get_path_count(); p++) for (int i = 0; i < get_point_count(p); i++) { String base = "paths/path_" + itos(p) + "/point_" + itos(i); list->push_back(PropertyInfo(Variant::VECTOR2, base, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_KEYING_INCREMENTS)); list->push_back(PropertyInfo(Variant::VECTOR2, base + "/in_handle", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT)); list->push_back(PropertyInfo(Variant::VECTOR2, base + "/out_handle", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT)); } } \
void CLASS::_bind_methods() { \
	ClassDB::bind_method(D_METHOD("set_deferred_updates", "enabled"), &CLASS::set_deferred_updates); \
	ClassDB::bind_method(D_METHOD("is_deferred_updates"), &CLASS::is_deferred_updates); \
	ClassDB::bind_method(D_METHOD("flush_paths"), &CLASS::flush_paths); \
	ADD_GROUP("Path Updates", ""); \
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "deferred_updates"), "set_deferred_updates", "is_deferred_updates"); \
	ClassDB::bind_method(D_METHOD("get_path_count"), &CLASS::get_path_count); ClassDB::bind_method(D_METHOD("get_point_count", "path"), &CLASS::get_point_count); \
	ClassDB::bind_method(D_METHOD("get_path_point", "path", "point"), &CLASS::get_path_point); ClassDB::bind_method(D_METHOD("set_path_point", "path", "point", "value"), &CLASS::set_path_point); \
	ClassDB::bind_method(D_METHOD("get_in_handle", "path", "point"), &CLASS::get_in_handle); ClassDB::bind_method(D_METHOD("set_in_handle", "path", "point", "value"), &CLASS::set_in_handle); \
	ClassDB::bind_method(D_METHOD("get_out_handle", "path", "point"), &CLASS::get_out_handle); ClassDB::bind_method(D_METHOD("set_out_handle", "path", "point", "value"), &CLASS::set_out_handle); \
	ClassDB::bind_method(D_METHOD("get_path_points", "path"), &CLASS::get_path_points); \
	ClassDB::bind_method(D_METHOD("path_to_document", "path", "point"), &CLASS::path_to_document); \
	ClassDB::bind_method(D_METHOD("document_to_path", "path", "point"), &CLASS::document_to_path); \
}

ANIMATE_IMPL(SVGAnimate2D, SVG2D)
ANIMATE_IMPL(SVGAnimate3D, SVG3D)

} // namespace svg2d

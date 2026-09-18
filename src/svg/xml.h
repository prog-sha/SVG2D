// SVGを描く側と編集する側で同じXMLノードを読む補助。
// 責務: 処理命令の終端を守り、その本文を図形として読まない。
// 設計思想: GodotのXMLParserを使い、SVGで不要な処理命令だけ読み飛ばす。
#ifndef SVG2D_XML_H
#define SVG2D_XML_H

#include <godot_cpp/classes/xml_parser.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <string_view>

namespace svg2d {
// seekは移動先を読み込むため、戻り値のノードをそのまま次の候補にする。
inline godot::Error read_svg_node(const godot::Ref<godot::XMLParser> &parser,
		const godot::PackedByteArray &buffer) {
	godot::Error error = parser->read();
	while (error == godot::OK && parser->get_node_type() == godot::XMLParser::NODE_UNKNOWN) {
		std::string_view text(reinterpret_cast<const char *>(buffer.ptr()), (size_t)buffer.size());
		size_t at = (size_t)parser->get_node_offset();
		if (at >= text.size() || text.substr(at, 2) != "<?") break;
		size_t end = text.find("?>", at + 2);
		if (end == std::string_view::npos || end + 2 >= text.size()) return godot::ERR_FILE_EOF;
		error = parser->seek(end + 2);
	}
	return error;
}
} // namespace svg2d
#endif

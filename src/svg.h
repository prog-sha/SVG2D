// SVG の絵を読んで描く係。
//
// 責務: SVG の中身を読み取り、決められた大きさの絵にすること。
// どこに置くかも、いつ描き直すかも知らない（それは SVG2D の受け持ち）。
//
// 設計思想: 覆い（どれだけ塗られているか）を面積として数えてから色を乗せる。
// Chromium も同じ考え方で描いているので、同じ SVG からほぼ同じ絵が出る。
// 三角形にして GPU へ渡すやり方も試せるが、まとまりごとの薄さ・切り抜き・
// 色の移り変わりが、どれも別の描き先を用意しないと正しくならない。
// SVG は一度描けば形が変わらないので、描いた絵を控えて貼るほうが速くて確かめやすい。
//
// できること: 四角・丸・楕円・線・折れ線・多角形・道（path）、入れ子の変形、
// 塗りと線（端・角・破線）、単色と色の移り変わり（まっすぐ・丸い）、
// 薄さ、切り抜き（clipPath。objectBoundingBox も）、使い回し（use と symbol）、
// 入れ子の svg、viewBox と preserveAspectRatio、長さの単位（px pt pc mm cm in Q）、
// style="" と <style>（CDATA で囲んであっても読む）。
// できないこと: 文字、ぼかしなどの効果（filter）、覆い（mask）、模様（pattern）、
// 印（marker）、動き（animation）、外の画像。
// <style> で見る指しかたは「札の名前・.組・#名札」まで。入れ子で指す書きかたや
// 疑似クラスは見ない。
#ifndef SVG2D_SVG_H
#define SVG2D_SVG_H

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace svg2d {

class SVG : public godot::RefCounted {
	GDCLASS(SVG, godot::RefCounted)

public:
	// 読み取った札 1 つぶん。中身は SVG の書きかたのまま持つ。
	struct Elem {
		// 名前と決めごとの棚は、Godot の String ではなく素の字で持つ。
		// Dictionary を const char* で引くと、引くたびに String を組み立てて
		// 混ぜ直すので、札 1 つで 20 回、絵 1 枚で 2 万回それをやることになる
		std::string tag;
		std::unordered_map<std::string, godot::String> attr;
		godot::String text;   // 札にはさまれた字。<style> の中身にだけ使う
		std::vector<std::shared_ptr<Elem>> kids;
	};

	// 描くたびに変わらないものを控えておく入れ物。中身は svg.cpp の中だけで使う。
	// 毎コマ描くつもりなら、道の字を読み直して折れ線に開き直すのがいちばん重い
	struct Store;

private:
	std::shared_ptr<Elem> _root;
	std::unique_ptr<Store> _store;
	std::unordered_map<std::string, Elem *> _ids;   // id から札を引く。use と切り抜きが使う
	godot::String _error;
	godot::Vector2 _size = godot::Vector2(0, 0);    // 札に書いてある大きさ
	godot::Rect2 _view;                             // viewBox。無ければ広さ 0
	godot::String _par = "xMidYMid meet";           // preserveAspectRatio

	void _index(const std::shared_ptr<Elem> &e);

protected:
	static void _bind_methods();

public:
	SVG();
	~SVG();
	// SVG の中身を読み取る。読めたら true。
	bool parse(const godot::String &text);
	// 読めなかったわけ。読めていれば空。
	godot::String get_error() const { return _error; }
	// 札に書いてある大きさ。width/height が無ければ viewBox の広さ。
	godot::Vector2 doc_size() const;
	// 決められた大きさの絵にする。読めていなければ空の絵。
	godot::Ref<godot::Image> render(int w, int h) const;
	// 控えを空ける。使っていない絵を抱えたままにしたくないときに呼ぶ。
	void clear_cache();
	// 控えが抱えている量。ためしと、どれだけ効いているかを見るのに使う。
	int cache_bytes() const;
};

// SVG を画面へ置くノード。
// 責務: 読み取った絵を、いまの大きさで焼いて貼ること。
// 大きさが変わったときだけ焼き直す。毎フレーム焼くと、置いてあるだけで重くなる。
class SVG2D : public godot::Node2D {
	GDCLASS(SVG2D, godot::Node2D)

private:
	godot::String _source;
	godot::Vector2 _size = godot::Vector2(0, 0);
	godot::Ref<SVG> _doc;
	godot::Ref<godot::Texture2D> _tex;
	godot::Vector2 _baked = godot::Vector2(0, 0);

	void _bake();

protected:
	static void _bind_methods();

public:
	void _draw() override;
	// SVG の中身を入れる。入れると次に描くときに焼き直す。
	void set_source(const godot::String &s);
	godot::String get_source() const { return _source; }
	// 出す大きさ。0 なら札に書いてある大きさをそのまま使う。
	void set_size(const godot::Vector2 &s);
	godot::Vector2 get_size() const { return _size; }
};

} // namespace svg2d

#endif // SVG2D_SVG_H

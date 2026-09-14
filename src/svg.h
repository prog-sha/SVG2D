// SVG の絵を読んで描く係。
//
// 責務: SVG の中身を読み取り、決められた大きさの絵にすること。
// どこに置くかも、いつ描き直すかも知らない（それは SVG2D と SVG3D の受け持ち）。
//
// 設計思想: 覆い（どの程度塗られているか）を面積として数えてから色を乗せる。
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
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/classes/node2d.hpp>
#include <godot_cpp/classes/node3d.hpp>
#include <godot_cpp/classes/sprite3d.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace svg2d {

class SVG {
public:
	// 読み取った札 1 つぶん。中身は SVG の書きかたのまま持つ。
	struct Elem {
		// 名前と決めごとの棚は、Godot の String ではなく素の字で持つ。
		// Dictionary を const char* で引くと、引くたびに String を組み立てて
		// 混ぜ直すので、札 1 つで 20 回、絵 1 枚で 2 万回それをやることになる
		std::string tag;
		std::unordered_map<std::string, godot::String> attr;
		godot::String text;   // 札にはさまれた字。<style> の中身に使う
		std::vector<std::shared_ptr<Elem>> kids;
	};

	// 描くたびに変わらないものを控えておく入れ物。中身は svg.cpp の内部で使う。
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
	// 控えが抱えている量。ためしと、どの程度効いているかを見るのに使う。
	int cache_bytes() const;
};

// SVG の文字列と焼いた画像を2D・3Dノードで共有する係。
// 責務: 入力を読み、指定した画素数の画像を必要なときに作ること。
// 設計思想: 表示先を持たず、2Dと3Dで同じ画像を使えるようにする。
class SVGTexture {
private:
	godot::String _src;
	std::unique_ptr<SVG> _doc;
	godot::Ref<godot::ImageTexture> _tex;
	godot::Vector2 _baked = godot::Vector2(0, 0);
	bool _dirty = true;

	// 画面密度を実際に必要な整数画素数へ丸める。
	godot::Vector2 _target(const godot::Vector2 &density) const;

public:
	// SVG の中身を読み、次の取得時に新しい画像を作れる状態へする。
	void set_src(const godot::String &s);
	godot::String get_src() const { return _src; }
	// SVGが場面内で占める基準サイズを返す。
	godot::Vector2 draw_size() const;
	// 指定した画面密度で画像を作り直す必要があるかを返す。
	bool needs(const godot::Vector2 &density) const;
	// 現在の入力と画面密度に対応する画像を返す。
	godot::Ref<godot::Texture2D> get_texture(const godot::Vector2 &density = godot::Vector2(1, 1));
};

// SVG を画面へ置くノード。
// 責務: 読み取った絵を、いまの大きさで焼いて貼ること。
// 大きさが変わった場合に焼き直す。毎フレーム焼くと、置いてある間も重くなる。
class SVG2D : public godot::Node2D {
	GDCLASS(SVG2D, godot::Node2D)

private:
	SVGTexture _svg;
	bool _adaptive = true;

	// ローカル座標からViewport座標への拡大率を返す。
	godot::Vector2 _density() const;

protected:
	static void _bind_methods();

public:
	SVG2D();
	void _draw() override;
	void _process(double delta) override;
	// SVG の中身を入れる。入れると次に描くときに焼き直す。
	void set_src(const godot::String &s);
	godot::String get_src() const { return _svg.get_src(); }
	// 画面上の大きさに合わせた自動解像度を切り替える。
	void set_adaptive(bool enabled);
	bool is_adaptive() const { return _adaptive; }
	// ノードが貼る画像を返す。Sprite2D など別の描き手でも使える。
	godot::Ref<godot::Texture2D> get_texture();
	// SVG文書の自然寸法。エディターの選択面にも使う。
	godot::Vector2 get_svg_size() const { return _svg.draw_size(); }
};

// SVG を3D空間の板へ置くノード。
// 責務: SVGを画像にし、画面上の占有画素数に合う細かさで3Dの面へ貼ること。
// 設計思想: 利用者の変形と内部画像の縮尺を分け、解像度を変えても空間内の大きさを保つ。
class SVG3D : public godot::Node3D {
	GDCLASS(SVG3D, godot::Node3D)

private:
	SVGTexture _svg;
	godot::Sprite3D *_sprite = nullptr;
	double _pixel_size = 0.01;
	bool _adaptive = true;
	bool _queued = false;

	// 画像を貼る内部ノードを必要になった時点で作る。
	void _ensure_sprite();
	// 現在のCamera3Dから画面上の拡大率を返す。
	godot::Vector2 _density() const;
	// まとまった設定変更のあと、入力に対応する画像を3Dの板へ反映する。
	void _queue_refresh();
	void _refresh();

protected:
	static void _bind_methods();

public:
	SVG3D();
	void _process(double delta) override;
	// SVG の中身を入れ、3Dの板を描き直す。
	void set_src(const godot::String &s);
	godot::String get_src() const { return _svg.get_src(); }
	// SVGの1画素を3D空間で何単位にするかを決める。
	void set_pixel_size(double size);
	double get_pixel_size() const { return _pixel_size; }
	// 画面上の大きさに合わせた自動解像度を切り替える。
	void set_adaptive(bool enabled);
	bool is_adaptive() const { return _adaptive; }
	// 内部の3D板が使っている画像を返す。
	godot::Ref<godot::Texture2D> get_texture() const;
};

} // namespace svg2d

#endif // SVG2D_SVG_H

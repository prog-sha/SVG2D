// 接点アニメーションの同じ姿勢へ戻ったとき、描画済み画像を再利用する。
// 責務: 表示条件を完全照合し、容量上限内で古い画像から解放する。
// 設計思想: ハッシュ検索と使用順リストで探索・更新の全件走査を避ける。
#ifndef SVG2D_ANIMATION_CACHE_H
#define SVG2D_ANIMATION_CACHE_H
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/variant/string.hpp>
#include <list>
#include <unordered_map>

namespace svg2d {
struct AnimationCache {
	struct Key {
		godot::String source;
		int width, height, pattern;
		double jitter;
		bool mipmaps;
		uint64_t source_hash;
		// ハッシュが一致しても、文書と全条件が違う画像は採用しない。
		bool operator==(const Key &other) const {
			return width == other.width && height == other.height && pattern == other.pattern &&
					jitter == other.jitter && mipmaps == other.mipmaps && source == other.source;
		}
	};
	struct Hash {
		// 文書のハッシュは入力変更時に計算済み。描画時は固定個数の条件だけ混ぜる。
		size_t operator()(const Key &key) const {
			size_t h = (size_t)key.source_hash;
			for (size_t value : {(size_t)key.width, (size_t)key.height, (size_t)key.pattern,
					std::hash<double>{}(key.jitter), (size_t)key.mipmaps})
				h ^= value + 0x9e3779b9u + (h << 6) + (h >> 2);
			return h;
		}
	};
	struct Entry {
		Key key;
		godot::Ref<godot::ImageTexture> texture;
		size_t bytes;
	};
	bool enabled = false; // 任意の連続変形ではヒットしないため明示的に有効化する
	size_t cap = 32 * 1024 * 1024; // 履歴の既定上限32 MiB
	size_t bytes = 0; // 画像・文書・管理情報の計上量
	uint64_t hits = 0, misses = 0; // 履歴検索の成否
	std::list<Entry> lru;
	std::unordered_map<Key, std::list<Entry>::iterator, Hash> index;
	static constexpr size_t MAX_FRAMES = 512; // 極小画像でも管理情報を増やし続けない

	// 参照順の先頭へ移し、次の追い出し対象から外す。
	godot::Ref<godot::ImageTexture> find(const Key &key) {
		auto found = index.find(key);
		if (found == index.end()) { misses++; return {}; }
		hits++;
		lru.splice(lru.begin(), lru, found->second);
		return found->second->texture;
	}
	// 収まるまで最も古い画像を外す。現在表示中の画像は表示側の参照が守る。
	void trim(size_t incoming) {
		while (!lru.empty() && (bytes + incoming > cap || (incoming && lru.size() >= MAX_FRAMES))) {
			const Entry &last = lru.back();
			bytes -= last.bytes;
			index.erase(last.key);
			lru.pop_back();
		}
	}
	// 保持中の画像は変更しない。大きすぎる画像は履歴へ入れず通常描画に任せる。
	bool keep(const Key &key, const godot::Ref<godot::ImageTexture> &texture, size_t pixels) {
		size_t cost = pixels + (size_t)key.source.length() * sizeof(char32_t) +
				sizeof(Entry) + sizeof(Key) + 4 * sizeof(void *);
		if (cost > cap) return false;
		trim(cost);
		lru.push_front({key, texture, cost});
		index.emplace(key, lru.begin());
		bytes += cost;
		return true;
	}
	// 保存するのは設定だけで、履歴と計数は明示的にリセットする。
	void clear() { index.clear(); lru.clear(); bytes = 0; hits = misses = 0; }
};
} // namespace svg2d
#endif

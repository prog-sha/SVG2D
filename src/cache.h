// 量で区切って持つ控え。
//
// 責務: 鍵から中身を引くこと。あふれたら、しばらく使っていないものから捨てること。
// 中身が何なのかは知らない。抱えている量を、外から教えてもらう。
//
// 設計思想: 数ではなく量で区切る。点の多い形 1 つが、短い形 100 個ぶんの重さに
// なるので、数で数えると効かない。捨てるときは半分まで空ける。上限ぎりぎりを
// なぞると、1 つ入れるたびに 1 つ捨てることになって、捨てる仕事ばかりが増える。
// このコマで使ったものは捨てない。使っている最中のものを捨てると、
// 同じコマの中で組み直しが起きる。
#ifndef SVG2D_CACHE_H
#define SVG2D_CACHE_H

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <unordered_map>
#include <utility>
#include <vector>

namespace svg2d {

// 鍵を作るための混ぜかた（FNV-1a）。控えを使うところで共通に使う。
inline uint64_t mix(uint64_t h, const void *data, size_t len) {
	const uint8_t *p = (const uint8_t *)data;
	for (size_t i = 0; i < len; i++) {
		h ^= p[i];
		h *= 1099511628211ULL;
	}
	return h;
}

static const uint64_t SEED = 14695981039346656037ULL;   // FNV-1a の始めの値

template <typename V>
class Cache {
public:
	struct Slot {
		V val;
		uint64_t used = 0;   // 最後に使った回
		size_t bytes = 0;    // この中身が抱えている量
	};

	explicit Cache(size_t cap) :
			_cap(cap) {}

	// いま何回目か。同じ数のあいだに入れたものは、あふれても捨てない
	void turn(uint64_t t) { _turn = t; }
	uint64_t turn() const { return _turn; }

	V *find(uint64_t key) {
		auto it = _map.find(key);
		if (it == _map.end()) return nullptr;
		it->second.used = _turn;
		return &it->second.val;
	}

	V &keep(uint64_t key, V &&v, size_t bytes) {
		// 同じ鍵で入れ直されたら、前のぶんを引いてから足す。引かないと、
		// 抱えている量がふくらんで、捨てるほうが止まらなくなる
		auto old = _map.find(key);
		if (old != _map.end()) _bytes -= old->second.bytes;
		if (_bytes + bytes > _cap) _trim(bytes);
		Slot s;
		s.val = std::move(v);
		s.used = _turn;
		s.bytes = bytes;
		_bytes += bytes;
		auto r = _map.insert_or_assign(key, std::move(s));
		return r.first->second.val;
	}

	// 中身を作り直したとき、加算せず現在の実量へ置き換える。
	void resize(uint64_t key, size_t bytes) {
		auto it = _map.find(key);
		if (it == _map.end()) return;
		_bytes -= it->second.bytes;
		it->second.bytes = bytes;
		_bytes += bytes;
	}

	void clear() {
		_map.clear();
		_bytes = 0;
	}
	int count() const { return (int)_map.size(); }
	size_t bytes() const { return _bytes; }

private:
	void _trim(size_t want) {
		std::vector<std::pair<uint64_t, uint64_t>> age;   // 使った回、鍵
		age.reserve(_map.size());
		for (auto &e : _map) age.push_back({ e.second.used, e.first });
		std::sort(age.begin(), age.end());
		for (auto &a : age) {
			if (_bytes + want <= _cap / 2) break;
			auto it = _map.find(a.second);
			if (it == _map.end() || it->second.used == _turn) continue;
			_bytes -= it->second.bytes;
			_map.erase(it);
		}
	}

	std::unordered_map<uint64_t, Slot> _map;
	size_t _cap = 0;
	size_t _bytes = 0;
	uint64_t _turn = 0;
};

} // namespace svg2d

#endif // SVG2D_CACHE_H

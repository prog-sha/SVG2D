// SVG描画キャッシュの容量計算だけをGodotなしで確かめる試験。
// 責務: 中身の置換を加算と誤認せず、実際の保持量を報告すること。
// 設計思想: 軽い部品試験として通常の描画試験より先に即時実行する。
#include "cache.h"

#include <cassert>
#include <vector>

int main() {
	svg2d::Cache<std::vector<int>> cache(1024);
	cache.turn(1);
	cache.keep(7, std::vector<int>{ 1 }, 16);
	assert(cache.bytes() == 16);
	for (size_t bytes = 17; bytes < 1000; bytes++) cache.resize(7, bytes);
	assert(cache.bytes() == 999);
	cache.resize(7, 24);
	assert(cache.bytes() == 24);
	return 0;
}

# SVG の動的解像度

拡大しても輪郭を鮮明に保ちながら、変化のない場面では画像化を止めるための設計だよ。

## 採用する形

- 2Dはローカル座標からViewport座標への変換を使い、SVGが占める画素数を求める。
- 3Dは現在のCamera3Dで板の縦横を画面座標へ投影し、SVGが占める画素数を求める。
- 必要解像度を2倍刻みで切り上げる。滑らかな拡大中に毎コマ画像化せず、解像度の境界を越えたときに更新する。
- 縮小時は現在の解像度が必要値の2倍を超えるまで使い回し、境界付近の往復を防ぐ。
- SVGの解析結果、開いたパス、色の計算結果を保持し、画像化のたびに読み直さない。
- 1辺4096画素を上限にして、1枚が使うRGBA画像を最大64 MiBへ抑える。

## 公式資料

- [CanvasItem](https://docs.godotengine.org/en/4.7/classes/class_canvasitem.html)
- [ViewportとCanvasの変換](https://docs.godotengine.org/en/stable/tutorials/2d/2d_transforms.html)
- [Camera3D](https://docs.godotengine.org/en/4.7/classes/class_camera3d.html)
- [Godotの通知](https://docs.godotengine.org/en/4.7/tutorials/best_practices/godot_notifications.html)

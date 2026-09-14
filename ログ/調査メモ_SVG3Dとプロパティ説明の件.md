# SVG3D とプロパティ説明の調査

SVG を 3D 空間へ正しい色で置き、インスペクターから設定の意味を読めるようにするよ。

## 採用する形

- `SVG3D` は `Sprite3D` を継承する。Godot が用意する3D用の板、透明描画、画素の縮尺、ビルボード設定をそのまま使える。
- SVG の読み取りと画像化は `SVG2D` と共有する。2Dと3Dで別の絵にならない設計にする。
- `src` と `size` の連続変更は、次のコマに1回まとめて画像化する。場面を読み込むときの重複した画像化を避けられる。
- `src` と `size` の説明はクラス参照XMLへ書き、デバッグ用バイナリーへ組み込む。Godot 4.3以降の公式な GDExtension 文書方式だよ。
- 3D描画を画像として取り出し、元のSVG画像と画素ごとの差を測る。合格値は RMSE 8未満とする。

## 公式資料

- [GDExtensionへ説明を追加する](https://docs.godotengine.org/en/latest/tutorials/scripting/cpp/gdextension_docs_system.html)
- [Sprite3D](https://docs.godotengine.org/en/latest/classes/class_sprite3d.html)
- [godot-cppのSConsビルド](https://docs.godotengine.org/en/4.7/tutorials/scripting/cpp/build_system/scons.html)

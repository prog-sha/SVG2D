# Godot Asset Library 審査の手順

SVG2D を Godot エディターから見つけて導入できるようにするため、公式 Asset Library へ登録するよ。

## 申請の流れ

1. Godot Asset Library へログインし、アセットの送信画面を開く。
2. 名前、英語の説明、分類、対応する Godot、版、MIT ライセンスを入力する。
3. GitHub のリポジトリー、Issues、正方形アイコンの直接 URL を入力する。
4. 配布ファイルを含むコミットの完全な SHA を Download Commit に入力する。
5. 内容を確認して送信し、管理者の審査結果を待つ。

## 公式資料

- [アセットライブラリへの送信](https://docs.godotengine.org/ja/4.x/community/asset_library/submitting_to_assetlib.html)
- [Godot Asset Library](https://godotengine.org/asset-library/asset)

## 確認項目

- リポジトリーが公開されている。
- ルートと `addons/svg2d` に MIT ライセンスと README がある。
- アイコンが PNG または JPEG の正方形で、128×128 以上である。
- Download Commit の書庫から `addons/svg2d` を導入できる。
- 英語の名前と説明が機能を正しく表している。

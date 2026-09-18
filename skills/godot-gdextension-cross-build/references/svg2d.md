# SVG2Dのビルド入口

このファイルはSVG2Dリポジトリ固有の対応表。実行前にリンク先の設定を読み、現状と一致していることを確認する。コマンドの作業場所はリポジトリ直下。

## 設定と配布対象

- [SConstruct](../../../SConstruct): godot-cppのAPI指定、出力名、debug用の文書生成。
- [build_profile.json](../../../build_profile.json): 使用するGodotクラス。
- [svg2d.gdextension](../../../addons/svg2d/svg2d.gdextension): `svg2d_init`、互換版、配布先一覧。

現在のAPI指定・最小互換版は4.7。debug/releaseをそれぞれ作る以下の7構成、計14ファイルを`addons/svg2d/bin/`へ置く。

| OS | CPU・構成 | 出力形式 |
| --- | --- | --- |
| macOS | universal（arm64 + x86_64） | dylib |
| Windows | x86_64 | dll |
| Linux | arm64、x86_64 | so |
| Android | arm64 | so |
| iOS | arm64実機 | dylib |
| Web | wasm32、threads=no | wasm |

## ビルドと指紋

[tests/build_all.sh](../../../tests/build_all.sh) が全対象の入口。[build_fingerprints.txt](../../../addons/svg2d/bin/build_fingerprints.txt) に入力と出力の指紋を保存する。

```sh
bash tests/build_all.sh
```

`--force`は全対象を再構築する。通常実行でも指紋が合わなければビルドが始まるので、必要なツールとLinux用ランナーを先に確認する。

Linuxランナーは`localhost/gd-linux-builder:latest`と`localhost/gd-linux-builder-x64:latest`を参照する。ローカルイメージなので、他の環境にあるとは限らない。イメージにSConsや対象コンパイラがなければ、[platforms.md](platforms.md) の独立コンテナ方式を使い、ビルド成功した成果物を所定の場所へ戻す。既存ランナーの共有マウントと、別のSConsプロセスを並行させない。

Apple Silicon開発機の単独NDKは`/opt/homebrew/share/android-ndk`が候補。実在を確認し、SDK配下NDKと競合する場合は次の形を使う。

```sh
ANDROID_NDK_ROOT=/opt/homebrew/share/android-ndk scons platform=android \
  target=template_debug arch=arm64 ANDROID_HOME= -j8
```

個別に全対象を作った場合に限り、その同じ入力から作った14出力を検証してから指紋を登録できる。

```sh
bash tests/build_all.sh --adopt
bash tests/build_all.sh
```

2回目は`0 built, 14 unchanged`を確認する。`--adopt`は既存バイナリの来歴を検証しない。古い出力が残っている状態で実行しない。

現行スクリプトの共通入力指紋には、`src/gen/`以外の`src/`全ファイルが入るため、オブジェクトも影響する。個別ビルドの途中で登録すると後続ビルドで指紋が変わる。登録は全対象の完了後に行う。新しい汎用スクリプトへこの方式をコピーする場合は、中間オブジェクトを除外する。

現行の指紋にはコンパイラ・SDK・NDK・コンテナイメージの版が含まれない。それらを変更した場合はキャッシュ一致だけで再利用せず、`--force`または対象ごとの手動ビルドで作り直す。検証後に指紋を登録する。

## 検証

```sh
# 現在のホストで公開API・描画・エディタ連携を確認する。
bash tests/test.sh

# SIMD経路に影響する変更で通常計算との一致を確認する。
bash tests/test_simd.sh

# 配布先14ファイルの存在・ヘッダー・CPUを確認する。
uv run --no-project python tests/test_binaries.py
```

[test.sh](../../../tests/test.sh) はホストのdebugビルドも行う。[test_simd.sh](../../../tests/test_simd.sh) はSIMD／scalarの比較後、通常のdebugビルドへ戻す。ビルド指紋の最終登録は、これらが終わってから行う。

[test_binaries.py](../../../tests/test_binaries.py) は形式とCPUの検査。クロス対象の実機実行、SDKの対象、全依存関係や初期化シンボルの検査までは行わない。必要な検査を追加し、確認範囲を分けて報告する。

Godotの場所は`GODOT`環境変数で指定できる。macOSで未指定なら`/Applications/Godot 4.7.1.app/Contents/MacOS/Godot`を参照する。バージョンと実在を確認する。

## 配布物を保存するとき

ビルド出力ディレクトリは`.gitignore`に含まれるが、既存の配布バイナリは追跡されている。既存ファイルの更新は`git add -u addons/svg2d/bin`で追加できる。新しい対象を追加する場合は`.gdextension`、対象表、検査を揃え、必要な新規成果物だけを明示して追加する。無関係なシーンやUIDファイルを含めない。

# 環境別のビルドと検証

SConsを使うgodot-cppプロジェクト向けの例。プロジェクト直下で実行し、採用中の`godot-cpp/tools/`が受け付ける設定へ合わせる。以下はdebugの例で、配布対象にreleaseがあれば`target=template_release`でも生成する。`-j8`はホストのメモリとCPUに合わせる。

## macOS / iOS

Xcodeと選択中のSDKを確認する。macOS universalはarm64とx86_64の両方を含む。iOS実機とsimulatorはCPUが同じarm64でも別の対象なので、相互に流用しない。

```sh
xcode-select -p
xcrun --sdk macosx --show-sdk-path
xcrun --sdk iphoneos --show-sdk-path
scons platform=macos target=template_debug arch=universal -j8
scons platform=ios target=template_debug arch=arm64 -j8
```

simulatorが必要なら採用版の`ios_simulator=yes`と対応archを確認する。成果物がdylib、静的ライブラリ、frameworkのどれになるかは`SConstruct`で決まる。XCFrameworkが必要な構成では、**拡張本体**の実機用／simulator用成果物をまとめる。godot-cppだけの静的ライブラリを拡張本体として配布しない。署名・アプリ書き出しはライブラリのクロスビルドとは別に、依頼範囲で実施する。

検査は`file`、`lipo -info`、`otool -L`、`nm`を使う。iOSは`vtool -show-build`または`otool -l`でSDKの対象も見る。ホスト専用の依存パスが残っていないか確認する。

## Windows

macOS/Linuxからは対象CPU用のMinGW-w64を利用できる。コンパイラがPATH上にあることと、SConsが実際にそのコンパイラを選んだことを確認する。

```sh
x86_64-w64-mingw32-g++ --version
scons platform=windows target=template_debug arch=x86_64 -j8
```

`file`と対象ツールチェーンの`objdump -p`でPEのCPU、DLLの依存先、初期化シンボルを確認する。ホストでビルドが通ることとWindowsで読み込めることは分けて報告する。

## Android

NDKの要求版とパスの優先順位を`godot-cpp/tools/android.py`で確認する。SDK配下のNDKを使う設定と、単独NDKを使う設定を混ぜない。

```sh
# SDK配下のNDKを使う例。実在するパスと採用版のNDK番号へ置き換える。
scons platform=android target=template_debug arch=arm64 \
  ANDROID_HOME=/path/to/android-sdk ndk_version=VERSION -j8

# 単独NDKの例。ANDROID_HOMEを優先する版ではSCons引数でも空にする。
ANDROID_NDK_ROOT=/path/to/android-ndk scons platform=android \
  target=template_debug arch=arm64 ANDROID_HOME= -j8
```

AndroidとLinuxのarm64は同じELFのCPU番号でも実行環境が異なる。NDKの`llvm-readelf`などで依存ライブラリ・ロードセグメントを確認し、対象Android版のAPI・ページサイズ要件へ合わせる。Linux成果物をAndroid用としてコピーしない。

## Web

Emscriptenを有効化し、エンジン／エクスポートテンプレートとスレッド構成を一致させる。GDExtensionはWebAssemblyのside moduleとして生成する。

```sh
emcc --version
scons platform=web target=template_debug arch=wasm32 threads=no -j8
```

`threads=no`はスレッドなしの対象向け。既存構成がスレッドありならそれに合わせる。拡張側の出力とブラウザ側のExtensions Support設定、必要な配信ヘッダーも確認する。WASMのヘッダー検査だけでは、インポート解決やブラウザでの読み込み成功までは証明できない。

## Linuxを別OSからビルド

macOSのコンパイラへ`platform=linux`を渡すだけでは、Linux用のリンク環境は揃わない。既存のPodman/Dockerイメージ、Linuxホスト、または正しいsysrootを持つクロスツールチェーンを使う。配布先で必要になるglibcの下限を意識してベース環境を選ぶ。

1. イメージの実在、CPU、SCons、C++コンパイラを調べる。イメージ名に「builder」とあっても必要ツールが揃っているとは限らない。
2. 独立した作業コンテナへソースをコピーする。`.git`、ホストのオブジェクト、ライブラリ、`.sconsign.dblite`、生成ヘッダーを混ぜず、submoduleのソースとAPI定義は含める。プロジェクト固有の生成済み必須入力は残す。
3. コンテナ内で不足ツールを用意し、CPU別にビルドする。Debian系ARM64環境でx86_64も作る例では`g++-x86-64-linux-gnu`が必要。
4. `arch=x86_64`などはCPU向けフラグを選ぶだけで、コンパイラを切り替えない版がある。コマンドと`-dumpmachine`で実際の対象を確認する。
5. 全対象の成功を確認してから出力をホストへコピーし、形式・CPU・依存関係を検査する。

ARM64 Linuxコンテナ内の例:

```sh
scons platform=linux target=template_debug arch=arm64 -j8

# gcc/g++を自動選択する構成で、対象のツールだけを作業用PATHへ用意する。
x86_64-linux-gnu-g++ -dumpmachine
mkdir -p tmp/cross-bin
for tool in gcc g++ ar ranlib; do
  ln -sf "$(command -v "x86_64-linux-gnu-$tool")" "tmp/cross-bin/$tool"
done
PATH="$PWD/tmp/cross-bin:$PATH" scons platform=linux \
  target=template_debug arch=x86_64 -j8
```

このPATH変更はコマンド単位に限定する。次のARM64ビルドへ持ち越さない。`use_llvm=yes`など別のコンパイラ選択がある場合は、その設定に合うツールチェーンを指定する。

検査は`readelf -h -d -Ws --version-info`を使い、ELFのCPU・共有ライブラリ形式・初期化シンボル・必要なGLIBC/GLIBCXXを確認する。`use_static_cpp`を使っても、glibcの互換性まで自動的に解決するわけではない。

## 参照先

オプションの正確な名前と既定値は、採用しているgodot-cppの`tools/macos.py`、`ios.py`、`windows.py`、`android.py`、`web.py`、`linux.py`を読む。[公式godot-cppのtools](https://github.com/godotengine/godot-cpp/tree/master/tools) は版の差を調べる入口として使う。

#!/usr/bin/env python
# SVG2D を各環境向けの共有ライブラリへ組み立てる設定。
# 責務: godot-cpp と描画本体を結び、アドオン内の決まった場所へ成果物を置くこと。
# 設計思想: Godot 公式テンプレートと同じ名前規則を使い、環境ごとの差を設定へ閉じ込める。

base = Environment(tools=["default"], PLATFORM="")
base["build_profile"] = "build_profile.json"  # SVG2D が使う型へ絞り、組み立て時間と容量を減らす
env = SConscript("godot-cpp/SConstruct", {"env": base, "api_version": "4.7"})
env.Append(CPPPATH=["src/"])

sources = Glob("src/*.cpp")  # 拡張の入口と SVG 描画本体
suffix = env["suffix"].replace(".dev", "").replace(".universal", "")  # 配布時の安定した名前
name = "{}svg2d{}{}".format(env.subst("$SHLIBPREFIX"), suffix, env.subst("$SHLIBSUFFIX"))  # 読み込み名
library = env.SharedLibrary("addons/svg2d/bin/{}/{}".format(env["platform"], name), source=sources)

Default(library)

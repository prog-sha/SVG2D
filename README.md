# SVG2D

**English** | [日本語](README.ja.md)

SVG2D is a lightweight GDExtension add-on that renders and edits SVG markup in Godot 2D and 3D scenes. `SVGAnimate2D` / `SVGAnimate3D` expose topology-preserving path anchors for editor manipulation and AnimationPlayer keyframes. It also provides `SpriteRope2D` / `SpriteRope3D` for arbitrary textures and separate SVG-source rope nodes.

The packaged add-on supports Godot 4.7 or later on Windows x86_64, macOS Universal, Linux x86_64/arm64, Android arm64, and Web wasm32 without threads. See [`addons/svg2d/README.md`](addons/svg2d/README.md) for installation, usage, and supported SVG features.

## Building from source

Install Godot 4.7, a C++17 compiler, and SCons, then clone the repository with its build-only submodule:

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=macos target=template_debug
scons platform=macos target=template_release
```

Replace `platform` and `arch` when building for another supported target. Android builds require the Android NDK, and Web builds require Emscripten; use `threads=no` for the packaged Web configuration. Use `template_release` for distribution and `template_debug` for development.

## Testing

On macOS, the test script automatically looks for Godot 4.7.1. Set `GODOT` when Godot is installed elsewhere.

```sh
GODOT=/path/to/godot sh tests/test.sh
```

Set `SVG2D_SCALAR=yes` to verify the scalar CPU fallback without SSE2 or NEON.

Run `sh tests/test_simd.sh` on macOS to verify that both paths produce the same pixel SHA-256.

Run `python3 tests/test_binaries.py` to verify that all packaged GDExtension paths contain binaries of the declared format and architecture.

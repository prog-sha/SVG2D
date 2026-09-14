# SVG2D

**English** | [日本語](README.ja.md)

SVG2D renders and edits SVG documents inside Godot. Use the `SVG2D` node for 2D or the `SVG3D` node for 3D, and open the **SVG** workspace to draw, arrange, inspect, and save the source SVG directly. The editor code is excluded from game exports; the small GDExtension renderer remains the only runtime component.

The runtime also provides four-frame deterministic path jitter, modulation, flipping, offsets, adaptive texture caching, visible-pixel picking, hitbox generation, and mipmapped 3D output matched to projected pixels.

The packaged add-on currently supports Godot 4.7 or later on Windows x86_64 and macOS Universal. See [`addons/svg2d/README.md`](addons/svg2d/README.md) for installation, usage, and supported SVG features.

## Building from source

Install Godot 4.7, a C++17 compiler, and SCons, then clone the repository with its build-only submodule:

```sh
git clone --recurse-submodules https://github.com/prog-sha/SVG2D.git
cd SVG2D
scons platform=macos target=template_debug
scons platform=macos target=template_release
```

Replace `platform` when building for another supported target. Use `template_release` for distribution and `template_debug` for development.

## Testing

On macOS, the test script automatically looks for Godot 4.7.1. Set `GODOT` when Godot is installed elsewhere.

```sh
GODOT=/path/to/godot sh tests/test.sh
```

Set `SVG2D_SCALAR=yes` to verify the scalar CPU fallback without SSE2 or NEON.

Run `sh tests/test_simd.sh` on macOS to verify that both paths produce the same pixel SHA-256.

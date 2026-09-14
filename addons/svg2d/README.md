# SVG2D

**English** | [日本語](README.ja.md)

SVG2D is a lightweight GDExtension add-on that renders SVG markup in Godot 2D and 3D scenes. It reuses cached textures while projected dimensions stay unchanged. `SVG3D` rasterizes at least 1.5 times its projected pixel size and generates mipmaps for cleaner lines.

## Compatibility

- Godot 4.7 or later
- Windows x86_64
- macOS Universal

The packaged add-on includes precompiled debug and release binaries for Windows x86_64 and macOS Universal.

## Installation

1. Copy the `svg2d` folder into your project's `addons` folder.
2. Open **Project > Project Settings > Plugins** in Godot.
3. Enable **SVG2D**.

## Usage

Add an `SVG2D` node to a 2D scene or an `SVG3D` node to a 3D scene. Use **Open SVG…** on `src` in the Inspector to choose a `.svg` asset and preview both the artwork and its dimensions. The SVG document width and height define its natural dimensions, and you can drag anywhere inside the artwork to move it in the 2D editor. Transform `SVG2D` or adjust the camera to change its on-screen dimensions. On `SVG3D`, use `pixel_size` to control its dimensions in 3D space.

```gdscript
var picture := SVG2D.new()
picture.src = "res://picture.svg"
picture.scale = Vector2(2, 2)
add_child(picture)
```

Animation is disabled by default. Enable `animation_enabled` to displace paths by `jitter_amount`, a ratio of the document dimensions (0.0008 by default, capped at 0.3). Four deterministic frames using seeds 1 through 4 are cached and cycled every `animation_interval` frames (10 by default). Disabling animation releases its three extra cached textures. Both nodes support `flip_h`, `flip_v`, `offset`, and `modulate` (the 2D modulate is the inherited CanvasItem property).

The `adaptive` property is enabled by default and follows both runtime cameras and the 3D editor camera. Disable it to keep a fixed resolution, capped at 4096 pixels on either axis. `SVG3D` still uses 1.5 times the natural document resolution in fixed mode.

Adaptive textures are limited to 4096 pixels on either axis to keep one RGBA texture within 64 MiB. Very large on-screen SVGs therefore use the highest available resolution.

Pixel conversion uses SSE2 on x86_64 and NEON on arm64. Builds for other architectures use the equivalent scalar CPU path.

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are not supported.

## License

See `LICENSE` in this folder.

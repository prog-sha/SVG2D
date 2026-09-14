# SVG2D

**English** | [日本語](README.ja.md)

SVG2D is a lightweight GDExtension add-on that renders SVG markup in Godot 2D and 3D scenes. By default, it monitors the viewport drawing area and rebuilds the texture at its integer pixel dimensions. It reuses the cached texture while those dimensions stay unchanged, keeping zoomed SVGs sharp without rasterizing every frame.

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

Add an `SVG2D` node to a 2D scene or an `SVG3D` node to a 3D scene, then set its `src` property to SVG markup. The SVG document width and height define its natural dimensions. Transform `SVG2D` or adjust the camera to change its on-screen dimensions. On `SVG3D`, use `pixel_size` to control its dimensions in 3D space.

```gdscript
var picture := SVG2D.new()
picture.src = FileAccess.get_file_as_string("res://picture.svg")
picture.scale = Vector2(2, 2)
add_child(picture)
```

The `adaptive` property is enabled by default. Disable it to keep the texture at the SVG document resolution, capped at 4096 pixels on either axis. The Inspector tooltips describe `src`, `adaptive`, and `pixel_size` where applicable.

Adaptive textures are limited to 4096 pixels on either axis to keep one RGBA texture within 64 MiB. Very large on-screen SVGs therefore use the highest available resolution.

Pixel conversion uses SSE2 on x86_64 and NEON on arm64. Builds for other architectures use the equivalent scalar CPU path.

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are not supported.

## License

See `LICENSE` in this folder.

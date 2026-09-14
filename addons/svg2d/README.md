# SVG2D

**English** | [日本語](README.ja.md)

SVG2D is a lightweight GDExtension add-on that renders SVG markup in Godot 2D and 3D scenes. By default, it monitors the viewport drawing area and rebuilds the texture at a suitable resolution when needed. It reuses the current power-of-two resolution level between changes, keeping zoomed SVGs sharp without rasterizing every frame.

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

Add an `SVG2D` node to a 2D scene or an `SVG3D` node to a 3D scene, then set its `src` property to SVG markup. Set `size` to control the displayed dimensions; leave it at zero to use the SVG document size. On `SVG3D`, use `pixel_size` to control the size in 3D space.

```gdscript
var picture := SVG2D.new()
picture.src = FileAccess.get_file_as_string("res://picture.svg")
picture.size = Vector2(320, 240)
add_child(picture)
```

The `adaptive` property is enabled by default. Disable it to keep the texture at the `size` resolution. The Inspector tooltips describe `src`, `size`, `adaptive`, and `pixel_size` where applicable.

Adaptive textures are limited to 4096 pixels on either axis to keep one RGBA texture within 64 MiB. Very large on-screen SVGs therefore use the highest available resolution.

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are not supported.

## License

See `LICENSE` in this folder.

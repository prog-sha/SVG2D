# SVG2D

SVG2D is a lightweight GDExtension add-on that renders SVG markup in Godot 2D scenes. It rasterizes an SVG only when its requested size changes, then reuses the resulting texture.

## Compatibility

- Godot 4.7 or later
- Windows x86_64

The packaged add-on currently includes precompiled debug and release binaries for Windows x86_64 only.

## Installation

1. Copy the `svg2d` folder into your project's `addons` folder.
2. Open **Project > Project Settings > Plugins** in Godot.
3. Enable **SVG2D**.

## Usage

Add an `SVG2D` node to a scene, then set its `src` property to SVG markup. Set `size` to control the rendered dimensions; leave it at zero to use the SVG document size.

```gdscript
var picture := SVG2D.new()
picture.src = FileAccess.get_file_as_string("res://picture.svg")
picture.size = Vector2(320, 240)
add_child(picture)
```

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are not supported.

## License

See `LICENSE` in this folder.

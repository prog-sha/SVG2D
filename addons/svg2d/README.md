# SVG2D

**English** | [日本語](README.ja.md)

SVG2D lets a Godot project edit SVG documents and render them sharply in 2D and 3D scenes. The **SVG** workspace saves standard SVG files directly, while the runtime GDExtension monitors the viewport drawing area and rebuilds the texture at its integer pixel dimensions. It reuses the cached texture while those dimensions stay unchanged. Moving an `SVG3D` node sideways at the same camera depth also reuses its texture when its projected dimensions stay unchanged.

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

## SVG editor

Choose **SVG** in Godot's main editor toolbar. Open an existing `.svg`, or create a new document. The workspace follows a familiar vector-editor layout:

- Pick Move, Node, Pen, Pencil, Rectangle, Ellipse, Line, Text, or View from the left tool panel.
- Draw and select on the center canvas. Drag a selection to move it, drag its lower-right handle to scale it, and use Node on straight paths and polygons to move their points.
- Arrange parts and groups in Layers. Use the top toolbar for history, duplication, deletion, grouping, stacking, alignment, zoom, and saving.
- Edit IDs, geometry, fill, stroke, opacity, transforms, and text in Appearance. Use the SVG tab when direct markup editing is more convenient.
- Select an `SVG2D` or `SVG3D` scene node to edit its `src` in the same workspace.

Unknown SVG elements and attributes remain in the document when it is opened and saved. Complex Bézier curves, boolean path operations, text shaping, gradients, masks, filters, and symbols can be preserved and edited in the SVG source panel; their dedicated visual tools are not yet provided.

The `editor` folder, plug-in entry script, and editing documentation are removed from exported games by the export filter. Files under `src` never reference editor scripts, so exported projects keep the runtime renderer separate.

The `adaptive` property is enabled by default. Disable it to keep the texture at the SVG document resolution, capped at 4096 pixels on either axis. The Inspector tooltips describe `src`, `adaptive`, and `pixel_size` where applicable.

Adaptive textures are limited to 4096 pixels on either axis to keep one RGBA texture within 64 MiB. Very large on-screen SVGs therefore use the highest available resolution.

Pixel conversion uses SSE2 on x86_64 and NEON on arm64. Builds for other architectures use the equivalent scalar CPU path.

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are preserved by the editor but are not rendered by the runtime node.

## License

See `LICENSE` in this folder.

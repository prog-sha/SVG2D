# SVG2D

**English** | [日本語](README.ja.md)

SVG2D is a lightweight GDExtension add-on that renders SVG markup in Godot 2D and 3D scenes. It reuses cached textures while projected dimensions stay unchanged. `SVG3D` rasterizes at least 1.5 times its projected pixel size and generates mipmaps for cleaner lines.

## Compatibility

- Godot 4.7 or later
- Windows x86_64
- macOS Universal
- Linux x86_64 and arm64
- Android arm64
- Web wasm32 (threadless)

The packaged add-on includes precompiled debug and release binaries for every platform listed above.

## Installation

1. Copy the `svg2d` folder into your project's `addons` folder.
2. Open **Project > Project Settings > Plugins** in Godot.
3. Enable **SVG2D**.

## Usage

Add an `SVG2D` node to a 2D scene or an `SVG3D` node to a 3D scene. Use **Open SVG…** on `src` in the Inspector to choose a `.svg` asset and preview both the artwork and its dimensions. The SVG document width and height define its natural dimensions, and visible pixels can be selected and dragged in both the 2D and 3D editors. Transform `SVG2D` or adjust the camera to change its on-screen dimensions. On `SVG3D`, use `pixel_size` to control its dimensions in 3D space.

The Inspector's **Create Hitbox** section adds the same standard `StaticBody` + collision child hierarchy used by Godot's 3D mesh collision tools. **Rect** creates a rectangular collision shape. **Shape** traces the visible outer silhouettes into collision polygons (or a thin 3D concave shape); transparent holes are intentionally omitted.

```gdscript
var picture := SVG2D.new()
picture.src = "res://picture.svg"
picture.scale = Vector2(2, 2)
add_child(picture)
```

Use `SVGAnimate2D` or `SVGAnimate3D` when existing SVG paths must be animated. Selecting the node shows every numbered anchor and the selected anchor's cubic handles directly in the 2D/3D editor. Drag anchors or handles and hold Shift to constrain movement. A normal handle drag preserves the smooth tangent on its opposite side; hold Alt to break and edit one side independently. `A` (or `V`), `I`, and `O` select anchor, incoming-handle, and outgoing-handle modes. Tab/Shift+Tab cycle points and `[`/`]` cycle paths. Choose a number in the Inspector's **Path Editor**, then use **Insert Point Key** or `K` to create a value track and key in the current AnimationPlayer. The standard key buttons on `paths/path_N/point_N` also work. Anchor and handle edits are stored in the scene. Editing never adds or removes paths, points, or segments; arcs remain arcs and straight segments remain straight.

Path overlays use the same rendered `viewBox`, `preserveAspectRatio`, nested group transforms, and path transforms in both directions. They stay aligned when the node moves, when the 2D editor is panned, and in both 2D and 3D views.

`SpriteRope2D` and `SpriteRope3D` accept any standard `Texture2D`, including PNG, WebP, and Godot-imported SVG resources. `SVGRope2D` and `SVGRope3D` are separate SVG-source variants with the `src` picker and supersampled SVG rendering. Both use a PBD rope pinned at the node origin; rows from top to bottom follow the particle chain. Enable `line_mode` for a plain rope configured by `line_width` and `line_color`. `max_length` set to zero derives the length from the texture or SVG height. Ropes use their World's system gravity by default; `gravity_scale` adjusts its strength. Disable `use_system_gravity` only when the local `gravity` override is needed.

Set `attachment_body` to a `PhysicsBody2D` or `PhysicsBody3D` to connect it through an internal moving `AnimatableBody` and Godot `PinJoint`. `attachment_point` selects the rope particle, with `-1` meaning the last particle. The physics engine remains responsible for the attached body's collision, mass, and rotation response; clearing the path removes the internal bodies, joint, and update work.

Verlet integration uses NEON on ARM64 or SSE2 on x86_64. The ordered distance-constraint solver remains scalar because each link depends on the preceding correction. Unsupported CPUs, double-precision builds, and builds made with `SVG2D_SCALAR=yes` automatically use the equivalent scalar integration path.

```gdscript
var rope := SVGRope2D.new()
rope.src = "res://banner.svg"
rope.segments = 24
rope.max_length = 320.0
rope.elasticity = 0.85
add_child(rope)
```

```gdscript
var image_rope := SpriteRope2D.new()
image_rope.texture = preload("res://banner.png")
add_child(image_rope)
```

Animation is disabled by default. Enable `animation_enabled` to deform path outlines without translating the whole shape. `jitter_amount` is the maximum peak-to-peak deformation as a ratio of the document dimensions (0.0008 by default, capped at 0.3). Four deterministic frames using seeds 1 through 4 are cached and cycled every `animation_interval` frames (10 by default). Disabling animation releases its three extra cached textures. Both nodes support `flip_h`, `flip_v`, `offset`, and `modulate` (the 2D modulate is the inherited CanvasItem property).

The `adaptive` property is enabled by default. It follows 2D editor zoom and display scale with at least 1.5x supersampling, as well as runtime cameras and the 3D editor camera. `SVG3D` applies the larger projected local-axis density to both texture axes, preserving the SVG aspect ratio while rotated. Disable adaptive rendering to keep a fixed resolution, capped at 4096 pixels on either axis. `SVG3D` still uses 1.5 times the natural document resolution in fixed mode.

Adaptive textures are limited to 4096 pixels on either axis to keep one RGBA texture within 64 MiB. Very large on-screen SVGs therefore use the highest available resolution.

Pixel conversion uses SSE2 on x86_64 and NEON on arm64. Builds for other architectures use the equivalent scalar CPU path.

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are not supported.

## License

See `LICENSE` in this folder.

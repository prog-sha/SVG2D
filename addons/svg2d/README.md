# SVG2D

Language: **English** | [日本語](README.ja.md) · [Repository guide](https://github.com/prog-sha/SVG2D/blob/main/README.md)

SVG2D is a GDExtension add-on for SVG rendering, path animation, and texture or SVG ropes in Godot 2D and 3D scenes. It reuses textures while projected dimensions stay unchanged. `SVG3D` rasterizes at least 1.5 times its projected pixel size and generates mipmaps for cleaner lines.

## Compatibility

- Godot 4.7 or later
- Windows x86_64
- macOS Universal
- iOS arm64
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

Use `SVGAnimate2D` or `SVGAnimate3D` when existing SVG paths must be animated. Selecting the node shows every numbered anchor and the selected anchor's cubic handles directly in the 2D/3D editor. Drag anchors or handles and hold Shift to constrain movement. A normal handle drag preserves the smooth tangent on its opposite side; hold Alt to break and edit one side independently. `A` (or `V`), `I`, and `O` select anchor, incoming-handle, and outgoing-handle modes. Tab/Shift+Tab cycle points and `[`/`]` cycle paths. Anchor and handle edits are stored in the scene. Editing never adds or removes paths, points, or segments; arcs remain arcs and straight segments remain straight.

To key a specific control in the editor: select the `SVGAnimate2D` or `SVGAnimate3D` node in the Scene tree; scroll to **Path Editor** at the bottom of the Inspector; choose **Path N**, enter the point number shown beside the viewport dot as `N:point`, then select **Anchor (A)**, **In (I)** or **Out (O)**. Select an `AnimationPlayer` in the same scene, create or select an animation, move its timeline to the desired time, then reselect the SVG node and press the small key-plus button beside the point number. Alternatively, right-click a viewport control to key the selected point, either cubic handle, that path's fill/stroke paint, fill/stroke opacity, stroke width, node modulate, or all SVG properties at once. `K` keys the selected control. If no player exists, one is created automatically; existing tracks targeting the SVG are preferred over other players. **Create AnimationPlayer (All SVG Properties)** creates a separate player node with initial tracks for every anchor, actual cubic handle, path paint/stroke setting and node modulate. Change a value and key it again at another time to animate it. The standard Inspector key buttons on the dynamic path properties also work. Solid `fill_color` and `stroke_color` interpolate as colors; `fill_paint` and `stroke_paint` preserve `none`, gradient references and other non-solid paints as discrete strings. Only actual cubic handles are offered, so straight and arc segments are not silently changed into cubic segments.

Path overlays use the same rendered `viewBox`, `preserveAspectRatio`, nested group transforms, and path transforms in both directions. They stay aligned with node transforms, `flip_h` / `flip_v`, editor panning, and 2D/3D camera movement. Hand-drawn jitter affects the rendered outline only; editor points and saved coordinates remain unjittered.

`SpriteRope2D` and `SpriteRope3D` accept any standard `Texture2D`, including PNG, WebP, and Godot-imported SVG resources. `SVGRope2D` and `SVGRope3D` are separate SVG-source variants with the `src` picker and supersampled SVG rendering. Both use a PBD rope pinned at the node origin; rows from top to bottom follow the particle chain. Enable `line_mode` for a plain rope configured by `line_width` and `line_color`. `max_length` set to zero derives the length from the texture or SVG height. Ropes use their World's system gravity by default; `gravity_scale` adjusts its strength. Disable `use_system_gravity` only when the local `gravity` override is needed.

Set `attachment_body` to a `PhysicsBody2D` / `PhysicsBody3D` to create internal rigid segments and PinJoint constraints in the same physics space. Mass, inertia and collision reactions affect both the rope and the attached body. `rope_mass` sets the total rope mass; `attachment_point` selects a particle, with `-1` selecting the last. Internal segments have collision layers disabled; environment contact is handled by the attached body's CollisionShape. Enable that body's `lock_rotation` to prevent spinning.

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

Hand-drawn outline animation is disabled by default on SVG and SVGAnimate nodes. Enable `animation_enabled` to deform outlines without translating the whole shape. `jitter_amount` is the peak-to-peak deformation as a ratio of document dimensions (0.0008 by default, capped at 0.3). Four deterministic patterns cycle every `animation_interval` frames (10 by default). Whether four textures are retained depends on `cache_animation_frames`; SVGAnimate defaults to one reused texture during path edits. The nodes also support `flip_h`, `flip_v`, `offset`, and `modulate` (2D inherits CanvasItem's modulate).

The `adaptive` property is enabled by default. It follows 2D editor zoom and display scale with at least 1.5x supersampling, as well as runtime cameras and the 3D editor camera. `SVG3D` applies the larger projected local-axis density to both texture axes, preserving the SVG aspect ratio while rotated. Disable adaptive rendering to keep a fixed resolution, capped at 4096 pixels on either axis. `SVG3D` still uses 1.5 times the natural document resolution in fixed mode.

Adaptive textures are limited to 4096 pixels on either axis to keep one RGBA texture within 64 MiB. Very large on-screen SVGs therefore use the highest available resolution.

Pixel conversion uses SSE2 on x86_64 and NEON on arm64. Builds for other architectures use the equivalent scalar CPU path.

## SVG support

Supported features include basic shapes, paths, fills, strokes, gradients, clipping paths, `use`, nested `svg` elements, `viewBox`, and basic CSS selectors.

Text, filters, masks, patterns, markers, animation, and external images are not supported.

## License

See `LICENSE` in this folder.

## Performance and memory settings

| Inspector setting | Nodes | Effect |
| --- | --- | --- |
| `adaptive` | SVG2D / 3D and SVGAnimate | Enabled by default; follows editor and camera scale. Disable for a fixed raster resolution. |
| `deferred_updates` | SVGAnimate2D / 3D | On by default. Combines path edits until idle time, rebuilding and parsing the SVG once per batch. |
| `keep_render_cache` | SVG2D / 3D and subclasses | Disable to release intermediate buffers after rasterization. Rerendering requires more allocation and computation; the displayed texture is retained. |
| `cache_animation_frames` | SVG2D / 3D and SVGAnimate | Keep four jitter textures for an unchanged shape. SVGAnimate defaults to off; SVG2D / 3D defaults to on. |
| `animation_cache_mode` | SVGAnimate2D / 3D | Exact Frames reuses previous identical path states; Disabled retains no history. |
| `animation_cache_limit_mb` | SVGAnimate2D / 3D | History budget: 1–256 MiB, 32 MiB by default and at most 512 frames. |
| `dynamic_mesh` | SpriteRope3D / SVGRope3D | On by default. Updates vertices and bounds while retaining UVs and triangle indices. |

Point getters and scene saving always use current edits. Call `flush_paths()` before immediately reading an edited 2D texture with deferred updates enabled. 3D texture refresh occurs at idle time. `get_render_cache_bytes()` reports estimated intermediate buffer usage.

`SVGAnimate2D` / `SVGAnimate3D` support the same hand-drawn outline jitter as ordinary SVG nodes. Enable `animation_enabled` in the Inspector, set the amount with `jitter_amount`, and the pattern interval with `animation_interval`. Path animation preserves jitter timing. Editor anchors, handles, picking positions and saved values use the unjittered path coordinates.

`cache_animation_frames` keeps four patterns when enabled, or updates a single texture when disabled. SVGAnimate defaults to disabled for continuous deformation; ordinary SVG2D / SVG3D default to enabled. Enable it for static shapes to avoid rerasterizing each cycle, or disable it to reduce texture memory during frequent path edits. Both modes produce the same jitter.

### Path animation history cache

SVGAnimate's **Animation Cache → Animation Cache Mode** defaults to **Exact Frames**. It reuses textures when an identical serialized path state, resolution and jitter configuration recur. Hits skip SVG parsing, rasterization and texture upload. There is no time or coordinate quantization: continuously varying interpolation values may not hit. Use **Disabled** when retaining past frames is not useful.

**Animation Cache Limit Mb** sets the history budget (32 MiB by default, 1–256). Up to 512 frames are retained, evicting least recently used entries when either limit is reached. Oversized individual frames bypass retention. Current display references and renderer work buffers are separate from this budget. Replacing `src`, changing the mode or calling `clear_animation_cache()` clears history.

Use `get_animation_cache_hits()`, `get_animation_cache_misses()`, `get_animation_cache_bytes()` and `get_animation_cache_frame_count()` to inspect usage. `cache_animation_frames` retains jitter patterns for the current shape; **Exact Frames** also retains previous path states. Neither changes editor anchor or handle coordinates.

### Cutting ropes and two-way physics

`cut_segment(from, to)` cuts where the input **global-coordinate** segment first intersects the rope. It inserts a particle at the intersection, preserving the pieces' current positions, velocities, rest lengths, mass and matching texture regions. The 3D overload takes an optional `tolerance` (default `0.001` world units) for closest-point intersection. A miss, parallel overlap, rope endpoint, or invalid input returns `null`. Apply the operation to both pieces to cut multiple crossings. The [stickman rope scene](https://github.com/prog-sha/SVG2D/blob/main/tests/stickman_rope_swing.tscn) lets you drag the character and draw a cut across the background; its rotation is locked.

`cut_at(point_index)` splits at an interior particle, creates the same built-in rope class through `ClassDB.instantiate`, adds it to the same parent and returns it. The original keeps the upper part; the new rope has a free start. Current shape, linear/angular velocities and texture regions are preserved, and length and mass are divided. An attachment at or beyond the cut moves to the new rope. Valid indices are `1` through `segments - 2`. Endpoints, invalid indices and nodes outside the tree return `null` without changes. Runtime only; scripts, children and signal connections are not copied. Use `call_deferred` when cutting from physics query callbacks.

```gdscript
var fallen_rope = $Rope.cut_segment(Vector2(200, 100), Vector2(450, 100))
# fallen_rope.get_parent() == $Rope.get_parent()
```

Unattached ropes use SIMD Verlet integration. Attached ropes use Godot rigid-body physics: `elasticity` and `constraint_iterations` apply to Verlet, while rigid segments use the project's physics solver settings. `damping` is the fraction of velocity removed per 1/60 second, adjusted to the current timestep. Attached bodies keep their own damping settings. Clearing the attachment preserves the moving segments; `reset_simulation()` releases them and restores the initial shape.

The two-way design draws on [Verlet Rope's rigid-body implementation](https://github.com/Tshmofen/verlet-rope-4/blob/master/addons/verlet_rope_4/Physics/VerletRopeRigid.cs), with a C++ implementation here.

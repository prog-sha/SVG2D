# Godot Asset Library submission

Use these values when submitting SVG2D to the Godot Asset Library.

| Field | Value |
| --- | --- |
| Asset Name | SVG2D |
| Description | SVG2D adds adaptive SVG2D/SVG3D rendering, editor path and color animation through AnimationPlayer, hand-drawn outline jitter, and texture/SVG ropes in 2D and 3D. Ropes can attach PhysicsBody nodes through Godot pin joints and can be cut by a global-coordinate line segment. SVGAnimate offers an exact-frame history cache; render-buffer and jitter-frame caching are separately configurable. Basic shapes, paths, gradients, clips, use elements, nested SVG elements, viewBox, and basic CSS selectors are supported. Prebuilt debug and release libraries cover Windows x86_64, macOS Universal, Linux x86_64/arm64, Android arm64, iOS arm64, and threadless Web wasm32. Requires Godot 4.7 or later. |
| Category | 2D Tools |
| License | MIT |
| Repository host | GitHub |
| Repository URL | https://github.com/prog-sha/SVG2D |
| Issues URL | https://github.com/prog-sha/SVG2D/issues |
| Minimum Godot version | 4.7 |
| Asset Version | 0.9.0 |
| Download Commit | Use the full commit SHA containing the release files. |
| Icon URL | https://raw.githubusercontent.com/prog-sha/SVG2D/main/addons/svg2d/icon.png |

The GitHub provider can be used because the precompiled DLLs and dylibs are tracked in the repository. The `godot-cpp` submodule is needed only to build the extension from source and is not needed by Asset Library users.

Before submitting:

1. Build and test the debug and release binaries for Windows x86_64, macOS Universal, Linux x86_64/arm64, Android arm64, iOS arm64, and threadless Web wasm32 with the release source.
2. Update `version` in `addons/svg2d/plugin.cfg` and the Asset Version above together.
3. Commit all release files and use the resulting full commit SHA as Download Commit.
4. Verify the generated archive contains only `addons/svg2d/` and that the add-on installs into a clean Godot 4.7 or later project.

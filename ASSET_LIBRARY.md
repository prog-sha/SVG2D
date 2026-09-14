# Godot Asset Library submission

Use these values when submitting SVG2D to the Godot Asset Library.

| Field | Value |
| --- | --- |
| Asset Name | SVG2D |
| Description | SVG2D adds a Godot SVG editing workspace plus lightweight SVG2D and SVG3D runtime nodes. Draw, arrange, inspect, and save standard SVG files without leaving the editor. Runtime nodes rasterize at their integer viewport dimensions and reuse cached textures while those dimensions stay unchanged. Pixel conversion uses SSE2 on x86_64 and NEON on arm64. Editor code is excluded from exported games. Windows x86_64 and macOS Universal binaries are included; Godot 4.7 or later is required. |
| Category | 2D Tools |
| License | MIT |
| Repository host | GitHub |
| Repository URL | https://github.com/prog-sha/SVG2D |
| Issues URL | https://github.com/prog-sha/SVG2D/issues |
| Minimum Godot version | 4.7 |
| Asset Version | 0.5.0 |
| Download Commit | Use the full commit SHA containing the release files. |
| Icon URL | https://raw.githubusercontent.com/prog-sha/SVG2D/main/addons/svg2d/icon.png |

The GitHub provider can be used because the precompiled DLLs and dylibs are tracked in the repository. The `godot-cpp` submodule is needed only to build the extension from source and is not needed by Asset Library users.

Before submitting:

1. Build and test the debug and release binaries for Windows x86_64 and macOS Universal with the release source.
2. Update `version` in `addons/svg2d/plugin.cfg` and the Asset Version above together.
3. Commit all release files and use the resulting full commit SHA as Download Commit.
4. Verify the generated archive contains only `addons/svg2d/` and that the add-on installs into a clean Godot 4.7 project.

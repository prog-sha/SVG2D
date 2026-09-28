---
name: godot-editor-acceptance
description: Verify user-visible Godot editor, rendering, path-editing, and animation changes against the exact requested scene and independent visual evidence. Use for GDExtension or editor-plugin work where headless tests alone cannot establish what users see; do not impose visual testing on unrelated nonvisual edits.
---

# Godot editor acceptance

The result to verify is the user's workflow, not merely a function's return value. Preserve the user's specified asset, scene, editor action, and viewing conditions as acceptance criteria before implementing a fix. A convenient demo is not a substitute for the requested fixture.

## Establish the observable case

- Record the relevant source asset and the exact interaction: setting it through the Inspector, selecting or dragging a path point or handle, adding a keyframe, seeking an animation, or viewing the rendered result.
- Include the combinations that can change the result: 2D/3D, nested transforms, the SVG node's own scale, flip and offset, and 3D camera position, rotation, and projection. Test combinations implicated by the report, not an arbitrary checklist for every edit.
- For animation captures, stop or pause playback before seeking to a named time. Record the actual time and configuration for each frame so a changing screenshot cannot masquerade as the requested animation state.

## Require independent evidence

- A round trip through production forward and inverse coordinate functions is not an independent position test: both can share one incorrect assumption. Compare editor handles and picking with Godot's actual rendered geometry or engine-provided bounds and transforms, then inspect a capture from the same scene.
- Exercise the real editor route when the change affects editor behavior. Headless integration tests may check APIs and events, but they do not prove that a point overlays the visible path, is clickable, or moves correctly in the editor.
- Use the project's Godot-driven editor capture or another permitted capture method for visual proof. Respect a user's prohibition on computer-use automation; do not silently replace a requested editor view with a synthetic diagram or unrelated scene.
- Separate evidence for compile success, headless tests, real editor appearance, editor interaction, animation output, and cross-platform artifact checks. A result in one category does not establish another.

## Fix the module, not the example

- Locate the shared source of truth for coordinates, geometry, redraws, and animation state. Do not branch on a particular SVG, path index, color, scene name, or test fixture to make one example pass.
- If a special case is genuinely required by the format or engine, define it using a content-independent property, explain the invariant, and test unrelated assets that satisfy and do not satisfy it.
- Keep editor updates event-driven where possible. Avoid expensive per-frame work solely to hide stale display state; verify that the actual state change schedules the redraw it needs.

## Completion gate

Before saying "fixed" or "tested," check the requested fixture and actions against the evidence. Report the commands and artifact locations for each passed check, and state failures and untested conditions explicitly. If a required screenshot, interaction, or independent comparison is missing—or the capture visibly disagrees with the claim—continue investigating or report the work as unverified, not complete.

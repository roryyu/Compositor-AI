---
name: compositor
description: Control the Compositor image editor on macOS — create documents, draw shapes/text/gradients, paint strokes, fill/select/crop/resize, transform layers, apply filters, and generate images with AI. Use when the user asks to draw, paint, edit, or manipulate an image in Compositor.
---

# Compositor control

Drive a running [Compositor](../../README.md) instance (a macOS SwiftUI image editor) through its local control API. The bridge is `compositor-mcp`; it launches Compositor automatically if the app isn't running.

## Two ways in

**MCP (preferred).** If configured, use the MCP tools directly — they are exactly the tools listed below.

```toml
# ~/.codex/config.toml
[mcp_servers.compositor]
command = "/Users/roryyu/Downloads/code/mycode/Compositor/Tools/CompositorMCP/.build/release/compositor-mcp"
```

**CLI (fallback).** Same tools over the shell:

```sh
B=/Users/roryyu/Downloads/code/mycode/Compositor/Tools/CompositorMCP/.build/release/compositor-mcp
$B health                     # app reachable?
$B tools                      # list tools
$B state                      # full canvas snapshot (pretty JSON)
$B call draw_shape '{"kind":"Ellipse","rect":[0,0,50,50],"color":"black"}'
```

`call` exits non-zero and prints the error message on failure.

## Workflow

1. **Call `get_canvas_state` first** and whenever you need fresh data. It returns `width`, `height`, `activeLayerID`, `selectionBounds`, and `layers` (each with a **short 8-char id** — that's what `layer_id` parameters take).
2. **No document open?** (`width == 0` or empty layers on a fresh session) Call `create_document` with the size. Nearly every other tool throws `noDocument` otherwise.
3. Make edits. Every edit is a normal undo step in the app; `undo` reverts one step.
4. Verify against `get_canvas_state` when done, and say what changed. Do **not** call `finish` — that tool belongs to the in-app agent loop only.

## Tool reference

**State:** `get_canvas_state`

**Document:** `create_document` (width, height) · `resize_canvas` (layers keep position) · `resize_image` (scales everything) · `crop` (rect) · `trim`

**Layers:** `add_blank_layer` (optional name) · `duplicate_layer` · `delete_layer` · `set_layer_properties` (opacity 0–1, blend_mode, visible, name) · `reorder_layer` (up/down) · `group_layers` · `merge_layers` · `transform_layer` (dx, dy, scale, rotation°)

**Draw** (all take `color` as a CSS name or `#rrggbb`; `draw_shape`/`draw_gradient` create their own layer):
`draw_shape` (kind Rectangle|Ellipse, rect [x,y,w,h], corner_radius for rects) · `draw_stroke` (points [[x,y]…], diameter, hardness, opacity) · `add_text` (text, point, font_size, font_name) · `draw_gradient` (kind linear|radial, rect, from, to) · `fill_layer` (target layer|selection)

**Select:** `set_selection` (all|rect|ellipse, rect, feather) · `modify_selection` (invert|deselect) · `select_subject`

**Effects:** `apply_filter` (Gaussian Blur, Motion Blur, Add Noise, Vignette, Bloom / Glow, Tonal Contrast, Remove Background — with radius/angle/distance/amount as applicable) · `apply_adjustment` (adds an adjustment layer) · `flip` (canvas|layers, horizontal|vertical)

**AI:** `analyze_image` (target canvas|active_layer, question in English — needs the vision model configured) · `generate_image` (prompt in English — needs the image model configured; inserts as a new centered layer)

**Meta:** `undo`

## Conventions

- Coordinates are **document points, top-left origin**: `[x, y, width, height]` for rects, `[x, y]` for points. Bounds from `get_canvas_state` are `[x, y, w, h]` arrays in the same space.
- Prefer `draw_shape` over stroke-by-stroke painting for geometric figures; prefer `fill_layer` over painting a solid region.
- Layer ids are short ids (first 8 chars of the UUID, e.g. `3F2A9C1B`) as reported by `get_canvas_state`; omit `layer_id` to mean the active layer.
- Colors: `"red"`, `"#FF8800"`, or separate `red`/`green`/`blue` floats 0–1.
- If a model isn't configured, `analyze_image` and `generate_image` fail with a clear message — tell the user to set up AI Settings in the app (AI menu) rather than retrying.

## Recipes

*"Draw a black circle, 50 px diameter, on a 800×600 canvas":*

```
create_document {"width":800,"height":600}        # only if state showed no document
draw_shape {"kind":"Ellipse","rect":[100,100,50,50],"color":"black"}
```

*"Make a title card":* `create_document` → `fill_layer {"color":"#101014"}` → `add_text {"text":"Hello","point":[200,260],"font_size":72,"font_name":"Helvetica-Bold","color":"white"}`

*"Blur the background":* `select_subject` → `modify_selection {"action":"invert"}` → `apply_filter {"kind":"Gaussian Blur","radius":8}`

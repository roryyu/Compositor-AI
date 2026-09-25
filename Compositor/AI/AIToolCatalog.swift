import AppKit

/// The function-calling tool directory advertised to the model. Each entry pairs a
/// JSON Schema with a handler in `AIToolDispatcher`.
nonisolated enum AIToolCatalog {
    static let all: [ToolDefinition] = [
        ToolDefinition(name: "get_canvas_state",
                       description: "Return the current canvas state: size, layers, active layer, and selection. Call this first and whenever you need fresh ids or bounds.",
                       parameters: .schema([:])),

        ToolDefinition(name: "analyze_image",
                       description: "Ask the vision model about part of the image, e.g. locating a subject or reading colors.",
                       parameters: .schema([
                        "target": .stringProperty("What to look at.", enum: ["canvas", "active_layer"]),
                        "question": .stringProperty("The question, in English."),
                       ], required: ["target", "question"])),

        ToolDefinition(name: "add_blank_layer",
                       description: "Add a transparent raster layer above the active layer.",
                       parameters: .schema([
                        "name": .stringProperty("Optional layer name."),
                       ])),

        ToolDefinition(name: "generate_image",
                       description: "Generate an image from a text prompt and insert it as a new layer, centered on the canvas.",
                       parameters: .schema([
                        "prompt": .stringProperty("What to generate, in English. Be specific and visual."),
                        "name": .stringProperty("Optional layer name."),
                       ], required: ["prompt"])),

        ToolDefinition(name: "duplicate_layer",
                       description: "Duplicate a layer. The copy is placed just above the original.",
                       parameters: .schema([
                        "layer_id": .stringProperty("The short layer id. Defaults to the active layer."),
                       ])),

        ToolDefinition(name: "delete_layer",
                       description: "Delete a layer, including everything in a group.",
                       parameters: .schema([
                        "layer_id": .stringProperty("The short layer id. Defaults to the active layer."),
                       ])),

        ToolDefinition(name: "set_layer_properties",
                       description: "Change one or more properties of a layer.",
                       parameters: .schema([
                        "layer_id": .stringProperty("The short layer id. Defaults to the active layer."),
                        "opacity": .numberProperty("0 to 1.", minimum: 0, maximum: 1),
                        "blend_mode": .stringProperty("Blend mode name.", enum: LayerBlendMode.allCases.map(\.rawValue)),
                        "visible": .boolProperty("Whether the layer is visible."),
                        "name": .stringProperty("New layer name."),
                       ])),

        ToolDefinition(name: "reorder_layer",
                       description: "Move a layer up or down within its siblings.",
                       parameters: .schema([
                        "layer_id": .stringProperty("The short layer id. Defaults to the active layer."),
                        "direction": .stringProperty("Direction to move.", enum: ["up", "down"]),
                       ], required: ["direction"])),

        ToolDefinition(name: "group_layers",
                       description: "Put the listed layers (or the current selection) into a group.",
                       parameters: .schema([
                        "layer_ids": JSONValue.object(["type": .string("array"),
                                                       "items": .string("string"),
                                                       "description": .string("Short layer ids. Defaults to the current selection.")]),
                       ])),

        ToolDefinition(name: "merge_layers",
                       description: "Merge the listed layers into one raster layer. With no ids, merge the active layer into the one below.",
                       parameters: .schema([
                        "layer_ids": JSONValue.object(["type": .string("array"),
                                                       "items": .string("string"),
                                                       "description": .string("Short layer ids.")]),
                       ])),

        ToolDefinition(name: "flip",
                       description: "Flip the whole canvas or the selected layers.",
                       parameters: .schema([
                        "target": .stringProperty("What to flip.", enum: ["canvas", "layers"]),
                        "axis": .stringProperty("Flip axis.", enum: ["horizontal", "vertical"]),
                       ], required: ["target", "axis"])),

        ToolDefinition(name: "transform_layer",
                       description: "Move, scale, or rotate a layer. Provide only the changes you want.",
                       parameters: .schema([
                        "layer_id": .stringProperty("The short layer id. Defaults to the active layer."),
                        "dx": .numberProperty("Move right by this many points (negative for left)."),
                        "dy": .numberProperty("Move down by this many points (negative for up)."),
                        "scale": .numberProperty("Uniform scale factor, e.g. 1.5 or 0.5.", minimum: 0.01, maximum: 100),
                        "rotation": .numberProperty("Additional clockwise rotation in degrees, -180 to 180.", minimum: -180, maximum: 180),
                       ])),

        ToolDefinition(name: "undo",
                       description: "Undo the last edit.",
                       parameters: .schema([:])),

        ToolDefinition(name: "fill_layer",
                       description: "Fill the active layer (or the selection within it) with a solid color.",
                       parameters: .schema(fields(colorParams, merging: [
                        "target": .stringProperty("What to fill.", enum: ["layer", "selection"]),
                       ]))),

        ToolDefinition(name: "draw_stroke",
                       description: "Paint a smooth stroke through a list of points on the active raster layer.",
                       parameters: .schema(fields([
                        "points": JSONValue.object(["type": .string("array"),
                                                    "description": .string("Points [x, y] in document coordinates, in order."),
                                                    "items": JSONValue.object(["type": .string("array"),
                                                                              "items": JSONValue.object(["type": .string("number")]),
                                                                              "minItems": .int(2), "maxItems": .int(2)])]),
                        "diameter": .numberProperty("Brush diameter in points.", minimum: 1, maximum: 2000),
                        "hardness": .numberProperty("0 (soft) to 1 (hard).", minimum: 0, maximum: 1),
                        "opacity": .numberProperty("0.01 to 1.", minimum: 0.01, maximum: 1),
                       ], merging: colorFields), required: ["points"])),

        ToolDefinition(name: "draw_shape",
                       description: "Draw a filled rectangle or ellipse on a new layer.",
                       parameters: .schema(fields([
                        "kind": .stringProperty("Shape kind.", enum: ["Rectangle", "Ellipse"]),
                        "rect": rectProperty("The shape's rect: x, y, width, height in document coordinates."),
                        "corner_radius": .numberProperty("Rounded corner radius, rectangles only.", minimum: 0),
                       ], merging: colorFields), required: ["kind", "rect"])),

        ToolDefinition(name: "add_text",
                       description: "Add a text layer at a point.",
                       parameters: .schema(fields([
                        "text": .stringProperty("The text content."),
                        "point": pointProperty("Where the text starts, in document coordinates."),
                        "font_size": .numberProperty("Font size in points.", minimum: 1, maximum: 2000),
                        "font_name": .stringProperty("PostScript font name, e.g. Helvetica-Bold."),
                       ], merging: colorFields), required: ["text", "point"])),

        ToolDefinition(name: "draw_gradient",
                       description: "Draw a linear or radial gradient from a color to transparent, on a new layer.",
                       parameters: .schema(fields([
                        "kind": .stringProperty("Gradient kind.", enum: ["linear", "radial"]),
                        "rect": rectProperty("The layer rect the gradient covers."),
                        "from": pointProperty("Gradient start point in document coordinates."),
                        "to": pointProperty("Gradient end point in document coordinates."),
                       ], merging: colorFields), required: ["kind", "rect", "from", "to"])),

        ToolDefinition(name: "apply_adjustment",
                       description: "Add an adjustment layer of the given kind above the active layer.",
                       parameters: .schema([
                        "kind": .stringProperty("Adjustment kind.",
                                                enum: AdjustmentKind.allCases.map(\.rawValue)),
                       ], required: ["kind"])),

        ToolDefinition(name: "apply_filter",
                       description: "Apply a filter to the active raster layer. Provide the parameter for the chosen kind.",
                       parameters: .schema([
                        "kind": .stringProperty("Filter kind.", enum: [
                            "Gaussian Blur", "Motion Blur", "Add Noise", "Vignette", "Bloom / Glow",
                            "Tonal Contrast", "Remove Background",
                        ]),
                        "radius": .numberProperty("Gaussian Blur radius in points.", minimum: 0.1, maximum: 250),
                        "angle": .numberProperty("Motion Blur angle in degrees.", minimum: -90, maximum: 90),
                        "distance": .numberProperty("Motion Blur streak length in points.", minimum: 1, maximum: 2000),
                        "amount": .numberProperty("Strength as a percentage (noise 0.1-400, others 0-100).", minimum: 0.1, maximum: 400),
                       ], required: ["kind"])),

        ToolDefinition(name: "set_selection",
                       description: "Replace the current selection.",
                       parameters: .schema([
                        "shape": .stringProperty("Selection shape.", enum: ["all", "rect", "ellipse"]),
                        "rect": rectProperty("Required for rect and ellipse."),
                        "feather": .numberProperty("Feather radius in points.", minimum: 0, maximum: 250),
                       ], required: ["shape"])),

        ToolDefinition(name: "modify_selection",
                       description: "Invert or clear the current selection.",
                       parameters: .schema([
                        "action": .stringProperty("Action.", enum: ["invert", "deselect"]),
                       ], required: ["action"])),

        ToolDefinition(name: "select_subject",
                       description: "Select the main subject of the image automatically.",
                       parameters: .schema([:])),

        ToolDefinition(name: "crop",
                       description: "Crop the canvas to a rect.",
                       parameters: .schema([
                        "rect": rectProperty("The crop rect."),
                       ], required: ["rect"])),

        ToolDefinition(name: "resize_canvas",
                       description: "Change the canvas size. Layers keep their positions (top-left anchor).",
                       parameters: .schema([
                        "width": .integerProperty("New canvas width.", minimum: 1, maximum: 30000),
                        "height": .integerProperty("New canvas height.", minimum: 1, maximum: 30000),
                       ], required: ["width", "height"])),

        ToolDefinition(name: "resize_image",
                       description: "Scale the whole image, canvas and layers, to a new pixel size.",
                       parameters: .schema([
                        "width": .integerProperty("New image width.", minimum: 1, maximum: 30000),
                        "height": .integerProperty("New image height.", minimum: 1, maximum: 30000),
                       ], required: ["width", "height"])),

        ToolDefinition(name: "trim",
                       description: "Crop away empty or single-color borders.",
                       parameters: .schema([:])),

        ToolDefinition(name: "finish",
                       description: "End the task and report what was done. Call this once the instruction is fully satisfied.",
                       parameters: .schema([
                        "summary": .stringProperty("A short summary of what you did."),
                       ], required: ["summary"])),
    ]

    /// Merges two parameter dictionaries; keys in `extra` win.
    static func fields(_ base: [String: JSONValue], merging extra: [String: JSONValue]) -> [String: JSONValue] {
        base.merging(extra) { _, new in new }
    }

    /// Shared color parameter schema fields.
    static var colorFields: [String: JSONValue] {
        [
            "color": .stringProperty("Color name or #rrggbb hex, e.g. '#FF8800' or 'white'."),
            "red": .numberProperty("Red 0-1 (used when no color is given).", minimum: 0, maximum: 1),
            "green": .numberProperty("Green 0-1.", minimum: 0, maximum: 1),
            "blue": .numberProperty("Blue 0-1.", minimum: 0, maximum: 1),
        ]
    }
    static var colorParams: [String: JSONValue] { colorFields }

    static func pointProperty(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description),
                 "items": .object(["type": .string("number")]),
                 "minItems": .int(2), "maxItems": .int(2)])
    }
    static func rectProperty(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "description": .string(description),
                 "items": .object(["type": .string("number")]),
                 "minItems": .int(4), "maxItems": .int(4)])
    }
}

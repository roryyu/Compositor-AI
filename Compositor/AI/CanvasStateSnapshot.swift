import AppKit

/// A read-only description of the canvas handed to the model each turn. Layer ids are
/// shortened to their first 8 characters to save tokens; the dispatcher resolves them.
nonisolated struct LayerStateInfo: Sendable {
    var shortID: String
    var name: String
    var visible: Bool
    var opacity: Double
    var blendMode: String
    var bounds: CGRect
    var isGroup: Bool
    var hasMask: Bool
    var kind: String   // "shape: Rectangle", "text", "adjustment: Levels", "image"
    var parent: String?
}

nonisolated struct CanvasStateSnapshot: Sendable {
    var width: Int
    var height: Int
    var activeLayerID: String?
    var selectionBounds: CGRect?
    var tool: String
    var layers: [LayerStateInfo]

    static func shortID(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    static func capture(_ session: EditorSession) -> CanvasStateSnapshot {
        guard let document = session.document else {
            return CanvasStateSnapshot(width: 0, height: 0, activeLayerID: nil,
                                      selectionBounds: nil, tool: session.tool.rawValue, layers: [])
        }
        let infos = document.layers.map { layer -> LayerStateInfo in
            var kind = "image"
            if layer.isGroup { kind = "group" }
            else if let shape = layer.liveShape { kind = "shape: \(shape.style.kind.rawValue)" }
            else if layer.liveText != nil { kind = "text" }
            else if let adjustment = layer.adjustment { kind = "adjustment: \(adjustment.kind.rawValue)" }
            return LayerStateInfo(
                shortID: shortID(layer.id),
                name: layer.name,
                visible: layer.isVisible,
                opacity: layer.opacity,
                blendMode: layer.blendMode.rawValue,
                bounds: CGRect(origin: layer.origin, size: layer.size),
                isGroup: layer.isGroup,
                hasMask: layer.mask != nil,
                kind: kind,
                parent: layer.parentID.map { shortID($0) })
        }
        let selectionBounds = session.selection.map { $0.path.boundingBoxOfPath }
        return CanvasStateSnapshot(
            width: document.width,
            height: document.height,
            activeLayerID: session.activeLayerID.map { shortID($0) },
            selectionBounds: selectionBounds?.isNull == true || selectionBounds?.isEmpty == true ? nil : selectionBounds,
            tool: session.tool.rawValue,
            layers: infos)
    }

    /// A compact plain-text rendering for the system message.
    var promptText: String {
        var lines: [String] = ["Canvas: \(width)x\(height) points. Active tool: \(tool). Origin (0,0) is the top-left; x grows right, y grows down."]
        if let activeLayerID { lines.append("Active layer: \(activeLayerID)") }
        if let selectionBounds {
            lines.append(String(format: "Selection bounds: x=%.0f y=%.0f w=%.0f h=%.0f",
                               selectionBounds.minX, selectionBounds.minY, selectionBounds.width, selectionBounds.height))
        } else {
            lines.append("Selection: none")
        }
        lines.append("Layers, bottom to top:")
        for layer in layers {
            let b = layer.bounds
            let parent = layer.parent.map { " parent=\($0)" } ?? ""
            lines.append(String(format: "- %@ \"%@\" %@ opacity=%.2f blend=%@ bounds=[%.0f,%.0f %.0fx%.0f]%@%@",
                               layer.shortID, layer.name, layer.visible ? "visible" : "hidden",
                               layer.opacity, layer.blendMode,
                               b.minX, b.minY, b.width, b.height,
                               " kind=\(layer.kind)", parent))
        }
        return lines.joined(separator: "\n")
    }

    /// Structured form, for tool observations.
    var json: JSONValue {
        .object([
            "width": .int(width),
            "height": .int(height),
            "activeLayerID": activeLayerID.map { .string($0) } ?? .null,
            "selectionBounds": selectionBounds.map { rect in
                .array([.double(rect.minX), .double(rect.minY), .double(rect.width), .double(rect.height)])
            } ?? .null,
            "layers": .array(layers.map { layer in
                .object([
                    "id": .string(layer.shortID),
                    "name": .string(layer.name),
                    "visible": .bool(layer.visible),
                    "opacity": .double(layer.opacity),
                    "blendMode": .string(layer.blendMode),
                    "kind": .string(layer.kind),
                ])
            }),
        ])
    }
}

import AppKit

/// One anchor of a pen path, in the layer box's 0–1 unit coordinates (the way a Line shape stores its ends),
/// so the path redraws correctly at any size. A nil handle is a corner with no curve on that side.
nonisolated struct PathAnchor: Codable, Equatable, Sendable {
    var point: CGPoint
    var inHandle: CGPoint? = nil
    var outHandle: CGPoint? = nil
}

/// What a path layer draws, kept so it can be drawn again at a new size.
nonisolated struct LayerPathStyle: Codable, Equatable, Sendable {
    var anchors: [PathAnchor]
    var closed: Bool
    /// False fills the path; true strokes it with `lineWidth`.
    var stroked: Bool
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    /// The stroke's thickness in the layer box's own pixels.
    var lineWidth: CGFloat
    var color: PaletteColor { PaletteColor(red: red, green: green, blue: blue) }

    /// The cubic Bézier path inside `rect`, from the unit-coordinate anchors and handles.
    func cgPath(in rect: CGRect) -> CGPath {
        func p(_ u: CGPoint) -> CGPoint { CGPoint(x: rect.minX + u.x * rect.width, y: rect.minY + u.y * rect.height) }
        let path = CGMutablePath()
        guard let first = anchors.first else { return path }
        path.move(to: p(first.point))
        var previous = first
        for anchor in anchors.dropFirst() {
            if let c1 = previous.outHandle, let c2 = anchor.inHandle {
                path.addCurve(to: p(anchor.point), control1: p(c1), control2: p(c2))
            } else {
                path.addLine(to: p(anchor.point))
            }
            previous = anchor
        }
        if closed, anchors.count > 1 {
            if let c1 = previous.outHandle, let c2 = first.inHandle {
                path.addCurve(to: p(first.point), control1: p(c1), control2: p(c2))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// A layer made with the Pen tool. Like `LayerShape`: its pixels are an ordinary raster, so it clips, masks,
/// blends and filters like any layer, and `image` is the raster the path drew. Once anything else changes those
/// pixels, the layer's image is no longer this one and the layer is plain pixels from then on.
nonisolated struct LayerPath: Equatable, @unchecked Sendable {
    var style: LayerPathStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerPathStyle?, image: CGImage?) -> LayerPath? {
        guard let style, let image else { return nil }
        return LayerPath(style: style, image: image)
    }
}

extension ImageLayer {
    /// The path this layer still is: nil once its pixels were edited some other way.
    var livePath: LayerPath? {
        guard let path, let image = asset?.image, image === path.image else { return nil }
        return path
    }
}

/// A path being drawn with the Pen tool, in whole document pixels. Handles are absolute document points too;
/// they become unit coordinates only when the path lands on a layer (see `EditorSession.finishPen`).
struct PathDraft: Equatable {
    var anchors: [PathAnchor] = []
    var closed = false
    /// The anchor index whose handles a drag is currently pulling out, if any.
    var dragging: Int? = nil
    /// Where the pointer is, for the rubber-band segment to the next click.
    var cursor: CGPoint? = nil
}

/// An in-progress edit of an existing path layer's anchors: a copy of its style, and what is being dragged.
struct PathEdit: Equatable {
    enum Target: Equatable {
        case anchor(Int)
        case inHandle(Int)
        case outHandle(Int)
    }
    let layerID: UUID
    var style: LayerPathStyle
    var target: Target
}

extension EditorSession {
    /// How close a click must be to an anchor or handle, in document pixels, to grab it.
    nonisolated static let penHitRadius: CGFloat = 6

    /// Starts or continues a path: a click adds an anchor, a click on the first anchor closes and finishes it.
    func beginPen(at point: CGPoint) {
        guard tool == .pen, canEditLayers, point.x.isFinite, point.y.isFinite else { return }
        var draft = penDraft ?? PathDraft()
        // Clicking the first anchor of a path with something to close finishes it as a closed shape.
        if draft.anchors.count >= 3, let first = draft.anchors.first,
           hypot(point.x - first.point.x, point.y - first.point.y) <= Self.penHitRadius {
            draft.closed = true
            draft.dragging = nil
            penDraft = draft
            finishPen()
            return
        }
        draft.anchors.append(PathAnchor(point: point))
        draft.dragging = draft.anchors.count - 1
        draft.cursor = point
        penDraft = draft
    }

    /// Dragging out from a freshly placed anchor pulls its handles, making it a smooth point.
    func dragPen(to point: CGPoint) {
        guard var draft = penDraft, point.x.isFinite, point.y.isFinite else { return }
        if let index = draft.dragging, draft.anchors.indices.contains(index) {
            let anchor = draft.anchors[index].point
            draft.anchors[index].outHandle = point
            draft.anchors[index].inHandle = CGPoint(x: 2 * anchor.x - point.x, y: 2 * anchor.y - point.y)
        }
        draft.cursor = point
        penDraft = draft
    }

    /// Moves the rubber-band end without placing a handle.
    func movePenCursor(to point: CGPoint) {
        guard var draft = penDraft, draft.dragging == nil, point.x.isFinite, point.y.isFinite else { return }
        draft.cursor = point
        penDraft = draft
    }

    /// Ends the drag from the last anchor; the path stays open for the next click until Enter finishes it.
    func endPenDrag() {
        guard var draft = penDraft, draft.dragging != nil else { return }
        draft.dragging = nil
        penDraft = draft
    }

    func cancelPen() {
        if penDraft != nil { penDraft = nil }
    }

    /// Rasterizes the drawn path onto a new layer above the active one, in one undo step. A path too short to
    /// enclose or stroke makes nothing.
    func finishPen() {
        guard let draft = penDraft else { return }
        penDraft = nil
        // A fill needs three anchors to enclose an area; a stroke needs two to run between.
        guard draft.anchors.count >= (draft.closed || !penStroked ? 3 : 2) else { return }
        let pad = (penStroked ? CGFloat(penLineWidth) / 2 : 0) + 0.5
        var box = CGRect.null
        func add(_ p: CGPoint) { box = box.isNull ? CGRect(x: p.x, y: p.y, width: 0, height: 0) : box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
        for anchor in draft.anchors {
            add(anchor.point)
            if let h = anchor.inHandle { add(h) }
            if let h = anchor.outHandle { add(h) }
        }
        guard !box.isNull else { return }
        let padded = box.insetBy(dx: -pad, dy: -pad)
        let origin = CGPoint(x: padded.minX.rounded(.down), y: padded.minY.rounded(.down))
        let rect = CGRect(x: origin.x, y: origin.y,
                          width: padded.maxX.rounded(.up) - origin.x, height: padded.maxY.rounded(.up) - origin.y)
        guard canEditLayers, document != nil, rect.width >= 1, rect.height >= 1 else { return }
        guard Int(rect.width) * Int(rect.height) <= Self.maxShapePixels else {
            brushError = "That path is too large. A path can cover up to \(DocumentLimits.maxSurfaceMegapixels) megapixels."
            return
        }
        func unit(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.width > 0 ? (p.x - rect.minX) / rect.width : 0.5,
                    y: rect.height > 0 ? (p.y - rect.minY) / rect.height : 0.5)
        }
        let anchors = draft.anchors.map { PathAnchor(point: unit($0.point), inHandle: $0.inHandle.map(unit), outHandle: $0.outHandle.map(unit)) }
        let style = LayerPathStyle(anchors: anchors, closed: draft.closed, stroked: penStroked,
                                   red: foregroundColor.red, green: foregroundColor.green, blue: foregroundColor.blue,
                                   lineWidth: CGFloat(max(1, penLineWidth)))
        do {
            let image = try Self.pathImage(style: style, size: rect.size)
            addPixelLayer(image, at: rect.origin, name: nextPathName(), editName: "Path",
                          dropsSelection: false, path: LayerPath(style: style, image: image))
        } catch { brushError = error.localizedDescription }
    }

    /// "Path 1", "Path 2", … skipping names already in the document.
    func nextPathName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("Path \(number)") { number += 1 }
        return "Path \(number)"
    }

    /// The path filled or stroked into its box, anti-aliased where it curves.
    nonisolated static func pathImage(style: LayerPathStyle, size: CGSize) throws -> CGImage {
        let context = try BrushRaster.context(width: max(1, Int(size.width)), height: max(1, Int(size.height)), mask: false)
        let bounds = CGRect(origin: .zero, size: size)
        let color = CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1)
        context.addPath(style.cgPath(in: bounds))
        if style.stroked {
            context.setStrokeColor(color)
            context.setLineWidth(max(1, style.lineWidth))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        } else {
            context.setFillColor(color)
            context.fillPath()
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// A path layer scaled to a new size draws its path again at that size, so its curves stay true instead of
    /// stretching. Part of the edit that changed the size, exactly like `redrawShape`.
    func redrawPath(at index: Int) {
        guard let layer = document?.layers[index], let path = layer.livePath, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded())), height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height, width * height <= Self.maxShapePixels,
              let image = try? Self.pathImage(style: path.style, size: CGSize(width: width, height: height)),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        if let mask = layer.mask, mask.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].path = LayerPath(style: path.style, image: image)
    }

    // MARK: - Editing an existing path layer

    /// Grabs an anchor or handle of the active path layer if the click lands on one, starting an edit. Returns
    /// false when there is nothing to grab, so the caller can start a new path instead. Option-clicking an
    /// anchor corners it (drops its handles) right away.
    func beginPathEdit(at point: CGPoint, option: Bool) -> Bool {
        guard tool == .pen, canEditLayers, let layer = activeLayer, let path = layer.livePath else { return false }
        let box = CGRect(origin: layer.transform.origin, size: layer.transform.size)
        guard box.width > 0, box.height > 0 else { return false }
        func doc(_ u: CGPoint) -> CGPoint { CGPoint(x: box.minX + u.x * box.width, y: box.minY + u.y * box.height) }
        let r = Self.penHitRadius
        let style = path.style
        for (i, anchor) in style.anchors.enumerated() {
            if let h = anchor.outHandle, hypot(point.x - doc(h).x, point.y - doc(h).y) <= r {
                pathEdit = PathEdit(layerID: layer.id, style: style, target: .outHandle(i)); return true
            }
            if let h = anchor.inHandle, hypot(point.x - doc(h).x, point.y - doc(h).y) <= r {
                pathEdit = PathEdit(layerID: layer.id, style: style, target: .inHandle(i)); return true
            }
        }
        for (i, anchor) in style.anchors.enumerated() where hypot(point.x - doc(anchor.point).x, point.y - doc(anchor.point).y) <= r {
            if option {
                var cornered = style
                cornered.anchors[i].inHandle = nil
                cornered.anchors[i].outHandle = nil
                commitPathEdit(style: cornered, layerID: layer.id, name: "Corner Anchor")
                return true
            }
            pathEdit = PathEdit(layerID: layer.id, style: style, target: .anchor(i)); return true
        }
        return false
    }

    /// Moves the grabbed anchor or handle to `point`; an anchor carries its handles along with it.
    func dragPathEdit(to point: CGPoint) {
        guard var edit = pathEdit, let layer = document?.layers.first(where: { $0.id == edit.layerID }),
              point.x.isFinite, point.y.isFinite else { return }
        let box = CGRect(origin: layer.transform.origin, size: layer.transform.size)
        guard box.width > 0, box.height > 0 else { return }
        let unit = CGPoint(x: (point.x - box.minX) / box.width, y: (point.y - box.minY) / box.height)
        switch edit.target {
        case .anchor(let i) where edit.style.anchors.indices.contains(i):
            let old = edit.style.anchors[i].point
            let dx = unit.x - old.x, dy = unit.y - old.y
            edit.style.anchors[i].point = unit
            if let h = edit.style.anchors[i].inHandle { edit.style.anchors[i].inHandle = CGPoint(x: h.x + dx, y: h.y + dy) }
            if let h = edit.style.anchors[i].outHandle { edit.style.anchors[i].outHandle = CGPoint(x: h.x + dx, y: h.y + dy) }
        case .inHandle(let i) where edit.style.anchors.indices.contains(i):
            edit.style.anchors[i].inHandle = unit
        case .outHandle(let i) where edit.style.anchors.indices.contains(i):
            edit.style.anchors[i].outHandle = unit
        default: return
        }
        pathEdit = edit
    }

    /// Re-rasterizes the edited path into its layer, as one undo step.
    func commitPathEdit() {
        guard let edit = pathEdit else { return }
        pathEdit = nil
        commitPathEdit(style: edit.style, layerID: edit.layerID, name: "Edit Path")
    }

    func cancelPathEdit() {
        if pathEdit != nil { pathEdit = nil }
    }

    private func commitPathEdit(style: LayerPathStyle, layerID: UUID, name: String) {
        guard let index = document?.layers.firstIndex(where: { $0.id == layerID }),
              let asset = document?.layers[index].asset else { return }
        let size = CGSize(width: asset.image.width, height: asset.image.height)
        guard size.width >= 1, size.height >= 1,
              let image = try? Self.pathImage(style: style, size: size),
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        beginEdit(name)
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].path = LayerPath(style: style, image: image)
        endEdit()
    }

    /// Turns the active path layer's outline into a selection, the way Photoshop's "Make Selection" does.
    func makeSelectionFromPath() {
        guard let layer = activeLayer, let path = layer.livePath else { return }
        let box = CGRect(origin: layer.transform.origin, size: layer.transform.size)
        applySelection(path.style.cgPath(in: box), mode: .replace, name: "Path Selection")
    }

    /// Drops the path, leaving the layer's pixels as they are — an ordinary raster layer from then on.
    func rasterizePath() {
        guard let layer = activeLayer, layer.livePath != nil,
              let index = document?.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        beginEdit("Rasterize Path")
        document?.layers[index].path = nil
        endEdit()
    }
}

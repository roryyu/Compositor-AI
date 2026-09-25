import AppKit

/// What a tool returned to the model. Failures are observations too, so the model can
/// see what went wrong and correct itself.
nonisolated struct ToolObservation: Sendable {
    var success: Bool
    var message: String
}

/// Runs one model tool call against the editor, on the main actor. The agent marks the
/// whole run busy; before each call the dispatcher briefly clears `isProjectBusy` so the
/// session's existing guards and history paths work unchanged, then restores it.
@MainActor
final class AIToolDispatcher {
    /// Generates images from a prompt using the image-generation configuration.
    typealias Generator = @Sendable (String) async throws -> [CGImage]

    let session: EditorSession
    /// Chat transport for `analyze_image`; the agent's own transport.
    let transport: (any ChatTransport)?
    let generator: Generator?

    init(session: EditorSession, transport: (any ChatTransport)? = nil, generator: Generator? = nil) {
        self.session = session
        self.transport = transport
        self.generator = generator
    }

    func dispatch(name: String, arguments: JSONValue) async -> ToolObservation {
        switch name {
        case "get_canvas_state": perform { stateTool() }
        case "analyze_image": await performAsync { try await analyzeImage(arguments) }
        case "add_blank_layer": perform { try addBlankLayer(arguments) }
        case "generate_image": await performAsync { try await generateImage(arguments) }
        case "duplicate_layer": perform { try duplicateLayer(arguments) }
        case "delete_layer": perform { try deleteLayer(arguments) }
        case "set_layer_properties": perform { try setLayerProperties(arguments) }
        case "reorder_layer": perform { try reorderLayer(arguments) }
        case "group_layers": perform { try groupLayers(arguments) }
        case "merge_layers": perform { try mergeLayers(arguments) }
        case "flip": perform { try flip(arguments) }
        case "transform_layer": perform { try transformLayer(arguments) }
        case "undo": perform { try undo() }
        case "fill_layer": await performAsync { try await fillLayer(arguments) }
        case "draw_stroke": perform { try drawStroke(arguments) }
        case "draw_shape": perform { try drawShape(arguments) }
        case "add_text": perform { try addText(arguments) }
        case "draw_gradient": perform { try drawGradient(arguments) }
        case "apply_adjustment": perform { try applyAdjustment(arguments) }
        case "apply_filter": await performAsync { try await applyFilter(arguments) }
        case "set_selection": perform { try setSelection(arguments) }
        case "modify_selection": perform { try modifySelection(arguments) }
        case "select_subject": await performAsync { try await selectSubject() }
        case "crop": await performAsync { try await crop(arguments) }
        case "resize_canvas": perform { try resizeCanvas(arguments) }
        case "resize_image": perform { try resizeImage(arguments) }
        case "trim": await performAsync { try await trim() }
        default:
            ToolObservation(success: false, message: "Unknown tool: \(name)")
        }
    }

    // MARK: Execution wrappers

    private func perform(_ body: () throws -> String) -> ToolObservation {
        session.isProjectBusy = false
        defer { session.isProjectBusy = true }
        do {
            return ToolObservation(success: true, message: try body())
        } catch let error as LocalizedError {
            return ToolObservation(success: false, message: error.errorDescription ?? "The tool failed.")
        } catch {
            return ToolObservation(success: false, message: "\(error)")
        }
    }

    private func performAsync(_ body: () async throws -> String) async -> ToolObservation {
        session.isProjectBusy = false
        defer { session.isProjectBusy = true }
        do {
            return ToolObservation(success: true, message: try await body())
        } catch let error as LocalizedError {
            return ToolObservation(success: false, message: error.errorDescription ?? "The tool failed.")
        } catch {
            return ToolObservation(success: false, message: "\(error)")
        }
    }

    // MARK: Argument helpers

    private func resolve(_ short: String?) -> ImageLayer? {
        guard let short, !short.isEmpty else { return session.activeLayer }
        return session.document?.layers.first { String($0.id.uuidString.prefix(8)) == short }
    }

    private static func point(_ value: JSONValue?) -> CGPoint? {
        guard let array = value?.array, array.count >= 2,
              let x = array[0].double, let y = array[1].double else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func rect(_ value: JSONValue?) -> CGRect? {
        guard let array = value?.array, array.count >= 4,
              let x = array[0].double, let y = array[1].double,
              let w = array[2].double, let h = array[3].double else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Resolves the `color`/`red,green,blue` arguments, falling back to the foreground color.
    private func color(_ args: JSONValue) -> PaletteColor {
        if let text = args["color"]?.string?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            if let hex = Self.parseHexColor(text) { return hex }
            if let named = Self.namedColor(text) { return named }
        }
        if let r = args["red"]?.double, let g = args["green"]?.double, let b = args["blue"]?.double {
            return PaletteColor(red: min(1, max(0, r)), green: min(1, max(0, g)), blue: min(1, max(0, b)))
        }
        return session.foregroundColor
    }

    private static func parseHexColor(_ text: String) -> PaletteColor? {
        var hex = text
        if hex.hasPrefix("#") { hex.removeFirst() }
        func value(_ start: Int, _ length: Int) -> Double? {
            let begin = hex.index(hex.startIndex, offsetBy: start)
            let end = hex.index(begin, offsetBy: length)
            return Int(hex[begin..<end], radix: 16).map { Double($0) / (length == 1 ? 15 : 255) }
        }
        switch hex.count {
        case 3:
            guard let r = value(0, 1), let g = value(1, 1), let b = value(2, 1) else { return nil }
            return PaletteColor(red: r, green: g, blue: b)
        case 6:
            guard let r = value(0, 2), let g = value(2, 2), let b = value(4, 2) else { return nil }
            return PaletteColor(red: r, green: g, blue: b)
        default:
            return nil
        }
    }

    private static let namedColors: [String: PaletteColor] = [
        "white": PaletteColor(red: 1, green: 1, blue: 1),
        "black": PaletteColor(red: 0, green: 0, blue: 0),
        "red": PaletteColor(red: 1, green: 0, blue: 0),
        "green": PaletteColor(red: 0, green: 1, blue: 0),
        "blue": PaletteColor(red: 0, green: 0, blue: 1),
        "yellow": PaletteColor(red: 1, green: 1, blue: 0),
        "cyan": PaletteColor(red: 0, green: 1, blue: 1),
        "magenta": PaletteColor(red: 1, green: 0, blue: 1),
        "orange": PaletteColor(red: 1, green: 0.541, blue: 0),
        "purple": PaletteColor(red: 0.5, green: 0, blue: 0.5),
        "gray": PaletteColor(red: 0.5, green: 0.5, blue: 0.5),
        "grey": PaletteColor(red: 0.5, green: 0.5, blue: 0.5),
        "pink": PaletteColor(red: 1, green: 0.753, blue: 0.796),
        "brown": PaletteColor(red: 0.6, green: 0.4, blue: 0.2),
    ]

    private static func namedColor(_ text: String) -> PaletteColor? { namedColors[text.lowercased()] }

    private func nextAIImageName() -> String {
        let names = Set(session.document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains("AI Image \(number)") { number += 1 }
        return "AI Image \(number)"
    }

    // MARK: Batch 1 — state and layers

    private func stateTool() -> String {
        CanvasStateSnapshot.capture(session).json.encodedString
    }

    private func analyzeImage(_ args: JSONValue) async throws -> String {
        guard let transport else { throw AIError.notConfigured("a vision model") }
        guard let document = session.document else { throw AIError.noDocument }
        let target = args["target"]?.string ?? "canvas"
        let question = args["question"]?.string ?? "Describe this image."
        let image: CGImage
        if target == "active_layer" {
            guard let layer = session.activeLayer, let pixels = layer.asset?.image else {
                throw AIError.imageFailed("the active layer has no pixels.")
            }
            image = pixels
        } else {
            let context = try BrushRaster.context(width: document.width, height: document.height, mask: false)
            session.drawLiveComposite(document, in: context)
            guard let composite = context.makeImage() else { throw AIError.imageFailed("the canvas could not be composited.") }
            image = composite
        }
        return try await VisionService(transport: transport).analyze(image: image, question: question)
    }

    private func addBlankLayer(_ args: JSONValue) throws -> String {
        session.addBlankLayer()
        guard let id = session.activeLayerID else { throw AIError.invalidResponse("the layer could not be added.") }
        if let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            session.renameLayer(id, to: name)
        }
        return "Added layer \(CanvasStateSnapshot.shortID(id))."
    }

    private func generateImage(_ args: JSONValue) async throws -> String {
        guard let generator else { throw AIError.notConfigured("an image generation model") }
        guard let prompt = args["prompt"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
            throw AIError.invalidResponse("a prompt is required.")
        }
        let images = try await generator(prompt)
        guard let generated = images.first else { throw AIError.imageFailed("no image was returned.") }
        let prepared = try ImageCodec.clampedToDocumentLimits(generated)
        let thumbnail = try PixelAdjust.thumbnail(of: prepared)
        let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? nextAIImageName()
        session.insert(ImportedImage(image: prepared, thumbnail: thumbnail, name: name))
        guard let id = session.activeLayerID else { throw AIError.imageFailed("the image could not be inserted.") }
        return "Generated and inserted \"\(name)\" as layer \(CanvasStateSnapshot.shortID(id))."
    }

    private func duplicateLayer(_ args: JSONValue) throws -> String {
        guard let layer = resolve(args["layer_id"]?.string) else { throw AIError.invalidResponse("unknown layer id.") }
        session.activeLayerID = layer.id
        session.duplicateActiveLayer()
        guard let id = session.activeLayerID else { throw AIError.invalidResponse("the layer could not be duplicated.") }
        return "Duplicated layer as \(CanvasStateSnapshot.shortID(id))."
    }

    private func deleteLayer(_ args: JSONValue) throws -> String {
        guard let layer = resolve(args["layer_id"]?.string) else { throw AIError.invalidResponse("unknown layer id.") }
        session.activeLayerID = layer.id
        session.deleteLayerOrMask()
        return "Deleted layer \"\(layer.name)\"."
    }

    private func setLayerProperties(_ args: JSONValue) throws -> String {
        guard let layer = resolve(args["layer_id"]?.string) else { throw AIError.invalidResponse("unknown layer id.") }
        var changed: [String] = []
        session.beginEdit("AI Layer Properties")
        defer { session.endEdit() }
        guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else {
            throw AIError.invalidResponse("unknown layer id.")
        }
        if let opacity = args["opacity"]?.double {
            session.document?.layers[index].opacity = min(1, max(0, opacity)); changed.append("opacity")
        }
        if let visible = args["visible"]?.bool {
            session.document?.layers[index].isVisible = visible; changed.append("visible")
        }
        if let name = args["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            session.document?.layers[index].name = name; changed.append("name")
        }
        if let blend = args["blend_mode"]?.string, let mode = LayerBlendMode(rawValue: blend) {
            session.document?.layers[index].blendMode = mode; changed.append("blend mode")
        }
        return changed.isEmpty ? "No properties changed." : "Updated \(changed.joined(separator: ", "))."
    }

    private func reorderLayer(_ args: JSONValue) throws -> String {
        guard let layer = resolve(args["layer_id"]?.string) else { throw AIError.invalidResponse("unknown layer id.") }
        session.activeLayerID = layer.id
        let up = (args["direction"]?.string ?? "up") == "up"
        session.moveActiveLayer(by: up ? 1 : -1)
        return "Moved layer \(up ? "up" : "down")."
    }

    private func groupLayers(_ args: JSONValue) throws -> String {
        if let shorts = args["layer_ids"]?.array?.compactMap({ $0.string }), !shorts.isEmpty {
            let ids = shorts.compactMap { resolve($0)?.id }
            guard !ids.isEmpty else { throw AIError.invalidResponse("no known layer ids.") }
            session.selectedLayerIDs = Set(ids)
        }
        session.groupSelectedLayers()
        guard let groupID = session.activeLayerID else { throw AIError.invalidResponse("the group could not be created.") }
        return "Created group \(CanvasStateSnapshot.shortID(groupID))."
    }

    private func mergeLayers(_ args: JSONValue) throws -> String {
        if let shorts = args["layer_ids"]?.array?.compactMap({ $0.string }), !shorts.isEmpty {
            let ids = shorts.compactMap { resolve($0)?.id }
            guard !ids.isEmpty else { throw AIError.invalidResponse("no known layer ids.") }
            session.selectedLayerIDs = Set(ids)
        }
        session.mergeLayers()
        return "Merged layers."
    }

    private func flip(_ args: JSONValue) throws -> String {
        let horizontal = (args["axis"]?.string ?? "horizontal") == "horizontal"
        if (args["target"]?.string ?? "canvas") == "canvas" {
            session.flipCanvas(horizontally: horizontal)
        } else {
            session.flipLayers(horizontally: horizontal)
        }
        return "Flipped \(horizontal ? "horizontally" : "vertically")."
    }

    private func transformLayer(_ args: JSONValue) throws -> String {
        guard let layer = resolve(args["layer_id"]?.string) else { throw AIError.invalidResponse("unknown layer id.") }
        guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else {
            throw AIError.invalidResponse("unknown layer id.")
        }
        var transform = session.document?.layers[index].transform ?? layer.transform
        if let dx = args["dx"]?.double { transform.origin.x += dx }
        if let dy = args["dy"]?.double { transform.origin.y += dy }
        if let scale = args["scale"]?.double {
            let center = transform.center
            transform.size = CGSize(width: transform.size.width * scale, height: transform.size.height * scale)
            transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
        }
        if let rotation = args["rotation"]?.double { transform.rotation += rotation }
        guard transform.isValid else { throw AIError.invalidResponse("the resulting transform is not valid.") }
        session.beginEdit("AI Transform Layer")
        session.document?.layers[index].transform = transform
        session.endEdit()
        return "Transformed layer."
    }

    private func undo() throws -> String {
        session.undo()
        return "Undid the last edit."
    }

    // MARK: Batch 2 — drawing and adjustments

    private func fillLayer(_ args: JSONValue) async throws -> String {
        guard session.activeLayer != nil else { throw AIError.imageFailed("select a layer to fill.") }
        let color = color(args)
        session.foregroundColor = color
        await session.fillSelection(with: .foreground)
        let target = args["target"]?.string == "selection" ? "selection" : "layer"
        return "Filled the \(target)."
    }

    private func drawStroke(_ args: JSONValue) throws -> String {
        session.isMaskSelected = false
        guard let layer = session.activeLayer, !layer.isGroup else {
            throw AIError.imageFailed("select a raster layer to paint on.")
        }
        guard let pointValues = args["points"]?.array, !pointValues.isEmpty else {
            throw AIError.invalidResponse("points are required.")
        }
        let paintColor = color(args)
        var settings = BrushSettings()
        settings.red = paintColor.red; settings.green = paintColor.green; settings.blue = paintColor.blue
        if let diameter = args["diameter"]?.double { settings.diameter = CGFloat(diameter) }
        if let hardness = args["hardness"]?.double { settings.hardness = CGFloat(hardness) }
        if let opacity = args["opacity"]?.double { settings.opacity = CGFloat(opacity) }
        settings.smoothing = 0
        let stroke = try session.makeRasterEdit(for: layer, settings: settings)
        let points = pointValues.compactMap { Self.point($0) }
        guard let first = points.first else { throw AIError.invalidResponse("no valid points.") }
        try stroke.append(first)
        for point in points.dropFirst() { try stroke.append(point) }
        try stroke.flush()
        if !stroke.patches.isEmpty { try session.commitPaintSnapshot(stroke) }
        return "Drew a stroke through \(points.count) points."
    }

    private func drawShape(_ args: JSONValue) throws -> String {
        guard let rect = Self.rect(args["rect"]) else { throw AIError.invalidResponse("a valid rect is required.") }
        let kind = ShapeKind(rawValue: args["kind"]?.string ?? "Rectangle") ?? .rectangle
        let paintColor = color(args)
        let cornerRadius = args["corner_radius"]?.double.map { CGFloat($0) } ?? 0
        let image = try EditorSession.shapeImage(kind, size: rect.size, color: paintColor, cornerRadius: cornerRadius)
        let style = LayerShapeStyle(kind: kind, red: paintColor.red, green: paintColor.green,
                                    blue: paintColor.blue, cornerRadius: cornerRadius)
        session.addPixelLayer(image, at: rect.origin, name: session.nextShapeName(kind),
                              editName: "AI Shape", dropsSelection: false,
                              shape: LayerShape(style: style, image: image))
        return "Drew \(kind.rawValue)."
    }

    private func addText(_ args: JSONValue) throws -> String {
        guard let point = Self.point(args["point"]) else { throw AIError.invalidResponse("a valid point is required.") }
        var style = LayerTextStyle()
        style.content = args["text"]?.string ?? "Text"
        if let size = args["font_size"]?.double { style.fontSize = CGFloat(size) }
        if let fontName = args["font_name"]?.string { style.fontName = fontName }
        let paintColor = color(args)
        style.red = paintColor.red; style.green = paintColor.green; style.blue = paintColor.blue
        guard style.isValid else { throw AIError.invalidResponse("the text style is not valid.") }
        let image = try EditorSession.textImage(style)
        let font = NSFont(name: style.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
        let origin = CGPoint(x: point.x - LayerTextStyle.padding,
                             y: point.y - (LayerTextStyle.padding + style.lineHeight - abs(font.descender)))
        session.addPixelLayer(image, at: origin, name: EditorSession.layerName(for: style.content),
                              editName: "AI Text", dropsSelection: false,
                              text: LayerText(style: style, image: image))
        return "Added text \"\(style.content)\"."
    }

    private func drawGradient(_ args: JSONValue) throws -> String {
        guard let rect = Self.rect(args["rect"]),
              let from = Self.point(args["from"]),
              let to = Self.point(args["to"]) else {
            throw AIError.invalidResponse("rect, from, and to are required.")
        }
        let kind: GradientShape = (args["kind"]?.string ?? "linear") == "radial" ? .radial : .linear
        let paintColor = color(args)
        let image = try Self.gradientImage(
            size: rect.size, kind: kind,
            from: CGPoint(x: from.x - rect.minX, y: from.y - rect.minY),
            to: CGPoint(x: to.x - rect.minX, y: to.y - rect.minY),
            color: paintColor)
        session.addPixelLayer(image, at: rect.origin, name: "AI Gradient", editName: "AI Gradient", dropsSelection: false)
        return "Drew \(kind.rawValue) gradient."
    }

    /// Rasterizes a color-to-transparent gradient into its own bitmap.
    private static func gradientImage(size: CGSize, kind: GradientShape, from: CGPoint, to: CGPoint,
                                      color: PaletteColor) throws -> CGImage {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.saveGState()
        // The shared context is y-flipped; draw in top-left coordinates.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let startColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        let colors = [startColor, startColor.copy(alpha: 0)!] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
            throw AIError.imageFailed("the gradient could not be built.")
        }
        let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        if kind == .linear {
            context.drawLinearGradient(gradient, start: from, end: to, options: options)
        } else {
            let radius = hypot(to.x - from.x, to.y - from.y)
            context.drawRadialGradient(gradient, startCenter: from, startRadius: 0,
                                       endCenter: from, endRadius: radius, options: options)
        }
        context.restoreGState()
        guard let image = context.makeImage() else { throw AIError.imageFailed("the gradient could not be rendered.") }
        return image
    }

    private func applyAdjustment(_ args: JSONValue) throws -> String {
        guard let raw = args["kind"]?.string, let kind = AdjustmentKind(rawValue: raw) else {
            throw AIError.invalidResponse("unknown adjustment kind.")
        }
        session.addAdjustment(kind)
        guard let id = session.activeLayerID else { throw AIError.invalidResponse("the adjustment could not be added.") }
        return "Added \(kind.rawValue) adjustment layer \(CanvasStateSnapshot.shortID(id))."
    }

    private func applyFilter(_ args: JSONValue) async throws -> String {
        guard let raw = args["kind"]?.string, let kind = FilterKind(rawValue: raw) else {
            throw AIError.invalidResponse("unknown filter kind.")
        }
        guard let layer = session.activeLayer, let asset = layer.asset else {
            throw AIError.imageFailed("select a raster layer first.")
        }
        var settings = FilterSettings()
        switch kind {
        case .gaussianBlur:
            if let radius = args["radius"]?.double { settings.radius = radius }
        case .motionBlur:
            if let angle = args["angle"]?.double { settings.angle = angle }
            if let distance = args["distance"]?.double { settings.distance = distance }
        case .addNoise:
            if let amount = args["amount"]?.double { settings.amount = amount }
        case .vignette:
            if let amount = args["amount"]?.double { settings.vignetteAmount = amount }
        case .bloomGlow:
            if let amount = args["amount"]?.double { settings.bloomAmount = amount }
        case .tonalContrast:
            if let amount = args["amount"]?.double { settings.tonalAmount = amount }
        default: break
        }
        let job = FilterJob(kind: kind, image: asset.image, settings: settings, scale: 1,
                            selection: nil, mapping: .identity)
        let result = try await Task.detached(priority: .userInitiated) {
            try PixelFilter.run(job)
        }.value
        let thumbnail = try PixelAdjust.thumbnail(of: result)
        session.beginEdit("AI Filter: \(kind.rawValue)")
        guard let index = session.document?.layers.firstIndex(where: { $0.id == layer.id }) else {
            session.endEdit()
            throw AIError.invalidResponse("the layer changed before the filter applied.")
        }
        session.document?.layers[index].asset = ImportedImage(image: result, thumbnail: thumbnail, name: layer.name)
        session.endEdit()
        return "Applied \(kind.rawValue)."
    }

    // MARK: Batch 3 — selection, canvas, links

    private func setSelection(_ args: JSONValue) throws -> String {
        switch args["shape"]?.string ?? "all" {
        case "all":
            session.selectAll()
        case "rect", "ellipse":
            guard let rect = Self.rect(args["rect"]) else { throw AIError.invalidResponse("a rect is required.") }
            let shape = args["shape"]?.string
            let path: CGPath = shape == "ellipse" ? CGPath(ellipseIn: rect, transform: nil) : CGPath(rect: rect, transform: nil)
            var selection = DocumentSelection(path: path)
            if let feather = args["feather"]?.double { selection.feather = CGFloat(feather) }
            session.setSelection(selection, name: "AI Selection")
        default:
            throw AIError.invalidResponse("unknown selection shape.")
        }
        return "Selection set."
    }

    private func modifySelection(_ args: JSONValue) throws -> String {
        switch args["action"]?.string {
        case "invert":
            session.invertSelection()
            return "Selection inverted."
        case "deselect":
            session.deselect()
            return "Selection cleared."
        default:
            throw AIError.invalidResponse("unknown selection action.")
        }
    }

    private func selectSubject() async throws -> String {
        await session.selectSubject()
        return "Subject selected."
    }

    private func crop(_ args: JSONValue) async throws -> String {
        guard let rect = Self.rect(args["rect"]) else { throw AIError.invalidResponse("a valid crop rect is required.") }
        session.cropRect = rect
        await session.commitCrop()
        return "Cropped the canvas."
    }

    private func resizeCanvas(_ args: JSONValue) throws -> String {
        guard let document = session.document,
              let width = args["width"]?.double.map(Int.init),
              let height = args["height"]?.double.map(Int.init),
              (1...DocumentLimits.maxSide).contains(width),
              (1...DocumentLimits.maxSide).contains(height) else {
            throw AIError.invalidResponse("valid width and height are required.")
        }
        session.beginEdit("AI Canvas Size")
        var newDocument = CanvasDocument(id: document.id, width: width, height: height,
                                         layers: document.layers, resolution: document.resolution,
                                         guides: document.guides)
        newDocument.selection = document.selection
        session.document = newDocument
        session.endEdit()
        return "Canvas resized to \(width)x\(height)."
    }

    private func resizeImage(_ args: JSONValue) throws -> String {
        guard let document = session.document,
              let width = args["width"]?.double,
              let height = args["height"]?.double,
              width >= 1, height >= 1,
              width <= Double(DocumentLimits.maxSide), height <= Double(DocumentLimits.maxSide) else {
            throw AIError.invalidResponse("valid width and height are required.")
        }
        let factorX = width / Double(document.width)
        let factorY = height / Double(document.height)
        let scaledLayers = document.layers.map { layer -> ImageLayer in
            var copy = layer
            var transform = layer.transform
            transform.origin.x *= factorX
            transform.origin.y *= factorY
            transform.size.width *= factorX
            transform.size.height *= factorY
            copy.transform = transform
            return copy
        }
        session.beginEdit("AI Image Size")
        var newDocument = CanvasDocument(id: document.id, width: Int(width), height: Int(height),
                                         layers: scaledLayers, resolution: document.resolution,
                                         guides: document.guides)
        newDocument.selection = document.selection
        session.document = newDocument
        session.endEdit()
        return "Image resized to \(Int(width))x\(Int(height))."
    }

    private func trim() async throws -> String {
        let changed = try await session.trim(options: TrimOptions())
        guard changed else { return "Nothing to trim." }
        return "Trimmed the borders."
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

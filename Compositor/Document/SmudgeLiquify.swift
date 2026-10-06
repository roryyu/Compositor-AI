import AppKit

/// The Brush tool's modes: Paint lays down color, Erase clears it, and the tone modes re-tone what is there.
nonisolated enum BrushToolMode: String, CaseIterable, Sendable {
    case paint = "Paint"
    case erase = "Erase"
    case dodge = "Dodge"
    case burn = "Burn"
    case sponge = "Sponge"
    /// The tone modes rework what is on the layer instead of laying color down.
    var isTone: Bool { self == .dodge || self == .burn || self == .sponge }
}

/// Which tones Dodge / Burn / Sponge reach, as in Photoshop.
nonisolated enum ToneRange: String, CaseIterable, Sendable {
    case shadows = "Shadows"
    case midtones = "Midtones"
    case highlights = "Highlights"
}

/// The Blur tool's modes. Smudge and Liquify push the active layer's pixels around under the brush;
/// Mix paints and blends like a Mixer Brush, carrying color along the stroke.
nonisolated enum BlurToolMode: String, CaseIterable, Sendable {
    case liquify = "Liquify"
    case blur = "Blur"
    case smudge = "Smudge"
    case mix = "Mix"
}

/// A Smudge or Liquify stroke in progress. It works on the active layer as the canvas shows it, at document size,
/// changing it dab by dab; the canvas shows that working copy in place of the layer. When the stroke ends, the result
/// is painted into the layer's own pixels along the stroke's path (see `EditorSession.finishWarp`).
final class WarpStroke {
    let layer: ImageLayer
    let mode: BlurToolMode
    let diameter: CGFloat
    let hardness: CGFloat
    let strength: CGFloat
    let width: Int
    let height: Int
    let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    /// Every dab's center, for painting the result into the layer.
    private(set) var points: [CGPoint] = []
    private(set) var image: CGImage?
    private var last: CGPoint?
    /// Smudge: the color the brush carries, a (2r+1)² RGBA square.
    private var carried: [Float] = []
    private var scratch: [Float] = []
    /// Mix: the loaded brush color (0–1), and the Wet / Mix percentages that steer the blend.
    private let brushColor: (r: Float, g: Float, b: Float)?
    private let wet: Float
    private let mixRatio: Float

    init(layer: ImageLayer, image: CGImage, transform: LayerTransform, canvas: CGSize, mode: BlurToolMode, settings: BrushSettings,
         brushColor: (r: Float, g: Float, b: Float)? = nil, wet: Float = 0, mixRatio: Float = 0) throws {
        self.layer = layer
        self.mode = mode
        self.brushColor = brushColor
        self.wet = wet
        self.mixRatio = mixRatio
        diameter = max(2, settings.diameter)
        hardness = min(0.98, max(0, settings.hardness))
        strength = min(1, max(0.01, settings.opacity))
        width = Int(canvas.width); height = Int(canvas.height)
        context = try BrushRaster.context(width: width, height: height, mask: false)
        LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        guard let data = context.data else { throw ExportError.render }
        // Top-left rows: a document point's row is its y.
        pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        self.image = context.makeImage()
    }

    private var radius: Int { Int((diameter / 2).rounded(.up)) }
    /// How much a dab moves pixels at a distance `u` (0 center, 1 rim) from its center.
    private func weight(_ u: Float) -> Float {
        guard u < 1 else { return 0 }
        let h = Float(hardness)
        guard u > h else { return 1 }
        let t = (1 - u) / (1 - h)
        return t * t * (3 - 2 * t)
    }

    /// Continues the stroke to `point`, dabbing along the way, then refreshes `image`.
    func append(_ point: CGPoint) {
        guard let from = last else {
            last = point
            if mode == .smudge { pickUp(at: point) } else if mode == .mix { loadBrush() }
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        let spacing = max(1, diameter * (mode == .smudge || mode == .mix ? 0.08 : 0.025))
        guard distance >= spacing else { return }
        let steps = Int((distance / spacing).rounded(.up))
        var previous = from
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            if mode == .smudge { smudge(at: next) } else if mode == .mix { mixDab(at: next) } else { push(from: previous, to: next) }
            points.append(next)
            previous = next
        }
        last = point
        image = context.makeImage()
    }

    private func pickUp(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        carried = [Float](repeating: 0, count: side * side * 4)
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 { carried[c + k] = Float(pixels[p + k]) }
            }
        }
    }

    private func smudge(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let keep = Float(strength), invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 {
                    let under = Float(pixels[p + k])
                    let painted = under + (carried[c + k] - under) * w
                    pixels[p + k] = UInt8(max(0, min(255, painted.rounded())))
                    // The brush picks up some of what it just left, more the weaker the smudge.
                    carried[c + k] = painted + (carried[c + k] - painted) * keep
                }
            }
        }
    }

    /// Mix: fill the carried square with the loaded brush color (opaque), replacing Smudge's pick-up.
    private func loadBrush() {
        let r = radius, side = 2 * r + 1
        carried = [Float](repeating: 0, count: side * side * 4)
        guard let color = brushColor else { return }
        for i in 0 ..< side * side {
            carried[i * 4] = color.r * 255
            carried[i * 4 + 1] = color.g * 255
            carried[i * 4 + 2] = color.b * 255
            carried[i * 4 + 3] = 255
        }
    }

    /// Mix: lay the carried color blended with what is under the brush, then pick up some of that.
    /// `mixRatio` leans the target from the brush color (0) to the canvas color (1); `wet` is how much
    /// the brush absorbs of the canvas as it travels; `flow` (strength) is how strongly each dab lands.
    private func mixDab(at center: CGPoint) {
        let r = radius, side = 2 * r + 1
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let invR = 1 / Float(diameter / 2)
        let flow = Float(strength)
        let m = min(1, max(0, mixRatio / 100))
        let wetAmt = min(1, max(0, wet / 100))
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let p = (y * width + x) * 4, c = ((dy + r) * side + dx + r) * 4
                for k in 0..<4 {
                    let under = Float(pixels[p + k])
                    let carriedC = carried[c + k]
                    let target = carriedC * (1 - m) + under * m
                    let painted = under + (target - under) * flow * w
                    pixels[p + k] = UInt8(max(0, min(255, painted.rounded())))
                    // The wetter the brush, the more it absorbs of the canvas color it just touched.
                    carried[c + k] = carriedC + (under - carriedC) * (wetAmt * w)
                }
            }
        }
    }

    /// Forward warp: pixels under the brush move with it, most at its center, fading to none at its rim.
    private func push(from a: CGPoint, to b: CGPoint) {
        let r = radius
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        // A copy of the area as it was before this dab, which the dab samples from.
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        if scratch.count < cw * ch * 4 { scratch = [Float](repeating: 0, count: cw * ch * 4) }
        for y in 0..<ch {
            for x in 0..<cw {
                let p = ((y + y0) * width + x + x0) * 4, s = (y * cw + x) * 4
                for k in 0..<4 { scratch[s + k] = Float(pixels[p + k]) }
            }
        }
        let invR = 1 / Float(diameter / 2)
        for dy in -r...r {
            let y = cy + dy
            guard y >= y0, y <= y1 else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= x0, x <= x1 else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                // Bilinear sample of the old pixels, from behind the brush's travel.
                let sx = min(Float(cw - 1), max(0, Float(x - x0) - move.x * w))
                let sy = min(Float(ch - 1), max(0, Float(y - y0) - move.y * w))
                let ix = min(cw - 2, Int(sx)), iy = min(ch - 2, Int(sy))
                guard ix >= 0, iy >= 0 else { continue }
                let fx = sx - Float(ix), fy = sy - Float(iy)
                let p = (y * width + x) * 4
                let s00 = (iy * cw + ix) * 4, s10 = s00 + 4, s01 = s00 + cw * 4, s11 = s01 + 4
                for k in 0..<4 {
                    let top = scratch[s00 + k] + (scratch[s10 + k] - scratch[s00 + k]) * fx
                    let bottom = scratch[s01 + k] + (scratch[s11 + k] - scratch[s01 + k]) * fx
                    pixels[p + k] = UInt8(max(0, min(255, (top + (bottom - top) * fy).rounded())))
                }
            }
        }
    }
}

/// A Dodge, Burn, or Sponge stroke in progress. Structurally the same as `WarpStroke` — it works on the
/// active layer as the canvas shows it, at document size, dab by dab — but instead of moving pixels it
/// re-tones them: Dodge lightens, Burn darkens, and Sponge moves saturation, each weighted by how much
/// of `ToneRange` a pixel's luminance falls in (an approximation of Photoshop's range protection).
final class ToneStroke {
    let layer: ImageLayer
    let mode: BrushToolMode
    let toneRange: ToneRange
    let diameter: CGFloat
    let hardness: CGFloat
    let strength: CGFloat
    let width: Int
    let height: Int
    let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    /// Every dab's center, for painting the result into the layer.
    private(set) var points: [CGPoint] = []
    private(set) var image: CGImage?
    private var last: CGPoint?

    init(layer: ImageLayer, image: CGImage, transform: LayerTransform, canvas: CGSize,
         mode: BrushToolMode, toneRange: ToneRange, settings: BrushSettings) throws {
        self.layer = layer
        self.mode = mode
        self.toneRange = toneRange
        diameter = max(2, settings.diameter)
        hardness = min(0.98, max(0, settings.hardness))
        strength = min(1, max(0.01, settings.opacity))
        width = Int(canvas.width); height = Int(canvas.height)
        context = try BrushRaster.context(width: width, height: height, mask: false)
        LayerRenderer.draw(image, transform: transform, center: transform.center, in: context)
        guard let data = context.data else { throw ExportError.render }
        // Top-left rows: a document point's row is its y.
        pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        self.image = context.makeImage()
    }

    private var radius: Int { Int((diameter / 2).rounded(.up)) }
    /// The brush tip's hardness falloff, as `WarpStroke`'s.
    private func weight(_ u: Float) -> Float {
        guard u < 1 else { return 0 }
        let h = Float(hardness)
        guard u > h else { return 1 }
        let t = (1 - u) / (1 - h)
        return t * t * (3 - 2 * t)
    }
    /// How much of this 0–1 luminance the chosen range protects: shadows reach dark pixels, highlights
    /// bright ones, midtones a bell around the middle.
    private func rangeWeight(_ luma: Float) -> Float {
        func smoothstep(_ t: Float) -> Float {
            let c = min(1, max(0, t))
            return c * c * (3 - 2 * c)
        }
        switch toneRange {
        case .shadows: return smoothstep(0.75 - luma)
        case .highlights: return smoothstep(luma - 0.25)
        case .midtones:
            let t = abs(luma - 0.5) * 2
            return 1 - smoothstep(t - 0.5)
        }
    }

    /// Continues the stroke to `point`, dabbing along the way, then refreshes `image`.
    func append(_ point: CGPoint) {
        guard let from = last else {
            last = point
            return
        }
        let distance = hypot(point.x - from.x, point.y - from.y)
        let spacing = max(1, diameter * 0.08)
        guard distance >= spacing else { return }
        let steps = Int((distance / spacing).rounded(.up))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let next = CGPoint(x: from.x + (point.x - from.x) * t, y: from.y + (point.y - from.y) * t)
            tone(at: next)
            points.append(next)
        }
        last = point
        image = context.makeImage()
    }

    private func tone(at center: CGPoint) {
        let r = radius
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        let invR = 1 / Float(diameter / 2)
        let amount = Float(strength)
        for dy in -r...r {
            let y = cy + dy
            guard y >= 0, y < height else { continue }
            for dx in -r...r {
                let x = cx + dx
                guard x >= 0, x < width else { continue }
                let w = weight(Float(dx * dx + dy * dy).squareRoot() * invR)
                guard w > 0 else { continue }
                let p = (y * width + x) * 4
                let a = Float(pixels[p + 3])
                guard a > 0 else { continue }
                // Un-premultiply, re-tone, premultiply again.
                let red = Float(pixels[p]) / a, green = Float(pixels[p + 1]) / a, blue = Float(pixels[p + 2]) / a
                let luma = 0.299 * red + 0.587 * green + 0.114 * blue
                let f = amount * w * rangeWeight(luma)
                guard f > 0 else { continue }
                var nr = red, ng = green, nb = blue
                switch mode {
                case .dodge:
                    let k = 1 + f
                    nr = red * k; ng = green * k; nb = blue * k
                case .burn:
                    let k = 1 / (1 + f)
                    nr = red * k; ng = green * k; nb = blue * k
                default:
                    // Sponge: Desaturate moves each channel toward the pixel's own luminance, Saturate away.
                    let l = min(1, max(0, luma))
                    let k = 1 - f
                    nr = l + (red - l) * k; ng = l + (green - l) * k; nb = l + (blue - l) * k
                }
                pixels[p] = UInt8(max(0, min(255, (nr * a).rounded())))
                pixels[p + 1] = UInt8(max(0, min(255, (ng * a).rounded())))
                pixels[p + 2] = UInt8(max(0, min(255, (nb * a).rounded())))
            }
        }
    }
}

extension EditorSession {
    func beginWarp(at point: CGPoint) {
        guard canPaint, !isMaskSelected, let layer = activeLayer, let image = layer.asset?.image, let document else {
            if isMaskSelected { brushError = "Smudge, Liquify and Mixer work on a layer's pixels, not its mask." }
            return
        }
        finishOpacityEdit()
        do {
            let fg = foregroundColor
            let stroke = try WarpStroke(layer: layer, image: image, transform: displayedTransform(for: layer),
                                        canvas: document.size, mode: blurMode, settings: brushSettings,
                                        brushColor: blurMode == .mix ? (Float(fg.red), Float(fg.green), Float(fg.blue)) : nil,
                                        wet: Float(mixWet), mixRatio: Float(mixRatio))
            stroke.append(point)
            warpStroke = stroke
            lastBrushPoint = (point, layer.id, false)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    func beginTone(at point: CGPoint) {
        guard canPaint, !isMaskSelected, let layer = activeLayer, let image = layer.asset?.image, let document else {
            if isMaskSelected { brushError = "Dodge, Burn and Sponge work on a layer's pixels, not its mask." }
            return
        }
        finishOpacityEdit()
        do {
            let stroke = try ToneStroke(layer: layer, image: image, transform: displayedTransform(for: layer),
                                        canvas: document.size, mode: brushMode, toneRange: toneRange, settings: brushSettings)
            stroke.append(point)
            toneStroke = stroke
            lastBrushPoint = (point, layer.id, false)
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }

    /// Paints the finished Smudge or Liquify result into the layer's pixels along the stroke, as one undo step.
    func finishWarp() {
        guard let warp = warpStroke else { return }
        warpStroke = nil
        brushRevision += 1
        guard !warp.points.isEmpty, let result = warp.image,
              let current = document?.layers.first(where: { $0.id == warp.layer.id }),
              current.asset?.image === warp.layer.asset?.image, current.transform == warp.layer.transform else { return }
        do {
            var settings = brushSettings
            // A hard tip a little wider than the brush covers everything the stroke moved.
            settings.diameter = warp.diameter + 4
            settings.hardness = 1
            settings.opacity = 1
            let stroke = try makeRasterEdit(for: current, settings: settings)
            stroke.clone = (result, .zero)
            stroke.replacesWithClone = true
            stroke.editName = warp.mode.rawValue
            for point in warp.points { try stroke.append(point) }
            try stroke.flush()
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
    }

    /// Paints the finished Dodge / Burn / Sponge result into the layer's pixels along the stroke, as one undo step.
    func finishTone() {
        guard let tone = toneStroke else { return }
        toneStroke = nil
        brushRevision += 1
        guard !tone.points.isEmpty, let result = tone.image,
              let current = document?.layers.first(where: { $0.id == tone.layer.id }),
              current.asset?.image === tone.layer.asset?.image, current.transform == tone.layer.transform else { return }
        do {
            var settings = brushSettings
            // A hard tip a little wider than the brush covers everything the stroke touched.
            settings.diameter = tone.diameter + 4
            settings.hardness = 1
            settings.opacity = 1
            let stroke = try makeRasterEdit(for: current, settings: settings)
            stroke.clone = (result, .zero)
            stroke.replacesWithClone = true
            stroke.editName = tone.mode.rawValue
            for point in tone.points { try stroke.append(point) }
            try stroke.flush()
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
    }
}

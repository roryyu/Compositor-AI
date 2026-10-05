import AppKit
import CoreImage

/// Color adjustments ported from PhotoCraft's adjustment stack. Each is a small, self-contained
/// settings value with an `apply`, so it works both as a destructive Image-menu filter and as a
/// live adjustment layer (see `FilterKind` / `AdjustmentKind`). The Core Image ones keep alpha and
/// extent; the pixel ones run through `ImageAdjustmentPixels` on premultiplied RGBA.

/// Vibrance: boosts muted colors more than already-saturated ones, so skin tones don't blow out.
/// `saturation` is a plain global shift on top. Both map to Core Image's `CIVibrance` at −1…1.
nonisolated struct VibranceSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -100...100
    var amount: Double = 0
    var saturation: Double = 0
    var isValid: Bool { [amount, saturation].allSatisfy { $0.isFinite && Self.range.contains($0) } }
    var isIdentity: Bool { amount == 0 && saturation == 0 }
    var normalized: Self {
        Self(amount: ImageAdjustmentPixels.clamp(amount, Self.range, 0),
             saturation: ImageAdjustmentPixels.clamp(saturation, Self.range, 0))
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIVibrance", parameters: [
            kCIInputAmountKey: amount / 100,
            kCIInputSaturationKey: saturation / 100,
        ])
        return try PixelAdjust.render(output.cropped(to: input.extent), width: image.width, height: image.height, isMask: false)
    }
}

/// Shadows / Highlights: lifts detail out of the shadows and pulls it back from the highlights,
/// within a local neighborhood of `radius` pixels. Core Image's `CIHighlightShadowAdjust`.
nonisolated struct ShadowsHighlightsSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = 0...100
    static let radiusRange: ClosedRange<Double> = 0...100
    var shadows: Double = 35
    var highlights: Double = 0
    var radius: Double = 0
    var isValid: Bool {
        [shadows, highlights].allSatisfy { $0.isFinite && Self.range.contains($0) }
            && radius.isFinite && Self.radiusRange.contains(radius)
    }
    var isIdentity: Bool { shadows == 0 && highlights == 0 }
    var normalized: Self {
        Self(shadows: ImageAdjustmentPixels.clamp(shadows, Self.range, 35),
             highlights: ImageAdjustmentPixels.clamp(highlights, Self.range, 0),
             radius: ImageAdjustmentPixels.clamp(radius, Self.radiusRange, 0))
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": shadows / 100,
            "inputHighlightAmount": highlights / 100,
            kCIInputRadiusKey: radius,
        ])
        return try PixelAdjust.render(output.cropped(to: input.extent), width: image.width, height: image.height, isMask: false)
    }
}

/// Posterize: reduces each channel to `levels` evenly spaced values, for a flat, screen-printed look.
nonisolated struct PosterizeSettings: Codable, Equatable, Sendable {
    static let levelsRange: ClosedRange<Double> = 2...255
    var levels: Double = 4
    var isValid: Bool { levels.isFinite && Self.levelsRange.contains(levels) }
    var normalized: Self { Self(levels: ImageAdjustmentPixels.clamp(levels, Self.levelsRange, 4)) }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
        return try PixelAdjust.render(output.cropped(to: input.extent), width: image.width, height: image.height, isMask: false)
    }
}

/// Threshold: pixels brighter than `level` become white, the rest black, keeping transparency.
nonisolated struct ThresholdSettings: Codable, Equatable, Sendable {
    static let levelRange: ClosedRange<Double> = 0...255
    var level: Double = 128
    var isValid: Bool { level.isFinite && Self.levelRange.contains(level) }
    var normalized: Self { Self(level: ImageAdjustmentPixels.clamp(level, Self.levelRange, 128)) }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let cutoff = level
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            for y in 0..<height {
                let row = pixels.advanced(by: y * stride)
                for x in 0..<width {
                    let p = row.advanced(by: x * 4)
                    let a = p[3]
                    guard a > 0 else { continue }
                    // The buffer is premultiplied; compare the un-premultiplied luminance against the cutoff.
                    let luma = (0.299 * Double(p[0]) + 0.587 * Double(p[1]) + 0.114 * Double(p[2])) / Double(a) * 255
                    let v: UInt8 = luma >= cutoff ? a : 0
                    p[0] = v; p[1] = v; p[2] = v
                }
            }
        }
    }
}

/// Desaturate: pulls color out toward gray by `amount` percent, leaving the tones alone.
nonisolated struct DesaturateSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = 0...100
    var amount: Double = 100
    var isValid: Bool { amount.isFinite && Self.range.contains(amount) }
    var normalized: Self { Self(amount: ImageAdjustmentPixels.clamp(amount, Self.range, 100)) }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        guard amount > 0 else { return image }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - amount / 100])
        return try PixelAdjust.render(output.cropped(to: input.extent), width: image.width, height: image.height, isMask: false)
    }
}

/// Photo Filter: multiplies the image by a colored gel picked by `hue`, at `density` strength.
/// Preserve Luminosity scales each pixel back to its original brightness so the tint doesn't also darken.
nonisolated struct PhotoFilterSettings: Codable, Equatable, Sendable {
    static let densityRange: ClosedRange<Double> = 0...100
    var hue: Double = 40
    var density: Double = 25
    var preserveLuminosity = true
    var isValid: Bool {
        hue.isFinite && (0...360).contains(hue) && density.isFinite && Self.densityRange.contains(density)
    }
    var normalized: Self {
        var result = self
        result.hue = ImageAdjustmentPixels.clamp(hue, 0...360, 40)
        result.density = ImageAdjustmentPixels.clamp(density, Self.densityRange, 25)
        return result
    }
    /// The gel color as sRGB 0–1, from the hue at full saturation and brightness.
    var tint: (red: Double, green: Double, blue: Double) {
        let hPrime = hue / 60
        let x = 1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1)
        switch hPrime {
        case 0..<1: return (red: 1, green: x, blue: 0)
        case 1..<2: return (red: x, green: 1, blue: 0)
        case 2..<3: return (red: 0, green: 1, blue: x)
        case 3..<4: return (red: 0, green: x, blue: 1)
        case 4..<5: return (red: x, green: 0, blue: 1)
        default: return (red: 1, green: 0, blue: x)
        }
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        guard density > 0 else { return image }
        let gel = tint
        let d = density / 100
        let fr = 1 + d * (gel.red - 1), fg = 1 + d * (gel.green - 1), fb = 1 + d * (gel.blue - 1)
        let preserve = preserveLuminosity
        return try ImageAdjustmentPixels.run(image) { pixels, width, height, stride in
            for y in 0..<height {
                let row = pixels.advanced(by: y * stride)
                for x in 0..<width {
                    let p = row.advanced(by: x * 4)
                    let a = p[3]
                    guard a > 0 else { continue }
                    let alpha = Double(a)
                    var r = Double(p[0]) / alpha, g = Double(p[1]) / alpha, b = Double(p[2]) / alpha
                    let before = preserve ? (0.299 * r + 0.587 * g + 0.114 * b) : 0
                    r *= fr; g *= fg; b *= fb
                    if preserve {
                        let after = 0.299 * r + 0.587 * g + 0.114 * b
                        if after > 0.0001 { let k = before / after; r *= k; g *= k; b *= k }
                    }
                    p[0] = UInt8(min(255, max(0, (r * alpha).rounded())))
                    p[1] = UInt8(min(255, max(0, (g * alpha).rounded())))
                    p[2] = UInt8(min(255, max(0, (b * alpha).rounded())))
                }
            }
        }
    }
}

/// Channel Mixer: rebuilds each output channel as a weighted mix of the source channels, in percent.
/// Monochrome sends the Red row to all three outputs for a black-and-white conversion. Core Image's
/// `CIColorMatrix`; the identity mix (100/0/0, 0/100/0, 0/0/100) leaves the image unchanged.
nonisolated struct ChannelMixerSettings: Codable, Equatable, Sendable {
    static let range: ClosedRange<Double> = -200...200
    var redRed: Double = 100, redGreen: Double = 0, redBlue: Double = 0
    var greenRed: Double = 0, greenGreen: Double = 100, greenBlue: Double = 0
    var blueRed: Double = 0, blueGreen: Double = 0, blueBlue: Double = 100
    var monochrome = false
    private var rows: [[Double]] {
        [[redRed, redGreen, redBlue], [greenRed, greenGreen, greenBlue], [blueRed, blueGreen, blueBlue]]
    }
    var isValid: Bool { rows.flatMap { $0 }.allSatisfy { $0.isFinite && Self.range.contains($0) } }
    var isIdentity: Bool { !monochrome && rows == [[100, 0, 0], [0, 100, 0], [0, 0, 100]] }
    var normalized: Self {
        var result = self
        result.redRed = ImageAdjustmentPixels.clamp(redRed, Self.range, 100)
        result.redGreen = ImageAdjustmentPixels.clamp(redGreen, Self.range, 0)
        result.redBlue = ImageAdjustmentPixels.clamp(redBlue, Self.range, 0)
        result.greenRed = ImageAdjustmentPixels.clamp(greenRed, Self.range, 0)
        result.greenGreen = ImageAdjustmentPixels.clamp(greenGreen, Self.range, 100)
        result.greenBlue = ImageAdjustmentPixels.clamp(greenBlue, Self.range, 0)
        result.blueRed = ImageAdjustmentPixels.clamp(blueRed, Self.range, 0)
        result.blueGreen = ImageAdjustmentPixels.clamp(blueGreen, Self.range, 0)
        result.blueBlue = ImageAdjustmentPixels.clamp(blueBlue, Self.range, 100)
        return result
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let input = CIImage(cgImage: image)
        let red = [redRed, redGreen, redBlue]
        let green = monochrome ? red : [greenRed, greenGreen, greenBlue]
        let blue = monochrome ? red : [blueRed, blueGreen, blueBlue]
        func vector(_ mix: [Double]) -> CIVector {
            CIVector(x: CGFloat(mix[0] / 100), y: CGFloat(mix[1] / 100), z: CGFloat(mix[2] / 100), w: 0)
        }
        let output = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": vector(red),
            "inputGVector": vector(green),
            "inputBVector": vector(blue),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        return try PixelAdjust.render(output.cropped(to: input.extent), width: image.width, height: image.height, isMask: false)
    }
}

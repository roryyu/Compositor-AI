import AppKit
import CoreImage

/// A parsed `.cube` 3D lookup table (Adobe/Iridas format). Only `LUT_3D_SIZE` tables are supported;
/// 1D LUTs (`LUT_1D_SIZE`) are rejected with an error. The parsed samples are stored as RGBA float32
/// (alpha 1) in the order Core Image's `CIColorCubeWithColorSpace` expects: blue fastest, then green,
/// then red — which matches the .cube file order (red fastest line-major means the first axis varies
/// slowest when read as r,g,b triples; see `data`).
nonisolated struct CubeLUT: Equatable, Sendable {
    enum Error: Swift.Error, Equatable {
        case missingSize
        case unsupportedSize
        case oneDimensional
        case truncatedTable
        case badValue
    }
    static let dimensionRange = 2...65
    /// Samples per axis.
    var dimension: Int
    /// RGBA float32 cube data, `dimension³ * 16` bytes.
    var data: Data

    /// Parses `.cube` text: ignores TITLE/comments/blank lines, records DOMAIN_MIN/MAX for scaling,
    /// reads `LUT_3D_SIZE N` then N³ `r g b` triples.
    static func parse(_ text: String) throws -> CubeLUT {
        var dimension = 0
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)
        var samples: [Float] = []
        var oneDimensional = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            switch parts[0].uppercased() {
            case "TITLE":
                continue
            case "LUT_3D_SIZE":
                guard parts.count > 1, let n = Int(parts[1]), Self.dimensionRange.contains(n) else { throw Error.unsupportedSize }
                dimension = n
                samples.reserveCapacity(n * n * n * 3)
            case "LUT_1D_SIZE":
                oneDimensional = true
            case "DOMAIN_MIN":
                guard parts.count > 3, let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) else { throw Error.badValue }
                domainMin = SIMD3(r, g, b)
            case "DOMAIN_MAX":
                guard parts.count > 3, let r = Float(parts[1]), let g = Float(parts[2]), let b = Float(parts[3]) else { throw Error.badValue }
                domainMax = SIMD3(r, g, b)
            default:
                guard !oneDimensional else { throw Error.oneDimensional }
                guard parts.count >= 3, let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { throw Error.badValue }
                samples.append(r); samples.append(g); samples.append(b)
            }
        }
        guard !oneDimensional else { throw Error.oneDimensional }
        guard dimension > 0 else { throw Error.missingSize }
        guard samples.count == dimension * dimension * dimension * 3 else { throw Error.truncatedTable }
        // Scale samples from the declared domain into 0–1, then repack as RGBA float32 in the
        // Core Image cube order (first axis varies slowest is exactly the file order).
        let span = domainMax - domainMin
        guard span.x > 0, span.y > 0, span.z > 0 else { throw Error.badValue }
        var packed = Data(count: samples.count / 3 * 16)
        try packed.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let out = raw.bindMemory(to: Float.self)
            for (index, sample) in samples.enumerated() {
                let channel = index % 3
                let value = (sample - [domainMin.x, domainMin.y, domainMin.z][channel]) / [span.x, span.y, span.z][channel]
                out[index / 3 * 4 + channel] = min(1, max(0, value))
                if channel == 2 { out[index / 3 * 4 + 3] = 1 }
            }
        }
        return CubeLUT(dimension: dimension, data: packed)
    }

    /// Reads and parses a `.cube` file right away; the data is embedded in the document rather than
    /// referenced by URL, so a reopened project keeps its LUT (as Photoshop's PSD does).
    static func load(url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }
}

/// Color Lookup: remaps every color through a `.cube` 3D LUT, at `intensity` percent. Core Image's
/// `CIColorCubeWithColorSpace` (sRGB in and out) mixed back with the source at partial intensity.
nonisolated struct ColorLookupSettings: Codable, Equatable, Sendable {
    static let intensityRange: ClosedRange<Double> = 0...100
    /// Packed RGBA float32 cube samples; nil until a LUT is chosen, in which case `apply` is a no-op.
    var cube: Data?
    var dimension = 0
    var intensity: Double = 100
    /// Display name of the loaded file.
    var lutName = ""
    var isValid: Bool {
        intensity.isFinite && Self.intensityRange.contains(intensity)
            && (cube == nil || (CubeLUT.dimensionRange.contains(dimension) && cube?.count == dimension * dimension * dimension * 16))
    }
    var isIdentity: Bool { cube == nil || intensity == 0 }
    var normalized: Self {
        var result = self
        result.intensity = ImageAdjustmentPixels.clamp(intensity, Self.intensityRange, 100)
        if let cube, !(CubeLUT.dimensionRange.contains(dimension) && cube.count == dimension * dimension * dimension * 16) {
            result.cube = nil; result.dimension = 0; result.lutName = ""
        }
        return result
    }
    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        guard let cube, intensity > 0 else { return image }
        let lut = CubeLUT(dimension: dimension, data: cube)
        let input = CIImage(cgImage: image)
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw ProjectError.invalid }
        let looked = input.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": lut.dimension,
            "inputCubeData": lut.data,
            "inputColorSpace": srgb,
        ])
        let output: CIImage
        if intensity >= 100 {
            output = looked.cropped(to: input.extent)
        } else {
            output = looked.cropped(to: input.extent)
                .applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: input,
                    kCIInputTimeKey: 1 - intensity / 100,
                ])
        }
        return try PixelAdjust.render(output, width: image.width, height: image.height, isMask: false)
    }
}

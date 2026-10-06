import AppKit
import Testing
@testable import Compositor

@MainActor struct CubeLUTTests {
    /// A 2³ identity table: each sample maps to itself.
    static let identityCube = """
    # identity
    TITLE "Identity"
    LUT_3D_SIZE 2
    DOMAIN_MIN 0.0 0.0 0.0
    DOMAIN_MAX 1.0 1.0 1.0
    0.0 0.0 0.0
    1.0 0.0 0.0
    0.0 1.0 0.0
    1.0 1.0 0.0
    0.0 0.0 1.0
    1.0 0.0 1.0
    0.0 1.0 1.0
    1.0 1.0 1.0
    """

    func image(_ color: PaletteColor) throws -> CGImage {
        let bytes = (0..<4).flatMap { _ in
            [UInt8((color.red * 255).rounded()), UInt8((color.green * 255).rounded()), UInt8((color.blue * 255).rounded()), 255]
        }
        return try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: ctx)
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    @Test func parsesAValidCube() throws {
        let lut = try CubeLUT.parse(Self.identityCube)
        #expect(lut.dimension == 2)
        #expect(lut.data.count == 2 * 2 * 2 * 16)
    }

    @Test func rejectsBadTables() throws {
        // Missing size.
        #expect(throws: CubeLUT.Error.missingSize) { try CubeLUT.parse("0.0 0.0 0.0\n1.0 1.0 1.0") }
        // Declared 2³ but only two samples.
        #expect(throws: CubeLUT.Error.truncatedTable) { try CubeLUT.parse("LUT_3D_SIZE 2\n0.0 0.0 0.0\n1.0 1.0 1.0") }
        // A 1D table is out of scope.
        #expect(throws: CubeLUT.Error.oneDimensional) { try CubeLUT.parse("LUT_1D_SIZE 4\n0.0 0.0 0.0\n1.0 1.0 1.0") }
        // Out of the supported size range.
        #expect(throws: CubeLUT.Error.unsupportedSize) { try CubeLUT.parse("LUT_3D_SIZE 66") }
    }

    @Test func identityLUTLeavesPixelsAlone() throws {
        let lut = try CubeLUT.parse(Self.identityCube)
        var settings = ColorLookupSettings()
        settings.cube = lut.data; settings.dimension = lut.dimension
        let source = try image(PaletteColor(red: 0.5, green: 0.25, blue: 0.75))
        let result = try settings.apply(source)
        let before = try pixels(source), after = try pixels(result)
        #expect(after.count == before.count)
        #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }

    @Test func zeroIntensityAndNoCubePassThrough() throws {
        let source = try image(PaletteColor(red: 1, green: 0, blue: 0))
        // No cube chosen: nothing to look up.
        #expect(try ColorLookupSettings().apply(source) === source)
        var settings = ColorLookupSettings()
        let lut = try CubeLUT.parse(Self.identityCube)
        settings.cube = lut.data; settings.dimension = lut.dimension; settings.intensity = 0
        #expect(try settings.apply(source) === source)
    }
}

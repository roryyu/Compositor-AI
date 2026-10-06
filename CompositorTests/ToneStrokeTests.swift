import AppKit
import Testing
@testable import Compositor

@MainActor struct ToneStrokeTests {
    /// A flat 8×8 image of one color, as a layer at the origin.
    func layer(_ red: UInt8, _ green: UInt8, _ blue: UInt8) throws -> (ImageLayer, CGImage) {
        let bytes: [UInt8] = (0..<64).flatMap { _ in [red, green, blue, 255] }
        let image = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let asset = ImportedImage(image: image, thumbnail: image, name: "Fixture")
        return (ImageLayer(asset: asset, origin: .zero), image)
    }

    /// One dab at the center: far enough from the edges that the whole tip lands inside the canvas.
    func dab(mode: BrushToolMode, range: ToneRange, red: UInt8 = 128, green: UInt8 = 128, blue: UInt8 = 128,
             opacity: CGFloat = 0.5) throws -> [UInt8] {
        let (layer, image) = try self.layer(red, green, blue)
        var settings = BrushSettings()
        settings.diameter = 4
        settings.hardness = 1
        settings.opacity = opacity
        let stroke = try ToneStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 8, height: 8),
                                    mode: mode, toneRange: range, settings: settings)
        stroke.append(CGPoint(x: 4, y: 4))
        stroke.append(CGPoint(x: 4, y: 6))   // past the spacing, so a dab actually lands
        let result = try #require(stroke.image)
        let ctx = try BrushRaster.context(width: 8, height: 8, mask: false)
        BrushRaster.draw(result, in: CGRect(x: 0, y: 0, width: 8, height: 8), mask: false, context: ctx)
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 8 * 8 * 4))
    }

    /// The center pixel's RGB.
    func centerPixel(_ pixels: [UInt8]) -> (Int, Int, Int) {
        let p = (4 * 8 + 4) * 4
        return (Int(pixels[p]), Int(pixels[p + 1]), Int(pixels[p + 2]))
    }

    @Test func dodgeLightensMidGray() throws {
        let pixel = centerPixel(try dab(mode: .dodge, range: .midtones))
        #expect(pixel.0 > 128 && pixel.1 > 128 && pixel.2 > 128)
    }

    @Test func burnDarkensMidGray() throws {
        let pixel = centerPixel(try dab(mode: .burn, range: .midtones))
        #expect(pixel.0 < 128 && pixel.1 < 128 && pixel.2 < 128)
    }

    @Test func spongePullsTowardItsLuminance() throws {
        let pixel = centerPixel(try dab(mode: .sponge, range: .midtones, red: 200, green: 80, blue: 80))
        // The red/green gap started at 120; desaturating narrows it without touching the extremes' order.
        #expect(pixel.0 - pixel.1 < 120)
        #expect(pixel.0 < 200 && pixel.1 > 80)
    }

    @Test func rangeProtectsTheOtherTones() throws {
        // A near-white pixel is outside the Shadows range, so Dodge leaves it alone.
        let pixel = centerPixel(try dab(mode: .dodge, range: .shadows, red: 250, green: 250, blue: 250))
        #expect(pixel.0 == 250 && pixel.1 == 250 && pixel.2 == 250)
        // The same pixel in the Highlights range does lighten… until it clips.
        let lit = centerPixel(try dab(mode: .dodge, range: .highlights, red: 200, green: 200, blue: 200))
        #expect(lit.0 > 200)
    }
}

import AppKit
import Testing
@testable import Compositor

@MainActor struct MixerStrokeTests {
    /// A flat 8×8 image of one color (alpha 0 when transparent), as a layer at the origin.
    func layer(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255) throws -> (ImageLayer, CGImage) {
        let bytes = (0..<64).flatMap { _ in [red, green, blue, alpha] }
        let image = try #require(CGImage(width: 8, height: 8, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let asset = ImportedImage(image: image, thumbnail: image, name: "Fixture")
        return (ImageLayer(asset: asset, origin: .zero), image)
    }

    /// One horizontal Mix stroke across the middle, loading a red brush, then the center pixel's RGBA.
    func stroke(red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0, alpha: UInt8 = 255,
                wet: Float, mix: Float, brush: (Float, Float, Float) = (1, 0, 0)) throws -> [UInt8] {
        let (layer, image) = try self.layer(red, green, blue, alpha)
        var settings = BrushSettings()
        settings.diameter = 6
        settings.hardness = 1
        settings.opacity = 1
        let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 8, height: 8),
                                    mode: .mix, settings: settings, brushColor: brush, wet: wet, mixRatio: mix)
        stroke.append(CGPoint(x: 1, y: 4))   // loads the brush, no dab yet
        stroke.append(CGPoint(x: 7, y: 4))   // dabs along the way, one landing dead center
        let result = try #require(stroke.image)
        let ctx = try BrushRaster.context(width: 8, height: 8, mask: false)
        BrushRaster.draw(result, in: CGRect(x: 0, y: 0, width: 8, height: 8), mask: false, context: ctx)
        let pixels = Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: 8 * 8 * 4))
        let p = (4 * 8 + 4) * 4
        return [pixels[p], pixels[p + 1], pixels[p + 2], pixels[p + 3]]
    }

    @Test func fullMixLeavesTheCanvasColor() throws {
        // Mix 100 aims entirely at the color under the brush, so a green canvas stays green.
        let pixel = try stroke(red: 40, green: 200, blue: 40, wet: 100, mix: 100)
        #expect(pixel == [40, 200, 40, 255])
    }

    @Test func dryBrushLaysPureLoadedColor() throws {
        // Wet 0 / Mix 0 never picks the canvas up, so the loaded red covers it.
        let pixel = try stroke(red: 40, green: 200, blue: 40, wet: 0, mix: 0)
        #expect(pixel == [255, 0, 0, 255])
    }

    @Test func startsPaintingOnTransparentPixels() throws {
        // A dry brush on a transparent canvas lays its color down, alpha and all.
        let pixel = try stroke(alpha: 0, wet: 0, mix: 0)
        #expect(pixel == [255, 0, 0, 255])
    }
}

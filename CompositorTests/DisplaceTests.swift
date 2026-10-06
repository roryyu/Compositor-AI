import AppKit
import Testing
@testable import Compositor

@MainActor struct DisplaceTests {
    /// A `width`×`height` image: left half black, right half white unless `gradient`, which ramps red 0→1 left to right.
    func image(width: Int, height: Int, gradient: Bool) throws -> CGImage {
        var bytes = [UInt8]()
        for _ in 0..<height {
            for x in 0..<width {
                if gradient {
                    let v = UInt8((Double(x) / Double(max(1, width - 1)) * 255).rounded())
                    bytes += [v, 0, 0, 255]
                } else {
                    let v: UInt8 = x < width / 2 ? 0 : 255
                    bytes += [v, v, v, 255]
                }
            }
        }
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: ctx)
        return Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    func displaced(_ source: CGImage, map: CGImage?, scale: Double) throws -> CGImage {
        var settings = FilterSettings()
        settings.displaceScale = scale
        var job = FilterJob(kind: .displace, image: source, settings: settings, scale: 1, selection: nil, mapping: .identity)
        job.displacement = map
        return try PixelFilter.run(job)
    }

    @Test func noMapLeavesTheImageAlone() throws {
        let source = try image(width: 8, height: 8, gradient: false)
        #expect(try displaced(source, map: nil, scale: 50) === source)
    }

    @Test func neutralGrayMapLeavesPixelsInPlace() throws {
        let source = try image(width: 16, height: 16, gradient: false)
        // A flat mid-gray map: every channel reads 0.5, which means no displacement anywhere.
        let ctx = try BrushRaster.context(width: 16, height: 16, mask: false)
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let flat = try #require(ctx.makeImage())
        let before = try pixels(source), after = try pixels(try displaced(source, map: flat, scale: 50))
        #expect(zip(before, after).allSatisfy { abs(Int($0) - Int($1)) <= 2 })
    }

    @Test func horizontalRampPushesPixelsSideways() throws {
        let width = 21
        let source = try image(width: width, height: 1, gradient: false)
        // Red ramps 0 → 1 left to right, so the push grows toward the right edge.
        let map = try image(width: width, height: 1, gradient: true)
        let before = try pixels(source)
        let after = try pixels(try displaced(source, map: map, scale: 12))
        // The black/white edge was at x = 10; after the push it is somewhere else on that row.
        let beforeEdge = (0..<width).first { before[$0 * 4] > 128 }
        let afterEdge = (0..<width).first { after[$0 * 4] > 128 }
        #expect(beforeEdge != nil && afterEdge != nil && beforeEdge != afterEdge)
        #expect(abs((afterEdge ?? 0) - (beforeEdge ?? 0)) <= 12)
    }
}

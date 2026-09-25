import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Decoding, scaling, and encoding of bitmaps for the AI features: chat image payloads,
/// and bringing generated images inside the document limits.
nonisolated enum ImageCodec {
    /// Decodes PNG/JPEG/HEIC/WebP bytes via ImageIO.
    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AIError.imageFailed("the data is not a readable image.")
        }
        return image
    }

    /// Draws `image` into a new bitmap of the given size (sRGB, premultiplied).
    static func scaled(_ image: CGImage, to size: CGSize) throws -> CGImage {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        guard width != image.width || height != image.height else { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw AIError.imageFailed("the scaled bitmap could not be allocated.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw AIError.imageFailed("the scaled bitmap could not be rendered.") }
        return result
    }

    /// Scales down proportionally when a side exceeds `maxSide`.
    static func scaledDown(toFitMaxSide image: CGImage, maxSide: CGFloat) throws -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxSide, longest > 0 else { return image }
        let factor = maxSide / longest
        return try scaled(image, to: CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
    }

    /// Keeps a generated image inside the document's side and pixel budget.
    static func clampedToDocumentLimits(_ image: CGImage) throws -> CGImage {
        var result = try scaledDown(toFitMaxSide: image, maxSide: CGFloat(DocumentLimits.maxSide))
        if result.width * result.height > DocumentLimits.maxSurfacePixels {
            let factor = sqrt(CGFloat(DocumentLimits.maxSurfacePixels) / CGFloat(result.width * result.height))
            result = try scaled(result, to: CGSize(width: CGFloat(result.width) * factor, height: CGFloat(result.height) * factor))
        }
        return result
    }

    /// JPEG bytes for a chat payload: longest side at most `maxSide` pixels.
    static func chatJPEGData(_ image: CGImage, maxSide: CGFloat = 1568, quality: CGFloat = 0.85) throws -> Data {
        let prepared = try scaledDown(toFitMaxSide: image, maxSide: maxSide)
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AIError.imageFailed("the image could not be encoded.")
        }
        CGImageDestinationAddImage(destination, prepared,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let result = data as Data? else {
            throw AIError.imageFailed("the image could not be encoded.")
        }
        return result
    }

    /// A base64 data URI for the OpenAI-compatible `image_url` part.
    static func dataURI(_ data: Data, mime: String) -> String {
        "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

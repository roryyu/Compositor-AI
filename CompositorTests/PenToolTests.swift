import AppKit
import Testing
@testable import Compositor

@MainActor
struct PenToolTests {
    private func makeSession() -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 80, emptyLayer: true)
        session.selectTool(.pen)
        session.foregroundColor = PaletteColor(red: 1, green: 0, blue: 0)
        return session
    }

    /// Places a closed triangle A(20,10) B(60,10) C(40,50) and finishes it as a filled path layer.
    private func triangle(_ session: EditorSession) {
        session.beginPen(at: CGPoint(x: 20, y: 10))
        session.beginPen(at: CGPoint(x: 60, y: 10))
        session.beginPen(at: CGPoint(x: 40, y: 50))
        session.beginPen(at: CGPoint(x: 20, y: 10))   // near the first anchor: closes and finishes
    }

    /// The flattened document as RGBA bytes, and a reader for one pixel's red and alpha.
    private func pixels(_ session: EditorSession) async throws -> (Int, Int) -> (red: Int, alpha: Int) {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                              count: image.width * image.height * 4))
        let width = image.width
        return { x, y in (Int(bytes[(y * width + x) * 4]), Int(bytes[(y * width + x) * 4 + 3])) }
    }

    /// How many pixels of a raster are opaque.
    private func opaqueCount(_ image: CGImage) throws -> Int {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                        count: image.width * image.height * 4)
        return (0..<(image.width * image.height)).filter { bytes[$0 * 4 + 3] > 128 }.count
    }

    @Test func closedTriangleFillsItsInteriorAndLeavesTheRestClear() async throws {
        let session = makeSession()
        triangle(session)
        #expect(session.activeLayer?.name == "Path 1")
        #expect(session.activeLayer?.livePath?.style.closed == true)
        let pixel = try await pixels(session)
        #expect(pixel(40, 25) == (255, 255), "the centroid is filled with the foreground color")
        #expect(pixel(22, 48).alpha == 0, "a bounding-box corner outside the triangle stays clear")
    }

    @Test func aPathDrawsAgainAtANewSizeSoItsAreaScalesWithIt() throws {
        let style = LayerPathStyle(anchors: [PathAnchor(point: CGPoint(x: 0.5, y: 0)),
                                             PathAnchor(point: CGPoint(x: 1, y: 1)),
                                             PathAnchor(point: CGPoint(x: 0, y: 1))],
                                   closed: true, stroked: false, red: 1, green: 0, blue: 0, lineWidth: 1)
        let small = try EditorSession.pathImage(style: style, size: CGSize(width: 20, height: 20))
        let large = try EditorSession.pathImage(style: style, size: CGSize(width: 40, height: 40))
        let a = try opaqueCount(small), b = try opaqueCount(large)
        #expect(b > a * 3 && b < a * 5, "twice the size is about four times the covered area (\(a) → \(b))")
    }

    @Test func draggingAnAnchorEditsThePathAsOneUndoStep() throws {
        let session = makeSession()
        triangle(session)
        let before = session.activeLayer?.asset?.image
        let count = session.history.undoCount
        #expect(session.beginPathEdit(at: CGPoint(x: 40, y: 50), option: false), "the apex anchor is grabbed")
        session.dragPathEdit(to: CGPoint(x: 40, y: 20))
        session.commitPathEdit()
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.asset?.image !== before, "the path redrew")
        session.undo()
        #expect(session.activeLayer?.asset?.image === before, "one undo restores the original pixels")
    }

    @Test func anOpenStrokeLaysPixelsAlongItsLine() async throws {
        let session = makeSession()
        session.penStroked = true
        session.penLineWidth = 4
        session.beginPen(at: CGPoint(x: 20, y: 40))
        session.beginPen(at: CGPoint(x: 60, y: 40))
        session.finishPen()
        #expect(session.activeLayer?.livePath?.style.stroked == true)
        let pixel = try await pixels(session)
        #expect(pixel(40, 40).alpha > 0, "on the stroked line")
        #expect(pixel(40, 20).alpha == 0, "off the line")
    }

    @Test func makeSelectionFromPathMatchesTheBoundingBox() throws {
        let session = makeSession()
        triangle(session)
        session.makeSelectionFromPath()
        let box = try #require(session.selection?.path.boundingBoxOfPath)
        #expect(abs(box.minX - 20) < 2 && abs(box.minY - 10) < 2)
        #expect(abs(box.width - 40) < 2 && abs(box.height - 40) < 2)
    }
}

import XCTest
@testable import Adawat

@MainActor
final class ImageTests: AdawatTestCase {
    func testConvertsAPhotoAndKeepsItsSize() async throws {
        let photo = try Samples.photo(file("photo.jpg"), width: 640, height: 400)
        for ext in ["png", "heic", "webp", "avif", "tiff", "gif", "bmp"] {
            let output = try await runOne("image.\(ext)", photo)
            XCTAssertEqual(output.lastPathComponent, "photo.\(ext)")
            XCTAssertEqual(try Samples.size(of: output), [640, 400], ext)
        }
    }

    func testConvertsAPngToJpeg() async throws {
        let output = try await runOne("image.jpg", try Samples.photo(file("drawing.png")))
        XCTAssertEqual(ImageFormat.of(output), .jpeg)
        XCTAssertEqual(try Samples.size(of: output), [640, 400])
    }

    func testConvertsSeveralPhotosAtOnce() async throws {
        let photos = try ["a.jpg", "b.jpg", "c.jpg"].map { try Samples.photo(file($0)) }
        let outputs = try await run("image.png", photos)
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["a.png", "b.png", "c.png"])
    }

    func testRotateTurnsAQuarter() async throws {
        let output = try await runOne("image.rotate", try Samples.photo(file("photo.jpg"), width: 640, height: 400))
        XCTAssertEqual(try Samples.size(of: output), [400, 640])
    }

    func testCropWithoutItsWindowCutsASquare() async throws {
        let outputs = try await ImageOps.squareCrop([try Samples.photo(file("photo.jpg"), width: 640, height: 400)], context: OperationContext())
        XCTAssertEqual(try Samples.size(of: try XCTUnwrap(outputs.first)), [400, 400])
    }

    func testPhotosBecomeAPdfWithAPageEach() async throws {
        let photos = try ["a.jpg", "b.png", "c.jpg"].map { try Samples.photo(file($0)) }
        let output = try await run("image.topdf", photos)
        XCTAssertEqual(try Samples.pageCount(try XCTUnwrap(output.first)), 3)
    }

    func testTheOriginalIsNeverChanged() async throws {
        let photo = try Samples.photo(file("photo.jpg"))
        let before = try Data(contentsOf: photo)
        _ = try await run("image.rotate", photo)
        _ = try await run("image.png", photo)
        _ = try await run("image.metadata", photo, try Samples.photo(file("other.jpg")))
        XCTAssertEqual(try Data(contentsOf: photo), before)
    }

    func testATextFileBecomesACodeThatScans() async throws {
        for text in ["https://example.com/adawat?tool=qr", "أدوات: حوّل أي ملف وأنت تسحبه"] {
            let link = try write(text + "\n", to: "link.txt")
            let png = try await runOne("text.qr", link)
            let image = try XCTUnwrap(CIImage(contentsOf: png))
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let codes = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(codes, [text])
            try FileManager.default.removeItem(at: png)
        }
    }
}

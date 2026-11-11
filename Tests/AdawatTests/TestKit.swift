import AppKit
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Adawat

/// A folder of its own for each test, removed afterwards. Results land in it, next to the originals.
@MainActor
class AdawatTestCase: XCTestCase {
    private(set) var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("adawat-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// The names in the folder, sorted, folders with a trailing slash.
    func names() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return items.map { $0.lastPathComponent + ($0.hasDirectoryPath ? "/" : "") }.filter { !$0.hasPrefix(".") }.sorted()
    }

    func write(_ text: String, to name: String) throws -> URL {
        let url = file(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Runs a wheel choice by its id, as a drop on its petal would.
    func run(_ id: String, _ files: URL...) async throws -> [URL] { try await run(id, files) }

    func run(_ id: String, _ files: [URL]) async throws -> [URL] {
        let choices = WheelMode.allCases.flatMap { OperationCatalog.operations(for: $0, files: files) }
        guard let operation = choices.first(where: { $0.id == id }) else {
            throw AdawatError.message("The wheel has no \(id) for \(files.map(\.lastPathComponent).joined(separator: ", "))")
        }
        return try await operation.run(files, OperationContext())
    }

    /// The single file a choice made.
    func runOne(_ id: String, _ files: URL...) async throws -> URL {
        let outputs = try await run(id, files)
        XCTAssertEqual(outputs.count, 1)
        let output = try XCTUnwrap(outputs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "\(id) reported \(output.lastPathComponent), which is not there")
        return output
    }

    /// Media tests need ffmpeg. Without it they are skipped, or fail where ADAWAT_TESTS_NEED_TOOLS=1 says it must be there.
    func needFfmpeg() throws {
        guard ExternalTool.ffmpeg.url == nil else { return }
        if ProcessInfo.processInfo.environment["ADAWAT_TESTS_NEED_TOOLS"] == "1" {
            XCTFail("ffmpeg was not found, and ADAWAT_TESTS_NEED_TOOLS=1 says it must be")
        }
        throw XCTSkip("ffmpeg is not installed")
    }

    func assertNear(_ actual: Double, _ expected: Double, tolerance: Double = 0.35, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, accuracy: tolerance, file: file, line: line)
    }

    /// Asserts that `work` throws, and hands back what it threw.
    func assertThrows(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> Error? {
        do {
            try await work()
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }
}

/// Sample files made on the spot, so the repository carries no binaries.
@MainActor
enum Samples {
    /// A photo: a gradient with a block of colour in one corner, so rotations and crops can be told apart.
    @discardableResult
    static func photo(_ url: URL, width: Int = 640, height: Int = 400) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let colors = [CGColor(red: 0.13, green: 0.33, blue: 0.8, alpha: 1), CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)] as CFArray
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: colors, locations: nil))
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        context.setFillColor(CGColor(red: 0.86, green: 0.08, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 10, y: height - height / 4 - 10, width: width / 4, height: height / 4))
        let image = try XCTUnwrap(context.makeImage())
        let type: UTType = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// Width and height of a picture, as shown.
    static func size(of url: URL) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), "\(url.lastPathComponent) is not a picture")
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        let turned = [5, 6, 7, 8].contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return turned ? [height, width] : [width, height]
    }

    private static func ffmpeg(_ arguments: [String]) async throws {
        try await ProcessRunner.run(try ExternalTool.ffmpeg.require(), ["-y", "-hide_banner", "-nostdin", "-loglevel", "error"] + arguments)
    }

    /// A short video with a tone: 320×240, 15 frames a second.
    @discardableResult
    static func clip(_ url: URL, seconds: Double = 2) async throws -> URL {
        let video = FFmpeg.encoders.contains("libx264") ? ["-c:v", "libx264", "-preset", "ultrafast"] : ["-c:v", "h264_videotoolbox"]
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=duration=\(seconds):size=320x240:rate=15", "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"]
                         + video + ["-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path])
        return url
    }

    /// A tone, in the format of the URL's extension.
    @discardableResult
    static func tone(_ url: URL, seconds: Double = 2, channels: Int = 1) async throws -> URL {
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)", "-ac", "\(channels)", url.path])
        return url
    }

    /// A PDF with one page per photo.
    static func pdf(_ url: URL, pages: Int) throws -> URL {
        let document = PDFDocument()
        for number in 0..<pages {
            let photo = url.deletingLastPathComponent().appendingPathComponent("page-\(UUID().uuidString).png")
            try Samples.photo(photo, width: 300 + number * 20, height: 400)
            defer { try? FileManager.default.removeItem(at: photo) }
            let image = try XCTUnwrap(NSImage(contentsOf: photo))
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: number)
        }
        XCTAssertTrue(document.write(to: url))
        return url
    }

    static func pageCount(_ url: URL) throws -> Int {
        try XCTUnwrap(PDFDocument(url: url), "\(url.lastPathComponent) is not a PDF").pageCount
    }
}

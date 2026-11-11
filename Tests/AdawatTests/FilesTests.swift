import XCTest
@testable import Adawat

/// What kind a file is, and what its results are called.
@MainActor
final class FilesTests: AdawatTestCase {
    func testKindComesFromTheExtension() {
        let kinds: [(String, FileKind)] = [
            ("photo.JPG", .image), ("photo.heic", .image), ("report.pdf", .pdf), ("clip.mkv", .video), ("voice.opus", .audio),
            ("letter.docx", .document), ("table.csv", .spreadsheet), ("deck.pptx", .presentation), ("film.vtt", .subtitle),
            ("box.tar.gz", .archive), ("data.xyz", .other), ("no extension", .other),
        ]
        for (name, kind) in kinds {
            XCTAssertEqual(FileKind(url: file(name)), kind, name)
        }
    }

    func testAFolderIsAFolderWhateverItsName() throws {
        let folder = file("holiday.jpg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(FileKind(url: folder), .folder)
    }

    func testAResultNeverReplacesAFileThatIsThere() throws {
        let first = file("photo.png")
        XCTAssertEqual(Output.unique(first), first)
        try Data().write(to: first)
        XCTAssertEqual(Output.unique(first).lastPathComponent, "photo 2.png")
        try Data().write(to: file("photo 2.png"))
        XCTAssertEqual(Output.unique(first).lastPathComponent, "photo 3.png")
    }

    func testAResultIsNamedAfterItsSourceAndSavedNextToIt() throws {
        let source = file("holiday.jpg")
        try Data().write(to: source)
        XCTAssertEqual(Output.url(for: source, extension: "png").path, file("holiday.png").path)
        XCTAssertEqual(Output.url(for: source, extension: "jpg", suffix: "rotated").path, file("holiday rotated.jpg").path)
    }

    func testThePetalUnderThePointerIsTheOneDrawnThere() {
        for count in [1, 2, 6, 9, 11] {
            for index in 0..<count {
                XCTAssertEqual(WheelGeometry.index(at: WheelGeometry.position(index: index, count: count), count: count), index, "\(index) of \(count)")
            }
            XCTAssertNil(WheelGeometry.index(at: CGPoint(x: WheelGeometry.size / 2, y: WheelGeometry.size / 2), count: count))
        }
    }

    /// A translation whose pattern does not compile is dropped without a word, so check them all.
    func testEveryArabicPatternCompiles() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ar.lproj")
        let strings = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("Localizable.strings")) as? [String: String])
        XCTAssertGreaterThan(strings.count, 400)
        for (english, arabic) in strings {
            XCTAssertFalse(arabic.trimmingCharacters(in: .whitespaces).isEmpty, "\"\(english)\" has no Arabic")
        }
        XCTAssertEqual(strings["Cancel"], "إلغاء")
        let patterns = try XCTUnwrap(NSDictionary(contentsOf: resources.appendingPathComponent("Patterns.strings")) as? [String: String])
        XCTAssertGreaterThan(patterns.count, 50)
        for (pattern, template) in patterns {
            let regex = try NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators])
            for group in 1...9 where template.contains("\\\(group)") {
                XCTAssertLessThanOrEqual(group, regex.numberOfCaptureGroups, "\"\(pattern)\" → \"\(template)\" names a value the English lacks")
            }
        }
    }
}

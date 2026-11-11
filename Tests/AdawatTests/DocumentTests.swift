import XCTest
@testable import Adawat

/// PDF, documents, spreadsheets and subtitles.
@MainActor
final class DocumentTests: AdawatTestCase {
    private func parts(_ outputs: [URL], _ ext: String) throws -> [URL] {
        try outputs.flatMap { output -> [URL] in
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isFolder), isFolder.boolValue else { return [output] }
            return try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil)
        }.filter { $0.pathExtension == ext }
    }

    // MARK: PDF

    func testSplitGivesAFileForEveryPage() async throws {
        let pages = try parts(try await run("pdf.split", try Samples.pdf(file("report.pdf"), pages: 3)), "pdf")
        XCTAssertEqual(pages.count, 3)
        for page in pages { XCTAssertEqual(try Samples.pageCount(page), 1) }
    }

    func testMergeKeepsEveryPage() async throws {
        let output = try await run("pdf.merge", try Samples.pdf(file("first.pdf"), pages: 3), try Samples.pdf(file("second.pdf"), pages: 2))
        XCTAssertEqual(try Samples.pageCount(try XCTUnwrap(output.first)), 5)
    }

    func testPagesBecomePictures() async throws {
        let pdf = try Samples.pdf(file("report.pdf"), pages: 2)
        for ext in ["png", "jpg"] {
            let pictures = try parts(try await run("pdf.\(ext)", pdf), ext)
            XCTAssertEqual(pictures.count, 2, ext)
            for picture in pictures { XCTAssertGreaterThan(try Samples.size(of: picture)[0], 100) }
        }
    }

    func testRemovingMetadataKeepsThePages() async throws {
        let pdf = try Samples.pdf(file("report.pdf"), pages: 2)
        let output = try await runOne("pdf.metadata", pdf)
        XCTAssertNotEqual(output.path, pdf.path)
        XCTAssertEqual(try Samples.pageCount(output), 2)
    }

    func testADamagedPdfIsReportedInWords() async throws {
        let broken = try write("this is not a PDF", to: "broken.pdf")
        let error = await assertThrows { _ = try await self.run("pdf.split", broken) }
        XCTAssertTrue(error?.localizedDescription.contains("broken.pdf") ?? false)
    }

    // MARK: Documents

    private let note = "# Travel notes\n\nHello **world**, this is a note.\n\n- one\n- two\n"

    func testMarkdownBecomesWordAndBack() async throws {
        let word = try await runOne("doc.docx", try write(note, to: "note.md"))
        XCTAssertEqual(word.lastPathComponent, "note.docx")
        let text = try String(contentsOf: try await runOne("doc.txt", word), encoding: .utf8)
        XCTAssertTrue(text.contains("Travel notes"))
        XCTAssertTrue(text.contains("Hello world, this is a note."))
        XCTAssertTrue(text.contains("one"))
    }

    func testMarkdownBecomesAWebPage() async throws {
        let html = try String(contentsOf: try await runOne("doc.html", try write(note, to: "note.md")), encoding: .utf8)
        XCTAssertTrue(html.lowercased().contains("<html"))
        XCTAssertTrue(html.contains("Travel notes"))
        XCTAssertTrue(html.contains("<b>world</b>"))
        XCTAssertFalse(html.contains("**"))
    }

    func testArabicTextSurvivesWord() async throws {
        let word = try await runOne("doc.docx", try write("# عنوان\n\nمرحبا بالعالم.\n", to: "arabic.md"))
        let text = try String(contentsOf: try await runOne("doc.txt", word), encoding: .utf8)
        XCTAssertTrue(text.contains("عنوان"))
        XCTAssertTrue(text.contains("مرحبا بالعالم."))
    }

    // MARK: Spreadsheets

    private let table = "name,age,city\nAli,30,Cairo\nMona,28,\"Giza, west\"\n"
    private let cells = [["name", "age", "city"], ["Ali", "30", "Cairo"], ["Mona", "28", "Giza, west"]]

    func testATableKeepsItsCells() async throws {
        let csv = try write(table, to: "table.csv")
        for ext in ["xlsx", "ods", "tsv"] {
            let output = try await runOne("sheet.\(ext)", csv)
            let read = try await SheetOps.read(output)
            XCTAssertEqual(read, cells, ext)
        }
    }

    func testExcelBecomesCsvAgain() async throws {
        let csv = try write(table, to: "table.csv")
        let excel = try await runOne("sheet.xlsx", csv)
        try FileManager.default.removeItem(at: csv)
        let back = try await runOne("sheet.csv", excel)
        let read = try await SheetOps.read(back)
        XCTAssertEqual(read, cells)
        XCTAssertTrue(try String(contentsOf: back, encoding: .utf8).contains("\"Giza, west\""))
    }

    // MARK: Subtitles

    private let srt = "1\n00:00:01,000 --> 00:00:02,500\nHello there\n\n2\n00:01:03,250 --> 00:01:05,000\nSecond line\nstill the second\n"

    func testSrtBecomesWebVttAndBack() async throws {
        let film = try write(srt, to: "film.srt")
        let vttFile = try await runOne("subtitle.vtt", film)
        let vtt = try String(contentsOf: vttFile, encoding: .utf8)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT"))
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:02.500"))
        XCTAssertTrue(vtt.contains("Second line\nstill the second"))
        try FileManager.default.removeItem(at: film)
        let back = try String(contentsOf: try await runOne("subtitle.srt", vttFile), encoding: .utf8)
        XCTAssertTrue(back.contains("1\n00:00:01,000 --> 00:00:02,500\nHello there"))
        XCTAssertTrue(back.contains("2\n00:01:03,250 --> 00:01:05,000\nSecond line"))
    }

    func testTextDropsTheTimings() async throws {
        let text = try String(contentsOf: try await runOne("subtitle.txt", try write(srt, to: "film.srt")), encoding: .utf8)
        XCTAssertFalse(text.contains("-->"))
        XCTAssertTrue(text.contains("Hello there"))
        XCTAssertTrue(text.contains("still the second"))
    }
}

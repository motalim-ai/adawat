import CryptoKit
import XCTest
@testable import Adawat

@MainActor
final class ArchiveTests: AdawatTestCase {
    /// A folder with a few files and a folder inside.
    private func trip() throws -> URL {
        let folder = file("trip")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("photos"), withIntermediateDirectories: true)
        try "packing list".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "مرحبا".write(to: folder.appendingPathComponent("عربي.txt"), atomically: true, encoding: .utf8)
        try Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 7) }).write(to: folder.appendingPathComponent("photos/one.bin"))
        return folder
    }

    /// What a folder holds, as "relative path = digest" lines.
    private func contents(_ folder: URL) throws -> [String] {
        let root = folder.resolvingSymlinksInPath().path
        let files = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        return try files.compactMap { $0 as? URL }.filter { (try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.map { url in
            let digest = SHA256.hash(data: try Data(contentsOf: url)).prefix(6).map { String(format: "%02x", $0) }.joined()
            return "\(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1).precomposedStringWithCanonicalMapping) = \(digest)"
        }.sorted()
    }

    func testAFolderPacksAndComesBackTheSame() async throws {
        let folder = try trip()
        for (format, name) in [("zip", "trip.zip"), ("tar", "trip.tar"), ("tgz", "trip.tar.gz")] {
            let archive = try await runOne("archive.\(format)", folder)
            XCTAssertEqual(archive.lastPathComponent, name)
            let extracted = try await runOne("archive.extract", archive)
            XCTAssertNotEqual(extracted.path, folder.path)
            XCTAssertEqual(try contents(extracted), try contents(folder), format)
            try FileManager.default.removeItem(at: extracted)
        }
    }

    func testAZipBecomesATarWithTheSameFiles() async throws {
        let folder = try trip()
        let tar = try await runOne("archive.to-tar", try await runOne("archive.zip", folder))
        XCTAssertEqual(tar.pathExtension, "tar")
        let extracted = try await runOne("archive.extract", tar)
        XCTAssertEqual(try contents(extracted), try contents(folder))
    }

    func testASingleFileGzipsAndComesBack() async throws {
        let text = String(repeating: "squeeze me ", count: 500)
        let data = try write(text, to: "data.xyz")
        let gz = try await runOne("archive.gz", data)
        XCTAssertEqual(gz.lastPathComponent, "data.xyz.gz")
        XCTAssertLessThan(try Data(contentsOf: gz).count, text.utf8.count)
    }

    func testAFileThatIsNotAnArchiveIsReportedAndLeavesNothing() async throws {
        let fake = try write("not a zip at all", to: "fake.zip")
        _ = await assertThrows { _ = try await self.run("archive.extract", fake) }
        XCTAssertEqual(names(), ["fake.zip"])
    }
}

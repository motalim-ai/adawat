import XCTest
@testable import Adawat

/// The wheel offers what Tests/wheel-choices.json says, in that order. The Windows and Linux tests read the same file.
@MainActor
final class WheelChoicesTests: AdawatTestCase {
    private struct Spec: Decodable {
        let actions: [Entry]
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let files: [String]
        let convert: [Entry]
        let tools: [Entry]
    }

    /// A choice's id, alone or with the platforms it is for.
    private struct Entry: Decodable {
        let id: String
        var only: [String]?
        var not: [String]?
        var optional: Bool?

        init(from decoder: Decoder) throws {
            if let id = try? decoder.singleValueContainer().decode(String.self) {
                self.id = id
                return
            }
            let values = try decoder.container(keyedBy: Keys.self)
            id = try values.decode(String.self, forKey: .id)
            only = try values.decodeIfPresent([String].self, forKey: .only)
            not = try values.decodeIfPresent([String].self, forKey: .not)
            optional = try values.decodeIfPresent(Bool.self, forKey: .optional)
        }

        private enum Keys: String, CodingKey { case id, only, not, optional }
    }

    func testEveryCase() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("wheel-choices.json")
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(spec.cases.count, 20)
        for (number, item) in spec.cases.enumerated() {
            let home = file("case \(number)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let files = try item.files.map { name -> URL in
                if name.hasSuffix("/") {
                    let url = home.appendingPathComponent(String(name.dropLast()), isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    return url
                }
                let url = home.appendingPathComponent(name)
                try Data().write(to: url)
                return url
            }
            check(item.name, "Convert", item.convert, OperationCatalog.operations(for: .convert, files: files))
            check(item.name, "Tools", item.tools, OperationCatalog.operations(for: .tools, files: files))
            check(item.name, "Actions", spec.actions, OperationCatalog.operations(for: .actions, files: files))
        }
    }

    private func check(_ name: String, _ wheel: String, _ expected: [Entry], _ offered: [AdawatOperation]) {
        let mine = expected.filter { ($0.only?.contains("mac") ?? true) && !($0.not?.contains("mac") ?? false) }
        let optional = Set(mine.filter { $0.optional == true }.map(\.id))
        let required = mine.filter { $0.optional != true }.map(\.id)
        // Choices that depend on what is installed may be there or not; everything else has to match, in petal order.
        let actual = offered.map(\.id).filter { !optional.contains($0) }
        XCTAssertEqual(actual, required, "\(name): the \(wheel) wheel")
        XCTAssertEqual(Set(offered.map(\.id)).count, offered.count, "\(name): the \(wheel) wheel repeats a choice")
    }
}

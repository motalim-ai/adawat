import AppKit

/// Spreadsheets as a grid of text: CSV, TSV, XLSX and ODS read and written directly, PDF as an export.
/// XLS and Numbers files go through Numbers (see IWorkBridge).
@MainActor
enum SheetOps {
    typealias Table = [[String]]

    enum Target: String, CaseIterable {
        case xlsx, ods, csv, tsv, pdf, html
        var title: String { rawValue.uppercased() }
    }

    // MARK: Reading

    static func read(_ url: URL) async throws -> Table {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "csv": return parseDelimited(try SubtitleOps.readText(url), separator: ",")
        case "tsv": return parseDelimited(try SubtitleOps.readText(url), separator: "\t")
        case "xlsx": return try await readXLSX(url)
        case "ods": return try await readODS(url)
        case "xls", "numbers":
            // Numbers reads both; it hands back an XLSX this engine understands.
            let temp = IWorkBridge.scratchURL(near: url, extension: "xlsx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await IWorkBridge.export(url, with: .numbers, as: .excel, to: temp)
            return try await readXLSX(temp)
        default:
            throw AdawatError.message("\(url.lastPathComponent) is not a spreadsheet.")
        }
    }

    /// RFC 4180: quoted fields may contain separators, quotes ("") and line breaks.
    static func parseDelimited(_ text: String, separator: Character) -> Table {
        var rows: Table = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil
        while let character = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && field.isEmpty {
                quoted = true
            } else if character == separator {
                row.append(field)
                field = ""
            } else if character == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private static func unzip(_ url: URL) async throws -> URL {
        let folder = Output.temporaryURL(extension: "").deletingPathExtension()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", url.path, folder.path])
        return folder
    }

    private static func readXLSX(_ url: URL) async throws -> Table {
        let folder = try await unzip(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        let xl = folder.appendingPathComponent("xl")
        // The first sheet listed in the workbook, through its relationship id.
        var sheetPath = "worksheets/sheet1.xml"
        if let workbook = try? Data(contentsOf: xl.appendingPathComponent("workbook.xml")),
           let rels = try? Data(contentsOf: xl.appendingPathComponent("_rels/workbook.xml.rels")) {
            let sheetIDs = XMLScan.attributes(of: "sheet", in: workbook)
            let targets = XMLScan.attributes(of: "Relationship", in: rels)
            if let id = sheetIDs.first?["r:id"], let target = targets.first(where: { $0["Id"] == id })?["Target"] {
                sheetPath = target.hasPrefix("/xl/") ? String(target.dropFirst(4)) : target
            }
        }
        let shared = (try? Data(contentsOf: xl.appendingPathComponent("sharedStrings.xml"))).map(SharedStrings.parse) ?? []
        guard let sheet = try? Data(contentsOf: xl.appendingPathComponent(sheetPath)) else {
            throw AdawatError.message("\(url.lastPathComponent) has no readable sheet.")
        }
        return SheetXML.parse(sheet, shared: shared)
    }

    private static func readODS(_ url: URL) async throws -> Table {
        let folder = try await unzip(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let content = try? Data(contentsOf: folder.appendingPathComponent("content.xml")) else {
            throw AdawatError.message("\(url.lastPathComponent) has no readable sheet.")
        }
        return ODSXML.parse(content)
    }

    // MARK: Writing

    static func containsArabic(_ table: Table) -> Bool {
        table.contains { $0.contains(where: ArabicText.containsArabic) }
    }

    /// Plain numbers become numeric cells; values like "007" or "+20" stay text so nothing is lost.
    private static func number(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, Double(trimmed) != nil, !trimmed.hasPrefix("+"),
              !(trimmed.count > 1 && trimmed.hasPrefix("0") && !trimmed.hasPrefix("0.")) else { return nil }
        return trimmed
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func columnName(_ index: Int) -> String {
        var index = index + 1
        var name = ""
        while index > 0 {
            let remainder = (index - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            index = (index - 1) / 26
        }
        return name
    }

    static func write(_ table: Table, as target: Target, to out: URL) async throws {
        switch target {
        case .csv:
            let text = table.map { row in
                row.map { field in
                    field.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
                }.joined(separator: ",")
            }.joined(separator: "\r\n")
            // The byte-order mark makes Excel read UTF-8, so Arabic does not turn into symbols.
            try Data(("\u{FEFF}" + text + "\r\n").utf8).write(to: out)
        case .tsv:
            let text = table.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                .joined(separator: "\t") }.joined(separator: "\n")
            try (text + "\n").write(to: out, atomically: true, encoding: .utf8)
        case .xlsx:
            try await writeXLSX(table, to: out)
        case .ods:
            try await writeODS(table, to: out)
        case .html:
            try html(table).write(to: out, atomically: true, encoding: .utf8)
        case .pdf:
            let data = Data(html(table).utf8)
            let text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html,
                                                                     .characterEncoding: String.Encoding.utf8.rawValue],
                                              documentAttributes: nil)
            try DocumentOps.writePDF(text, to: out)
        }
    }

    static func html(_ table: Table) -> String {
        let direction = containsArabic(table) ? "rtl" : "ltr"
        let rows = table.enumerated().map { index, row in
            let tag = index == 0 ? "th" : "td"
            return "<tr>" + row.map { "<\(tag)>\(escape($0))</\(tag)>" }.joined() + "</tr>"
        }.joined(separator: "\n")
        return """
        <!doctype html><html dir="\(direction)"><head><meta charset="utf-8"><style>
        body { font: 10pt -apple-system, "Geeza Pro", sans-serif; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #999; padding: 3px 6px; text-align: start; }
        th { background: #eee; font-weight: bold; }
        </style></head><body><table>
        \(rows)
        </table></body></html>
        """
    }

    private static func zipFolder(_ folder: URL, to out: URL, storedFirst: String? = nil) async throws {
        let zip = URL(fileURLWithPath: "/usr/bin/zip")
        try? FileManager.default.removeItem(at: out)
        if let storedFirst {
            try await ProcessRunner.run(zip, ["-X", "-0", "-q", out.path, storedFirst], currentDirectory: folder)
        }
        let items = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != storedFirst && $0 != ".DS_Store" }
        try await ProcessRunner.run(zip, ["-X", "-r", "-q", "-9", out.path] + items, currentDirectory: folder)
    }

    private static func writeXLSX(_ table: Table, to out: URL) async throws {
        let fm = FileManager.default
        let root = Output.temporaryURL(extension: "").deletingPathExtension()
        defer { try? fm.removeItem(at: root) }
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let rtl = containsArabic(table) ? " rightToLeft=\"1\"" : ""
        var rows = ""
        for (r, row) in table.enumerated() {
            rows += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = "\(columnName(c))\(r + 1)"
                let style = r == 0 ? " s=\"1\"" : ""
                if let number = number(value) {
                    rows += "<c r=\"\(ref)\"\(style)><v>\(number)</v></c>"
                } else {
                    rows += "<c r=\"\(ref)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(escape(value))</t></is></c>"
                }
            }
            rows += "</row>"
        }
        let files: [String: String] = [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """,
            "xl/styles.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"\(rtl)/></sheetViews><sheetData>\(rows)</sheetData></worksheet>
            """,
        ]
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try await zipFolder(root, to: out)
    }

    private static func writeODS(_ table: Table, to out: URL) async throws {
        let fm = FileManager.default
        let root = Output.temporaryURL(extension: "").deletingPathExtension()
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        var rows = ""
        for row in table {
            rows += "<table:table-row>"
            for value in row {
                if let number = number(value) {
                    rows += "<table:table-cell office:value-type=\"float\" office:value=\"\(number)\"><text:p>\(number)</text:p></table:table-cell>"
                } else {
                    rows += "<table:table-cell office:value-type=\"string\"><text:p>\(escape(value))</text:p></table:table-cell>"
                }
            }
            rows += "</table:table-row>"
        }
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet><table:table table:name="Sheet1">\(rows)</table:table></office:spreadsheet></office:body></office:document-content>
        """
        let manifest = """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2"><manifest:file-entry manifest:full-path="/" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """
        try "application/vnd.oasis.opendocument.spreadsheet".write(to: root.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try content.write(to: root.appendingPathComponent("content.xml"), atomically: true, encoding: .utf8)
        try manifest.write(to: root.appendingPathComponent("META-INF/manifest.xml"), atomically: true, encoding: .utf8)
        // ODF requires the uncompressed mimetype entry to come first.
        try await zipFolder(root, to: out, storedFirst: "mimetype")
    }

    static func convert(_ files: [URL], to target: Target, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try await context.checkpoint()
            context.report("Converting \(index + 1) of \(files.count)")
            let table = try await read(file)
            guard !table.isEmpty else { throw AdawatError.message("\(file.lastPathComponent) is empty.") }
            let out = Output.url(for: file, extension: target.rawValue)
            try await write(table, as: target, to: out)
            outputs.append(out)
        }
        return outputs
    }
}

// MARK: - XML readers

/// Collects every element's attributes by name; enough for small index files.
final class XMLScan: NSObject, XMLParserDelegate {
    private let name: String
    private var found: [[String: String]] = []

    private init(name: String) { self.name = name }

    static func attributes(of name: String, in data: Data) -> [[String: String]] {
        let scan = XMLScan(name: name)
        let parser = XMLParser(data: data)
        parser.delegate = scan
        parser.parse()
        return scan.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == name || elementName.hasSuffix(":" + name) { found.append(attributes) }
    }
}

/// xl/sharedStrings.xml: each <si> is one string, possibly split into rich-text runs.
final class SharedStrings: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let reader = SharedStrings()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == "si" { current = "" }
        if elementName == "t" { inText = true }
        if elementName == "rPh" { inText = false }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "si" { strings.append(current) }
    }
}

/// A worksheet's <sheetData>: cells placed by their A1 reference, with shared, inline, boolean and number values.
final class SheetXML: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [Int: [Int: String]] = [:]
    private var row = 0
    private var column = 0
    private var type = ""
    private var value = ""
    private var capture = false

    private init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> SheetOps.Table {
        let reader = SheetXML(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        guard let last = reader.rows.keys.max() else { return [] }
        let width = (reader.rows.values.flatMap(\.keys).max() ?? 0) + 1
        return (0...last).map { r in (0..<width).map { reader.rows[r]?[$0] ?? "" } }
    }

    private static func reference(_ ref: String) -> (row: Int, column: Int) {
        var column = 0
        var digits = ""
        for character in ref {
            if let ascii = character.asciiValue, character.isLetter {
                column = column * 26 + Int(ascii - 64)
            } else {
                digits.append(character)
            }
        }
        return ((Int(digits) ?? 1) - 1, column - 1)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "row":
            if let r = attributes["r"], let number = Int(r) { row = number - 1 }
            column = 0
        case "c":
            if let ref = attributes["r"] { (row, column) = Self.reference(ref) }
            type = attributes["t"] ?? "n"
            value = ""
        case "v", "t":
            capture = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { value += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "v", "t":
            capture = false
        case "c":
            var text = value
            if type == "s", let index = Int(value), shared.indices.contains(index) { text = shared[index] }
            if type == "b" { text = value == "1" ? "TRUE" : "FALSE" }
            if !text.isEmpty { rows[row, default: [:]][column] = text }
            column += 1
        case "row":
            row += 1
        default:
            break
        }
    }
}

/// An OpenDocument spreadsheet's first table, expanding repeated rows and cells (but not runs of empties).
final class ODSXML: NSObject, XMLParserDelegate {
    private var table: SheetOps.Table = []
    private var row: [String] = []
    private var cell = ""
    private var repeatColumns = 1
    private var repeatRows = 1
    private var inCell = false
    private var tables = 0
    private var paragraphs = 0

    static func parse(_ data: Data) -> SheetOps.Table {
        let reader = ODSXML()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        // Trailing blank rows and columns are padding, not data.
        var table = reader.table.map { row -> [String] in
            var row = row
            while row.last?.isEmpty == true { row.removeLast() }
            return row
        }
        while table.last?.isEmpty == true { table.removeLast() }
        let width = table.map(\.count).max() ?? 0
        return table.map { $0 + Array(repeating: "", count: width - $0.count) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        switch elementName {
        case "table:table": tables += 1
        case "table:table-row" where tables == 1:
            row = []
            repeatRows = min(Int(attributes["table:number-rows-repeated"] ?? "1") ?? 1, 1000)
        case "table:table-cell", "table:covered-table-cell":
            inCell = tables == 1
            cell = ""
            paragraphs = 0
            repeatColumns = min(Int(attributes["table:number-columns-repeated"] ?? "1") ?? 1, 1000)
        case "text:p" where inCell:
            if paragraphs > 0 { cell += "\n" }
            paragraphs += 1
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inCell { cell += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "table:table-cell", "table:covered-table-cell" where inCell:
            row += Array(repeating: cell, count: cell.isEmpty ? min(repeatColumns, 1) : repeatColumns)
            inCell = false
        case "table:table-row" where tables == 1:
            table += Array(repeating: row, count: row.allSatisfy(\.isEmpty) ? min(repeatRows, 1) : repeatRows)
        default:
            break
        }
    }
}

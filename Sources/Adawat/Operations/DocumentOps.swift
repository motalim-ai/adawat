import AppKit

/// Conversions between text documents through NSAttributedString, which reads
/// TXT, RTF, RTFD, DOC, DOCX, ODT, HTML and web archives.
@MainActor
enum DocumentOps {
    enum Target: String {
        case pdf, docx, pages, epub, md, rtf, txt, html, odt

        var title: String { self == .md ? "MD" : rawValue.uppercased() }
    }

    static func load(_ url: URL) async throws -> NSAttributedString {
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return Markdown.attributed(try SubtitleOps.readText(url))
        case "epub":
            return try await EPUB.read(url)
        case "pages":
            // Pages hands back a Word file, which keeps its styles and tables.
            let temp = IWorkBridge.scratchURL(near: url, extension: "docx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await IWorkBridge.export(url, with: .pages, as: .word, to: temp)
            return try NSAttributedString(url: temp, options: [:], documentAttributes: nil)
        case "textclipping":
            // Clippings are property lists holding the dragged text under one or more pasteboard types.
            guard let plist = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
                  let items = plist["UTI-Data"] as? [String: Any] else {
                throw AdawatError.message("This text clipping has an unsupported or malformed format.")
            }
            if let rtf = items["public.rtf"] as? Data, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) { return text }
            if let plain = items["public.utf8-plain-text"] as? String ?? (items["public.utf8-plain-text"] as? Data).flatMap({ String(data: $0, encoding: .utf8) }) {
                return NSAttributedString(string: plain, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            }
            throw AdawatError.message("The clipping contains no supported text.")
        default:
            break
        }
        if ["txt", "text", "csv", "log"].contains(url.pathExtension.lowercased()) {
            let raw = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .utf16)
            let text = NSMutableAttributedString(string: raw, attributes: [.font: NSFont.systemFont(ofSize: 13)])
            ArabicText.applyParagraphDirection(text)
            return text
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw AdawatError.message("\(url.lastPathComponent) could not be read as a document")
        }
    }

    static func convert(_ files: [URL], to target: Target, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            context.report("Converting \(index + 1) of \(files.count)")
            let out = Output.url(for: file, extension: target.rawValue)
            if target == .pdf, WordPrinter.handles(file), await WordPrinter.print(file, to: out) {
                outputs.append(out)
                continue
            }
            try await write(try await load(file), as: target, to: out, title: file.deletingPathExtension().lastPathComponent)
            outputs.append(out)
        }
        return outputs
    }

    static func write(_ text: NSAttributedString, as target: Target, to out: URL, title: String = "Untitled") async throws {
        switch target {
        case .pdf:
            try writePDF(text, to: out)
        case .epub:
            try await EPUB.write(text, title: title, to: out)
        case .md:
            try Markdown.string(from: text).write(to: out, atomically: true, encoding: .utf8)
        case .pages:
            let temp = IWorkBridge.scratchURL(near: out, extension: "docx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await write(text, as: .docx, to: temp)
            try await IWorkBridge.export(temp, with: .pages, as: .native, to: out)
        case .txt:
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case .docx, .rtf, .html, .odt:
            let type: NSAttributedString.DocumentType = switch target {
            case .docx: .officeOpenXML
            case .rtf: .rtf
            case .html: .html
            default: .openDocument
            }
            var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
            if type == .html { attributes[.characterEncoding] = String.Encoding.utf8.rawValue }
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
            try data.write(to: out)
        }
    }

    /// Lays the text out on US Letter pages with one-inch margins and prints it to a PDF file.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 72
        info.bottomMargin = 72
        info.leftMargin = 72
        info.rightMargin = 72
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        // Print-to-PDF centers short documents on the page by default; text belongs at the top.
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textStorage?.setAttributedString(ArabicText.withPrintableArabicFont(text))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw AdawatError.message("The document could not be printed as PDF")
        }
    }
}

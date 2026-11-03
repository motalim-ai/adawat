import AppKit
import PDFKit
import Quartz

@MainActor
enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw AdawatError.message("\(url.lastPathComponent) cannot be read or is password-protected")
        }
        if document.isLocked { throw AdawatError.message("\(url.lastPathComponent) is password-protected") }
        guard document.pageCount > 0 else { throw AdawatError.message("\(url.lastPathComponent) has no pages") }
        return document
    }

    static func merge(_ files: [URL], context: OperationContext) async throws -> [URL] {
        let merged = PDFDocument()
        for file in files {
            let document = try open(file)
            for index in 0..<document.pageCount {
                if let page = document.page(at: index) {
                    merged.insert(page, at: merged.pageCount)
                }
            }
        }
        let out = Output.url(named: "Merged.pdf", near: files[0])
        guard merged.write(to: out) else { throw AdawatError.message("Could not write the combined PDF") }
        context.finish(with: "Merged \(files.count) PDFs · \(merged.pageCount) pages")
        return [out]
    }

    /// Saves every page as its own PDF inside a new folder.
    static func split(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            let document = try open(file)
            let base = file.deletingPathExtension().lastPathComponent
            let folder = Output.url(named: "\(base) pages", near: file)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<document.pageCount {
                context.report("Page \(index + 1) of \(document.pageCount)")
                guard let page = document.page(at: index) else { continue }
                let single = PDFDocument()
                single.insert(page, at: 0)
                let out = folder.appendingPathComponent(String(format: "%@ %03d.pdf", base, index + 1))
                guard single.write(to: out) else { throw AdawatError.message("Could not save page \(index + 1) of \(file.lastPathComponent)") }
            }
            outputs.append(folder)
        }
        return outputs
    }

    /// Renders every page at 300 DPI. Several pages go into a folder named after the PDF.
    static func renderPages(_ files: [URL], format: ImageFormat, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            let document = try open(file)
            let base = file.deletingPathExtension().lastPathComponent
            let folder: URL? = document.pageCount > 1 ? Output.url(named: "\(base) \(format.name)", near: file) : nil
            if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            for index in 0..<document.pageCount {
                context.report("Rendering page \(index + 1) of \(document.pageCount)")
                context.progress(Double(index) / Double(document.pageCount))
                guard let page = document.page(at: index), let image = render(page, dpi: 300) else {
                    throw AdawatError.message("Could not render page \(index + 1)")
                }
                let out = folder?.appendingPathComponent(String(format: "%@ %03d.%@", base, index + 1, format.ext))
                    ?? Output.url(for: file, extension: format.ext)
                try await ImageOps.write(image, to: out, format: format, quality: 0.9)
                if folder == nil { outputs.append(out) }
            }
            if let folder { outputs.append(folder) }
        }
        return outputs
    }

    /// Draws a page upright (honoring its /Rotate) on white at `dpi`, capped at 6000 px on the long side
    /// because scanned PDFs sometimes declare enormous pages.
    static func render(_ page: PDFPage, dpi: CGFloat) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let box = page.bounds(for: .mediaBox)
        let quarterTurned = (page.rotation / 90) % 2 != 0
        let size = quarterTurned ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(dpi / 72, 6000 / max(size.width, size.height, 1))
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // The drawing transform only ever scales down, so it is computed at point size after scaling up.
        ctx.concatenate(pageRef.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size),
                                                    rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(pageRef)
        return ctx.makeImage()
    }

    /// Selectable text, falling back to OCR for scanned pages; Arabic presentation forms are repaired.
    static func text(of file: URL, context: OperationContext) async throws -> String {
        let document = try open(file)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let selectable = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !selectable.isEmpty {
                pages.append(ArabicText.normalizeExtracted(selectable))
            } else if let image = render(page, dpi: 200) {
                context.report("Recognizing page \(index + 1) of \(document.pageCount)")
                pages.append(try await ImageOps.recognizeText(in: image))
            }
            context.progress(Double(index + 1) / Double(document.pageCount))
        }
        return pages.joined(separator: "\n\n")
    }

    static func toText(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            let text = try await self.text(of: file, context: context)
            let out = Output.url(for: file, extension: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            outputs.append(out)
        }
        return outputs
    }

    /// Editable Word or RTF text with the PDF's fonts and styles; Arabic paragraphs read right to left.
    static func toDocument(_ files: [URL], target: DocumentOps.Target, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            let document = try open(file)
            let text = NSMutableAttributedString()
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.attributedString { text.append(page) }
                if index < document.pageCount - 1 { text.append(NSAttributedString(string: "\n\n")) }
            }
            guard text.length > 0 else {
                throw AdawatError.message("\(file.lastPathComponent) has no selectable text. Use Copy Text to read scanned pages.")
            }
            let fixed = ArabicText.normalizeExtracted(text)
            ArabicText.applyParagraphDirection(fixed)
            let out = Output.url(for: file, extension: target.rawValue)
            try await DocumentOps.write(fixed, as: target, to: out, title: file.deletingPathExtension().lastPathComponent)
            outputs.append(out)
        }
        return outputs
    }

    /// The same "Reduce File Size" filter Preview uses; it downsamples and recompresses embedded images.
    static func compress(_ files: [URL], context: OperationContext) async throws -> [URL] {
        let filterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")
        guard let filter = QuartzFilter(url: filterURL) else { throw AdawatError.message("The macOS PDF compression filter is unavailable") }
        var outputs: [URL] = []
        var before: Int64 = 0
        var after: Int64 = 0
        for file in files {
            let document = try open(file)
            let out = Output.url(for: file, extension: "pdf", suffix: "compressed")
            guard document.write(to: out, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) else {
                throw AdawatError.message("Could not create the compressed PDF")
            }
            let original = ImageOps.fileSize(file), compressed = ImageOps.fileSize(out)
            before += original
            // A PDF of text and vectors can grow; keep the original size in that case.
            if compressed >= original {
                try? FileManager.default.removeItem(at: out)
                after += original
                continue
            }
            after += compressed
            outputs.append(out)
        }
        let saved = before > 0 ? 100 - Int((Double(after) / Double(before) * 100).rounded()) : 0
        context.finish(with: outputs.isEmpty ? "These PDFs are already as small as they get" : "Compressed PDF · \(saved)% smaller")
        return outputs
    }

    /// Clears the title, author, creator and other document info.
    static func stripMetadata(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            let document = try open(file)
            document.documentAttributes = [:]
            let out = Output.url(for: file, extension: "pdf", suffix: "clean")
            guard document.write(to: out) else { throw AdawatError.message("Could not write the cleaned PDF") }
            outputs.append(out)
        }
        context.finish(with: "Metadata removed from \(files.count) PDF\(files.count == 1 ? "" : "s")")
        return outputs
    }
}

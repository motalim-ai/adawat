import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

struct ImageFormat: Hashable {
    let name: String
    let ext: String
    let type: UTType
    let lossy: Bool

    static let png = ImageFormat(name: "PNG", ext: "png", type: .png, lossy: false)
    static let jpeg = ImageFormat(name: "JPEG", ext: "jpg", type: .jpeg, lossy: true)
    static let heic = ImageFormat(name: "HEIC", ext: "heic", type: .heic, lossy: true)
    static let webp = ImageFormat(name: "WebP", ext: "webp", type: .webP, lossy: true)
    static let avif = ImageFormat(name: "AVIF", ext: "avif", type: UTType("public.avif") ?? .image, lossy: true)
    static let tiff = ImageFormat(name: "TIFF", ext: "tiff", type: .tiff, lossy: false)
    static let gif = ImageFormat(name: "GIF", ext: "gif", type: .gif, lossy: false)
    static let bmp = ImageFormat(name: "BMP", ext: "bmp", type: .bmp, lossy: false)
    static let ico = ImageFormat(name: "ICO", ext: "ico", type: .ico, lossy: false)

    static let all: [ImageFormat] = [.png, .jpeg, .heic, .webp, .avif, .tiff, .gif, .bmp, .ico]

    /// Formats whose viewers reliably honor the EXIF orientation tag, so rotated photos need no redraw.
    var keepsOrientationTag: Bool { [.jpeg, .heic, .avif, .tiff].contains(self) }

    static func of(_ url: URL) -> ImageFormat? {
        let ext = url.pathExtension.lowercased()
        if ext == "jpeg" { return .jpeg }
        if ext == "tif" { return .tiff }
        return all.first { $0.ext == ext }
    }
}

@MainActor
enum ImageOps {
    /// Upright pixels for analysis (text and QR recognition).
    static func loadImage(_ url: URL, maxPixels: Int? = nil) throws -> CGImage {
        try ImageFile(url).upright(maxPixels: maxPixels)
    }

    /// Saves already-rendered pixels, such as PDF pages, in `format`.
    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double) async throws {
        try await ImageEngine.writeRendered(image, as: format, to: url, quality: quality)
    }

    // MARK: Operations

    static func convert(_ files: [URL], to format: ImageFormat, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, url) in files.enumerated() {
            context.report("Converting \(index + 1) of \(files.count)")
            let out = Output.url(for: url, extension: format.ext)
            try await ImageEngine.save(try ImageFile(url), as: format, to: out, quality: 0.9)
            outputs.append(out)
        }
        return outputs
    }

    /// Lossy formats stay as they are; lossless ones become JPEG, or HEIC when they carry transparency.
    static func compressedFormat(for file: ImageFile) -> ImageFormat {
        if let format = ImageFormat.of(file.url), format.lossy, ImageEngine.canWrite(format) { return format }
        return file.hasAlpha ? .heic : .jpeg
    }

    static func resize(_ files: [URL], context: OperationContext) async throws -> [URL] {
        let maxPixels = AppSettings.shared.resizeMaxPixels
        var outputs: [URL] = []
        for (index, url) in files.enumerated() {
            context.report("Resizing \(index + 1) of \(files.count)")
            let file = try ImageFile(url)
            let size = file.uprightSize
            let scale = min(1, Double(maxPixels) / Double(max(size.width, size.height, 1)))
            let w = Int((Double(size.width) * scale).rounded()), h = Int((Double(size.height) * scale).rounded())
            var format = ImageFormat.of(url) ?? .png
            if format == .gif || format == .ico || !ImageEngine.canWrite(format) { format = .png }
            let out = Output.url(for: url, extension: format.ext, suffix: "\(w)x\(h)")
            try await ImageEngine.save(file, as: format, to: out, quality: 0.9, edit: .resize(maxPixels: maxPixels))
            outputs.append(out)
        }
        return outputs
    }

    static func removeMetadata(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for url in files {
            let out = Output.url(for: url, extension: url.pathExtension, suffix: "clean")
            outputs.append(try await ImageEngine.stripMetadata(try ImageFile(url), to: out))
        }
        context.finish(with: "Metadata removed from \(files.count) image\(files.count == 1 ? "" : "s")")
        return outputs
    }

    /// Crops every image to the same normalized rectangle (top-left origin), keeping HDR where present.
    static func crop(_ files: [URL], rect: CGRect, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, url) in files.enumerated() {
            context.report("Cropping \(index + 1) of \(files.count)")
            let file = try ImageFile(url)
            var format = ImageFormat.of(url) ?? .png
            if !ImageEngine.canWrite(format) || format == .gif { format = .png }
            let out = Output.url(for: url, extension: format.ext, suffix: "cropped")
            try await ImageEngine.save(file, as: format, to: out, quality: 0.92, edit: .crop(rect))
            outputs.append(out)
        }
        return outputs
    }

    /// The largest centered square, for one-step runs without the crop window.
    static func squareCrop(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for url in files {
            let size = try ImageFile(url).uprightSize
            let w = CGFloat(size.width), h = CGFloat(size.height), side = min(w, h)
            let rect = CGRect(x: (w - side) / 2 / w, y: (h - side) / 2 / h, width: side / w, height: side / h)
            outputs += try await crop([url], rect: rect, context: context)
        }
        return outputs
    }

    static func frame(_ files: [URL], options: FrameOptions, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for url in files {
            let source = try ImageFile(url)
            let image = try FrameRenderer.render(try source.upright(), options: options)
            let format = ImageEngine.editedFormat(for: url)
            let out = Output.url(for: url, extension: format.ext, suffix: "framed")
            try await ImageEngine.saveDrawn(source, image: image, as: format, to: out, quality: 0.92)
            outputs.append(out)
        }
        return outputs
    }

    static func collage(_ files: [URL], options: CollageOptions, context: OperationContext) async throws -> [URL] {
        context.report("Creating collage")
        var options = options
        options.columns = files.count <= 4 ? 2 : 3
        let images = try files.map { try ImageFile($0).upright(maxPixels: options.width) }
        let out = Output.url(named: "Collage.jpg", near: files[0])
        try await ImageEngine.saveDrawn(nil, image: try CollageRenderer.render(images, options: options), as: .jpeg, to: out, quality: 0.92)
        return [out]
    }

    static func rotate(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for url in files {
            let out = Output.url(for: url, extension: url.pathExtension, suffix: "rotated")
            try await ImageEngine.rotateClockwise(try ImageFile(url), to: out)
            outputs.append(out)
        }
        return outputs
    }

    static func makePDF(_ files: [URL], context: OperationContext) async throws -> [URL] {
        context.report("Creating PDF from \(files.count) image\(files.count == 1 ? "" : "s")")
        let images = try files.map(ImageFile.init)
        let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "Images"
        let out = Output.url(named: "\(name).pdf", near: files[0])
        try ImageEngine.writePDF(images, to: out)
        return [out]
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: Vision

    static func recognizeText(in image: CGImage) async throws -> String {
        try await performVision(on: image) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            return request
        } results: { request in
            ((request.results as? [VNRecognizedTextObservation]) ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
    }

    static func readQRCodes(in image: CGImage) async throws -> [String] {
        try await performVision(on: image) {
            VNDetectBarcodesRequest()
        } results: { request in
            ((request.results as? [VNBarcodeObservation]) ?? []).compactMap(\.payloadStringValue)
        }
    }

    /// Runs one Vision request off the main thread and reads its results after `perform` returns.
    private static func performVision<Request: VNRequest, Value>(
        on image: CGImage,
        make: @escaping () -> Request,
        results: @escaping (Request) -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = make()
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    continuation.resume(returning: results(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Recognizes text in images and PDFs, saves a .txt next to each and copies it all.
    static func extractText(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        var all: [String] = []
        for (index, file) in files.enumerated() {
            context.report("Reading text \(index + 1) of \(files.count)")
            var text: String
            if FileKind(url: file) == .pdf {
                text = try await PDFOps.text(of: file, context: context)
            } else {
                text = try await recognizeText(in: loadImage(file))
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let out = Output.url(for: file, extension: "txt")
            try text.write(to: out, atomically: true, encoding: .utf8)
            outputs.append(out)
            all.append(text)
        }
        guard !all.isEmpty else { throw AdawatError.message("No text found") }
        Clipboard.copy(text: all.joined(separator: "\n\n"))
        context.finish(with: "Text copied to clipboard")
        return outputs
    }

    static func readQRCodes(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var payloads: [String] = []
        for file in files {
            payloads += try await readQRCodes(in: loadImage(file))
        }
        guard !payloads.isEmpty else { throw AdawatError.message("No QR codes found") }
        Clipboard.copy(text: payloads.joined(separator: "\n"))
        let preview = payloads[0].count > 60 ? String(payloads[0].prefix(60)) + "…" : payloads[0]
        context.finish(with: "Copied: \(preview)")
        return []
    }
}

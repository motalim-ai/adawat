import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One image file opened for reading, with the traits that decide how it can be re-encoded.
struct ImageFile {
    let url: URL
    let source: CGImageSource
    let properties: [CFString: Any]

    init(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw AdawatError.message("Could not read \(url.lastPathComponent)")
        }
        self.url = url
        self.source = source
        properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    var orientation: Int { properties[kCGImagePropertyOrientation] as? Int ?? 1 }
    var hasAlpha: Bool { properties[kCGImagePropertyHasAlpha] as? Bool ?? false }
    var typeIdentifier: String? { CGImageSourceGetType(source) as String? }
    var pixelWidth: Int { properties[kCGImagePropertyPixelWidth] as? Int ?? 0 }
    var pixelHeight: Int { properties[kCGImagePropertyPixelHeight] as? Int ?? 0 }
    /// Width and height as the photo is shown, after its orientation tag.
    var uprightSize: (width: Int, height: Int) {
        (5...8).contains(orientation) ? (pixelHeight, pixelWidth) : (pixelWidth, pixelHeight)
    }

    /// iPhone HDR photos and ProRAW keep their extra highlight range in an auxiliary gain map.
    var hasGainMap: Bool {
        if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil { return true }
        if #available(macOS 15.0, *) {
            return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
        }
        return false
    }

    /// Decodes the picture upright, optionally no larger than `maxPixels` on its longest side.
    func upright(maxPixels: Int? = nil) throws -> CGImage {
        let longest = max(uprightSize.width, uprightSize.height, 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixels ?? longest, longest),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AdawatError.message("Could not decode \(url.lastPathComponent)")
        }
        return image
    }

    /// Camera, location and copyright data with the orientation reset, for pixels that are already upright.
    var uprightMetadata: [CFString: Any] {
        var meta: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = properties[key] { meta[key] = value }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }
        meta[kCGImagePropertyOrientation] = 1
        return meta
    }
}

/// A change applied to the pixels while saving.
enum ImageEdit: Equatable {
    case none
    case resize(maxPixels: Int)
    /// Normalized rectangle (0…1) with a top-left origin on the upright picture.
    case crop(CGRect)
}

/// Saves images with as little quality loss as each format allows.
///
/// In order of preference: HDR photos keep their gain map; untouched pixels are copied straight from the
/// source, keeping bit depth, color profile and metadata; only when that is impossible are they redrawn.
@MainActor
enum ImageEngine {
    static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    /// Whether this Mac can produce `format` (AVIF writing arrived after macOS 14; WebP needs cwebp).
    static func canWrite(_ format: ImageFormat) -> Bool {
        if format == .webp { return ExternalTool.cwebp.url != nil }
        return writableTypes.contains(format.type.identifier)
    }

    static func save(_ file: ImageFile, as format: ImageFormat, to out: URL, quality: Double,
                     edit: ImageEdit = .none, keepMetadata: Bool = true) async throws {
        do {
            try await encode(file, as: format, to: out, quality: quality, edit: edit, keepMetadata: keepMetadata)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    private static func encode(_ file: ImageFile, as format: ImageFormat, to out: URL, quality: Double,
                               edit: ImageEdit, keepMetadata: Bool) async throws {
        if format == .webp {
            try await writeWebP(try redraw(file, edit: edit, for: format), to: out, quality: quality)
            return
        }
        guard canWrite(format) else { throw AdawatError.message("This Mac cannot write \(format.name) images") }

        if file.hasGainMap, try saveHDR(file, as: format, to: out, quality: quality,
                                       transform: { apply(edit, to: $0) }, keepMetadata: keepMetadata) {
            return
        }

        let needsFlatten = (format == .jpeg || format == .bmp) && file.hasAlpha
        let tagIsHonored = file.orientation == 1 || format.keepsOrientationTag
        if edit == .none, !needsFlatten, tagIsHonored, format != .ico {
            try copyPixels(file, as: format, to: out, quality: quality, keepMetadata: keepMetadata)
            return
        }

        let image = try redraw(file, edit: edit, for: format)
        try write(image, as: format, to: out, quality: quality,
                  metadata: keepMetadata ? file.uprightMetadata : [kCGImagePropertyOrientation: 1])
    }

    /// Re-encodes the source pixels directly: full bit depth, the original color profile and all metadata.
    private static func copyPixels(_ file: ImageFile, as format: ImageFormat, to out: URL, quality: Double,
                                   keepMetadata: Bool) throws {
        let destination = try makeDestination(out, format)
        var options: [CFString: Any] = [:]
        if format.lossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        if !keepMetadata {
            options[kCGImagePropertyExifDictionary] = kCFNull
            options[kCGImagePropertyGPSDictionary] = kCFNull
            options[kCGImagePropertyIPTCDictionary] = kCFNull
        }
        CGImageDestinationAddImageFromSource(destination, file.source, 0, options as CFDictionary)
        try finalize(destination, out)
    }

    /// Upright pixels with the edit applied, ready for formats that need fresh pixels.
    static func redraw(_ file: ImageFile, edit: ImageEdit, for format: ImageFormat) throws -> CGImage {
        var image: CGImage
        switch edit {
        case .none:
            image = try file.upright()
        case .resize(let maxPixels):
            image = try file.upright(maxPixels: maxPixels)
        case .crop(let rect):
            let full = try file.upright()
            let w = CGFloat(full.width), h = CGFloat(full.height)
            let pixels = CGRect(x: rect.minX * w, y: rect.minY * h, width: rect.width * w, height: rect.height * h).integral
            guard let cropped = full.cropping(to: pixels) else { throw AdawatError.message("Could not crop the image") }
            image = cropped
        }
        if format == .jpeg || format == .bmp { image = flattened(image) }
        if format == .ico { image = squareIcon(image, side: 256) }
        return image
    }

    static func write(_ image: CGImage, as format: ImageFormat, to out: URL, quality: Double,
                      metadata: [CFString: Any]) throws {
        let destination = try makeDestination(out, format)
        var options = format == .ico ? [:] : metadata
        if format.lossy { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        try finalize(destination, out)
    }

    /// Saves rendered pixels with no source file behind them.
    static func writeRendered(_ image: CGImage, as format: ImageFormat, to out: URL, quality: Double) async throws {
        if format == .webp {
            try await writeWebP(image, to: out, quality: quality)
        } else {
            var image = image
            if format == .jpeg || format == .bmp { image = flattened(image) }
            if format == .ico { image = squareIcon(image, side: 256) }
            try write(image, as: format, to: out, quality: quality, metadata: [:])
        }
    }

    private static func writeWebP(_ image: CGImage, to out: URL, quality: Double) async throws {
        let cwebp = try ExternalTool.cwebp.require()
        let temp = Output.temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: temp) }
        try write(image, as: .png, to: temp, quality: 1, metadata: [:])
        try await ProcessRunner.run(cwebp, ["-quiet", "-q", "\(Int((quality * 100).rounded()))", "-metadata", "none",
                                            temp.path, "-o", out.path])
    }

    private static func makeDestination(_ out: URL, _ format: ImageFormat) throws -> CGImageDestination {
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw AdawatError.message("This Mac cannot write \(format.name) images")
        }
        return destination
    }

    private static func finalize(_ destination: CGImageDestination, _ out: URL) throws {
        guard CGImageDestinationFinalize(destination) else {
            throw AdawatError.message("Could not save \(out.lastPathComponent)")
        }
    }

    // MARK: Metadata

    /// Removes camera, location and editing data without re-compressing the pixels when the format allows.
    /// Returns where the copy went: `out`, or `out` with another extension when the original format cannot be
    /// written (RAW, PSD, or WebP without cwebp) and the copy is saved as PNG.
    @discardableResult
    static func stripMetadata(_ file: ImageFile, to out: URL) async throws -> URL {
        let format = ImageFormat.of(file.url) ?? .png
        if format != .webp, let type = file.typeIdentifier, writableTypes.contains(type),
           let destination = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) {
            let metadata = CGImageMetadataCreateMutable()
            if file.orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation,
                                                             file.orientation as CFNumber)
            }
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            if CGImageDestinationCopyImageSource(destination, file.source, options as CFDictionary, nil) { return out }
            try? FileManager.default.removeItem(at: out)
        }
        let written = canWrite(format) ? format : .png
        let target = written == format ? out : Output.unique(out.deletingPathExtension().appendingPathExtension(written.ext))
        try await save(file, as: written, to: target, quality: 0.95, keepMetadata: false)
        return target
    }

    // MARK: Rotation

    /// The EXIF orientation that shows the picture turned another 90° clockwise.
    private static let clockwise: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]

    /// Turns the picture 90° clockwise. Formats that honor the orientation tag only get a new tag,
    /// so the pixels and every byte of quality stay untouched; the rest are redrawn.
    static func rotateClockwise(_ file: ImageFile, to out: URL) async throws {
        let next = clockwise[file.orientation] ?? 6
        if let format = ImageFormat.of(file.url), format.keepsOrientationTag, let type = file.typeIdentifier,
           writableTypes.contains(type),
           let destination = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) {
            // ImageIO rejects this option alongside kCGImageDestinationMetadata, and needs nothing else.
            let options: [CFString: Any] = [kCGImageDestinationOrientation: next]
            if CGImageDestinationCopyImageSource(destination, file.source, options as CFDictionary, nil) { return }
            try? FileManager.default.removeItem(at: out)
        }
        let image = try file.upright()
        guard let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: image.bitsPerComponent,
                                  bytesPerRow: 0, space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: image.bitmapInfo.rawValue)
                ?? CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AdawatError.message("Could not rotate \(file.url.lastPathComponent)")
        }
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rotated = ctx.makeImage() else { throw AdawatError.message("Could not rotate \(file.url.lastPathComponent)") }
        var format = ImageFormat.of(file.url) ?? .png
        if !canWrite(format) || format == .gif { format = .png }
        if format == .webp {
            try await writeRendered(rotated, as: format, to: out, quality: 0.95)
        } else {
            try write(format == .jpeg || format == .bmp ? flattened(rotated) : rotated, as: format, to: out,
                      quality: 0.95, metadata: file.uprightMetadata)
        }
    }

    // MARK: HDR

    private static let gainMapFormats: Set<ImageFormat> = [.jpeg, .heic, .avif]

    /// Writes an HDR photo with a gain map. Returns false when this Mac or format cannot carry one,
    /// so the caller falls back to a standard save.
    private static func saveHDR(_ file: ImageFile, as format: ImageFormat, to out: URL, quality: Double,
                                transform: (CIImage) -> CIImage, keepMetadata: Bool) throws -> Bool {
        guard #available(macOS 15.0, *), gainMapFormats.contains(format) else { return false }
        let upright: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard var sdr = CIImage(contentsOf: file.url, options: upright),
              var hdr = CIImage(contentsOf: file.url, options: upright.merging([.expandToHDR: true]) { a, _ in a }) else {
            return false
        }
        sdr = transform(sdr)
        hdr = transform(hdr)
        let context = CIContext()

        if format == .avif {
            guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3),
                  let image = context.createCGImage(hdr, from: hdr.extent, format: .RGBAh, colorSpace: space) else {
                return false
            }
            let destination = try makeDestination(out, format)
            var options: [CFString: Any] = keepMetadata ? file.uprightMetadata : [kCGImagePropertyOrientation: 1]
            options[kCGImageDestinationLossyCompressionQuality] = quality
            options[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            try finalize(destination, out)
            return true
        }

        var metadata = keepMetadata ? sdr.properties : [:]
        metadata[kCGImagePropertyOrientation as String] = 1
        if var tiff = metadata[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            metadata[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        sdr = sdr.settingProperties(metadata)
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        if format == .jpeg {
            try context.writeJPEGRepresentation(of: sdr, to: out, colorSpace: space, options: options)
        } else {
            try context.writeHEIFRepresentation(of: sdr, to: out, format: .RGBA8, colorSpace: space, options: options)
        }
        return true
    }

    private static func apply(_ edit: ImageEdit, to image: CIImage) -> CIImage {
        let extent = image.extent
        switch edit {
        case .none:
            return image
        case .resize(let maxPixels):
            let scale = Double(maxPixels) / Double(max(extent.width, extent.height))
            guard scale < 1 else { return image }
            let filter = CIFilter(name: "CILanczosScaleTransform")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(scale, forKey: kCIInputScaleKey)
            filter?.setValue(1.0, forKey: kCIInputAspectRatioKey)
            return filter?.outputImage ?? image
        case .crop(let rect):
            // Core Image counts from the bottom-left.
            return image.cropped(to: CGRect(x: extent.minX + rect.minX * extent.width,
                                            y: extent.minY + (1 - rect.maxY) * extent.height,
                                            width: rect.width * extent.width,
                                            height: rect.height * extent.height).integral)
        }
    }

    // MARK: Edited copies

    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Saves the photo with a Core Image filter chain applied. HDR photos run the same chain on both their
    /// standard and HDR renditions, so the gain map survives the edit.
    static func saveFiltered(_ file: ImageFile, as format: ImageFormat, to out: URL, quality: Double,
                             filter: @escaping (CIImage) -> CIImage) async throws {
        if format != .webp, canWrite(format), file.hasGainMap,
           try saveHDR(file, as: format, to: out, quality: quality, transform: { filter($0).cropped(to: $0.extent) },
                       keepMetadata: true) {
            return
        }
        guard let input = CIImage(contentsOf: file.url, options: [.applyOrientationProperty: true]) else {
            throw AdawatError.message("Could not read \(file.url.lastPathComponent)")
        }
        let output = filter(input).cropped(to: input.extent)
        let deep = (file.properties[kCGImagePropertyDepth] as? Int ?? 8) > 8
        let space = input.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let image = ciContext.createCGImage(output, from: input.extent, format: deep ? .RGBA16 : .RGBA8, colorSpace: space) else {
            throw AdawatError.message("Could not render the edited image")
        }
        try await saveDrawn(file, image: image, as: format, to: out, quality: quality)
    }

    /// Saves freshly drawn pixels (annotations, frames, redactions) with the source photo's metadata.
    static func saveDrawn(_ file: ImageFile?, image: CGImage, as format: ImageFormat, to out: URL, quality: Double) async throws {
        do {
            if format == .webp || file == nil {
                try await writeRendered(image, as: format, to: out, quality: quality)
            } else {
                var image = image
                if format == .jpeg || format == .bmp { image = flattened(image) }
                try write(image, as: format, to: out, quality: quality, metadata: file!.uprightMetadata)
            }
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    /// The format an edited copy is saved in: the source's own when this Mac can write it.
    static func editedFormat(for url: URL, needsAlpha: Bool = false) -> ImageFormat {
        var format = ImageFormat.of(url) ?? .png
        if !canWrite(format) || format == .gif || format == .ico || format == .bmp { format = .png }
        if needsAlpha, format == .jpeg { format = .png }
        return format
    }

    // MARK: Pixel helpers

    /// JPEG and BMP have no transparency, so transparent pixels go on white.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// ICO entries must be square and at most 256 px, so the picture is centered on a clear canvas.
    private static func squareIcon(_ image: CGImage, side: Int) -> CGImage {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: PDF

    /// One page per image, sized from each image's DPI. Opaque images are embedded as JPEG so the PDF
    /// stays close to the size of the photos instead of storing raw pixels.
    static func writePDF(_ files: [ImageFile], to out: URL) throws {
        let info: [CFString: Any] = [kCGPDFContextCreator: "Adawat"]
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw AdawatError.message("Could not create the PDF")
        }
        for file in files {
            var image = try file.upright()
            if !file.hasAlpha, let jpeg = jpegBacked(image) { image = jpeg }
            var dpi = file.properties[kCGImagePropertyDPIWidth] as? Double ?? 72
            if dpi < 1 { dpi = 72 }
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.draw(image, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    private static func jpegBacked(_ image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The file `file` would become, encoded in memory, for size targets and estimates.
    static func encodedData(_ file: ImageFile, as format: ImageFormat, quality: Double, maxPixels: Int?) async throws -> Data {
        let edit: ImageEdit = maxPixels.map { .resize(maxPixels: $0) } ?? .none
        if format == .webp {
            let temp = Output.temporaryURL(extension: "webp")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await writeWebP(try redraw(file, edit: edit, for: format), to: temp, quality: quality)
            return try Data(contentsOf: temp)
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw AdawatError.message("This Mac cannot write \(format.name) images")
        }
        let needsFlatten = (format == .jpeg || format == .bmp) && file.hasAlpha
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if edit == .none, !needsFlatten, file.orientation == 1 || format.keepsOrientationTag {
            CGImageDestinationAddImageFromSource(destination, file.source, 0, options as CFDictionary)
        } else {
            options.merge(file.uprightMetadata) { current, _ in current }
            CGImageDestinationAddImage(destination, try redraw(file, edit: edit, for: format), options as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw AdawatError.message("Could not encode the image") }
        return data as Data
    }

    /// The encoded size of `file` at `quality` without saving it, for live estimates in the compress window.
    static func estimatedSize(_ file: ImageFile, as format: ImageFormat, quality: Double) -> Int? {
        guard format != .webp, canWrite(format) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImageFromSource(destination, file.source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data.length : nil
    }
}

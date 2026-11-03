import Foundation

enum CompressPreset: String, CaseIterable, Identifiable {
    case light, balanced, strong

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        }
    }

    var detail: String {
        switch self {
        case .light: return "Better visual quality with moderate file-size savings."
        case .balanced: return "Smaller files with less quality loss."
        case .strong: return "Smaller files with more quality loss."
        }
    }

    var imageQuality: Double {
        switch self {
        case .light: return 0.85
        case .balanced: return 0.7
        case .strong: return 0.5
        }
    }

    /// Share of the original bitrate kept for video and audio.
    var mediaShare: Double {
        switch self {
        case .light: return 0.65
        case .balanced: return 0.45
        case .strong: return 0.3
        }
    }
}

enum CompressTarget: Equatable {
    /// An exact size for each file.
    case bytes(Int64)
    /// Remove this share (0.01…0.99) of each file's size.
    case reduction(Double)

    func bytes(for original: Int64) -> Int64 {
        switch self {
        case .bytes(let value): return value
        case .reduction(let share): return Int64(Double(original) * (1 - share))
        }
    }
}

struct CompressSettings {
    var preset: CompressPreset = .balanced
    /// Longest image edge after compressing; nil keeps the original dimensions.
    var imageMaxPixels: Int?
    /// Tallest video frame after compressing; nil keeps the original height.
    var videoMaxHeight: Int?
    var target: CompressTarget?

    /// The defaults remembered from the last compress window, used by one-step runs.
    @MainActor static var saved: CompressSettings {
        let settings = AppSettings.shared
        return CompressSettings(preset: settings.compressPreset,
                                imageMaxPixels: settings.compressImageMaxPixels,
                                videoMaxHeight: settings.compressVideoMaxHeight)
    }
}

@MainActor
enum Compression {
    // MARK: Images

    static func images(_ files: [URL], _ settings: CompressSettings, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        var before: Int64 = 0
        var after: Int64 = 0
        var skipped = 0
        for (index, url) in files.enumerated() {
            context.report("Compressing \(index + 1) of \(files.count)")
            context.progress(Double(index) / Double(files.count))
            let file = try ImageFile(url)
            let format = ImageOps.compressedFormat(for: file)
            let original = ImageOps.fileSize(url)
            let out = Output.url(for: url, extension: format.ext, suffix: "compressed")
            if let target = settings.target {
                let data = try await fit(file, as: format, within: target.bytes(for: original),
                                         maxPixels: settings.imageMaxPixels)
                try data.write(to: out)
            } else {
                let edit: ImageEdit = settings.imageMaxPixels.map { .resize(maxPixels: $0) } ?? .none
                try await ImageEngine.save(file, as: format, to: out, quality: settings.preset.imageQuality, edit: edit)
                // Re-encoding an already tight file can grow it; keep nothing rather than a bigger copy.
                if settings.imageMaxPixels == nil, ImageOps.fileSize(out) >= original {
                    try? FileManager.default.removeItem(at: out)
                    skipped += 1
                    continue
                }
            }
            before += original
            after += ImageOps.fileSize(out)
            outputs.append(out)
        }
        if outputs.isEmpty, skipped > 0 {
            throw AdawatError.message("Already as small as this preset gets. Try Strong or a target size.")
        }
        context.finish(with: savings("image", count: outputs.count, before: before, after: after))
        return outputs
    }

    /// Finds the highest quality that fits `limit`, shrinking the picture only when even the lowest
    /// quality is too big.
    private static func fit(_ file: ImageFile, as format: ImageFormat, within limit: Int64,
                            maxPixels: Int?) async throws -> Data {
        guard limit >= 1024 else { throw AdawatError.message("Enter a target size of at least 1 KB.") }
        let longest = max(file.uprightSize.width, file.uprightSize.height)
        var pixels = maxPixels.map { min($0, longest) }
        var smallest = Int64.max
        for _ in 0..<8 {
            if let data = try await bestQuality(file, as: format, within: limit, maxPixels: pixels) { return data }
            smallest = min(smallest, Int64(try await ImageEngine.encodedData(file, as: format, quality: 0.05,
                                                                            maxPixels: pixels).count))
            pixels = Int(Double(pixels ?? longest) * 0.8)
            if (pixels ?? 0) < 32 { break }
        }
        throw AdawatError.message("Could not reach the target size. Smallest attempt was \(ByteText.string(smallest)).")
    }

    private static func bestQuality(_ file: ImageFile, as format: ImageFormat, within limit: Int64,
                                    maxPixels: Int?) async throws -> Data? {
        let top = try await ImageEngine.encodedData(file, as: format, quality: 0.95, maxPixels: maxPixels)
        if top.count <= limit { return top }
        var low = 0.05, high = 0.95
        var best: Data?
        for _ in 0..<7 {
            let mid = (low + high) / 2
            let data = try await ImageEngine.encodedData(file, as: format, quality: mid, maxPixels: maxPixels)
            if data.count <= limit {
                best = data
                low = mid
            } else {
                high = mid
            }
        }
        if best == nil {
            let floor = try await ImageEngine.encodedData(file, as: format, quality: 0.05, maxPixels: maxPixels)
            if floor.count <= limit { best = floor }
        }
        return best
    }

    // MARK: Video and audio

    static func videos(_ files: [URL], _ settings: CompressSettings, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        var before: Int64 = 0
        var after: Int64 = 0
        for (index, file) in files.enumerated() {
            context.report("Compressing \(index + 1) of \(files.count)")
            let info = await MediaProbe.info(file)
            guard info.hasVideo, info.duration > 0 else { throw AdawatError.message("\(file.lastPathComponent) has no video track") }
            let audioBits: Double = info.hasAudio ? 128_000 : 0
            var videoBits = videoBitrate(info, settings, audioBits: audioBits)
            let out = Output.url(for: file, extension: "mp4", suffix: "compressed")
            let limit = settings.target?.bytes(for: info.fileSize)
            // Hardware encoders overshoot short clips; with a size target, retry at a proportionally lower rate.
            for attempt in 0..<3 {
                var args = ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                            "-c:v", "hevc_videotoolbox", "-b:v", "\(Int(videoBits))", "-maxrate", "\(Int(videoBits * 1.1))",
                            "-bufsize", "\(Int(videoBits))", "-tag:v", "hvc1"]
                if info.isHighDepth { args += ["-profile:v", "main10", "-pix_fmt", "p010le"] }
                if let height = settings.videoMaxHeight, info.height > height { args += ["-vf", "scale=-2:\(height)"] }
                args += info.hasAudio ? ["-c:a", FFmpeg.aac, "-b:a", "128k"] : []
                args += ["-movflags", "+faststart"]
                if attempt > 0 { context.report("Fitting \(index + 1) of \(files.count) to the target size") }
                do {
                    try await FFmpeg.run(input: file, output: out, arguments: args, duration: info.duration,
                                         progress: context.progressHandler(file: index, of: files.count))
                } catch {
                    try? FileManager.default.removeItem(at: out)
                    throw error
                }
                guard let limit, ImageOps.fileSize(out) > limit, videoBits > 100_000 else { break }
                let overshoot = Double(ImageOps.fileSize(out)) / Double(limit)
                videoBits = max(100_000, videoBits / overshoot * 0.95)
                if attempt == 2 {
                    try? FileManager.default.removeItem(at: out)
                    throw AdawatError.message("Could not fit \(file.lastPathComponent) within \(ByteText.string(limit)). Choose a larger size.")
                }
            }
            // At the lowest bitrate the loop stops early; a file still over the target is no result.
            if let limit, ImageOps.fileSize(out) > limit {
                try? FileManager.default.removeItem(at: out)
                throw AdawatError.message("Could not fit \(file.lastPathComponent) within \(ByteText.string(limit)). Choose a larger size.")
            }
            before += info.fileSize
            after += ImageOps.fileSize(out)
            outputs.append(out)
        }
        context.finish(with: savings("video", count: files.count, before: before, after: after))
        return outputs
    }

    private static func videoBitrate(_ info: MediaInfo, _ settings: CompressSettings, audioBits: Double) -> Double {
        if let target = settings.target {
            let total = Double(target.bytes(for: info.fileSize)) * 8 / info.duration
            return max(150_000, total * 0.97 - audioBits)
        }
        var bits = info.bitrate * settings.preset.mediaShare - audioBits
        // A smaller frame needs proportionally fewer bits for the same look.
        if let height = settings.videoMaxHeight, info.height > height {
            bits *= Double(height * height) / Double(info.height * info.height)
        }
        return max(300_000, bits)
    }

    static func audio(_ files: [URL], _ settings: CompressSettings, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        var before: Int64 = 0
        var after: Int64 = 0
        for (index, file) in files.enumerated() {
            context.report("Compressing \(index + 1) of \(files.count)")
            let info = await MediaProbe.info(file)
            guard info.hasAudio, info.duration > 0 else { throw AdawatError.message("\(file.lastPathComponent) has no audio track") }
            let bitrate = Int(audioBitrate(info, settings))
            let (codec, ext): (String, String) = switch file.pathExtension.lowercased() {
            case "mp3": ("libmp3lame", "mp3")
            case "opus": ("libopus", "opus")
            case "ogg": ("libvorbis", "ogg")
            default: (FFmpeg.aac, "m4a")
            }
            let out = Output.url(for: file, extension: ext, suffix: "compressed")
            do {
                try await FFmpeg.run(input: file, output: out,
                                     arguments: ["-vn", "-map", "0:a:0", "-map_metadata", "0", "-c:a", codec, "-b:a", "\(bitrate)"],
                                     duration: info.duration, progress: context.progressHandler(file: index, of: files.count))
            } catch {
                try? FileManager.default.removeItem(at: out)
                throw error
            }
            before += info.fileSize
            after += ImageOps.fileSize(out)
            outputs.append(out)
        }
        context.finish(with: savings("file", count: files.count, before: before, after: after))
        return outputs
    }

    private static func audioBitrate(_ info: MediaInfo, _ settings: CompressSettings) -> Double {
        if let target = settings.target {
            return min(320_000, max(32_000, Double(target.bytes(for: info.fileSize)) * 8 / info.duration * 0.97))
        }
        return min(320_000, max(64_000, info.bitrate * settings.preset.mediaShare))
    }

    // MARK: Estimates

    /// Expected total size after compressing, or nil when it cannot be predicted.
    static func estimate(_ files: [URL], kind: FileKind, settings: CompressSettings) async -> Int64? {
        switch kind {
        case .image:
            if let target = settings.target {
                return files.reduce(0) { $0 + min(ImageOps.fileSize($1), target.bytes(for: ImageOps.fileSize($1))) }
            }
            // Encode a few files for real and scale up; large selections stay responsive.
            let sample = files.prefix(4)
            var encoded: Int64 = 0
            for url in sample {
                guard let file = try? ImageFile(url),
                      let data = try? await ImageEngine.encodedData(file, as: ImageOps.compressedFormat(for: file),
                                                                   quality: settings.preset.imageQuality,
                                                                   maxPixels: settings.imageMaxPixels) else { return nil }
                encoded += min(Int64(data.count), ImageOps.fileSize(url))
            }
            return encoded * Int64(files.count) / Int64(max(sample.count, 1))
        case .video, .audio:
            var total: Int64 = 0
            for url in files {
                let info = await MediaProbe.info(url)
                guard info.duration > 0 else { return nil }
                if let target = settings.target {
                    total += min(info.fileSize, target.bytes(for: info.fileSize))
                } else if kind == .video {
                    let audioBits: Double = info.hasAudio ? 128_000 : 0
                    total += min(info.fileSize, Int64((videoBitrate(info, settings, audioBits: audioBits) + audioBits) * info.duration / 8))
                } else {
                    total += min(info.fileSize, Int64(audioBitrate(info, settings) * info.duration / 8))
                }
            }
            return total
        default:
            return nil
        }
    }

    private static func savings(_ noun: String, count: Int, before: Int64, after: Int64) -> String {
        let label = "\(count) \(noun)\(count == 1 ? "" : "s")"
        guard before > 0 else { return "Compressed \(label)" }
        let saved = 100 - Int((Double(after) / Double(before) * 100).rounded())
        return saved > 0 ? "Compressed \(label) · \(saved)% smaller" : "Compressed \(label) · already as small as it gets"
    }
}

import AVFoundation
import Foundation

/// A covered area of a video, shown from `start` to `end` seconds.
struct VideoRedaction: Identifiable, Equatable {
    let id = UUID()
    /// Normalized, top-left origin, on the upright picture.
    var rect: CGRect
    var start: Double
    var end: Double
}

enum VisualizerShape: String, CaseIterable, Identifiable {
    case landscape = "Landscape · 16:9", portrait = "Portrait · 9:16", square = "Square · 1:1"

    var id: String { rawValue }

    var size: (width: Int, height: Int) {
        switch self {
        case .landscape: return (1920, 1080)
        case .portrait: return (1080, 1920)
        case .square: return (1080, 1080)
        }
    }
}

@MainActor
extension MediaOps {
    /// Hardware video encoding arguments that keep 10-bit HDR sources in HEVC Main10.
    private static func videoEncoder(_ info: MediaInfo, quality: Int = 72) -> [String] {
        info.isHighDepth
            ? ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-q:v", "\(quality)", "-tag:v", "hvc1"]
            : ["-c:v", "h264_videotoolbox", "-q:v", "\(quality)", "-pix_fmt", "yuv420p"]
    }

    private static func videoOutputExtension(_ file: URL) -> String {
        ["mov", "mp4", "m4v", "mkv"].contains(file.pathExtension.lowercased()) ? file.pathExtension.lowercased() : "mp4"
    }

    private static func number(_ value: Double) -> String { String(format: "%.4f", value) }

    // MARK: Speed

    /// A faster or slower copy. Audio keeps its pitch through chained atempo filters (each 0.5…2).
    static func changeSpeed(_ file: URL, speed: Double, context: OperationContext) async throws -> URL {
        let info = await MediaProbe.info(file)
        let speed = min(max(speed, 0.25), 4)
        var tempo: [String] = []
        var remaining = speed
        while remaining > 2 { tempo.append("atempo=2"); remaining /= 2 }
        while remaining < 0.5 { tempo.append("atempo=0.5"); remaining /= 0.5 }
        tempo.append("atempo=\(number(remaining))")
        var stretched = info
        stretched.duration = info.duration / speed
        let label = speed == speed.rounded() ? "\(Int(speed))x" : String(format: "%gx", speed)
        if info.hasVideo {
            let ext = videoOutputExtension(file)
            let out = Output.url(for: file, extension: ext, suffix: label)
            var args = ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0",
                        "-filter:v", "setpts=PTS/\(number(speed))"] + videoEncoder(info)
            if info.hasAudio { args += ["-filter:a", tempo.joined(separator: ","), "-c:a", FFmpeg.aac, "-b:a", "192k"] }
            if ext == "mp4" || ext == "mov" { args += ["-movflags", "+faststart"] }
            try await encode(file, to: out, arguments: args, info: stretched, progress: context.progressHandler(file: 0, of: 1))
            return out
        }
        let out = Output.url(for: file, extension: file.pathExtension, suffix: label)
        try await encode(file, to: out,
                         arguments: ["-vn", "-map", "0:a:0", "-map_metadata", "0", "-filter:a", tempo.joined(separator: ",")]
                             + audioCodec(forExtension: file.pathExtension, deep: info.audioBits >= 24),
                         info: stretched, progress: context.progressHandler(file: 0, of: 1))
        return out
    }

    // MARK: Crop

    /// Crops to a normalized rectangle of the upright frame, keeping the original audio untouched.
    static func cropVideo(_ files: [URL], rect: CGRect, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        // Expressions on the frame's own size stay right for rotated phone videos; sizes stay even for the encoder.
        let crop = "crop=w=trunc(iw*\(number(rect.width))/2)*2:h=trunc(ih*\(number(rect.height))/2)*2"
            + ":x=trunc(iw*\(number(rect.minX))):y=trunc(ih*\(number(rect.minY)))"
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let info = await MediaProbe.info(file)
            let ext = videoOutputExtension(file)
            let out = Output.url(for: file, extension: ext, suffix: "cropped")
            var args = ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0", "-vf", crop] + videoEncoder(info, quality: 75)
            args += ["-c:a", "copy"]
            if ext == "mp4" || ext == "mov" { args += ["-movflags", "+faststart"] }
            try await encode(file, to: out, arguments: args, info: info, progress: context.progressHandler(file: index, of: files.count))
            outputs.append(out)
        }
        return outputs
    }

    // MARK: Split

    /// Cuts the video at `points`. Kept clips go into one folder, or are joined back into a single video.
    static func split(_ file: URL, points: [Double], removed: Set<Int>, joinKept: Bool,
                      context: OperationContext) async throws -> [URL] {
        let info = await MediaProbe.info(file)
        let bounds = [0] + points.sorted().filter { $0 > 0.05 && $0 < info.duration - 0.05 } + [info.duration]
        let segments = (0..<(bounds.count - 1)).map { (index: $0, start: bounds[$0], end: bounds[$0 + 1]) }
            .filter { !removed.contains($0.index) }
        guard !segments.isEmpty else { throw AdawatError.message("Keep at least one clip.") }
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension.lowercased()

        if joinKept {
            let staging = Output.temporaryURL(extension: "").deletingPathExtension()
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            var parts: [URL] = []
            for (order, segment) in segments.enumerated() {
                try Task.checkCancellation()
                context.report("Cutting clip \(order + 1) of \(segments.count)")
                let part = staging.appendingPathComponent("part \(order).\(ext)")
                try await cutSegment(file, start: segment.start, end: segment.end, to: part, info: info,
                                     progress: context.progressHandler(file: order, of: segments.count + 1))
                parts.append(part)
            }
            context.report("Joining \(parts.count) clips")
            let out = Output.url(for: file, extension: videoOutputExtension(file), suffix: "edited")
            if parts.count == 1 {
                try FileManager.default.moveItem(at: parts[0], to: out)
            } else {
                let joined = try await join(parts, context: context)
                try FileManager.default.moveItem(at: joined[0], to: out)
            }
            return [out]
        }

        let folder = Output.url(named: "\(base) clips", near: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (order, segment) in segments.enumerated() {
            try Task.checkCancellation()
            context.report("Saving clip \(order + 1) of \(segments.count)")
            let out = folder.appendingPathComponent(String(format: "%@ %02d.%@", base, order + 1, ext))
            try await cutSegment(file, start: segment.start, end: segment.end, to: out, info: info,
                                 progress: context.progressHandler(file: order, of: segments.count))
        }
        context.finish(with: "Saved \(segments.count) clip\(segments.count == 1 ? "" : "s")")
        return [folder]
    }

    // MARK: Frames

    /// Full-resolution PNGs at exact times; several go into a folder.
    static func saveFrames(_ file: URL, times: [Double], context: OperationContext) async throws -> [URL] {
        guard !times.isEmpty else { throw AdawatError.message("Add a frame to save.") }
        let base = file.deletingPathExtension().lastPathComponent
        let folder: URL? = times.count > 1 ? Output.url(named: "\(base) frames", near: file) : nil
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var outputs: [URL] = []
        for (index, time) in times.sorted().enumerated() {
            try Task.checkCancellation()
            context.progress(Double(index) / Double(times.count))
            let name = String(format: "Frame %03d - %.3fs.png", index + 1, time)
            let out = folder?.appendingPathComponent(name) ?? Output.url(for: file, extension: "png", suffix: String(format: "%.3fs", time))
            if let (image, _) = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                try ImageEngine.write(image, as: .png, to: out, quality: 1, metadata: [:])
            } else {
                try await encode(file, to: out, arguments: ["-frames:v", "1"], inputOptions: ["-ss", number(time)],
                                 info: MediaInfo(), progress: { _ in })
            }
            if folder == nil { outputs.append(out) }
        }
        return folder.map { [$0] } ?? outputs
    }

    // MARK: Redact

    /// Covers each area for its time range: a filled box, or a pixelated blur.
    static func redactVideo(_ file: URL, redactions: [VideoRedaction], blur: Bool, color: RGB,
                            context: OperationContext) async throws -> URL {
        guard !redactions.isEmpty else { throw AdawatError.message("Draw at least one redaction.") }
        let info = await MediaProbe.info(file)
        func enable(_ r: VideoRedaction) -> String { "between(t\\,\(number(r.start))\\,\(number(r.end)))" }
        var graph: String
        if blur {
            graph = "[0:v]null[v0];"
            for (index, r) in redactions.enumerated() {
                let rect = r.rect
                graph += "[v\(index)]split[b\(index)][c\(index)];"
                    + "[c\(index)]crop=w=iw*\(number(rect.width)):h=ih*\(number(rect.height))"
                    + ":x=iw*\(number(rect.minX)):y=ih*\(number(rect.minY)),"
                    + "scale=w=max(2\\,trunc(iw/16)):h=max(2\\,trunc(ih/16)),scale=w=iw*16:h=ih*16:flags=neighbor,boxblur=4[p\(index)];"
                    + "[b\(index)][p\(index)]overlay=x=main_w*\(number(rect.minX)):y=main_h*\(number(rect.minY))"
                    + ":enable='\(enable(r))'[v\(index + 1)];"
            }
            graph += "[v\(redactions.count)]format=yuv420p[out]"
        } else {
            let hex = String(format: "0x%02X%02X%02X", Int(color.red * 255), Int(color.green * 255), Int(color.blue * 255))
            let boxes = redactions.map { r in
                "drawbox=x=iw*\(number(r.rect.minX)):y=ih*\(number(r.rect.minY)):w=iw*\(number(r.rect.width))"
                    + ":h=ih*\(number(r.rect.height)):color=\(hex)@1:t=fill:enable='\(enable(r))'"
            }
            graph = "[0:v]" + boxes.joined(separator: ",") + ",format=yuv420p[out]"
        }
        let ext = videoOutputExtension(file)
        let out = Output.url(for: file, extension: ext, suffix: "redacted")
        // A redacted copy should not reveal where it was filmed either.
        var args = ["-filter_complex", graph, "-map", "[out]", "-map", "0:a?", "-map_metadata", "-1"]
            + videoEncoder(info, quality: 75) + ["-c:a", "copy"]
        if ext == "mp4" || ext == "mov" { args += ["-movflags", "+faststart"] }
        if info.isHighDepth { args = args.map { $0 == "format=yuv420p[out]" ? "format=p010le[out]" : $0 } }
        try await encode(file, to: out, arguments: args, info: info, progress: context.progressHandler(file: 0, of: 1))
        return out
    }

    // MARK: Loudness

    static func normalize(_ file: URL, target: Double, range: Double, peak: Double, context: OperationContext) async throws -> URL {
        let info = await MediaProbe.info(file)
        guard info.hasAudio else { throw AdawatError.message("This file has no audio track.") }
        let settings = "I=\(number(target)):TP=\(number(peak)):LRA=\(number(range))"
        context.report("Measuring loudness")
        var filter = "loudnorm=\(settings)"
        if let measured = try await measureLoudness(file, target: settings) {
            filter += ":measured_I=\(measured.i):measured_TP=\(measured.tp):measured_LRA=\(measured.lra)"
                + ":measured_thresh=\(measured.thresh):offset=\(measured.offset):linear=true"
        }
        context.report("Normalizing")
        let ext = file.pathExtension.isEmpty ? "m4a" : file.pathExtension
        var args = ["-map", "0:v?", "-map", "0:a", "-map_metadata", "0", "-af", filter, "-ar", "48000"]
        if info.hasVideo { args += ["-c:v", "copy"] }
        args += audioCodec(forExtension: ext, deep: info.audioBits >= 24)
        let out = Output.url(for: file, extension: ext, suffix: "normalized")
        try await encode(file, to: out, arguments: args, info: info, progress: context.progressHandler(file: 0, of: 1))
        return out
    }

    // MARK: Visualizer

    /// An MP4 of the audio over an animated waveform, or over a still image.
    static func visualize(_ file: URL, image: URL?, shape: VisualizerShape, color: RGB,
                          context: OperationContext) async throws -> URL {
        let info = await MediaProbe.info(file)
        guard info.hasAudio else { throw AdawatError.message("This file has no playable audio.") }
        let (w, h) = shape.size
        let out = Output.url(for: file, extension: "mp4", suffix: "visualizer")
        let hex = String(format: "0x%02X%02X%02X", Int(color.red * 255), Int(color.green * 255), Int(color.blue * 255))
        let ffmpeg = try ExternalTool.ffmpeg.require()
        var args: [String]
        if let image {
            args = ["-loop", "1", "-framerate", "15", "-i", image.path, "-i", file.path, "-filter_complex",
                    "[0:v]scale=\(w):\(h):force_original_aspect_ratio=decrease:force_divisible_by=2,format=rgba,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,format=yuv420p[v]",
                    "-map", "[v]", "-map", "1:a:0"]
        } else {
            // draw=full paints the chosen colour as is; the default blending adds overlapping samples until the colour overflows.
            let waveWidth = (w - w / 8) / 2 * 2, waveHeight = h / 3 / 2 * 2
            args = ["-i", file.path, "-filter_complex",
                    "[0:a]showwaves=s=\(waveWidth)x\(waveHeight):mode=cline:rate=30:colors=\(hex):scale=sqrt:draw=full,"
                        + "format=rgba,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black,format=yuv420p[v]",
                    "-map", "[v]", "-map", "0:a:0"]
        }
        args += ["-c:v", "h264_videotoolbox", "-q:v", "65", "-c:a", FFmpeg.aac, "-b:a", "192k", "-shortest",
                 "-movflags", "+faststart", out.path]
        _ = ffmpeg
        do {
            try await FFmpeg.run(arguments: args, duration: info.duration, progress: context.progressHandler(file: 0, of: 1))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    // MARK: Channels

    /// The pan filter for a mono or stereo result with per-side volume; `solo` previews one source channel.
    static func channelFilter(_ info: MediaInfo, mono: Bool, left: Double, right: Double, solo: Int? = nil) -> String {
        let stereoSource = info.audioChannels >= 2
        guard stereoSource else {
            // One source channel: a term may not name it twice, so the two sides' gains are combined.
            if solo != nil { return "pan=mono|c0=c0" }
            if mono { return "pan=mono|c0=\(number((left + right) / 2))*c0" }
            return "pan=stereo|c0=\(number(left))*c0|c1=\(number(right))*c0"
        }
        if let solo { return "pan=mono|c0=c\(solo == 0 ? 0 : 1)" }
        if mono { return "pan=mono|c0=\(number(left * 0.5))*c0+\(number(right * 0.5))*c1" }
        return "pan=stereo|c0=\(number(left))*c0|c1=\(number(right))*c1"
    }

    static func convertChannels(_ file: URL, mono: Bool, left: Double, right: Double, context: OperationContext) async throws -> URL {
        let info = await MediaProbe.info(file)
        guard info.hasAudio else { throw AdawatError.message("Choose Mono or Stereo for a file with an audio track.") }
        var args = ["-map", "0:v?", "-map", "0:a:0", "-map_metadata", "0", "-af", channelFilter(info, mono: mono, left: left, right: right)]
        if info.hasVideo { args += ["-c:v", "copy"] }
        args += audioCodec(forExtension: file.pathExtension, deep: info.audioBits >= 24)
        let out = Output.url(for: file, extension: file.pathExtension, suffix: mono ? "mono" : "stereo")
        try await encode(file, to: out, arguments: args, info: info, progress: context.progressHandler(file: 0, of: 1))
        return out
    }

    // MARK: Bleep

    static func bleepFilter(_ ranges: [ClosedRange<Double>], duration: Double) -> String {
        let windows = ranges.map { "between(t\\,\(number($0.lowerBound))\\,\(number($0.upperBound)))" }.joined(separator: "+")
        return "[0:a:0]aresample=48000,volume=0:enable='\(windows)'[muted];"
            + "sine=frequency=1000:sample_rate=48000:duration=\(number(duration)),volume=0.3,"
            + "volume=0:enable='not(\(windows))'[tone];"
            + "[muted][tone]amix=inputs=2:duration=first:normalize=0[a]"
    }

    /// Replaces each range with a 1 kHz tone; video, if any, is copied untouched.
    static func bleep(_ file: URL, ranges: [ClosedRange<Double>], to target: URL? = nil, context: OperationContext?) async throws -> URL {
        guard !ranges.isEmpty else { throw AdawatError.message("Add at least one bleep range.") }
        let info = await MediaProbe.info(file)
        guard info.hasAudio else { throw AdawatError.message("This file has no audio track.") }
        let ext = target?.pathExtension ?? file.pathExtension
        let out = target ?? Output.url(for: file, extension: ext, suffix: "bleeped")
        var args = ["-filter_complex", bleepFilter(ranges, duration: info.duration), "-map", "0:v?", "-map", "[a]", "-map_metadata", "0"]
        if info.hasVideo, target == nil { args += ["-c:v", "copy"] }
        args += audioCodec(forExtension: ext, deep: info.audioBits >= 24)
        try await encode(file, to: out, arguments: args, info: info, progress: context?.progressHandler(file: 0, of: 1) ?? { _ in })
        return out
    }

    /// A short temporary rendering for in-window previews (channel output, bleeps).
    static func previewAudio(_ file: URL, filter: String, complex: Bool) async throws -> URL {
        let out = Output.temporaryURL(extension: "m4a")
        let args = (complex ? ["-filter_complex", filter, "-map", "[a]"] : ["-vn", "-map", "0:a:0", "-af", filter])
            + ["-c:a", FFmpeg.aac, "-b:a", "160k"]
        try await encode(file, to: out, arguments: args, info: MediaInfo(), progress: { _ in })
        return out
    }
}

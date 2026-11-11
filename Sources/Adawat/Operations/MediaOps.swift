import AVFoundation
import Foundation

struct MediaFormat: Hashable {
    let name: String
    let ext: String
    let audioOnly: Bool

    static let mp4 = MediaFormat(name: "MP4", ext: "mp4", audioOnly: false)
    static let mov = MediaFormat(name: "MOV", ext: "mov", audioOnly: false)
    static let mkv = MediaFormat(name: "MKV", ext: "mkv", audioOnly: false)
    static let webm = MediaFormat(name: "WebM", ext: "webm", audioOnly: false)
    static let gif = MediaFormat(name: "GIF", ext: "gif", audioOnly: false)
    static let mp3 = MediaFormat(name: "MP3", ext: "mp3", audioOnly: true)
    static let m4a = MediaFormat(name: "M4A", ext: "m4a", audioOnly: true)
    static let wav = MediaFormat(name: "WAV", ext: "wav", audioOnly: true)
    static let flac = MediaFormat(name: "FLAC", ext: "flac", audioOnly: true)
    static let aiff = MediaFormat(name: "AIFF", ext: "aiff", audioOnly: true)
    static let ogg = MediaFormat(name: "OGG", ext: "ogg", audioOnly: true)
    static let opus = MediaFormat(name: "Opus", ext: "opus", audioOnly: true)

    static let video: [MediaFormat] = [.mp4, .mov, .mkv, .webm, .gif, .mp3, .m4a]
    static let audio: [MediaFormat] = [.mp3, .m4a, .wav, .flac, .aiff, .ogg, .opus]
}

@MainActor
enum MediaOps {
    // MARK: Conversion

    /// Codecs each container can hold as-is, so converting only re-wraps the streams: instant and lossless.
    private static let copyableVideo: [String: Set<String>] = [
        "mp4": ["h264", "hevc"],
        "mov": ["h264", "hevc", "prores", "mjpeg"],
        "mkv": ["h264", "hevc", "vp9", "av1", "prores", "mpeg4"],
        "webm": ["vp9", "av1"],
    ]
    private static let copyableAudio: [String: Set<String>] = [
        "mp4": ["aac", "alac", "mp3"],
        "mov": ["aac", "alac", "mp3", "pcm"],
        "mkv": ["aac", "alac", "mp3", "pcm", "opus", "flac", "ac3", "eac3", "vorbis"],
        "webm": ["opus", "vorbis"],
    ]

    /// VideoToolbox quality (1…100) for each quality setting.
    private static var hardwareQuality: Int {
        switch AppSettings.shared.videoQuality {
        case .high: return 75
        case .balanced: return 65
        case .small: return 50
        }
    }

    static func conversionArguments(_ format: MediaFormat, _ info: MediaInfo) throws -> [String] {
        if format.audioOnly { return try audioArguments(format, info) }
        if format == .gif {
            guard info.hasVideo else { throw AdawatError.message("This file has no video track") }
            return ["-an", "-vf",
                    "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0"]
        }
        guard info.hasVideo else { throw AdawatError.message("This file has no video track") }
        let container = format.ext
        let keepVideo = copyableVideo[container]?.contains(info.videoCodec ?? "") ?? false
        let keepAudio = !info.hasAudio || (copyableAudio[container]?.contains(info.audioCodec ?? "") ?? false)

        var args = ["-map", "0:v:0", "-map", "0:a?", "-map_metadata", "0"]
        if keepVideo {
            args += ["-c:v", "copy"]
            if info.videoCodec == "hevc", container != "mkv" { args += ["-tag:v", "hvc1"] }
            // iPhone HDR adds a Dolby Vision box that ffmpeg only keeps in "unofficial" mode.
            args += ["-strict", "unofficial"]
        } else if container == "webm" {
            args += ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
        } else if info.isHighDepth {
            // Keep 10-bit HDR as HEVC Main10, the format the iPhone itself records.
            args += ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le",
                     "-q:v", "\(hardwareQuality)", "-tag:v", "hvc1"]
        } else {
            args += ["-c:v", "h264_videotoolbox", "-q:v", "\(hardwareQuality)", "-pix_fmt", "yuv420p"]
        }
        if keepAudio {
            args += ["-c:a", "copy"]
        } else if container == "webm" {
            args += ["-c:a", "libopus", "-b:a", "128k"]
        } else {
            args += ["-c:a", FFmpeg.aac, "-b:a", "192k"]
        }
        if container == "mp4" || container == "mov" { args += ["-movflags", "+faststart"] }
        return args
    }

    private static func audioArguments(_ format: MediaFormat, _ info: MediaInfo) throws -> [String] {
        guard info.hasAudio else { throw AdawatError.message("This file has no audio track") }
        let source = info.audioCodec ?? ""
        let deep = info.audioBits >= 24
        var args = ["-vn", "-map", "0:a:0", "-map_metadata", "0"]
        switch format.ext {
        case "m4a": args += ["alac", "aac"].contains(source) ? ["-c:a", "copy"] : ["-c:a", FFmpeg.aac, "-b:a", "256k"]
        case "mp3": args += source == "mp3" ? ["-c:a", "copy"] : ["-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": args += ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"]
        case "aiff": args += ["-c:a", deep ? "pcm_s24be" : "pcm_s16be"]
        case "flac": args += source == "flac" ? ["-c:a", "copy"] : ["-c:a", "flac"]
        case "ogg": args += source == "vorbis" ? ["-c:a", "copy"] : ["-c:a", "libvorbis", "-q:a", "5"]
        case "opus": args += source == "opus" ? ["-c:a", "copy"] : ["-c:a", "libopus", "-b:a", "160k"]
        default: break
        }
        return args
    }

    static func convert(_ files: [URL], to format: MediaFormat, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            context.report("Converting \(index + 1) of \(files.count) to \(format.name)")
            let info = await MediaProbe.info(file)
            let out = Output.url(for: file, extension: format.ext)
            try await encode(file, to: out, arguments: try conversionArguments(format, info), info: info,
                             progress: context.progressHandler(file: index, of: files.count))
            outputs.append(out)
        }
        return outputs
    }

    /// Runs ffmpeg and removes a half-written output if it fails.
    static func encode(_ file: URL, to out: URL, arguments: [String], inputOptions: [String] = [],
                               info: MediaInfo, progress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            try await FFmpeg.run(input: file, output: out, arguments: arguments, inputOptions: inputOptions,
                                 duration: info.duration, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
    }

    // MARK: Lossless edits

    static func mute(_ files: [URL], context: OperationContext) async throws -> [URL] {
        try await streamCopy(files, suffix: "muted", context: context, arguments: ["-map", "0:v", "-c", "copy", "-an"])
    }

    /// Strips container tags, chapters and the timed-metadata tracks where phones store location.
    static func stripMetadata(_ files: [URL], context: OperationContext) async throws -> [URL] {
        let outputs = try await streamCopy(files, suffix: "clean", context: context, arguments: [
            "-map", "0:v?", "-map", "0:a?", "-map_metadata", "-1", "-map_chapters", "-1",
            "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", "-c", "copy",
        ])
        context.finish(with: "Metadata removed from \(files.count) file\(files.count == 1 ? "" : "s")")
        return outputs
    }

    private static func streamCopy(_ files: [URL], suffix: String, context: OperationContext,
                                   arguments: [String]) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let info = await MediaProbe.info(file)
            let out = Output.url(for: file, extension: file.pathExtension, suffix: suffix)
            try await encode(file, to: out, arguments: arguments, info: info,
                             progress: context.progressHandler(file: index, of: files.count))
            outputs.append(out)
        }
        return outputs
    }

    /// Turns the video 90° clockwise by changing its display rotation, without re-encoding.
    static func rotate(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            try Task.checkCancellation()
            let out = Output.url(for: file, extension: file.pathExtension, suffix: "rotated")
            if let type = passthroughTypes[file.pathExtension.lowercased()] {
                try await rotateWithAVFoundation(file, to: out, type: type)
            } else {
                // Other containers: ffmpeg rewrites the rotation tag while copying the streams.
                let info = await MediaProbe.info(file)
                try await encode(file, to: out, arguments: ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"],
                                 inputOptions: ["-display_rotation:v:0", "-90"], info: info, progress: { _ in })
            }
            outputs.append(out)
        }
        return outputs
    }

    private static let passthroughTypes: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v]

    private static func rotateWithAVFoundation(_ file: URL, to out: URL, type: AVFileType) async throws {
        let asset = AVURLAsset(url: file)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            guard let copy = composition.addMutableTrack(withMediaType: track.mediaType,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            if track.mediaType == .video {
                let size = try await track.load(.naturalSize)
                var transform = try await track.load(.preferredTransform)
                    .concatenating(CGAffineTransform(rotationAngle: .pi / 2))
                // Move the rotated frame back so it starts at the origin.
                let box = CGRect(origin: .zero, size: size).applying(transform)
                transform = transform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY))
                copy.preferredTransform = transform
            }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw AdawatError.message("Could not prepare \(file.lastPathComponent) for rotation")
        }
        session.metadata = try await asset.load(.metadata)
        if #available(macOS 15.0, *) {
            try await session.export(to: out, as: type)
        } else {
            session.outputURL = out
            session.outputFileType = type
            await session.export()
            if let error = session.error { throw error }
        }
    }

    // MARK: Join

    /// Plays the clips one after another in a single MP4. Matching H.264/HEVC clips are joined without
    /// re-encoding; mixed clips are fitted onto the first clip's frame and encoded on the hardware encoder.
    static func join(_ files: [URL], context: OperationContext) async throws -> [URL] {
        guard files.count >= 2 else { throw AdawatError.message("Select at least two videos to join.") }
        var infos: [MediaInfo] = []
        for file in files { infos.append(await MediaProbe.info(file)) }
        guard infos.allSatisfy(\.hasVideo) else { throw AdawatError.message("Every selected file must contain a video track.") }
        let first = infos[0]
        let total = infos.reduce(0) { $0 + $1.duration }
        let out = Output.url(named: "\(files[0].deletingPathExtension().lastPathComponent) joined.mp4", near: files[0])

        let sameShape = infos.allSatisfy {
            $0.videoCodec == first.videoCodec && $0.width == first.width && $0.height == first.height
                && $0.audioCodec == first.audioCodec && $0.isHighDepth == first.isHighDepth
        }
        if sameShape, ["h264", "hevc"].contains(first.videoCodec ?? ""), [nil, "aac"].contains(first.audioCodec) {
            context.report("Joining \(files.count) videos")
            let list = Output.temporaryURL(extension: "txt")
            defer { try? FileManager.default.removeItem(at: list) }
            let lines = files.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            var args = ["-f", "concat", "-safe", "0", "-i", list.path, "-map", "0:v", "-map", "0:a?", "-c", "copy"]
            if first.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
            args += ["-movflags", "+faststart", out.path]
            do {
                try await FFmpeg.run(arguments: args, duration: total, progress: context.progressHandler(file: 0, of: 1))
                return [out]
            } catch {
                // Streams that look alike can still disagree in detail; fall through to re-encoding.
                try? FileManager.default.removeItem(at: out)
                DebugLog.write("lossless join failed, re-encoding: \(error.localizedDescription)")
            }
        }

        context.report("Encoding \(files.count) videos into one")
        let width = first.width > 0 ? first.width : 1920, height = first.height > 0 ? first.height : 1080
        var inputs: [String] = []
        var graph = ""
        var silentInputs = files.count
        for (index, file) in files.enumerated() {
            inputs += ["-i", file.path]
            graph += "[\(index):v]scale=\(width):\(height):force_original_aspect_ratio=decrease,"
                + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(index)];"
        }
        // Clips without sound get matching silence so the audio stays in step with the pictures.
        for (index, info) in infos.enumerated() {
            if info.hasAudio {
                graph += "[\(index):a]aformat=sample_rates=48000:channel_layouts=stereo,asetpts=PTS-STARTPTS[a\(index)];"
            } else {
                inputs += ["-f", "lavfi", "-t", String(format: "%.3f", info.duration), "-i", "anullsrc=r=48000:cl=stereo"]
                graph += "[\(silentInputs):a]asetpts=PTS-STARTPTS[a\(index)];"
                silentInputs += 1
            }
        }
        graph += (0..<files.count).map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(files.count):v=1:a=1[v][a]"
        let highDepth = infos.contains(where: \.isHighDepth)
        let video = highDepth
            ? ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-q:v", "70", "-tag:v", "hvc1"]
            : ["-c:v", "h264_videotoolbox", "-q:v", "70"]
        let args = inputs + ["-filter_complex", graph.replacingOccurrences(of: "format=yuv420p", with: highDepth ? "format=p010le" : "format=yuv420p"),
                             "-map", "[v]", "-map", "[a]"] + video + ["-c:a", FFmpeg.aac, "-b:a", "192k", "-movflags", "+faststart", out.path]
        do {
            try await FFmpeg.run(arguments: args, duration: total, progress: context.progressHandler(file: 0, of: 1))
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return [out]
    }

    // MARK: Trim

    /// Keeps `start…end`. MOV/MP4/M4A are cut by AVFoundation without re-encoding and land on the exact
    /// frame; other containers are stream-copied by ffmpeg. Trimming silence re-encodes the audio.
    static func trim(_ file: URL, start: Double, end: Double, trimSilence: Bool, context: OperationContext) async throws -> URL {
        let ext = file.pathExtension.lowercased()
        let out = Output.url(for: file, extension: ext, suffix: "trimmed")
        let info = await MediaProbe.info(file)
        let length = max(0.05, end - start)
        let window = ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", length)]
        var clipped = info
        clipped.duration = length
        if trimSilence {
            let edge = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.1"
            try await encode(file, to: out,
                             arguments: ["-vn", "-map", "0:a:0", "-map_metadata", "0", "-af", "\(edge),areverse,\(edge),areverse"]
                                 + audioCodec(forExtension: ext, deep: info.audioBits >= 24),
                             inputOptions: window, info: clipped, progress: context.progressHandler(file: 0, of: 1))
            return out
        }
        try await cutSegment(file, start: start, end: end, to: out, info: info, progress: context.progressHandler(file: 0, of: 1))
        return out
    }

    /// Writes `start…end` of `file` to `out`: AVFoundation passthrough (exact and lossless) for MOV/MP4/M4A,
    /// a stream copy for audio-only files, and a frame-accurate hardware re-encode for other video.
    static func cutSegment(_ file: URL, start: Double, end: Double, to out: URL, info: MediaInfo,
                           progress: @escaping @Sendable (Double) -> Void) async throws {
        let ext = file.pathExtension.lowercased()
        let types: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v, "m4a": .m4a]
        if let type = types[ext] {
            let asset = AVURLAsset(url: file)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw AdawatError.message("Could not prepare \(file.lastPathComponent) for cutting")
            }
            session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                            end: CMTime(seconds: end, preferredTimescale: 600))
            if #available(macOS 15.0, *) {
                try await session.export(to: out, as: type)
            } else {
                session.outputURL = out
                session.outputFileType = type
                await session.export()
                if let error = session.error { throw error }
            }
            return
        }
        let length = max(0.05, end - start)
        var clipped = info
        clipped.duration = length
        var args = ["-map", "0:v?", "-map", "0:a?", "-map_metadata", "0"]
        if info.hasVideo {
            args += info.isHighDepth
                ? ["-c:v", "hevc_videotoolbox", "-profile:v", "main10", "-pix_fmt", "p010le", "-q:v", "80"]
                : ["-c:v", ext == "webm" ? "libvpx-vp9" : "h264_videotoolbox", "-q:v", "80"]
            if ext == "webm" { args += ["-b:v", "0", "-crf", "30", "-row-mt", "1"] }
            args += ext == "webm" ? ["-c:a", "libopus", "-b:a", "160k"] : ["-c:a", FFmpeg.aac, "-b:a", "192k"]
        } else {
            args += ["-c", "copy"]
        }
        try await encode(file, to: out, arguments: args,
                         inputOptions: ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", length)],
                         info: clipped, progress: progress)
    }

    /// Peak levels (0…1) across the file for drawing a waveform, decoded at a low rate by ffmpeg.
    nonisolated static func waveform(_ file: URL, bars: Int, channel: Int? = nil) async -> [Float] {
        let mix = channel.map { ["-af", "pan=mono|c0=c\($0)"] } ?? ["-ac", "1"]
        guard let ffmpeg = ExternalTool.ffmpeg.url,
              let result = try? await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", file.path, "-vn"]
                                                            + mix + ["-ar", "4000", "-f", "f32le", "-"]) else { return [] }
        let samples = result.stdout.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !samples.isEmpty, bars > 0 else { return [] }
        let chunk = max(1, samples.count / bars)
        var peaks: [Float] = []
        var index = 0
        while index < samples.count, peaks.count < bars {
            let slice = samples[index..<min(index + chunk, samples.count)]
            peaks.append(slice.reduce(0) { max($0, abs($1)) })
            index += chunk
        }
        let top = peaks.max() ?? 1
        return top > 0 ? peaks.map { $0 / top } : peaks
    }

    // MARK: Audio tools

    /// Two-pass EBU R128 normalization to -16 LUFS / -1.5 dBTP: the first pass measures the file so the
    /// second can hit the target exactly instead of estimating it on the fly.
    static func normalize(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            context.report("Measuring loudness \(index + 1) of \(files.count)")
            let info = await MediaProbe.info(file)
            guard info.hasAudio else { throw AdawatError.message("\(file.lastPathComponent) has no audio track") }
            let target = "I=-16:TP=-1.5:LRA=11"
            var filter = "loudnorm=\(target)"
            if let measured = try await measureLoudness(file, target: target) {
                filter += ":measured_I=\(measured.i):measured_TP=\(measured.tp):measured_LRA=\(measured.lra)"
                    + ":measured_thresh=\(measured.thresh):offset=\(measured.offset):linear=true"
            }
            context.report("Normalizing \(index + 1) of \(files.count)")
            let ext = info.hasVideo || !file.pathExtension.isEmpty ? file.pathExtension : "m4a"
            var args = ["-map", "0:v?", "-map", "0:a", "-map_metadata", "0", "-af", filter]
            if info.hasVideo { args += ["-c:v", "copy"] }
            args += audioCodec(forExtension: ext, deep: info.audioBits >= 24)
            // loudnorm works at 192 kHz internally; return to a standard rate.
            args += ["-ar", "48000"]
            let out = Output.url(for: file, extension: ext, suffix: "normalized")
            try await encode(file, to: out, arguments: args, info: info,
                             progress: context.progressHandler(file: index, of: files.count))
            outputs.append(out)
        }
        return outputs
    }

    struct Loudness: Decodable {
        let i, tp, lra, thresh, offset: String

        enum CodingKeys: String, CodingKey {
            case i = "input_i", tp = "input_tp", lra = "input_lra", thresh = "input_thresh", offset = "target_offset"
        }
    }

    static func measureLoudness(_ file: URL, target: String) async throws -> Loudness? {
        let ffmpeg = try ExternalTool.ffmpeg.require()
        let result = try await ProcessRunner.run(ffmpeg, ["-hide_banner", "-nostdin", "-i", file.path, "-vn",
                                                          "-af", "loudnorm=\(target):print_format=json", "-f", "null", "-"])
        guard let start = result.stderr.lastIndex(of: "{"), let end = result.stderr.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(Loudness.self, from: Data(result.stderr[start...end].utf8))
    }

    static func toMono(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let info = await MediaProbe.info(file)
            guard info.hasAudio else { throw AdawatError.message("\(file.lastPathComponent) has no audio track") }
            var args = ["-map", "0:v?", "-map", "0:a", "-map_metadata", "0", "-ac", "1"]
            if info.hasVideo { args += ["-c:v", "copy"] }
            args += audioCodec(forExtension: file.pathExtension, deep: info.audioBits >= 24)
            let out = Output.url(for: file, extension: file.pathExtension, suffix: "mono")
            try await encode(file, to: out, arguments: args, info: info,
                             progress: context.progressHandler(file: index, of: files.count))
            outputs.append(out)
        }
        return outputs
    }

    /// Cuts leading and trailing silence quieter than -45 dB.
    static func trimSilence(_ files: [URL], context: OperationContext) async throws -> [URL] {
        let edge = "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.1"
        let filter = "\(edge),areverse,\(edge),areverse"
        var outputs: [URL] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            let info = await MediaProbe.info(file)
            let out = Output.url(for: file, extension: file.pathExtension, suffix: "trimmed")
            try await encode(file, to: out,
                             arguments: ["-vn", "-map", "0:a:0", "-map_metadata", "0", "-af", filter]
                                 + audioCodec(forExtension: file.pathExtension, deep: info.audioBits >= 24),
                             info: info, progress: context.progressHandler(file: index, of: files.count))
            outputs.append(out)
        }
        return outputs
    }

    static func audioCodec(forExtension ext: String, deep: Bool) -> [String] {
        switch ext.lowercased() {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "mp4", "mov", "m4v", "aac": return ["-c:a", FFmpeg.aac, "-b:a", "192k"]
        case "wav": return ["-c:a", deep ? "pcm_s24le" : "pcm_s16le"]
        case "aif", "aiff": return ["-c:a", deep ? "pcm_s24be" : "pcm_s16be"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libvorbis", "-q:a", "5"]
        case "webm", "opus", "mkv": return ["-c:a", "libopus", "-b:a", "160k"]
        default: return []
        }
    }

    // MARK: Frames

    /// A full-resolution still from the middle of each video, decoded exactly at that time.
    static func snapshot(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            try Task.checkCancellation()
            let info = await MediaProbe.info(file)
            let time = info.duration / 2
            let out = Output.url(for: file, extension: "png", suffix: "frame")
            if passthroughTypes[file.pathExtension.lowercased()] != nil {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                try ImageEngine.write(image, as: .png, to: out, quality: 1, metadata: [:])
            } else {
                try await encode(file, to: out, arguments: ["-frames:v", "1"],
                                 inputOptions: ["-ss", String(format: "%.3f", time)], info: info, progress: { _ in })
            }
            outputs.append(out)
        }
        return outputs
    }
}

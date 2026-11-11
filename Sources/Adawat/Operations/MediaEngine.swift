import AVFoundation
import Foundation

/// What a media file contains, read with AVFoundation (no ffprobe needed), falling back to
/// ffmpeg's own stream report for containers AVFoundation cannot open (MKV, WebM, AVI…).
struct MediaInfo {
    var duration: Double = 0
    var videoCodec: String?
    var audioCodec: String?
    /// Sample size of PCM audio, so lossless conversions keep 24-bit sources at 24 bits.
    var audioBits = 0
    var audioChannels = 0
    /// 10/12-bit or HLG/PQ video, such as iPhone HDR or ProRes, which must not be squeezed into 8-bit H.264.
    var isHighDepth = false
    var width = 0
    var height = 0
    var fileSize: Int64 = 0

    var hasVideo: Bool { videoCodec != nil }
    var hasAudio: Bool { audioCodec != nil }
    /// Average bits per second of the whole file.
    var bitrate: Double { duration > 0 ? Double(fileSize) * 8 / duration : 0 }
}

enum MediaProbe {
    static func info(_ url: URL) async -> MediaInfo {
        var info = await avInfo(url) ?? ffmpegInfo(url)
        info.fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return info
    }

    private static func avInfo(_ url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.load(.tracks), !tracks.isEmpty else { return nil }
        var info = MediaInfo()
        if let duration = try? await asset.load(.duration) { info.duration = duration.seconds.isFinite ? duration.seconds : 0 }
        for track in tracks {
            guard let format = (try? await track.load(.formatDescriptions))?.first else { continue }
            let fourCC = fourCharacterCode(CMFormatDescriptionGetMediaSubType(format))
            switch track.mediaType {
            case .video where info.videoCodec == nil:
                info.videoCodec = videoCodecs[fourCC] ?? fourCC
                let dimensions = CMVideoFormatDescriptionGetDimensions(format)
                info.width = Int(dimensions.width)
                info.height = Int(dimensions.height)
                let bits = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? Int ?? 8
                let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                let hdrTransfers = [kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String]
                info.isHighDepth = bits > 8 || hdrTransfers.contains(transfer ?? "") || info.videoCodec == "prores"
            case .audio where info.audioCodec == nil:
                info.audioCodec = audioCodecs[fourCC] ?? fourCC
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    info.audioBits = Int(asbd.mBitsPerChannel)
                    info.audioChannels = Int(asbd.mChannelsPerFrame)
                }
            default:
                break
            }
        }
        return info.hasVideo || info.hasAudio ? info : nil
    }

    /// Parses the "Stream #0:0: Video: h264 …" lines ffmpeg prints for its input.
    private static func ffmpegInfo(_ url: URL) -> MediaInfo {
        var info = MediaInfo()
        guard let ffmpeg = ExternalTool.ffmpeg.url else { return info }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-nostdin", "-i", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return info }
        let report = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        if let match = report.firstMatch(of: #/Duration: (\d+):(\d+):(\d+(?:\.\d+)?)/#) {
            let hours = Double(match.1) ?? 0, minutes = Double(match.2) ?? 0, seconds = Double(match.3) ?? 0
            info.duration = hours * 3600 + minutes * 60 + seconds
        }
        for line in report.split(separator: "\n") where line.contains("Stream #") {
            if info.videoCodec == nil, let match = line.firstMatch(of: #/Video: (\w+)/#) {
                info.videoCodec = String(match.1)
                info.isHighDepth = line.contains("p10") || line.contains("p12") || line.contains("arib-std-b67")
                    || line.contains("smpte2084")
                if let size = line.firstMatch(of: #/, (\d{2,5})x(\d{2,5})/#) {
                    info.width = Int(size.1) ?? 0
                    info.height = Int(size.2) ?? 0
                }
            } else if info.audioCodec == nil, let match = line.firstMatch(of: #/Audio: (\w+)/#) {
                var codec = String(match.1)
                if codec.hasPrefix("pcm_") {
                    info.audioBits = Int(codec.filter(\.isNumber)) ?? 16
                    codec = "pcm"
                }
                info.audioCodec = codec
                info.audioChannels = line.contains("mono") ? 1 : line.contains("stereo") ? 2 : line.contains("5.1") ? 6 : 2
            }
        }
        return info
    }

    private static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    private static let videoCodecs: [String: String] = [
        "avc1": "h264", "avc3": "h264", "hvc1": "hevc", "hev1": "hevc", "dvh1": "hevc", "dvhe": "hevc",
        "ap4h": "prores", "ap4x": "prores", "apch": "prores", "apcn": "prores", "apcs": "prores", "apco": "prores",
        "jpeg": "mjpeg", "vp09": "vp9", "av01": "av1", "mp4v": "mpeg4",
    ]

    private static let audioCodecs: [String: String] = [
        "aac": "aac", "alac": "alac", ".mp3": "mp3", "lpcm": "pcm", "sowt": "pcm", "twos": "pcm",
        "opus": "opus", "flac": "flac", "ac-3": "ac3", "ec-3": "eac3",
    ]
}

/// Runs ffmpeg off the main thread, reporting progress and retrying on software encoders when the
/// Mac's hardware encoder is unavailable (some virtual machines and older macOS installs).
enum FFmpeg {
    static let encoders: Set<String> = {
        guard let ffmpeg = ExternalTool.ffmpeg.url else { return [] }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Set(text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts[0].count == 6 ? String(parts[1]) : nil
        })
    }()

    /// The Apple AudioToolbox AAC encoder sounds better than ffmpeg's own; use it when present.
    static var aac: String { encoders.contains("aac_at") ? "aac_at" : "aac" }

    static func run(input: URL, output: URL, arguments: [String], inputOptions: [String] = [], duration: Double,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try ExternalTool.ffmpeg.require()
        let full = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
            + inputOptions + ["-i", input.path] + arguments + [output.path]
        do {
            do {
                try await execute(ffmpeg, full, duration: duration, progress: progress)
            } catch where !(error is CancellationError) && softwareFallback(arguments) != nil {
                DebugLog.write("hardware encoder failed, retrying in software: \(error.localizedDescription)")
                let software = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
                    + inputOptions + ["-i", input.path] + softwareFallback(arguments)! + [output.path]
                try await execute(ffmpeg, software, duration: duration, progress: progress)
            }
        } catch is CancellationError {
            // A cancelled job leaves no half-written file behind.
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
    }

    /// Runs ffmpeg with a complete argument list (several inputs, filter graphs), with progress and
    /// the same software fallback.
    static func run(arguments: [String], duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        let ffmpeg = try ExternalTool.ffmpeg.require()
        let prefix = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
        do {
            do {
                try await execute(ffmpeg, prefix + arguments, duration: duration, progress: progress)
            } catch where !(error is CancellationError) && softwareFallback(arguments) != nil {
                DebugLog.write("hardware encoder failed, retrying in software: \(error.localizedDescription)")
                try await execute(ffmpeg, prefix + softwareFallback(arguments)!, duration: duration, progress: progress)
            }
        } catch is CancellationError {
            // The output is the last argument; a cancelled job leaves no half-written file behind.
            if let last = arguments.last, last.hasPrefix("/") { try? FileManager.default.removeItem(atPath: last) }
            throw CancellationError()
        }
    }

    /// Cancelling the task stops ffmpeg and throws `CancellationError`.
    private static func execute(_ ffmpeg: URL, _ arguments: [String], duration: Double,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        let handle = ProcessHandle()
        try await withTaskCancellationHandler {
            try await execute(ffmpeg, arguments, duration: duration, handle: handle, progress: progress)
        } onCancel: {
            handle.cancel()
        }
    }

    private static func execute(_ ffmpeg: URL, _ arguments: [String], duration: Double, handle: ProcessHandle,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = ffmpeg
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                let errors = LockedData()
                err.fileHandleForReading.readabilityHandler = { errors.append($0.availableData) }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                handle.attach(process)
                var buffer = ""
                while case let data = out.fileHandleForReading.availableData, !data.isEmpty {
                    buffer += String(decoding: data, as: UTF8.self)
                    while let newline = buffer.firstIndex(of: "\n") {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        if duration > 0, line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst(12)) {
                            progress(min(1, max(0, micros / 1_000_000 / duration)))
                        }
                    }
                }
                process.waitUntilExit()
                err.fileHandleForReading.readabilityHandler = nil
                if handle.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: errors.value, as: UTF8.self)
                    let last = message.split(separator: "\n").last.map(String.init) ?? "exit code \(process.terminationStatus)"
                    continuation.resume(throwing: AdawatError.message("ffmpeg: \(last)"))
                }
            }
        }
    }

    /// The same job on software encoders: x265 for HEVC (keeping 10-bit), x264 otherwise.
    static func softwareFallback(_ arguments: [String]) -> [String]? {
        guard let index = arguments.firstIndex(of: "-c:v"), index + 1 < arguments.count,
              arguments[index + 1].hasSuffix("_videotoolbox") else { return nil }
        var args = arguments
        let wantsHEVC = args[index + 1] == "hevc_videotoolbox" && encoders.contains("libx265")
        func drop(_ flag: String) {
            if let i = args.firstIndex(of: flag), i + 1 < args.count { args.removeSubrange(i...(i + 1)) }
        }
        var quality: [String] = []
        if let q = args.firstIndex(of: "-q:v"), q + 1 < args.count, let value = Double(args[q + 1]) {
            // VideoToolbox quality runs 1…100 (higher is better); CRF runs the other way.
            quality = ["-crf", "\(Int(max(16, min(34, 40 - value * 0.3))))"]
        }
        drop("-q:v")
        if !wantsHEVC { drop("-profile:v"); drop("-tag:v") }
        if let p = args.firstIndex(of: "p010le") { args[p] = wantsHEVC ? "yuv420p10le" : "yuv420p" }
        guard let codec = args.firstIndex(of: "-c:v") else { return nil }
        args[codec + 1] = wantsHEVC ? "libx265" : "libx264"
        args.insert(contentsOf: ["-preset", "medium"] + quality, at: codec + 2)
        return args
    }
}

/// Thread-safe byte buffer for collecting a child process's stderr.
final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

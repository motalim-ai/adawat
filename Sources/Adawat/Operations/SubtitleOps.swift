import Foundation

/// SRT and WebVTT subtitles, converted between each other and to plain text.
enum SubtitleOps {
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    enum Target: String, CaseIterable {
        case srt, vtt, txt
        var title: String { rawValue.uppercased() }
    }

    static let extensions: Set<String> = ["srt", "vtt"]

    /// Reads UTF-8 (with or without BOM), falling back to UTF-16 and Windows Arabic/Latin code pages.
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // Older Arabic subtitles are often saved in Windows-1256.
        let arabic = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.windowsArabic.rawValue)))
        for encoding in [String.Encoding.utf8, .utf16, arabic, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) {
                return text.replacingOccurrences(of: "\u{FEFF}", with: "")
                    .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            }
        }
        throw AdawatError.message("\(url.lastPathComponent) is not readable text.")
    }

    /// "00:01:02,500", "01:02.500" or "1:02:03.5" → seconds.
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        // "inf" and huge numbers parse as Doubles but would crash the Int conversion in stamp().
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1_000_000 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        for block in text.components(separatedBy: "\n\n") {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let sides = lines[timing].components(separatedBy: "-->")
            // VTT cue settings ("align:start") follow the end time after a space.
            let endText = sides.count > 1 ? String(sides[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") : ""
            guard let start = parseTime(sides[0]), let end = parseTime(endText) else { continue }
            lines.removeSubrange(0...timing)
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(Cue(start: start, end: end, text: body)) }
        }
        return cues
    }

    static func stamp(_ seconds: Double, separator: Character) -> String {
        let total = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", total / 3_600_000, (total / 60_000) % 60, (total / 1000) % 60,
                      String(separator), total % 1000)
    }

    /// Plain text with markup tags removed, one cue per paragraph.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
    }

    static func write(_ cues: [Cue], as target: Target) -> String {
        switch target {
        case .srt:
            return cues.enumerated().map { index, cue in
                "\(index + 1)\n\(stamp(cue.start, separator: ",")) --> \(stamp(cue.end, separator: ","))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case .vtt:
            return "WEBVTT\n\n" + cues.map { cue in
                "\(stamp(cue.start, separator: ".")) --> \(stamp(cue.end, separator: "."))\n\(cue.text)"
            }.joined(separator: "\n\n") + "\n"
        case .txt:
            return cues.map { plain($0.text) }.joined(separator: "\n\n") + "\n"
        }
    }

    @MainActor
    static func convert(_ files: [URL], to target: Target, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            let cues = parse(try readText(file))
            guard !cues.isEmpty else { throw AdawatError.message("No valid subtitle cues were found in \(file.lastPathComponent).") }
            let out = Output.url(for: file, extension: target.rawValue)
            try write(cues, as: target).write(to: out, atomically: true, encoding: .utf8)
            outputs.append(out)
        }
        return outputs
    }
}

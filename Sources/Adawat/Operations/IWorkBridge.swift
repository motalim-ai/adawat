import AppKit

/// Converts through Pages, Keynote and Numbers with AppleScript, for formats only those apps read or
/// write faithfully (Pages and Keynote files, PowerPoint slides, legacy XLS). The app is quit again
/// afterwards when it was not already open.
@MainActor
enum IWorkBridge {
    enum App: String {
        case pages = "Pages", keynote = "Keynote", numbers = "Numbers"

        var bundleID: String { "com.apple.iWork.\(rawValue)" }
    }

    enum Format {
        case pdf, word, excel, powerpoint, epub, plainText, richText, csv
        case images(png: Bool)
        /// The app's own format: .pages, .key or .numbers.
        case native

        var script: String {
            switch self {
            case .pdf: return "PDF"
            case .word: return "Microsoft Word"
            case .excel: return "Microsoft Excel"
            case .powerpoint: return "Microsoft PowerPoint"
            case .epub: return "EPUB"
            case .plainText: return "unformatted text"
            case .richText: return "formatted text"
            case .csv: return "CSV"
            case .images(let png): return "slide images with properties {image format:\(png ? "PNG" : "JPEG")}"
            case .native: return ""
            }
        }
    }

    /// A hidden scratch file beside `url`. Pages, Keynote and Numbers are sandboxed: they can open and save
    /// where the user's files live, but not in this app's temporary folder.
    static func scratchURL(near url: URL, extension ext: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".adawat-\(UUID().uuidString).\(ext)")
    }

    static func isInstalled(_ app: App) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil
    }

    private static func quoted(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func export(_ input: URL, with app: App, as format: Format, to out: URL) async throws {
        guard isInstalled(app) else {
            throw AdawatError.message("\(app.rawValue) is needed for \(input.pathExtension.uppercased()) files. It is free in the App Store.")
        }
        let action: String
        if case .native = format {
            action = "save theDocument in POSIX file \(quoted(out.path))"
        } else {
            action = "export theDocument to POSIX file \(quoted(out.path)) as \(format.script)"
        }
        // Opening a Word, Excel or PowerPoint file is an import: `open` does not hand back the new document,
        // so wait for it to appear and use the front document instead.
        let script = """
        set wasRunning to application id "\(app.bundleID)" is running
        tell application id "\(app.bundleID)"
            set countBefore to count of documents
            open POSIX file \(quoted(input.path))
            repeat 300 times
                if (count of documents) > countBefore then exit repeat
                delay 0.1
            end repeat
            -- No new document: the file was already open or asked for a password. The front document is then
            -- someone else's, so it must not be exported or closed.
            if (count of documents) is not greater than countBefore then error "ADAWAT_NOT_OPENED"
            set theDocument to front document
            \(action)
            close theDocument saving no
            if not wasRunning then quit
        end tell
        """
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
        } catch {
            let message = error.localizedDescription
            DebugLog.write("\(app.rawValue) bridge failed for \(input.lastPathComponent): \(message)")
            if message.contains("ADAWAT_NOT_OPENED") {
                throw AdawatError.message("\(app.rawValue) did not open \(input.lastPathComponent). Close it if it is open there, or remove its password, and try again.")
            }
            if message.contains("-1743") || message.lowercased().contains("not authorized") {
                throw AdawatError.message("Allow Adawat to control \(app.rawValue) in System Settings › Privacy & Security › Automation.")
            }
            throw AdawatError.message("\(app.rawValue) could not convert \(input.lastPathComponent).")
        }
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw AdawatError.message("\(app.rawValue) finished without creating \(out.lastPathComponent).")
        }
    }
}

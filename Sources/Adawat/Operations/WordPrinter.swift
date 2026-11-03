import AppKit

/// Word documents exported to PDF by an app that lays out their pages: Microsoft Word, LibreOffice or Pages, the
/// first one installed. Headers, footers, letterhead pictures, fonts, sizes and page layout then come out as they
/// look in Word. NSAttributedString, the route every other document takes, keeps only the text and its styles.
@MainActor
enum WordPrinter {
    private static let wordBundleID = "com.microsoft.Word"

    static func handles(_ url: URL) -> Bool {
        ["docx", "doc", "odt", "rtf"].contains(url.pathExtension.lowercased())
    }

    private static var hasWord: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: wordBundleID) != nil
    }

    private static var libreOffice: URL? {
        let roots = ["/Applications", "\(NSHomeDirectory())/Applications"]
        for root in roots {
            let path = "\(root)/LibreOffice.app/Contents/MacOS/soffice"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// Exports `input` to `out` and returns true, or returns false when no app could, so the caller can fall back.
    static func print(_ input: URL, to out: URL) async -> Bool {
        if hasWord {
            do {
                try await exportWithWord(input, to: out)
                return true
            } catch {
                DebugLog.write("Word could not export \(input.lastPathComponent) as PDF: \(error.localizedDescription)")
            }
        }
        if let soffice = libreOffice {
            do {
                try await exportWithLibreOffice(soffice, input, to: out)
                return true
            } catch {
                DebugLog.write("LibreOffice could not export \(input.lastPathComponent) as PDF: \(error.localizedDescription)")
            }
        }
        // Pages opens Word files, not OpenDocument; plain RTF reads well enough through NSAttributedString.
        if ["docx", "doc"].contains(input.pathExtension.lowercased()), IWorkBridge.isInstalled(.pages) {
            let scratch = IWorkBridge.scratchURL(near: input, extension: "pdf")
            defer { try? FileManager.default.removeItem(at: scratch) }
            do {
                try await IWorkBridge.export(input, with: .pages, as: .pdf, to: scratch)
                try move(scratch, to: out)
                return true
            } catch {
                DebugLog.write("Pages could not export \(input.lastPathComponent) as PDF: \(error.localizedDescription)")
            }
        }
        return false
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func move(_ from: URL, to out: URL) throws {
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw AdawatError.message("No PDF was created")
        }
        if FileManager.default.fileExists(atPath: out.path) { try FileManager.default.removeItem(at: out) }
        try FileManager.default.moveItem(at: from, to: out)
    }

    /// Word is sandboxed like Pages: it saves beside the original, which it was allowed to open, and the PDF is moved
    /// from there. Word is quit again afterwards when it was not already open.
    private static func exportWithWord(_ input: URL, to out: URL) async throws {
        let scratch = IWorkBridge.scratchURL(near: input, extension: "pdf")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let script = """
        set wasRunning to application id "\(wordBundleID)" is running
        tell application id "\(wordBundleID)"
            set countBefore to count of documents
            open POSIX file \(quoted(input.path))
            repeat 300 times
                if (count of documents) > countBefore then exit repeat
                delay 0.1
            end repeat
            if (count of documents) is not greater than countBefore then error "ADAWAT_NOT_OPENED"
            set theDocument to active document
            save as theDocument file name ((POSIX file \(quoted(scratch.path))) as text) file format format PDF
            close theDocument saving no
            if not wasRunning then quit saving no
        end tell
        """
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script])
        try move(scratch, to: out)
    }

    /// LibreOffice converts headless, with a profile of its own so a LibreOffice window that is already open does not
    /// swallow the job.
    private static func exportWithLibreOffice(_ soffice: URL, _ input: URL, to out: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("adawat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = folder.appendingPathComponent("profile")
        try await ProcessRunner.run(soffice, [
            "-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
            "--convert-to", "pdf", "--outdir", folder.path, input.path,
        ])
        try move(folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent + ".pdf"), to: out)
    }
}

import Foundation

/// Packing and unpacking with the Mac's own ditto, bsdtar (libarchive) and gzip family.
@MainActor
enum ArchiveOps {
    enum Format: String, CaseIterable {
        case zip, tar, tgz, gz

        var title: String {
            switch self {
            case .zip: return "ZIP"
            case .tar: return "TAR"
            case .tgz: return "TAR.GZ"
            case .gz: return "GZIP"
            }
        }

        var suffix: String { self == .tgz ? "tar.gz" : rawValue }
    }

    private static let tar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    private static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// Single-file compressors that are not tar archives.
    private static let streams: [String: String] = ["gz": "/usr/bin/gunzip", "bz2": "/usr/bin/bunzip2", "xz": "/usr/bin/unxz"]

    static func isTarStream(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return ["tar.gz", "tar.bz2", "tar.xz", "tgz", "tbz", "txz"].contains { name.hasSuffix($0) }
    }

    /// The archive format a file already is, so the wheel can leave it out.
    static func format(of url: URL) -> Format? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tgz }
        if name.hasSuffix(".gz") { return .gz }
        return nil
    }

    // MARK: Packing

    /// Packs the files into one archive; several items are gathered under a folder named "Archive".
    static func pack(_ files: [URL], as format: Format, context: OperationContext) async throws -> [URL] {
        context.report("Compressing \(files.count) item\(files.count == 1 ? "" : "s")")
        let fm = FileManager.default
        var source = files[0]
        let staging = Output.temporaryURL(extension: "").deletingPathExtension()
        defer { try? fm.removeItem(at: staging) }
        if files.count > 1 {
            source = staging.appendingPathComponent("Archive")
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            for file in files { try fm.copyItem(at: file, to: Output.unique(source.appendingPathComponent(file.lastPathComponent))) }
        }
        var format = format
        // gzip compresses a single file; a folder becomes a gzipped tar instead.
        if format == .gz, source.hasDirectoryPath || (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            format = .tgz
        }
        let out = Output.url(named: "\(source.lastPathComponent).\(format.suffix)", near: files[0])
        let parent = source.deletingLastPathComponent().path
        // bsdtar would read a name like "-backup" as an option.
        let name = source.lastPathComponent.hasPrefix("-") ? "./" + source.lastPathComponent : source.lastPathComponent
        switch format {
        case .zip:
            try await ProcessRunner.run(ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, out.path])
        case .tar:
            try await ProcessRunner.run(tar, ["-cf", out.path, "--exclude", ".DS_Store", "-C", parent, name])
        case .tgz:
            try await ProcessRunner.run(tar, ["-czf", out.path, "--exclude", ".DS_Store", "-C", parent, name])
        case .gz:
            let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/gzip"), ["-c", "-9", source.path])
            try result.stdout.write(to: out)
        }
        return [out]
    }

    // MARK: Unpacking

    /// Extracts ZIP, TAR (any compression), RAR, 7z, ISO and CPIO archives, or decompresses single
    /// .gz/.bz2/.xz files. An archive with one top-level item extracts as that item.
    static func extract(_ files: [URL], context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        for file in files {
            context.report("Extracting \(file.lastPathComponent)")
            outputs.append(try await extractOne(file))
        }
        return outputs
    }

    private static func extractOne(_ file: URL) async throws -> URL {
        let fm = FileManager.default
        let ext = file.pathExtension.lowercased()
        if let tool = streams[ext], !isTarStream(file) {
            let out = Output.url(named: file.deletingPathExtension().lastPathComponent, near: file)
            let result = try await ProcessRunner.run(URL(fileURLWithPath: tool), ["-c", file.path])
            try result.stdout.write(to: out)
            return out
        }
        let staging = try extractToStaging(file)
        defer { try? fm.removeItem(at: staging) }
        try await unpack(file, into: staging)
        let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
        guard !entries.isEmpty else { throw AdawatError.message("The source archive is empty.") }
        let out: URL
        if entries.count == 1 {
            out = Output.url(named: entries[0].lastPathComponent, near: file)
            try fm.moveItem(at: entries[0], to: out)
        } else {
            var base = file.deletingPathExtension()
            if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
            out = Output.url(named: base.lastPathComponent, near: file)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            for entry in entries { try fm.moveItem(at: entry, to: out.appendingPathComponent(entry.lastPathComponent)) }
        }
        return out
    }

    private static func extractToStaging(_ file: URL) throws -> URL {
        let staging = Output.temporaryURL(extension: "").deletingPathExtension()
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    private static func unpack(_ file: URL, into folder: URL) async throws {
        if file.pathExtension.lowercased() == "zip" {
            // ditto keeps macOS metadata and resource forks stored by the Finder.
            try await ProcessRunner.run(ditto, ["-x", "-k", file.path, folder.path])
        } else {
            do {
                try await ProcessRunner.run(tar, ["-xf", file.path, "-C", folder.path])
            } catch {
                if file.pathExtension.lowercased() == "rar" {
                    throw AdawatError.message("This RAR archive is encrypted or uses a format the Mac cannot open.")
                }
                throw error
            }
        }
    }

    /// Repacks an archive in another format, through a temporary extraction.
    static func convert(_ files: [URL], to format: Format, context: OperationContext) async throws -> [URL] {
        var outputs: [URL] = []
        let fm = FileManager.default
        for file in files {
            context.report("Converting \(file.lastPathComponent)")
            let staging = try extractToStaging(file)
            defer { try? fm.removeItem(at: staging) }
            var base = file.deletingPathExtension()
            if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
            let root = staging.appendingPathComponent(base.lastPathComponent)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try await unpack(file, into: root)
            let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .filter { !["__MACOSX", ".DS_Store"].contains($0.lastPathComponent) }
            // Keep a single top-level folder as the archive root instead of nesting it.
            let source = entries.count == 1 && (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                ? entries[0] : root
            let packed = try await pack([source], as: format == .gz ? .tgz : format, context: context)[0]
            let out = Output.url(named: "\(base.lastPathComponent).\((format == .gz ? Format.tgz : format).suffix)", near: file)
            try fm.moveItem(at: packed, to: out)
            outputs.append(out)
        }
        return outputs
    }
}

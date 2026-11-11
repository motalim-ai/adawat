import Foundation

enum ExternalTool: String {
    case ffmpeg, ffprobe, cwebp

    private static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "/usr/bin",
    ]

    /// The tool bundled in Adawat.app, or the first copy found on this Mac.
    var url: URL? {
        if let bundled = Bundle.main.url(forResource: rawValue, withExtension: nil, subdirectory: "Tools") {
            return bundled
        }
        for dir in Self.searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(rawValue)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func require() throws -> URL {
        guard let url else {
            throw AdawatError.message("\(rawValue) is not installed. Install it with: brew install \(installName)")
        }
        return url
    }

    private var installName: String {
        switch self {
        case .ffmpeg, .ffprobe: return "ffmpeg"
        case .cwebp: return "webp"
        }
    }
}

/// Lets a cancelled task stop the child process it is waiting for.
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Call once the process is running. A task cancelled before that stops it here.
    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let stopNow = cancelled
        lock.unlock()
        if stopNow { Self.stop(process) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process { Self.stop(process) }
    }

    /// Asks the process to stop, then makes it. The bundled ffmpeg can go on encoding for a long time after being
    /// asked, to finish a file that a cancelled job throws away anyway.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: Data
        let stderr: String
    }

    /// Runs a command off the main thread and throws with its stderr when it fails. Cancelling the task stops the command.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], currentDirectory: URL? = nil) async throws -> Result {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await run(executable, arguments, currentDirectory: currentDirectory, handle: handle)
        } onCancel: {
            handle.cancel()
        }
    }

    private static func run(_ executable: URL, _ arguments: [String], currentDirectory: URL?, handle: ProcessHandle) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                    handle.attach(process)
                    // Read both pipes before waiting so a full buffer cannot block the child.
                    var outData = Data()
                    var errData = Data()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        outData = out.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    let result = Result(
                        status: process.terminationStatus,
                        stdout: outData,
                        stderr: String(decoding: errData, as: UTF8.self)
                    )
                    if handle.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if result.status == 0 {
                        continuation.resume(returning: result)
                    } else {
                        let lastLine = result.stderr
                            .split(separator: "\n").last.map(String.init) ?? "exit code \(result.status)"
                        continuation.resume(throwing: AdawatError.message(
                            "\(executable.lastPathComponent) failed: \(lastLine)"))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

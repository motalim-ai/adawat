import AppKit

/// One choice on the wheel: a conversion, a tool or an action.
struct AdawatOperation: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    /// Format name drawn alone in the wheel petal instead of an icon, such as "PNG".
    var badge: String?
    /// Shorter petal label for tools and actions, such as "METADATA".
    var short: String?
    /// Whether the operation shows its result in a Float when it finishes.
    var producesFiles = true
    let run: @MainActor ([URL], OperationContext) async throws -> [URL]
    /// Opens an options window instead of running right away. `run` stays the one-step version
    /// with saved defaults, used from the command line.
    var window: (@MainActor ([URL]) -> Void)?

    /// The petal label: translated, and upper-cased in scripts that have capitals.
    var wheelLabel: String {
        let text = badge ?? L10n.t(short ?? title)
        return L10n.isArabic ? text : text.uppercased()
    }

    func opening(_ window: @escaping @MainActor ([URL]) -> Void) -> AdawatOperation {
        var copy = self
        copy.window = window
        return copy
    }
}

/// Passed to every operation so it can report progress and messages.
@MainActor
final class OperationContext {
    private(set) var message: String?

    func report(_ text: String) {
        HUDController.shared.update(text)
    }

    /// Fraction done (0…1) of the whole operation, drawn as a bar in the toast.
    func progress(_ fraction: Double) {
        HUDController.shared.setProgress(fraction)
    }

    /// A callback for background work on file `index` of `count` that maps its own 0…1 progress
    /// onto the whole operation.
    nonisolated func progressHandler(file index: Int, of count: Int) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            Task { @MainActor in self?.progress((Double(index) + fraction) / Double(max(count, 1))) }
        }
    }

    /// Call between files or pages. Stops here if the user cancelled, after giving the screen a turn: much of the
    /// work holds the main thread, and this is when the toast redraws and its Cancel button can answer.
    func checkpoint() async throws {
        await Task.yield()
        try Task.checkCancellation()
    }

    /// A message shown in the finish toast instead of the default one.
    func finish(with text: String) {
        message = text
    }
}

enum AdawatError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}

@MainActor
enum OperationRunner {
    /// The work in progress.
    private static var running: [UUID: Task<Void, Never>] = [:]

    /// The toast's Cancel button: stops everything in progress, since the one toast speaks for all of it.
    static func cancelAll() {
        running.values.forEach { $0.cancel() }
    }

    static func run(_ operation: AdawatOperation, on files: [URL]) {
        let context = OperationContext()
        // Actions (AirDrop, Move, Copy…) are over at once or wait on a panel of their own; only work that makes files offers Cancel.
        let cancel: (() -> Void)? = operation.producesFiles ? { cancelAll() } : nil
        HUDController.shared.show(L10n.t("\(operation.title)…"), style: .working, cancel: cancel)

        let id = UUID()
        running[id] = Task<Void, Never> { @MainActor in
            defer { running[id] = nil }
            do {
                let outputs = try await operation.run(files, context)
                let text = context.message ?? doneMessage(operation, outputs: outputs)
                HUDController.shared.show(text, style: .success)
                Feedback.success()
                if operation.producesFiles, !outputs.isEmpty, AppSettings.shared.showResultsInFloat {
                    FloatManager.shared.showResults(outputs)
                }
            } catch {
                // A cancelled job can fail in its own words, such as ffmpeg reporting that it was stopped.
                if Task.isCancelled {
                    HUDController.shared.show("Cancelled", style: .cancelled)
                } else {
                    HUDController.shared.show(error.localizedDescription, style: .failure)
                    Feedback.failure()
                }
            }
        }
    }

    /// Runs work started from a tool window, with the same toast, sound and Float as a wheel drop.
    static func run(_ title: String, on files: [URL], producesFiles: Bool = true,
                    _ work: @escaping @MainActor ([URL], OperationContext) async throws -> [URL]) {
        run(AdawatOperation(id: "window", title: title, systemImage: "", producesFiles: producesFiles, run: work), on: files)
    }

    private static func doneMessage(_ operation: AdawatOperation, outputs: [URL]) -> String {
        switch outputs.count {
        case 0: return "\(operation.title) done"
        case 1: return "Saved \(outputs[0].lastPathComponent)"
        default: return "Saved \(outputs.count) files"
        }
    }
}

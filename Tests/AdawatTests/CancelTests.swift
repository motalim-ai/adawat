import XCTest
@testable import Adawat

/// The toast's Cancel: tools stop, batches stop between files, and nothing half-written stays behind.
@MainActor
final class CancelTests: AdawatTestCase {
    /// Starts `work`, cancels it once `ready` is true, and returns what it threw and how long the cancel took.
    private func cancel(when ready: @escaping @MainActor () -> Bool, _ work: @escaping @MainActor () async throws -> Void) async throws -> (error: Error?, seconds: Double) {
        let task = Task { @MainActor in try await work() }
        let deadline = Date().addingTimeInterval(30)
        while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(ready(), "the work never got going")
        let start = Date()
        task.cancel()
        do {
            try await task.value
            return (nil, Date().timeIntervalSince(start))
        } catch {
            return (error, Date().timeIntervalSince(start))
        }
    }

    func testAToolStopsWhenItsTaskIsCancelled() async throws {
        var started = false
        let result = try await cancel(when: { started }) {
            started = true
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["60"])
        }
        XCTAssertTrue(result.error is CancellationError, "\(String(describing: result.error))")
        XCTAssertLessThan(result.seconds, 5)
    }

    /// The ffmpeg bundled in the app keeps encoding for a long time after a polite stop, so a tool that ignores one is
    /// stopped for good half a second later.
    func testAToolThatIgnoresAPoliteStopIsStoppedAnyway() async throws {
        var started = false
        let result = try await cancel(when: { started }) {
            started = true
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/perl"), ["-e", "$SIG{TERM} = 'IGNORE'; sleep 60"])
        }
        XCTAssertTrue(result.error is CancellationError, "\(String(describing: result.error))")
        XCTAssertLessThan(result.seconds, 5)
    }

    func testABatchStopsBetweenFilesAndKeepsWhatItFinished() async throws {
        let photos = try (1...40).map { try Samples.photo(file("photo\($0).jpg"), width: 1600, height: 1000) }
        let made = { self.names().filter { $0.hasSuffix(".png") }.count }
        let result = try await cancel(when: { made() >= 2 }) { _ = try await self.run("image.png", photos) }
        XCTAssertTrue(result.error is CancellationError, "\(String(describing: result.error))")
        XCTAssertGreaterThanOrEqual(made(), 2)
        XCTAssertLessThan(made(), 40)
        let afterwards = made()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(made(), afterwards, "the batch went on after it was cancelled")
    }

    func testACancelledConversionStopsFfmpegAndRemovesItsFile() async throws {
        try needFfmpeg()
        let clip = try await Samples.clip(file("long.mp4"), seconds: 60)
        let result = try await cancel(when: { self.names().contains("long.webm") }) { _ = try await self.run("media.webm", clip) }
        XCTAssertTrue(result.error is CancellationError, "\(String(describing: result.error))")
        XCTAssertLessThan(result.seconds, 5)
        XCTAssertEqual(names(), ["long.mp4"])
    }

    func testACheckpointStopsACancelledOperation() async throws {
        let context = OperationContext()
        try await context.checkpoint()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await context.checkpoint()
        }
        do {
            try await task.value
            XCTFail("the checkpoint let a cancelled operation through")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

import AVFoundation
import XCTest
@testable import Adawat

/// Video and audio, through ffmpeg. Skipped where ffmpeg is not installed.
@MainActor
final class MediaTests: AdawatTestCase {
    func testAVideoGivesItsSoundAlone() async throws {
        try needFfmpeg()
        let clip = try await Samples.clip(file("clip.mp4"))
        for (ext, codec) in [("mp3", "mp3"), ("m4a", "aac")] {
            let info = await MediaProbe.info(try await runOne("media.\(ext)", clip))
            XCTAssertNil(info.videoCodec, ext)
            XCTAssertEqual(info.audioCodec, codec)
            assertNear(info.duration, 2)
        }
    }

    func testAVideoChangesContainerAndKeepsPictureAndSound() async throws {
        try needFfmpeg()
        let clip = try await Samples.clip(file("clip.mp4"))
        for ext in ["mov", "mkv", "webm"] {
            let info = await MediaProbe.info(try await runOne("media.\(ext)", clip))
            XCTAssertNotNil(info.videoCodec, ext)
            XCTAssertNotNil(info.audioCodec, ext)
            XCTAssertEqual([info.width, info.height], [320, 240], ext)
            assertNear(info.duration, 2)
        }
    }

    func testAVideoBecomesAGif() async throws {
        try needFfmpeg()
        let gif = try await runOne("media.gif", try await Samples.clip(file("clip.mp4"), seconds: 1))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1)
    }

    func testMuteDropsTheSoundOnly() async throws {
        try needFfmpeg()
        let info = await MediaProbe.info(try await runOne("video.mute", try await Samples.clip(file("clip.mp4"))))
        XCTAssertNotNil(info.videoCodec)
        XCTAssertNil(info.audioCodec)
    }

    func testRotateTurnsAQuarter() async throws {
        try needFfmpeg()
        let rotated = try await runOne("video.rotate", try await Samples.clip(file("clip.mp4")))
        // Rotate turns the picture with a tag where the format has one, so read the size as a player shows it.
        let tracks = try await AVURLAsset(url: rotated).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = size.applying(transform)
        XCTAssertEqual([Int(abs(shown.width).rounded()), Int(abs(shown.height).rounded())], [240, 320])
    }

    func testJoinPlaysOneAfterTheOther() async throws {
        try needFfmpeg()
        let first = try await Samples.clip(file("first.mp4"), seconds: 2)
        let second = try await Samples.clip(file("second.mp4"), seconds: 1)
        let info = await MediaProbe.info(try await runOne("video.join", first, second))
        XCTAssertNotNil(info.videoCodec)
        XCTAssertNotNil(info.audioCodec)
        assertNear(info.duration, 3)
    }

    func testAudioConverts() async throws {
        try needFfmpeg()
        let tone = try await Samples.tone(file("tone.wav"))
        for (ext, codec) in [("flac", "flac"), ("opus", "opus"), ("m4a", "aac"), ("mp3", "mp3")] {
            let info = await MediaProbe.info(try await runOne("media.\(ext)", tone))
            XCTAssertEqual(info.audioCodec, codec, ext)
            assertNear(info.duration, 2)
        }
    }

    func testToMonoLeavesOneChannel() async throws {
        try needFfmpeg()
        let stereo = try await Samples.tone(file("stereo.wav"), channels: 2)
        let stereoInfo = await MediaProbe.info(stereo)
        XCTAssertEqual(stereoInfo.audioChannels, 2)
        let outputs = try await run("audio.mono", stereo, try await Samples.tone(file("tone.wav")))
        XCTAssertEqual(outputs.count, 2)
        for output in outputs {
            let info = await MediaProbe.info(output)
            XCTAssertEqual(info.audioChannels, 1)
        }
    }
}

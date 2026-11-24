import XCTest
import AVFoundation
import class FluidAudio.AudioConverter
import ScribeCore
@testable import Scribe

final class AudioCompressionTests: XCTestCase {
    func testRetryRemovesOnlyAbandonedCompressorStagingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let abandoned = directory.appendingPathComponent(".compress-\(UUID().uuidString).m4a")
        let unrelated = directory.appendingPathComponent(".compress-not-a-staging-file.m4a")
        try Data(repeating: 0, count: 100).write(to: abandoned)
        try Data(repeating: 0, count: 50).write(to: unrelated)
        try writeTrack(at: directory.appendingPathComponent(AudioTrack.system.filename), frames: 48_000)
        try AudioCompressor.compress(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingStorage.compressedURL(for: .system, in: directory).path))
    }

    @MainActor
    func testCompressedTracksKeepTimingSeekingAndPlaybackAndReduceStorage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let frames = 160_123 // Include a partial final AAC packet.
        for track in [AudioTrack.system, .microphone] {
            try writeTrack(at: directory.appendingPathComponent(track.filename), frames: frames)
        }
        let before = RecordingStorage.audioByteCount(in: directory)
        try AudioCompressor.compress(in: directory)
        let after = RecordingStorage.audioByteCount(in: directory)
        XCTAssertLessThan(after, before / 3)
        XCTAssertFalse(RecordingStorage.hasUncompressedAudio(in: directory))
        for track in [AudioTrack.system, .microphone] {
            let url = RecordingStorage.audioURL(for: track, in: directory)
            XCTAssertEqual(url.pathExtension, "m4a")
            let decoded = try AVAudioFile(forReading: url)
            XCTAssertEqual(decoded.length, Int64(frames))
            XCTAssertEqual(decoded.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(decoded.processingFormat.channelCount, 1)
            // Decode after a non-packet-aligned seek, as retranscription does.
            decoded.framePosition = 48_137
            let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 1024)!
            try decoded.read(into: buffer)
            let error = (0..<Int(buffer.frameLength)).reduce(0.0) { total, index in
                total + abs(Double(buffer.floatChannelData![0][index]) - sample(at: 48_137 + index))
            } / Double(buffer.frameLength)
            XCTAssertLessThan(error, 0.04, "Encoding must preserve sample alignment and audible signal.")
            XCTAssertFalse(try AudioActivityScanner.windows(in: url).isEmpty)
            let speakerInput = try AudioConverter().resampleAudioFile(url)
            XCTAssertEqual(speakerInput.count, frames)
        }
        let player = PlaybackController()
        let duration = Double(frames) / 16_000
        try player.load(Recording(title: "AAC fixture", duration: duration), directory: directory)
        XCTAssertTrue(player.hasAudio)
        XCTAssertEqual(player.duration, duration, accuracy: 0.01)
        player.seek(to: 3.25)
        XCTAssertEqual(player.position, 3.25)
        let filesBeforeRetry = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        try AudioCompressor.compress(in: directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), filesBeforeRetry)
        XCTAssertEqual(RecordingStorage.audioByteCount(in: directory), after)
        print("AAC fixture: \(before) bytes → \(after) bytes; \(100 - after * 100 / before)% smaller")
    }

    func testFailedCompressionPreservesOriginalAndRemovesTemporaryOutput() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(AudioTrack.system.filename)
        let invalid = Data("unreadable audio".utf8)
        try invalid.write(to: url)
        XCTAssertThrowsError(try AudioCompressor.compress(in: directory))
        XCTAssertEqual(try Data(contentsOf: url), invalid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [AudioTrack.system.filename])
    }

    func testRetryAfterInterruptedReplacementAndMixedFormats() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent(AudioTrack.system.filename)
        try writeTrack(at: source, frames: 80_000)
        let original = try Data(contentsOf: source)
        try AudioCompressor.compress(in: directory)
        // A crash after committing the M4A but before removing the CAF leaves both.
        try original.write(to: source)
        try writeTrack(at: directory.appendingPathComponent(AudioTrack.microphone.filename), frames: 64_000)
        XCTAssertEqual(RecordingStorage.audioURL(for: .system, in: directory), source)
        try AudioCompressor.compress(in: directory)
        XCTAssertFalse(RecordingStorage.hasUncompressedAudio(in: directory))
        XCTAssertEqual(try AVAudioFile(forReading: RecordingStorage.audioURL(for: .system, in: directory)).length, 80_000)
        XCTAssertEqual(try AVAudioFile(forReading: RecordingStorage.audioURL(for: .microphone, in: directory)).length, 64_000)
    }

    func testSilentTrackRemainsSilentAfterCompression() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var writer: AudioTrackWriter? = try AudioTrackWriter(
            url: directory.appendingPathComponent(AudioTrack.microphone.filename), startHostTime: 1, meter: { _ in })
        try writer!.finish(duration: 4)
        writer = nil
        try AudioCompressor.compress(in: directory)
        let url = RecordingStorage.audioURL(for: .microphone, in: directory)
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertTrue(try AudioActivityScanner.windows(in: url).isEmpty)
    }

    @MainActor
    func testManualCompressionRefreshesSizeAndPlaybackWithoutChangingTranscript() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = Recording(title: "Archived fixture", duration: 5, status: .ready, hasMicrophone: false)
        let speaker = ScribeCore.Speaker(recordingID: recording.id, name: "Custom name", colorIndex: 0)
        let segment = TranscriptSegment(recordingID: recording.id, speakerID: speaker.id,
                                        start: 1, end: 3, text: "Edited text", track: .system)
        let database = try LibraryDatabase(url: root.appendingPathComponent("library.sqlite"))
        try database.saveTranscript(recording: recording, speakers: [speaker], segments: [segment])
        let directory = root.appendingPathComponent("Recordings").appendingPathComponent(recording.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeTrack(at: directory.appendingPathComponent(AudioTrack.system.filename), frames: 80_000)
        let model = AppModel(isDemo: false, dataDirectory: root)
        let before = try XCTUnwrap(model.recordingByteCounts[recording.id])
        model.transcriptSearch = "Edited"
        model.playback.seek(to: 2.75)
        XCTAssertTrue(model.uncompressedRecordingIDs.contains(recording.id))
        model.compressRecording(recording)
        XCTAssertTrue(model.isBusy)
        // Deletion is blocked until the replacement has been verified and committed.
        model.delete(recording)
        XCTAssertNotNil(model.selectedRecording)
        for _ in 0..<300 where model.compressionID != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.compressionID)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.uncompressedRecordingIDs.contains(recording.id))
        XCTAssertLessThan(try XCTUnwrap(model.recordingByteCounts[recording.id]), before)
        XCTAssertEqual(model.segments, [segment])
        XCTAssertEqual(model.speakers, [speaker])
        XCTAssertEqual(model.transcriptSearch, "Edited")
        XCTAssertEqual(model.playback.position, 2.75)
        XCTAssertTrue(model.playback.hasAudio)
        let reopened = AppModel(isDemo: false, dataDirectory: root)
        XCTAssertTrue(reopened.playback.hasAudio)
        XCTAssertEqual(reopened.segments, [segment])
        XCTAssertEqual(reopened.recordingByteCounts[recording.id], model.recordingByteCounts[recording.id])
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-compression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sample(at frame: Int) -> Double {
        // Leading silence and distinct tones make changes to the timeline detectable.
        guard frame >= 16_000 else { return 0 }
        return sin(2 * .pi * 440 * Double(frame) / 16_000) * 0.3
            + sin(2 * .pi * 710 * Double(frame) / 16_000) * 0.1
    }

    private func writeTrack(at url: URL, frames: Int) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<frames { buffer.floatChannelData![0][frame] = Float(sample(at: frame)) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }
}

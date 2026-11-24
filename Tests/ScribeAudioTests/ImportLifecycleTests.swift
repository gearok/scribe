import XCTest
import AVFoundation
@testable import Scribe

@MainActor
final class ImportLifecycleTests: XCTestCase {
    func testSuccessfulImportFinishesCompressionAndPublishesStorageMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.caf")
        try writeSource(source)
        let model = AppModel(isDemo: false, dataDirectory: root.appendingPathComponent("library"))
        model.importMedia(from: source)
        try await waitUntilIdle(model)
        let recording = try XCTUnwrap(model.selectedRecording)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(recording.hasMicrophone)
        XCTAssertTrue(recording.hasSystemAudio)
        XCTAssertEqual(recording.duration, 3, accuracy: 0.01)
        XCTAssertGreaterThan(model.recordingByteCounts[recording.id] ?? 0, 0)
        XCTAssertFalse(model.uncompressedRecordingIDs.contains(recording.id))
        XCTAssertTrue(model.playback.hasAudio)
        XCTAssertEqual(RecordingStorage.audioURL(for: .system, in: model.directory(for: recording)).pathExtension, "m4a")
    }

    func testFailedImportLeavesNoOrphanedRecordingDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: source)
        let model = AppModel(isDemo: false, dataDirectory: root.appendingPathComponent("library"))
        model.importMedia(from: source)
        try await waitUntilIdle(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.recordings.isEmpty)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: model.rootDirectory.appendingPathComponent("Recordings").path))?.isEmpty ?? true)
    }

    func testQuitCancelsImportAndNeverStartsCompressionOrTranscription() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.caf")
        try writeSource(source)
        let model = AppModel(isDemo: false, dataDirectory: root.appendingPathComponent("library"))
        model.importMedia(from: source)
        XCTAssertTrue(model.isImporting)
        model.finishBeforeQuit()
        try await waitUntilIdle(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.compressionID)
        XCTAssertNil(model.processingID)
        XCTAssertTrue(model.recordings.isEmpty)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: model.rootDirectory.appendingPathComponent("Recordings").path))?.isEmpty ?? true)
    }

    private func waitUntilIdle(_ model: AppModel) async throws {
        for _ in 0..<500 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Import or compression did not finish.")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-import-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSource(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = Float(sin(2 * .pi * 440 * Double(frame) / 16_000) * 0.25)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        file.close()
    }
}

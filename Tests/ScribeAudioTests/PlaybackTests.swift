import XCTest
import AVFoundation
import ScribeCore
@testable import Scribe

@MainActor
final class PlaybackTests: XCTestCase {
    func testParagraphPlaybackSeekingAndPausingDriveTheHighlight() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("system.caf"), settings: format.settings)
            try file.write(from: buffer)
        }
        let recording = Recording(title: "Silent playback fixture", duration: 12, hasMicrophone: false)
        let segments = [
            TranscriptSegment(id: "first", recordingID: recording.id, speakerID: "speaker", start: 1, end: 3, text: "First", track: .system),
            TranscriptSegment(id: "second", recordingID: recording.id, speakerID: "speaker", start: 5, end: 7, text: "Second", track: .system),
        ]
        let player = PlaybackController()
        defer { player.pause() }
        try player.load(recording, directory: directory)
        XCTAssertTrue(player.hasAudio)
        func state() -> TranscriptPlaybackState {
            TranscriptPlaybackState(segments: segments, position: player.position, isPlaying: player.isPlaying)
        }
        player.playSegment(segments[0])
        XCTAssertEqual(state().activeSegmentIDs, ["first"])
        player.seek(to: 5.5)
        XCTAssertEqual(state().activeSegmentIDs, ["second"])
        player.pause()
        XCTAssertTrue(state().activeSegmentIDs.isEmpty)
        XCTAssertNil(state().followingSegmentID)
        player.seek(to: 2)
        XCTAssertTrue(state().activeSegmentIDs.isEmpty)
        player.play()
        XCTAssertEqual(state().activeSegmentIDs, ["first"])
        try player.load(nil, directory: nil)
        XCTAssertFalse(player.isPlaying)
        XCTAssertTrue(state().activeSegmentIDs.isEmpty)
    }
}

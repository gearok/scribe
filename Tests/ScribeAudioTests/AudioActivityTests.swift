import XCTest
import AVFoundation
@testable import Scribe

final class AudioActivityTests: XCTestCase {
    func testSilentTrackHasNoWindows() throws {
        try withAudio(duration: 3, sample: { _ in 0 }) { url in
            XCTAssertTrue(try AudioActivityScanner.windows(in: url).isEmpty)
        }
    }

    func testQuietAudioIsRetainedWithPaddingAndRealTimestamps() throws {
        try withAudio(duration: 4, sample: { time in
            (1..<2).contains(time) ? 0.0001 : 0
        }) { url in
            let windows = try AudioActivityScanner.windows(in: url)
            XCTAssertEqual(windows.count, 1)
            XCTAssertEqual(windows[0].start, 0.82, accuracy: 0.001)
            XCTAssertEqual(windows[0].end, 2.18, accuracy: 0.001)
        }
    }

    func testLongAudioUsesBoundedNonoverlappingWindows() throws {
        try withAudio(duration: 50, sample: { _ in 0.01 }) { url in
            let windows = try AudioActivityScanner.windows(in: url)
            XCTAssertEqual(windows.count, 3)
            XCTAssertEqual(windows.first?.start, 0)
            XCTAssertEqual(windows.last?.end, 50)
            XCTAssertTrue(windows.allSatisfy { $0.end - $0.start <= 22 })
            XCTAssertEqual(windows[0].end, windows[1].start)
            XCTAssertEqual(windows[1].end, windows[2].start)
        }
    }

    private func withAudio(duration: Double, sample: (Double) -> Float, check: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-activity-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * 16_000))!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = sample(Double(index) / 16_000) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        try check(url)
    }
}

import XCTest
import AVFoundation
@testable import Scribe

final class AudioImporterTests: XCTestCase {
    func testMultiblockStereoImportPreservesDurationAndSamples() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.caf")
        let destination = root.appendingPathComponent("converted")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = buffer.frameCapacity
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            for second in 0..<8 {
                for channel in 0..<2 {
                    buffer.floatChannelData![channel].update(repeating: Float(second + 1) / 10, count: Int(buffer.frameLength))
                }
                try file.write(from: buffer)
            }
        }
        XCTAssertEqual(try AudioImporter.convert(source: source, directory: destination), 8, accuracy: 0.001)
        let result = try AVAudioFile(forReading: destination.appendingPathComponent("system.caf"))
        XCTAssertEqual(result.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(result.processingFormat.channelCount, 1)
        XCTAssertEqual(result.length, 128_000, accuracy: 50)
        let samples = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length))!
        try result.read(into: samples)
        for second in 0..<8 {
            XCTAssertEqual(samples.floatChannelData![0][second * 16_000 + 8_000], Float(second + 1) / 10, accuracy: 0.03)
        }
    }
}

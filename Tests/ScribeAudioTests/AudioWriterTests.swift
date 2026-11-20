import XCTest
import AVFoundation
import ScribeCore
@testable import Scribe

final class AudioWriterTests: XCTestCase {
    func testStartupDelayAndDeviceGapKeepAudioOnTheMeetingTimeline() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-audio-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for i in 0..<1_600 { buffer.floatChannelData![0][i] = 0.25 }
        var writer: AudioTrackWriter? = try AudioTrackWriter(url: url, startHostTime: 1, meter: { _ in })
        writer!.append(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: 1))
        writer!.append(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: 2))
        try writer!.finish(duration: 3)
        writer = nil
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 48_000, accuracy: 2)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][8_000], 0, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![0][16_800], 0.25, accuracy: 0.01)
        XCTAssertEqual(read.floatChannelData![0][24_000], 0, accuracy: 0.0001)
        XCTAssertEqual(read.floatChannelData![0][32_800], 0.25, accuracy: 0.01)
        XCTAssertEqual(read.floatChannelData![0][44_000], 0, accuracy: 0.0001)
    }

    func testDeviceSampleRateIsConvertedTo16kMonoWithoutShiftingTime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-conversion-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 { for i in 0..<4_800 { buffer.floatChannelData![channel][i] = 0.2 } }
        var writer: AudioTrackWriter? = try AudioTrackWriter(url: url, startHostTime: 1, meter: { _ in })
        for block in 0..<10 {
            writer!.append(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: Double(block) / 10))
        }
        try writer!.finish(duration: 1)
        writer = nil
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.length, 16_000, accuracy: 50)
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: read)
        XCTAssertEqual(read.floatChannelData![0][8_000], 0.2, accuracy: 0.03)
    }
}

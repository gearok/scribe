import XCTest
import AVFoundation
import ScribeCore
@testable import Scribe

final class AudioWriterTests: XCTestCase {
    func testPaddingAndSilentBuffersAreNotReportedAsCapturedMicrophoneAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-silent-mic-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioTrackWriter(url: url, startHostTime: 1, meter: { _ in })
        XCTAssertFalse(try writer.finish(duration: 1))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = 0 }
        try writer.appendSynchronously(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: 1))
        XCTAssertFalse(try writer.finish(duration: 2))
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = 0.1 }
        try writer.appendSynchronously(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: 2))
        XCTAssertTrue(try writer.finish(duration: 3))
    }

    func testChangingBluetoothSampleRatesAndChannelsKeepsAudioAndMeetingTiming() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-bt-formats-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        var writer: AudioTrackWriter? = try AudioTrackWriter(url: url, startHostTime: 1, meter: { _ in })
        for (section, rate, channels) in [(0, 48_000.0, AVAudioChannelCount(2)), (1, 16_000.0, 1), (2, 24_000.0, 1)] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
            let frames = AVAudioFrameCount(rate / 10)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for channel in 0..<Int(channels) {
                for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = Float(section + 1) * 0.2 }
            }
            for block in 0..<10 {
                try writer!.appendSynchronously(buffer, hostTime: 1 + AVAudioTime.hostTime(forSeconds: Double(section) + Double(block) / 10))
            }
        }
        XCTAssertTrue(try writer!.finish(duration: 3))
        writer = nil
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertEqual(file.length, 48_000, accuracy: 100)
        for (index, value) in [(8_000, Float(0.2)), (24_000, 0.4), (40_000, 0.6)] {
            XCTAssertEqual(buffer.floatChannelData![0][index], value, accuracy: 0.03)
        }
    }

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

import XCTest
import AVFoundation
@testable import Scribe

final class AudioImporterTests: XCTestCase {
    func testMultiblockStereoImportPreservesDurationAndSamples() async throws {
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
        let duration = try await AudioImporter.convert(source: source, directory: destination)
        XCTAssertEqual(duration, 8, accuracy: 0.001)
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

    func testVideoImportExtractsItsAudioTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-video-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("meeting.mov")
        let destination = root.appendingPathComponent("converted")
        try await makeMovieWithAudio(at: source)

        let asset = AVURLAsset(url: source)
        let videoTrackCount = try await asset.loadTracks(withMediaType: .video).count
        let audioTrackCount = try await asset.loadTracks(withMediaType: .audio).count
        XCTAssertEqual(videoTrackCount, 1)
        XCTAssertEqual(audioTrackCount, 1)

        let duration = try await AudioImporter.convert(source: source, directory: destination)
        XCTAssertEqual(duration, 2, accuracy: 0.05)
        let result = try AVAudioFile(forReading: destination.appendingPathComponent("system.caf"))
        XCTAssertEqual(result.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(result.processingFormat.channelCount, 1)
        XCTAssertEqual(result.length, 32_000, accuracy: 800)
        let samples = AVAudioPCMBuffer(pcmFormat: result.processingFormat, frameCapacity: AVAudioFrameCount(result.length))!
        try result.read(into: samples)
        let peak = (0..<Int(samples.frameLength)).map { abs(samples.floatChannelData![0][$0]) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.1)
    }

    private func makeMovieWithAudio(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let videoAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ])
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
            nil, &pixelBuffer
        )
        guard let pixelBuffer else { throw ScribeError.message("Could not create the test video.") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x20, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard videoAdaptor.append(pixelBuffer, withPresentationTime: .zero),
              videoAdaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: 1.9, preferredTimescale: 600)) else {
            throw writer.error ?? ScribeError.message("Could not write the test video.")
        }
        guard audioInput.append(try audioSampleBuffer(duration: 2)) else {
            throw writer.error ?? ScribeError.message("Could not write the test audio.")
        }
        videoInput.markAsFinished()
        audioInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? ScribeError.message("Could not finish the test video.")
        }
    }

    private func audioSampleBuffer(duration: Double) throws -> CMSampleBuffer {
        let sampleRate = 48_000
        let frameCount = Int(Double(sampleRate) * duration)
        let samples = (0..<frameCount).map { frame in
            Float(sin(2 * Double.pi * 440 * Double(frame) / Double(sampleRate)) * 0.3)
        }
        var blockBuffer: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { throw ScribeError.message("Could not create test audio storage.") }
        try samples.withUnsafeBytes { bytes in
            guard CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: byteCount
            ) == noErr else { throw ScribeError.message("Could not fill test audio storage.") }
        }

        var description: CMAudioFormatDescription?
        var stream = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &stream,
            layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { throw ScribeError.message("Could not describe test audio.") }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: description, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { throw ScribeError.message("Could not create test audio.") }
        return sampleBuffer
    }
}

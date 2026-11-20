import AVFoundation

/// Each track is converted and written on its own queue. Shared host timestamps preserve the meeting timeline.
final class AudioTrackWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.scribe.audio-writer.\(UUID().uuidString)")
    private let file: AVAudioFile
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private let startHostTime: UInt64
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var framesWritten: Int64 = 0
    private var failure: Error?
    private var lastMeterTime = 0.0
    let meter: @Sendable (Float) -> Void

    init(url: URL, startHostTime: UInt64, meter: @escaping @Sendable (Float) -> Void) throws {
        self.startHostTime = startHostTime; self.meter = meter
        file = try AVAudioFile(forWriting: url, settings: outputFormat.settings)
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        // Audio callbacks own their buffers only until return; copy before crossing queues.
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            if let from = source[index].mData, let to = destination[index].mData {
                memcpy(to, from, min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize)))
            }
        }
        queue.async { [self] in
            guard failure == nil else { return }
            do { try write(copy, hostTime: hostTime) } catch { failure = error }
        }
    }

    /// File imports run on a worker thread and wait for conversion before reading again.
    /// The caller retains the buffer until this returns; no queued copy is needed.
    func appendSynchronously(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws {
        try queue.sync {
            if let failure { throw failure }
            do { try write(buffer, hostTime: hostTime) }
            catch { failure = error; throw error }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) throws {
        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { throw ScribeError.message("The audio device format could not be converted.") }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / buffer.format.sampleRate) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error, converted.frameLength > 0 else { return }
        let elapsed = hostTime >= startHostTime ? AVAudioTime.seconds(forHostTime: hostTime - startHostTime) : 0
        let expected = Int64(elapsed * 16_000)
        // Fill device startup delays and later interruptions, rather than shifting words earlier in the meeting.
        if expected - framesWritten > 1_600 || framesWritten == 0 { try pad(to: expected) }
        try file.write(from: converted)
        framesWritten += Int64(converted.frameLength)
        if elapsed - lastMeterTime >= 0.08, let samples = converted.floatChannelData?[0] {
            var power: Float = 0
            for index in 0..<Int(converted.frameLength) { power += samples[index] * samples[index] }
            meter(min(1, sqrt(power / Float(converted.frameLength)) * 5))
            lastMeterTime = elapsed
        }
    }

    private func pad(to frame: Int64) throws {
        guard frame > framesWritten else { return }
        guard let silence = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_000) else { return }
        while framesWritten < frame {
            silence.frameLength = AVAudioFrameCount(min(16_000, frame - framesWritten))
            if let data = silence.floatChannelData?[0] { memset(data, 0, Int(silence.frameLength) * MemoryLayout<Float>.size) }
            try file.write(from: silence)
            framesWritten += Int64(silence.frameLength)
        }
    }

    func finish(duration: Double) throws {
        try queue.sync {
            if let failure { throw failure }
            try pad(to: Int64(duration * 16_000))
        }
    }
}

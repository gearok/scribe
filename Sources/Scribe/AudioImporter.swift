import AVFoundation
import ScribeCore

enum AudioImporter {
    /// Run off the main thread. AVAssetReader decodes only the asset's audio tracks,
    /// whether they came from an audio file or a video container.
    static func convert(source: URL, directory: URL) async throws -> Double {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ScribeError.message("This file does not contain an audio track.")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outputURL = directory.appendingPathComponent(AudioTrack.system.filename)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw ScribeError.message("Could not open this audio or video file.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ScribeError.message("Could not open this audio or video file.")
        }

        let writer = try AudioTrackWriter(url: outputURL, startHostTime: 1, meter: { _ in })
        var duration = 0.0
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let time = max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)))
                let sampleDuration = CMTimeGetSeconds(CMSampleBufferGetDuration(sample))
                var decodedDuration = 0.0
                try withPCMBuffer(from: sample) { buffer in
                    decodedDuration = Double(buffer.frameLength) / buffer.format.sampleRate
                    try writer.appendSynchronously(
                        buffer,
                        hostTime: 1 + AVAudioTime.hostTime(forSeconds: time)
                    )
                }
                duration = max(duration, time + (sampleDuration.isFinite && sampleDuration > 0 ? sampleDuration : decodedDuration))
            }
        } catch {
            reader.cancelReading()
            throw error
        }
        guard reader.status == .completed else {
            throw reader.error ?? ScribeError.message("Could not read the imported audio.")
        }
        guard duration > 0 else {
            throw ScribeError.message("This file does not contain readable audio.")
        }
        try writer.finish(duration: duration)
        completed = true
        return duration
    }

    private static func withPCMBuffer<T>(
        from sample: CMSampleBuffer,
        body: (AVAudioPCMBuffer) throws -> T
    ) throws -> T {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            throw ScribeError.message("The imported audio has an unsupported format.")
        }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
        )
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  bufferListNoCopy: &bufferList,
                  deallocator: nil
              ) else {
            throw ScribeError.message("Could not read the imported audio.")
        }
        buffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        return try withExtendedLifetime(blockBuffer) { try body(buffer) }
    }
}

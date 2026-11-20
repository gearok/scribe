import AVFoundation
import CoreAudio
import ScribeCore

struct CaptureSource: Identifiable, Hashable {
    let id: Int32
    let name: String
    static let all = CaptureSource(id: 0, name: "All system audio")
    static let microphone = CaptureSource(id: -1, name: "Microphone only")
}

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

final class AudioCaptureService {
    private var engine: AVAudioEngine?
    private var micWriter: AudioTrackWriter?
    private var systemWriter: AudioTrackWriter?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var beganHostTime: UInt64 = 0
    private var isCapturing = false
    private var micTapInstalled = false

    func start(directory: URL, source: CaptureSource,
               meter: @Sendable @escaping (AudioTrack, Float) -> Void) async throws {
        guard !isCapturing else { throw ScribeError.message("A recording is already in progress.") }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw ScribeError.message("Microphone access is off. Enable Scribe in System Settings → Privacy & Security → Microphone.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        beganHostTime = mach_absolute_time()
        do {
            micWriter = try AudioTrackWriter(url: directory.appendingPathComponent(AudioTrack.microphone.filename), startHostTime: beganHostTime) { meter(.microphone, $0) }
            let engine = AVAudioEngine()
            self.engine = engine
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ScribeError.message("No microphone is available. Connect an input device and try again.") }
            let micWriter = self.micWriter!
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
                micWriter.append(buffer, hostTime: time.isHostTimeValid ? time.hostTime : mach_absolute_time())
            }
            micTapInstalled = true
            engine.prepare()
            try engine.start()
            if source.id != -1 {
                systemWriter = try AudioTrackWriter(url: directory.appendingPathComponent(AudioTrack.system.filename), startHostTime: beganHostTime) { meter(.system, $0) }
                try startSystemAudio(source: source)
            }
            isCapturing = true
        } catch {
            _ = try? stop()
            throw error
        }
    }

    private func processObject(pid: Int32) throws -> AudioObjectID {
        var pid = pid
        var object: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<Int32>.size), &pid, &size, &object), "Find the meeting application's audio")
        guard object != 0 else { throw ScribeError.message("The selected application has no audio process. Start the meeting audio, or select All system audio.") }
        return object
    }

    private func startSystemAudio(source: CaptureSource) throws {
        let description: CATapDescription
        if source.id == 0 {
            let ownProcess = try? processObject(pid: ProcessInfo.processInfo.processIdentifier)
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? [])
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: [try processObject(pid: source.id)])
        }
        description.name = "Scribe meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Start system audio capture. Allow Scribe in System Settings → Privacy & Security → Screen & System Audio Recording")
        var stream = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &stream), "Read the system audio format")
        guard let format = AVAudioFormat(streamDescription: &stream) else { throw ScribeError.message("The system audio format is unavailable.") }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Scribe capture",
            kAudioAggregateDeviceUIDKey: "app.scribe.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID), "Create the system audio input")
        guard let writer = systemWriter else { return }
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            let bytes = inputData.pointee.mBuffers.mDataByteSize
            buffer.frameLength = bytes / max(1, stream.mBytesPerFrame)
            writer.append(buffer, hostTime: inputTime.pointee.mHostTime > 0 ? inputTime.pointee.mHostTime : mach_absolute_time())
        }, "Attach the system audio recorder")
        try check(AudioDeviceStart(aggregateID, ioProc), "Start meeting audio recording")
    }

    @discardableResult
    func stop() throws -> Double {
        let duration = beganHostTime > 0 ? AVAudioTime.seconds(forHostTime: mach_absolute_time() - beganHostTime) : 0
        if let engine {
            if micTapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        micTapInstalled = false
        engine = nil
        if aggregateID != 0, let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        var writeError: Error?
        do { try micWriter?.finish(duration: duration) } catch { writeError = error }
        do { try systemWriter?.finish(duration: duration) } catch { writeError = error }
        micWriter = nil; systemWriter = nil; isCapturing = false; beganHostTime = 0
        if let writeError { throw writeError }
        return duration
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw ScribeError.message(L10n.format("%@ failed (audio error %d).", L10n.text(operation), status)) }
    }
}

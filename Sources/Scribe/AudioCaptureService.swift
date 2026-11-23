import AVFoundation
import CoreAudio
import ScribeCore

struct CaptureSource: Identifiable, Hashable {
    let id: Int32
    let name: String
    static let all = CaptureSource(id: 0, name: "All system audio")
    static let microphone = CaptureSource(id: -1, name: "Microphone only")
}

@MainActor
final class AudioCaptureService {
    private var microphoneSession: MicrophoneCaptureSession?
    private var micWriter: AudioTrackWriter?
    private var systemWriter: AudioTrackWriter?
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var beganHostTime: UInt64 = 0
    private var isCapturing = false
    private var reportWarning: @Sendable (String) -> Void = { _ in }

    func start(directory: URL, source: CaptureSource,
               warning: @escaping @Sendable (String) -> Void = { _ in },
               meter: @Sendable @escaping (AudioTrack, Float) -> Void) async throws {
        guard !isCapturing else { throw ScribeError.message("A recording is already in progress.") }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw ScribeError.message("Microphone access is off. Enable Scribe in System Settings → Privacy & Security → Microphone.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        beganHostTime = mach_absolute_time()
        reportWarning = warning
        do {
            micWriter = try AudioTrackWriter(url: directory.appendingPathComponent(AudioTrack.microphone.filename), startHostTime: beganHostTime) { meter(.microphone, $0) }
            let microphoneSession = MicrophoneCaptureSession(writer: micWriter!, reportInterruption: warning)
            self.microphoneSession = microphoneSession
            try microphoneSession.start()
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
        microphoneSession?.stop(); microphoneSession = nil
        if aggregateID != 0, let ioProc {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        var writeError: Error?
        do {
            if let micWriter, try !micWriter.finish(duration: duration), duration >= 3 {
                reportWarning("No microphone audio was captured. Check the selected input device and microphone level in System Settings → Sound before recording again.")
            }
        } catch { writeError = error }
        do { try systemWriter?.finish(duration: duration) } catch { writeError = error }
        micWriter = nil; systemWriter = nil; isCapturing = false; beganHostTime = 0
        reportWarning = { _ in }
        if let writeError { throw writeError }
        return duration
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw ScribeError.message(L10n.format("%@ failed (audio error %d).", L10n.text(operation), status)) }
    }
}

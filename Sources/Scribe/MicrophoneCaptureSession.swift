import AVFoundation

@MainActor
protocol MicrophoneInput: AnyObject {
    var configurationChangeObject: AnyObject { get }
    var isRunning: Bool { get }
    func start(receive: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws
    func stop()
}

@MainActor
private final class EngineMicrophoneInput: MicrophoneInput {
    private let engine = AVAudioEngine()
    private var hasTap = false

    var configurationChangeObject: AnyObject { engine }
    var isRunning: Bool { engine.isRunning }

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws {
        let input = engine.inputNode
        let hardwareFormat = input.inputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw ScribeError.message("No microphone is available. Connect an input device and try again.")
        }
        // Let the input node use its native format. Bluetooth profile changes can
        // invalidate an explicit format between reading it and installing the tap.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in
            receive(buffer, time.isHostTimeValid ? time.hostTime : mach_absolute_time())
        }
        hasTap = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if hasTap { engine.inputNode.removeTap(onBus: 0); hasTap = false }
        engine.stop()
    }
}

private final class MicrophoneBufferArrival: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval?

    func record(_ time: TimeInterval) { lock.lock(); last = time; lock.unlock() }
    func latest() -> TimeInterval? { lock.lock(); defer { lock.unlock() }; return last }
}

/// Rebuild the input tap after route changes, keeping the same writer and meeting
/// clock. AVAudioEngine stops itself on sample-rate/channel changes (notably Bluetooth).
@MainActor
final class MicrophoneCaptureSession {
    private let writer: AudioTrackWriter
    private let makeInput: @MainActor () -> any MicrophoneInput
    private let now: @Sendable () -> TimeInterval
    private let recoveryDelay: UInt64
    private let reportInterruption: @Sendable (String) -> Void
    private var input: (any MicrophoneInput)?
    private var observer: NSObjectProtocol?
    private var recoveryTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var arrivals = MicrophoneBufferArrival()
    private var generation = UUID()
    private var startedAt: TimeInterval = 0
    private var active = false
    private var recoveryAttempts = 0
    private var reportedInterruption = false

    init(writer: AudioTrackWriter,
         makeInput: (@MainActor () -> any MicrophoneInput)? = nil,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         recoveryDelay: UInt64 = 250_000_000,
         reportInterruption: @escaping @Sendable (String) -> Void) {
        self.writer = writer; self.now = now
        if let makeInput {
            self.makeInput = makeInput
        } else {
            // Keep the engine alive across tap rebuilds. Deallocating the final
            // Bluetooth input engine can switch the headset back to its playback
            // profile and trigger another format change as soon as we reopen it.
            let input = EngineMicrophoneInput()
            self.makeInput = { input }
        }
        self.recoveryDelay = recoveryDelay; self.reportInterruption = reportInterruption
    }

    func start() throws {
        active = true
        do { try replaceInput() }
        catch { stop(); throw error }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self else { return }
                self.checkInput()
            }
        }
    }

    func stop() {
        active = false; generation = UUID()
        recoveryTask?.cancel(); recoveryTask = nil
        monitoringTask?.cancel(); monitoringTask = nil
        detachInput()
    }

    func checkInput() {
        guard active, recoveryTask == nil else { return }
        let lastArrival = arrivals.latest() ?? startedAt
        if now() - lastArrival >= 3 || (input?.isRunning == false && now() - startedAt >= 1) {
            scheduleRecovery()
        } else if arrivals.latest() != nil {
            recoveryAttempts = 0
        }
    }

    private func detachInput() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        input?.stop(); input = nil
    }

    private func replaceInput() throws {
        detachInput()
        let next = makeInput()
        input = next
        generation = UUID()
        let currentGeneration = generation
        let arrivals = MicrophoneBufferArrival()
        self.arrivals = arrivals
        startedAt = now()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                           object: next.configurationChangeObject, queue: nil) { [weak self] _ in
            // Apple's notification can arrive on an internal audio queue. Rebuild
            // later on the main actor, never tear down the engine inside that callback.
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.scheduleRecovery()
            }
        }
        let writer = writer, now = now
        try next.start { buffer, hostTime in
            arrivals.record(now())
            writer.append(buffer, hostTime: hostTime)
        }
    }

    private func scheduleRecovery() {
        guard active, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self, recoveryDelay] in
            do { try await Task.sleep(nanoseconds: recoveryDelay) } catch { return }
            guard let self, self.active else { return }
            self.recoveryTask = nil
            self.recoveryAttempts += 1
            do { try self.replaceInput() }
            catch { self.reportOnce() }
            if self.recoveryAttempts >= 3 { self.reportOnce() }
        }
    }

    private func reportOnce() {
        guard !reportedInterruption else { return }
        reportedInterruption = true
        reportInterruption("Microphone audio was interrupted. Scribe is trying to reconnect. Check your input device in System Settings → Sound.")
    }
}

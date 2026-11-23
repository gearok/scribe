import XCTest
import AVFoundation
@testable import Scribe

@MainActor
private final class TestMicrophoneInput: MicrophoneInput {
    private let object = NSObject()
    var configurationChangeObject: AnyObject { object }
    var isRunning = false
    var startError: Error?
    var startCount = 0
    var stopCount = 0
    var receive: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?

    func start(receive: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws {
        startCount += 1
        if let startError { throw startError }
        self.receive = receive
        isRunning = true
    }

    func stop() { stopCount += 1; isRunning = false; receive = nil }

    func changeConfiguration() {
        isRunning = false
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: object)
    }
}

private final class TestCaptureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); value += seconds; lock.unlock() }
}

@MainActor
final class MicrophoneCaptureTests: XCTestCase {
    private func makeWriter() throws -> AudioTrackWriter {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-mic-recovery-\(UUID().uuidString).caf")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try AudioTrackWriter(url: url, startHostTime: 1, meter: { _ in })
    }

    func testConfigurationChangesReplaceInputOnceAndIgnoreOldEngineNotifications() async throws {
        let first = TestMicrophoneInput(), second = TestMicrophoneInput()
        let restarted = expectation(description: "Microphone reconnected")
        var creations = 0
        let session = MicrophoneCaptureSession(writer: try makeWriter(), makeInput: {
            creations += 1
            if creations == 2 { restarted.fulfill() }
            return creations == 1 ? first : second
        }, recoveryDelay: 10_000_000, reportInterruption: { _ in XCTFail("Unexpected interruption") })
        defer { session.stop() }
        try session.start()
        first.changeConfiguration()
        first.changeConfiguration()
        first.changeConfiguration()
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.startCount, 1)
        first.changeConfiguration()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(creations, 2)
    }

    func testStoppingCancelsAPendingReconnect() async throws {
        let input = TestMicrophoneInput()
        var creations = 0
        let session = MicrophoneCaptureSession(writer: try makeWriter(), makeInput: {
            creations += 1; return input
        }, recoveryDelay: 50_000_000, reportInterruption: { _ in XCTFail("Warning after stop") })
        try session.start()
        input.changeConfiguration()
        await Task.yield()
        session.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(input.stopCount, 1)
    }

    func testRebuildingTapOnTheSameEngineKeepsTheBluetoothInputAlive() async throws {
        let input = TestMicrophoneInput()
        let restarted = expectation(description: "Existing input restarted")
        var creations = 0
        let session = MicrophoneCaptureSession(writer: try makeWriter(), makeInput: {
            creations += 1
            if creations == 2 { restarted.fulfill() }
            return input
        }, recoveryDelay: 0, reportInterruption: { _ in XCTFail("Unexpected interruption") })
        defer { session.stop() }
        try session.start()
        input.changeConfiguration()
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(input.startCount, 2)
        XCTAssertEqual(input.stopCount, 1)
        XCTAssertTrue(input.isRunning)
    }

    func testMissingCallbacksTriggerRecoveryEvenWithoutAConfigurationNotification() async throws {
        let first = TestMicrophoneInput(), second = TestMicrophoneInput()
        let restarted = expectation(description: "Stalled input reconnected")
        let clock = TestCaptureClock()
        var creations = 0
        let session = MicrophoneCaptureSession(writer: try makeWriter(), makeInput: {
            creations += 1
            if creations == 2 { restarted.fulfill() }
            return creations == 1 ? first : second
        }, now: { clock.read() }, recoveryDelay: 0, reportInterruption: { _ in XCTFail("Unexpected interruption") })
        defer { session.stop() }
        try session.start()
        clock.advance(4)
        session.checkInput()
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertTrue(second.isRunning)
    }

    func testReceivingSilentBuffersIsHealthyAndDoesNotCauseReconnectLoops() async throws {
        let input = TestMicrophoneInput()
        let clock = TestCaptureClock()
        let writer = try makeWriter()
        var creations = 0
        let session = MicrophoneCaptureSession(writer: writer, makeInput: {
            creations += 1; return input
        }, now: { clock.read() }, recoveryDelay: 0, reportInterruption: { _ in XCTFail("Unexpected interruption") })
        defer { session.stop() }
        try session.start()
        clock.advance(20)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        for index in 0..<1_600 { buffer.floatChannelData![0][index] = 0 }
        input.receive?(buffer, 1)
        session.checkInput()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(creations, 1)
        XCTAssertFalse(try writer.finish(duration: 0.1))
    }

    func testFailedReconnectReportsTheProblemAndCanRecoverLater() async throws {
        enum Failure: Error { case disconnected }
        let first = TestMicrophoneInput(), failed = TestMicrophoneInput(), restored = TestMicrophoneInput()
        failed.startError = Failure.disconnected
        let warning = expectation(description: "Input failure is visible")
        let recovered = expectation(description: "Input restored")
        let clock = TestCaptureClock()
        var creations = 0
        let session = MicrophoneCaptureSession(writer: try makeWriter(), makeInput: {
            creations += 1
            if creations == 3 { recovered.fulfill() }
            return creations == 1 ? first : (creations == 2 ? failed : restored)
        }, now: { clock.read() }, recoveryDelay: 0, reportInterruption: { _ in warning.fulfill() })
        defer { session.stop() }
        try session.start()
        first.changeConfiguration()
        await fulfillment(of: [warning], timeout: 2)
        clock.advance(4)
        session.checkInput()
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertTrue(restored.isRunning)
        XCTAssertEqual(failed.stopCount, 1)
    }
}

import AppKit
import Combine
import Sparkle

/// Keeps Sparkle's pending restart out of an active recording or processing job.
@MainActor
final class UpdateInstallationGate {
    private var resume: (() -> Void)?
    var isBusy = false {
        didSet {
            guard !isBusy, let resume else { return }
            self.resume = nil
            resume()
        }
    }

    func postpone(_ install: @escaping () -> Void) -> Bool {
        guard isBusy else { return false }
        resume = install
        return true
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isBusy = false
    @Published private(set) var automaticallyChecksForUpdates = false
    private var controller: SPUStandardUpdaterController!
    private weak var model: AppModel?
    private var observation: AnyCancellable?
    private let installationGate = UpdateInstallationGate()

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
    }

    func start(model: AppModel) {
        // Tests and isolated demo libraries must never start a network check or install an update.
        guard !isEnabled, !model.isDemo, Bundle.main.bundleURL.pathExtension == "app" else { return }
        self.model = model
        refreshActivity()
        observation = model.objectWillChange.sink { [weak self] in
            // @Published emits before its value changes. Read the completed state on the next turn.
            Task { @MainActor in self?.refreshActivity() }
        }
        isEnabled = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        guard isEnabled, !hasActiveWork, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isEnabled else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    private var hasActiveWork: Bool { model.map { $0.isBusy || $0.isPreparingModels } ?? false }

    private func refreshActivity() {
        isBusy = hasActiveWork
        installationGate.isBusy = isBusy
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !hasActiveWork else {
            throw NSError(domain: "app.scribe.mac.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.text("Updates are paused while recording or processing.")])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        refreshActivity()
        return installationGate.postpone(installHandler)
    }
}

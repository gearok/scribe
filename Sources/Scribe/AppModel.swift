import AppKit
import AVFoundation
import Combine
import ScribeCore
import UniformTypeIdentifiers
import IOKit.pwr_mgt

@MainActor
final class AppModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published private(set) var recordingByteCounts: [String: Int64] = [:]
    @Published private(set) var uncompressedRecordingIDs: Set<String> = []
    @Published var folders: [RecordingFolder] = []
    @Published var folderAssignments: [String: String] = [:]
    @Published private(set) var selectedFolderID: String?
    @Published var selectedID: String?
    @Published var speakers: [Speaker] = []
    @Published var segments: [TranscriptSegment] = [] {
        didSet { overlappingSegmentIDs = TranscriptInterleaver.overlappingSegmentIDs(in: segments) }
    }
    private(set) var overlappingSegmentIDs: Set<String> = []
    @Published var search = ""
    @Published var searchFocusRequest = 0
    @Published var transcriptSearch = ""
    @Published var transcriptSearchFocusRequest = 0
    @Published var showNewRecording = false
    @Published var showNewFolder = false
    @Published var showSettings = false
    @Published var showSpeakers = false
    @Published var errorMessage: String?
    @Published var recordingID: String?
    @Published var processingID: String?
    @Published private(set) var compressionID: String?
    @Published var processingStep = ""
    @Published var processingProgress: Double?
    @Published var isStarting = false
    @Published var modelsReady = false
    @Published var isPreparingModels = false
    @Published var modelStep = ""
    @Published var modelProgress: Double?
    @Published var modelSetupPhase: ModelSetupPhase = .waiting
    @Published var availableModelComponents: Set<TranscriptionModelComponent> = []
    @Published var isImporting = false
    @Published var appearance: AppAppearance = .saved() {
        didSet { appearance.save() }
    }
    @Published var interfaceLanguage: InterfaceLanguage = L10n.language {
        didSet { interfaceLanguage.save() }
    }
    @Published var defaultLanguage: MeetingLanguage = MeetingLanguage(rawValue: UserDefaults.standard.string(forKey: "defaultLanguage") ?? "auto") ?? .automatic {
        didSet { UserDefaults.standard.set(defaultLanguage.rawValue, forKey: "defaultLanguage") }
    }
    @Published var transcriptTextSize = TranscriptTextSize.saved() {
        didSet { TranscriptTextSize.save(transcriptTextSize) }
    }
    let playback = PlaybackController()
    let recordingActivity = RecordingActivity()
    let rootDirectory: URL
    let isDemo: Bool
    private let database: LibraryDatabase?
    private let transcription: TranscriptionService
    private let capture = AudioCaptureService()
    private var processingTask: Task<Void, Never>?
    private var compressionTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: TimeInterval?
    private var isShuttingDown = false
    private var powerAssertion: IOPMAssertionID = 0

    var selectedRecording: Recording? { recordings.first { $0.id == selectedID } }
    var isBusy: Bool { recordingID != nil || processingID != nil || compressionID != nil || isStarting || isImporting }
    var selectedFolder: RecordingFolder? { folders.first { $0.id == selectedFolderID } }
    var selectedFolderTitle: String { selectedFolder?.name ?? L10n.text("All Recordings") }
    var folderRecordings: [Recording] {
        recordings.filter { selectedFolderID == nil || folderAssignments[$0.id] == selectedFolderID }
    }
    var filteredRecordings: [Recording] {
        folderRecordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var filteredSegments: [TranscriptSegment] {
        guard !transcriptSearch.isEmpty else { return segments }
        let matchingSpeakers = Set(speakers.filter {
            $0.displayName(in: interfaceLanguage).localizedCaseInsensitiveContains(transcriptSearch)
        }.map(\.id))
        return segments.filter {
            $0.text.localizedCaseInsensitiveContains(transcriptSearch) || matchingSpeakers.contains($0.speakerID)
        }
    }

    init(isDemo: Bool = CommandLine.arguments.contains("--demo"), dataDirectory: URL? = nil) {
        self.isDemo = isDemo
        let customRoot = ProcessInfo.processInfo.environment["SCRIBE_DATA_DIR"].map { URL(fileURLWithPath: $0) }
        rootDirectory = dataDirectory ?? (isDemo
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Scribe-Demo-\(UUID().uuidString)")
            : customRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scribe"))
        transcription = TranscriptionService(modelsDirectory: rootDirectory.appendingPathComponent("Models"))
        do {
            try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            database = try LibraryDatabase(url: rootDirectory.appendingPathComponent("library.sqlite"))
        } catch {
            database = nil
            errorMessage = L10n.format("The recording library could not be opened: %@", error.localizedDescription)
        }
        do {
            if isDemo, let database { try DemoLibrary.seed(in: database) }
            if let database {
                for var recording in try database.recordings() where recording.status == .recording || recording.status == .processing {
                    recording.status = recording.status == .recording ? .interrupted : .captured
                    recording.errorMessage = "Scribe closed before this finished. Your saved audio is available to process again."
                    if let file = try? AVAudioFile(forReading: RecordingStorage.audioURL(for: recording.hasSystemAudio ? .system : .microphone, in: directory(for: recording))) {
                        recording.duration = Double(file.length) / file.processingFormat.sampleRate
                    }
                    try database.save(recording)
                }
            }
            try reload()
            selectedID = recordings.first?.id
            select(selectedID)
        } catch { errorMessage = error.localizedDescription }
        Task { await refreshModelAvailability() }
    }

    private func startRecordingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
                if Int(elapsed) != Int(self.recordingActivity.elapsed), let recording = self.recordings.first(where: { $0.id == self.recordingID }) {
                    self.recordingByteCounts[recording.id] = RecordingStorage.audioByteCount(in: self.directory(for: recording))
                }
                self.recordingActivity.elapsed = elapsed
            }
        }
    }

    deinit { timer?.invalidate() }

    func directory(for recording: Recording) -> URL {
        rootDirectory.appendingPathComponent("Recordings").appendingPathComponent(recording.id)
    }
    func speaker(for id: String) -> Speaker? { speakers.first { $0.id == id } }
    func reload(refreshAudioStorage: Bool = true) throws {
        recordings = try database?.recordings() ?? []
        // Most library changes do not touch audio. Retain cached sizes on those paths.
        recordingByteCounts = Dictionary(uniqueKeysWithValues: recordings.map {
            ($0.id, !refreshAudioStorage ? recordingByteCounts[$0.id] ?? RecordingStorage.audioByteCount(in: directory(for: $0))
                : RecordingStorage.audioByteCount(in: directory(for: $0)))
        })
        if refreshAudioStorage {
            uncompressedRecordingIDs = Set(recordings.filter { RecordingStorage.hasUncompressedAudio(in: directory(for: $0)) }.map(\.id))
        } else {
            let existingIDs = Set(recordings.map(\.id))
            uncompressedRecordingIDs.formIntersection(existingIDs)
        }
        folders = try database?.folders() ?? []
        folderAssignments = try database?.folderAssignments() ?? [:]
    }

    private func refreshRecordingStorage(for recording: Recording) {
        recordingByteCounts[recording.id] = RecordingStorage.audioByteCount(in: directory(for: recording))
        if RecordingStorage.hasUncompressedAudio(in: directory(for: recording)) {
            uncompressedRecordingIDs.insert(recording.id)
        } else {
            uncompressedRecordingIDs.remove(recording.id)
        }
    }

    private func updateCachedRecording(_ recording: Recording) {
        guard let index = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[index] = recording
    }

    func folder(for recording: Recording) -> RecordingFolder? {
        folders.first { $0.id == folderAssignments[recording.id] }
    }

    func selectFolder(_ id: String?) {
        guard id == nil || folders.contains(where: { $0.id == id }) else { return }
        selectedFolderID = id
        if !filteredRecordings.contains(where: { $0.id == selectedID }) {
            select(filteredRecordings.first?.id)
        }
    }

    @discardableResult
    func createFolder(name: String, color: FolderColor = .gray) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let database else { return false }
        do {
            let folder = RecordingFolder(name: name, color: color)
            try database.saveFolder(folder)
            folders = try database.folders()
            selectFolder(folder.id)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func moveRecordings(_ ids: [String], toFolder folderID: String?) -> Bool {
        guard !ids.isEmpty, let database,
              folderID == nil || folders.contains(where: { $0.id == folderID }),
              ids.allSatisfy({ id in recordings.contains { $0.id == id } }) else { return false }
        do {
            try database.moveRecordings(ids, toFolder: folderID)
            folderAssignments = try database.folderAssignments()
            if !folderRecordings.contains(where: { $0.id == selectedID }) {
                select(filteredRecordings.first?.id)
            }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func select(_ id: String?) {
        selectedID = id
        transcriptSearch = ""
        do {
            let transcript = try id.flatMap { try database?.transcript(recordingID: $0) }
            speakers = transcript?.speakers ?? []; segments = transcript?.segments ?? []
            if recordingID != id { try playback.load(selectedRecording, directory: selectedRecording.map(directory(for:))) }
            else { try playback.load(nil, directory: nil) }
        } catch { errorMessage = error.localizedDescription }
    }

    func sources() -> [CaptureSource] {
        [CaptureSource.all, .microphone] + NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.localizedName.map { CaptureSource(id: app.processIdentifier, name: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func startRecording(title: String, source: CaptureSource, language: MeetingLanguage) {
        guard !isBusy, !isDemo, let database else { return }
        let destinationFolderID = selectedFolderID
        isStarting = true; playback.pause()
        Task { [self] in
            let date = Date()
            let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            var recording = Recording(title: enteredTitle.isEmpty ? RecordingPresentation.dateAndTime(date) : enteredTitle, createdAt: date,
                                      status: .recording, language: language, sourceName: source.name, hasSystemAudio: source.id != -1)
            do {
                try database.save(recording)
                if let destinationFolderID { try database.moveRecordings([recording.id], toFolder: destinationFolderID) }
                let captureRecordingID = recording.id
                try await capture.start(directory: directory(for: recording), source: source, warning: { [weak self] message in
                    Task { @MainActor in self?.errorMessage = L10n.text(message) }
                }) { [weak self] track, level in
                    Task { @MainActor in
                        guard self?.recordingID == captureRecordingID else { return }
                        if track == .microphone { self?.recordingActivity.microphoneLevel = level }
                        else { self?.recordingActivity.systemLevel = level }
                    }
                }
                recordingID = recording.id; startedAt = ProcessInfo.processInfo.systemUptime; recordingActivity.reset()
                startRecordingTimer()
                preventSleep()
                try reload(refreshAudioStorage: false); refreshRecordingStorage(for: recording)
                selectFolder(destinationFolderID); select(recording.id); showNewRecording = false
            } catch {
                recording.status = .failed; recording.errorMessage = error.localizedDescription
                try? database.save(recording); try? reload(refreshAudioStorage: false)
                refreshRecordingStorage(for: recording); select(recording.id)
                errorMessage = error.localizedDescription
            }
            isStarting = false
        }
    }

    func stopRecording() {
        guard let id = recordingID, var recording = recordings.first(where: { $0.id == id }) else { return }
        do {
            recording.duration = try capture.stop()
            recording.status = .captured
            recording.errorMessage = nil
            try database?.save(recording)
        } catch {
            recording.status = .failed; recording.duration = recordingActivity.elapsed; recording.errorMessage = error.localizedDescription
            try? database?.save(recording); errorMessage = error.localizedDescription
        }
        timer?.invalidate(); timer = nil
        recordingID = nil; startedAt = nil; recordingActivity.reset()
        allowSleep()
        updateCachedRecording(recording); refreshRecordingStorage(for: recording); select(id)
        if recording.status == .captured {
            if modelsReady { process(recording) }
            else { compressRecording(recording) }
        }
    }

    func compressRecording(_ recording: Recording) {
        guard !isBusy, !isDemo, uncompressedRecordingIDs.contains(recording.id),
              recording.status != .recording && recording.status != .processing else { return }
        compressionID = recording.id
        preventSleep()
        compressionTask = Task { [self] in
            await compressAudioFiles(for: recording)
            compressionID = nil; compressionTask = nil
            allowSleep()
        }
    }

    private func compressAudioFiles(for recording: Recording) async {
        compressionID = recording.id
        defer { compressionID = nil }
        let directory = directory(for: recording)
        let work = Task.detached(priority: .utility) { try AudioCompressor.compress(in: directory) }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch is CancellationError {
            // The compressor retains any track that has not been safely replaced.
        } catch {
            errorMessage = L10n.format("Audio compression failed. Uncompressed tracks have been kept: %@", error.localizedDescription)
        }
        do {
            refreshRecordingStorage(for: recording)
            if selectedID == recording.id {
                let position = playback.position
                let wasPlaying = playback.isPlaying
                try playback.load(nil, directory: nil)
                try playback.load(selectedRecording, directory: directory)
                playback.seek(to: position)
                if wasPlaying { playback.play() }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func process(_ recording: Recording) {
        guard !isBusy, !isPreparingModels, !isDemo, let database else { return }
        guard let recording = recordings.first(where: { $0.id == recording.id }) else { return }
        guard modelsReady else { showSettings = true; return }
        processingID = recording.id; processingStep = "Preparing your recording"; processingProgress = nil
        var pending = recording; pending.status = .processing; pending.errorMessage = nil
        do { try database.save(pending); updateCachedRecording(pending) } catch { processingID = nil; errorMessage = error.localizedDescription; return }
        preventSleep()
        let directory = directory(for: recording)
        processingTask = Task { [self] in
            var transcriptSaved = false
            do {
                let (speakers, segments) = try await transcription.process(recording: recording, directory: directory) { [self] step, fraction in
                    await updateProcessing(step, fraction)
                }
                try Task.checkCancellation()
                // Preserve title edits made while the models were working.
                var finished = recordings.first { $0.id == recording.id } ?? recording
                finished.status = .ready; finished.errorMessage = nil
                try database.saveTranscript(recording: finished, speakers: speakers, segments: segments)
                updateCachedRecording(finished)
                if selectedID == finished.id { select(finished.id) }
                transcriptSaved = true
            } catch {
                var failed = recordings.first { $0.id == recording.id } ?? recording
                failed.status = error is CancellationError ? .captured : .failed
                failed.errorMessage = error is CancellationError ? nil : error.localizedDescription
                try? database.save(failed)
                updateCachedRecording(failed)
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            if transcriptSaved && !Task.isCancelled {
                processingStep = "Compressing audio…"; processingProgress = nil
                await compressAudioFiles(for: recording)
            }
            processingID = nil; processingTask = nil; allowSleep()
        }
    }

    func cancelProcessing() { processingTask?.cancel(); processingStep = "Stopping after the current step…" }

    func prepareModels(redownload: Bool = false) {
        guard !isPreparingModels, !isBusy, !isDemo else { return }
        isPreparingModels = true; modelStep = "Preparing downloads"; modelProgress = nil
        modelSetupPhase = .waiting
        if redownload {
            modelsReady = false
            availableModelComponents = []
        }
        modelsTask = Task { [self] in
            do {
                if redownload { try await transcription.deleteDownloadedModels() }
                try Task.checkCancellation()
                try await transcription.prepare { [self] step, progress in
                    await updateModels(step, progress)
                }
                modelsReady = true
            } catch { errorMessage = error.localizedDescription }
            await refreshModelAvailability()
            isPreparingModels = false; modelsTask = nil
        }
    }

    func renameRecording(_ recording: Recording, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        guard var changed = recordings.first(where: { $0.id == recording.id }) else { return }
        changed.title = title
        do { try database?.save(changed); updateCachedRecording(changed) } catch { errorMessage = error.localizedDescription }
    }

    func changeLanguage(_ recording: Recording, to language: MeetingLanguage) {
        guard var changed = recordings.first(where: { $0.id == recording.id }) else { return }
        changed.language = language
        do { try database?.save(changed); updateCachedRecording(changed) } catch { errorMessage = error.localizedDescription }
    }

    func renameSpeaker(_ speaker: Speaker, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var changed = speaker; changed.name = name; changed.isNameCustomized = true
        do {
            try database?.saveSpeaker(changed)
            if let index = speakers.firstIndex(where: { $0.id == speaker.id }) { speakers[index] = changed }
        } catch { errorMessage = error.localizedDescription }
    }

    func mergeSpeaker(_ source: Speaker, into destination: Speaker) {
        do { try database?.mergeSpeaker(source, into: destination); select(selectedID) } catch { errorMessage = error.localizedDescription }
    }

    func reassign(_ segment: TranscriptSegment, to speaker: Speaker) {
        var changed = segment; changed.speakerID = speaker.id
        saveSegment(changed)
    }
    func editText(_ segment: TranscriptSegment, text: String) {
        var changed = segment; changed.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !changed.text.isEmpty else { return }
        if changed.text != segment.text { changed.words = nil }
        saveSegment(changed)
    }
    private func saveSegment(_ segment: TranscriptSegment) {
        do {
            guard try database?.saveSegment(segment) == true else { return }
            if let index = segments.firstIndex(where: { $0.id == segment.id }) { segments[index] = segment }
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ recording: Recording) {
        guard recording.id != recordingID, recording.id != processingID, recording.id != compressionID else { return }
        do {
            // Remove the library entry only after its audio has been successfully removed.
            let folder = directory(for: recording)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try database?.delete(recordingID: recording.id)
            try reload(refreshAudioStorage: false); if selectedID == recording.id { select(filteredRecordings.first?.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func importMedia() {
        guard !isBusy, !isDemo else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.text("Import Audio or Video"); panel.prompt = L10n.text("Import")
        panel.allowedContentTypes = [.audio, .movie, .video]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importMedia(from: source)
    }

    /// Keep native file selection separate from the cancellable import operation.
    func importMedia(from source: URL) {
        guard !isBusy, !isDemo, !isShuttingDown, let database else { return }
        let destinationFolderID = selectedFolderID
        isImporting = true
        preventSleep()
        let recording = Recording(title: source.deletingPathExtension().lastPathComponent, language: defaultLanguage,
                                  sourceName: "Imported media", hasMicrophone: false, hasSystemAudio: true)
        let folder = directory(for: recording)
        importTask = Task { [self] in
            var saved = false
            var result: Recording?
            let conversion = Task.detached(priority: .userInitiated) {
                try await AudioImporter.convert(source: source, directory: folder)
            }
            do {
                let duration = try await withTaskCancellationHandler {
                    try await conversion.value
                } onCancel: {
                    conversion.cancel()
                }
                try Task.checkCancellation()
                var imported = recording; imported.duration = duration
                try database.save(imported)
                saved = true
                if let destinationFolderID { try database.moveRecordings([imported.id], toFolder: destinationFolderID) }
                try reload(refreshAudioStorage: false)
                refreshRecordingStorage(for: imported)
                selectFolder(destinationFolderID)
                select(imported.id)
                result = imported
            } catch is CancellationError {
                // Quitting must cancel decoding and avoid starting a transcription afterwards.
            } catch { errorMessage = error.localizedDescription }
            if !saved { try? FileManager.default.removeItem(at: folder) }
            else if result == nil { try? reload() }
            isImporting = false; importTask = nil; allowSleep()
            if let result, !isShuttingDown {
                if modelsReady { process(result) }
                else { compressRecording(result) }
            }
        }
    }

    func exportTranscript() {
        guard let recording = selectedRecording else { return }
        let panel = NSSavePanel()
        panel.title = L10n.text("Export Transcript"); panel.prompt = L10n.text("Export Transcript")
        panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = recording.title + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = ([recording.title, recording.createdAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(interfaceLanguage.locale)), ""] + segments.map {
            "[\(TimeLabel.clock($0.start))] \(speaker(for: $0.speakerID)?.displayName ?? L10n.text("Unassigned"))\n\($0.text)\n"
        }).joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { errorMessage = error.localizedDescription }
    }

    func revealLibrary() { NSWorkspace.shared.open(rootDirectory) }
    private func updateProcessing(_ step: String, _ progress: Double?) { processingStep = step; processingProgress = progress }
    func modelStatus(_ component: TranscriptionModelComponent) -> ModelComponentStatus {
        component.status(available: availableModelComponents, phase: modelSetupPhase, isPreparing: isPreparingModels)
    }

    func refreshModelsForSettings() async {
        await refreshModelAvailability()
    }

    private func refreshModelAvailability() async {
        availableModelComponents = await transcription.availableModelComponents()
        modelsReady = await transcription.isPrepared()
    }

    private func updateModels(_ phase: ModelSetupPhase, _ progress: Double?) {
        // Whisper callbacks arrive through independent Tasks. Ignore callbacks for
        // stages already completed so the details cannot jump backward.
        guard isPreparingModels, phase.rawValue >= modelSetupPhase.rawValue else { return }
        modelSetupPhase = phase; modelStep = phase.message; modelProgress = progress
    }
    func finishBeforeQuit() {
        isShuttingDown = true
        // Save audio on quit without starting a new inference task during termination.
        if let id = recordingID, var recording = recordings.first(where: { $0.id == id }) {
            do {
                recording.duration = try capture.stop(); recording.status = .captured
                try database?.save(recording)
            } catch {
                recording.duration = recordingActivity.elapsed; recording.status = .interrupted; recording.errorMessage = error.localizedDescription
                try? database?.save(recording)
            }
            timer?.invalidate(); timer = nil
            recordingID = nil; startedAt = nil
        }
        processingTask?.cancel(); compressionTask?.cancel(); importTask?.cancel(); modelsTask?.cancel(); allowSleep()
    }
    private func preventSleep() {
        guard powerAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Scribe is recording or processing a meeting" as CFString, &powerAssertion)
    }
    private func allowSleep() { if powerAssertion != 0 { IOPMAssertionRelease(powerAssertion); powerAssertion = 0 } }
}

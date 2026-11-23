import AppKit
import AVFoundation
import Combine
import ScribeCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var folders: [RecordingFolder] = []
    @Published var folderAssignments: [String: String] = [:]
    @Published private(set) var selectedFolderID: String?
    @Published var selectedID: String?
    @Published var speakers: [Speaker] = []
    @Published var segments: [TranscriptSegment] = []
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
    @Published var processingStep = ""
    @Published var processingProgress: Double?
    @Published var elapsed = 0.0
    @Published var microphoneLevel: Float = 0
    @Published var systemLevel: Float = 0
    @Published var isStarting = false
    @Published var modelsReady = false
    @Published var isPreparingModels = false
    @Published var modelStep = ""
    @Published var modelProgress: Double?
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
    let rootDirectory: URL
    let isDemo: Bool
    private let database: LibraryDatabase?
    private let transcription: TranscriptionService
    private let capture = AudioCaptureService()
    private var processingTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var timer: Timer?
    private var startedAt: Date?
    private var powerAssertion: IOPMAssertionID = 0

    var selectedRecording: Recording? { recordings.first { $0.id == selectedID } }
    var isBusy: Bool { recordingID != nil || processingID != nil || isStarting || isImporting }
    var selectedFolder: RecordingFolder? { folders.first { $0.id == selectedFolderID } }
    var selectedFolderTitle: String { selectedFolder?.name ?? L10n.text("All Recordings") }
    var folderRecordings: [Recording] {
        recordings.filter { selectedFolderID == nil || folderAssignments[$0.id] == selectedFolderID }
    }
    var filteredRecordings: [Recording] {
        folderRecordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var filteredSegments: [TranscriptSegment] {
        segments.filter {
            transcriptSearch.isEmpty || $0.text.localizedCaseInsensitiveContains(transcriptSearch)
                || speaker(for: $0.speakerID)?.name.localizedCaseInsensitiveContains(transcriptSearch) == true
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
            if isDemo { try seedDemo() }
            if let database {
                for var recording in try database.recordings() where recording.status == .recording || recording.status == .processing {
                    recording.status = recording.status == .recording ? .interrupted : .captured
                    recording.errorMessage = "Scribe closed before this finished. Your saved audio is available to process again."
                    if let file = try? AVAudioFile(forReading: directory(for: recording).appendingPathComponent(recording.hasSystemAudio ? "system.caf" : "microphone.caf")) {
                        recording.duration = Double(file.length) / file.processingFormat.sampleRate
                    }
                    try database.save(recording)
                }
            }
            try reload()
            selectedID = recordings.first?.id
            select(selectedID)
        } catch { errorMessage = error.localizedDescription }
        Task { modelsReady = await transcription.isPrepared() }
    }

    private func startRecordingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    deinit { timer?.invalidate() }

    func directory(for recording: Recording) -> URL {
        rootDirectory.appendingPathComponent("Recordings").appendingPathComponent(recording.id)
    }
    func speaker(for id: String) -> Speaker? { speakers.first { $0.id == id } }
    func reload() throws {
        recordings = try database?.recordings() ?? []
        folders = try database?.folders() ?? []
        folderAssignments = try database?.folderAssignments() ?? [:]
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
    func createFolder(name: String, color: FolderColor) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let database else { return false }
        do {
            let folder = RecordingFolder(name: name, color: color)
            try database.saveFolder(folder)
            try reload()
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
                try await capture.start(directory: directory(for: recording), source: source) { [weak self] track, level in
                    Task { @MainActor in
                        if track == .microphone { self?.microphoneLevel = level } else { self?.systemLevel = level }
                    }
                }
                recordingID = recording.id; startedAt = Date(); elapsed = 0
                startRecordingTimer()
                preventSleep()
                try reload(); selectFolder(destinationFolderID); select(recording.id); showNewRecording = false
            } catch {
                recording.status = .failed; recording.errorMessage = error.localizedDescription
                try? database.save(recording); try? reload(); select(recording.id)
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
            recording.status = .failed; recording.duration = elapsed; recording.errorMessage = error.localizedDescription
            try? database?.save(recording); errorMessage = error.localizedDescription
        }
        timer?.invalidate(); timer = nil
        recordingID = nil; startedAt = nil; microphoneLevel = 0; systemLevel = 0
        allowSleep()
        do { try reload(); select(id) } catch { errorMessage = error.localizedDescription }
        if modelsReady && recording.status == .captured { process(recording) }
    }

    func process(_ recording: Recording) {
        guard !isBusy, !isDemo, let database else { return }
        guard modelsReady else { showSettings = true; return }
        processingID = recording.id; processingStep = "Preparing your recording"; processingProgress = nil
        var pending = recording; pending.status = .processing; pending.errorMessage = nil
        do { try database.save(pending); try reload() } catch { processingID = nil; errorMessage = error.localizedDescription; return }
        preventSleep()
        let directory = directory(for: recording)
        processingTask = Task { [self] in
            do {
                let (speakers, segments) = try await transcription.process(recording: recording, directory: directory) { [self] step, fraction in
                    await updateProcessing(step, fraction)
                }
                try Task.checkCancellation()
                // Preserve title edits made while the models were working.
                var finished = recordings.first { $0.id == recording.id } ?? recording
                finished.status = .ready; finished.errorMessage = nil
                try database.saveTranscript(recording: finished, speakers: speakers, segments: segments)
            } catch {
                var failed = recordings.first { $0.id == recording.id } ?? recording
                failed.status = error is CancellationError ? .captured : .failed
                failed.errorMessage = error is CancellationError ? nil : error.localizedDescription
                try? database.save(failed)
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
            processingID = nil; processingTask = nil; allowSleep()
            do { try reload(); select(selectedID) } catch { errorMessage = error.localizedDescription }
        }
    }

    func cancelProcessing() { processingTask?.cancel(); processingStep = "Stopping after the current step…" }

    func prepareModels() {
        guard !isPreparingModels, !isBusy, !isDemo else { return }
        isPreparingModels = true; modelStep = "Preparing downloads"; modelProgress = nil
        modelsTask = Task { [self] in
            do {
                try await transcription.prepare { [self] step, progress in
                    await updateModels(step, progress)
                }
                modelsReady = true
            } catch { errorMessage = error.localizedDescription }
            isPreparingModels = false; modelsTask = nil
        }
    }

    func renameRecording(_ recording: Recording, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var changed = recordings.first(where: { $0.id == recording.id }) ?? recording; changed.title = title
        do { try database?.save(changed); try reload() } catch { errorMessage = error.localizedDescription }
    }

    func changeLanguage(_ recording: Recording, to language: MeetingLanguage) {
        var changed = recordings.first(where: { $0.id == recording.id }) ?? recording; changed.language = language
        do { try database?.save(changed); try reload() } catch { errorMessage = error.localizedDescription }
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
        saveSegment(changed)
    }
    private func saveSegment(_ segment: TranscriptSegment) {
        do {
            try database?.saveSegment(segment)
            if let index = segments.firstIndex(where: { $0.id == segment.id }) { segments[index] = segment }
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ recording: Recording) {
        guard recording.id != recordingID, recording.id != processingID else { return }
        do {
            // Remove the library entry only after its audio has been successfully removed.
            let folder = directory(for: recording)
            if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            try database?.delete(recordingID: recording.id)
            try reload(); if selectedID == recording.id { select(filteredRecordings.first?.id) }
        } catch { errorMessage = error.localizedDescription }
    }

    func importMedia() {
        guard !isBusy, !isDemo else { return }
        let destinationFolderID = selectedFolderID
        let panel = NSOpenPanel()
        panel.title = L10n.text("Import Audio or Video"); panel.prompt = L10n.text("Import")
        panel.allowedContentTypes = [.audio, .movie, .video]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isImporting = true
        let recording = Recording(title: source.deletingPathExtension().lastPathComponent, language: defaultLanguage,
                                  sourceName: "Imported media", hasMicrophone: false, hasSystemAudio: true)
        let folder = directory(for: recording)
        Task {
            do {
                let duration = try await Task.detached(priority: .userInitiated) {
                    try await AudioImporter.convert(source: source, directory: folder)
                }.value
                var imported = recording; imported.duration = duration
                try database?.save(imported)
                if let destinationFolderID { try database?.moveRecordings([imported.id], toFolder: destinationFolderID) }
                try reload()
                selectFolder(destinationFolderID)
                select(imported.id)
                isImporting = false
                if modelsReady { process(imported) }
            } catch { isImporting = false; errorMessage = error.localizedDescription }
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
    private func updateModels(_ step: String, _ progress: Double?) { modelStep = step; modelProgress = progress }
    func finishBeforeQuit() {
        // Save audio on quit without starting a new inference task during termination.
        if let id = recordingID, var recording = recordings.first(where: { $0.id == id }) {
            do {
                recording.duration = try capture.stop(); recording.status = .captured
                try database?.save(recording)
            } catch {
                recording.duration = elapsed; recording.status = .interrupted; recording.errorMessage = error.localizedDescription
                try? database?.save(recording)
            }
            timer?.invalidate(); timer = nil
            recordingID = nil; startedAt = nil
        }
        processingTask?.cancel(); modelsTask?.cancel(); allowSleep()
    }
    private func preventSleep() {
        guard powerAssertion == 0 else { return }
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Scribe is recording or processing a meeting" as CFString, &powerAssertion)
    }
    private func allowSleep() { if powerAssertion != 0 { IOPMAssertionRelease(powerAssertion); powerAssertion = 0 } }

    private func seedDemo() throws {
        guard let database else { return }
        let work = RecordingFolder(name: "Работа", color: .blue)
        let personal = RecordingFolder(name: "Личное", color: .green)
        try database.saveFolder(work)
        try database.saveFolder(personal)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let meeting = Recording(title: "Планирование продукта", createdAt: date(daysAgo: 0, hour: 15, minute: 22), duration: 2528, status: .ready,
                                sourceName: "Google Meet", hasMicrophone: false, hasSystemAudio: false)
        let me = Speaker(recordingID: meeting.id, name: "You", colorIndex: 0, isLocal: true)
        let anna = Speaker(recordingID: meeting.id, name: "Анна", colorIndex: 1)
        let max = Speaker(recordingID: meeting.id, name: "Speaker 2", colorIndex: 2)
        let lines: [(Speaker, Double, String)] = [
            (anna, 12, "Давайте начнём. Сегодня нам нужно договориться о приоритетах на следующий спринт и обсудить обратную связь от пользователей."),
            (me, 28, "Я посмотрел последние интервью. Людям важно быстро находить нужный момент встречи, поэтому предлагаю начать с поиска по расшифровке."),
            (max, 46, "Согласен. А ещё стоит добавить возможность переименовать участников. Тогда запись будет гораздо удобнее читать и отправлять коллегам."),
            (anna, 67, "Хорошая мысль. Let’s keep the first version focused. Запись, расшифровка и понятные имена участников — этого достаточно для начала."),
            (me, 89, "Тогда сохраняем всё локально. После встречи можно прослушать фрагмент, исправить текст и назначить каждому голосу имя."),
            (max, 112, "Я возьму на себя проверку на длинных встречах. Особенно интересно, как обработаются моменты, когда несколько человек говорят одновременно."),
            (anna, 138, "Отлично. Давайте вернёмся с результатами в четверг. Если будут вопросы по дизайну, обсудим их отдельно."),
        ]
        let transcript = lines.map { TranscriptSegment(recordingID: meeting.id, speakerID: $0.0.id, start: $0.1, end: $0.1 + 12, text: $0.2, track: $0.0.isLocal ? .microphone : .system) }
        try database.saveTranscript(recording: meeting, speakers: [me, anna, max], segments: transcript)
        try database.moveRecordings([meeting.id], toFolder: work.id)
        let examples: [(String, Int, Int, Int, String)] = [
            ("Обратная связь клиентов", 0, 11, 30, "Zoom"),
            ("Design catch-up", 1, 16, 0, "Google Meet"),
            ("Обсуждение архитектуры", 1, 10, 15, "Microsoft Teams"),
            ("Еженедельная встреча", 2, 14, 0, "Zoom"),
            ("Интервью с пользователем", 2, 9, 30, "Microphone only"),
            ("Sprint review", 4, 12, 0, "Google Meet"),
        ]
        for (index, example) in examples.enumerated() {
            let (title, daysAgo, hour, minute, source) = example
            let recording = Recording(title: title, createdAt: date(daysAgo: daysAgo, hour: hour, minute: minute),
                                      duration: 1840, status: .captured, sourceName: source, hasMicrophone: false, hasSystemAudio: false)
            try database.save(recording)
            if index < 5 { try database.moveRecordings([recording.id], toFolder: index == 4 ? personal.id : work.id) }
        }
    }
}

import IOKit.pwr_mgt

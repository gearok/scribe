import SwiftUI
import ScribeCore

struct NewRecordingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = RecordingPresentation.dateAndTime()
    @State private var source = CaptureSource.all
    @State private var sources: [CaptureSource] = [.all, .microphone]
    @State private var language: MeetingLanguage = .automatic

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L10n.text("Meeting Title"), text: $title)
                    Picker(L10n.text("Meeting Audio"), selection: $source) {
                        ForEach(sources) { Text($0.id <= 0 ? L10n.text($0.name) : $0.name).tag($0) }
                    }
                    Picker(L10n.text("Language"), selection: $language) {
                        ForEach(MeetingLanguage.allCases, id: \.self) { Text(L10n.text($0.label)).tag($0) }
                    }
                } header: {
                    Text(L10n.text("Start Recording")).font(.headline)
                } footer: {
                    Text(L10n.text("Use headphones for clearer speaker separation. Audio and transcripts stay on this Mac."))
                }
                if !model.modelsReady {
                    Section {
                        Label(L10n.text("You can download transcription models after recording."), systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true)
            HStack {
                if model.isStarting { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.text("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isStarting)
                Button(L10n.text("Start Recording"), systemImage: "record.circle") {
                    model.startRecording(title: title, source: source, language: language)
                }
                .primaryActionStyle().keyboardShortcut(.defaultAction)
                .disabled(model.isStarting || model.isBusy || model.isDemo)
            }.padding()
        }
        .frame(width: 500, height: model.modelsReady ? 300 : 360)
        .modifier(SheetErrorAlert(model: model))
        .interactiveDismissDisabled(model.isStarting)
        .onAppear { sources = model.sources(); language = model.defaultLanguage }
    }
}

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var updates: AppUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.text("Interface")) {
                    Picker(L10n.text("Interface Language"), selection: $model.interfaceLanguage) {
                        ForEach(InterfaceLanguage.allCases) { language in
                            Text(language.name).tag(language)
                        }
                    }
                }
                Section(L10n.text("Local Transcription")) {
                    LabeledContent(L10n.text("Models"), value: L10n.text(model.modelsReady ? "Ready to Use Offline" : "Not Downloaded"))
                    if model.isPreparingModels {
                        Text(L10n.text(model.modelStep))
                        if let progress = model.modelProgress { ProgressView(value: progress) }
                        else { ProgressView().controlSize(.small) }
                        Text(L10n.text("The first setup may take several minutes. Keep Scribe open."))
                            .font(.callout).foregroundStyle(.secondary)
                    } else if !model.modelsReady {
                        Button(L10n.text("Download Models"), systemImage: "arrow.down.circle") { model.prepareModels() }
                            .primaryActionStyle().disabled(model.isBusy || model.isDemo)
                    }
                    Text(L10n.text("Models download from Hugging Face. Meeting audio is processed locally. Allow a few GB of free disk space for setup."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section(L10n.text("Recording")) {
                    Picker(L10n.text("Default Language"), selection: $model.defaultLanguage) {
                        ForEach(MeetingLanguage.allCases, id: \.self) { Text(L10n.text($0.label)).tag($0) }
                    }
                    LabeledContent(L10n.text("Recording Library")) {
                        Button(L10n.text("Show in Finder")) { model.revealLibrary() }
                    }
                }
                Section(L10n.text("Updates")) {
                    LabeledContent(L10n.text("Version"), value: AppUpdater.version)
                    Toggle(L10n.text("Automatically Check for Updates"), isOn: Binding(
                        get: { updates.automaticallyChecksForUpdates },
                        set: { updates.setAutomaticallyChecksForUpdates($0) }
                    )).disabled(!updates.isEnabled)
                    Button(L10n.text("Check for Updates")) { updates.checkForUpdates() }
                        .disabled(!updates.isEnabled || !updates.canCheckForUpdates || updates.isBusy)
                    Text(L10n.text(updates.isBusy ? "Updates are paused while recording or processing." : "Updates download from GitHub and are verified before installation. You choose when to install."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section {
                    Label(L10n.text("Audio, transcripts, and speaker names stay on this Mac."), systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack {
                Text("Scribe \(AppUpdater.version)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 580, height: 580)
        .modifier(SheetErrorAlert(model: model))
    }
}

struct SpeakersSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var mergeSource: Speaker?
    @State private var mergeDestination: Speaker?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Speakers")).font(.headline)
                Text(L10n.text("Rename a speaker throughout this recording, or merge duplicate labels."))
                    .foregroundStyle(.secondary)
            }.padding()
            List {
                ForEach(model.speakers) { speaker in
                    SpeakerEditorRow(speaker: speaker) { destination in
                        mergeSource = speaker; mergeDestination = destination
                    }
                }
            }.listStyle(.inset)
            HStack {
                Text(L10n.text("Overlapping voices may need manual correction.")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.text("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 580, height: 390)
        .modifier(SheetErrorAlert(model: model))
        .alert(L10n.text("Merge these speakers?"), isPresented: Binding(get: { mergeSource != nil }, set: {
            if !$0 { mergeSource = nil; mergeDestination = nil }
        })) {
            Button(L10n.text("Cancel"), role: .cancel) { mergeSource = nil; mergeDestination = nil }
            Button(L10n.text("Merge")) {
                if let source = mergeSource, let destination = mergeDestination { model.mergeSpeaker(source, into: destination) }
                mergeSource = nil; mergeDestination = nil
            }
        } message: {
            Text(L10n.format("All paragraphs from %@ will be assigned to %@.", mergeSource?.displayName ?? "", mergeDestination?.displayName ?? ""))
        }
    }
}

private struct SheetErrorAlert: ViewModifier {
    @ObservedObject var model: AppModel
    func body(content: Content) -> some View {
        content.alert(L10n.text("Scribe needs your attention"), isPresented: Binding(get: { model.errorMessage != nil }, set: {
            if !$0 { model.errorMessage = nil }
        })) {
            Button(L10n.text("OK")) { model.errorMessage = nil }
        } message: { Text(L10n.text(model.errorMessage ?? "")) }
    }
}

private struct SpeakerEditorRow: View {
    @EnvironmentObject private var model: AppModel
    let speaker: Speaker
    let onMerge: (Speaker) -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: speaker.isLocal ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.text("Speaker Name"), text: $name).textFieldStyle(.roundedBorder)
                .focused($focused).onSubmit { save(); focused = false }
                .accessibilityLabel(L10n.format("Name for %@", speaker.displayName))
            Button(L10n.text("Listen"), systemImage: "play.circle") {
                if let segment = model.segments.first(where: { $0.speakerID == speaker.id }) {
                    model.playback.playSegment(segment)
                }
            }
            .labelStyle(.iconOnly)
            .disabled(!model.playback.hasAudio).help(L10n.text("Listen to this speaker"))
            Menu(L10n.text("Merge Speaker"), systemImage: "ellipsis") {
                ForEach(model.speakers.filter { $0.id != speaker.id }) { destination in
                    Button(L10n.format("Merge into %@", destination.displayName)) { save(); onMerge(destination) }
                }
            }
            .labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.speakers.count < 2)
        }
        .padding(.vertical, 4)
        .onAppear { name = speaker.displayName }
        .onChange(of: focused) { _, value in if !value { save() } }
        .onChange(of: speaker.name) { _, _ in if !focused { name = speaker.displayName } }
        .onChange(of: model.interfaceLanguage) { _, _ in if !focused { name = speaker.displayName } }
        .onDisappear { save() }
    }

    private func save() { if name != speaker.displayName { model.renameSpeaker(speaker, name: name) } }
}

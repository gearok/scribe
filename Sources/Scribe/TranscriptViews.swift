import SwiftUI
import ScribeCore

struct PlaybackTranscriptView<Heading: View>: View {
    let player: PlaybackController
    @StateObject private var tracker = TranscriptPlaybackTracker()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let segments: [TranscriptSegment]
    let search: String
    let heading: Heading

    var body: some View {
        let playback = tracker.state
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    heading.padding(.bottom, 8)
                    ForEach(segments) { segment in
                        TranscriptParagraph(segment: segment, isActive: playback.activeSegmentIDs.contains(segment.id))
                            .id(segment.id)
                    }
                    if segments.isEmpty { ContentUnavailableView.search(text: search) }
                }
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
            .onChange(of: segments, initial: true) { _, segments in
                tracker.setSegments(segments, position: player.position, isPlaying: player.isPlaying)
            }
            .onReceive(player.$position.combineLatest(player.$isPlaying)) { position, isPlaying in
                tracker.update(position: position, isPlaying: isPlaying)
            }
            .onChange(of: playback.followingSegmentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

private struct TranscriptParagraph: View {
    @EnvironmentObject private var model: AppModel
    let segment: TranscriptSegment
    let isActive: Bool
    @State private var rename = false
    @State private var name = ""
    @State private var editing = false
    @State private var editedText = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let speaker = model.speaker(for: segment.speakerID) {
                    Button(speaker.displayName) { name = speaker.displayName; rename = true }
                        .buttonStyle(.borderless).font(.headline).foregroundStyle(.primary)
                        .help(L10n.format("Rename %@", speaker.displayName))
                }
                Button(TimeLabel.clock(segment.start)) { model.playback.playSegment(segment) }
                    .buttonStyle(.borderless).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .help(L10n.format("Play from %@", TimeLabel.clock(segment.start))).disabled(!model.playback.hasAudio)
                    .accessibilityValue(isActive ? L10n.text("Now Playing") : "")
                if model.overlappingSegmentIDs.contains(segment.id) {
                    Image(systemName: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(L10n.text("Overlapping Speech"))
                        .accessibilityLabel(L10n.text("Overlapping Speech"))
                }
                Spacer()
                Button(L10n.text("Copy Paragraph"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(editing ? editedText : segment.text, forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(L10n.text("Copy Paragraph"))
                Menu(L10n.text("Paragraph Actions"), systemImage: "ellipsis") {
                    Button(L10n.text("Edit Text"), systemImage: "pencil") { beginEditing() }
                    Menu(L10n.text("Assign Speaker")) {
                        ForEach(model.speakers) { speaker in Button(speaker.displayName) { model.reassign(segment, to: speaker) } }
                    }
                    Button(L10n.text("Play From Here"), systemImage: "play") { model.playback.playSegment(segment) }.disabled(!model.playback.hasAudio)
                }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if editing {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        // Match the editor's line wrapping, including an empty final line.
                        Text(editedText + "\u{200B}")
                            .font(.system(size: model.transcriptTextSize))
                            .padding(.horizontal, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden().accessibilityHidden(true)
                        TextEditor(text: $editedText)
                            .font(.system(size: model.transcriptTextSize))
                            .scrollContentBackground(.hidden)
                            .scrollDisabled(true)
                            .focused($editorFocused)
                            .accessibilityLabel(L10n.text("Edit Transcript"))
                            .onExitCommand { editing = false }
                            .task { editorFocused = true }
                    }
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(editorFocused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    HStack {
                        Spacer()
                        Button(L10n.text("Cancel"), role: .cancel) { editing = false }
                            .buttonStyle(.borderedProminent).tint(.gray)
                        Button(L10n.text("Save")) { saveEditing() }
                        .primaryActionStyle()
                        .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                // Keep Save and Cancel inside the editing region so Cancel never autosaves.
                .background(OutsideClickObserver(onOutsideClick: saveEditing))
            } else {
                Text(highlightedText)
                    .font(.system(size: model.transcriptTextSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture(count: 2).onEnded { beginEditing() })
                    .help(L10n.text("Double-click to edit this paragraph"))
            }
        }
        .overlay(alignment: .leading) {
            if isActive {
                Capsule().fill(.tint).frame(width: 3).offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear { saveEditing() }
        .alert(L10n.text("Rename Speaker"), isPresented: $rename) {
            TextField(L10n.text("Name"), text: $name)
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Save")) { if let speaker = model.speaker(for: segment.speakerID) { model.renameSpeaker(speaker, name: name) } }
        } message: { Text(L10n.text("This name will appear throughout this recording.")) }
    }

    private var highlightedText: AttributedString {
        var text = AttributedString(segment.text)
        let query = model.transcriptSearch
        guard !query.isEmpty else { return text }
        var remaining = segment.text.startIndex..<segment.text.endIndex
        while let match = segment.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                            range: remaining, locale: .current) {
            guard !match.isEmpty else { break }
            if let range = Range(match, in: text) {
                text[range].backgroundColor = .yellow.opacity(0.35)
            }
            remaining = match.upperBound..<segment.text.endIndex
        }
        return text
    }

    private func saveEditing() {
        guard editing else { return }
        editing = false
        if editedText.trimmingCharacters(in: .whitespacesAndNewlines) != segment.text {
            model.editText(segment, text: editedText)
        }
    }

    private func beginEditing() {
        model.playback.pause()
        editedText = segment.text
        editing = true
    }
}

struct PlaybackBar: View {
    @ObservedObject var player: PlaybackController
    let interfaceLanguage: InterfaceLanguage
    var body: some View {
        HStack(spacing: 16) {
            Button(L10n.text(player.isPlaying ? "Pause" : "Play", language: interfaceLanguage), systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.toggle() }
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.large)
                .disabled(!player.hasAudio).help(L10n.text(player.isPlaying ? "Pause" : "Play Recording", language: interfaceLanguage))
            Text(TimeLabel.clock(player.position)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                .disabled(!player.hasAudio).accessibilityLabel(L10n.text("Playback position"))
            Text(TimeLabel.clock(player.duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            Picker(L10n.text("Playback Speed"), selection: $player.rate) {
                ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { value in
                    Text("\(value.formatted(.number.locale(interfaceLanguage.locale)))×").tag(value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 62)
            .disabled(!player.hasAudio)
        }.padding().playbackSurface()
    }
}

struct RecordingInProgressView: View {
    @EnvironmentObject private var model: AppModel
    let recording: Recording
    @ObservedObject var activity: RecordingActivity
    var body: some View {
        VStack(spacing: 24) {
            Label(L10n.text("Recording"), systemImage: "record.circle.fill").foregroundStyle(.red)
            Text(TimeLabel.clock(activity.elapsed)).font(.largeTitle).monospacedDigit()
            Form {
                LabeledContent(L10n.text("Microphone")) {
                    ProgressView(value: Double(activity.microphoneLevel)).accessibilityLabel(L10n.text("Microphone level"))
                }
                if recording.hasSystemAudio {
                    LabeledContent(L10n.text("Meeting Audio")) {
                        ProgressView(value: Double(activity.systemLevel)).accessibilityLabel(L10n.text("Meeting audio level"))
                    }
                }
            }.formStyle(.grouped).scrollDisabled(true).frame(width: 360, height: 140)
            Button(L10n.text(model.modelsReady ? "Stop & Transcribe" : "Stop Recording"), systemImage: "stop.fill") { model.stopRecording() }
                .primaryActionStyle()
            Text(L10n.text(recording.sourceName)).font(.callout).foregroundStyle(.secondary)
        }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

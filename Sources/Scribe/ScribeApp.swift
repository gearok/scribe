import SwiftUI
import AppKit

struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updates = AppUpdater()
    @Environment(\.openWindow) private var openWindow

    init() {
        if ProcessInfo.processInfo.environment["SCRIBE_UI_LANGUAGE"] == nil { L10n.language.save() }
    }

    var body: some Scene {
        Window("Scribe", id: "main") {
            ContentView().environmentObject(model).environmentObject(updates)
                .environment(\.locale, model.interfaceLanguage.locale)
                .onAppear {
                    delegate.model = model
                    updates.start(model: model)
                    #if DEBUG
                    if model.isDemo,
                       let value = ProcessInfo.processInfo.environment["SCRIBE_PREVIEW_PLAYBACK_POSITION"],
                       let position = Double(value), let recording = model.selectedRecording {
                        do {
                            let directory = model.directory(for: recording)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            var writer: AudioTrackWriter? = try AudioTrackWriter(url: directory.appendingPathComponent("system.caf"), startHostTime: 1, meter: { _ in })
                            try writer?.finish(duration: 180)
                            writer = nil
                            try model.playback.load(nil, directory: nil)
                            try model.playback.load(recording, directory: directory)
                            model.playback.seek(to: position)
                            model.playback.play()
                        } catch { NSLog("Could not prepare playback preview: %@", error.localizedDescription) }
                    }
                    if ProcessInfo.processInfo.environment["SCRIBE_PREVIEW_SCREEN"] == "settings" { model.showSettings = true }
                    if let destination = ProcessInfo.processInfo.environment["SCRIBE_SNAPSHOT_PATH"] {
                        Task { @MainActor in
                            let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain })
                            window?.makeFirstResponder(nil)
                            window?.makeKeyAndOrderFront(nil)
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            try? await Task.sleep(for: .seconds(3))
                            window?.contentView?.layoutSubtreeIfNeeded()
                            window?.displayIfNeeded()
                            if ProcessInfo.processInfo.environment["SCRIBE_SNAPSHOT_METHOD"] == "screen", let rootWindow = window {
                                let window = rootWindow.attachedSheet ?? rootWindow
                                let capture = Process()
                                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination]
                                if ProcessInfo.processInfo.environment["SCRIBE_SNAPSHOT_SIDEBAR"] == "1",
                                   let content = window.contentView,
                                   let scroll = RecordingListSelectionAppearance.table(in: content)?.enclosingScrollView,
                                   let screen = NSScreen.screens.first {
                                    let listFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                                    let frame = window.frame
                                    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]]
                                    let bounds = info?.first?[kCGWindowBounds as String] as? [String: Any]
                                    let windowBounds = bounds.flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                                    let x = windowBounds?.minX ?? frame.minX
                                    let y = windowBounds?.minY ?? screen.frame.maxY - frame.maxY
                                    let height = windowBounds?.height ?? frame.height
                                    let rectangle = "\(Int(x)),\(Int(y)),\(Int(listFrame.maxX - frame.minX)),\(Int(height))"
                                    capture.arguments = ["-x", "-R", rectangle, destination]
                                }
                                do {
                                    try capture.run()
                                    capture.waitUntilExit()
                                } catch {
                                    NSLog("Could not capture the preview: %@", error.localizedDescription)
                                }
                                NSApplication.shared.terminate(nil)
                                return
                            }
                            guard let contentView = NSApplication.shared.windows.first(where: { $0.canBecomeMain })?.contentView else { return }
                            let view = contentView.superview ?? contentView
                            guard
                                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            if let data = bitmap.representation(using: .png, properties: [:]) {
                                try? data.write(to: URL(fileURLWithPath: destination))
                            }
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    #endif
                }
                .preferredColorScheme(effectiveAppearance.colorScheme)
                .onChange(of: effectiveAppearance, initial: true) { _, appearance in
                    // Apply to AppKit panels, menus, and updater windows as well as SwiftUI.
                    NSApplication.shared.appearance = appearance.nativeAppearance
                }
        }
        .defaultSize(width: 1280, height: 790)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.text("Check for Updates")) { updates.checkForUpdates() }
                    .disabled(!updates.isEnabled || !updates.canCheckForUpdates || updates.isBusy)
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("Start Recording")) { model.showNewRecording = true }.keyboardShortcut("n").disabled(model.isBusy || model.isDemo)
                Button(L10n.text("Import Audio")) { model.importAudio() }.keyboardShortcut("o").disabled(model.isBusy || model.isDemo)
                Button(L10n.text("New Folder")) { model.showNewFolder = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button(L10n.text("Export Transcript")) { model.exportTranscript() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.segments.isEmpty)
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("Settings")) { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(after: .textEditing) {
                Button(L10n.text("Search")) { model.searchFocusRequest += 1 }.keyboardShortcut("k")
            }
        }
        MenuBarExtra {
            if model.recordingID != nil {
                Text(L10n.format("Recording · %@", ScribeCore.TimeLabel.clock(model.elapsed)))
                Button(L10n.text("Stop Recording")) { model.stopRecording() }
            } else {
                Button(L10n.text("Start Recording")) { activate(); model.showNewRecording = true }.disabled(model.isBusy || model.isDemo)
            }
            Button(L10n.text("Show Scribe")) { activate() }
            Divider()
            Button(L10n.text("Settings")) { activate(); model.showSettings = true }
            Button(L10n.text("Quit Scribe")) { NSApplication.shared.terminate(nil) }
        } label: {
            if model.recordingID != nil { Image(systemName: "record.circle.fill") }
            else { Image(nsImage: ScribeAssets.feather) }
        }
    }

    private func activate() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    private var effectiveAppearance: AppAppearance {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SCRIBE_APPEARANCE"],
           let appearance = AppAppearance(rawValue: value) {
            return appearance
        }
        #endif
        return model.appearance
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // Set the bundled icon explicitly as well, so a locally built app updates its Dock tile immediately.
        if let url = Bundle.main.url(forResource: "Scribe", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, model.recordingID != nil {
            let alert = NSAlert()
            alert.messageText = L10n.text("Stop recording and quit?")
            alert.informativeText = L10n.text("Your audio will be saved. You can transcribe it the next time you open Scribe.")
            alert.addButton(withTitle: L10n.text("Stop & Quit")); alert.addButton(withTitle: L10n.text("Keep Recording"))
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        model?.finishBeforeQuit()
        return .terminateNow
    }
}

import ScribeCore

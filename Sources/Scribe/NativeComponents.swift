import SwiftUI
import AppKit

enum ScribeAssets {
    static let feather: NSImage = {
        guard let url = ScribeResources.bundle.url(forResource: "Feather", withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("The bundled feather symbol is missing.")
        }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// A template PDF lets native controls supply their own tint and vibrancy.
struct FeatherSymbol: View {
    var body: some View {
        Image(nsImage: ScribeAssets.feather)
            .renderingMode(.template).resizable().scaledToFit().accessibilityHidden(true)
    }
}

/// An inline native search field keeps search above the recordings column even
/// when the separate folders sidebar is collapsed.
struct RecordingSearchField: View {
    @Binding var text: String
    @Binding var focusRequest: Int
    let placeholder: String
    @State private var isFocused = false

    var body: some View {
        HStack(spacing: 4) {
            NativeRecordingSearchField(text: $text, isFocused: $isFocused,
                                       focusRequest: focusRequest, placeholder: placeholder)
            Button {
                text = ""
                focusRequest += 1
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    .frame(width: 22, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("Clear Search"))
            .accessibilityLabel(L10n.text("Clear Search"))
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 30)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay {
            Capsule().strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct NativeRecordingSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequest: Int
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused, focusRequest: focusRequest)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(string: text)
        field.cell = PillSearchFieldCell(textCell: text)
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        // Keep native search/text editor insets; only suppress the bezel drawing.
        field.isBezeled = true
        field.drawsBackground = false
        field.focusRingType = .none
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder + " (⌘K)"
        field.setAccessibilityLabel(placeholder)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.selectText(nil)
            }
        }
    }

    final class PillSearchFieldCell: NSSearchFieldCell {
        override func draw(withFrame frame: NSRect, in controlView: NSView) {
            super.drawInterior(withFrame: frame, in: controlView)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>
        var lastFocusRequest: Int
        init(text: Binding<String>, isFocused: Binding<Bool>, focusRequest: Int) {
            self.text = text; self.isFocused = isFocused; lastFocusRequest = focusRequest
        }

        func controlTextDidBeginEditing(_ notification: Notification) { isFocused.wrappedValue = true }
        func controlTextDidEndEditing(_ notification: Notification) { isFocused.wrappedValue = false }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { searchChanged(field) }
        }

        @objc func searchChanged(_ field: NSSearchField) { text.wrappedValue = field.stringValue }
    }
}

/// Keep the Notes-style yellow selection when focus moves into the transcript. The native
/// list still owns selection, keyboard navigation, accessibility, and context menus.
struct RecordingListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            var ancestor = view?.superview
            while let container = ancestor {
                if let table = Self.table(in: container) {
                    table.selectionHighlightStyle = .none
                    return
                }
                ancestor = container.superview
            }
        }
    }

    static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = table(in: child) { return table }
        }
        return nil
    }
}

/// Observe clicks without consuming them, so the clicked control still performs its action.
struct OutsideClickObserver: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> ClickObservationView { ClickObservationView() }

    func updateNSView(_ view: ClickObservationView, context: Context) {
        view.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ view: ClickObservationView, coordinator: ()) {
        view.stopObserving()
    }

    final class ClickObservationView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, !self.isHiddenOrHasHiddenAncestor else { return event }
                if event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onOutsideClick?()
                }
                return event
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stopObserving() }
    }
}

extension View {
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) }
        else { buttonStyle(.borderedProminent) }
    }

    /// Glass belongs on accessory controls, rather than the transcript content.
    @ViewBuilder
    func playbackSurface() -> some View {
        if #available(macOS 26, *) { glassEffect() }
        else { background(.bar) }
    }
}

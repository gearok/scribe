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

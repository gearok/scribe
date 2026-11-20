import Foundation

enum ScribeResources {
    static let bundle: Bundle = {
        // SwiftPM's generated accessor varies by toolchain. Resolve our installed
        // macOS app layout before allowing the development/test accessor to run.
        if let packaged = packagedBundle(in: .main) { return packaged }
        precondition(Bundle.main.bundleURL.pathExtension != "app",
                     "Scribe_Scribe.bundle is missing from the app's Contents/Resources folder.")
        return .module
    }()

    static func packagedBundle(in application: Bundle) -> Bundle? {
        guard let resources = application.resourceURL else { return nil }
        return Bundle(url: resources.appendingPathComponent("Scribe_Scribe.bundle", isDirectory: true))
    }
}

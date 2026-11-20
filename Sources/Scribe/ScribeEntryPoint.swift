import Foundation
import SwiftUI

@main
enum ScribeEntryPoint {
    @MainActor
    static func main() {
        // CI can exercise the installed executable without opening a window,
        // touching the recording library, starting updates, or requesting audio access.
        if CommandLine.arguments.contains("--check-resources") {
            do {
                try checkPackagedResources()
                print("Packaged resources verified: English, Russian, and feather symbol.")
                return
            } catch {
                fputs("Resource check failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        ScribeApp.main()
    }

    private static func checkPackagedResources() throws {
        guard let packaged = ScribeResources.packagedBundle(in: .main),
              packaged.bundleURL.standardizedFileURL == ScribeResources.bundle.bundleURL.standardizedFileURL,
              let feather = packaged.url(forResource: "Feather", withExtension: "pdf"),
              !(try Data(contentsOf: feather)).isEmpty,
              InterfaceLanguage.allCases.allSatisfy({
                  guard let path = packaged.path(forResource: $0.rawValue, ofType: "lproj"),
                        let localized = Bundle(path: path) else { return false }
                  return localized.url(forResource: "Localizable", withExtension: "strings") != nil
              }),
              L10n.text("Start Recording", language: .english) == "Start Recording",
              L10n.text("Start Recording", language: .russian) == "Начать запись" else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

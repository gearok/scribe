import XCTest
@testable import Scribe

final class ResourceBundleTests: XCTestCase {
    func testResourcesResolveInsideARelocatedMacApp() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-resources-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Scribe.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "app.scribe.resource-test", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let host = try XCTUnwrap(Bundle(url: app))
        XCTAssertNil(ScribeResources.packagedBundle(in: host))
        try FileManager.default.copyItem(at: ScribeResources.bundle.bundleURL,
                                        to: resources.appendingPathComponent("Scribe_Scribe.bundle"))
        let resolved = try XCTUnwrap(ScribeResources.packagedBundle(in: host))
        XCTAssertTrue(resolved.bundleURL.path.hasPrefix(directory.path))
        XCTAssertNotNil(resolved.url(forResource: "Feather", withExtension: "pdf"))
        for (language, expected) in [("en", "Start Recording"), ("ru", "Начать запись")] {
            let path = try XCTUnwrap(resolved.path(forResource: language, ofType: "lproj"))
            let localized = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(localized.localizedString(forKey: "Start Recording", value: nil, table: "Localizable"), expected)
        }
    }
}

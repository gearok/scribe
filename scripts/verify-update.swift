import CryptoKit
import Foundation

// Verify the update's public metadata and archive against the key embedded in the app.
// Sparkle's sign_update separately verifies the signed feed using the same signing key.
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "ScribeUpdateVerification", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let arguments = CommandLine.arguments
    try require(arguments.count == 5, "Usage: verify-update.swift appcast.xml archive.dmg Scribe.app vMAJOR.MINOR.PATCH")
    let feedURL = URL(fileURLWithPath: arguments[1])
    let archiveURL = URL(fileURLWithPath: arguments[2])
    let appURL = URL(fileURLWithPath: arguments[3])
    let tag = arguments[4]
    let version = String(tag.dropFirst())
    let infoData = try Data(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] ?? [:]
    try require(info["CFBundleVersion"] as? String == version && info["CFBundleShortVersionString"] as? String == version,
                "The packaged app version does not match the release tag.")
    let document = try XMLDocument(contentsOf: feedURL, options: [.nodeLoadExternalEntitiesNever])
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "The feed must contain exactly the packaged release.")
    guard let item = items.first as? XMLElement,
          let enclosure = item.elements(forName: "enclosure").first,
          let signature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue.flatMap({ Data(base64Encoded: $0) }),
          let publicKeyData = (info["SUPublicEDKey"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
        throw NSError(domain: "ScribeUpdateVerification", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "The feed is missing its signed archive or app public key."])
    }
    try require(item.elements(forName: "sparkle:version").first?.stringValue == version,
                "The feed version does not match the packaged app.")
    let expectedName = "Scribe-\(tag)-arm64.dmg"
    let expectedURL = "https://github.com/gearok/scribe/releases/download/\(tag)/\(expectedName)"
    try require(archiveURL.lastPathComponent == expectedName && enclosure.attribute(forName: "url")?.stringValue == expectedURL,
                "The feed points to an unexpected download URL.")
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    try require(enclosure.attribute(forName: "length")?.stringValue == String(archive.count), "The update length is incorrect.")
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    try require(publicKey.isValidSignature(signature, for: archive), "The DMG signature does not match the app's public key.")
    print("Verified update version, GitHub download URL, length, and DMG signature against the app's public key.")
} catch {
    fputs("Update verification failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

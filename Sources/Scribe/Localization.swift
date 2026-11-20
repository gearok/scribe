import Foundation
import ScribeCore

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case english = "en", russian = "ru"
    var id: String { rawValue }
    var name: String { self == .english ? "English" : "Русский" }
    var locale: Locale { Locale(identifier: rawValue) }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: "interfaceLanguage").flatMap(Self.init(rawValue:)) ?? .russian
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "interfaceLanguage")
        // Native system panels use this preference the next time the app launches.
        defaults.set([rawValue], forKey: "AppleLanguages")
    }
}

enum L10n {
    private static let bundles: [InterfaceLanguage: Bundle] = Dictionary(uniqueKeysWithValues: InterfaceLanguage.allCases.map { language in
        let bundle = ScribeResources.bundle.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? ScribeResources.bundle
        return (language, bundle)
    })

    static var language: InterfaceLanguage {
        if let code = ProcessInfo.processInfo.environment["SCRIBE_UI_LANGUAGE"],
           let language = InterfaceLanguage(rawValue: code) { return language }
        return .saved()
    }

    static func bundle(for language: InterfaceLanguage) -> Bundle {
        bundles[language] ?? ScribeResources.bundle
    }

    static func text(_ key: String, language: InterfaceLanguage? = nil) -> String {
        bundle(for: language ?? self.language).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, _ arguments: CVarArg..., language: InterfaceLanguage? = nil) -> String {
        let language = language ?? self.language
        return String(format: text(key, language: language), locale: language.locale, arguments: arguments)
    }

    static func count(_ count: Int, noun: String, language: InterfaceLanguage? = nil) -> String {
        let language = language ?? self.language
        let form: String
        if language == .russian {
            let last = count % 10, lastTwo = count % 100
            if last == 1 && lastTwo != 11 { form = "one" }
            else if (2...4).contains(last) && !(12...14).contains(lastTwo) { form = "few" }
            else { form = "many" }
        } else { form = count == 1 ? "one" : "many" }
        return format("\(noun).\(form)", count, language: language)
    }
}

extension Speaker {
    var displayName: String { displayName(in: L10n.language) }

    func displayName(in language: InterfaceLanguage) -> String {
        guard isNameCustomized != true else { return name }
        if isLocal && name == "You" { return L10n.text("You", language: language) }
        if name == "Unassigned" { return L10n.text("Unassigned", language: language) }
        if name.hasPrefix("Speaker "), let number = Int(name.dropFirst("Speaker ".count)) {
            return L10n.format("Speaker %ld", number, language: language)
        }
        return name
    }
}

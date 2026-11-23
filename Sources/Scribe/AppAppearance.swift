import AppKit
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }
    var label: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }

    static func saved(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: "appearance").flatMap(Self.init(rawValue:)) ?? .light
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "appearance")
    }
}

enum TranscriptTextSize {
    static let defaultValue = 13.0
    static let minimum = defaultValue
    static let maximum = 28.0
    static let range = minimum...maximum

    private static let key = "transcriptTextSize"

    static func saved(in defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return min(max(defaults.double(forKey: key), minimum), maximum)
    }

    static func save(_ value: Double, in defaults: UserDefaults = .standard) {
        defaults.set(min(max(value, minimum), maximum), forKey: key)
    }
}

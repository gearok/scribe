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

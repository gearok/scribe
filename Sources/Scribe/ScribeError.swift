import Foundation

enum ScribeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return L10n.text(message) }; return nil }
}

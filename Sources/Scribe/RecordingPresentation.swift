import Foundation

enum RecordingPresentation {
    static func dateAndTime(_ date: Date = Date()) -> String {
        date.formatted(.dateTime.day(.twoDigits).month(.twoDigits).year().hour().minute().locale(L10n.language.locale))
    }
}

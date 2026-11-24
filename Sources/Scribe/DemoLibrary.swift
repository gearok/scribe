import Foundation
import ScribeCore

/// Isolated sample content; production state management does not own demo fixtures.
enum DemoLibrary {
    static func seed(in database: LibraryDatabase) throws {
        let work = RecordingFolder(name: "Работа", color: .blue)
        let personal = RecordingFolder(name: "Личное", color: .green)
        try database.saveFolder(work)
        try database.saveFolder(personal)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        let meeting = Recording(title: "Планирование продукта", createdAt: date(daysAgo: 0, hour: 15, minute: 22), duration: 2528, status: .ready,
                                sourceName: "Google Meet", hasMicrophone: false, hasSystemAudio: false)
        let me = Speaker(recordingID: meeting.id, name: "You", colorIndex: 0, isLocal: true)
        let anna = Speaker(recordingID: meeting.id, name: "Анна", colorIndex: 1)
        let max = Speaker(recordingID: meeting.id, name: "Speaker 2", colorIndex: 2)
        let lines: [(Speaker, Double, String)] = [
            (anna, 12, "Давайте начнём. Сегодня нам нужно договориться о приоритетах на следующий спринт и обсудить обратную связь от пользователей."),
            (me, 28, "Я посмотрел последние интервью. Людям важно быстро находить нужный момент встречи, поэтому предлагаю начать с поиска по расшифровке."),
            (max, 46, "Согласен. А ещё стоит добавить возможность переименовать участников. Тогда запись будет гораздо удобнее читать и отправлять коллегам."),
            (anna, 67, "Хорошая мысль. Let’s keep the first version focused. Запись, расшифровка и понятные имена участников — этого достаточно для начала."),
            (me, 89, "Тогда сохраняем всё локально. После встречи можно прослушать фрагмент, исправить текст и назначить каждому голосу имя."),
            (max, 112, "Я возьму на себя проверку на длинных встречах. Особенно интересно, как обработаются моменты, когда несколько человек говорят одновременно."),
            (anna, 138, "Отлично. Давайте вернёмся с результатами в четверг. Если будут вопросы по дизайну, обсудим их отдельно."),
        ]
        let transcript = lines.map { TranscriptSegment(recordingID: meeting.id, speakerID: $0.0.id, start: $0.1, end: $0.1 + 12, text: $0.2, track: $0.0.isLocal ? .microphone : .system) }
        try database.saveTranscript(recording: meeting, speakers: [me, anna, max], segments: transcript)
        try database.moveRecordings([meeting.id], toFolder: work.id)
        let examples: [(String, Int, Int, Int, String)] = [
            ("Обратная связь клиентов", 0, 11, 30, "Zoom"),
            ("Design catch-up", 1, 16, 0, "Google Meet"),
            ("Обсуждение архитектуры", 1, 10, 15, "Microsoft Teams"),
            ("Еженедельная встреча", 2, 14, 0, "Zoom"),
            ("Интервью с пользователем", 2, 9, 30, "Microphone only"),
            ("Sprint review", 4, 12, 0, "Google Meet"),
        ]
        for (index, example) in examples.enumerated() {
            let (title, daysAgo, hour, minute, source) = example
            let recording = Recording(title: title, createdAt: date(daysAgo: daysAgo, hour: hour, minute: minute),
                                      duration: 1840, status: .captured, sourceName: source, hasMicrophone: false, hasSystemAudio: false)
            try database.save(recording)
            if index < 5 { try database.moveRecordings([recording.id], toFolder: index == 4 ? personal.id : work.id) }
        }
    }
}

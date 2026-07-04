import Foundation

struct MuseumEvent: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var museum: Museum
    var url: URL
    var date: Date
    var eventType: String
    var description: String?
    var exhibitionTitle: String?
    var location: String?
    var language: String?
    var notes: String?
    var isCancelled: Bool
    var fetchedAt: Date

    nonisolated init(
        id: UUID = UUID(),
        title: String,
        museum: Museum,
        url: URL,
        date: Date,
        eventType: String,
        description: String? = nil,
        exhibitionTitle: String? = nil,
        location: String? = nil,
        language: String? = nil,
        notes: String? = nil,
        isCancelled: Bool = false
    ) {
        self.id = id
        self.title = title
        self.museum = museum
        self.url = url
        self.date = date
        self.eventType = eventType
        self.description = description
        self.exhibitionTitle = exhibitionTitle
        self.location = location
        self.language = language
        self.notes = notes
        self.isCancelled = isCancelled
        self.fetchedAt = Date()
    }

    var formattedDateTime: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        let cal = Calendar.current
        let hasTime = cal.component(.hour, from: date) != 0 || cal.component(.minute, from: date) != 0
        f.dateFormat = hasTime ? "EEE, d. MMM yyyy, HH:mm 'Uhr'" : "EEE, d. MMM yyyy"
        return f.string(from: date)
    }

    var isUpcoming: Bool { date >= Date() }
}

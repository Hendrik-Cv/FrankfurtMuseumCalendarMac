import Foundation

struct Exhibition: Identifiable, Codable, Sendable {
    let id: UUID
    var title: String
    var museum: Museum
    var url: URL
    var startDate: Date
    var endDate: Date
    var description: String?
    var fetchedAt: Date

    nonisolated init(id: UUID = UUID(), title: String, museum: Museum, url: URL,
                     startDate: Date, endDate: Date, description: String? = nil) {
        self.id = id
        self.title = title
        self.museum = museum
        self.url = url
        self.startDate = startDate
        self.endDate = endDate
        self.description = description
        self.fetchedAt = Date()
    }

    enum Status {
        case ongoing, upcoming, past

        var label: String {
            switch self {
            case .ongoing:  return "Laufend"
            case .upcoming: return "Demnächst"
            case .past:     return "Vergangen"
            }
        }
    }

    var status: Status {
        let now = Date()
        if endDate < now   { return .past }
        if startDate > now { return .upcoming }
        return .ongoing
    }

    var formattedDateRange: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: "de_DE")
        return "\(f.string(from: startDate)) – \(f.string(from: endDate))"
    }
}

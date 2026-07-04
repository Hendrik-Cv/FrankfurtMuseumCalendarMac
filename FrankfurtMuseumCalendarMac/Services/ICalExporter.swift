import Foundation
import EventKit

@Observable
final class ICalExporter {
    var hasAccess = false
    var selectedCalendar: EKCalendar?
    private let store = EKEventStore()

    var availableCalendars: [EKCalendar] {
        store.calendars(for: .event).sorted { $0.title < $1.title }
    }

    @MainActor
    func requestAccess() async {
        do {
            hasAccess = try await store.requestFullAccessToEvents()
            selectedCalendar = store.defaultCalendarForNewEvents
        } catch {
            hasAccess = false
        }
    }

    func addToCalendar(_ exhibition: Exhibition, calendar: EKCalendar) throws {
        let event = EKEvent(eventStore: store)
        event.title = "[\(exhibition.museum.shortName)] \(exhibition.title)"
        event.startDate = exhibition.startDate
        event.endDate = exhibition.endDate
        event.isAllDay = true
        event.url = exhibition.url
        event.notes = buildNotes(exhibition)
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    func addAllToCalendar(_ exhibitions: [Exhibition], calendar: EKCalendar) throws {
        for ex in exhibitions {
            try addToCalendar(ex, calendar: calendar)
        }
    }

    func generateICS(_ exhibitions: [Exhibition]) -> String {
        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyyMMdd"
        dtFmt.locale = Locale(identifier: "en_US_POSIX")
        dtFmt.timeZone = TimeZone(identifier: "Europe/Berlin")

        let stampFmt = ISO8601DateFormatter()
        stampFmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = stampFmt.string(from: Date()).replacingOccurrences(of: "-", with: "")
                            .replacingOccurrences(of: ":", with: "")

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Frankfurt Museum Calendar//DE",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:Frankfurt Museumsausstellungen",
            "X-WR-TIMEZONE:Europe/Berlin",
        ]

        for ex in exhibitions {
            let desc = icsEscape(buildNotes(ex))
            lines += [
                "BEGIN:VEVENT",
                "UID:\(ex.id.uuidString)@frankfurt-museum-calendar",
                "DTSTAMP:\(stamp)",
                "DTSTART;VALUE=DATE:\(dtFmt.string(from: ex.startDate))",
                "DTEND;VALUE=DATE:\(dtFmt.string(from: ex.endDate))",
                "SUMMARY:\(icsEscape("[\(ex.museum.shortName)] \(ex.title)"))",
                "URL:\(ex.url.absoluteString)",
                "LOCATION:\(icsEscape(ex.museum.name + ", Frankfurt am Main"))",
                "DESCRIPTION:\(desc)",
                "END:VEVENT",
            ]
        }

        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private func buildNotes(_ ex: Exhibition) -> String {
        var parts = [ex.url.absoluteString]
        if let desc = ex.description, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: "\n\n")
    }

    private func icsEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

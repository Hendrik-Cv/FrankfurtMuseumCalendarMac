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
            if hasAccess {
                selectedCalendar = store.defaultCalendarForNewEvents
            }
        } catch {
            hasAccess = false
        }
    }

    /// Already permanently denied — user must enable in System Preferences.
    var isDenied: Bool {
        EKEventStore.authorizationStatus(for: .event) == .denied
    }

    func addToCalendar(_ exhibition: Exhibition, calendar: EKCalendar) throws {
        let predicate = store.predicateForEvents(
            withStart: exhibition.startDate, end: exhibition.endDate, calendars: [calendar])
        let existing = store.events(matching: predicate)

        let event = existing.first(where: { $0.url == exhibition.url }) ?? EKEvent(eventStore: store)
        event.title = "[\(exhibition.museum.shortName)] \(exhibition.title)"
        event.startDate = exhibition.startDate
        event.endDate = exhibition.endDate
        event.isAllDay = true
        event.url = exhibition.url
        event.location = exhibition.museum.address
        event.notes = exhibition.description
        event.calendar = calendar
        try store.save(event, span: .thisEvent)
    }

    func addAllToCalendar(_ exhibitions: [Exhibition], calendar: EKCalendar) throws {
        for ex in exhibitions {
            try addToCalendar(ex, calendar: calendar)
        }
    }

    func addEventToCalendar(_ event: MuseumEvent, calendar: EKCalendar) throws {
        let endDate = Calendar.current.date(byAdding: .hour, value: 2, to: event.date) ?? event.date
        let predicate = store.predicateForEvents(withStart: event.date, end: endDate, calendars: [calendar])
        let existing = store.events(matching: predicate)

        let ekEvent = existing.first(where: { $0.url == event.url }) ?? EKEvent(eventStore: store)
        ekEvent.title = "[\(event.museum.shortName)] \(event.title)"
        ekEvent.startDate = event.date
        ekEvent.endDate = endDate
        ekEvent.isAllDay = false
        ekEvent.url = event.url
        ekEvent.location = event.location ?? event.museum.address
        var notes = ""
        if let ex = event.exhibitionTitle { notes += "Ausstellung: \(ex)\n\n" }
        if let d = event.description { notes += d }
        if let n = event.notes, !n.isEmpty { notes += "\n\nHinweise: \(n)" }
        ekEvent.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        ekEvent.calendar = calendar
        try store.save(ekEvent, span: .thisEvent)
    }

    func addEventsToCalendar(_ events: [MuseumEvent], calendar: EKCalendar) throws {
        for ev in events { try addEventToCalendar(ev, calendar: calendar) }
    }

    func generateEventICS(_ events: [MuseumEvent]) -> String {
        let dtFmt = DateFormatter()
        dtFmt.dateFormat = "yyyyMMdd'T'HHmmss"
        dtFmt.locale = Locale(identifier: "en_US_POSIX")
        dtFmt.timeZone = TimeZone(identifier: "Europe/Berlin")

        let stampFmt = ISO8601DateFormatter()
        stampFmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = stampFmt.string(from: Date())
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")

        var lines = [
            "BEGIN:VCALENDAR",
            "VERSION:2.0",
            "PRODID:-//Frankfurt Museum Calendar//DE",
            "CALSCALE:GREGORIAN",
            "METHOD:PUBLISH",
            "X-WR-CALNAME:Frankfurt Museumsveranstaltungen",
            "X-WR-TIMEZONE:Europe/Berlin",
        ]

        for ev in events {
            let end = Calendar.current.date(byAdding: .hour, value: 2, to: ev.date) ?? ev.date
            var desc = ""
            if let ex = ev.exhibitionTitle { desc += "Ausstellung: \(ex)\\n\\n" }
            if let d = ev.description { desc += icsEscape(d) }
            if let n = ev.notes, !n.isEmpty { desc += "\\n\\nHinweise: \(icsEscape(n))" }
            lines += [
                "BEGIN:VEVENT",
                "UID:\(ev.id.uuidString)@frankfurt-museum-calendar",
                "DTSTAMP:\(stamp)",
                "DTSTART;TZID=Europe/Berlin:\(dtFmt.string(from: ev.date))",
                "DTEND;TZID=Europe/Berlin:\(dtFmt.string(from: end))",
                "SUMMARY:\(icsEscape("[\(ev.museum.shortName)] \(ev.title)"))",
                "URL:\(ev.url.absoluteString)",
                "LOCATION:\(icsEscape(ev.location ?? ev.museum.address))",
                "DESCRIPTION:\(desc)",
                "END:VEVENT",
            ]
        }

        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
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

        let sequence = Int(Date().timeIntervalSince1970 / 3600)

        for ex in exhibitions {
            let desc = icsEscape(ex.description ?? "")
            lines += [
                "BEGIN:VEVENT",
                "UID:\(stableUID(for: ex))@frankfurt-museum-calendar",
                "DTSTAMP:\(stamp)",
                "SEQUENCE:\(sequence)",
                "DTSTART;VALUE=DATE:\(dtFmt.string(from: ex.startDate))",
                "DTEND;VALUE=DATE:\(dtFmt.string(from: ex.endDate))",
                "SUMMARY:\(icsEscape("[\(ex.museum.shortName)] \(ex.title)"))",
                "URL:\(ex.url.absoluteString)",
                "LOCATION:\(icsEscape(ex.museum.address))",
                "DESCRIPTION:\(desc)",
                "END:VEVENT",
            ]
        }

        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    private func stableUID(for ex: Exhibition) -> String {
        ex.url.absoluteString
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func icsEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

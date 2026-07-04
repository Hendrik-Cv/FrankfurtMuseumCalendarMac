import Foundation

final class MfKFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "mfk" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)

        // Extract "Jetzt im Museum" and "Vorschau" sections; stop at "Online"
        let relevantHTML: String
        if let s = html.range(of: "Jetzt im Museum"),
           let e = html.range(of: "Online", range: s.upperBound..<html.endIndex) {
            relevantHTML = String(html[s.lowerBound..<e.lowerBound])
        } else {
            relevantHTML = html
        }

        // Match: href + h3 title + p date within a slide/group block
        guard let regex = try? NSRegularExpression(
            pattern: #"href="(https://www\.mfk-frankfurt\.de/[^"]+)"[\s\S]{0,3000}?<h3[^>]*>([^<]{10,200})</h3>[\s\S]{0,400}?<p[^>]*>([^<]{5,80})</p>"#,
            options: []) else { throw FetcherError.parsingFailed("Regex failed") }

        let ns = relevantHTML as NSString
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!

        for m in regex.matches(in: relevantHTML, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 3 else { continue }
            let href    = ns.substring(with: m.range(at: 1))
            let title   = HTMLFetcher.stripHTML(ns.substring(with: m.range(at: 2)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let dateRaw = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(href).inserted else { continue }
            guard let url = URL(string: href) else { continue }
            // Skip non-date paragraphs (permanent, opening hours, etc.)
            guard let (start, end) = parseMfKDate(dateRaw) else { continue }
            guard end >= cutoff else { continue }
            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 6)
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let now = Date()
        let cal = Calendar.current
        let toDate = cal.date(byAdding: .day, value: 90, to: now) ?? now
        let apiURL = URL(string: "https://www.mfk-frankfurt.de/wp-json/my-calendar/v1/events?from=\(mfkDateStr(now))&to=\(mfkDateStr(toDate))")!
        let raw = try await HTMLFetcher.fetchHTML(from: apiURL)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetcherError.parsingFailed("MfK My Calendar JSON")
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Europe/Berlin")

        let cutoff = cal.date(byAdding: .hour, value: -2, to: now)!
        let calendarFallback = URL(string: "https://www.mfk-frankfurt.de/?cid=my-calendar")!
        var events: [MuseumEvent] = []
        var seen = Set<String>()

        for dateKey in json.keys.sorted() {
            guard let dayEvents = json[dateKey] as? [[String: Any]] else { continue }
            for event in dayEvents {
                // Skip all-day / unscheduled (time = midnight)
                guard let eventTime = event["event_time"] as? String, eventTime != "00:00:00" else { continue }
                guard let occurBegin = event["occur_begin"] as? String,
                      let date = df.date(from: occurBegin),
                      date >= cutoff else { continue }

                // Unique key by occurrence ID
                let occurID: String
                if let s = event["occur_id"] as? String { occurID = s }
                else if let i = event["occur_id"] as? Int { occurID = "\(i)" }
                else { continue }
                guard seen.insert(occurID).inserted else { continue }

                var rawTitle = (event["event_title"] as? String ?? "")
                    .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawTitle.isEmpty else { continue }
                // Skip cancelled / rescheduled
                guard !rawTitle.hasPrefix("VERSCHOBEN:"), !rawTitle.hasPrefix("ABGESAGT:") else { continue }

                // Sold-out prefix → note
                var notes: String? = nil
                if rawTitle.hasPrefix("AUSGEBUCHT:") {
                    rawTitle = rawTitle.replacingOccurrences(of: "AUSGEBUCHT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    notes = "Ausgebucht"
                }

                let linkStr = (event["event_link"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let eventURL = URL(string: linkStr) ?? calendarFallback

                let cats = (event["categories"] as? [[String: Any]] ?? []).compactMap { $0["category_name"] as? String }

                let shortRaw = (event["event_short"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let description: String? = {
                    let t = HTMLFetcher.stripHTML(shortRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.count >= 40 ? t : nil
                }()

                events.append(MuseumEvent(
                    title: rawTitle,
                    museum: museum,
                    url: eventURL,
                    date: date,
                    eventType: inferMfKEventType(from: cats, title: rawTitle),
                    description: description,
                    notes: notes
                ))
            }
        }

        return events.sorted { $0.date < $1.date }
    }

    private func mfkDateStr(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: date)
    }

    private func inferMfKEventType(from categories: [String], title: String) -> String {
        let catStr = categories.joined(separator: " ").lowercased()
        let l = title.lowercased()
        if catStr.contains("führung") || l.contains("führung") || l.contains("tour")    { return "Führung" }
        if catStr.contains("workshop") || l.contains("workshop")                         { return "Workshop" }
        if l.contains("vortrag") || l.contains("lecture")                                { return "Vortrag" }
        if l.contains("konzert")                                                         { return "Konzert" }
        if l.contains("eröffnung") || l.contains("opening")                             { return "Eröffnung" }
        if l.contains("lesung")                                                          { return "Lesung" }
        if catStr.contains("kinder") || l.contains("kinder") || l.contains("familie")   { return "Kinderprogramm" }
        return "Veranstaltung"
    }

    private func parseMfKDate(_ raw: String) -> (Date, Date)? {
        // "30. Januar bis 26. Juli 2026" — full range with "bis"
        if raw.contains(" bis ") {
            let parts = raw.components(separatedBy: " bis ")
            guard parts.count == 2 else { return nil }
            let endStr   = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let startStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let end = HTMLFetcher.parseGermanDate(endStr) else { return nil }
            if let start = HTMLFetcher.parseGermanDate(startStr) { return (start, end) }
            // Year-only-at-end: "30. Januar" → "30. Januar 2026"
            let year = Calendar.current.component(.year, from: end)
            if let start = HTMLFetcher.parseGermanDate("\(startStr) \(year)") { return (start, end) }
            return nil
        }
        // "ab 28. Mai 2026" / "seit 3. Dezember 2025" — start only; end = start + 1 year
        var cleaned = raw
        for prefix in ["ab ", "seit "] {
            if cleaned.hasPrefix(prefix) { cleaned = String(cleaned.dropFirst(prefix.count)); break }
        }
        guard let start = HTMLFetcher.parseGermanDate(cleaned) else { return nil }
        guard let end = Calendar.current.date(byAdding: .year, value: 1, to: start) else { return nil }
        return (start, end)
    }
}

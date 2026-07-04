import Foundation

final class CaricaturaFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    private static let base = "https://www.caricatura-museum.de"

    init() { super.init(museum: Museum.all.first { $0.id == "caricatura" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let pages = [
            URL(string: "\(Self.base)/ausstellungen/sonderausstellung/")!,
            URL(string: "\(Self.base)/ausstellungen/caricatura-salon/")!,
        ]

        var exhibitions: [Exhibition] = []
        for pageURL in pages {
            guard let html = try? await HTMLFetcher.fetchHTML(from: pageURL) else { continue }
            // Try all badge paragraphs; use first that yields a valid date range
            let badges = HTMLFetcher.allCaptures(pattern: #"class="badge"[^>]*>([^<]+)<"#, in: html)
            guard let (start, end) = badges.lazy.compactMap({ self.parseBadgeDate($0) }).first else { continue }
            guard let title = HTMLFetcher.allCaptures(
                    pattern: #"<h2[^>]*class="headline"[^>]*>([^<]+)</h2>"#, in: html).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            let desc = extractDescription(from: html)
            exhibitions.append(Exhibition(
                title: title, museum: museum, url: pageURL,
                startDate: start, endDate: end, description: desc))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return exhibitions
    }

    // Handles "27. Juni 2026 – 17. Januar 2027" and "Laufzeit 17. Juli - 18. Oktober 2026"
    private func parseBadgeDate(_ raw: String) -> (Date, Date)? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("Laufzeit ") { cleaned = String(cleaned.dropFirst("Laufzeit ".count)) }
        // Standard ranges with full years on both sides
        if let range = HTMLFetcher.parseDateRange(cleaned) { return range }
        // Year only at end: "17. Juli - 18. Oktober 2026"
        for sep in ["–", "—", " - ", " bis ", "−"] {
            let parts = cleaned.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            let endStr   = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let startStr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let end = HTMLFetcher.parseGermanDate(endStr) else { continue }
            let year = Calendar.current.component(.year, from: end)
            if let start = HTMLFetcher.parseGermanDate("\(startStr) \(year)") {
                return (start, end)
            }
        }
        return nil
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let listURL = URL(string: "\(Self.base)/veranstaltungen/")!
        let html = try await HTMLFetcher.fetchHTML(from: listURL)

        let rows = HTMLFetcher.allCaptures(
            pattern: #"<div\s+class="event_row\s+columns">([\s\S]+?)<div\s+class="column_112"></div>"#,
            in: html)

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        var events: [MuseumEvent] = []

        for row in rows {
            guard let dateStr = extractFirst(pattern: #"class="event_date">(\d{1,2}\.\d{1,2}\.)<"#, in: row),
                  let href = extractFirst(pattern: #"href="(/aktuelles/veranstaltungen/veranstaltung/[^"]+)""#, in: row)
            else { continue }

            let timeStr = extractFirst(
                pattern: #"class="event_time"[^>]*>(?:[\s\S]{0,100}?)(\d{1,2}\.\d{2})\s+Uhr"#,
                in: row) ?? ""

            guard let date = parseCaricaturaDate(dateStr, time: timeStr) else { continue }
            guard date >= cutoff else { continue }

            let titleHTML = extractFirst(pattern: #"<a\s+href="[^"]+"\s*>([\s\S]{5,500}?)</a>"#, in: row) ?? ""
            let title = HTMLFetcher.stripHTML(
                titleHTML
                    .replacingOccurrences(of: "<br>", with: " ")
                    .replacingOccurrences(of: "<br/>", with: " ")
                    .replacingOccurrences(of: "<br />", with: " ")
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let eventURL = URL(string: "\(Self.base)\(href)") ?? listURL

            events.append(MuseumEvent(
                title: title,
                museum: museum,
                url: eventURL,
                date: date,
                eventType: inferCaricaturaEventType(from: title)
            ))
        }

        return events.sorted { $0.date < $1.date }
    }

    private func parseCaricaturaDate(_ dateStr: String, time: String) -> Date? {
        let parts = dateStr.components(separatedBy: ".").filter { !$0.isEmpty }
        guard parts.count == 2,
              let day = Int(parts[0]),
              let month = Int(parts[1]) else { return nil }
        let year = inferCaricaturaYear(day: day, month: month)
        let timeParts = time.components(separatedBy: ".")
        let hour   = timeParts.count >= 1 ? Int(timeParts[0]) ?? 0 : 0
        let minute = timeParts.count >= 2 ? Int(timeParts[1]) ?? 0 : 0
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return Calendar.current.date(from: comps)
    }

    private func inferCaricaturaYear(day: Int, month: Int) -> Int {
        let cal = Calendar.current
        let now = Date()
        let cm = cal.component(.month, from: now)
        let cd = cal.component(.day, from: now)
        let cy = cal.component(.year, from: now)
        return (month > cm || (month == cm && day >= cd)) ? cy : cy + 1
    }

    private func inferCaricaturaEventType(from title: String) -> String {
        let l = title.lowercased()
        if l.contains("eröffnung") || l.contains("opening") { return "Eröffnung" }
        if l.contains("führung") || l.contains("tour")      { return "Führung" }
        if l.contains("workshop")                            { return "Workshop" }
        if l.contains("vortrag") || l.contains("lecture")   { return "Vortrag" }
        if l.contains("konzert")                             { return "Konzert" }
        if l.contains("finissage")                           { return "Finissage" }
        if l.contains("lesung")                              { return "Lesung" }
        return "Veranstaltung"
    }

    private func extractDescription(from html: String) -> String? {
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]{80,3000}?)</p>"#, in: html)
        var result: [String] = []
        var total = 0
        for p in paras {
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            guard text.count >= 80 else { continue }
            // Navigation menu text
            guard !text.contains("Ausstellungsvorschau") else { continue }
            // Opening-night announcement line
            guard !text.hasPrefix("ERÖFFNUNG") else { continue }
            // Guided tour schedule
            guard !text.contains("Öffentliche Führungen") else { continue }
            guard !lower.contains("uhrzeit:") else { continue }
            // Book shop listings
            guard !lower.contains("avant-verlag") else { continue }
            // Footer address / contact
            guard !text.contains("Weckmarkt") else { continue }
            guard !text.contains("Führungsanfragen:") else { continue }
            // Standard boilerplate filters
            guard !lower.contains("upgrade your browser") else { continue }
            guard !(lower.contains("javascript") && text.count < 300) else { continue }
            guard !(lower.contains("cookie") && text.count < 200) else { continue }
            guard !(text.hasPrefix("©") || (text.contains("©") && text.count < 400)) else { continue }
            guard !lower.contains("courtesy of") else { continue }

            if total + text.count > 6000 { break }
            result.append(text)
            total += text.count
            if result.count >= 6 { break }
        }
        return result.isEmpty ? nil : result.joined(separator: "\n\n")
    }
}

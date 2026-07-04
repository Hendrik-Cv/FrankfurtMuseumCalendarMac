import Foundation

final class GierschFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "giersch" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        // Stop before the archive section
        let activeHTML: String
        if let cut = html.range(of: "ce-exhibition-archive") {
            activeHTML = String(html[..<cut.lowerBound])
        } else {
            activeHTML = html
        }
        var exhibitions: [Exhibition] = []
        let currentDates = HTMLFetcher.allCaptures(
            pattern: #"class="teaser-date">([^<]+)<"#, in: activeHTML)
        let currentTitles = HTMLFetcher.allCaptures(
            pattern: #"class="teaser-title">([^<]+)<"#, in: activeHTML)
        let currentHrefs = HTMLFetcher.allCaptures(
            pattern: #"<a\s+href="(https://www\.mggu\.de/ausstellungen/[^"]+)""#, in: activeHTML)
        for i in 0..<min(currentDates.count, currentTitles.count) {
            guard let (start, end) = parseGierschDate(currentDates[i]) else { continue }
            let url = i < currentHrefs.count ? URL(string: currentHrefs[i]) ?? museum.exhibitionsURL
                                             : museum.exhibitionsURL
            exhibitions.append(Exhibition(
                title: currentTitles[i].trimmingCharacters(in: .whitespacesAndNewlines),
                museum: museum, url: url, startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 6)
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let apiURL = URL(string: "https://www.mggu.de/wp-json/wp/v2/pages/192?_fields=content")!
        let raw = try await HTMLFetcher.fetchHTML(from: apiURL)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (json["content"] as? [String: Any])?["rendered"] as? String else {
            throw FetcherError.parsingFailed("Giersch Veranstaltungen page")
        }

        let blocks = HTMLFetcher.allCaptures(
            pattern: #"class="calendar-entry"[^>]*>\s*(<a[\s\S]{50,2000}?</a>)\s*</div>"#,
            in: content)

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        var events: [MuseumEvent] = []
        var seen = Set<String>()

        for block in blocks {
            guard let rawURL = extractFirst(pattern: #"href="(https://www\.mggu\.de/kalender/[^"]+)""#, in: block),
                  let tsStr = extractFirst(pattern: #"\?event=(\d+)"#, in: block),
                  let ts = Int(tsStr) else { continue }

            let date = Date(timeIntervalSince1970: Double(ts))
            guard date >= cutoff else { continue }
            guard seen.insert(rawURL).inserted else { continue }

            guard let eventURL = URL(string: rawURL) else { continue }

            let rawTitle = extractFirst(pattern: #"class="entry-title">([^<]+)<"#, in: block) ?? ""
            let title = HTMLFetcher.stripHTML(rawTitle)
                .replacingOccurrences(of: "&#038;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let subtitle = extractFirst(pattern: #"class="entry-subtitle">([^<]+)<"#, in: block)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            events.append(MuseumEvent(
                title: title,
                museum: museum,
                url: eventURL,
                date: date,
                eventType: inferGierschEventType(from: subtitle, title: title)
            ))
        }

        return events.sorted { $0.date < $1.date }
    }

    private func inferGierschEventType(from subtitle: String, title: String) -> String {
        let ls = subtitle.lowercased()
        let lt = title.lowercased()
        if ls.contains("öffentliche führung") || ls.contains("führung") || lt.contains("führung") { return "Führung" }
        if ls.contains("workshop") || lt.contains("workshop")            { return "Workshop" }
        if ls.contains("kinderprogramm") || ls.contains("familien")      { return "Kinderprogramm" }
        if ls.contains("film")                                            { return "Film" }
        if ls.contains("vortrag") || lt.contains("vortrag")              { return "Vortrag" }
        if ls.contains("konzert")                                         { return "Konzert" }
        if ls.contains("event")                                           { return "Veranstaltung" }
        return subtitle.isEmpty ? "Veranstaltung" : subtitle
    }

    // Handles "28.03.2026 - 06.09.2026" and "6.11.26 – 16.5.27"
    private func parseGierschDate(_ raw: String) -> (Date, Date)? {
        func expand(_ s: String) -> String {
            // "6.11.26" → "6.11.2026"
            let ns = s as NSString
            guard let m = (try? NSRegularExpression(pattern: #"^(\d{1,2}\.\d{1,2}\.)(\d{2})$"#))?
                    .firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 2 else { return s }
            let prefix = ns.substring(with: m.range(at: 1))
            let yr = Int(ns.substring(with: m.range(at: 2))) ?? 0
            return "\(prefix)\(yr < 50 ? 2000 + yr : 1900 + yr)"
        }
        let separators = ["–", "—", " - ", " bis ", "−", "-"]
        for sep in separators {
            let parts = raw.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            let s = expand(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            let e = expand(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            if let start = HTMLFetcher.parseGermanDate(s), let end = HTMLFetcher.parseGermanDate(e) {
                return (start, end)
            }
        }
        return nil
    }
}

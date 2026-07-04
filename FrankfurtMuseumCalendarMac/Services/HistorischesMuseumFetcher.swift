import Foundation

final class HistorischesMuseumFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "historisches" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        let entries = HTMLFetcher.allCaptures(
            pattern: #"<li[^>]*hmfScroller__entry[^>]*>([\s\S]*?)</li>"#, in: html)
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()
        for entry in entries {
            let href = HTMLFetcher.allCaptures(
                pattern: #"href="(https://historisches-museum-frankfurt\.de/de/ausstellungen/[^"]+)""#,
                in: entry).first ?? ""
            guard !href.isEmpty, let url = URL(string: href),
                  seen.insert(href).inserted else { continue }
            let titleRaw = HTMLFetcher.allCaptures(pattern: #"<a[^>]*>([\s\S]+?)</a>"#, in: entry).first ?? ""
            let title = HTMLFetcher.stripHTML(titleRaw)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let paras = HTMLFetcher.allCaptures(pattern: #"<p>([^<]+)</p>"#, in: entry)
            // Only entries with a date paragraph (contains digits)
            guard let datePara = paras.first(where: { $0.range(of: "\\d{2}\\.\\d{2}\\.\\d{2}", options: .regularExpression) != nil }) else { continue }
            guard let (start, end) = parseHMFDate(datePara) else { continue }
            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 6)
    }

    // Parses "bis 31.01.27", "Ab 10.06.26", or "12.03.26 – 31.01.27"
    private func parseHMFDate(_ raw: String) -> (Date, Date)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func expand(_ shortDate: String) -> String {
            // "31.01.27" → "31.01.2027"
            let ns = shortDate as NSString
            guard let m = (try? NSRegularExpression(pattern: #"^(\d{1,2}\.\d{1,2}\.)(\d{2})$"#))?
                    .firstMatch(in: shortDate, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 2 else { return shortDate }
            let prefix = ns.substring(with: m.range(at: 1))
            let yr = Int(ns.substring(with: m.range(at: 2))) ?? 0
            return "\(prefix)\(yr < 50 ? 2000 + yr : 1900 + yr)"
        }
        // "bis DATE" — ongoing, infer start as 1 year before end
        if let rest = s.lowercased().starts(with: "bis ") ? Optional(String(s.dropFirst(4))) : nil {
            if let end = HTMLFetcher.parseGermanDate(expand(rest.trimmingCharacters(in: .whitespaces))) {
                let start = Calendar.current.date(byAdding: .year, value: -1, to: end) ?? end
                return (start, end)
            }
        }
        // "Ab DATE" or "ab DATE" — upcoming, infer end as 1 year after start
        if s.lowercased().hasPrefix("ab ") {
            let rest = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let start = HTMLFetcher.parseGermanDate(expand(rest)) {
                let end = Calendar.current.date(byAdding: .year, value: 1, to: start) ?? start
                return (start, end)
            }
        }
        // Full range "DATE – DATE"
        if let (start, end) = HTMLFetcher.parseDateRange(s) { return (start, end) }
        return nil
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let apiURL = URL(string: "https://historisches-museum-frankfurt.de/de/api/calendar")!
        let raw = try await HTMLFetcher.fetchHTML(from: apiURL)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["events"] as? [[String: Any]] else {
            throw FetcherError.parsingFailed("HMF calendar API JSON")
        }

        // Build lookup tables from top-level arrays
        let locationMap = buildLookup(json["locations"])
        let typeMap     = buildLookup(json["types"])
        let fallbackURL = URL(string: "https://historisches-museum-frankfurt.de/de/veranstaltungen")!

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        var events: [MuseumEvent] = []
        var seen = Set<String>()

        for entry in entries {
            guard let type = entry["type"] as? String, type == "event",
                  let rawTitle = entry["title"] as? String,
                  let dateStartRaw = entry["dateStart"] else { continue }

            let dateStart: Double
            if let d = dateStartRaw as? Double { dateStart = d }
            else if let i = dateStartRaw as? Int { dateStart = Double(i) }
            else { continue }

            let date = Date(timeIntervalSince1970: dateStart)
            guard date >= cutoff else { continue }

            // Skip "museum closed" day markers
            let lTitle = rawTitle.lowercased()
            guard !lTitle.contains("geschlossen") else { continue }

            let key = "\(Int(dateStart))|\(rawTitle)"
            guard seen.insert(key).inserted else { continue }

            let isCancelled = rawTitle.lowercased().hasPrefix("abgesagt")
            let title = isCancelled
                ? rawTitle.replacingOccurrences(of: #"^[Aa]bgesagt:\s*"#, with: "", options: .regularExpression)
                : rawTitle

            // Description: prefer body, fall back to summary
            let bodyHTML    = entry["body"]    as? String ?? ""
            let summaryHTML = entry["summary"] as? String ?? ""
            let descHTML = bodyHTML.isEmpty ? summaryHTML : bodyHTML
            let desc = HTMLFetcher.htmlToStructuredText(descHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Location: first UID → name
            let locationUID = (entry["locations"] as? [String])?.first
                           ?? (entry["locations"] as? [Any])?.compactMap { $0 as? String }.first
                           ?? ""
            let location = locationMap[locationUID]

            // EventType: first type UID → name
            let typeUID = (entry["types"] as? [String])?.first
                       ?? (entry["types"] as? [Any])?.compactMap { $0 as? String }.first
                       ?? ""
            let eventType = typeMap[typeUID] ?? inferHMFEventType(from: title)

            let evtURL = (entry["url"] as? String).flatMap { URL(string: $0) } ?? fallbackURL

            events.append(MuseumEvent(
                title: title,
                museum: museum,
                url: evtURL,
                date: date,
                eventType: eventType,
                description: desc.isEmpty ? nil : desc,
                location: location,
                isCancelled: isCancelled
            ))
        }

        return events.sorted { $0.date < $1.date }
    }

    private func buildLookup(_ value: Any?) -> [String: String] {
        guard let arr = value as? [[String: Any]] else { return [:] }
        var dict: [String: String] = [:]
        for item in arr {
            if let uid = item["uid"] as? String, let title = item["title"] as? String {
                dict[uid] = title
            }
        }
        return dict
    }

    private func inferHMFEventType(from title: String) -> String {
        let l = title.lowercased()
        if l.contains("führung") || l.contains("tour")      { return "Führung" }
        if l.contains("workshop") || l.contains("werkstatt"){ return "Workshop" }
        if l.contains("vortrag")                             { return "Vortrag" }
        if l.contains("konzert") || l.contains("jazz")       { return "Konzert" }
        if l.contains("stadtgang") || l.contains("stadtführung") || l.contains("fahrradtour") { return "Stadtgang" }
        if l.contains("lesung")                              { return "Lesung" }
        if l.contains("gespräch") || l.contains("podium") || l.contains("fishbowl") { return "Gespräch" }
        if l.contains("symposium") || l.contains("tagung")  { return "Tagung" }
        if l.contains("finissage")                           { return "Finissage" }
        if l.contains("eröffnung") || l.contains("opening") { return "Eröffnung" }
        return "Veranstaltung"
    }
}

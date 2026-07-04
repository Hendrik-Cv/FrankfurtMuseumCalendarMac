import Foundation

final class DAMFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "dam" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let exhibitions = try await super.fetchExhibitions()
        var seen = Set<String>()
        let filtered = exhibitions.filter {
            $0.endDate.timeIntervalSince($0.startDate) >= 86400 &&
            seen.insert($0.url.absoluteString).inserted
        }
        return await enrichWithDescriptions(filtered, maxParagraphs: 6)
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let listURL = URL(string: "https://dam-online.de/de/veranstaltungen")!
        let html = try await HTMLFetcher.fetchHTML(from: listURL)

        let jsonLDBlocks = HTMLFetcher.allCaptures(
            pattern: #"<script[^>]*type="application/ld\+json"[^>]*>([\s\S]*?)</script>"#, in: html)

        struct EventRef {
            let title: String
            let start: Date
            let url: URL
            let baseURL: URL
            let location: String?
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var seen = Set<String>()
        var refs: [EventRef] = []

        for block in jsonLDBlocks {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
            for entry in json {
                guard let type = entry["@type"] as? String, type == "Event",
                      let rawName = entry["name"] as? String,
                      let startStr = entry["startDate"] as? String,
                      let start = iso.date(from: startStr) else { continue }

                // Only events with a specific time (not midnight = exhibitions)
                let cal = Calendar.current
                guard cal.component(.hour, from: start) != 0
                   || cal.component(.minute, from: start) != 0 else { continue }

                let evtURL = (entry["url"] as? String).flatMap { URL(string: $0) } ?? listURL
                guard seen.insert(evtURL.absoluteString + startStr).inserted else { continue }

                let title = HTMLFetcher.stripHTML(rawName).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }

                let location = (entry["location"] as? [String: Any])?["name"] as? String
                refs.append(EventRef(title: title, start: start, url: evtURL,
                                     baseURL: damBaseURL(evtURL), location: location))
            }
        }

        // Fetch full descriptions from detail pages — deduplicated by base URL
        let uniqueBases = Array(Set(refs.map { $0.baseURL.absoluteString }))
            .compactMap { URL(string: $0) }

        // Step 1: fetch HTML concurrently
        var detailHTMLs: [(String, String)] = []
        await withTaskGroup(of: (String, String)?.self) { group in
            for base in uniqueBases {
                group.addTask {
                    guard let detailHTML = try? await HTMLFetcher.fetchHTML(from: base) else { return nil }
                    return (base.absoluteString, detailHTML)
                }
            }
            for await pair in group { if let pair { detailHTMLs.append(pair) } }
        }

        // Step 2: extract descriptions outside task closures
        var descByBase: [String: String] = [:]
        for (baseStr, detailHTML) in detailHTMLs {
            let desc = extractDAMEventDescription(from: detailHTML)
            if !desc.isEmpty { descByBase[baseStr] = desc }
        }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        var events: [MuseumEvent] = []
        for ref in refs {
            guard ref.start >= cutoff else { continue }
            let desc = descByBase[ref.baseURL.absoluteString]
            let eventType = inferDAMEventType(from: ref.title, description: desc ?? "")
            events.append(MuseumEvent(
                title: ref.title,
                museum: museum,
                url: ref.url,
                date: ref.start,
                eventType: eventType,
                description: desc,
                location: ref.location
            ))
        }
        return events.sorted { $0.date < $1.date }
    }

    // Strip trailing /YYYY-MM-DD/ occurrence suffix to get the canonical event URL
    private func damBaseURL(_ url: URL) -> URL {
        let path = url.path
        guard let range = path.range(of: #"/\d{4}-\d{2}-\d{2}/$"#, options: .regularExpression) else {
            return url
        }
        let basePath = String(path[..<range.lowerBound]) + "/"
        return URL(string: "https://dam-online.de\(basePath)") ?? url
    }

    private func extractDAMEventDescription(from html: String) -> String {
        let block = HTMLFetcher.allCaptures(
            pattern: #"class="tribe-events-single-event-description[^"]*"[^>]*>([\s\S]{0,5000}?)</div>"#,
            in: html).first ?? ""
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]{0,2000}?)</p>"#, in: block)
        var result: [String] = []
        for para in paras {
            // Skip paragraphs whose content is entirely within <strong> elements (metadata blocks)
            let withoutStrong = para
                .replacingOccurrences(of: #"<strong[^>]*>[\s\S]*?</strong>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<br\s*/?>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !withoutStrong.isEmpty else { continue }

            let text = HTMLFetcher.htmlToStructuredText(para).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Skip standalone date/time lines like "1. JULI 2026, 17 Uhr"
            let isDateLine = text.range(of: #"^\d{1,2}\.\s+[A-ZÄÖÜ]"#, options: .regularExpression) != nil
                          && text.count < 40
            guard !isDateLine else { continue }

            result.append(text)
        }
        return result.joined(separator: "\n\n")
    }

    private func inferDAMEventType(from title: String, description: String) -> String {
        let lt = title.lowercased()
        let ld = description.lowercased()
        if lt.contains("führung")                          { return "Führung" }
        if lt.contains("workshop") || lt.contains("werkstatt") || lt.contains("block lab") { return "Workshop" }
        if lt.contains("vortrag")                          { return "Vortrag" }
        if lt.contains("eröffnung") || lt.contains("opening") { return "Eröffnung" }
        if lt.contains("finissage")                        { return "Finissage" }
        if lt.contains("lesung")                           { return "Lesung" }
        if lt.contains("konzert")                          { return "Konzert" }
        if lt.contains("symposium") || lt.contains("konferenz") { return "Symposium" }
        if lt.contains("fest") || lt.contains("festival") { return "Veranstaltung" }
        if ld.contains("vortragsreihe") || ld.contains("vortrag") { return "Vortrag" }
        return "Veranstaltung"
    }
}

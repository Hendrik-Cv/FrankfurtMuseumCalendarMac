import Foundation

final class KunstvereinFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "kunstverein" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let listURL = URL(string: "https://www.fkv.de/exhibitions-current-preview/")!
        let listHTML = try await HTMLFetcher.fetchHTML(from: listURL)

        // Tile: <a class="tile-link" href="/ausstellung/SLUG/">
        //         <h3 class="archive-title">TITLE</h3>
        //         <p class="subtitle">DD.MM.YYYY — DD.MM.YYYY | Ausstellung</p>
        guard let tileRegex = try? NSRegularExpression(
            pattern: #"class="tile-link"[^>]+href="([^"]+)"[\s\S]*?class="archive-title"[^>]*>([^<]+)</h3>[\s\S]*?class="subtitle"[^>]*>(\d{1,2}\.\d{1,2}\.\d{4})\s*[—–]\s*(\d{1,2}\.\d{1,2}\.\d{4})"#,
            options: []) else { throw FetcherError.parsingFailed("Regex failed") }

        struct Item { let germanURL: URL; let start: Date; let end: Date }
        let ns = listHTML as NSString
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var items: [Item] = []
        var seen = Set<String>()

        for m in tileRegex.matches(in: listHTML, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 4 else { continue }
            let href     = ns.substring(with: m.range(at: 1))
            let startStr = ns.substring(with: m.range(at: 3))
            let endStr   = ns.substring(with: m.range(at: 4))
            guard let start = HTMLFetcher.parseGermanDate(startStr),
                  let end   = HTMLFetcher.parseGermanDate(endStr),
                  end >= start else { continue }
            guard end >= cutoff else { continue }
            guard let detailURL = URL(string: href, relativeTo: listURL)?.absoluteURL,
                  seen.insert(href).inserted else { continue }
            items.append(Item(germanURL: detailURL, start: start, end: end))
        }
        guard !items.isEmpty else { throw FetcherError.noExhibitionsFound }

        let museum = self.museum
        var exhibitions: [Exhibition] = []
        await withTaskGroup(of: Exhibition?.self) { group in
            for item in items {
                group.addTask {
                    guard let html = try? await HTMLFetcher.fetchHTML(from: item.germanURL) else { return nil }
                    // Use German title from detail page <h1>
                    guard let rawTitle = HTMLFetcher.allCaptures(
                            pattern: #"<h1[^>]*>([^<]+)</h1>"#, in: html).first else { return nil }
                    let title = HTMLFetcher.stripHTML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { return nil }
                    let desc = Self.extractDescription(from: html)
                    return Exhibition(title: title, museum: museum, url: item.germanURL,
                                      startDate: item.start, endDate: item.end, description: desc)
                }
            }
            for await ex in group { if let ex { exhibitions.append(ex) } }
        }
        // Restore original listing order
        let byURL = Dictionary(exhibitions.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { $1 })
        return items.compactMap { byURL[$0.germanURL.absoluteString] }
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let listHTML = try await HTMLFetcher.fetchHTML(from: URL(string: "https://www.fkv.de/veranstaltungen/")!)

        // Step 1: collect event refs from listing
        struct EventRef { let url: URL; let title: String }
        let hrefs  = HTMLFetcher.allCaptures(pattern: #"href="(https://www\.fkv\.de/veranstaltung/[^"]+)""#, in: listHTML)
        let titles = HTMLFetcher.allCaptures(pattern: #"class="archive-title"[^>]*>([^<]+)<"#, in: listHTML)
        var refs: [EventRef] = []
        var seen = Set<String>()
        for (i, href) in hrefs.enumerated() {
            guard seen.insert(href).inserted, let url = URL(string: href) else { continue }
            let title = i < titles.count
                ? titles[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            refs.append(EventRef(url: url, title: title))
        }
        guard !refs.isEmpty else { return [] }

        // Step 2: fetch all detail pages concurrently
        var detailPages: [(EventRef, String)] = []
        await withTaskGroup(of: (EventRef, String)?.self) { group in
            for ref in refs {
                group.addTask { [url = ref.url] in
                    guard let html = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    return (ref, html)
                }
            }
            for await pair in group { if let pair { detailPages.append(pair) } }
        }

        // Step 3: extract events outside task closures
        var events: [MuseumEvent] = []
        for (ref, html) in detailPages {
            guard let date = parseKunstvereinDate(from: html) else { continue }
            let desc          = extractKunstvereinDescription(from: html)
            let exhibTitle    = extractKunstvereinExhibitionTitle(from: html)
            let eventType     = inferKunstvereinEventType(from: ref.title)
            events.append(MuseumEvent(
                title: ref.title,
                museum: museum,
                url: ref.url,
                date: date,
                eventType: eventType,
                description: desc,
                exhibitionTitle: exhibTitle
            ))
        }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        return events.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    // "21.06.2026, 16:00 Uhr" → Date
    private func parseKunstvereinDate(from html: String) -> Date? {
        guard let raw = HTMLFetcher.allCaptures(
                pattern: #"<p class="dates">([\s\S]*?)</p>"#, in: html).first else { return nil }
        let text = HTMLFetcher.stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let ns = text as NSString
        guard let regex = try? NSRegularExpression(
                pattern: #"(\d{1,2})\.(\d{1,2})\.(\d{4}),?\s*(\d{1,2}):(\d{2})\s*Uhr"#),
              let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 5 else { return nil }
        guard let day   = Int(ns.substring(with: m.range(at: 1))),
              let month = Int(ns.substring(with: m.range(at: 2))),
              let year  = Int(ns.substring(with: m.range(at: 3))),
              let hour  = Int(ns.substring(with: m.range(at: 4))),
              let min   = Int(ns.substring(with: m.range(at: 5))) else { return nil }
        return Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: min))
    }

    private func extractKunstvereinDescription(from html: String) -> String? {
        // All <p> except class="dates", converted to structured text
        let paras = HTMLFetcher.allCaptures(
            pattern: #"<p(?![^>]*class="dates")[^>]*>([\s\S]{25,}?)</p>"#, in: html)
            .map { HTMLFetcher.htmlToStructuredText($0) }
            .filter { text in
                text.count >= 25
                && !text.lowercased().contains("freuen uns")
                && !text.lowercased().contains("foaf:image")
                && !text.lowercased().contains("courtesy")
                && !text.lowercased().contains("photo:")
                && !text.hasPrefix("©")
            }
        guard !paras.isEmpty else { return nil }
        return paras.joined(separator: "\n\n")
    }

    private func extractKunstvereinExhibitionTitle(from html: String) -> String? {
        // Sidebar: "EXHIBITION TITLE DD.MM.YYYY — DD.MM.YYYY | Ausstellung"
        let sidebarHTML = HTMLFetcher.allCaptures(
            pattern: #"class="[^"]*sidebar[^"]*"[^>]*>([\s\S]*?)</(?:aside|div)>"#, in: html).first ?? ""
        var text = HTMLFetcher.stripHTML(sidebarHTML).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains("| Ausstellung") || text.contains("| Exhibition") else { return nil }
        // Strip date range
        if let r = text.range(of: #"\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) {
            text = String(text[..<r.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func inferKunstvereinEventType(from title: String) -> String {
        let l = title.lowercased()
        if l.contains("führung")                                   { return "Führung" }
        if l.contains("eröffnung") || l.contains("opening")       { return "Eröffnung" }
        if l.contains("finissage")                                 { return "Finissage" }
        if l.contains("gespräch") || l.contains("im gespräch")    { return "Gespräch" }
        if l.contains("vortrag")                                   { return "Vortrag" }
        if l.contains("workshop")                                  { return "Workshop" }
        if l.contains("lesung")                                    { return "Lesung" }
        if l.contains("konzert")                                   { return "Konzert" }
        if l.contains("performance")                               { return "Performance" }
        if l.contains("diskussion")                                { return "Diskussion" }
        return "Veranstaltung"
    }

    private static func extractDescription(from html: String) -> String? {
        // Skip photo caption paragraphs by class; capture remaining <p> content
        let paras = HTMLFetcher.allCaptures(
            pattern: #"<p(?![^>]*class="credits")[^>]*>([\s\S]{80,2000}?)</p>"#, in: html)

        var result: [String] = []
        var total = 0
        for p in paras {
            // Skip bold meta-info blocks (e.g. "Kuratiert von ...", "Eine Ausstellung des ...")
            if p.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<strong>") { continue }
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            // Skip date+meta lines like "19.06.2026 — ... Eine Ausstellung des ..."
            let startsWithDate = text.range(of: #"^\d{1,2}\.\d{1,2}\.\d{4}"#, options: .regularExpression) != nil
            guard text.count >= 80,
                  !startsWithDate,
                  !lower.contains("photo:"),
                  !lower.contains("courtesy"),
                  !lower.contains("ausstellungsansicht"),
                  !text.contains("©")
            else { continue }
            if total + text.count > 6000 { break }
            result.append(text)
            total += text.count
            if result.count >= 6 { break }
        }
        return result.isEmpty ? nil : result.joined(separator: "\n\n")
    }
}

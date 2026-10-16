import Foundation

final class PortikusFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "portikus" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let listHTML = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        let currentYear = Calendar.current.component(.year, from: Date())
        // Site redesign (2026-10): listing is now a flat run of
        // <a class="preview-exhibition" itemtype=".../ExhibitionEvent">…</a> cards,
        // each carrying its own year — no more per-year table wrapper to split on.
        let cardBlocks = HTMLFetcher.allCaptures(
            pattern: #"<a href="(/de/exhibitions/[^"]+)" class="preview-exhibition"[\s\S]*?</a>"#,
            in: listHTML, group: 0)
        struct Entry { let slug: String; let title: String }
        var entries: [Entry] = []
        for block in cardBlocks {
            guard let slug = HTMLFetcher.allCaptures(pattern: #"href="([^"]+)""#, in: block).first,
                  let yearStr = HTMLFetcher.allCaptures(
                    pattern: #"preview-exhibition__year">\s*(\d{4})"#, in: block).first,
                  let year = Int(yearStr), year >= currentYear - 1 else { continue }
            let artists = HTMLFetcher.allCaptures(pattern: #"itemprop="artist">([^<]*)</span>"#, in: block)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: ", ")
            guard let exTitle = HTMLFetcher.allCaptures(pattern: #"itemprop="title">([^<]*)</span>"#, in: block)
                    .first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !exTitle.isEmpty else { continue }
            let title = artists.isEmpty ? exTitle : "\(artists): \(exTitle)"
            entries.append(Entry(slug: slug, title: title))
        }
        guard !entries.isEmpty else { throw FetcherError.noExhibitionsFound }
        let museum = self.museum
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date())!
        var exhibitions: [Exhibition] = []
        await withTaskGroup(of: Exhibition?.self) { group in
            for entry in entries {
                group.addTask {
                    guard let pageURL = URL(string: "https://www.portikus.de\(entry.slug)"),
                          let html = try? await HTMLFetcher.fetchHTML(from: pageURL) else { return nil }
                    // Date range now sits right after the article number, e.g.
                    // <span class="article-number">#245</span>  03.10.2026–03.01.2027
                    guard let rawDate = HTMLFetcher.allCaptures(
                            pattern: #"article-number">#\d+</span>\s*([^<]+)"#, in: html).first,
                          let (start, end) = Self.parsePortikusDate(rawDate),
                          end >= cutoff else { return nil }
                    let desc: String? = HTMLFetcher.allCaptures(
                        pattern: #"<p[^>]*>([\s\S]{80,2000}?)</p>"#, in: html)
                    .map { HTMLFetcher.stripHTML($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { text in
                        text.count >= 80 &&
                        !text.lowercased().contains("pdf") &&
                        !text.lowercased().contains("eröffnung") &&
                        !text.contains(" Uhr")
                    })
                    return Exhibition(title: entry.title, museum: museum, url: pageURL,
                                      startDate: start, endDate: end, description: desc)
                }
            }
            for await result in group {
                if let e = result { exhibitions.append(e) }
            }
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return exhibitions.sorted { $0.startDate < $1.startDate }
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        // Homepage lists current exhibitions; small and fast
        let homeHTML = try await HTMLFetcher.fetchHTML(from: URL(string: "https://www.portikus.de/de/")!)
        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!

        // Only genuinely current exhibitions are linked from the homepage ("Aktuell");
        // archive/permanent homeitems use a non-linking JS-toggle div instead of <a href>.
        let hrefs = HTMLFetcher.allCaptures(
            pattern: #"<a href="(/de/exhibitions/[^"]+)" class="homeitem-title">"#, in: homeHTML)
        var exhibitionURLs: [URL] = []
        for href in hrefs {
            guard let url = URL(string: "https://www.portikus.de\(href)") else { continue }
            exhibitionURLs.append(url)
        }
        guard !exhibitionURLs.isEmpty else { return [] }

        // Fetch exhibition pages concurrently — parse outside the task group (actor isolation)
        var pages: [(URL, String)] = []
        await withTaskGroup(of: (URL, String)?.self) { group in
            for url in exhibitionURLs {
                group.addTask {
                    guard let html = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    return (url, html)
                }
            }
            for await r in group { if let r { pages.append(r) } }
        }

        var events: [MuseumEvent] = []
        for (pageURL, html) in pages {
            // Skip exhibitions that have already ended. Date range sits right after the
            // article number, e.g. <span class="article-number">#245</span>  03.10.2026–03.01.2027
            guard let dateRangeStr = extractFirst(
                    pattern: #"article-number">#\d+</span>\s*([^<]+)"#, in: html),
                  let (_, endDate) = Self.parsePortikusDate(dateRangeStr),
                  endDate >= cutoff else { continue }
            let fallbackYear = Calendar.current.component(.year, from: endDate)

            let exhibTitle = extractFirst(pattern: #"<title>([^<]+)</title>"#, in: html)?
                .replacingOccurrences(of: " - Portikus Frankfurt", with: "")
                .replacingOccurrences(of: #"^#\d+\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            events.append(contentsOf: parseInfoBlockEvents(
                html, pageURL: pageURL, exhibTitle: exhibTitle, fallbackYear: fallbackYear, cutoff: cutoff))
        }

        return events.sorted { $0.date < $1.date }
    }

    // `html` is the full exhibition page; event announcements ("Eröffnung: …",
    // "Open Rehearsals: …") are the only paragraphs tagged class="indent" on the page.
    private func parseInfoBlockEvents(_ html: String, pageURL: URL, exhibTitle: String?, fallbackYear: Int, cutoff: Date) -> [MuseumEvent] {
        let paras = HTMLFetcher.allCaptures(pattern: #"<p class="indent">([\s\S]{3,400}?)</p>"#, in: html)
        guard !paras.isEmpty else { return [] }

        var events: [MuseumEvent] = []
        for para in paras {
            let raw = HTMLFetcher.stripHTML(para)
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Expected format: "EventTitle: DD.MM.YYYY, HH Uhr"
            guard raw.contains(":"), raw.contains(".") else { continue }
            guard let colonRange = raw.range(of: ": ") else { continue }
            let eventTitle = String(raw[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let dateBlock  = String(raw[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract start hour from ", HH[-HH] Uhr"
            let ns = dateBlock as NSString
            var startHour = 0
            var datesOnly = dateBlock
            if let m = (try? NSRegularExpression(pattern: #",\s*(\d{1,2})[:\.\-]?\d*\s*(?:-[\d:\.]+)?\s*Uhr"#))?
                .firstMatch(in: dateBlock, range: NSRange(location: 0, length: ns.length)) {
                startHour = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
                    ? Int(ns.substring(with: m.range(at: 1))) ?? 0 : 0
                if let r = Range(m.range, in: dateBlock) { datesOnly = String(dateBlock[..<r.lowerBound]) }
            }

            // Year for year-less dates: use year from the last date part that has one
            let dateParts = datesOnly.components(separatedBy: "&").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var yearForSet = fallbackYear
            for part in dateParts {
                if let y = extractFirst(pattern: #"(20\d{2})"#, in: part).flatMap({ Int($0) }) { yearForSet = y }
            }

            for part in dateParts {
                guard let date = parsePortikusEventDate(part, year: yearForSet, hour: startHour),
                      date >= cutoff else { continue }
                events.append(MuseumEvent(
                    title: eventTitle, museum: museum, url: pageURL, date: date,
                    eventType: inferPortikusEventType(from: eventTitle),
                    exhibitionTitle: exhibTitle
                ))
            }
        }
        return events
    }

    private func parsePortikusEventDate(_ raw: String, year: Int, hour: Int) -> Date? {
        let ns = raw as NSString
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})\.(\d{1,2})\.(\d{4})?"#),
              let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 2 else { return nil }
        guard let day = Int(ns.substring(with: m.range(at: 1))),
              let month = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        let eventYear = (m.range(at: 3).location != NSNotFound && m.range(at: 3).length > 0)
            ? Int(ns.substring(with: m.range(at: 3))) ?? year : year
        var comps = DateComponents()
        comps.year = eventYear; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = 0
        return Calendar.current.date(from: comps)
    }

    private func inferPortikusEventType(from title: String) -> String {
        let l = title.lowercased()
        if l.contains("eröffnung") || l.contains("opening")     { return "Eröffnung" }
        if l.contains("finissage")                               { return "Finissage" }
        if l.contains("führung") || l.contains("tour")           { return "Führung" }
        if l.contains("rehearsal") || l.contains("probe")        { return "Performance" }
        if l.contains("performance")                             { return "Performance" }
        if l.contains("gespräch") || l.contains("talk")          { return "Gespräch" }
        if l.contains("workshop")                                { return "Workshop" }
        if l.contains("vortrag") || l.contains("lecture")        { return "Vortrag" }
        if l.contains("konzert")                                 { return "Konzert" }
        return "Veranstaltung"
    }

    // Parses "29.05.–30.08.2026" — year only on end date
    private nonisolated static func parsePortikusDate(_ raw: String) -> (Date, Date)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in ["–", "—", "-"] {
            let parts = s.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            var startStr = parts[0].trimmingCharacters(in: .whitespaces)
            let endStr   = parts[1].trimmingCharacters(in: .whitespaces)
            // Borrow year from end date if start is "DD.MM." only
            if startStr.hasSuffix("."),
               let yearRange = endStr.range(of: "20\\d{2}", options: .regularExpression) {
                startStr += String(endStr[yearRange])
            }
            if let start = HTMLFetcher.parseGermanDate(startStr),
               let end   = HTMLFetcher.parseGermanDate(endStr) {
                return (start, end)
            }
        }
        return nil
    }
}

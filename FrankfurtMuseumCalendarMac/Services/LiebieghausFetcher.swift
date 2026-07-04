import Foundation

final class LiebieghausFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "liebieghaus" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let exhibitions = try await super.fetchExhibitions()
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 6)
    }

    override func parseHTML(_ html: String) throws -> [Exhibition] {
        // Liebieghaus uses <li class="lh-exhibitions__item"> with lh-teaser__title and lh-teaser__subtitle
        let items = HTMLFetcher.allCaptures(
            pattern: #"<li[^>]*class="[^"]*lh-exhibitions__item[^"]*"[^>]*>([\s\S]*?)</li>"#, in: html)
        var result: [Exhibition] = []
        for item in items {
            guard let title = extractFirst(
                    pattern: #"class="lh-teaser__title"[^>]*>([^<]+)<"#, in: item)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            guard var dateRaw = extractFirst(
                    pattern: #"class="lh-teaser__subtitle"[^>]*>([^<]+)<"#, in: item) else { continue }
            dateRaw = dateRaw
                .replacingOccurrences(of: "&ndash;", with: "–")
                .replacingOccurrences(of: "&#8211;", with: "–")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let (start, end) = HTMLFetcher.parseDateRange(dateRaw) else { continue }
            let href = extractFirst(pattern: #"href="(/de/ausstellungen/[^"]+)""#, in: item)
                      ?? museum.exhibitionsURL.absoluteString
            let url = resolveURL(href)
            result.append(Exhibition(title: title, museum: museum, url: url, startDate: start, endDate: end))
        }
        return result.isEmpty ? try super.parseHTML(html) : result
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let calendarURL = URL(string: "https://liebieghaus.de/de/kalender")!
        let html = try await HTMLFetcher.fetchHTML(from: calendarURL)

        // All events are inline in the calendar — no second fetch needed
        let items = HTMLFetcher.allCaptures(
            pattern: #"<li[^>]*class="[^"]*lh-event-list__item[^"]*"[^>]*>([\s\S]{0,3000}?)</li>"#,
            in: html)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var events: [MuseumEvent] = []
        var seen = Set<String>()

        for item in items {
            guard let datetimeStr = extractFirst(
                    pattern: #"itemprop="startDate"[^>]*datetime="([^"]+)""#, in: item),
                  let date = iso.date(from: datetimeStr) else { continue }

            guard let rawTitle = extractFirst(
                    pattern: #"lh-event-list__title[^>]*>([^<]+)<"#, in: item) else { continue }
            let title = HTMLFetcher.stripHTML(rawTitle)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            // Dedup by datetime + title (calendar lists same events in grid AND "Unsere Tipps")
            guard seen.insert("\(datetimeStr)|\(title)").inserted else { continue }

            let isCancelled = title.lowercased().hasPrefix("abgesagt")

            let offering = extractFirst(
                pattern: #"lh-event-list__offering[^>]*>([^<]+)<"#, in: item)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let descHTML = extractFirst(
                pattern: #"lh-event-list__description[^>]*lh-typography[^>]*>([\s\S]{0,3000}?)</div>"#,
                in: item) ?? ""

            let (desc, exhibTitle, location) = parseLiebieghausEventDetail(from: descHTML)
            let eventType = mapLiebieghausOffering(offering)

            events.append(MuseumEvent(
                title: title,
                museum: museum,
                url: calendarURL,
                date: date,
                eventType: eventType,
                description: desc,
                exhibitionTitle: exhibTitle,
                location: location,
                isCancelled: isCancelled
            ))
        }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        return events.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    private func parseLiebieghausEventDetail(from descHTML: String) -> (String?, String?, String?) {
        let exhibTitle = extractFirst(
            pattern: #"href="/de/ausstellungen/[^"]+">([^<]+)<"#, in: descHTML)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let paras = HTMLFetcher.allCaptures(
            pattern: #"<p[^>]*>([\s\S]{0,2000}?)</p>"#, in: descHTML)
            .map { HTMLFetcher.htmlToStructuredText($0) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Zur Ausstellung") }

        var location: String? = nil
        for para in paras {
            if let r = para.range(of: "Treffpunkt:") {
                let after = String(para[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                let loc = after.components(separatedBy: "\n").first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                location = loc.isEmpty ? nil : loc
            }
        }

        let desc = paras.isEmpty ? nil : paras.joined(separator: "\n\n")
        return (desc, exhibTitle, location)
    }

    private func mapLiebieghausOffering(_ offering: String) -> String {
        let l = offering.lowercased()
        if l.contains("führung")                        { return "Führung" }
        if l.contains("atelierkurs") || l.contains("ferienkurs") || l.contains("workshop") { return "Kurs" }
        if l.contains("konzert") || l.contains("jazz") { return "Konzert" }
        if l.contains("vortrag") || l.contains("meisterwerke") { return "Vortrag" }
        if l.contains("lesung")                         { return "Lesung" }
        if l.contains("performance")                    { return "Performance" }
        return "Veranstaltung"
    }
}

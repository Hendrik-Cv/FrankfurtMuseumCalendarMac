import Foundation

final class WeltkulturenFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "weltkulturen" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let urls = [museum.exhibitionsURL,
                    museum.exhibitionsURL.appendingPathComponent("vorschau")]
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()
        for pageURL in urls {
            guard let html = try? await HTMLFetcher.fetchHTML(from: pageURL) else { continue }
            guard let regex = try? NSRegularExpression(
                pattern: #"href="(/de/ausstellungen/(?!vorschau|archiv)[^"]+)">([\s\S]{10,3000}?)</a>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 2 else { continue }
                let href    = ns.substring(with: match.range(at: 1))
                let content = ns.substring(with: match.range(at: 2))
                guard let title = HTMLFetcher.allCaptures(
                        pattern: #"<h2[^>]*>([^<]+)</h2>"#, in: content).first else { continue }
                let dateRaw = HTMLFetcher.allCaptures(
                    pattern: #"class="date"[^>]*>\s*([\s\S]{5,60}?)\s*<"#, in: content).first ?? ""
                guard let (start, end) = HTMLFetcher.parseDateRange(dateRaw) else { continue }
                let url = resolveURL(href)
                guard seen.insert(url.absoluteString).inserted else { continue }
                exhibitions.append(Exhibition(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                              museum: museum, url: url, startDate: start, endDate: end))
            }
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 6)
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let baseURL = "https://weltkulturenmuseum.de"
        let listBase = URL(string: "\(baseURL)/de/veranstaltungen/")!
        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        var events: [MuseumEvent] = []
        var seen = Set<String>()

        // Collect HTML from all pages concurrently
        var pageHTMLs: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for page in 1...8 {
                let pageURL = page == 1
                    ? listBase
                    : URL(string: "\(baseURL)/de/veranstaltungen/?page=\(page)")!
                group.addTask { try? await HTMLFetcher.fetchHTML(from: pageURL) }
            }
            for await html in group { if let html { pageHTMLs.append(html) } }
        }

        let germanDF = makeDateFormatter()

        for html in pageHTMLs {
            let items = HTMLFetcher.allCaptures(
                pattern: #"<div\s+class="panel-item[^"]*">\s*<div>\s*(<a[\s\S]{50,3000}?)</div>\s*</div>"#,
                in: html)
            for item in items {
                guard let href = extractFirst(pattern: #"href="(/de/veranstaltungen/[^"]+)""#, in: item) else { continue }
                let eventURL = URL(string: "\(baseURL)\(href)") ?? listBase
                guard seen.insert(href).inserted else { continue }

                let rawDate = extractFirst(
                    pattern: #"<span\s+class="date"[^>]*>\s*([\s\S]{5,120}?)\s*(?:<br|</span)"#, in: item) ?? ""
                let cleanDate = rawDate
                    .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let date = parseWKDate(cleanDate, formatter: germanDF) else { continue }
                guard date >= cutoff else { continue }

                // Title: all <br/>-separated text lines in the <p> after the date span
                let titleBlock = extractFirst(
                    pattern: #"</span></p><p>([\s\S]{5,500}?)</p>"#, in: item) ?? ""
                let titleLines = HTMLFetcher.allCaptures(pattern: #"([^<\n]{3,})"#, in: titleBlock)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix("br") && !$0.hasPrefix("/>") && !$0.hasSuffix(">") }
                guard let firstLine = titleLines.first else { continue }
                let title = titleLines.joined(separator: " ")
                let eventType = inferWKEventType(from: firstLine)

                events.append(MuseumEvent(
                    title: title,
                    museum: museum,
                    url: eventURL,
                    date: date,
                    eventType: eventType
                ))
            }
        }

        return events.sorted { $0.date < $1.date }
    }

    private func makeDateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.locale = Locale(identifier: "de_DE")
        df.dateFormat = "EEEE, d. MMMM yyyy - HH:mm"
        return df
    }

    // Parses "Sonntag, 28. Juni 2026 - 15:00" and
    // "Montag, 29. Juni 2026 - 09:30 bis Freitag, 3. Juli 2026 - 16:30"
    private func parseWKDate(_ raw: String, formatter: DateFormatter) -> Date? {
        let s = raw.components(separatedBy: " bis ").first ?? raw
        return formatter.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func inferWKEventType(from title: String) -> String {
        let l = title.lowercased()
        if l.contains("führung")                     { return "Führung" }
        if l.contains("workshop") || l.contains("ferien-workshop") { return "Workshop" }
        if l.contains("vortrag") || l.contains("lecture") { return "Vortrag" }
        if l.contains("konzert")                     { return "Konzert" }
        if l.contains("eröffnung") || l.contains("opening") { return "Eröffnung" }
        if l.contains("finissage")                   { return "Finissage" }
        if l.contains("lesung")                      { return "Lesung" }
        if l.contains("festival")                    { return "Festival" }
        return "Veranstaltung"
    }
}

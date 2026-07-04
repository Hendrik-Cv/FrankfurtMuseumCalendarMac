import Foundation

final class MfKFetcher: GenericMuseumFetcher, @unchecked Sendable {
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
            pattern: #"href="(https://www\.mfk-frankfurt\.de/[^"]+)"[\s\S]{0,600}?<h3[^>]*>([^<]{10,200})</h3>[\s\S]{0,400}?<p[^>]*>([^<]{5,80})</p>"#,
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

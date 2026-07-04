import Foundation

final class CaricaturaFetcher: GenericMuseumFetcher, @unchecked Sendable {
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
            guard let (start, end) = badges.lazy.compactMap({ parseBadgeDate($0) }).first else { continue }
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

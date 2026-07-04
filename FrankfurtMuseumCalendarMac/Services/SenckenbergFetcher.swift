import Foundation

final class SenckenbergFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "senckenberg" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)

        // Each card: <a href="URL">...<h3 class="headline...">TITLE</h3>...<p class="date">DATE</p>...
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\s+href="(https://museumfrankfurt\.senckenberg\.de/de/ausstellungen/sonderausstellungen/[^"]+)"[^>]*>[\s\S]*?<h3[^>]*class="[^"]*headline[^"]*"[^>]*>([^<]+)</h3>[\s\S]*?<p class="date">([^<]+)</p>"#,
            options: []) else { throw FetcherError.parsingFailed("Regex failed") }

        let ns = html as NSString
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()

        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 3 else { continue }
            let href    = ns.substring(with: m.range(at: 1))
            let title   = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let dateRaw = ns.substring(with: m.range(at: 3))
            guard !title.isEmpty, seen.insert(href).inserted else { continue }
            guard let url = URL(string: href) else { continue }
            guard let (start, end) = parseSenckenbergDate(dateRaw) else { continue }
            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }

        // Fetch detail pages concurrently, then extract descriptions outside task closures
        var detailPages: [(Exhibition, String)] = []
        await withTaskGroup(of: (Exhibition, String)?.self) { group in
            for ex in exhibitions {
                group.addTask { [url = ex.url] in
                    guard let html = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    return (ex, html)
                }
            }
            for await pair in group { if let pair { detailPages.append(pair) } }
        }

        let museum = self.museum
        return exhibitions.map { ex in
            guard let (_, pageHTML) = detailPages.first(where: { $0.0.id == ex.id }) else { return ex }
            guard let desc = extractDescription(from: pageHTML) else { return ex }
            return Exhibition(id: ex.id, title: ex.title, museum: museum, url: ex.url,
                              startDate: ex.startDate, endDate: ex.endDate, description: desc)
        }
    }

    // Handles "27. 3&nbsp;—&nbsp;18. 10. 2026" (numeric months, &nbsp; separators, year only at end)
    private func parseSenckenbergDate(_ raw: String) -> (Date, Date)? {
        let cleaned = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned.components(separatedBy: " — ")
        guard parts.count == 2 else { return nil }

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
             .replacingOccurrences(of: ". ", with: ".")
             .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        let endNorm = norm(parts[1])
        guard let end = HTMLFetcher.parseGermanDate(endNorm) else { return nil }
        let startNorm = norm(parts[0])
        if let start = HTMLFetcher.parseGermanDate(startNorm) { return (start, end) }
        let year = Calendar.current.component(.year, from: end)
        if let start = HTMLFetcher.parseGermanDate("\(startNorm).\(year)") { return (start, end) }
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
            guard !text.contains("Mitgliedschaft") else { continue }
            guard !text.contains("Zeichensprache") else { continue }
            guard !text.contains("Patenschaften") else { continue }
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

import Foundation

final class KunstvereinFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "kunstverein" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        // English listing has all current exhibitions with dates visible without JS
        let listURL = URL(string: "https://www.fkv.de/en/exhibitions/")!
        let listHTML = try await HTMLFetcher.fetchHTML(from: listURL)

        // Tile: <a class="tile-link" href="/en/exhibition/SLUG/">
        //         <h3 class="archive-title">TITLE</h3>
        //         <p class="subtitle">DD.MM.YYYY — DD.MM.YYYY | Exhibition</p>
        guard let tileRegex = try? NSRegularExpression(
            pattern: #"class="tile-link"[^>]+href="([^"]+)"[\s\S]*?class="archive-title"[^>]*>([^<]+)</h3>[\s\S]*?class="subtitle"[^>]*>(\d{1,2}\.\d{1,2}\.\d{4})\s*[—–]\s*(\d{1,2}\.\d{1,2}\.\d{4})"#,
            options: []) else { throw FetcherError.parsingFailed("Regex failed") }

        struct Item { let germanURL: URL; let start: Date; let end: Date }
        let ns = listHTML as NSString
        var items: [Item] = []
        var seen = Set<String>()

        for m in tileRegex.matches(in: listHTML, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 4 else { continue }
            let enHref   = ns.substring(with: m.range(at: 1))
            let startStr = ns.substring(with: m.range(at: 3))
            let endStr   = ns.substring(with: m.range(at: 4))
            guard let start = HTMLFetcher.parseGermanDate(startStr),
                  let end   = HTMLFetcher.parseGermanDate(endStr),
                  end >= start else { continue }
            // Convert /en/exhibition/SLUG/ → /ausstellung/SLUG/ for German detail page
            let germanHref = enHref.replacingOccurrences(of: "/en/exhibition/", with: "/ausstellung/")
            guard let germanURL = URL(string: germanHref),
                  seen.insert(germanHref).inserted else { continue }
            items.append(Item(germanURL: germanURL, start: start, end: end))
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

    private static func extractDescription(from html: String) -> String? {
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]{80,1500}?)</p>"#, in: html)
        return paras.compactMap { p -> String? in
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            guard text.count >= 80,
                  !lower.contains("photo:"),
                  !lower.contains("courtesy"),
                  !lower.contains("ausstellungsansicht"),
                  !text.hasPrefix("©"),
                  text.range(of: #"^\d{2}\.\d{2}\.\d{4}"#, options: .regularExpression) == nil
            else { return nil }
            return text
        }.first
    }
}

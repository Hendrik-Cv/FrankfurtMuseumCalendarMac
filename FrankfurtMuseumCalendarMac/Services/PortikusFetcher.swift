import Foundation

final class PortikusFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "portikus" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let listHTML = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        let currentYear = Calendar.current.component(.year, from: Date())
        let tableBlocks = HTMLFetcher.allCaptures(
            pattern: #"<div class="exhibition-table">([\s\S]*?)(?=<div class="exhibition-table">|$)"#,
            in: listHTML)
        struct Entry { let slug: String; let artist: String; let title: String }
        var entries: [Entry] = []
        for block in tableBlocks {
            let yearStr = HTMLFetcher.allCaptures(
                pattern: #"item-year td[^>]*>\s*(\d{4})"#, in: block).first ?? ""
            guard let year = Int(yearStr), year >= currentYear - 1 else { continue }
            guard let rowRegex = try? NSRegularExpression(
                pattern: #"data-href="(/de/exhibitions/[^"]+)"[\s\S]*?item-artist[^>]*>([\s\S]{3,200}?)</div>[\s\S]*?item-title[^>]*>\s*<a[^>]*>([^<]+)</a>"#,
                options: []) else { continue }
            let ns = block as NSString
            for m in rowRegex.matches(in: block, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges > 3 else { continue }
                let slug   = ns.substring(with: m.range(at: 1))
                let artist = HTMLFetcher.stripHTML(ns.substring(with: m.range(at: 2)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let exTitle = ns.substring(with: m.range(at: 3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = artist.isEmpty ? exTitle : "\(artist): \(exTitle)"
                entries.append(Entry(slug: slug, artist: artist, title: title))
            }
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
                    return await MainActor.run {
                        guard let infoBlock = HTMLFetcher.allCaptures(
                                pattern: #"wrap-exhibitons-info[^>]*>([\s\S]{0,400}?)</div>"#,
                                in: html).first,
                              let rawDate = HTMLFetcher.allCaptures(
                                pattern: #"<p>(\d{1,2}\.\d{1,2}\.[\s\S]{3,20}?)</p>"#,
                                in: infoBlock).first else { return nil }
                        guard let (start, end) = Self.parsePortikusDate(rawDate),
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
            }
            for await result in group {
                if let e = result { exhibitions.append(e) }
            }
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return exhibitions.sorted { $0.startDate < $1.startDate }
    }

    // Parses "29.05.–30.08.2026" — year only on end date
    private static func parsePortikusDate(_ raw: String) -> (Date, Date)? {
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

import Foundation

final class HistorischesMuseumFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "historisches" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        let entries = HTMLFetcher.allCaptures(
            pattern: #"<li[^>]*hmfScroller__entry[^>]*>([\s\S]*?)</li>"#, in: html)
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()
        for entry in entries {
            let href = HTMLFetcher.allCaptures(
                pattern: #"href="(https://historisches-museum-frankfurt\.de/de/ausstellungen/[^"]+)""#,
                in: entry).first ?? ""
            guard !href.isEmpty, let url = URL(string: href),
                  seen.insert(href).inserted else { continue }
            let titleRaw = HTMLFetcher.allCaptures(pattern: #"<a[^>]*>([\s\S]+?)</a>"#, in: entry).first ?? ""
            let title = HTMLFetcher.stripHTML(titleRaw)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let paras = HTMLFetcher.allCaptures(pattern: #"<p>([^<]+)</p>"#, in: entry)
            // Only entries with a date paragraph (contains digits)
            guard let datePara = paras.first(where: { $0.range(of: "\\d{2}\\.\\d{2}\\.\\d{2}", options: .regularExpression) != nil }) else { continue }
            guard let (start, end) = parseHMFDate(datePara) else { continue }
            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions)
    }

    // Parses "bis 31.01.27", "Ab 10.06.26", or "12.03.26 – 31.01.27"
    private func parseHMFDate(_ raw: String) -> (Date, Date)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func expand(_ shortDate: String) -> String {
            // "31.01.27" → "31.01.2027"
            let ns = shortDate as NSString
            guard let m = (try? NSRegularExpression(pattern: #"^(\d{1,2}\.\d{1,2}\.)(\d{2})$"#))?
                    .firstMatch(in: shortDate, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 2 else { return shortDate }
            let prefix = ns.substring(with: m.range(at: 1))
            let yr = Int(ns.substring(with: m.range(at: 2))) ?? 0
            return "\(prefix)\(yr < 50 ? 2000 + yr : 1900 + yr)"
        }
        // "bis DATE" — ongoing, infer start as 1 year before end
        if let rest = s.lowercased().starts(with: "bis ") ? Optional(String(s.dropFirst(4))) : nil {
            if let end = HTMLFetcher.parseGermanDate(expand(rest.trimmingCharacters(in: .whitespaces))) {
                let start = Calendar.current.date(byAdding: .year, value: -1, to: end) ?? end
                return (start, end)
            }
        }
        // "Ab DATE" or "ab DATE" — upcoming, infer end as 1 year after start
        if s.lowercased().hasPrefix("ab ") {
            let rest = String(s.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if let start = HTMLFetcher.parseGermanDate(expand(rest)) {
                let end = Calendar.current.date(byAdding: .year, value: 1, to: start) ?? start
                return (start, end)
            }
        }
        // Full range "DATE – DATE"
        if let (start, end) = HTMLFetcher.parseDateRange(s) { return (start, end) }
        return nil
    }
}

import Foundation

final class MAKFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "mak" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        // Only look at sections before "Vergangene Ausstellungen"
        let activeHTML: String
        if let cut = html.range(of: "Vergangene Ausstellungen") {
            activeHTML = String(html[..<cut.lowerBound])
        } else {
            activeHTML = html
        }
        let articles = HTMLFetcher.allCaptures(
            pattern: #"<article[^>]*mak-event-item[^>]*>([\s\S]*?)</article>"#, in: activeHTML)
        let months = "Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember"
        guard let regex = try? NSRegularExpression(
            pattern: "(\\d{1,2}\\. (?:\(months))(?:\\s+\\d{4})?) - (\\d{1,2}\\. (?:\(months)) \\d{4})",
            options: .caseInsensitive) else { throw FetcherError.parsingFailed("Regex failed") }
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()
        for article in articles {
            guard let title = HTMLFetcher.allCaptures(
                    pattern: #"mak-event-heading[^>]*>([^<]+)<"#, in: article).first,
                  !title.isEmpty else { continue }
            let dateRaw = HTMLFetcher.allCaptures(
                pattern: #"class="text-inverse">([^<]+)<"#, in: article).first ?? ""
            let ns = dateRaw as NSString
            guard let match = regex.firstMatch(in: dateRaw, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 2 else { continue }
            var startStr = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let endStr   = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if startStr.range(of: "\\d{4}", options: .regularExpression) == nil,
               let yearRange = endStr.range(of: "\\d{4}", options: .regularExpression) {
                startStr += " " + String(endStr[yearRange])
            }
            guard let start = HTMLFetcher.parseGermanDate(startStr),
                  let end   = HTMLFetcher.parseGermanDate(endStr), end >= start else { continue }
            let href = HTMLFetcher.allCaptures(
                pattern: #"href="(/de/besuch/ausstellungen/[^"]+)""#, in: article).first
                ?? museum.exhibitionsURL.absoluteString
            let url = resolveURL(href)
            let dedupeKey = url.absoluteString != museum.exhibitionsURL.absoluteString
                ? url.absoluteString
                : title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(dedupeKey).inserted else { continue }
            exhibitions.append(Exhibition(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                          museum: museum, url: url, startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions)
    }
}

import Foundation

final class FilmmuseumFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "filmmuseum" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        guard let apiURL = URL(string: "https://www.dff.film/wp-json/wp/v2/ausstellung?per_page=30&_fields=link,title,content") else {
            throw FetcherError.invalidURL
        }
        let data = try await HTMLFetcher.fetchData(from: apiURL)
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FetcherError.parsingFailed("WP API JSON parsing failed")
        }

        let months = "Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember"
        let dateOptYear = "\\d{1,2}\\.?\\s*(?:\(months))(?:\\s*\\d{4})?"
        let dateWithYear = "\\d{1,2}\\.?\\s*(?:\(months))\\s*\\d{4}"
        guard let regex = try? NSRegularExpression(
            pattern: "(?:vom\\s+)?(\(dateOptYear))\\s+bis\\s+(\(dateWithYear))",
            options: [.caseInsensitive]) else { throw FetcherError.parsingFailed("Regex failed") }

        var exhibitions: [Exhibition] = []
        for item in items {
            guard let linkStr = item["link"] as? String, let url = URL(string: linkStr),
                  let rawTitle = (item["title"] as? [String: Any])?["rendered"] as? String else { continue }
            let title = HTMLFetcher.stripHTML(rawTitle)
            let rawContent = (item["content"] as? [String: Any])?["rendered"] as? String ?? ""
            let plain = HTMLFetcher.stripHTML(rawContent)
            let ns = plain as NSString
            guard let match = regex.firstMatch(in: plain, range: NSRange(location: 0, length: ns.length)),
                  match.numberOfRanges > 2 else { continue }
            var startStr = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let endStr   = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            // If start date has no year, borrow the year from the end date
            if startStr.range(of: "\\d{4}", options: .regularExpression) == nil,
               let yearRange = endStr.range(of: "\\d{4}", options: .regularExpression) {
                startStr += " " + String(endStr[yearRange])
            }
            guard let start = HTMLFetcher.parseGermanDate(startStr),
                  let end   = HTMLFetcher.parseGermanDate(endStr), end >= start else { continue }
            // Extract description from content paragraphs, stripping WPBakery shortcodes first
            let cleanContent = rawContent.replacingOccurrences(
                of: #"\[/?[a-z_][a-z0-9_]*[^\]]*\]"#, with: " ", options: .regularExpression)
            let desc = HTMLFetcher.allCaptures(
                pattern: #"<p[^>]*>([\s\S]{30,}?)</p>"#, in: cleanContent)
            .compactMap { p -> String? in
                let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = text.lowercased()
                guard text.count >= 40,
                      !lower.hasPrefix("foto"),
                      !lower.hasPrefix("photo"),
                      !text.hasPrefix("©"),
                      !lower.contains("courtesy of")
                else { return nil }
                return text
            }.first
            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end, description: desc))
        }
        return exhibitions
    }
}

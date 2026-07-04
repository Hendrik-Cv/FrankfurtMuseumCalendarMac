import Foundation

final class LiebieghausFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "liebieghaus" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let exhibitions = try await super.fetchExhibitions()
        return await enrichWithDescriptions(exhibitions)
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
}

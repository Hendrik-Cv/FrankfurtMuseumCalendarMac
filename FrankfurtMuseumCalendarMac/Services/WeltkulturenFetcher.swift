import Foundation

final class WeltkulturenFetcher: GenericMuseumFetcher, @unchecked Sendable {
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
        return await enrichWithDescriptions(exhibitions)
    }
}

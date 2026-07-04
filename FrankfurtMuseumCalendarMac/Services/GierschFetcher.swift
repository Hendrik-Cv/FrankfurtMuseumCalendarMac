import Foundation

final class GierschFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "giersch" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        // Stop before the archive section
        let activeHTML: String
        if let cut = html.range(of: "ce-exhibition-archive") {
            activeHTML = String(html[..<cut.lowerBound])
        } else {
            activeHTML = html
        }
        var exhibitions: [Exhibition] = []
        let currentDates = HTMLFetcher.allCaptures(
            pattern: #"class="teaser-date">([^<]+)<"#, in: activeHTML)
        let currentTitles = HTMLFetcher.allCaptures(
            pattern: #"class="teaser-title">([^<]+)<"#, in: activeHTML)
        let currentHrefs = HTMLFetcher.allCaptures(
            pattern: #"<a\s+href="(https://www\.mggu\.de/ausstellungen/[^"]+)""#, in: activeHTML)
        for i in 0..<min(currentDates.count, currentTitles.count) {
            guard let (start, end) = parseGierschDate(currentDates[i]) else { continue }
            let url = i < currentHrefs.count ? URL(string: currentHrefs[i]) ?? museum.exhibitionsURL
                                             : museum.exhibitionsURL
            exhibitions.append(Exhibition(
                title: currentTitles[i].trimmingCharacters(in: .whitespacesAndNewlines),
                museum: museum, url: url, startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 3)
    }

    // Handles "28.03.2026 - 06.09.2026" and "6.11.26 – 16.5.27"
    private func parseGierschDate(_ raw: String) -> (Date, Date)? {
        func expand(_ s: String) -> String {
            // "6.11.26" → "6.11.2026"
            let ns = s as NSString
            guard let m = (try? NSRegularExpression(pattern: #"^(\d{1,2}\.\d{1,2}\.)(\d{2})$"#))?
                    .firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges > 2 else { return s }
            let prefix = ns.substring(with: m.range(at: 1))
            let yr = Int(ns.substring(with: m.range(at: 2))) ?? 0
            return "\(prefix)\(yr < 50 ? 2000 + yr : 1900 + yr)"
        }
        let separators = ["–", "—", " - ", " bis ", "−", "-"]
        for sep in separators {
            let parts = raw.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            let s = expand(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            let e = expand(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            if let start = HTMLFetcher.parseGermanDate(s), let end = HTMLFetcher.parseGermanDate(e) {
                return (start, end)
            }
        }
        return nil
    }
}

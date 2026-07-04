import Foundation

protocol EventFetcher: Sendable {
    var museum: Museum { get }
    func fetchEvents() async throws -> [MuseumEvent]
}

class GenericMuseumFetcher: @unchecked Sendable, MuseumFetcher {
    let museum: Museum

    init(museum: Museum) { self.museum = museum }

    func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)

        let jsonLD = HTMLFetcher.extractJSONLD(from: html)
        let fromJSONLD = HTMLFetcher.exhibitionsFromJSONLD(jsonLD, museum: museum)
        if !fromJSONLD.isEmpty { return fromJSONLD }

        return try parseHTML(html)
    }

    func parseHTML(_ html: String) throws -> [Exhibition] {
        // 1. <time datetime=""> pairs
        let byTime = parseByTimeElements(html)
        if !byTime.isEmpty { return byTime }

        // 2. <a> tags containing embedded date ranges in their text
        let byLinks = parseByLinksWithDates(html)
        if !byLinks.isEmpty { return byLinks }

        // 3. Block elements (<li>, <article>, <div>) containing date ranges
        let byBlocks = parseByBlocksWithDates(html)
        if !byBlocks.isEmpty { return byBlocks }

        // 4. Context scan: find date patterns anywhere in HTML, look backwards for title
        return parseByDateContext(html)
    }

    // MARK: - Strategy 1: <time datetime=""> pairs

    func parseByTimeElements(_ html: String) -> [Exhibition] {
        let datetimes = HTMLFetcher.allCaptures(
            pattern: #"<time[^>]+datetime=["\']([^"\']+)["\'][^>]*>"#, in: html)
        let titles = HTMLFetcher.allCaptures(
            pattern: #"<h[23][^>]*>([^<]{5,120})</h[23]>"#, in: html
        ).map { HTMLFetcher.stripHTML($0) }

        guard datetimes.count >= 2 else { return [] }
        var result: [Exhibition] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        var i = 0; var titleIndex = 0
        while i + 1 < datetimes.count {
            if let start = iso.date(from: datetimes[i]) ?? HTMLFetcher.parseGermanDate(datetimes[i]),
               let end   = iso.date(from: datetimes[i+1]) ?? HTMLFetcher.parseGermanDate(datetimes[i+1]),
               end >= start {
                let title = titleIndex < titles.count ? titles[titleIndex] : "Ausstellung"
                result.append(Exhibition(title: title, museum: museum,
                                         url: museum.exhibitionsURL, startDate: start, endDate: end))
                titleIndex += 1; i += 2
            } else { i += 1 }
        }
        return result
    }

    // MARK: - Strategy 2: <a> tags with embedded date ranges

    func parseByLinksWithDates(_ html: String) -> [Exhibition] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a[^>]+href=["\'"]([^"\'#\s][^"\']*)["\'"'][^>]*>([\s\S]{5,1200}?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var result: [Exhibition] = []
        var seenURLs = Set<String>()
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 2,
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: 2).location != NSNotFound else { continue }
            let href = ns.substring(with: match.range(at: 1))
            let text = HTMLFetcher.stripHTML(ns.substring(with: match.range(at: 2)))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count > 8 else { continue }
            guard let (title, start, end) = findTitleAndDates(in: text) else { continue }
            guard title.count >= 3, title.count <= 200 else { continue }
            let url = resolveURL(href)
            guard seenURLs.insert(url.absoluteString).inserted else { continue }
            result.append(Exhibition(title: title, museum: museum, url: url, startDate: start, endDate: end))
        }
        return result
    }

    // MARK: - Strategy 3: Block elements with date ranges

    func parseByBlocksWithDates(_ html: String) -> [Exhibition] {
        let blockPatterns = [
            #"<li[^>]*>([\s\S]{10,3000}?)</li>"#,
            #"<article[^>]*>([\s\S]{10,3000}?)</article>"#,
            #"<div[^>]+class="[^"]*(?:card|teaser|item|entry|event)[^"]*"[^>]*>([\s\S]{10,3000}?)</div>"#,
        ]
        var result: [Exhibition] = []
        var seenURLs = Set<String>()
        for blockPattern in blockPatterns {
            guard result.isEmpty,
                  let regex = try? NSRegularExpression(
                    pattern: blockPattern,
                    options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            let ns = html as NSString
            for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                guard match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { continue }
                let block = ns.substring(with: match.range(at: 1))
                let text  = HTMLFetcher.stripHTML(block)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count > 8 else { continue }
                guard let (title, start, end) = findTitleAndDates(in: text) else { continue }
                guard title.count >= 3, title.count <= 200 else { continue }
                let href = extractFirst(pattern: #"href=["\'"]([^"\'#\s][^"\'"]*)["\'""]"#, in: block)
                          ?? museum.exhibitionsURL.absoluteString
                let url  = resolveURL(href)
                guard seenURLs.insert(url.absoluteString).inserted else { continue }
                result.append(Exhibition(title: title, museum: museum, url: url, startDate: start, endDate: end))
            }
        }
        return result
    }

    // MARK: - Strategy 4: Context scan — find date pairs in raw HTML, look backwards for title

    func parseByDateContext(_ html: String) -> [Exhibition] {
        let months = "Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember"
        let numDate = #"\d{1,2}\.\d{1,2}\.20\d{2}"#
        let monDate = "\\d{1,2}\\.\\s*(?:\(months))\\s*20\\d{2}"
        let dateAlt = "(?:\(numDate)|\(monDate))"
        let pairPat = "(\(dateAlt))\\s*[–—−\\-]\\s*(\(dateAlt))"

        guard let regex = try? NSRegularExpression(pattern: pairPat, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        var result: [Exhibition] = []
        var seenKeys = Set<String>()

        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 2 else { continue }
            let startStr = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let endStr   = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            guard let start = HTMLFetcher.parseGermanDate(startStr),
                  let end   = HTMLFetcher.parseGermanDate(endStr),
                  end >= start else { continue }
            let key = "\(startStr)-\(endStr)"
            guard seenKeys.insert(key).inserted else { continue }

            // Look 700 chars before the date pair for title + URL
            let ctxStart = max(0, match.range.location - 700)
            let ctxLen   = match.range.location - ctxStart
            let context  = ns.substring(with: NSRange(location: ctxStart, length: ctxLen))

            // Find nearest heading or strong text (last occurrence = closest to date)
            let title = lastCapture(pattern: #"<h[1-6][^>]*>([^<]{3,150})</h[1-6]>"#, in: context)
                     ?? lastCapture(pattern: #"<strong[^>]*>([^<]{3,150})</strong>"#, in: context)
                     ?? lastCapture(pattern: #"<b[^>]*>([^<]{5,150})</b>"#, in: context)
            guard var t = title.map({ HTMLFetcher.stripHTML($0).trimmingCharacters(in: .whitespacesAndNewlines) }),
                  t.count >= 3 else { continue }
            t = t.replacingOccurrences(of: #"[\s\-–|·•]+$"#, with: "", options: .regularExpression)
                 .trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 3, t.count <= 200 else { continue }

            let href = lastCapture(pattern: #"href=["\'"]([^"\'#\s][^"\'"]*)["\'""]"#, in: context)
                      ?? museum.exhibitionsURL.absoluteString
            let url  = resolveURL(href)

            result.append(Exhibition(title: t, museum: museum, url: url, startDate: start, endDate: end))
        }
        return result
    }

    // MARK: - Shared helpers

    func findTitleAndDates(in text: String) -> (String, Date, Date)? {
        let months = "Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember"
        let numDate = #"\d{1,2}\.\d{1,2}\.20\d{2}"#
        let monDate = "\\d{1,2}\\.\\s*(?:\(months))\\s*20\\d{2}"
        let dateGrp = "(?:\(numDate)|\(monDate))"
        let sepGrp  = "\\s*[–—−\\-]\\s*|\\s+bis\\s+"
        let pattern = "(\(dateGrp))(\(sepGrp))(\(dateGrp))"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 3 else { return nil }

        let startStr = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        let endStr   = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces)
        guard let start = HTMLFetcher.parseGermanDate(startStr),
              let end   = HTMLFetcher.parseGermanDate(endStr),
              end >= start else { return nil }

        var title = ns.substring(with: NSRange(location: 0, length: match.range.location))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count < 3 {
            let afterStart = match.range.location + match.range.length
            title = ns.substring(with: NSRange(location: afterStart, length: ns.length - afterStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        title = title.replacingOccurrences(of: #"[\s\-–|·•]+$"#, with: "", options: .regularExpression)
                     .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.count >= 3 ? (title, start, end) : nil
    }

    func resolveURL(_ href: String) -> URL {
        URL(string: href, relativeTo: museum.websiteURL)?.absoluteURL ?? museum.exhibitionsURL
    }

    func extractFirst(pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    func lastCapture(pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard let last = matches.last, last.numberOfRanges > 1,
              last.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: last.range(at: 1))
    }

    func enrichWithDescriptions(_ exhibitions: [Exhibition], maxParagraphs: Int = 1) async -> [Exhibition] {
        let museum = self.museum
        var enriched: [Exhibition] = []
        await withTaskGroup(of: Exhibition.self) { group in
            for ex in exhibitions {
                group.addTask {
                    guard ex.description == nil,
                          ex.url.absoluteString != museum.exhibitionsURL.absoluteString,
                          let html = try? await HTMLFetcher.fetchHTML(from: ex.url) else { return ex }
                    let og = HTMLFetcher.extractMetaDescription(from: html)
                    let content = HTMLFetcher.extractContentDescription(from: html, maxParagraphs: maxParagraphs)
                    // Prefer content description when it's substantially longer than OG
                    let desc: String?
                    if let og, let content, content.count > og.count * 2 {
                        desc = content
                    } else {
                        desc = og ?? content
                    }
                    guard let desc else { return ex }
                    return Exhibition(id: ex.id, title: ex.title, museum: ex.museum, url: ex.url,
                                      startDate: ex.startDate, endDate: ex.endDate, description: desc)
                }
            }
            for await ex in group { enriched.append(ex) }
        }
        let byID = Dictionary(enriched.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        return exhibitions.map { byID[$0.id] ?? $0 }
    }
}

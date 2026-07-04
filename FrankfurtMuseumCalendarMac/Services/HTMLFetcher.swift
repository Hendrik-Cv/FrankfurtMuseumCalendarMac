import Foundation

enum FetcherError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case httpError(Int)
    case parsingFailed(String)
    case noExhibitionsFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:              return "Ungültige URL"
        case .networkError(let e):     return "Netzwerkfehler: \(e.localizedDescription)"
        case .httpError(let code):     return "HTTP \(code)"
        case .parsingFailed(let msg):  return "Parsing fehlgeschlagen: \(msg)"
        case .noExhibitionsFound:      return "Keine Ausstellungen gefunden"
        }
    }
}

protocol MuseumFetcher: Sendable {
    var museum: Museum { get }
    func fetchExhibitions() async throws -> [Exhibition]
}

// MARK: - Shared HTTP + HTML utilities

// Accepts any SSL certificate — needed for museums with expired/self-signed certs
private final class AnySSLDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum HTMLFetcher {
    private static let delegate = AnySSLDelegate()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "de-DE,de;q=0.9,en;q=0.8"
        ]
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()

    static func fetchHTML(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetcherError.httpError(http.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else {
            throw FetcherError.parsingFailed("Konnte HTML nicht dekodieren")
        }
        return html
    }

    static func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetcherError.httpError(http.statusCode)
        }
        return data
    }

    // Extract all JSON-LD blocks from the page
    static func extractJSONLD(from html: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        let pattern = #"<script[^>]+type=["\']application/ld\+json["\'][^>]*>([\s\S]*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let jsonStr = String(html[r])
            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let dict = obj as? [String: Any] {
                results.append(dict)
            } else if let arr = obj as? [[String: Any]] {
                results.append(contentsOf: arr)
            }
        }
        return results
    }

    // Parse JSON-LD events into Exhibitions
    static func exhibitionsFromJSONLD(_ items: [[String: Any]], museum: Museum) -> [Exhibition] {
        let eventTypes: Set<String> = ["Event", "ExhibitionEvent", "VisualArtsEvent", "SocialEvent"]
        var exhibitions: [Exhibition] = []

        func process(_ dict: [String: Any]) {
            let typeRaw = dict["@type"]
            let typeStr: String?
            if let s = typeRaw as? String { typeStr = s }
            else if let arr = typeRaw as? [String] { typeStr = arr.first }
            else { typeStr = nil }

            guard let t = typeStr, eventTypes.contains(t) else { return }
            guard let rawTitle = dict["name"] as? String else { return }
            let title = stripHTML(rawTitle)

            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withFullDate]
            let startStr = dict["startDate"] as? String ?? ""
            let endStr   = dict["endDate"]   as? String ?? ""
            guard let start = iso.date(from: startStr) ?? parseGermanDate(startStr),
                  let end   = iso.date(from: endStr)   ?? parseGermanDate(endStr) else { return }

            let urlStr = dict["url"] as? String ?? museum.exhibitionsURL.absoluteString
            let url = URL(string: urlStr) ?? museum.exhibitionsURL
            let desc = (dict["description"] as? String).map { stripHTML($0) }

            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end, description: desc))
        }

        for item in items {
            if let graph = item["@graph"] as? [[String: Any]] {
                graph.forEach { process($0) }
            } else {
                process(item)
            }
        }
        return exhibitions
    }

    // Convert HTML to structured plain text: preserves paragraph breaks and <br> as newlines.
    // Use this instead of stripHTML when the source has a meaningful multi-paragraph structure.
    static func htmlToStructuredText(_ html: String) -> String {
        var s = html
        // Entities
        s = s
            .replacingOccurrences(of: "&amp;",   with: "&")
            .replacingOccurrences(of: "&lt;",    with: "<")
            .replacingOccurrences(of: "&gt;",    with: ">")
            .replacingOccurrences(of: "&nbsp;",  with: " ")
            .replacingOccurrences(of: "&quot;",  with: "\"")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
        // Numeric character references (&#38; etc.)
        if let ncr = try? NSRegularExpression(pattern: #"&#(\d{1,6});"#) {
            let ns = s as NSString
            for m in ncr.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard let code = Int(ns.substring(with: m.range(at: 1))),
                      let scalar = Unicode.Scalar(code),
                      let r = Range(m.range, in: s) else { continue }
                s.replaceSubrange(r, with: String(Character(scalar)))
            }
        }
        // Block-level tags → newlines
        // Consume optional trailing whitespace/newline after <br> so we don't get double blank lines
        s = s.replacingOccurrences(of: #"<br\s*/?>[ \t]*\r?\n?"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</p>"#,        with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</h[1-6]>"#,  with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"</li>"#,       with: "\n",   options: .regularExpression)
        // Strip remaining tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Normalize whitespace per line and collapse 3+ blank lines
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        s = lines.joined(separator: "\n")
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Strip HTML tags and decode entities
    static func stripHTML(_ html: String) -> String {
        // Remove literal escape sequences (e.g. \n, \t from JSON-LD double-escaping)
        var s = html
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
        // Decode entities first so that entity-encoded tags like &lt;p&gt; are also stripped
        s = s
            .replacingOccurrences(of: "&amp;",   with: "&")
            .replacingOccurrences(of: "&lt;",    with: "<")
            .replacingOccurrences(of: "&gt;",    with: ">")
            .replacingOccurrences(of: "&nbsp;",  with: " ")
            .replacingOccurrences(of: "&quot;",  with: "\"")
            .replacingOccurrences(of: "&ndash;", with: "–")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&copy;",  with: "©")
            .replacingOccurrences(of: "&reg;",   with: "®")
        // Decode all remaining &#NNN; numeric character references (e.g. &#038; → &, &#39; → ')
        if let ncr = try? NSRegularExpression(pattern: #"&#(\d{1,6});"#) {
            let ns = s as NSString
            for match in ncr.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
                guard match.numberOfRanges > 1,
                      let code = Int(ns.substring(with: match.range(at: 1))),
                      let scalar = Unicode.Scalar(code),
                      let range = Range(match.range, in: s) else { continue }
                s.replaceSubrange(range, with: String(Character(scalar)))
            }
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Extract first capture group for all matches of a pattern
    static func allCaptures(pattern: String, in html: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges > group else { return nil }
            let r = match.range(at: group)
            guard r.location != NSNotFound else { return nil }
            return ns.substring(with: r)
        }
    }

    // Parse German date strings: dd.MM.yyyy, d. MMMM yyyy, yyyy-MM-dd
    static func parseGermanDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = ["dd.MM.yyyy", "d.M.yyyy", "d. MMMM yyyy", "d. MMM yyyy",
                       "yyyy-MM-dd", "dd. MMMM yyyy", "MMMM yyyy"]
        for fmt in formats {
            let f = DateFormatter()
            f.dateFormat = fmt
            f.locale = Locale(identifier: "de_DE")
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // Extract og:description or meta description from a page's HTML
    static func extractMetaDescription(from html: String) -> String? {
        let patterns = [
            #"<meta\s+property="og:description"\s+content="([^"]{20,600})""#,
            #"<meta\s+content="([^"]{20,600})"\s+property="og:description""#,
            #"<meta\s+name="description"\s+content="([^"]{20,600})""#,
            #"<meta\s+content="([^"]{20,600})"\s+name="description""#,
        ]
        for pattern in patterns {
            if let raw = allCaptures(pattern: pattern, in: html).first {
                let text = stripHTML(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 20 { return text }
            }
        }
        return nil
    }

    // Extract real content paragraphs from a page, filtering out boilerplate.
    // maxParagraphs > 1 joins multiple paragraphs up to ~1500 chars total.
    static func extractContentDescription(from html: String, maxParagraphs: Int = 1) -> String? {
        let paras = allCaptures(pattern: #"<p[^>]*>([\s\S]{80,3000}?)</p>"#, in: html)
        let candidates: [String] = paras.compactMap { p -> String? in
            let text = stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 80 else { return nil }
            let lower = text.lowercased()
            if lower.contains("upgrade your browser") { return nil }
            if lower.contains("javascript") && text.count < 300 { return nil }
            if lower.contains("cookie") && text.count < 200 { return nil }
            if lower.hasPrefix("foto") || lower.hasPrefix("photo") { return nil }
            if text.hasPrefix("©") || text.contains("©") && text.count < 400 { return nil }
            if lower.contains("courtesy of") { return nil }
            if text.contains("Kalender") && text.contains("News") { return nil }
            if text.range(of: #"^\d+\s*€"#, options: .regularExpression) != nil { return nil }
            if lower.contains("eintritt") && text.count < 150 { return nil }
            // Skip date-range meta lines (e.g. "13. Februar – 26. April 2026 Eine Zusammenarbeit")
            let startsWithDate = text.range(of: #"^\d{1,2}\.?\s*(0?\d|Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember)"#, options: .regularExpression) != nil
            if startsWithDate { return nil }
            return text
        }
        if maxParagraphs == 1 {
            return candidates.first(where: { !$0.hasSuffix("?") }) ?? candidates.first
        }
        // Multiple paragraphs: preserve page order, cap at 6000 chars total
        var result: [String] = []
        var total = 0
        for p in candidates.prefix(maxParagraphs) {
            if total + p.count > 6000 { break }
            result.append(p)
            total += p.count
        }
        return result.isEmpty ? nil : result.joined(separator: "\n\n")
    }

    // Parse a date-range text like "12.06.2025 – 14.09.2025"
    static func parseDateRange(_ text: String) -> (Date, Date)? {
        let separators = ["–", "—", " bis ", " - ", "−", "&ndash;", "&mdash;"]
        for sep in separators {
            let parts = text.components(separatedBy: sep)
            guard parts.count == 2 else { continue }
            if let s = parseGermanDate(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
               let e = parseGermanDate(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) {
                return (s, e)
            }
        }
        return nil
    }
}

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
            guard let title = dict["name"] as? String else { return }

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

    // Strip HTML tags and decode entities
    static func stripHTML(_ html: String) -> String {
        var s = html
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
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

    // Parse a date-range text like "12.06.2025 – 14.09.2025"
    static func parseDateRange(_ text: String) -> (Date, Date)? {
        let separators = ["–", "—", " bis ", " - ", "−"]
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

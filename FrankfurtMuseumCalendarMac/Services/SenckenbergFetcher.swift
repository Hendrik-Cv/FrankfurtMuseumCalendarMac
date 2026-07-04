import Foundation

final class SenckenbergFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "senckenberg" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)

        // Each card: <a href="URL">...<h3 class="headline...">TITLE</h3>...<p class="date">DATE</p>...
        guard let regex = try? NSRegularExpression(
            pattern: #"<a\s+href="(https://museumfrankfurt\.senckenberg\.de/de/ausstellungen/sonderausstellungen/[^"]+)"[^>]*>[\s\S]*?<h3[^>]*class="[^"]*headline[^"]*"[^>]*>([^<]+)</h3>[\s\S]*?<p class="date">([^<]+)</p>"#,
            options: []) else { throw FetcherError.parsingFailed("Regex failed") }

        let ns = html as NSString
        var exhibitions: [Exhibition] = []
        var seen = Set<String>()

        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 3 else { continue }
            let href    = ns.substring(with: m.range(at: 1))
            let title   = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let dateRaw = ns.substring(with: m.range(at: 3))
            guard !title.isEmpty, seen.insert(href).inserted else { continue }
            guard let url = URL(string: href) else { continue }
            guard let (start, end) = parseSenckenbergDate(dateRaw) else { continue }
            exhibitions.append(Exhibition(title: title, museum: museum, url: url,
                                          startDate: start, endDate: end))
        }
        guard !exhibitions.isEmpty else { throw FetcherError.noExhibitionsFound }

        // Fetch detail pages concurrently, then extract descriptions outside task closures
        var detailPages: [(Exhibition, String)] = []
        await withTaskGroup(of: (Exhibition, String)?.self) { group in
            for ex in exhibitions {
                group.addTask { [url = ex.url] in
                    guard let html = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    return (ex, html)
                }
            }
            for await pair in group { if let pair { detailPages.append(pair) } }
        }

        let museum = self.museum
        return exhibitions.map { ex in
            guard let (_, pageHTML) = detailPages.first(where: { $0.0.id == ex.id }) else { return ex }
            guard let desc = extractDescription(from: pageHTML) else { return ex }
            return Exhibition(id: ex.id, title: ex.title, museum: museum, url: ex.url,
                              startDate: ex.startDate, endDate: ex.endDate, description: desc)
        }
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let apiBase = "https://www.senckenberg.de/de/wp-json/wp/v2"

        // Fetch event type taxonomy and events concurrently
        var taxHTML = ""
        var evHTML = ""
        await withTaskGroup(of: (Int, String).self) { group in
            group.addTask {
                let r = (try? await HTMLFetcher.fetchHTML(from: URL(string: "\(apiBase)/event_type?per_page=50&_fields=id,name")!)) ?? ""
                return (0, r)
            }
            group.addTask {
                let r = (try? await HTMLFetcher.fetchHTML(from: URL(string: "\(apiBase)/events?per_page=100&_fields=id,link,acf,event_type&status=publish")!)) ?? ""
                return (1, r)
            }
            for await (idx, html) in group {
                if idx == 0 { taxHTML = html } else { evHTML = html }
            }
        }

        // Build event type lookup: term ID → human-readable name
        var typeMap: [Int: String] = [:]
        if let data = taxHTML.data(using: .utf8),
           let terms = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for term in terms {
                if let id = term["id"] as? Int, let name = term["name"] as? String {
                    typeMap[id] = name
                }
            }
        }

        guard let data = evHTML.data(using: .utf8),
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FetcherError.parsingFailed("Senckenberg events JSON")
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "Europe/Berlin")

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        let calURL = URL(string: "https://www.senckenberg.de/de/kalender/")!
        var result: [MuseumEvent] = []
        var seen = Set<Int>()

        for event in events {
            guard let id = event["id"] as? Int, seen.insert(id).inserted else { continue }
            guard let acf = event["acf"] as? [String: Any],
                  (acf["hide_event"] as? Int) == 0 else { continue }
            guard let startStr = acf["event_start_time"] as? String,
                  let date = df.date(from: startStr),
                  date >= cutoff else { continue }

            let rawTitle = (acf["event_title"] as? String) ?? ""
            let title = HTMLFetcher.stripHTML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let link = event["link"] as? String ?? ""
            let eventURL = URL(string: link) ?? calURL

            // Resolve event type from taxonomy; fall back to title-based inference
            let typeIDs = (event["event_type"] as? [Any] ?? []).compactMap { v -> Int? in
                if let i = v as? Int { return i }
                if let n = v as? NSNumber { return n.intValue }
                return nil
            }
            let eventType = typeIDs.compactMap { typeMap[$0] }.first
                ?? inferSenckenbergEventType(from: title)

            let soldOut = (acf["event_sold_out"] as? Int) == 1
            let description = extractSenckenbergDescription(acf["event_decription"] as? String ?? "")

            result.append(MuseumEvent(
                title: title,
                museum: museum,
                url: eventURL,
                date: date,
                eventType: eventType,
                description: description,
                notes: soldOut ? "Ausgebucht" : nil
            ))
        }

        return result.sorted { $0.date < $1.date }
    }

    private func extractSenckenbergDescription(_ html: String) -> String? {
        guard !html.isEmpty else { return nil }
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]{40,2000}?)</p>"#, in: html)
        for p in paras {
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 40 else { continue }
            let lower = text.lowercased()
            guard !lower.hasPrefix("ort:") && !lower.hasPrefix("zeitplan:") else { continue }
            guard !lower.contains("mailto:") else { continue }
            return text.count > 600 ? String(text.prefix(600)) + "…" : text
        }
        let stripped = HTMLFetcher.stripHTML(html).trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.count >= 40 ? String(stripped.prefix(500)) : nil
    }

    private func inferSenckenbergEventType(from title: String) -> String {
        let l = title.lowercased()
        if l.contains("führung") || l.contains("tour")       { return "Führung" }
        if l.contains("workshop")                             { return "Workshop" }
        if l.contains("vortrag") || l.contains("lecture")    { return "Vortrag" }
        if l.contains("exkursion") || l.contains("spazier")  { return "Exkursion" }
        if l.contains("eröffnung") || l.contains("opening")  { return "Ausstellungseröffnung" }
        if l.contains("film") || l.contains("kino")          { return "Film" }
        if l.contains("diskussion")                          { return "Diskussion" }
        if l.contains("konzert")                             { return "Konzert" }
        if l.contains("lesung")                              { return "Lesung" }
        return "Veranstaltung"
    }

    // Handles "27. 3&nbsp;—&nbsp;18. 10. 2026" (numeric months, &nbsp; separators, year only at end)
    private func parseSenckenbergDate(_ raw: String) -> (Date, Date)? {
        let cleaned = raw
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned.components(separatedBy: " — ")
        guard parts.count == 2 else { return nil }

        func norm(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
             .replacingOccurrences(of: ". ", with: ".")
             .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }

        let endNorm = norm(parts[1])
        guard let end = HTMLFetcher.parseGermanDate(endNorm) else { return nil }
        let startNorm = norm(parts[0])
        if let start = HTMLFetcher.parseGermanDate(startNorm) { return (start, end) }
        let year = Calendar.current.component(.year, from: end)
        if let start = HTMLFetcher.parseGermanDate("\(startNorm).\(year)") { return (start, end) }
        return nil
    }

    private func extractDescription(from html: String) -> String? {
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]{80,3000}?)</p>"#, in: html)
        var result: [String] = []
        var total = 0
        for p in paras {
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = text.lowercased()
            guard text.count >= 80 else { continue }
            guard !text.contains("Mitgliedschaft") else { continue }
            guard !text.contains("Zeichensprache") else { continue }
            guard !text.contains("Patenschaften") else { continue }
            guard !lower.contains("upgrade your browser") else { continue }
            guard !(lower.contains("javascript") && text.count < 300) else { continue }
            guard !(lower.contains("cookie") && text.count < 200) else { continue }
            guard !(text.hasPrefix("©") || (text.contains("©") && text.count < 400)) else { continue }
            guard !lower.contains("courtesy of") else { continue }
            if total + text.count > 6000 { break }
            result.append(text)
            total += text.count
            if result.count >= 6 { break }
        }
        return result.isEmpty ? nil : result.joined(separator: "\n\n")
    }
}

import Foundation

final class MAKFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
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
        return await enrichWithDescriptions(exhibitions, maxParagraphs: 6)
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let html = try await HTMLFetcher.fetchHTML(from: museum.exhibitionsURL)
        let activeHTML: String
        if let cut = html.range(of: "Vergangene Ausstellungen") {
            activeHTML = String(html[..<cut.lowerBound])
        } else {
            activeHTML = html
        }

        let articles = HTMLFetcher.allCaptures(
            pattern: #"<article[^>]*mak-event-item[^>]*>([\s\S]*?)</article>"#, in: activeHTML)

        let months = "Januar|Februar|März|April|Mai|Juni|Juli|August|September|Oktober|November|Dezember"
        let dateRegex = try? NSRegularExpression(
            pattern: "(\\d{1,2}\\. (?:\(months))(?:\\s+\\d{4})?) - (\\d{1,2}\\. (?:\(months)) \\d{4})",
            options: .caseInsensitive)

        struct ExhibitionRef { let url: URL; let endDate: Date? }
        var refs: [ExhibitionRef] = []

        for article in articles {
            guard let href = HTMLFetcher.allCaptures(
                pattern: #"href="(/de/besuch/ausstellungen/[^"]+)""#, in: article).first else { continue }
            let url = resolveURL(href)
            var endDate: Date? = nil
            if let regex = dateRegex {
                let raw = HTMLFetcher.allCaptures(
                    pattern: #"class="text-inverse">([^<]+)<"#, in: article).first ?? ""
                let ns = raw as NSString
                if let m = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)),
                   m.numberOfRanges > 2 {
                    endDate = HTMLFetcher.parseGermanDate(ns.substring(with: m.range(at: 2)))
                }
            }
            refs.append(ExhibitionRef(url: url, endDate: endDate))
        }

        guard !refs.isEmpty else { return [] }

        // Step 1: fetch all detail pages concurrently
        var detailPages: [(ExhibitionRef, String)] = []
        await withTaskGroup(of: (ExhibitionRef, String)?.self) { group in
            for ref in refs {
                group.addTask { [url = ref.url] in
                    guard let pageHTML = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    return (ref, pageHTML)
                }
            }
            for await pair in group { if let pair { detailPages.append(pair) } }
        }

        // Step 2: extract events outside task closures (actor isolation)
        var allEvents: [MuseumEvent] = []
        for (ref, pageHTML) in detailPages {
            let events = extractMAKEvents(from: pageHTML, url: ref.url, endDate: ref.endDate)
            allEvents.append(contentsOf: events)
        }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        return allEvents
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
    }

    private func extractMAKEvents(from html: String, url: URL, endDate: Date?) -> [MuseumEvent] {
        let articles = HTMLFetcher.allCaptures(
            pattern: #"<article[^>]*mak-event-item[^>]*>([\s\S]*?)</article>"#, in: html)
        let museum = self.museum
        var events: [MuseumEvent] = []

        for article in articles {
            guard let dayStr = HTMLFetcher.allCaptures(
                    pattern: #"mak-event-day">([^<]+)<"#, in: article).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let headingRaw = HTMLFetcher.allCaptures(
                    pattern: #"mak-event-heading">([^<]+)<"#, in: article).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            else { continue }

            let weekday = HTMLFetcher.allCaptures(
                pattern: #"mak-event-weekday">([^<]+)<"#, in: article).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let isCancelled = headingRaw.hasPrefix("Fällt aus!")
            let headingClean = isCancelled
                ? headingRaw.replacingOccurrences(of: "Fällt aus! ", with: "").trimmingCharacters(in: .whitespaces)
                : headingRaw

            // Parse "[HH:mm Uhr –] Title" or "[HH–HH Uhr –] Title" (time range → use start hour)
            var hour = 0, minute = 0, title = headingClean
            let ns = headingClean as NSString
            let timePattern = #"^(\d{1,2})(?:[.:](\d{2}))?(?:\s*[–\-]\s*\d{1,2}(?:[.:]\d{2})?)?\s*Uhr\s*[–\-]\s*"#
            if let regex = try? NSRegularExpression(pattern: timePattern),
               let m = regex.firstMatch(in: headingClean, range: NSRange(location: 0, length: ns.length)) {
                hour = Int(ns.substring(with: m.range(at: 1))) ?? 0
                if m.range(at: 2).location != NSNotFound {
                    minute = Int(ns.substring(with: m.range(at: 2))) ?? 0
                }
                title = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespaces)
            }

            guard !title.isEmpty,
                  let date = parseMAKEventDate(dayStr: dayStr, weekday: weekday,
                                               hour: hour, minute: minute, referenceDate: endDate)
            else { continue }

            let typeStr = HTMLFetcher.allCaptures(
                pattern: #"mak-event-type">([^<]+)<"#, in: article).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Veranstaltung"

            let exhibitionTitle = HTMLFetcher.allCaptures(
                pattern: #"mak-event-subheading">([^<]+)<"#, in: article).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let descHTML = HTMLFetcher.allCaptures(
                pattern: #"mak-accordion-content[^>]*>([\s\S]*?)</div>"#, in: article).first
            let desc = descHTML.flatMap {
                let s = HTMLFetcher.htmlToStructuredText($0)
                return s.isEmpty ? nil : s
            }

            events.append(MuseumEvent(
                title: title,
                museum: museum,
                url: url,
                date: date,
                eventType: typeStr,
                description: desc,
                exhibitionTitle: exhibitionTitle,
                isCancelled: isCancelled
            ))
        }
        return events
    }

    // "28 Jun" + weekday → Date. Uses weekday to pick the correct year reliably.
    private func parseMAKEventDate(dayStr: String, weekday: String?, hour: Int, minute: Int, referenceDate: Date?) -> Date? {
        let monthMap: [String: Int] = [
            "Jan":1,"Feb":2,"Mär":3,"Apr":4,"Mai":5,"Jun":6,
            "Jul":7,"Aug":8,"Sep":9,"Okt":10,"Nov":11,"Dez":12
        ]
        // Calendar.weekday: Sunday=1 … Saturday=7
        let weekdayMap: [String: Int] = [
            "Montag":2,"Dienstag":3,"Mittwoch":4,"Donnerstag":5,
            "Freitag":6,"Samstag":7,"Sonntag":1
        ]
        let parts = dayStr.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
        guard parts.count == 2,
              let day = Int(parts[0]),
              let month = monthMap[String(parts[1].prefix(3))] else { return nil }

        let cal = Calendar.current
        let expectedWeekday = weekday.flatMap { weekdayMap[$0] }
        let baseYear = cal.component(.year, from: Date())

        for year in [baseYear, baseYear + 1] {
            guard let d = cal.date(from: DateComponents(
                year: year, month: month, day: day, hour: hour, minute: minute))
            else { continue }
            if let wd = expectedWeekday {
                if cal.component(.weekday, from: d) == wd { return d }
            } else if d >= cal.date(byAdding: .month, value: -6, to: Date())! {
                return d
            }
        }
        // Fallback: use exhibition end date year
        let refYear = referenceDate.map { cal.component(.year, from: $0) } ?? baseYear
        return cal.date(from: DateComponents(year: refYear, month: month, day: day, hour: hour, minute: minute))
    }
}

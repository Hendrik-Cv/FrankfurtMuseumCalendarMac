import Foundation

final class SchirnFetcher: WordPressExhibitionFetcher, @unchecked Sendable, EventFetcher {
    init() {
        super.init(
            museum: Museum.all.first { $0.id == "schirn" }!,
            apiBaseURL: URL(string: "https://www.schirn.de/wp-json/")!,
            postType: "exhibition"
        )
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let programURL = URL(string: "https://www.schirn.de/programm/")!
        let listingHTML = try await HTMLFetcher.fetchHTML(from: programURL)

        // Step 1: parse listing page for event refs
        struct EventRef {
            let url: URL
            let title: String
            let eventType: String
            let exhibitionTitle: String?
            let rawDateText: String
        }

        let items = HTMLFetcher.allCaptures(
            pattern: #"<li[^>]*wp-block-ho-lane-item[^>]*>([\s\S]*?)</li>"#, in: listingHTML)

        var refs: [EventRef] = []
        for item in items {
            guard let href = HTMLFetcher.allCaptures(
                    pattern: #"href="(https://www\.schirn\.de/[^"]+)""#, in: item).first,
                  let url = URL(string: href) else { continue }

            guard let dateText = HTMLFetcher.allCaptures(
                    pattern: #"event-display[^>]*>([^<]+)<"#, in: item).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !dateText.isEmpty else { continue }

            guard let title = HTMLFetcher.allCaptures(
                    pattern: #"ho-sd-teaser-headline-medium[^>]*>([^<]+)<"#, in: item).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }

            let metadata = HTMLFetcher.allCaptures(
                pattern: #"<p class="ho-sd-metadata[^"]*">([^<]+)</p>"#, in: item)
            let eventType = metadata.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Veranstaltung"
            let exhibitionTitle = metadata.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)

            refs.append(EventRef(url: url, title: title, eventType: eventType,
                                 exhibitionTitle: exhibitionTitle, rawDateText: dateText))
        }

        guard !refs.isEmpty else { return [] }

        // Step 2: fetch all detail pages concurrently
        var detailPages: [(EventRef, String)] = []
        await withTaskGroup(of: (EventRef, String)?.self) { group in
            for ref in refs {
                group.addTask { [url = ref.url] in
                    guard let html = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    return (ref, html)
                }
            }
            for await pair in group { if let pair { detailPages.append(pair) } }
        }

        // Step 3: extract events outside task closures
        var events: [MuseumEvent] = []
        for (ref, detailHTML) in detailPages {
            let extracted = extractSchirnEventDetails(from: detailHTML)
            // Use detail-page "Wann" date if available (has year), else fall back to listing
            let dates: [Date]
            if let wann = extracted.wann, let d = parseSchirnDetailDate(wann) {
                dates = [d]
            } else {
                dates = parseSchirnListingDates(ref.rawDateText)
            }
            for date in dates {
                events.append(MuseumEvent(
                    title: ref.title,
                    museum: museum,
                    url: ref.url,
                    date: date,
                    eventType: ref.eventType,
                    description: extracted.description,
                    exhibitionTitle: ref.exhibitionTitle,
                    location: extracted.location,
                    language: extracted.language,
                    notes: extracted.notes
                ))
            }
        }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        return events
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
    }

    // MARK: - Detail page parsing

    private struct EventDetails {
        var wann: String?
        var location: String?
        var language: String?
        var notes: String?
        var description: String?
    }

    private func extractSchirnEventDetails(from html: String) -> EventDetails {
        var result = EventDetails()

        // Parse ho-sd-body-small-list paragraphs: <strong>Label</strong> or <strong>Label<br></strong>
        let infoParas = HTMLFetcher.allCaptures(
            pattern: #"<p[^>]*ho-sd-body-small-list[^>]*>([\s\S]*?)</p>"#, in: html)
        for para in infoParas {
            let text = HTMLFetcher.stripHTML(para).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("Wann") {
                result.wann = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if text.hasPrefix("Ort") {
                result.location = String(text.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if text.hasPrefix("Sprache") {
                result.language = String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if text.hasPrefix("Hinweise") {
                result.notes = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Full description from ho-sd-body paragraphs (exclude short credits lines)
        let descParas = HTMLFetcher.allCaptures(
            pattern: #"<p[^>]*class=[\"']ho-sd-body[\"'][^>]*>([\s\S]*?)</p>"#, in: html)
            .map { HTMLFetcher.stripHTML($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 40 }
        if !descParas.isEmpty {
            result.description = descParas.joined(separator: "\n\n")
        }

        return result
    }

    // Parse "Dienstag, 30. Juni 2026, 19 Uhr" or "..., 18:30 Uhr" (has year → reliable)
    private func parseSchirnDetailDate(_ text: String) -> Date? {
        let monthMap: [String: Int] = [
            "Januar":1,"Februar":2,"März":3,"April":4,"Mai":5,"Juni":6,
            "Juli":7,"August":8,"September":9,"Oktober":10,"November":11,"Dezember":12
        ]
        let ns = text as NSString
        guard let r = try? NSRegularExpression(
            pattern: #"(\d{1,2})\. (\w+) (\d{4})(?:,\s*(\d{1,2})(?:[:.h](\d{2}))?\s*Uhr)?"#),
              let m = r.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 3 else { return nil }

        guard let day = Int(ns.substring(with: m.range(at: 1))),
              let month = monthMap[ns.substring(with: m.range(at: 2))],
              let year = Int(ns.substring(with: m.range(at: 3))) else { return nil }

        var hour = 0, minute = 0
        if m.range(at: 4).location != NSNotFound {
            hour = Int(ns.substring(with: m.range(at: 4))) ?? 0
        }
        if m.range(at: 5).location != NSNotFound {
            minute = Int(ns.substring(with: m.range(at: 5))) ?? 0
        }

        return Calendar.current.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))
    }

    // Fallback: parse listing date text for recurring events with multiple dates
    // e.g. "25. Juni, 23. Juli & 27. Aug.,18:30–21:30 Uhr"
    private func parseSchirnListingDates(_ text: String) -> [Date] {
        let cleaned = text
            .replacingOccurrences(of: "&#038;", with: "&")
            .replacingOccurrences(of: "&amp;", with: "&")

        let monthMap: [String: Int] = [
            "Jan":1,"Feb":2,"Mär":3,"Apr":4,"Mai":5,"Jun":6,
            "Jul":7,"Aug":8,"Sep":9,"Okt":10,"Nov":11,"Dez":12
        ]
        let cal = Calendar.current
        let now = Date()
        let ns = cleaned as NSString

        var hour = 0, minute = 0
        if let tr = try? NSRegularExpression(pattern: #"(\d{1,2})[.:](\d{2})\s*(?:[–\-][^U]*)?Uhr"#),
           let tm = tr.firstMatch(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            hour = Int(ns.substring(with: tm.range(at: 1))) ?? 0
            minute = Int(ns.substring(with: tm.range(at: 2))) ?? 0
        }

        guard let dr = try? NSRegularExpression(pattern: #"(\d{1,2})\. ([A-Za-zÄÖÜäöü]{3})"#) else { return [] }
        var dates: [Date] = []
        for m in dr.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges > 2,
                  let day = Int(ns.substring(with: m.range(at: 1))),
                  let month = monthMap[String(ns.substring(with: m.range(at: 2)).prefix(3))]
            else { continue }
            let year = cal.component(.year, from: now)
            var comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            if let d = cal.date(from: comps),
               d < cal.date(byAdding: .month, value: -1, to: now)! {
                comps.year = year + 1
            }
            if let finalDate = cal.date(from: comps) {
                dates.append(finalDate)
            }
        }
        return dates
    }
}

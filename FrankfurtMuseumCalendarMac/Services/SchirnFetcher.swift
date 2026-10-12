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
        // Step 1: parse listing pages for event refs.
        // Führungen have their own listing page with the same lane-item markup.
        let listingPages: [(url: URL, defaultEventType: String)] = [
            (URL(string: "https://www.schirn.de/programm/")!, "Veranstaltung"),
            (URL(string: "https://www.schirn.de/programm/events/")!, "Event"),
            (URL(string: "https://www.schirn.de/programm/fuehrungen/")!, "Führung"),
            (URL(string: "https://www.schirn.de/programm/kinder-familien/")!, "Kinder & Familien"),
        ]

        var refs: [EventRef] = []
        var seenURLs: Set<URL> = []
        for page in listingPages {
            guard let listingHTML = try? await HTMLFetcher.fetchHTML(from: page.url) else { continue }
            for ref in parseEventRefs(from: listingHTML, defaultEventType: page.defaultEventType) {
                // Same event can appear in several lanes / on several pages
                guard seenURLs.insert(ref.url).inserted else { continue }
                refs.append(ref)
            }
        }

        guard !refs.isEmpty else { return [] }

        // Step 2: fetch all detail pages concurrently; if a detail page links its
        // ticket-shop calendar, fetch the exact bookable dates from there as well.
        var detailPages: [(EventRef, String, [Date])] = []
        await withTaskGroup(of: (EventRef, String, [Date])?.self) { group in
            for ref in refs {
                group.addTask { [url = ref.url] in
                    guard let html = try? await HTMLFetcher.fetchHTML(from: url) else { return nil }
                    var ticketDates: [Date] = []
                    if let vorlageOid = HTMLFetcher.allCaptures(
                            pattern: #"ticketfritz\.de/Event/Kalender/(\d+)"#, in: html).first {
                        ticketDates = await self.fetchTicketfritzDates(vorlageOid: vorlageOid)
                    }
                    return (ref, html, ticketDates)
                }
            }
            for await triple in group { if let triple { detailPages.append(triple) } }
        }

        // Step 3: extract events outside task closures
        var events: [MuseumEvent] = []
        for (ref, detailHTML, ticketDates) in detailPages {
            let extracted = extractSchirnEventDetails(from: detailHTML)
            // Date source priority:
            // 1. Ticket-shop calendar (exact bookable occurrences incl. exceptions)
            // 2. Detail-page "Wann" with concrete dates (has year — keep all, otherwise
            //    events whose first date is past disappear entirely)
            // 3. Weekday rules like "Dienstags 17 Uhr" expanded over the next weeks
            // 4. Listing-page date text
            let dates: [Date]
            if !ticketDates.isEmpty {
                dates = ticketDates
            } else if let wann = extracted.wann {
                let concrete = parseSchirnDetailDates(wann)
                if !concrete.isEmpty {
                    dates = concrete
                } else {
                    let recurring = parseSchirnWeekdayRules(wann)
                    dates = recurring.isEmpty ? parseSchirnListingDates(ref.rawDateText) : recurring
                }
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

    // MARK: - Ticket-shop calendar (ticketfritz)

    // The Schirn ticket shop knows the exact bookable dates of recurring events
    // (incl. holiday exceptions). Returns occurrences within the next six months.
    private func fetchTicketfritzDates(vorlageOid: String) async -> [Date] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let now = Date()
        let end = Calendar.current.date(byAdding: .month, value: 6, to: now)!

        var comps = URLComponents(string: "https://schirn.ticketfritz.de/Event/getEvents")!
        comps.queryItems = [
            URLQueryItem(name: "ZeitpunktVon", value: df.string(from: now)),
            URLQueryItem(name: "ZeitpunktBis", value: df.string(from: end)),
            URLQueryItem(name: "Typ", value: "Vorlage"),
            URLQueryItem(name: "Wert", value: ""),
            URLQueryItem(name: "VorlageOid", value: vorlageOid),
            URLQueryItem(name: "AnzahlBesucher", value: "0"),
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return [] }

        var dates: [Date] = []
        for item in items {
            // "Zeitpunkt" is a .NET JSON date incl. time-of-day:
            // "/Date(1786276800000+0200)/" (ms since epoch, UTC). "Datum" lacks the time.
            guard let zeitpunkt = item["Zeitpunkt"] as? String,
                  let ms = HTMLFetcher.allCaptures(pattern: #"/Date\((\d+)"#, in: zeitpunkt).first
                      .flatMap(Double.init) else { continue }
            dates.append(Date(timeIntervalSince1970: ms / 1000))
        }
        return dates.sorted()
    }

    // MARK: - Listing page parsing

    private struct EventRef {
        let url: URL
        let title: String
        let eventType: String
        let exhibitionTitle: String?
        let rawDateText: String
    }

    private func parseEventRefs(from listingHTML: String, defaultEventType: String) -> [EventRef] {
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
            let eventType = metadata.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? defaultEventType
            let exhibitionTitle = metadata.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)

            refs.append(EventRef(url: url, title: title, eventType: eventType,
                                 exhibitionTitle: exhibitionTitle, rawDateText: dateText))
        }
        return refs
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
            if text.hasPrefix("Wann") || text.hasPrefix("When") {
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

    // Parse all occurrences like "Dienstag, 30. Juni 2026, 19 Uhr" or "..., 18:30 Uhr"
    // (has year → reliable). Recurring events list several dates in one "Wann" text.
    // English-language offers use "Thursday, August 20, 2026, 8 PM" instead.
    private func parseSchirnDetailDates(_ text: String) -> [Date] {
        let cal = Calendar.current
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var dates: [Date] = []

        let germanMonths: [String: Int] = [
            "Januar":1,"Februar":2,"März":3,"April":4,"Mai":5,"Juni":6,
            "Juli":7,"August":8,"September":9,"Oktober":10,"November":11,"Dezember":12
        ]
        if let r = try? NSRegularExpression(
            pattern: #"(\d{1,2})\. (\w+) (\d{4})(?:,\s*(\d{1,2})(?:[:.h](\d{2}))?\s*(?:[–\-]\d{1,2}(?:[:.h]\d{2})?\s*)?Uhr)?"#) {
            for m in r.matches(in: text, range: fullRange) {
                guard m.numberOfRanges > 3,
                      let day = Int(ns.substring(with: m.range(at: 1))),
                      let month = germanMonths[ns.substring(with: m.range(at: 2))],
                      let year = Int(ns.substring(with: m.range(at: 3))) else { continue }

                var hour = 0, minute = 0
                if m.range(at: 4).location != NSNotFound {
                    hour = Int(ns.substring(with: m.range(at: 4))) ?? 0
                }
                if m.range(at: 5).location != NSNotFound {
                    minute = Int(ns.substring(with: m.range(at: 5))) ?? 0
                }

                if let d = cal.date(from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute)) {
                    dates.append(d)
                }
            }
        }

        let englishMonths: [String: Int] = [
            "january":1,"february":2,"march":3,"april":4,"may":5,"june":6,
            "july":7,"august":8,"september":9,"october":10,"november":11,"december":12
        ]
        if let r = try? NSRegularExpression(
            pattern: #"(?i)(january|february|march|april|may|june|july|august|september|october|november|december)\s+(\d{1,2}),\s*(\d{4})(?:,\s*(\d{1,2})(?::(\d{2}))?\s*([AP]M))?"#) {
            for m in r.matches(in: text, range: fullRange) {
                guard let month = englishMonths[ns.substring(with: m.range(at: 1)).lowercased()],
                      let day = Int(ns.substring(with: m.range(at: 2))),
                      let year = Int(ns.substring(with: m.range(at: 3))) else { continue }

                var hour = 0, minute = 0
                if m.range(at: 4).location != NSNotFound {
                    hour = Int(ns.substring(with: m.range(at: 4))) ?? 0
                }
                if m.range(at: 5).location != NSNotFound {
                    minute = Int(ns.substring(with: m.range(at: 5))) ?? 0
                }
                if m.range(at: 6).location != NSNotFound {
                    let meridiem = ns.substring(with: m.range(at: 6)).uppercased()
                    if meridiem == "PM" && hour < 12 { hour += 12 }
                    if meridiem == "AM" && hour == 12 { hour = 0 }
                }

                if let d = cal.date(from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute)) {
                    dates.append(d)
                }
            }
        }

        return dates.sorted()
    }

    // Expand weekday rules like "Dienstags 17 Uhr, mittwochs 16 Uhr", "Sonntags, 11 Uhr"
    // or "Jeden Samstag, 14–18 Uhr" into concrete dates for the next four weeks —
    // weekly tours have no concrete dates on the site.
    private func parseSchirnWeekdayRules(_ text: String) -> [Date] {
        // Calendar weekday numbers: 1 = Sunday … 7 = Saturday
        let weekdayMap: [String: Int] = [
            "sonntag":1,"montag":2,"dienstag":3,"mittwoch":4,
            "donnerstag":5,"freitag":6,"samstag":7
        ]
        guard let r = try? NSRegularExpression(
            pattern: #"(?i)(sonntag|montag|dienstag|mittwoch|donnerstag|freitag|samstag)s?,?\s*(\d{1,2})(?:[:.](\d{2}))?(?:\s*[–\-]\s*\d{1,2}(?:[:.]\d{2})?)?\s*Uhr"#) else { return [] }

        let ns = text as NSString
        let cal = Calendar.current
        let now = Date()
        let horizon = cal.date(byAdding: .day, value: 28, to: now)!

        var dates: [Date] = []
        for m in r.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let weekday = weekdayMap[ns.substring(with: m.range(at: 1)).lowercased()],
                  let hour = Int(ns.substring(with: m.range(at: 2))) else { continue }
            var minute = 0
            if m.range(at: 3).location != NSNotFound {
                minute = Int(ns.substring(with: m.range(at: 3))) ?? 0
            }
            var cursor = cal.startOfDay(for: now)
            while let d = cal.nextDate(after: cursor,
                                       matching: DateComponents(hour: hour, minute: minute, weekday: weekday),
                                       matchingPolicy: .nextTime),
                  d <= horizon {
                dates.append(d)
                cursor = d
            }
        }
        return dates.sorted()
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

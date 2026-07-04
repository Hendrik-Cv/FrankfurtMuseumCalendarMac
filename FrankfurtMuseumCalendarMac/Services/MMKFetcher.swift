import Foundation

final class MMKFetcher: GenericMuseumFetcher, @unchecked Sendable, EventFetcher {
    init() { super.init(museum: Museum.all.first { $0.id == "mmk" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        guard let apiURL = URL(string: "https://cms.mmk.art/exhibitions") else {
            throw FetcherError.invalidURL
        }
        let data = try await HTMLFetcher.fetchData(from: apiURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetcherError.parsingFailed("MMK CMS JSON parsing failed")
        }
        let upcoming = json["items_upcoming"] as? [[String: Any]] ?? []
        guard !upcoming.isEmpty else { throw FetcherError.noExhibitionsFound }

        let museum = self.museum
        var exhibitions: [Exhibition] = []
        await withTaskGroup(of: Exhibition?.self) { group in
            for item in upcoming {
                group.addTask {
                    guard let titleDe = (item["title"] as? [String: Any])?["de"] as? String else { return nil }
                    let subtitleDe = (item["subtitle"] as? [String: Any])?["de"] as? String ?? ""
                    let startTS = (item["date"] as? [String: Any])?["timestamp"] as? Double ?? 0
                    let endTS   = (item["date_end"] as? [String: Any])?["timestamp"] as? Double ?? 0
                    guard startTS > 0, endTS > 0 else { return nil }
                    let path = item["path"] as? String ?? ""
                    let url = URL(string: "https://www.mmk.art\(path)") ?? museum.exhibitionsURL

                    let venueLabel: String? = {
                        guard let venues = item["related_venues"] as? [[String: Any]],
                              let name = venues.first?["name"] as? String else { return nil }
                        switch name.lowercased() {
                        case "zollamt": return "Zollamt"
                        case "tower":   return "Tower"
                        default:        return nil
                        }
                    }()
                    var title = subtitleDe.isEmpty ? titleDe : "\(titleDe) – \(subtitleDe)"
                    if let label = venueLabel { title += " (\(label))" }

                    let itemName = item["name"] as? String ?? ""
                    let desc = await Self.fetchDescription(itemName: itemName)

                    return Exhibition(title: title, museum: museum, url: url,
                                      startDate: Date(timeIntervalSince1970: startTS),
                                      endDate: Date(timeIntervalSince1970: endTS),
                                      description: desc)
                }
            }
            for await result in group { if let ex = result { exhibitions.append(ex) } }
        }
        // Restore original listing order
        let names = upcoming.compactMap { $0["name"] as? String }
        let byName = Dictionary(exhibitions.map { ($0.url.absoluteString, $0) }, uniquingKeysWith: { $1 })
        return names.compactMap { name in
            guard let path = upcoming.first(where: { $0["name"] as? String == name })?["path"] as? String,
                  let url = URL(string: "https://www.mmk.art\(path)") else { return nil }
            return byName[url.absoluteString]
        }
    }

    // MARK: - EventFetcher

    func fetchEvents() async throws -> [MuseumEvent] {
        let apiURL = URL(string: "https://cms.mmk.art/whats-on/")!
        let raw = try await HTMLFetcher.fetchHTML(from: apiURL)
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            throw FetcherError.parsingFailed("MMK whats-on JSON")
        }

        let cutoff = Calendar.current.date(byAdding: .hour, value: -2, to: Date())!
        let cal = Calendar.current

        // Step 1: parse listing
        struct EventRef {
            let name: String; let date: Date; let url: URL
            let title: String; let eventType: String; let venue: String?
        }
        var refs: [EventRef] = []
        var seen = Set<String>()
        for item in items {
            guard let ts = (item["date"] as? [String: Any]).flatMap({ $0["timestamp"] as? Int }),
                  let titleDE = (item["title"] as? [String: Any])?["de"] as? String else { continue }
            let timeStr = ((item["time"] as? [String: Any])?["de"] as? String) ?? ""
            let eventDate = combineDateTimestamp(ts, time: timeStr, calendar: cal)
            guard eventDate >= cutoff else { continue }
            let path = item["path"] as? String ?? ""
            let name = item["name"] as? String ?? ""
            let key = "\(ts)|\(path)"
            guard seen.insert(key).inserted, !name.isEmpty else { continue }
            let cats = (item["related_events_categories"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            let venue: String? = {
                guard let venues = item["related_venues"] as? [[String: Any]],
                      let venueName = venues.first?["name"] as? String else { return nil }
                switch venueName.lowercased() {
                case "tower":   return "MMK Tower, Taunusturm"
                case "zollamt": return "MMK Zollamt"
                default:        return nil
                }
            }()
            refs.append(EventRef(
                name: name,
                date: eventDate,
                url: URL(string: "https://www.mmk.art/de\(path)") ?? apiURL,
                title: titleDE,
                eventType: inferMMKEventType(from: cats, title: titleDE),
                venue: venue
            ))
        }

        // Step 2: fetch descriptions concurrently
        let museum = self.museum
        var events: [MuseumEvent] = []
        await withTaskGroup(of: MuseumEvent?.self) { group in
            for ref in refs {
                group.addTask {
                    let desc = await Self.fetchEventDescription(name: ref.name)
                    return MuseumEvent(
                        title: ref.title, museum: museum, url: ref.url,
                        date: ref.date, eventType: ref.eventType,
                        description: desc, location: ref.venue
                    )
                }
            }
            for await ev in group { if let ev { events.append(ev) } }
        }

        return events.sorted { $0.date < $1.date }
    }

    private static func fetchEventDescription(name: String) async -> String? {
        guard let url = URL(string: "https://cms.mmk.art/whats-on/items/\(name)/"),
              let data = try? await HTMLFetcher.fetchData(from: url),
              let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let textHTML = (detail["text"] as? [String: Any])?["de"] as? String,
              !textHTML.isEmpty else { return nil }

        // Boilerplate-Muster die gefiltert werden
        let boilerplate = [
            "booklets zu den", "audiobeschreibung", "kunstvermittlung",
            "@stadt-frankfurt", "telefonisch unter", "finden sie auf unserer website",
            "newsletter", "impressum", "abonnieren"
        ]
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]+?)</p>"#, in: textHTML)
        let filtered = paras.compactMap { p -> String? in
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 10 else { return nil }
            let lower = text.lowercased()
            guard !boilerplate.contains(where: { lower.contains($0) }) else { return nil }
            return text
        }
        return filtered.isEmpty ? nil : filtered.joined(separator: "\n\n")
    }

    private func combineDateTimestamp(_ ts: Int, time: String, calendar: Calendar) -> Date {
        let dateOnly = Date(timeIntervalSince1970: Double(ts))
        let parts = time.components(separatedBy: ":").prefix(2)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1].prefix(2)) else { return dateOnly }
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dateOnly) ?? dateOnly
    }

    private func inferMMKEventType(from categories: [String], title: String) -> String {
        let l = title.lowercased()
        if l.contains("gespräch") || l.contains("podium")                                     { return "Gespräch" }
        if l.contains("vortrag") || l.contains("lecture")                                     { return "Vortrag" }
        if l.contains("konzert")                                                               { return "Konzert" }
        if l.contains("eröffnung") || l.contains("opening")                                   { return "Eröffnung" }
        if categories.contains("workshop") || l.contains("workshop") || l.contains("atelier") { return "Workshop" }
        if categories.contains("tour") || l.contains("führung") || l.contains("tour")         { return "Führung" }
        return "Veranstaltung"
    }

    private static func fetchDescription(itemName: String) async -> String? {
        guard !itemName.isEmpty,
              let url = URL(string: "https://cms.mmk.art/whats-on/items/\(itemName)/"),
              let data = try? await HTMLFetcher.fetchData(from: url),
              let detail = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (detail["name"] as? String) != "http404",
              let textHTML = (detail["text"] as? [String: Any])?["de"] as? String,
              !textHTML.isEmpty else { return nil }
        let paras = HTMLFetcher.allCaptures(pattern: #"<p[^>]*>([\s\S]{40,}?)</p>"#, in: textHTML)
        return paras.compactMap { p -> String? in
            let text = HTMLFetcher.stripHTML(p).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count >= 40 ? text : nil
        }.first
    }
}

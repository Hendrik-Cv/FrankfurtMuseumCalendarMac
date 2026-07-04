import Foundation

final class MMKFetcher: GenericMuseumFetcher, @unchecked Sendable {
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
                        switch name {
                        case "ZOLLAMTMMK": return "Zollamt"
                        case "TOWERMMK":   return "Tower"
                        default:           return nil
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

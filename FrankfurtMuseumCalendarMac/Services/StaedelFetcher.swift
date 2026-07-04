import Foundation

final class StaedelFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "staedel" }!) }

    private static let nonExhibitionSlugs = [
        "ausstellungen", "besuch", "das-staedel", "engagement", "kontakt", "newsletter",
        "karriere", "impressum", "datenschutz", "sammlung", "digital", "programm",
        "bildung", "gruppen", "familien", "tickets", "endowment", "preferences",
        "grusskarte", "hausordnung", "bildnachweise", "hauptmenu", "search", "cancellation"
    ]

    override func fetchExhibitions() async throws -> [Exhibition] {
        let sitemapData = try await HTMLFetcher.fetchData(from: URL(string: "https://www.staedelmuseum.de/sitemap.xml")!)
        let xml = String(data: sitemapData, encoding: .utf8) ?? ""

        // Only single-segment /de/[slug] URLs — no subpaths
        let allLinks = HTMLFetcher.allCaptures(
            pattern: #"<loc>(https://www\.staedelmuseum\.de/de/[^/<]+)</loc>"#, in: xml)
        let exhibitionLinks = Array(Set(allLinks.filter { link in
            let slug = link.components(separatedBy: "/de/").last ?? ""
            return !Self.nonExhibitionSlugs.contains(where: { slug.hasPrefix($0) })
        }))

        let museum = self.museum
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        var exhibitions: [Exhibition] = []
        await withTaskGroup(of: [Exhibition].self) { group in
            for linkStr in exhibitionLinks {
                group.addTask {
                    guard let url = URL(string: linkStr),
                          let html = try? await HTMLFetcher.fetchHTML(from: url) else { return [] }
                    return await MainActor.run {
                        let jsonLD = HTMLFetcher.extractJSONLD(from: html)
                        var results = HTMLFetcher.exhibitionsFromJSONLD(jsonLD, museum: museum)
                            .filter { $0.endDate >= cutoff }
                        if !results.isEmpty {
                            var desc: String? = nil

                            // Strategy 1: stMainTabs__panel (pages with tab layout)
                            let panels = HTMLFetcher.allCaptures(
                                pattern: #"class="stMainTabs__panel"[^>]*>([\s\S]+?)(?=class="stMainTabs__panel"|</body>)"#,
                                in: html)
                            for panel in panels {
                                let paras = HTMLFetcher.allCaptures(
                                    pattern: #"<p[^>]*>([\s\S]{150,1200}?)</p>"#, in: panel)
                                for p in paras {
                                    let text = HTMLFetcher.stripHTML(p)
                                    if text.contains("Uhr") || text.contains("€") || text.contains("Ticket") { continue }
                                    if text.count > (desc?.count ?? 0) { desc = text }
                                }
                            }

                            // Strategy 2: stTypo block after "Über die Ausstellung" heading
                            if desc == nil {
                                let afterHeading = HTMLFetcher.allCaptures(
                                    pattern: #"Über die Ausstellung[\s\S]{0,300}?<div[^>]*stTypo[^>]*>([\s\S]{150,3000}?)</div>"#,
                                    in: html)
                                if let block = afterHeading.first {
                                    let paras = HTMLFetcher.allCaptures(
                                        pattern: #"<p[^>]*>([\s\S]{50,1200}?)</p>"#, in: block)
                                    desc = paras.first.map { HTMLFetcher.stripHTML($0) }
                                }
                            }

                            // Strategy 3: og:description fallback
                            if desc == nil {
                                desc = HTMLFetcher.extractMetaDescription(from: html)
                            }

                            results = results.map {
                                Exhibition(id: $0.id, title: $0.title, museum: $0.museum, url: $0.url,
                                           startDate: $0.startDate, endDate: $0.endDate, description: desc)
                            }
                        }
                        return results
                    }
                }
            }
            for await result in group { exhibitions.append(contentsOf: result) }
        }
        return exhibitions
    }
}

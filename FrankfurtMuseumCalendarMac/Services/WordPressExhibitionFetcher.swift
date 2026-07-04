import Foundation

class WordPressExhibitionFetcher: GenericMuseumFetcher, @unchecked Sendable {
    let apiBaseURL: URL
    let postType: String

    init(museum: Museum, apiBaseURL: URL, postType: String = "exhibition") {
        self.apiBaseURL = apiBaseURL
        self.postType = postType
        super.init(museum: museum)
    }

    override func fetchExhibitions() async throws -> [Exhibition] {
        var components = URLComponents(
            url: apiBaseURL.appendingPathComponent("wp/v2/\(postType)"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "_fields", value: "link")
        ]
        guard let apiURL = components.url else { throw FetcherError.invalidURL }

        let data = try await HTMLFetcher.fetchData(from: apiURL)
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FetcherError.parsingFailed("WP API JSON parsing failed")
        }
        let links = items.compactMap { $0["link"] as? String }
        guard !links.isEmpty else { throw FetcherError.noExhibitionsFound }

        let museum = self.museum
        var exhibitions: [Exhibition] = []
        await withTaskGroup(of: [Exhibition].self) { group in
            for link in links {
                group.addTask {
                    guard let url = URL(string: link),
                          let html = try? await HTMLFetcher.fetchHTML(from: url) else { return [] }
                    return await MainActor.run {
                        let jsonLD = HTMLFetcher.extractJSONLD(from: html)
                        var results = HTMLFetcher.exhibitionsFromJSONLD(jsonLD, museum: museum)
                        if results.contains(where: { $0.description == nil }),
                           let fallbackDesc = HTMLFetcher.extractMetaDescription(from: html) {
                            results = results.map { ex in
                                guard ex.description == nil else { return ex }
                                return Exhibition(id: ex.id, title: ex.title, museum: ex.museum, url: ex.url,
                                                  startDate: ex.startDate, endDate: ex.endDate,
                                                  description: fallbackDesc)
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

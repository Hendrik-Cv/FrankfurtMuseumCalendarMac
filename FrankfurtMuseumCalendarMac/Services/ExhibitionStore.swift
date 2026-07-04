import Foundation
import Observation

@Observable
final class ExhibitionStore {
    var exhibitions: [Exhibition] = []
    var isLoading = false
    var fetchErrors: [(museum: String, message: String)] = []
    var lastUpdated: Date?

    var selectedMuseumIDs: Set<String> = Set(Museum.all.map { $0.id })
    var showPast = false
    var sortByDate = true

    private let fetchers: [any MuseumFetcher]
    private let cacheURL: URL

    init() {
        self.fetchers = MuseumFetcherFactory.allFetchers()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.cacheURL = docs.appendingPathComponent("exhibitions_cache.json")
        loadFromCache()
    }

    // MARK: - Computed filtered/sorted list

    var filteredExhibitions: [Exhibition] {
        var list = exhibitions.filter { selectedMuseumIDs.contains($0.museum.id) }
        if !showPast {
            list = list.filter { $0.status != .past }
        }
        if sortByDate {
            list.sort { $0.startDate < $1.startDate }
        } else {
            list.sort { $0.museum.name < $1.museum.name }
        }
        return list
    }

    // MARK: - Refresh

    @MainActor
    func refresh() async {
        isLoading = true
        fetchErrors = []
        var newExhibitions: [Exhibition] = []

        await withTaskGroup(of: (museum: String, exhibitions: [Exhibition], error: String?).self) { group in
            for fetcher in fetchers {
                let museumName = fetcher.museum.name
                group.addTask {
                    do {
                        let exs = try await fetcher.fetchExhibitions()
                        return (museum: museumName, exhibitions: exs, error: nil)
                    } catch {
                        return (museum: museumName, exhibitions: [], error: error.localizedDescription)
                    }
                }
            }
            for await result in group {
                if let err = result.error {
                    fetchErrors.append((museum: result.museum, message: err))
                } else {
                    newExhibitions.append(contentsOf: result.exhibitions)
                }
            }
        }

        exhibitions = newExhibitions
        lastUpdated = Date()
        isLoading = false
        saveToCache(newExhibitions)
    }

    // MARK: - Persistence

    private func saveToCache(_ exhibitions: [Exhibition]) {
        guard let data = try? JSONEncoder().encode(exhibitions) else { return }
        try? data.write(to: cacheURL)
    }

    private func loadFromCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([Exhibition].self, from: data) else { return }
        exhibitions = cached
        lastUpdated = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap { $0.contentModificationDate }
    }
}

import Foundation

final class DAMFetcher: GenericMuseumFetcher, @unchecked Sendable {
    init() { super.init(museum: Museum.all.first { $0.id == "dam" }!) }

    override func fetchExhibitions() async throws -> [Exhibition] {
        let exhibitions = try await super.fetchExhibitions()
        var seen = Set<String>()
        let filtered = exhibitions.filter {
            $0.endDate.timeIntervalSince($0.startDate) >= 86400 &&
            seen.insert($0.url.absoluteString).inserted
        }
        return await enrichWithDescriptions(filtered)
    }
}

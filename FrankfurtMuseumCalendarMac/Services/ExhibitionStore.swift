import Foundation
import Observation

@Observable
final class ExhibitionStore {
    // MARK: - Loading state
    var isLoading = false
    var isEventsLoading = false
    var fetchErrors: [(museum: String, message: String)] = []
    var lastUpdated: Date?
    var eventsLastFetched: Date?
    var loadedMuseumCount: Int = 0
    var totalMuseumCount: Int = 0
    var loadedEventMuseumCount: Int = 0
    var totalEventMuseumCount: Int = 0

    // MARK: - Cached filtered outputs (private setters — updated by rebuildCache methods)
    private(set) var filteredExhibitions: [Exhibition] = []
    private(set) var filteredEvents: [MuseumEvent] = []
    private(set) var availableEventTypes: [String] = []
    private(set) var eventSeriesInfo: [MuseumEvent.ID: EventSeriesInfo] = [:]
    // Increments on every filter-settings change; used by the List to skip animations.
    private(set) var filterRevision: Int = 0

    // MARK: - Data (didSet triggers cache rebuild)
    var exhibitions: [Exhibition] = [] { didSet { rebuildExhibitionCache() } }
    var events: [MuseumEvent] = []    { didSet { rebuildEventCache() } }

    // MARK: - Filter settings (didSet increments filterRevision + rebuilds)
    var selectedMuseumIDs: Set<String> = Set(Museum.all.map { $0.id }) {
        didSet { filterRevision += 1; rebuildAllCaches() }
    }
    var showPast = false         { didSet { filterRevision += 1; rebuildExhibitionCache() } }
    var sortOrder: SortOrder = .endDate { didSet { filterRevision += 1; rebuildExhibitionCache() } }
    var showOnlyFavorites = false { didSet { filterRevision += 1; rebuildAllCaches() } }
    var favoriteIDs: Set<UUID> = [] { didSet { filterRevision += 1; rebuildAllCaches() } }
    var selectedEventType: String? = nil { didSet { filterRevision += 1; rebuildEventCache() } }
    var eventTimeRange: EventTimeRange = .all { didSet { filterRevision += 1; rebuildEventCache() } }

    // MARK: - Non-filter state
    var showEvents = true
    var selectedEventIDs: Set<MuseumEvent.ID> = []

    // MARK: - Enums
    enum SortOrder: String, CaseIterable, Equatable {
        case startDate = "Startdatum"
        case endDate   = "Schließt bald"
        case museum    = "Museum"
    }

    enum EventTimeRange: String, CaseIterable, Equatable {
        case all       = "Alle"
        case thisWeek  = "Diese Woche"
        case thisMonth = "Dieser Monat"
    }

    struct EventSeriesInfo {
        let siblingCount: Int
        let siblings: [MuseumEvent]
    }

    // MARK: - Cache rebuild

    private func rebuildExhibitionCache() {
        var list = exhibitions.filter { selectedMuseumIDs.contains($0.museum.id) }
        if !showPast { list = list.filter { $0.status != .past } }
        if showOnlyFavorites { list = list.filter { favoriteIDs.contains($0.id) } }
        switch sortOrder {
        case .startDate: list.sort { $0.startDate < $1.startDate }
        case .endDate:   list.sort { $0.endDate < $1.endDate }
        case .museum:    list.sort { $0.museum.name < $1.museum.name }
        }
        filteredExhibitions = list
    }

    private func rebuildEventCache() {
        let cal = Calendar.current
        let now = Date()
        var list = events.filter { selectedMuseumIDs.contains($0.museum.id) }
        switch eventTimeRange {
        case .all:
            list = list.filter { $0.date >= now }
        case .thisWeek:
            let end = cal.date(byAdding: .day, value: 7, to: now)!
            list = list.filter { $0.date >= now && $0.date <= end }
        case .thisMonth:
            let end = cal.date(byAdding: .month, value: 1, to: now)!
            list = list.filter { $0.date >= now && $0.date <= end }
        }
        if let type = selectedEventType { list = list.filter { $0.eventType == type } }
        if showOnlyFavorites { list = list.filter { favoriteIDs.contains($0.id) } }
        filteredEvents = list.sorted { $0.date < $1.date }

        // Available types (without selectedEventType filter so all chips stay visible)
        var allList = events.filter { selectedMuseumIDs.contains($0.museum.id) }
        switch eventTimeRange {
        case .all:      allList = allList.filter { $0.date >= now }
        case .thisWeek: let end = cal.date(byAdding: .day, value: 7, to: now)!
                        allList = allList.filter { $0.date >= now && $0.date <= end }
        case .thisMonth: let end = cal.date(byAdding: .month, value: 1, to: now)!
                         allList = allList.filter { $0.date >= now && $0.date <= end }
        }
        availableEventTypes = Array(Set(allList.map { $0.eventType })).sorted()

        // Series info
        var groups: [String: [MuseumEvent]] = [:]
        for event in filteredEvents {
            let key = "\(event.museum.id)|\(event.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            groups[key, default: []].append(event)
        }
        var result: [MuseumEvent.ID: EventSeriesInfo] = [:]
        for event in filteredEvents {
            let key = "\(event.museum.id)|\(event.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
            let sibs = (groups[key] ?? []).filter { $0.id != event.id }
            result[event.id] = EventSeriesInfo(siblingCount: sibs.count, siblings: sibs)
        }
        eventSeriesInfo = result
    }

    private func rebuildAllCaches() {
        rebuildExhibitionCache()
        rebuildEventCache()
    }

    // MARK: - Infrastructure
    private let fetchers: [any MuseumFetcher]
    private let eventFetchers: [any EventFetcher]
    private let cacheURL: URL
    private let eventsCacheURL: URL
    private static let eventsCacheDuration: TimeInterval = 60 * 60

    init() {
        self.fetchers = MuseumFetcherFactory.allFetchers()
        self.eventFetchers = MuseumFetcherFactory.allEventFetchers()
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.cacheURL = docs.appendingPathComponent("exhibitions_cache.json")
        self.eventsCacheURL = docs.appendingPathComponent("events_cache.json")
        let saved = UserDefaults.standard.array(forKey: "favoriteIDs") as? [String] ?? []
        self.favoriteIDs = Set(saved.compactMap { UUID(uuidString: $0) })
        loadFromCache()
        loadEventsFromCache()
        rebuildAllCaches()
    }

    func toggleFavorite(_ id: UUID) {
        if favoriteIDs.contains(id) { favoriteIDs.remove(id) } else { favoriteIDs.insert(id) }
        UserDefaults.standard.set(favoriteIDs.map { $0.uuidString }, forKey: "favoriteIDs")
    }

    // MARK: - Refresh exhibitions

    @MainActor
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        fetchErrors = []
        exhibitions = []
        loadedMuseumCount = 0
        totalMuseumCount = fetchers.count

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
                loadedMuseumCount += 1
                if let err = result.error {
                    if !fetchErrors.contains(where: { $0.museum == result.museum }) {
                        fetchErrors.append((museum: result.museum, message: err))
                    }
                } else {
                    exhibitions.append(contentsOf: result.exhibitions)
                }
            }
        }

        lastUpdated = Date()
        isLoading = false
        let snapshot = exhibitions
        let url = cacheURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - Refresh events

    @MainActor
    func refreshEvents(force: Bool = false) async {
        if !force,
           let last = eventsLastFetched,
           Date().timeIntervalSince(last) < Self.eventsCacheDuration,
           !events.isEmpty {
            return
        }
        guard !isEventsLoading else { return }
        isEventsLoading = true
        loadedEventMuseumCount = 0
        totalEventMuseumCount = eventFetchers.count
        var fetched: [MuseumEvent] = []
        await withTaskGroup(of: (museum: String, events: [MuseumEvent], error: String?).self) { group in
            for fetcher in eventFetchers {
                let museumName = fetcher.museum.name
                group.addTask {
                    do {
                        let evts = try await fetcher.fetchEvents()
                        return (museum: museumName, events: evts, error: nil)
                    } catch {
                        return (museum: museumName, events: [], error: error.localizedDescription)
                    }
                }
            }
            for await result in group {
                loadedEventMuseumCount += 1
                if let err = result.error {
                    if !fetchErrors.contains(where: { $0.museum == result.museum }) {
                        fetchErrors.append((museum: result.museum, message: err))
                    }
                } else {
                    fetched.append(contentsOf: result.events)
                }
            }
        }
        selectedEventIDs = []
        events = fetched.sorted { $0.date < $1.date }
        eventsLastFetched = Date()
        isEventsLoading = false
        let snapshot = events
        let url = eventsCacheURL
        Task.detached(priority: .background) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url)
        }
    }

    // MARK: - Persistence

    private func loadFromCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode([Exhibition].self, from: data) else { return }
        exhibitions = cached
        lastUpdated = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap { $0.contentModificationDate }
    }

    private func loadEventsFromCache() {
        guard let data = try? Data(contentsOf: eventsCacheURL),
              let cached = try? JSONDecoder().decode([MuseumEvent].self, from: data) else { return }
        events = cached.sorted { $0.date < $1.date }
        eventsLastFetched = (try? eventsCacheURL.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap { $0.contentModificationDate }
    }
}

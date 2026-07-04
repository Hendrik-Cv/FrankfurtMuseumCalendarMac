import Foundation

enum MuseumFetcherFactory {
    static func allFetchers() -> [any MuseumFetcher] {
        [
            StaedelFetcher(), MMKFetcher(), MAKFetcher(), SchirnFetcher(),
            LiebieghausFetcher(), DAMFetcher(), FilmmuseumFetcher(),
            WeltkulturenFetcher(), HistorischesMuseumFetcher(),
            GierschFetcher(), PortikusFetcher(), KunstvereinFetcher(),
        ]
    }
}

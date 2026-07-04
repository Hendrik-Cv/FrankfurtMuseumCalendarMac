import Foundation

enum MuseumFetcherFactory {
    static func allFetchers() -> [any MuseumFetcher] {
        [
            StaedelFetcher(), MMKFetcher(), MAKFetcher(), SchirnFetcher(),
            LiebieghausFetcher(), DAMFetcher(), FilmmuseumFetcher(),
            WeltkulturenFetcher(), HistorischesMuseumFetcher(),
            GierschFetcher(), PortikusFetcher(), KunstvereinFetcher(),
            CaricaturaFetcher(), SenckenbergFetcher(), MfKFetcher(),
        ]
    }

    static func allEventFetchers() -> [any EventFetcher] {
        [MAKFetcher(), SchirnFetcher(), KunstvereinFetcher(), LiebieghausFetcher(), DAMFetcher(), HistorischesMuseumFetcher(), StaedelFetcher(), WeltkulturenFetcher(), MMKFetcher(), GierschFetcher(), CaricaturaFetcher(), PortikusFetcher(), MfKFetcher(), SenckenbergFetcher()]
    }
}

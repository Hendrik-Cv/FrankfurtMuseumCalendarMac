import Foundation

enum MuseumCategory: String, CaseIterable, Codable, Sendable {
    case art     = "Bildende Kunst"
    case design  = "Design & Architektur"
    case history = "Geschichte & Kulturen"
    case film    = "Film & Medien"
}

struct Museum: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let exhibitionsURL: URL
    let websiteURL: URL
    let colorHex: String
    let category: MuseumCategory

    static func == (lhs: Museum, rhs: Museum) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Museum {
    static let all: [Museum] = [
        Museum(
            id: "staedel",
            name: "Städel Museum",
            shortName: "Städel",
            exhibitionsURL: URL(string: "https://www.staedelmuseum.de/de/ausstellungen")!,
            websiteURL: URL(string: "https://www.staedelmuseum.de")!,
            colorHex: "#C41E3A",
            category: .art
        ),
        Museum(
            id: "mmk",
            name: "Museum für Moderne Kunst",
            shortName: "MMK",
            exhibitionsURL: URL(string: "http://www.mmk.art/ausstellungen/")!,
            websiteURL: URL(string: "http://www.mmk.art")!,
            colorHex: "#1A1A2E",
            category: .art
        ),
        Museum(
            id: "schirn",
            name: "Schirn Kunsthalle Frankfurt",
            shortName: "Schirn",
            exhibitionsURL: URL(string: "https://www.schirn.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.schirn.de")!,
            colorHex: "#E63946",
            category: .art
        ),
        Museum(
            id: "liebieghaus",
            name: "Liebieghaus Skulpturensammlung",
            shortName: "Liebieghaus",
            exhibitionsURL: URL(string: "https://www.liebieghaus.de/de/ausstellungen")!,
            websiteURL: URL(string: "https://www.liebieghaus.de")!,
            colorHex: "#8B6914",
            category: .art
        ),
        Museum(
            id: "giersch",
            name: "Museum Giersch der Goethe-Universität",
            shortName: "Giersch",
            exhibitionsURL: URL(string: "https://www.mggu.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.mggu.de")!,
            colorHex: "#5C8A62",
            category: .art
        ),
        Museum(
            id: "portikus",
            name: "Portikus",
            shortName: "Portikus",
            exhibitionsURL: URL(string: "https://www.portikus.de/de/exhibitions/")!,
            websiteURL: URL(string: "https://www.portikus.de")!,
            colorHex: "#2B2D42",
            category: .art
        ),
        Museum(
            id: "mak",
            name: "Museum Angewandte Kunst",
            shortName: "MAK",
            exhibitionsURL: URL(string: "https://www.museumangewandtekunst.de/de/besuch/ausstellungen/")!,
            websiteURL: URL(string: "https://www.museumangewandtekunst.de")!,
            colorHex: "#2C6E35",
            category: .design
        ),
        Museum(
            id: "dam",
            name: "Deutsches Architekturmuseum",
            shortName: "DAM",
            exhibitionsURL: URL(string: "https://dam-online.de/ausstellungen/")!,
            websiteURL: URL(string: "https://dam-online.de")!,
            colorHex: "#457B9D",
            category: .design
        ),
        Museum(
            id: "historisches",
            name: "Historisches Museum Frankfurt",
            shortName: "Hist. Museum",
            exhibitionsURL: URL(string: "https://historisches-museum-frankfurt.de/de/sonderausstellungen/")!,
            websiteURL: URL(string: "https://historisches-museum-frankfurt.de")!,
            colorHex: "#4A4E69",
            category: .history
        ),
        Museum(
            id: "weltkulturen",
            name: "Museum der Weltkulturen",
            shortName: "Weltkulturen",
            exhibitionsURL: URL(string: "https://www.weltkulturenmuseum.de/de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.weltkulturenmuseum.de")!,
            colorHex: "#E76F51",
            category: .history
        ),
        Museum(
            id: "filmmuseum",
            name: "Deutsches Filmmuseum",
            shortName: "Filmmuseum",
            exhibitionsURL: URL(string: "https://www.dff.film/ausstellungen/")!,
            websiteURL: URL(string: "https://www.dff.film")!,
            colorHex: "#6B35A8",
            category: .film
        ),
    ]
}

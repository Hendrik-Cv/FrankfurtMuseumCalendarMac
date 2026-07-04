import Foundation

enum MuseumCategory: String, CaseIterable, Codable, Sendable {
    case art           = "Bildende Kunst"
    case design        = "Design & Architektur"
    case history       = "Geschichte & Kulturen"
    case film          = "Film & Medien"
    case nature        = "Naturkunde & Wissenschaft"
    case communication = "Kommunikation"
}

struct Museum: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let shortName: String
    let address: String
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
            address: "Schaumainkai 63, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.staedelmuseum.de/de/ausstellungen")!,
            websiteURL: URL(string: "https://www.staedelmuseum.de")!,
            colorHex: "#C41E3A",
            category: .art
        ),
        Museum(
            id: "mmk",
            name: "Museum für Moderne Kunst",
            shortName: "MMK",
            address: "Domstraße 10, 60311 Frankfurt am Main",
            exhibitionsURL: URL(string: "http://www.mmk.art/ausstellungen/")!,
            websiteURL: URL(string: "http://www.mmk.art")!,
            colorHex: "#1A1A2E",
            category: .art
        ),
        Museum(
            id: "schirn",
            name: "Schirn Kunsthalle Frankfurt",
            shortName: "Schirn",
            address: "Römerberg 6, 60311 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.schirn.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.schirn.de")!,
            colorHex: "#E63946",
            category: .art
        ),
        Museum(
            id: "liebieghaus",
            name: "Liebieghaus Skulpturensammlung",
            shortName: "Liebieghaus",
            address: "Schaumainkai 71, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.liebieghaus.de/de/ausstellungen")!,
            websiteURL: URL(string: "https://www.liebieghaus.de")!,
            colorHex: "#8B6914",
            category: .art
        ),
        Museum(
            id: "giersch",
            name: "Museum Giersch der Goethe-Universität",
            shortName: "Giersch",
            address: "Schaumainkai 83, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.mggu.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.mggu.de")!,
            colorHex: "#5C8A62",
            category: .art
        ),
        Museum(
            id: "portikus",
            name: "Portikus",
            shortName: "Portikus",
            address: "Alte Brücke 2, 60594 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.portikus.de/de/exhibitions/")!,
            websiteURL: URL(string: "https://www.portikus.de")!,
            colorHex: "#2B2D42",
            category: .art
        ),
        Museum(
            id: "mak",
            name: "Museum Angewandte Kunst",
            shortName: "MAK",
            address: "Schaumainkai 17, 60594 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.museumangewandtekunst.de/de/besuch/ausstellungen/")!,
            websiteURL: URL(string: "https://www.museumangewandtekunst.de")!,
            colorHex: "#2C6E35",
            category: .design
        ),
        Museum(
            id: "dam",
            name: "Deutsches Architekturmuseum",
            shortName: "DAM",
            address: "Schaumainkai 43, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://dam-online.de/ausstellungen/")!,
            websiteURL: URL(string: "https://dam-online.de")!,
            colorHex: "#457B9D",
            category: .design
        ),
        Museum(
            id: "historisches",
            name: "Historisches Museum Frankfurt",
            shortName: "Hist. Museum",
            address: "Saalgasse 19, 60311 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://historisches-museum-frankfurt.de/de/sonderausstellungen/")!,
            websiteURL: URL(string: "https://historisches-museum-frankfurt.de")!,
            colorHex: "#4A4E69",
            category: .history
        ),
        Museum(
            id: "weltkulturen",
            name: "Museum der Weltkulturen",
            shortName: "Weltkulturen",
            address: "Schaumainkai 29, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.weltkulturenmuseum.de/de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.weltkulturenmuseum.de")!,
            colorHex: "#E76F51",
            category: .history
        ),
        Museum(
            id: "filmmuseum",
            name: "Deutsches Filmmuseum",
            shortName: "Filmmuseum",
            address: "Schaumainkai 41, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.dff.film/ausstellungen/")!,
            websiteURL: URL(string: "https://www.dff.film")!,
            colorHex: "#6B35A8",
            category: .film
        ),
        Museum(
            id: "kunstverein",
            name: "Frankfurter Kunstverein",
            shortName: "Kunstverein",
            address: "Markt 44, 60311 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.fkv.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.fkv.de")!,
            colorHex: "#1B998B",
            category: .art
        ),
        Museum(
            id: "caricatura",
            name: "Caricatura – Museum für Komische Kunst",
            shortName: "Caricatura",
            address: "Weckmarkt 17, 60311 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.caricatura-museum.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.caricatura-museum.de")!,
            colorHex: "#D4820A",
            category: .art
        ),
        Museum(
            id: "senckenberg",
            name: "Senckenberg Naturmuseum Frankfurt",
            shortName: "Senckenberg",
            address: "Senckenberganlage 25, 60325 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://museumfrankfurt.senckenberg.de/de/ausstellungen/sonderausstellungen/")!,
            websiteURL: URL(string: "https://museumfrankfurt.senckenberg.de")!,
            colorHex: "#3D7A4E",
            category: .nature
        ),
        Museum(
            id: "mfk",
            name: "Museum für Kommunikation Frankfurt",
            shortName: "MfK",
            address: "Schaumainkai 53, 60596 Frankfurt am Main",
            exhibitionsURL: URL(string: "https://www.mfk-frankfurt.de/ausstellungen/")!,
            websiteURL: URL(string: "https://www.mfk-frankfurt.de")!,
            colorHex: "#1E6B9A",
            category: .communication
        ),
    ]
}

# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

## [1.0] – 2026-10-16

### Fixed
- **Portikus-Fetcher repariert**: portikus.de hat im Oktober 2026 ein komplettes Redesign bekommen (neue Klassen für Listing, Detailseiten und Startseite). Der alte Scraper lieferte dadurch weder Ausstellungen noch Events. Listing- und Detailseiten-Parsing wurden an die neue Markup-Struktur angepasst und live gegen die echte Website verifiziert.
- **„Weitere Termine" bei wiederkehrenden Events**: Die Liste der anderen Termine eines wiederkehrenden Events wurde fälschlich aus der zeitraum-gefilterten Liste berechnet. Dadurch verschwanden Folgetermine komplett, sobald der Filter „Heute" (oder „Diese Woche"/„Dieser Monat") aktiv war. Wird jetzt unabhängig vom aktiven Zeitfilter aus allen zukünftigen Events berechnet.

### Added
- **„Heute"-Filter** für Veranstaltungen (`EventTimeRange.today`), inkl. automatischem Neuaufbau um Mitternacht bzw. nach dem Aufwachen aus dem Ruhezustand.
- **Schirn-Fetcher erweitert**: zusätzliche Listing-Seiten (Events, Führungen, Kinder & Familien), exakte wiederkehrende Termine über den ticketfritz.de-Buchungskalender, Fallback auf Wochentag-Regeln und englischsprachige Datumsangaben.

### Changed
- **Swift 6 Language Mode** aktiviert (`SWIFT_VERSION = 6`) – Vorbereitung auf macOS 27. Dafür wurden reine Parsing-Hilfsfunktionen (`HTMLFetcher` u. a.) als `nonisolated` markiert und ein echtes Datenrennen im `MMKFetcher` behoben (nicht-`Sendable` JSON-Dictionary wurde direkt in einer `TaskGroup`-Closure erfasst).
- Xcode-Projektwarnungen bereinigt (Info.plist-Zielmitgliedschaft, empfohlene Build-Einstellungen).

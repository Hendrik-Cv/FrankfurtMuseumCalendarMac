import SwiftUI

extension Notification.Name {
    static let showWelcome = Notification.Name("showWelcome")
}

@main
struct FrankfurtMuseumCalendarMacApp: App {
    @State private var store = ExhibitionStore()
    @State private var exporter = ICalExporter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(exporter)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Aktualisieren") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Einführung anzeigen") {
                    NotificationCenter.default.post(name: .showWelcome, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}

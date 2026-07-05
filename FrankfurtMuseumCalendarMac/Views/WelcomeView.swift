import SwiftUI

struct WelcomeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .padding(.top, 36)

                Text("Frankfurter Museumskalender")
                    .font(.title.bold())

                Text("Alle Ausstellungen und Veranstaltungen\nFrankfurter Museen auf einen Blick.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 32)

            // Feature rows
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(
                    icon: "photo.stack",
                    color: .blue,
                    title: "Ausstellungen",
                    description: "Laufende und kommende Ausstellungen aus über einem Dutzend Frankfurter Häusern, täglich aktuell."
                )
                FeatureRow(
                    icon: "calendar.badge.clock",
                    color: .orange,
                    title: "Veranstaltungen",
                    description: "Führungen, Vorträge, Eröffnungen, Workshops und mehr – gefiltert nach Typ und Zeitraum."
                )
                FeatureRow(
                    icon: "sidebar.left",
                    color: .purple,
                    title: "Museen filtern",
                    description: "In der linken Spalte Museen einzeln oder nach Kategorie an- und abwählen."
                )
                FeatureRow(
                    icon: "calendar.badge.plus",
                    color: .green,
                    title: "Kalender-Export",
                    description: "Ausstellungen und Veranstaltungen direkt in den Kalender übernehmen oder als .ics-Datei exportieren."
                )
                FeatureRow(
                    icon: "magnifyingglass",
                    color: .gray,
                    title: "Suche & Aktualisierung",
                    description: "Suchfeld oben rechts zum Filtern. ⌘R lädt alle Daten neu."
                )
            }
            .padding(.horizontal, 36)

            Spacer()

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Loslegen") {
                    hasSeenWelcome = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding()
            }
        }
        .frame(width: 500, height: 580)
    }
}

private struct FeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    WelcomeView()
}

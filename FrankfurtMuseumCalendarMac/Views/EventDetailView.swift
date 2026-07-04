import SwiftUI
import EventKit

struct EventDetailView: View {
    let event: MuseumEvent
    var siblings: [MuseumEvent] = []
    @Environment(ICalExporter.self) private var exporter
    @Environment(ExhibitionStore.self) private var store
    @State private var showCalendarPicker = false
    @State private var exportMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(event.museum.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(adaptiveHex: event.museum.colorHex) ?? .accentColor)
                        Spacer()
                        if event.isCancelled {
                            EventDetailBadge(label: "Abgesagt", color: .red)
                        }
                        EventDetailBadge(label: event.eventType, color: event.badgeColor)
                        Button {
                            store.toggleFavorite(event.id)
                        } label: {
                            Image(systemName: store.favoriteIDs.contains(event.id) ? "star.fill" : "star")
                                .foregroundStyle(store.favoriteIDs.contains(event.id) ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Text(event.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(event.isCancelled ? .secondary : .primary)
                        .strikethrough(event.isCancelled)
                }
                .padding(.horizontal)

                Divider()

                // Date / time
                EventLabeledRow(icon: "calendar", label: "Datum") {
                    Text(event.formattedDateTime)
                        .font(.body)
                }

                // Alternative dates in the same series
                if !siblings.isEmpty {
                    EventLabeledRow(icon: "calendar.badge.clock", label: "Weitere Termine") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(siblings, id: \.id) { alt in
                                Text(alt.formattedDateTime)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Exhibition context
                if let ex = event.exhibitionTitle {
                    EventLabeledRow(icon: "arrow.right", label: "Ausstellung") {
                        Text(ex).font(.body)
                    }
                }

                // Location: specific venue if known, otherwise museum address
                EventLabeledRow(icon: "mappin.and.ellipse", label: "Ort") {
                    Text(event.location ?? event.museum.address)
                        .font(.body)
                }

                // Language
                if let lang = event.language {
                    EventLabeledRow(icon: "globe", label: "Sprache") {
                        Text(lang).font(.body)
                    }
                }

                // Website
                EventLabeledRow(icon: "link", label: "Website") {
                    Link(event.url.host ?? event.url.absoluteString,
                         destination: event.url)
                        .font(.body)
                        .lineLimit(1)
                }

                // Description
                if let desc = event.description, !desc.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Beschreibung", systemImage: "text.alignleft")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(desc)
                            .font(.body)
                    }
                    .padding(.horizontal)
                }

                // Notes / Hinweise
                if let notes = event.notes, !notes.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Hinweise", systemImage: "info.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(notes)
                            .font(.body)
                    }
                    .padding(.horizontal)
                }

                Divider()

                // Actions
                VStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(event.url)
                    } label: {
                        Label("Im Browser öffnen", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if exporter.hasAccess {
                        Button { showCalendarPicker = true } label: {
                            Label("Zum Kalender hinzufügen", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else if exporter.isDenied {
                        Button {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        } label: {
                            Label("Kalender in Einstellungen freigeben", systemImage: "calendar.badge.exclamationmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button { Task { await exporter.requestAccess() } } label: {
                            Label("Kalenderzugriff erlauben", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    ShareLink(
                        item: exporter.generateEventICS([event]),
                        preview: SharePreview(event.title, icon: Image(systemName: "calendar"))
                    ) {
                        Label("Als .ics exportieren", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                if let msg = exportMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
            .padding(.vertical)
        }
        .navigationTitle(event.museum.shortName)
        .sheet(isPresented: $showCalendarPicker) {
            EventCalendarPickerSheet(event: event, exporter: exporter) { msg in exportMessage = msg }
        }
    }

}

private struct EventCalendarPickerSheet: View {
    let event: MuseumEvent
    let exporter: ICalExporter
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String = ""

    private var selectedCalendar: EKCalendar? {
        exporter.availableCalendars.first { $0.calendarIdentifier == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Kalender wählen")
                .font(.headline)
                .padding()
            Divider()
            Form {
                Picker("Kalender", selection: $selectedID) {
                    ForEach(exporter.availableCalendars, id: \.calendarIdentifier) { cal in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color(cgColor: cal.cgColor))
                                .frame(width: 10, height: 10)
                            Text(cal.title)
                        }
                        .tag(cal.calendarIdentifier)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Hinzufügen") {
                    guard let cal = selectedCalendar ?? exporter.selectedCalendar else { return }
                    do {
                        try exporter.addEventToCalendar(event, calendar: cal)
                        onDone("Veranstaltung zum Kalender hinzugefügt.")
                    } catch {
                        onDone("Fehler: \(error.localizedDescription)")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCalendar == nil && exporter.selectedCalendar == nil)
            }
            .padding()
        }
        .frame(width: 320, height: 360)
        .onAppear {
            selectedID = exporter.selectedCalendar?.calendarIdentifier
                ?? exporter.availableCalendars.first?.calendarIdentifier ?? ""
        }
    }
}

private struct EventLabeledRow<Content: View>: View {
    let icon: String
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Label(label, systemImage: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            content()
            Spacer()
        }
        .padding(.horizontal)
    }
}

private struct EventDetailBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

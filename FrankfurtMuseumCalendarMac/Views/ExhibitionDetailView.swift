import SwiftUI
import EventKit

struct ExhibitionDetailView: View {
    let exhibition: Exhibition
    @State private var showCalendarPicker = false
    @State private var exporterMessage: String?
    @Environment(ICalExporter.self) private var exporter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(exhibition.museum.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(hex: exhibition.museum.colorHex) ?? .accentColor)
                        Spacer()
                        StatusChip(status: exhibition.status)
                    }
                    Text(exhibition.title)
                        .font(.title2)
                        .fontWeight(.bold)
                }
                .padding(.horizontal)

                Divider()

                // Dates
                LabeledRow(icon: "calendar", label: "Laufzeit") {
                    Text(exhibition.formattedDateRange)
                        .font(.body)
                }

                // URL / Website
                LabeledRow(icon: "link", label: "Website") {
                    Link(exhibition.url.host ?? exhibition.url.absoluteString,
                         destination: exhibition.url)
                        .font(.body)
                        .lineLimit(1)
                }

                // Description
                if let desc = exhibition.description, !desc.isEmpty {
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

                Divider()

                // Actions
                VStack(spacing: 10) {
                    Button {
                        NSWorkspace.shared.open(exhibition.url)
                    } label: {
                        Label("Im Browser öffnen", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    if exporter.hasAccess {
                        Button {
                            showCalendarPicker = true
                        } label: {
                            Label("Zum Kalender hinzufügen", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await exporter.requestAccess() }
                        } label: {
                            Label("Kalenderzugriff erlauben", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    ShareLink(
                        item: exporter.generateICS([exhibition]),
                        preview: SharePreview(exhibition.title, icon: Image(systemName: "calendar"))
                    ) {
                        Label("Als .ics exportieren", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                if let msg = exporterMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal)
                }

                Spacer(minLength: 20)
            }
            .padding(.vertical)
        }
        .navigationTitle(exhibition.museum.shortName)
        .sheet(isPresented: $showCalendarPicker) {
            CalendarPickerSheet(exhibition: exhibition) { msg in
                exporterMessage = msg
            }
            .environment(exporter)
        }
    }
}

// MARK: - Supporting Views

private struct LabeledRow<Content: View>: View {
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

private struct StatusChip: View {
    let status: Exhibition.Status

    var body: some View {
        Text(status.label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .ongoing:  return .green
        case .upcoming: return .blue
        case .past:     return .gray
        }
    }
}

private struct CalendarPickerSheet: View {
    let exhibition: Exhibition
    let onDone: (String) -> Void
    @Environment(ICalExporter.self) private var exporter
    @Environment(\.dismiss) private var dismiss
    @State private var selected: EKCalendar?

    var body: some View {
        VStack(spacing: 0) {
            Text("Kalender wählen")
                .font(.headline)
                .padding()

            Divider()

            List(exporter.availableCalendars, id: \.calendarIdentifier) { cal in
                HStack {
                    Circle()
                        .fill(Color(cgColor: cal.cgColor))
                        .frame(width: 12, height: 12)
                    Text(cal.title)
                    Spacer()
                    if selected?.calendarIdentifier == cal.calendarIdentifier {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = cal }
            }

            Divider()

            HStack {
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Hinzufügen") {
                    guard let cal = selected ?? exporter.selectedCalendar else { return }
                    do {
                        try exporter.addToCalendar(exhibition, calendar: cal)
                        onDone("Ausstellung wurde zum Kalender hinzugefügt.")
                    } catch {
                        onDone("Fehler: \(error.localizedDescription)")
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil && exporter.selectedCalendar == nil)
            }
            .padding()
        }
        .frame(width: 320, height: 400)
        .onAppear { selected = exporter.selectedCalendar }
    }
}

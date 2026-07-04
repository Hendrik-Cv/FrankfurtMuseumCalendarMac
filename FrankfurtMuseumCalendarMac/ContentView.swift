import SwiftUI
import EventKit

struct ContentView: View {
    @Environment(ExhibitionStore.self) private var store
    @Environment(ICalExporter.self) private var exporter
    @State private var searchText = ""
    @State private var listSelection: ListSelection?
    @State private var showBulkExport = false
    @State private var showEventExport = false
    @State private var showErrorSheet = false

    private enum ListSelection: Hashable {
        case exhibition(Exhibition.ID)
        case event(MuseumEvent.ID)
    }

    private var selectedExhibition: Exhibition? {
        guard case .exhibition(let id) = listSelection else { return nil }
        return store.exhibitions.first { $0.id == id }
    }

    private var selectedEventGroup: EventGroup? {
        guard case .event(let id) = listSelection else { return nil }
        return store.groupedFilteredEvents.first { $0.id == id }
    }

    var searchResults: [Exhibition] {
        let base = store.filteredExhibitions
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.museum.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // P6: search extended to events
    var filteredEventGroups: [EventGroup] {
        let groups = store.groupedFilteredEvents
        guard !searchText.isEmpty else { return groups }
        return groups.filter {
            $0.primary.title.localizedCaseInsensitiveContains(searchText) ||
            $0.primary.museum.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .environment(store)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } content: {
            exhibitionList
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let group = selectedEventGroup {
                EventDetailView(group: group)
                    .environment(exporter)
                    .id(group.id)
            } else if let exhibition = selectedExhibition {
                ExhibitionDetailView(exhibition: exhibition)
                    .environment(exporter)
                    .id(exhibition.id)
            } else {
                ContentUnavailableView(
                    "Keine Auswahl",
                    systemImage: "building.columns",
                    description: Text("Wähle eine Ausstellung oder Veranstaltung aus der Liste.")
                )
            }
        }
        .searchable(text: $searchText, prompt: "Ausstellung, Veranstaltung oder Museum suchen")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showBulkExport) {
            BulkExportSheet()
                .environment(exporter)
                .environment(store)
        }
        .sheet(isPresented: $showEventExport) {
            EventExportSheet()
                .environment(exporter)
                .environment(store)
        }
        .sheet(isPresented: $showErrorSheet) {
            ErrorSheet()
                .environment(store)
        }
        .task { await store.refresh() }
    }

    // MARK: - Exhibition/Event List

    private var exhibitionList: some View {
        VStack(spacing: 0) {
            // P2 + P4: event filter bar
            if store.showEvents && !store.events.isEmpty {
                EventFilterBar()
                    .environment(store)
                Divider()
            }

            Group {
                if store.isLoading && store.exhibitions.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Ausstellungen werden geladen…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty && filteredEventGroups.isEmpty {
                    ContentUnavailableView(
                        "Keine Einträge",
                        systemImage: "building.columns",
                        description: Text(store.exhibitions.isEmpty
                            ? "Drücke ⌘R um Daten zu laden."
                            : "Keine Treffer für die gewählten Filter.")
                    )
                } else {
                    List(selection: $listSelection) {
                        if store.isLoading {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("Wird aktualisiert…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .listRowSeparator(.hidden)
                        }

                        if store.showEvents {
                            Section("Veranstaltungen") {
                                // P8: Kino-Link für Filmmuseum
                                if store.selectedMuseumIDs.contains("filmmuseum") {
                                    KinoLinkRow()
                                }
                                ForEach(filteredEventGroups) { group in
                                    EventRowView(
                                        group: group,
                                        isSelected: store.selectedEventIDs.contains(group.id),
                                        onToggle: {
                                            if store.selectedEventIDs.contains(group.id) {
                                                store.selectedEventIDs.remove(group.id)
                                            } else {
                                                store.selectedEventIDs.insert(group.id)
                                            }
                                        },
                                        isFavorite: store.favoriteIDs.contains(group.id),
                                        onToggleFavorite: { store.toggleFavorite(group.id) }
                                    )
                                    .tag(ListSelection.event(group.id))
                                }
                            }
                        }

                        if store.sortOrder == .endDate {
                            let ongoing  = searchResults.filter { $0.status == .ongoing }
                            let upcoming = searchResults.filter { $0.status == .upcoming }
                            if !ongoing.isEmpty {
                                Section("Schließt bald") {
                                    ForEach(ongoing) { ex in
                                        ExhibitionRowView(
                                            exhibition: ex,
                                            isFavorite: store.favoriteIDs.contains(ex.id),
                                            onToggleFavorite: { store.toggleFavorite(ex.id) }
                                        ).tag(ListSelection.exhibition(ex.id))
                                    }
                                }
                            }
                            if !upcoming.isEmpty {
                                Section("Demnächst") {
                                    ForEach(upcoming) { ex in
                                        ExhibitionRowView(
                                            exhibition: ex,
                                            isFavorite: store.favoriteIDs.contains(ex.id),
                                            onToggleFavorite: { store.toggleFavorite(ex.id) }
                                        ).tag(ListSelection.exhibition(ex.id))
                                    }
                                }
                            }
                        } else {
                            let ongoing  = searchResults.filter { $0.status == .ongoing }
                            let upcoming = searchResults.filter { $0.status == .upcoming }
                            let past     = searchResults.filter { $0.status == .past }

                            if !ongoing.isEmpty {
                                Section("Laufend") {
                                    ForEach(ongoing) { ex in
                                        ExhibitionRowView(
                                            exhibition: ex,
                                            isFavorite: store.favoriteIDs.contains(ex.id),
                                            onToggleFavorite: { store.toggleFavorite(ex.id) }
                                        ).tag(ListSelection.exhibition(ex.id))
                                    }
                                }
                            }
                            if !upcoming.isEmpty {
                                Section("Demnächst") {
                                    ForEach(upcoming) { ex in
                                        ExhibitionRowView(
                                            exhibition: ex,
                                            isFavorite: store.favoriteIDs.contains(ex.id),
                                            onToggleFavorite: { store.toggleFavorite(ex.id) }
                                        ).tag(ListSelection.exhibition(ex.id))
                                    }
                                }
                            }
                            if !past.isEmpty {
                                Section("Vergangen") {
                                    ForEach(past) { ex in
                                        ExhibitionRowView(
                                            exhibition: ex,
                                            isFavorite: store.favoriteIDs.contains(ex.id),
                                            onToggleFavorite: { store.toggleFavorite(ex.id) }
                                        ).tag(ListSelection.exhibition(ex.id))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Frankfurt Museen")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if !store.selectedEventIDs.isEmpty {
                Button {
                    showEventExport = true
                } label: {
                    Label("Veranstaltungen exportieren (\(store.selectedEventIDs.count))",
                          systemImage: "calendar.badge.plus")
                }
                .help("Ausgewählte Veranstaltungen zum Kalender hinzufügen")
            }

            if !store.fetchErrors.isEmpty {
                Button {
                    showErrorSheet = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .help("Ladefehler anzeigen")
            }

            Button {
                showBulkExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Alle exportieren")
            .disabled(store.filteredExhibitions.isEmpty)

            if store.isLoading {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Aktualisieren (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

// MARK: - Event Filter Bar (P2 + P4)

private struct EventFilterBar: View {
    @Environment(ExhibitionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    EventFilterChip(
                        label: "Alle Typen",
                        isActive: store.selectedEventType == nil
                    ) { store.selectedEventType = nil }

                    ForEach(store.availableEventTypes, id: \.self) { type in
                        EventFilterChip(
                            label: type,
                            isActive: store.selectedEventType == type
                        ) {
                            store.selectedEventType = store.selectedEventType == type ? nil : type
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }

            Picker("Zeitraum", selection: $store.eventTimeRange) {
                ForEach(ExhibitionStore.EventTimeRange.allCases, id: \.self) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct EventFilterChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isActive ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isActive ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isActive ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Kino Link Row (P8)

private struct KinoLinkRow: View {
    private let filmmuseum = Museum.all.first { $0.id == "filmmuseum" }!

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://www.dff.film/kino/")!)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: filmmuseum.colorHex) ?? .purple)
                    .frame(width: 4, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(filmmuseum.shortName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(hex: filmmuseum.colorHex) ?? .purple)
                    Text("DFF Kino")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text("Spielplan auf dff.film ↗")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bulk Export Sheet

private struct BulkExportSheet: View {
    @Environment(ICalExporter.self) private var exporter
    @Environment(ExhibitionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCalendarID: String?
    @State private var message: String?
    @State private var messageIsError = false

    private var exhibitions: [Exhibition] { store.filteredExhibitions }
    private var selectedCalendar: EKCalendar? {
        exporter.availableCalendars.first { $0.calendarIdentifier == selectedCalendarID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Alle exportieren")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section {
                    Text("\(exhibitions.count) Ausstellung\(exhibitions.count == 1 ? "" : "en") in der aktuellen Ansicht")
                        .foregroundStyle(.secondary)
                }

                Section("Zum Kalender hinzufügen") {
                    if exporter.hasAccess {
                        Picker("Kalender", selection: $selectedCalendarID) {
                            ForEach(exporter.availableCalendars, id: \.calendarIdentifier) { cal in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(cgColor: cal.cgColor))
                                        .frame(width: 10, height: 10)
                                    Text(cal.title)
                                }
                                .tag(Optional(cal.calendarIdentifier))
                            }
                        }

                        Button {
                            guard let cal = selectedCalendar else { return }
                            do {
                                try exporter.addAllToCalendar(exhibitions, calendar: cal)
                                message = "\(exhibitions.count) Ausstellungen zu \"\(cal.title)\" hinzugefügt."
                                messageIsError = false
                            } catch {
                                message = error.localizedDescription
                                messageIsError = true
                            }
                        } label: {
                            Label("Alle \(exhibitions.count) hinzufügen", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedCalendar == nil)
                    } else {
                        Button("Kalenderzugriff erlauben") {
                            Task { await exporter.requestAccess() }
                        }
                    }
                }

                Section("Als Datei") {
                    ShareLink(
                        item: exporter.generateICS(exhibitions),
                        preview: SharePreview("Frankfurt Museen.ics",
                                              icon: Image(systemName: "calendar"))
                    ) {
                        Label("Als .ics exportieren", systemImage: "square.and.arrow.up")
                    }
                }

                if let msg = message {
                    Section {
                        Text(msg)
                            .foregroundStyle(messageIsError ? Color.red : Color.green)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding()
            }
        }
        .frame(width: 400, height: 460)
        .onAppear {
            selectedCalendarID = exporter.selectedCalendar?.calendarIdentifier
                ?? exporter.availableCalendars.first?.calendarIdentifier
        }
    }
}

// MARK: - Error Sheet

private struct ErrorSheet: View {
    @Environment(ExhibitionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Ladefehler")
                .font(.headline)
                .padding()

            Divider()

            List(store.fetchErrors, id: \.museum) { err in
                VStack(alignment: .leading, spacing: 4) {
                    Text(err.museum).fontWeight(.semibold)
                    Text(err.message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding()
            }
        }
        .frame(width: 420, height: 320)
    }
}

// MARK: - Event Export Sheet

private struct EventExportSheet: View {
    @Environment(ICalExporter.self) private var exporter
    @Environment(ExhibitionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCalendarID: String?
    @State private var message: String?
    @State private var messageIsError = false

    private var selectedEvents: [MuseumEvent] {
        store.filteredEvents.filter { store.selectedEventIDs.contains($0.id) }
    }
    private var selectedCalendar: EKCalendar? {
        exporter.availableCalendars.first { $0.calendarIdentifier == selectedCalendarID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Veranstaltungen exportieren")
                .font(.headline)
                .padding()

            Divider()

            Form {
                Section {
                    Text("\(selectedEvents.count) Veranstaltung\(selectedEvents.count == 1 ? "" : "en") ausgewählt")
                        .foregroundStyle(.secondary)
                }

                Section("Zum Kalender hinzufügen") {
                    if exporter.hasAccess {
                        Picker("Kalender", selection: $selectedCalendarID) {
                            ForEach(exporter.availableCalendars, id: \.calendarIdentifier) { cal in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(cgColor: cal.cgColor))
                                        .frame(width: 10, height: 10)
                                    Text(cal.title)
                                }
                                .tag(Optional(cal.calendarIdentifier))
                            }
                        }
                        Button {
                            guard let cal = selectedCalendar else { return }
                            do {
                                try exporter.addEventsToCalendar(selectedEvents, calendar: cal)
                                store.selectedEventIDs = []
                                message = "\(selectedEvents.count) Veranstaltungen zu \"\(cal.title)\" hinzugefügt."
                                messageIsError = false
                            } catch {
                                message = error.localizedDescription
                                messageIsError = true
                            }
                        } label: {
                            Label("Alle \(selectedEvents.count) hinzufügen", systemImage: "calendar.badge.plus")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedCalendar == nil)
                    } else {
                        Button("Kalenderzugriff erlauben") {
                            Task { await exporter.requestAccess() }
                        }
                    }
                }

                Section("Als Datei") {
                    ShareLink(
                        item: exporter.generateEventICS(selectedEvents),
                        preview: SharePreview("Veranstaltungen.ics", icon: Image(systemName: "calendar"))
                    ) {
                        Label("Als .ics exportieren", systemImage: "square.and.arrow.up")
                    }
                }

                if let msg = message {
                    Section {
                        Text(msg)
                            .foregroundStyle(messageIsError ? Color.red : Color.green)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .padding()
            }
        }
        .frame(width: 400, height: 440)
        .onAppear {
            selectedCalendarID = exporter.selectedCalendar?.calendarIdentifier
                ?? exporter.availableCalendars.first?.calendarIdentifier
        }
    }
}

#Preview {
    ContentView()
        .environment(ExhibitionStore())
        .environment(ICalExporter())
}

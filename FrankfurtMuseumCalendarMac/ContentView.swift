import SwiftUI
import EventKit

struct ContentView: View {
    @Environment(ExhibitionStore.self) private var store
    @Environment(ICalExporter.self) private var exporter
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var searchDebounceTask: Task<Void, Never>?
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

    private var selectedEvent: MuseumEvent? {
        guard case .event(let id) = listSelection else { return nil }
        return store.filteredEvents.first { $0.id == id }
    }

    // Precomputed once per render cycle for all rows + detail pane
    private var seriesInfo: [MuseumEvent.ID: ExhibitionStore.EventSeriesInfo] {
        store.eventSeriesInfo
    }

    var searchResults: [Exhibition] {
        let base = store.filteredExhibitions
        guard !debouncedSearch.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(debouncedSearch) ||
            $0.museum.name.localizedCaseInsensitiveContains(debouncedSearch)
        }
    }

    var searchFilteredEvents: [MuseumEvent] {
        let events = store.filteredEvents
        guard !debouncedSearch.isEmpty else { return events }
        return events.filter {
            $0.title.localizedCaseInsensitiveContains(debouncedSearch) ||
            $0.museum.name.localizedCaseInsensitiveContains(debouncedSearch)
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
            if let event = selectedEvent {
                EventDetailView(
                    event: event,
                    siblings: seriesInfo[event.id]?.siblings ?? []
                )
                .environment(exporter)
                .id(event.id)
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
        .onChange(of: searchText) { _, new in
            searchDebounceTask?.cancel()
            searchDebounceTask = Task {
                if !new.isEmpty {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard !Task.isCancelled else { return }
                debouncedSearch = new
            }
        }
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
        .task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await store.refresh() }
                if store.showEvents { group.addTask { await store.refreshEvents() } }
            }
        }
    }

    // MARK: - Exhibition/Event List

    private var loadingProgress: Double {
        guard store.totalMuseumCount > 0 else { return 0 }
        return Double(store.loadedMuseumCount) / Double(store.totalMuseumCount)
    }

    private var eventsLoadingProgress: Double {
        guard store.totalEventMuseumCount > 0 else { return 0 }
        return Double(store.loadedEventMuseumCount) / Double(store.totalEventMuseumCount)
    }

    private var exhibitionList: some View {
        VStack(spacing: 0) {
            if store.isLoading {
                DeterministicLoadingBar(progress: loadingProgress, color: .accentColor)
            } else if store.isEventsLoading {
                DeterministicLoadingBar(progress: eventsLoadingProgress, color: .orange)
            } else {
                Color.clear.frame(height: 2)
            }

            // P2 + P4: event filter bar
            if store.showEvents && !store.events.isEmpty {
                EventFilterBar()
                    .environment(store)
                Divider()
            }

            Group {
                if store.isLoading && store.exhibitions.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView(value: loadingProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                        Text("Lade Ausstellungen \(store.loadedMuseumCount)/\(store.totalMuseumCount)…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty && searchFilteredEvents.isEmpty {
                    ContentUnavailableView(
                        "Keine Einträge",
                        systemImage: "building.columns",
                        description: Text(store.exhibitions.isEmpty
                            ? "Drücke ⌘R um Daten zu laden."
                            : "Keine Treffer für die gewählten Filter.")
                    )
                } else if store.isEventsLoading && store.events.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView(value: eventsLoadingProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                        Text("Lade Veranstaltungen \(store.loadedEventMuseumCount)/\(store.totalEventMuseumCount)…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $listSelection) {


                        if store.showEvents {
                            Section("Veranstaltungen") {
                                if store.selectedMuseumIDs.contains("filmmuseum") {
                                    KinoLinkRow()
                                }
                                if searchFilteredEvents.isEmpty {
                                    Text("Keine bevorstehenden Veranstaltungen")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                } else {
                                    ForEach(searchFilteredEvents) { event in
                                        EventRowView(
                                            event: event,
                                            siblingCount: seriesInfo[event.id]?.siblingCount ?? 0,
                                            isSelected: store.selectedEventIDs.contains(event.id),
                                            onToggle: {
                                                if store.selectedEventIDs.contains(event.id) {
                                                    store.selectedEventIDs.remove(event.id)
                                                } else {
                                                    store.selectedEventIDs.insert(event.id)
                                                }
                                            },
                                            isFavorite: store.favoriteIDs.contains(event.id),
                                            onToggleFavorite: { store.toggleFavorite(event.id) }
                                        )
                                        .tag(ListSelection.event(event.id))
                                    }
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
                    .animation(.none, value: store.filterRevision)
                }
            }
        }
        .navigationTitle("Frankfurter Museumskalender")
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
                Label(
                    "\(store.loadedMuseumCount)/\(store.totalMuseumCount)",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else if store.isEventsLoading {
                Label(
                    "\(store.loadedEventMuseumCount)/\(store.totalEventMuseumCount)",
                    systemImage: "calendar.badge.clock"
                )
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        await store.refresh()
                        if store.showEvents { await store.refreshEvents(force: true) }
                    }
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

// MARK: - Deterministic Loading Bar

private struct DeterministicLoadingBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            color.opacity(0.75)
                .frame(width: max(0, geo.size.width * progress))
                .animation(.linear(duration: 0.2), value: progress)
        }
        .frame(height: 2)
        .background(color.opacity(0.12))
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

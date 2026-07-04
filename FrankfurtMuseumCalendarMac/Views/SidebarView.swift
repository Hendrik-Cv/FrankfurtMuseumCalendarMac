import SwiftUI

struct SidebarView: View {
    @Environment(ExhibitionStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List {
            // P5: Favoriten als prominentes Nav-Item
            Section {
                Toggle(isOn: $store.showOnlyFavorites) {
                    Label(
                        store.showOnlyFavorites ? "Nur Favoriten" : "Favoriten",
                        systemImage: store.showOnlyFavorites ? "star.fill" : "star"
                    )
                    .foregroundStyle(store.showOnlyFavorites ? Color.yellow : Color.primary)
                }
                .tint(.yellow)
            }

            Section("Ansicht") {
                Toggle("Vergangene anzeigen", isOn: $store.showPast)
                Toggle("Veranstaltungen", isOn: $store.showEvents)
                    .onChange(of: store.showEvents) { _, on in
                        if on { Task { await store.refreshEvents() } }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sortieren nach")
                    Picker("", selection: $store.sortOrder) {
                        ForEach(ExhibitionStore.SortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            Section {
                Toggle("Alle auswählen", isOn: Binding(
                    get: { Museum.all.allSatisfy { store.selectedMuseumIDs.contains($0.id) } },
                    set: { on in
                        store.selectedMuseumIDs = on ? Set(Museum.all.map { $0.id }) : []
                    }
                ))
                .toggleStyle(.checkbox)
            } header: {
                Text("Museen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            // P3: Sektions-Header klickbar → selektiert/deselektiert alle Museen der Kategorie
            ForEach(MuseumCategory.allCases, id: \.self) { category in
                let museumsInCategory = Museum.all.filter { $0.category == category }
                Section {
                    ForEach(museumsInCategory) { museum in
                        Toggle(isOn: Binding(
                            get: { store.selectedMuseumIDs.contains(museum.id) },
                            set: { isOn in
                                if isOn { store.selectedMuseumIDs.insert(museum.id) }
                                else    { store.selectedMuseumIDs.remove(museum.id) }
                            }
                        )) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color(adaptiveHex: museum.colorHex) ?? .blue)
                                    .frame(width: 4, height: 16)
                                Text(museum.shortName)
                                    .font(.body)
                            }
                        }
                    }
                } header: {
                    CategorySectionHeader(category: category, store: store)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

private struct CategorySectionHeader: View {
    let category: MuseumCategory
    let store: ExhibitionStore

    private var museumsInCategory: [Museum] {
        Museum.all.filter { $0.category == category }
    }
    private var allSelected: Bool {
        museumsInCategory.allSatisfy { store.selectedMuseumIDs.contains($0.id) }
    }
    private var anySelected: Bool {
        museumsInCategory.contains { store.selectedMuseumIDs.contains($0.id) }
    }

    var body: some View {
        Button {
            if allSelected {
                museumsInCategory.forEach { store.selectedMuseumIDs.remove($0.id) }
            } else {
                museumsInCategory.forEach { store.selectedMuseumIDs.insert($0.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(category.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Image(systemName: allSelected ? "checkmark.circle.fill"
                                 : anySelected ? "minus.circle.fill"
                                 : "circle")
                    .font(.caption2)
                    .foregroundStyle(allSelected ? Color.accentColor
                                    : anySelected ? Color.accentColor.opacity(0.6)
                                    : Color.clear)
            }
        }
        .buttonStyle(.plain)
    }
}

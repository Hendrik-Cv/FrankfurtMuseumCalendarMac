import SwiftUI

struct EventDetailView: View {
    let event: MuseumEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(event.museum.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color(hex: event.museum.colorHex) ?? .accentColor)
                        Spacer()
                        if event.isCancelled {
                            EventDetailBadge(label: "Abgesagt", color: .red)
                        }
                        EventDetailBadge(label: event.eventType, color: eventTypeColor)
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

                // Exhibition context
                if let ex = event.exhibitionTitle {
                    EventLabeledRow(icon: "arrow.right", label: "Ausstellung") {
                        Text(ex)
                            .font(.body)
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

                Divider()

                // Actions
                Button {
                    NSWorkspace.shared.open(event.url)
                } label: {
                    Label("Im Browser öffnen", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)

                Spacer(minLength: 20)
            }
            .padding(.vertical)
        }
        .navigationTitle(event.museum.shortName)
    }

    private var eventTypeColor: Color {
        let t = event.eventType.lowercased()
        if t.contains("führung")                               { return .orange }
        if t.contains("eröffnung") || t.contains("opening")   { return .blue   }
        if t.contains("vortrag") || t.contains("diskussion")  { return .purple }
        if t.contains("workshop")                              { return .teal   }
        if t.contains("finissage")                             { return .pink   }
        return .gray
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

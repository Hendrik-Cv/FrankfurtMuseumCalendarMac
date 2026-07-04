import SwiftUI

struct EventRowView: View {
    let event: MuseumEvent
    var siblingCount: Int = 0
    var isSelected: Bool = false
    var onToggle: (() -> Void)? = nil
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let toggle = onToggle {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.top, 3)
            }

            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: event.museum.colorHex) ?? .blue)
                .frame(width: 4)
                .frame(minHeight: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(event.museum.shortName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(hex: event.museum.colorHex) ?? .blue)
                    Spacer()
                    if siblingCount > 0 {
                        Text("+\(siblingCount) Termin\(siblingCount == 1 ? "" : "e")")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    if event.isCancelled { CancelledBadge() }
                    EventTypeBadge(type: event.eventType)
                    if let toggle = onToggleFavorite {
                        Button(action: toggle) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(event.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(event.isCancelled ? .secondary : .primary)
                    .strikethrough(event.isCancelled)
                    .lineLimit(2)

                Text(event.formattedDateTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let ex = event.exhibitionTitle {
                    Text("→ \(ex)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if let desc = event.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct EventTypeBadge: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(eventTypeColor(type).opacity(0.15))
            .foregroundStyle(eventTypeColor(type))
            .clipShape(Capsule())
    }
}

func eventTypeColor(_ type: String) -> Color {
    let l = type.lowercased()
    if l.contains("führung")                                 { return .orange }
    if l.contains("eröffnung") || l.contains("opening")     { return .blue   }
    if l.contains("finissage")                               { return .pink   }
    if l.contains("vortrag") || l.contains("diskussion") || l.contains("gespräch") || l.contains("lecture") { return .purple }
    if l.contains("workshop")                                { return .teal   }
    if l.contains("kinder") || l.contains("familie") || l.contains("ferienprogramm") { return .green }
    if l.contains("konzert") || l.contains("musik")         { return .indigo }
    if l.contains("film") || l.contains("kino")             { return .brown  }
    if l.contains("performance")                             { return .pink   }
    if l.contains("exkursion") || l.contains("spazier")     { return .mint   }
    return .gray
}

private struct CancelledBadge: View {
    var body: some View {
        Text("Abgesagt")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.red.opacity(0.15))
            .foregroundStyle(.red)
            .clipShape(Capsule())
    }
}

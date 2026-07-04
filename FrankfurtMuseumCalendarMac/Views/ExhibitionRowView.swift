import SwiftUI

struct ExhibitionRowView: View {
    let exhibition: Exhibition
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(adaptiveHex: exhibition.museum.colorHex) ?? Color.blue)
                .frame(width: 4)
                .frame(minHeight: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(exhibition.museum.shortName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(adaptiveHex: exhibition.museum.colorHex) ?? Color.blue)

                    Spacer()

                    if let days = daysUntilEnd, days <= 20 {
                        ClosingSoonBadge(days: days)
                    } else if let days = daysUntilStart, days <= 20 {
                        StartingSoonBadge(days: days)
                    } else {
                        StatusBadge(status: exhibition.status)
                    }

                    if let toggle = onToggleFavorite {
                        Button(action: toggle) {
                            Image(systemName: isFavorite ? "star.fill" : "star")
                                .font(.caption)
                                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(exhibition.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(exhibition.formattedDateRange)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var daysUntilEnd: Int? {
        guard exhibition.status == .ongoing else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
            from: cal.startOfDay(for: Date()),
            to: cal.startOfDay(for: exhibition.endDate)).day
    }

    private var daysUntilStart: Int? {
        guard exhibition.status == .upcoming else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day],
            from: cal.startOfDay(for: Date()),
            to: cal.startOfDay(for: exhibition.startDate)).day
    }
}

private struct ClosingSoonBadge: View {
    let days: Int

    var body: some View {
        Text(days == 0 ? "Letzter Tag" : "Noch \(days) Tag\(days == 1 ? "" : "e")")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(days <= 3 ? Color.red.opacity(0.15) : Color.orange.opacity(0.15))
            .foregroundStyle(days <= 3 ? Color.red : Color.orange)
            .clipShape(Capsule())
    }
}

private struct StartingSoonBadge: View {
    let days: Int

    var body: some View {
        Text(days == 0 ? "Heute" : "In \(days) Tag\(days == 1 ? "" : "en")")
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.teal.opacity(0.15))
            .foregroundStyle(Color.teal)
            .clipShape(Capsule())
    }
}

private struct StatusBadge: View {
    let status: Exhibition.Status

    var body: some View {
        Text(status.label)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15))
            .foregroundStyle(badgeColor)
            .clipShape(Capsule())
    }

    private var badgeColor: Color {
        switch status {
        case .ongoing:  return .green
        case .upcoming: return .blue
        case .past:     return .gray
        }
    }
}

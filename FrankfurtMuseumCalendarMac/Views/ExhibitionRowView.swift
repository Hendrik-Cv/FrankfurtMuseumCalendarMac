import SwiftUI

struct ExhibitionRowView: View {
    let exhibition: Exhibition

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: exhibition.museum.colorHex) ?? Color.blue)
                .frame(width: 4)
                .frame(minHeight: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(exhibition.museum.shortName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(hex: exhibition.museum.colorHex) ?? Color.blue)

                    Spacer()

                    StatusBadge(status: exhibition.status)
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

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: (r, g, b) = (int >> 16, int >> 8 & 0xFF, int & 0xFF)
        default: return nil
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255)
    }
}

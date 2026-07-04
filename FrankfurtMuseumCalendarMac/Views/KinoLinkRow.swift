import SwiftUI

struct KinoLinkRow: View {
    private let filmmuseum = Museum.all.first { $0.id == "filmmuseum" }!

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "https://www.dff.film/kino/")!)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(adaptiveHex: filmmuseum.colorHex) ?? .purple)
                    .frame(width: 4, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(filmmuseum.shortName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color(adaptiveHex: filmmuseum.colorHex) ?? .purple)
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

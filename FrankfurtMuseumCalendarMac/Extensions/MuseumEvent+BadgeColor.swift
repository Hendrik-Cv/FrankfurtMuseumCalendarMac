import SwiftUI

extension MuseumEvent {
    var badgeColor: Color { MuseumEvent.color(for: eventType) }

    static func color(for eventType: String) -> Color {
        let l = eventType.lowercased()
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
}

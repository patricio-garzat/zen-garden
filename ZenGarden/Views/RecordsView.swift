import SwiftUI

struct RecordsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let s = model.progression.stats
        VStack(spacing: 0) {
            SheetHeader(title: T("Records", "Récords")) { dismiss() }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    tile("scribble.variable", "\(s.strokes)", T("Strokes", "Trazos"))
                    tile("ruler", distance(s.distance), T("Sand raked", "Arena rastrillada"))
                    tile("clock", duration(s.secondsRaking), T("Time raking", "Tiempo rastrillando"))
                    tile("circle.circle", "\(s.ripples)", T("Ripples", "Ondas"))
                    tile("mountain.2", "\(s.stonesPlaced)", T("Stones placed", "Piedras colocadas"))
                    tile("wind", "\(s.smooths)", T("Fresh starts", "Nuevos comienzos"))
                    tile("square.grid.2x2", "\(s.gardensSaved)", T("Gardens saved", "Jardines guardados"))
                    tile("calendar", since(s.firstPlayed), T("Playing since", "Jugando desde"))
                }
                .padding(.horizontal, 20)
                Text(T("Zen Points, unlockable rakes, stones and sands arrive in a coming update.",
                       "Los Zen Points y los rastrillos, piedras y arenas desbloqueables llegan en una próxima versión."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func tile(_ symbol: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(ZenPalette.moss)
            Text(value)
                .font(.system(size: 26, weight: .light, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Garden units are about a metre each.
    private func distance(_ d: Double) -> String {
        d < 1000 ? String(format: "%.0f m", d) : String(format: "%.1f km", d / 1000)
    }

    private func duration(_ s: Double) -> String {
        let m = Int(s / 60)
        return m < 60 ? "\(m) min" : String(format: "%d h %02d", m / 60, m % 60)
    }

    private func since(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: model.settings.language == .es ? "es" : "en")
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: d)
    }
}

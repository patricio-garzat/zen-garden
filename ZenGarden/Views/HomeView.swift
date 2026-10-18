import SwiftUI

/// "ZEN GARDEN", written softly over the sand.
struct GameTitle: View {
    var showsTagline: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var shown = false

    var body: some View {
        VStack(spacing: 10) {
            Text("ZEN GARDEN")
                .font(.system(size: 30, weight: .light, design: .serif))
                .tracking(shown ? 6 : 2)
                .blur(radius: shown ? 0 : 6)
            Text(T("Rake. Breathe. Begin again.", "Rastrilla. Respira. Vuelve a empezar."))
                .font(.system(size: 15, weight: .regular, design: .serif))
                .italic()
                .opacity(showsTagline ? 0.75 : 0)
        }
        .foregroundStyle(ZenPalette.overSand(scheme))
        .shadow(color: (scheme == .dark ? Color.black : Color.white).opacity(0.35), radius: 8)
        .opacity(shown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 150)
        .allowsHitTesting(false)
        .onAppear {
            if UIAccessibility.isReduceMotionEnabled {
                shown = true
            } else {
                withAnimation(.easeOut(duration: 1.6).delay(0.6)) { shown = true }
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            VStack(spacing: 14) {
                Spacer()
                Button {
                    Feedback.tap()
                    model.enterGarden()
                } label: {
                    HStack(spacing: 12) {
                        ToolIcon(.fine, size: 24)
                        Text(T("Free Garden", "Jardín libre"))
                            .font(.system(size: 19, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .contentShape(Capsule())
                }
                .buttonStyle(SoftPressStyle())
                .foregroundStyle(.primary)
                .zenGlass(Capsule(), interactive: true)

                HStack(spacing: 12) {
                    SoonCard(title: T("Zen Patterns", "Patrones Zen"), symbol: "circle.dotted.circle")
                    SoonCard(title: T("Daily Garden", "Jardín del día"), symbol: "sun.horizon")
                }

                HStack(spacing: 18) {
                    HomeIcon(symbol: "square.grid.2x2", label: T("Gardens", "Jardines")) { model.sheet = .gallery }
                    HomeIcon(symbol: "chart.bar", label: T("Records", "Récords")) { model.sheet = .records }
                    HomeIcon(symbol: "questionmark.circle", label: T("How to play", "Cómo jugar")) { model.sheet = .howToPlay }
                    HomeIcon(symbol: "gearshape", label: T("Settings", "Ajustes")) { model.sheet = .settings }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 26)
        }
    }
}

private struct SoonCard: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18, weight: .light))
            Text(title).font(.system(size: 14, weight: .medium))
            Text(T("Coming soon", "Muy pronto"))
                .font(.system(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(1.2)
                .opacity(0.6)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .foregroundStyle(.primary.opacity(0.75))
        .zenGlass(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct HomeIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            Feedback.tap()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .light))
                    .frame(width: 52, height: 52)
                    .zenGlass(Circle(), interactive: true)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(SoftPressStyle())
        .foregroundStyle(.primary)
    }
}

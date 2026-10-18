import SwiftUI

/// Zen Garden's own palette (no studio blues, no Cube Swipe rhombuses).
enum ZenPalette {
    static let ink = Color(red: 0.184, green: 0.169, blue: 0.149)        // #2F2B26
    static let inkSoft = Color(red: 0.42, green: 0.39, blue: 0.36)
    static let moss = Color(red: 0.435, green: 0.518, blue: 0.376)       // #6F8460
    static let sand = Color(red: 0.914, green: 0.882, blue: 0.82)        // #E9E1D1
    static let paper = Color(red: 0.95, green: 0.93, blue: 0.89)

    /// Text drawn directly over the sand (the sand is light by day and dusky in dark mode).
    static func overSand(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.95, green: 0.92, blue: 0.87) : ink
    }
}

enum Feedback {
    static func tap() {
        HapticsManager.shared.uiTap()
        AudioManager.shared.play(.uiTap, volume: 0.55)
    }
}

extension View {
    /// Translucent iOS surface: Liquid Glass on iOS 26, material + hairline before.
    @ViewBuilder
    func zenGlass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.22), lineWidth: 0.5))
        }
    }
}

/// Gentle press response: a slight scale and dim, no bounce.
struct SoftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

/// Round glass button with an SF Symbol (line style).
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = 44
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button {
            Feedback.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .regular))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .foregroundStyle(.primary)
        .zenGlass(Circle(), interactive: true)
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// Small transient message at the top of the screen.
struct ToastView: View {
    let toast: GardenUIState.Toast
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.symbol).font(.system(size: 14, weight: .medium))
            Text(toast.text).font(.system(size: 15, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .zenGlass(Capsule())
    }
}

/// Title used in sheets.
struct SheetHeader: View {
    let title: String
    let close: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 28, weight: .light, design: .serif))
            Spacer()
            Button {
                Feedback.tap()
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(SoftPressStyle())
            .foregroundStyle(.primary)
            .accessibilityLabel(T("Close", "Cerrar"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
    }
}

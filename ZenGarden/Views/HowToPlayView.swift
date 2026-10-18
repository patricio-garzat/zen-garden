import SwiftUI

struct HowToPlayView: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id = UUID()
        let icon: AnyView
        let title: String
        let text: String
    }

    private var steps: [Step] {
        [
            Step(icon: AnyView(ToolIcon(.fine, size: 28)), title: T("Rake the sand", "Rastrilla la arena"),
                 text: T("Slide your finger. The rake follows a little behind, so your lines come out calm and flowing.",
                         "Desliza el dedo. El rastrillo te sigue un poco atrás, así tus líneas salen tranquilas y fluidas.")),
            Step(icon: AnyView(ToolIcon(.wide, size: 28)), title: T("Four tools", "Cuatro herramientas"),
                 text: T("Fine rake for delicate lines, wide rake for deep furrows, wave rake for flowing curves, smoother to erase.",
                         "Rastrillo fino para líneas delicadas, ancho para surcos profundos, de ondas para curvas suaves y alisador para borrar.")),
            Step(icon: AnyView(ToolIcon(.wave, size: 28)), title: T("Ripples", "Ondas"),
                 text: T("With the wave rake, tap the sand to draw circles. Tap a stone to ring it with ripples.",
                         "Con el rastrillo de ondas, toca la arena para dibujar círculos. Toca una piedra para rodearla de ondas.")),
            Step(icon: AnyView(ToolIcon(.stones, size: 28)), title: T("Stones", "Piedras"),
                 text: T("Add stones from the tray. Drag to move, use two fingers to rotate, and drag one off the sand to remove it.",
                         "Agrega piedras desde la bandeja. Arrástralas para moverlas, gíralas con dos dedos y sácalas de la arena para quitarlas.")),
            Step(icon: AnyView(ToolIcon(.smoothAll, size: 28)), title: T("Start again", "Empieza de nuevo"),
                 text: T("Smooth the whole garden with one touch and watch the sand settle. Undo and redo anytime.",
                         "Alisa todo el jardín con un toque y mira cómo se asienta la arena. Puedes deshacer y rehacer cuando quieras.")),
            Step(icon: AnyView(Image(systemName: "square.and.arrow.down").font(.system(size: 22, weight: .light)).frame(width: 28, height: 28)),
                 title: T("Keep your gardens", "Guarda tus jardines"),
                 text: T("Your garden is kept automatically. Save it to your gallery, or as an image in Photos.",
                         "Tu jardín se guarda solo. También puedes guardarlo en tu galería o como imagen en Fotos.")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: T("How to play", "Cómo jugar")) { dismiss() }
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 16) {
                            step.icon
                                .foregroundStyle(ZenPalette.moss)
                                .frame(width: 44, height: 44)
                                .background(ZenPalette.moss.opacity(0.12), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).font(.system(size: 17, weight: .semibold))
                                Text(step.text).font(.system(size: 15)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .presentationDragIndicator(.visible)
    }
}

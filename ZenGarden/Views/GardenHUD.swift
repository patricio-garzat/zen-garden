import SwiftUI

/// Controls shown over the garden. They fade back while the player touches the sand.
struct GardenHUD: View {
    @Environment(AppModel.self) private var model
    @State private var trayOpen = false
    @State private var toolBanner: String?
    @State private var bannerWork: DispatchWorkItem?
    @State private var dimmed = false
    @Namespace private var toolNS

    private var ui: GardenUIState { model.engine.ui }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if let toolBanner {
                Text(toolBanner)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .zenGlass(Capsule())
                    .transition(.opacity)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
            if trayOpen {
                StoneTray { type in model.engine.addStone(type: type) }
                    .transition(.opacity.combined(with: .offset(y: 12)))
                    .padding(.bottom, 10)
            }
            toolbar
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .opacity(dimmed ? 0.28 : 1)
        .overlay(alignment: .top) {
            if let toast = ui.toast {
                ToastView(toast: toast)
                    .padding(.top, 64)
                    .transition(.opacity)
                    .id(toast.id)
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 1_700_000_000)
                        withAnimation(.easeInOut(duration: 0.4)) { if ui.toast?.id == toast.id { ui.toast = nil } }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: ui.toast)
        .onChange(of: ui.interacting) { _, active in
            if active {
                withAnimation(.easeInOut(duration: 0.35)) { dimmed = true }
            } else {
                withAnimation(.easeInOut(duration: 0.6).delay(0.35)) { dimmed = false }
            }
        }
    }

    // MARK: - Top

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "house") { model.goHome() }
                .accessibilityLabel(T("Home", "Inicio"))
            Spacer()
            GlassIconButton(symbol: "arrow.uturn.backward", enabled: ui.canUndo && !ui.busy) { model.engine.undo() }
                .accessibilityLabel(T("Undo", "Deshacer"))
            GlassIconButton(symbol: "arrow.uturn.forward", enabled: ui.canRedo && !ui.busy) { model.engine.redo() }
                .accessibilityLabel(T("Redo", "Rehacer"))
            Menu {
                Button { Feedback.tap(); model.engine.saveToGallery() } label: {
                    Label(T("Save garden", "Guardar jardín"), systemImage: "square.and.arrow.down")
                }
                Button { Feedback.tap(); model.sheet = .gallery } label: {
                    Label(T("My gardens", "Mis jardines"), systemImage: "square.grid.2x2")
                }
                Button { Feedback.tap(); model.engine.exportToPhotos() } label: {
                    Label(T("Save image to Photos", "Guardar imagen en Fotos"), systemImage: "photo")
                }
                Divider()
                Button { Feedback.tap(); model.engine.newGarden() } label: {
                    Label(T("New garden", "Jardín nuevo"), systemImage: "leaf")
                }
                Button { Feedback.tap(); model.sheet = .howToPlay } label: {
                    Label(T("How to play", "Cómo jugar"), systemImage: "questionmark.circle")
                }
                Button { Feedback.tap(); model.sheet = .settings } label: {
                    Label(T("Settings", "Ajustes"), systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .zenGlass(Circle(), interactive: true)
            }
            .foregroundStyle(.primary)
            .accessibilityLabel(T("More", "Más"))
            .simultaneousGesture(TapGesture().onEnded { Feedback.tap() })
        }
        .padding(.top, 4)
    }

    // MARK: - Bottom

    private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(ToolKind.allCases) { tool in
                Button {
                    trayOpen = false
                    withAnimation(.smooth(duration: 0.35)) { model.engine.select(tool) }
                    showBanner(tool.title)
                } label: {
                    ToolIcon(tool: tool, size: 26)
                        .frame(width: 50, height: 50)
                        .background {
                            if ui.tool == tool && !trayOpen {
                                Circle()
                                    .fill(Color.primary.opacity(0.10))
                                    .matchedGeometryEffect(id: "sel", in: toolNS)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(ui.tool == tool ? .isSelected : [])
            }

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: 26)
                .padding(.horizontal, 6)

            Button {
                Feedback.tap()
                withAnimation(.smooth(duration: 0.35)) { trayOpen.toggle() }
            } label: {
                ToolIcon(.stones, size: 26)
                    .frame(width: 50, height: 50)
                    .background {
                        if trayOpen {
                            Circle().fill(Color.primary.opacity(0.10)).matchedGeometryEffect(id: "sel", in: toolNS)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel(T("Stones", "Piedras"))

            Button {
                Feedback.tap()
                trayOpen = false
                model.engine.smoothAll()
                showBanner(T("Smoothing the garden", "Alisando el jardín"))
            } label: {
                ToolIcon(.smoothAll, size: 26)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(SoftPressStyle())
            .disabled(ui.busy)
            .accessibilityLabel(T("Smooth the whole garden", "Alisar todo el jardín"))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .zenGlass(Capsule())
    }

    private func showBanner(_ text: String) {
        bannerWork?.cancel()
        withAnimation(.easeInOut(duration: 0.25)) { toolBanner = text }
        let work = DispatchWorkItem { withAnimation(.easeInOut(duration: 0.5)) { toolBanner = nil } }
        bannerWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }
}

/// Five stones to place. Tap one: it drops onto a free spot of the sand.
struct StoneTray: View {
    let add: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(StoneCatalog.all, id: \.id) { type in
                    Button {
                        Feedback.tap()
                        add(type.id)
                    } label: {
                        VStack(spacing: 4) {
                            StoneThumb(type: type, size: 44)
                            Text(type.name).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(SoftPressStyle())
                    .accessibilityLabel(type.name)
                }
            }
            Text(T("Drag to move · two fingers to rotate · drag off the sand to remove",
                   "Arrastra para mover · dos dedos para girar · sácala de la arena para quitarla"))
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .opacity(0.65)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .zenGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

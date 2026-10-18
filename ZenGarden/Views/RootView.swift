import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var systemScheme

    private var isDark: Bool {
        switch model.settings.theme {
        case .auto: return systemScheme == .dark
        case .light: return false
        case .dark: return true
        }
    }

    var body: some View {
        @Bindable var model = model
        ZStack {
            GardenMetalView(engine: model.engine)
                .ignoresSafeArea()

            if model.phase == .gameIntro || model.phase == .home {
                GameTitle(showsTagline: true)
                    .transition(.opacity)
            }
            if model.phase == .home {
                HomeView()
                    .transition(.opacity)
            }
            if model.phase == .garden {
                GardenHUD()
                    .transition(.opacity)
            }

            if model.phase == .bluberIntro {
                BluBerIntroView { model.bluberIntroFinished() }
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(model.settings.theme.colorScheme)
        .statusBarHidden(true)
        .persistentSystemOverlays(model.phase == .garden ? .hidden : .automatic)
        .defersSystemGestures(on: .bottom)
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .settings: SettingsView()
                case .howToPlay: HowToPlayView()
                case .records: RecordsView()
                case .gallery: GalleryView()
                }
            }
            .environment(model)
            .preferredColorScheme(model.settings.theme.colorScheme)
        }
        .onAppear { model.engine.setDark(isDark) }
        .onChange(of: isDark) { _, dark in model.engine.setDark(dark) }
        .onChange(of: model.settings.quality) { _, _ in model.engine.applyQualitySetting() }
    }
}

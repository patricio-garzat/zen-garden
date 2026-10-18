import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        @Bindable var settings = model.settings
        VStack(spacing: 0) {
            SheetHeader(title: T("Settings", "Ajustes")) { dismiss() }
            Form {
                Section(T("Sound", "Sonido")) {
                    Toggle(isOn: $settings.soundOn) { Label(T("Sound", "Sonido"), systemImage: "speaker.wave.2") }
                    if settings.soundOn {
                        HStack {
                            Image(systemName: "speaker").font(.system(size: 13)).foregroundStyle(.secondary)
                            Slider(value: $settings.volume, in: 0.1...1)
                            Image(systemName: "speaker.wave.3").font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                    }
                }

                Section(T("Haptics", "Vibración")) {
                    Toggle(isOn: $settings.hapticsOn) { Label(T("Haptics", "Vibración"), systemImage: "hand.tap") }
                    if settings.hapticsOn {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(T("Intensity", "Intensidad")).font(.subheadline).foregroundStyle(.secondary)
                            Slider(value: $settings.hapticIntensity, in: 0.2...1) { editing in
                                if !editing { HapticsManager.shared.stoneImpact(size: 0.6, strength: 0.8) }
                            }
                        }
                    }
                }

                Section(T("Appearance", "Apariencia")) {
                    Picker(selection: $settings.theme) {
                        ForEach(ThemeSetting.allCases) { Text($0.title).tag($0) }
                    } label: { Label(T("Theme", "Tema"), systemImage: "circle.lefthalf.filled") }

                    Picker(selection: $settings.language) {
                        ForEach(LanguageSetting.allCases) { Text($0.title).tag($0) }
                    } label: { Label(T("Language", "Idioma"), systemImage: "globe") }
                }

                Section {
                    Picker(selection: $settings.quality) {
                        ForEach(QualitySetting.allCases) { Text($0.title).tag($0) }
                    } label: { Label(T("Graphics", "Gráficos"), systemImage: "sparkles") }
                } header: {
                    Text(T("Performance", "Rendimiento"))
                } footer: {
                    Text(settings.quality == .auto
                         ? T("Auto starts at Balanced and lowers the detail by itself if the iPhone needs it. Now: \(model.engine.ui.activeQuality.title).",
                             "Auto empieza en Equilibrado y baja el detalle solo si el iPhone lo necesita. Ahora: \(model.engine.ui.activeQuality.title).")
                         : T("Eco saves battery. Ultra adds finer sand and longer shadows.",
                             "Eco ahorra batería. Ultra agrega arena más fina y sombras más largas."))
                }

                Section(T("Data", "Datos")) {
                    Button(role: .destructive) {
                        Feedback.tap()
                        confirmDelete = true
                    } label: {
                        Label(T("Delete all gardens and records", "Borrar jardines y récords"), systemImage: "trash")
                    }
                }

                Section(T("About", "Acerca de")) {
                    HStack {
                        Label(T("Version", "Versión"), systemImage: "info.circle")
                        Spacer()
                        Text(model.settings.appVersion).foregroundStyle(.secondary)
                    }
                    Link(destination: URL(string: "https://blubergames.com")!) {
                        HStack {
                            Label(T("Website", "Sitio web"), systemImage: "safari")
                            Spacer()
                            Text("blubergames.com").foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://blubergames.com/support/")!) {
                        HStack {
                            Label(T("Support", "Soporte"), systemImage: "lifepreserver")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .tint(ZenPalette.moss)
        .onChange(of: settings.soundOn) { _, _ in HapticsManager.shared.selection() }
        .onChange(of: settings.hapticsOn) { _, on in if on { HapticsManager.shared.selection() } }
        .onChange(of: settings.theme) { _, _ in HapticsManager.shared.selection() }
        .onChange(of: settings.language) { _, _ in HapticsManager.shared.selection() }
        .onChange(of: settings.quality) { _, _ in HapticsManager.shared.selection() }
        .alert(T("Delete everything?", "¿Borrar todo?"), isPresented: $confirmDelete) {
            Button(T("Delete", "Borrar"), role: .destructive) { model.deleteAllData() }
            Button(T("Cancel", "Cancelar"), role: .cancel) {}
        } message: {
            Text(T("Your saved gardens and records will be removed. This cannot be undone.",
                   "Se borrarán tus jardines guardados y tus récords. No se puede deshacer."))
        }
        .presentationDragIndicator(.visible)
    }
}

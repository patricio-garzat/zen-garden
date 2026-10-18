import SwiftUI
import Observation

enum AppPhase: Equatable { case bluberIntro, gameIntro, home, garden }

enum AppSheet: String, Identifiable {
    case settings, howToPlay, records, gallery
    var id: String { rawValue }
}

/// App-level navigation: Intro → Home → Free Garden, plus the sheets.
@Observable
final class AppModel {
    var phase: AppPhase = .bluberIntro
    var sheet: AppSheet?
    let settings = SettingsManager.shared
    let progression = GameProgression.shared
    @ObservationIgnored let engine: GardenEngine

    init() {
        AudioManager.shared.start()
        HapticsManager.shared.prepare()
        engine = GardenEngine()
    }

    func bluberIntroFinished() {
        withAnimation(.easeInOut(duration: 0.7)) { phase = .gameIntro }
        engine.playIntro { [weak self] in
            withAnimation(.easeInOut(duration: 0.8)) { self?.phase = .home }
        }
    }

    func enterGarden() {
        engine.enterFreeGarden()
        withAnimation(.easeInOut(duration: 0.45)) { phase = .garden }
    }

    func goHome() {
        engine.inputEnabled = false
        engine.saveCurrent()
        withAnimation(.easeInOut(duration: 0.45)) { phase = .home }
    }

    func openGallery(_ id: UUID) {
        sheet = nil
        engine.openFromGallery(id)
        engine.inputEnabled = true
        withAnimation(.easeInOut(duration: 0.45)) { phase = .garden }
    }

    func deleteAllData() {
        GardenStore.shared.deleteAll()
        progression.reset()
        engine.resetEverything()
    }

    func handleScenePhase(_ p: ScenePhase) {
        switch p {
        case .background:
            engine.suspend()
            progression.saveNow()
            AudioManager.shared.suspend()
            HapticsManager.shared.suspend()
        case .active:
            AudioManager.shared.resume()
            HapticsManager.shared.resume()
            engine.resume()
        default:
            break
        }
    }
}

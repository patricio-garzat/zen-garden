import Foundation
import Observation
import SwiftUI

enum ThemeSetting: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .auto: return nil; case .light: return .light; case .dark: return .dark }
    }
    var title: String {
        switch self { case .auto: return T("Auto", "Auto"); case .light: return T("Light", "Claro"); case .dark: return T("Dark", "Oscuro") }
    }
}

enum LanguageSetting: String, CaseIterable, Identifiable {
    case en, es
    var id: String { rawValue }
    var title: String { self == .en ? "English" : "Español" }
}

enum QualitySetting: String, CaseIterable, Identifiable {
    case auto, eco, balanced, ultra
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return T("Auto", "Auto")
        case .eco: return "Eco"
        case .balanced: return T("Balanced", "Equilibrado")
        case .ultra: return "Ultra"
        }
    }
}

enum QualityLevel: Int, Comparable {
    case eco = 0, balanced, ultra
    static func < (a: QualityLevel, b: QualityLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self { case .eco: return "Eco"; case .balanced: return T("Balanced", "Equilibrado"); case .ultra: return "Ultra" }
    }
    /// Heightmap width in texels (the length follows the garden's proportions).
    var resolution: Int { [512, 768, 1024][rawValue] }
    var shadowSteps: Int { [0, 8, 12][rawValue] }
    var particleCap: Int { [40, 110, 220][rawValue] }
    var undoDepth: Int { [10, 12, 10][rawValue] }
    var glints: Float { [0.0, 1.0, 1.0][rawValue] }
}

/// User preferences, persisted in UserDefaults.
@Observable
final class SettingsManager {
    static let shared = SettingsManager()
    @ObservationIgnored private let d = UserDefaults.standard

    var soundOn: Bool { didSet { d.set(soundOn, forKey: "soundOn"); AudioManager.shared.applySettings() } }
    var volume: Double { didSet { d.set(volume, forKey: "volume"); AudioManager.shared.applySettings() } }
    var hapticsOn: Bool { didSet { d.set(hapticsOn, forKey: "hapticsOn") } }
    var hapticIntensity: Double { didSet { d.set(hapticIntensity, forKey: "hapticIntensity") } }
    var theme: ThemeSetting { didSet { d.set(theme.rawValue, forKey: "theme") } }
    var language: LanguageSetting { didSet { d.set(language.rawValue, forKey: "language") } }
    var quality: QualitySetting { didSet { d.set(quality.rawValue, forKey: "quality") } }

    private init() {
        d.register(defaults: [
            "soundOn": true, "volume": 0.85, "hapticsOn": true, "hapticIntensity": 0.7,
            "theme": ThemeSetting.auto.rawValue, "language": LanguageSetting.en.rawValue,
            "quality": QualitySetting.auto.rawValue,
        ])
        soundOn = d.bool(forKey: "soundOn")
        volume = d.double(forKey: "volume")
        hapticsOn = d.bool(forKey: "hapticsOn")
        hapticIntensity = d.double(forKey: "hapticIntensity")
        theme = ThemeSetting(rawValue: d.string(forKey: "theme") ?? "") ?? .auto
        language = LanguageSetting(rawValue: d.string(forKey: "language") ?? "") ?? .en
        quality = QualitySetting(rawValue: d.string(forKey: "quality") ?? "") ?? .auto
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

/// Inline localisation: English by default, Spanish from Settings. Reading the language here
/// registers an Observation dependency, so every view re-renders when it changes.
func T(_ en: String, _ es: String) -> String {
    SettingsManager.shared.language == .es ? es : en
}

import Foundation

enum ToolKind: String, CaseIterable, Codable, Identifiable {
    case fineRake, wideRake, waveRake, smoother
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fineRake: return T("Fine rake", "Rastrillo fino")
        case .wideRake: return T("Wide rake", "Rastrillo ancho")
        case .waveRake: return T("Wave rake", "Rastrillo de ondas")
        case .smoother: return T("Smoother", "Alisador")
        }
    }

    var spec: ToolSpec {
        switch self {
        case .fineRake: return .fine
        case .wideRake: return .wide
        case .waveRake: return .wave
        case .smoother: return .smoother
        }
    }
}

/// Physical description of a tool, in world units (the sand is 1.0 wide, about 1 m).
/// Tweak these numbers to change how each rake feels; nothing else needs to change.
struct ToolSpec {
    /// Number of tines (0 for the smoother).
    var tines: Int
    /// Distance between tines.
    var spacing: Float
    /// Groove amplitude (height of ridges above / depth of grooves below flat sand).
    var depth: Float
    /// How far the rake head trails the finger. Bigger = smoother, more flowing curves.
    var leash: Float
    /// How strongly each stamp reshapes the sand (0...1).
    var strength: Float
    /// Smoother only: radius of the board and how much one pass flattens.
    var radius: Float = 0
    var passFlatten: Float = 0

    var halfWidth: Float { tines > 0 ? Float(tines) * spacing * 0.5 : radius }

    static let fine = ToolSpec(tines: 8, spacing: 0.0105, depth: 0.0019, leash: 0.012, strength: 0.6)
    static let wide = ToolSpec(tines: 5, spacing: 0.024, depth: 0.0042, leash: 0.016, strength: 0.6)
    static let wave = ToolSpec(tines: 4, spacing: 0.016, depth: 0.0030, leash: 0.045, strength: 0.6)
    static let smoother = ToolSpec(tines: 0, spacing: 0, depth: 0, leash: 0, strength: 0, radius: 0.055, passFlatten: 0.45)

    /// Concentric ripples made by tapping with the wave rake.
    static let ringSpacing: Float = 0.016
    static let ringDepth: Float = 0.0030
    static let ringCount: Float = 6
}

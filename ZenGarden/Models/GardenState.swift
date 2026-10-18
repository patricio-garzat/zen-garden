import Foundation
import simd

/// A stone resting in the garden. Positions are in world units (the sand is 1.0 wide).
struct StoneState: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: Int
    var x: Float
    var y: Float
    var rotation: Float
    var scale: Float

    var position: SIMD2<Float> {
        get { SIMD2(x, y) }
        set { x = newValue.x; y = newValue.y }
    }
}

enum SandType: String, Codable, CaseIterable {
    case warmWhite
    // Future: .riverGrey, .goldenDune, .volcanic (Phase 3 unlockables)
}

/// Everything needed to rebuild a garden, except the heightmap (stored next to it as binary).
struct GardenDocument: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var created: Date = Date()
    var modified: Date = Date()
    var sandType: SandType = .warmWhite
    var stones: [StoneState] = []
    var heightWidth: Int = 0
    var heightHeight: Int = 0
    /// When the current garden was opened from (or saved to) the gallery, its gallery id.
    var galleryID: UUID?
    var formatVersion: Int = 1
}

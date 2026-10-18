import Foundation
import Observation

/// The small slice of engine state the SwiftUI layer observes.
@Observable
final class GardenUIState {
    struct Toast: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let symbol: String
    }

    var tool: ToolKind = .fineRake
    var interacting = false
    var canUndo = false
    var canRedo = false
    var stoneCount = 0
    var activeQuality: QualityLevel = .balanced
    var toast: Toast?
    var busy = false
}

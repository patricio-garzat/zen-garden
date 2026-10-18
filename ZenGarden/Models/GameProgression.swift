import Foundation
import Observation

/// Relaxed progression. Phase 1 records what the player does (shown in Records);
/// Zen Points and unlockables build on these numbers in Phase 3.
@Observable
final class GameProgression {
    static let shared = GameProgression()

    struct Stats: Codable, Equatable {
        var strokes = 0
        var distance: Double = 0          // world units raked (1 unit ≈ 1 m)
        var stonesPlaced = 0
        var ripples = 0
        var smooths = 0
        var gardensSaved = 0
        var secondsRaking: Double = 0
        var zenPoints = 0
        var firstPlayed: Date?
    }

    private(set) var stats: Stats
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let key = "progression.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let s = try? JSONDecoder().decode(Stats.self, from: data) {
            stats = s
        } else {
            stats = Stats()
        }
    }

    func record(_ change: (inout Stats) -> Void) {
        change(&stats)
        if stats.firstPlayed == nil { stats.firstPlayed = Date() }
        scheduleSave()
    }

    func reset() {
        stats = Stats()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: key) }
    }
}

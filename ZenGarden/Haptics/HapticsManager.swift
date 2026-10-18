import CoreHaptics
import UIKit

/// Core Haptics with a UIKit fallback. Everything is scaled by the user's intensity setting
/// and kept deliberately subtle: the goal is to *feel* the sand, not to buzz.
final class HapticsManager {
    static let shared = HapticsManager()

    private var engine: CHHapticEngine?
    private var continuous: CHHapticAdvancedPatternPlayer?
    private var continuousRunning = false
    private var lastGrain: CFTimeInterval = 0
    private let supports = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private let softFallback = UIImpactFeedbackGenerator(style: .soft)
    private let lightFallback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFallback = UISelectionFeedbackGenerator()

    private init() {}

    private var enabled: Bool { SettingsManager.shared.hapticsOn }
    private var scale: Float { Float(SettingsManager.shared.hapticIntensity) }

    func prepare() {
        guard supports else { softFallback.prepare(); return }
        do {
            let e = try CHHapticEngine()
            e.playsHapticsOnly = true
            e.isAutoShutdownEnabled = true
            e.resetHandler = { [weak self] in
                guard let self else { return }
                try? self.engine?.start()
                self.continuous = nil
                self.continuousRunning = false
            }
            e.stoppedHandler = { [weak self] _ in
                self?.continuous = nil
                self?.continuousRunning = false
            }
            try e.start()
            engine = e
        } catch {
            engine = nil
        }
    }

    func suspend() {
        endContinuous()
        engine?.stop(completionHandler: nil)
    }

    func resume() {
        guard supports else { return }
        if engine == nil { prepare() } else { try? engine?.start() }
    }

    // MARK: - Transients

    private func transient(intensity: Float, sharpness: Float) {
        guard enabled else { return }
        let i = max(0, min(1, intensity * scale))
        guard i > 0.01 else { return }
        guard supports, let engine else {
            softFallback.impactOccurred(intensity: CGFloat(i))
            return
        }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    /// Light tap for every button.
    func uiTap() {
        guard enabled else { return }
        if supports { transient(intensity: 0.32, sharpness: 0.35) } else { lightFallback.impactOccurred(intensity: CGFloat(0.5 * scale)) }
    }

    func selection() {
        guard enabled else { return }
        if supports { transient(intensity: 0.4, sharpness: 0.3) } else { selectionFallback.selectionChanged() }
    }

    /// A stone touching the sand: intensity grows with its size and the fall.
    func stoneImpact(size: Float, strength: Float) {
        transient(intensity: 0.35 + 0.45 * size * strength, sharpness: 0.18 + 0.1 * (1 - size))
    }

    func stoneLift() { transient(intensity: 0.22, sharpness: 0.2) }

    /// A single sand grain passing under a tine. Rate-limited so it never becomes a buzz.
    func grain(_ intensity: Float) {
        let now = CACurrentMediaTime()
        guard now - lastGrain > 0.04 else { return }
        lastGrain = now
        transient(intensity: intensity, sharpness: 0.45)
    }

    func ringTick() { transient(intensity: 0.2, sharpness: 0.25) }

    /// Reward: three soft pulses rising gently.
    func patternComplete() {
        guard enabled else { return }
        guard supports, let engine else { softFallback.impactOccurred(intensity: CGFloat(0.6 * scale)); return }
        let events = (0..<3).map { k in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: (0.3 + 0.15 * Float(k)) * scale),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ], relativeTime: Double(k) * 0.13)
        }
        do {
            try engine.start()
            try engine.makePlayer(with: CHHapticPattern(events: events, parameters: [])).start(atTime: CHHapticTimeImmediate)
        } catch {}
    }

    // MARK: - Continuous (raking / smoothing)

    func beginContinuous(intensity: Float, sharpness: Float) {
        guard enabled, supports, let engine else { return }
        if continuous == nil {
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
            ], relativeTime: 0, duration: 30)
            do {
                let p = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                p.loopEnabled = true
                continuous = p
            } catch { return }
        }
        do {
            try engine.start()
            if !continuousRunning {
                try continuous?.start(atTime: CHHapticTimeImmediate)
                continuousRunning = true
            }
        } catch {}
        updateContinuous(intensity: intensity, sharpness: sharpness)
    }

    func updateContinuous(intensity: Float, sharpness: Float) {
        guard continuousRunning, let continuous else { return }
        let i = enabled ? max(0, min(1, intensity * scale)) : 0
        try? continuous.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: i, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness - 0.5, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    func endContinuous() {
        guard continuousRunning else { return }
        continuousRunning = false
        try? continuous?.stop(atTime: CHHapticTimeImmediate)
    }
}

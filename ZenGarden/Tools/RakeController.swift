import UIKit
import simd

/// Turns touches into tool strokes, stone drags and ripple taps.
///
/// Strokes use a "lazy brush": the rake head trails the finger on a short leash, which turns
/// shaky finger paths into the calm, flowing curves a real rake leaves. The head's angle
/// follows its own motion, so the tines always sit perpendicular to the stroke.
final class RakeController {
    private unowned let engine: GardenEngine

    private enum Mode { case idle, rake, stone(UUID) }
    private var mode: Mode = .idle
    private var primary: UITouch?
    private var secondary: UITouch?
    private var lastTwist: Float = 0

    private var head = SIMD2<Float>.zero
    private var angle: Float = 0
    private var hasDirection = false
    private(set) var stampedThisStroke = false
    private var startTime: TimeInterval = 0
    private var startPoint = CGPoint.zero
    private var maxTravel: CGFloat = 0
    private var frameDistance: Float = 0
    private var smoothedSpeed: Float = 0
    private var strokeTime: Float = 0
    private var tickDistance: Float = 0
    private var grabOffset = SIMD2<Float>.zero
    // Finger path smoothing (quadratic curves through the midpoints of the samples).
    private var lastSample = SIMD2<Float>.zero
    private var lastMid = SIMD2<Float>.zero

    init(engine: GardenEngine) { self.engine = engine }

    var isActive: Bool { if case .idle = mode { return false } else { return true } }
    var isRaking: Bool { if case .rake = mode { return true } else { return false } }
    /// 0...1, perceptual speed of the tool.
    var speed: Float { 1 - exp(-smoothedSpeed / 0.55) }
    var headPosition: SIMD2<Float> { head }
    var headAngle: Float { angle }
    var currentStrokeTime: Float { strokeTime }

    // MARK: - Touches

    func touchesBegan(_ touches: Set<UITouch>, in view: UIView) {
        for t in touches {
            if primary == nil {
                primary = t
                begin(t, view)
            } else if secondary == nil, case .stone = mode {
                secondary = t
                lastTwist = twistAngle(view)
            }
        }
    }

    func touchesMoved(_ touches: Set<UITouch>, event: UIEvent?, in view: UIView) {
        if let p = primary, touches.contains(p) {
            let samples = event?.coalescedTouches(for: p) ?? [p]
            for s in samples { process(s.location(in: view)) }
        }
        if secondary != nil, case let .stone(id) = mode {
            let a = twistAngle(view)
            engine.rotateStone(id, by: wrapAngle(a - lastTwist))
            lastTwist = a
        }
    }

    func touchesEnded(_ touches: Set<UITouch>, in view: UIView, cancelled: Bool) {
        if let s = secondary, touches.contains(s) { secondary = nil }
        guard let p = primary, touches.contains(p) else { return }
        let tap = !cancelled && maxTravel < 10 && (p.timestamp - startTime) < 0.35
        switch mode {
        case .rake:
            if !cancelled { finishCurve() }
            if tap && !stampedThisStroke && engine.tool == .waveRake {
                engine.ripple(at: engine.ground(startPoint), around: nil)
            }
            engine.strokeEnded()
        case let .stone(id):
            engine.releaseStone(id, tapped: tap)
        case .idle:
            break
        }
        mode = .idle
        primary = nil
        secondary = nil
        smoothedSpeed = 0
    }

    func cancelAll() {
        if case .rake = mode { engine.strokeEnded() }
        if case let .stone(id) = mode { engine.releaseStone(id, tapped: false) }
        mode = .idle
        primary = nil
        secondary = nil
    }

    private func begin(_ t: UITouch, _ view: UIView) {
        let p = t.location(in: view)
        startPoint = p
        startTime = t.timestamp
        maxTravel = 0
        if let id = engine.stones.hitTest({ z in self.engine.ground(p, z: z) }) {
            mode = .stone(id)
            let w = engine.ground(p)
            if let s = engine.stones.state(id) { grabOffset = s.position - w }
            engine.grabStone(id)
        } else {
            mode = .rake
            let w = engine.ground(p)
            lastSample = w
            lastMid = w
            head = clampToGarden(w)
            hasDirection = false
            stampedThisStroke = false
            strokeTime = 0
            smoothedSpeed = 0
            frameDistance = 0
            tickDistance = 0
            engine.strokeBegan()
        }
    }

    private func process(_ point: CGPoint) {
        maxTravel = max(maxTravel, hypot(point.x - startPoint.x, point.y - startPoint.y))
        switch mode {
        case .rake: follow(engine.ground(point))
        case let .stone(id): engine.dragStone(id, to: engine.ground(point) + grabOffset)
        case .idle: break
        }
    }

    private func twistAngle(_ view: UIView) -> Float {
        guard let a = primary, let b = secondary else { return 0 }
        let wa = engine.ground(a.location(in: view)), wb = engine.ground(b.location(in: view))
        return atan2(wb.y - wa.y, wb.x - wa.x)
    }

    // MARK: - Stroke geometry

    private func clampToGarden(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let lim = GardenEngine.gardenHalf + engine.tool.spec.halfWidth
        return SIMD2(clampf(p.x, -lim.x, lim.x), clampf(p.y, -lim.y, lim.y))
    }

    /// Feeds the rake along a quadratic curve from the previous midpoint to the new one, with the
    /// previous sample as control point: corners in the raw finger path become smooth arcs, even
    /// when the touch samples are far apart.
    private func follow(_ p: SIMD2<Float>) {
        let m1 = (lastSample + p) * 0.5
        let approx = simd_length(lastSample - lastMid) + simd_length(m1 - lastSample)
        let n = min(240, max(1, Int(approx / (engine.sim.texelWorld * 1.5))))
        for i in 1...n {
            let t = Float(i) / Float(n), u = 1 - t
            rake(toward: lastMid * (u * u) + lastSample * (2 * u * t) + m1 * (t * t))
        }
        lastSample = p
        lastMid = m1
    }

    private func finishCurve() {
        let d = lastSample - lastMid
        let n = min(120, max(1, Int(simd_length(d) / (engine.sim.texelWorld * 1.5))))
        for i in 1...n { rake(toward: lastMid + d * (Float(i) / Float(n))) }
        lastMid = lastSample
    }

    private func rake(toward finger: SIMD2<Float>) {
        let spec = engine.tool.spec
        let f = clampToGarden(finger)
        let d = f - head
        let dist = simd_length(d)
        let target: SIMD2<Float>
        if spec.leash > 0 {
            guard dist > spec.leash else { return }
            target = f - d / dist * spec.leash
        } else {
            guard dist > engine.sim.texelWorld * 0.35 else { return }
            target = f
        }
        moveHead(to: target)
    }

    private func moveHead(to target: SIMD2<Float>) {
        let m = target - head
        let len = simd_length(m)
        guard len > 1e-6 else { return }
        let moveAngle = atan2(m.y, m.x)
        let newAngle: Float
        if !hasDirection {
            angle = moveAngle
            newAngle = moveAngle
            hasDirection = true
        } else {
            let k = min(1, len / (engine.sim.texelWorld * 3))
            newAngle = angle + wrapAngle(moveAngle - angle) * k
        }
        engine.emitToolStamps(from: head, angle: angle, to: target, angle: newAngle)
        stampedThisStroke = true
        frameDistance += len
        tickDistance += len
        head = target
        angle = newAngle
    }

    // MARK: - Per frame

    func update(dt: Float) {
        guard case .rake = mode else { return }
        strokeTime += dt
        let instant = frameDistance / max(dt, 1e-3)
        smoothedSpeed += (instant - smoothedSpeed) * (1 - exp(-dt * 14))
        let moved = frameDistance
        frameDistance = 0
        var ticks = 0
        let spacing = max(engine.tool.spec.spacing, 0.012) * 1.6
        while tickDistance > spacing { tickDistance -= spacing; ticks += 1 }
        engine.strokeFeedback(dt: dt, moved: moved, ticks: ticks)
    }
}

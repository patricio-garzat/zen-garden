import Metal
import simd

/// Stones in the garden: placement, lifting, dragging, rotating, dropping and removal.
/// Animations are physical but calm: stones fall with gravity and settle without bouncing.
final class StoneManager {
    enum Phase { case resting, held, falling, leaving }

    struct Stone {
        var state: StoneState
        var z: Float = 0
        var vz: Float = 0
        var alpha: Float = 1
        var targetAlpha: Float = 1
        var phase: Phase = .resting
        var target: SIMD2<Float>
        var settle: Float = 1          // 0...1 progress of the little press into the sand
        var removalArmed = false
        var fallHeight: Float = 0
    }

    enum Event {
        case landed(StoneState, strength: Float)
        case removed(StoneState)
    }

    static let maxStones = 16
    static let liftHeight: Float = 0.035
    private static let gravity: Float = 4.5

    let meshes: [StoneMesh]
    private(set) var stones: [Stone] = []
    private let gardenHalf: SIMD2<Float>
    private let removeMargin: Float

    init(device: MTLDevice, gardenHalf: SIMD2<Float>, frameWidth: Float) {
        meshes = StoneCatalog.all.map { StoneMeshFactory.make($0, device: device) }
        self.gardenHalf = gardenHalf
        removeMargin = frameWidth * 0.35
    }

    var states: [StoneState] { stones.filter { $0.phase != .leaving }.map(\.state) }
    var count: Int { stones.filter { $0.phase != .leaving }.count }
    var isAnimating: Bool { stones.contains { $0.phase != .resting || $0.settle < 1 || abs($0.alpha - $0.targetAlpha) > 0.001 } }

    func footprintRadii(_ s: StoneState) -> SIMD2<Float> { meshes[s.type].footprint * s.scale }
    func topHeight(_ s: StoneState) -> Float { meshes[s.type].top * s.scale }

    // MARK: - Placement

    /// Adds a stone that falls from above onto `position`.
    @discardableResult
    func add(type: Int, at position: SIMD2<Float>, rotation: Float, scale: Float, dropFrom: Float = 0.07) -> StoneState? {
        guard count < Self.maxStones else { return nil }
        let st = StoneState(type: type, x: position.x, y: position.y, rotation: rotation, scale: scale)
        var s = Stone(state: st, target: position)
        s.z = dropFrom
        s.fallHeight = dropFrom
        s.alpha = 0
        s.targetAlpha = 1
        s.phase = .falling
        stones.append(s)
        return st
    }

    /// A free spot near the middle, as far as possible from the other stones.
    func freeSpot(rng: inout SeededRandom) -> SIMD2<Float> {
        var best = SIMD2<Float>(0, 0.1), bestScore: Float = -1
        for _ in 0..<40 {
            let p = SIMD2(rng.range(-0.3, 0.3), rng.range(-0.55, 0.55))
            var d: Float = 1
            for s in stones where s.phase != .leaving { d = min(d, simd_length(s.state.position - p)) }
            let score = d - simd_length(p) * 0.15
            if score > bestScore { bestScore = score; best = p }
        }
        return best
    }

    /// Replaces all stones (undo/redo). No animation, no events.
    func restore(_ states: [StoneState]) {
        stones = states.map { var s = Stone(state: $0, target: $0.position); s.settle = 1; return s }
    }

    /// Replaces all stones with a short animation (opening a saved garden).
    func transition(to states: [StoneState]) {
        for i in stones.indices { stones[i].phase = .leaving; stones[i].targetAlpha = 0 }
        for (k, st) in states.enumerated() {
            var s = Stone(state: st, target: st.position)
            s.z = 0.05 + Float(k) * 0.012
            s.fallHeight = s.z
            s.alpha = 0
            s.phase = .falling
            stones.append(s)
        }
    }

    func removeAll(animated: Bool) {
        if animated {
            for i in stones.indices { stones[i].phase = .leaving; stones[i].targetAlpha = 0 }
        } else {
            stones.removeAll()
        }
    }

    // MARK: - Interaction

    /// Finds the stone under a screen point. `ground(z)` maps the touch to the plane at height z,
    /// so tall stones can be grabbed by their visible top, not only by their base.
    func hitTest(_ ground: (Float) -> SIMD2<Float>) -> UUID? {
        for s in stones.reversed() where s.phase == .resting || s.phase == .falling {
            let st = s.state
            let w = ground(topHeight(st) * 0.55)
            let d = w - st.position
            let c = cos(st.rotation), sn = sin(st.rotation)
            let local = SIMD2(d.x * c + d.y * sn, -d.x * sn + d.y * c)
            let r = footprintRadii(st) * 1.25 + 0.012
            if simd_length(local / r) < 1 { return st.id }
        }
        return nil
    }

    func state(_ id: UUID) -> StoneState? { stones.first { $0.state.id == id }?.state }

    func grab(_ id: UUID) {
        guard let i = index(id) else { return }
        stones[i].phase = .held
        stones[i].target = stones[i].state.position
        stones[i].vz = 0
    }

    func drag(_ id: UUID, to p: SIMD2<Float>) {
        guard let i = index(id) else { return }
        let limit = gardenHalf + 0.12
        let clamped = SIMD2(clampf(p.x, -limit.x, limit.x), clampf(p.y, -limit.y, limit.y))
        stones[i].target = clamped
        let outside = abs(clamped.x) > gardenHalf.x + removeMargin || abs(clamped.y) > gardenHalf.y + removeMargin
        stones[i].removalArmed = outside
        stones[i].targetAlpha = outside ? 0.45 : 1
    }

    func rotate(_ id: UUID, by delta: Float) {
        guard let i = index(id) else { return }
        stones[i].state.rotation += delta
    }

    /// Lets go of a held stone. Returns true if it is being removed.
    @discardableResult
    func release(_ id: UUID) -> Bool {
        guard let i = index(id) else { return false }
        if stones[i].removalArmed {
            stones[i].phase = .leaving
            stones[i].targetAlpha = 0
            return true
        }
        // Keep it inside the sand.
        let r = footprintRadii(stones[i].state)
        let lim = gardenHalf - r * 0.8
        var p = stones[i].target
        p.x = clampf(p.x, -lim.x, lim.x)
        p.y = clampf(p.y, -lim.y, lim.y)
        stones[i].target = p
        stones[i].phase = .falling
        stones[i].fallHeight = max(stones[i].z, 0.004)
        return false
    }

    private func index(_ id: UUID) -> Int? { stones.firstIndex { $0.state.id == id } }

    // MARK: - Simulation

    func update(dt: Float) -> [Event] {
        var events: [Event] = []
        var i = 0
        while i < stones.count {
            var s = stones[i]
            s.alpha = damp(s.alpha, s.targetAlpha, rate: s.phase == .leaving ? 9 : 14, dt: dt)
            switch s.phase {
            case .held:
                s.z = damp(s.z, Self.liftHeight, rate: 14, dt: dt)
                s.state.position = damp(s.state.position, s.target, rate: 22, dt: dt)
            case .falling:
                s.state.position = damp(s.state.position, s.target, rate: 26, dt: dt)
                s.vz -= Self.gravity * dt
                s.z += s.vz * dt
                if s.z <= 0 {
                    s.z = 0
                    let strength = min(1, max(0.25, sqrt(s.fallHeight / 0.05)))
                    s.vz = 0
                    s.phase = .resting
                    s.settle = 0
                    s.state.position = s.target
                    events.append(.landed(s.state, strength: strength))
                }
            case .leaving:
                s.z = damp(s.z, Self.liftHeight * 1.4, rate: 6, dt: dt)
                if s.alpha < 0.02 {
                    events.append(.removed(s.state))
                    stones.remove(at: i)
                    continue
                }
            case .resting:
                break
            }
            if s.settle < 1 { s.settle = min(1, s.settle + dt / 0.2) }
            stones[i] = s
            i += 1
        }
        return events
    }

    /// Footprints of resting stones, in heightmap texels.
    func footprints(sim: SandSimulation) -> [Footprint] {
        stones.compactMap { s in
            guard s.phase == .resting, s.alpha > 0.5 else { return nil }
            let c = sim.toTexel(s.state.position)
            let r = footprintRadii(s.state) / sim.texelWorld
            return Footprint(a: SIMD4(c.x, c.y, r.x, r.y), b: SIMD4(cos(s.state.rotation), sin(s.state.rotation), 0, 0))
        }
    }

    // MARK: - GPU

    func gpuData() -> [StoneGPU] {
        stones.map { s in
            let type = StoneCatalog.all[s.state.type]
            let sink = -0.0012 * sin(.pi * s.settle) * s.state.scale
            let lift = s.z + (s.settle < 1 ? sink : 0)
            let model = simd_float4x4.translation(SIMD3(s.state.x, s.state.y, lift))
                * simd_float4x4.rotationZ(s.state.rotation)
                * simd_float4x4.scale(s.state.scale)
            let c = cos(s.state.rotation), sn = sin(s.state.rotation)
            let r = footprintRadii(s.state)
            var g = StoneGPU()
            g.model = model
            g.n0 = SIMD4(c, sn, 0, 0)
            g.n1 = SIMD4(-sn, c, 0, 0)
            g.n2 = SIMD4(0, 0, 1, 0)
            g.colorA = SIMD4(type.colorA, 1)
            g.colorB = SIMD4(type.colorB, 1)
            g.colorC = SIMD4(type.colorC, 1)
            g.material = SIMD4(type.material, Float(type.seed) * 0.37 + Float(s.state.id.hashValue & 0xFF) * 0.01)
            g.foot = SIMD4(s.state.x, s.state.y, r.x, r.y)
            g.rot = SIMD4(c, sn, topHeight(s.state), max(0, s.z))
            g.state = SIMD4(s.alpha, s.phase == .resting ? 1 : 0, 0, 0)
            return g
        }
    }
}

import Metal
import simd

/// Tiny grains of sand kicked up by the tools. Fixed-size pool, no per-frame allocation.
/// They are an accent that sells contact, never the main effect.
final class ParticleSystem {
    struct Grain {
        var p: SIMD3<Float>
        var v: SIMD3<Float>
        var life: Float
        var maxLife: Float
        var size: Float
        var tint: Float
    }

    private(set) var grains: [Grain] = []
    var capacity = 110 { didSet { if grains.count > capacity { grains.removeLast(grains.count - capacity) } } }
    var color = SIMD3<Float>(0.80, 0.74, 0.63)
    private var rng = SeededRandom(seed: 7)
    static let gravity: Float = 2.6

    init() { grains.reserveCapacity(256) }

    var count: Int { grains.count }
    var random: Float { rng.unit() }

    func emit(at p: SIMD3<Float>, velocity v: SIMD3<Float>, life: Float, size: Float) {
        guard grains.count < capacity else { return }
        grains.append(Grain(p: p, v: v, life: 0, maxLife: life, size: size, tint: rng.range(0.86, 1.06)))
    }

    /// Grains thrown from a moving tool: a little forward, mostly up, a little sideways.
    func spray(at p: SIMD2<Float>, direction d: SIMD2<Float>, lateral n: SIMD2<Float>, speed: Float) {
        let side = rng.range(-1, 1)
        let up = rng.range(0.06, 0.16) * (0.6 + speed)
        let fwd = d * rng.range(0.02, 0.09) * (0.5 + speed)
        let lat = n * side * rng.range(0.01, 0.05)
        emit(at: SIMD3(p, 0.001), velocity: SIMD3(fwd + lat, up), life: rng.range(0.18, 0.38), size: rng.range(0.0011, 0.0022))
    }

    /// A small puff where a stone lands.
    func puff(at c: SIMD2<Float>, radii r: SIMD2<Float>, rotation: Float, amount: Int) {
        let cs = cos(rotation), sn = sin(rotation)
        for _ in 0..<amount {
            let a = rng.range(0, 2 * .pi)
            let local = SIMD2(cos(a) * r.x, sin(a) * r.y) * 1.05
            let w = SIMD2(local.x * cs - local.y * sn, local.x * sn + local.y * cs)
            let out = simd_length(w) > 0 ? normalize(w) : SIMD2(1, 0)
            emit(at: SIMD3(c + w, 0.001), velocity: SIMD3(out * rng.range(0.04, 0.12), rng.range(0.05, 0.14)),
                 life: rng.range(0.2, 0.4), size: rng.range(0.0012, 0.0024))
        }
    }

    func update(dt: Float) {
        var i = 0
        while i < grains.count {
            var g = grains[i]
            g.life += dt
            if g.life >= g.maxLife {
                grains.swapAt(i, grains.count - 1)
                grains.removeLast()
                continue
            }
            g.v.z -= Self.gravity * dt
            g.p += g.v * dt
            if g.p.z < 0.0006 && g.v.z < 0 {
                g.p.z = 0.0006
                g.v.z *= -0.2
                g.v.x *= 0.4
                g.v.y *= 0.4
            }
            grains[i] = g
            i += 1
        }
    }

    func clear() { grains.removeAll(keepingCapacity: true) }

    /// Writes GPU data into `buffer`, returns the number of instances.
    func write(to buffer: MTLBuffer) -> Int {
        let n = min(grains.count, buffer.length / MemoryLayout<ParticleGPU>.stride)
        let out = buffer.contents().bindMemory(to: ParticleGPU.self, capacity: n)
        for i in 0..<n {
            let g = grains[i]
            let t = g.life / g.maxLife
            let a = 1 - smoothstepf(0.55, 1, t)
            out[i] = ParticleGPU(posSize: SIMD4(g.p, g.size), color: SIMD4(color * g.tint, a))
        }
        return n
    }
}

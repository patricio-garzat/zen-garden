import Metal
import simd

/// The wooden frame: four planks with chamfered top edges, built from one extruded profile.
enum FrameMesh {
    static func make(device: MTLDevice, half: SIMD2<Float>, width F: Float, height H: Float) -> (MTLBuffer, Int) {
        let c: Float = min(0.006, F * 0.12)      // chamfer
        let bottom: Float = -0.03                // the table
        // Profile in (outward distance from the inner edge, height).
        let profile: [SIMD2<Float>] = [
            SIMD2(0, -0.004), SIMD2(0, H - c), SIMD2(c, H), SIMD2(F - c, H), SIMD2(F, H - c), SIMD2(F, bottom),
        ]
        var verts: [MeshVertex] = []

        /// Extrudes the profile along a plank. `origin` is the inner edge start, `along` the plank
        /// direction, `out` the outward direction; `length` in world units.
        func plank(origin: SIMD2<Float>, along: SIMD2<Float>, out: SIMD2<Float>, length: Float, seed: Float, caps: Bool) {
            func world(_ q: SIMD2<Float>, _ s: Float) -> SIMD3<Float> {
                let xy = origin + along * s + out * q.x
                return SIMD3(xy.x, xy.y, q.y)
            }
            var acc: Float = 0
            for k in 0..<(profile.count - 1) {
                let a = profile[k], b = profile[k + 1]
                let e = b - a
                let len = simd_length(e)
                // 2D normal of this face (pointing away from the plank's inside).
                let n2 = normalize(SIMD2(e.y, -e.x)) * -1
                let n = normalize(SIMD3(out * n2.x, 0) + SIMD3(0, 0, n2.y))
                let v0 = acc, v1 = acc + len
                acc = v1
                let p00 = world(a, 0), p01 = world(b, 0), p10 = world(a, length), p11 = world(b, length)
                let quad: [(SIMD3<Float>, Float, Float)] = [
                    (p00, 0, v0), (p10, length, v0), (p11, length, v1),
                    (p00, 0, v0), (p11, length, v1), (p01, 0, v1),
                ]
                for (p, u, v) in quad {
                    let alongCoord = dot(SIMD2(p.x, p.y), along)
                    verts.append(MeshVertex(position: SIMD4(p, 1), normal: SIMD4(n, 0), uv: SIMD4(alongCoord + u * 0, v, seed, 0)))
                }
            }
            guard caps else { return }
            // End caps (end grain), fan from the profile's centroid.
            for (s, dirSign) in [(Float(0), Float(-1)), (length, Float(1))] {
                let n = SIMD3(along * dirSign, 0)
                let centre = profile.reduce(SIMD2<Float>.zero, +) / Float(profile.count)
                for k in 0..<profile.count {
                    let a = profile[k], b = profile[(k + 1) % profile.count]
                    for q in [centre, a, b] {
                        let p = world(q, s)
                        verts.append(MeshVertex(position: SIMD4(p, 1), normal: SIMD4(n, 0), uv: SIMD4(q.x * 3, q.y * 3, seed + 0.5, 0)))
                    }
                }
            }
        }

        let ext = half.x + F
        // Far and near planks run the full width (their end grain shows at the corners).
        plank(origin: SIMD2(-ext, half.y), along: SIMD2(1, 0), out: SIMD2(0, 1), length: 2 * ext, seed: 0.13, caps: true)
        plank(origin: SIMD2(-ext, -half.y), along: SIMD2(1, 0), out: SIMD2(0, -1), length: 2 * ext, seed: 0.61, caps: true)
        // Side planks fit between them.
        plank(origin: SIMD2(-half.x, -half.y), along: SIMD2(0, 1), out: SIMD2(-1, 0), length: 2 * half.y, seed: 0.37, caps: false)
        plank(origin: SIMD2(half.x, -half.y), along: SIMD2(0, 1), out: SIMD2(1, 0), length: 2 * half.y, seed: 0.89, caps: false)

        let buffer = device.makeBuffer(bytes: verts, length: MemoryLayout<MeshVertex>.stride * verts.count, options: .storageModeShared)!
        buffer.label = "Frame"
        return (buffer, verts.count)
    }
}

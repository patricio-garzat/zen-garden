import Metal
import simd

/// GPU mesh for one stone type.
struct StoneMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    /// Footprint radii where the stone meets the sand (world units, before instance scale).
    let footprint: SIMD2<Float>
    /// Highest point above the sand.
    let top: Float
}

/// Builds organic stones: a subdivided icosphere displaced by fractal noise, squashed at the
/// bottom and sunk slightly into the sand. 642 vertices each: light, smooth and convincing.
enum StoneMeshFactory {
    static func make(_ type: StoneType, device: MTLDevice) -> StoneMesh {
        var (positions, triangles) = icosphere(subdivisions: 3)

        for i in positions.indices {
            let p = positions[i]
            var r: Float = 1 + type.roughness * (Noise.fbm3(p * type.frequency + Float(type.seed), seed: type.seed) - 0.5) * 2
            if type.facets > 0 {
                let ridged = abs(Noise.value3(p * type.frequency * 0.8 + 3.3, seed: type.seed &+ 5) - 0.5)
                r -= type.facets * ridged
            }
            var q = p * r * type.radii
            if q.z < 0 { q.z *= 0.35 }                  // flat-ish base
            q.z -= type.radii.z * 0.12                   // sits a little into the sand
            positions[i] = q
        }

        // Smooth normals from the faces.
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in triangles {
            let a = positions[Int(t.x)], b = positions[Int(t.y)], c = positions[Int(t.z)]
            let n = cross(b - a, c - a)
            normals[Int(t.x)] += n; normals[Int(t.y)] += n; normals[Int(t.z)] += n
        }

        var verts: [MeshVertex] = []
        verts.reserveCapacity(positions.count)
        var foot = SIMD2<Float>(0.001, 0.001)
        var top: Float = 0
        for i in positions.indices {
            let p = positions[i]
            let n = simd_length(normals[i]) > 0 ? normalize(normals[i]) : SIMD3(0, 0, 1)
            verts.append(MeshVertex(position: SIMD4(p, 1), normal: SIMD4(n, 0), uv: .zero))
            if abs(p.z) < type.radii.z * 0.25 { foot = max(foot, SIMD2(abs(p.x), abs(p.y))) }
            top = max(top, p.z)
        }
        let idx: [UInt16] = triangles.flatMap { [UInt16($0.x), UInt16($0.y), UInt16($0.z)] }

        let vb = device.makeBuffer(bytes: verts, length: MemoryLayout<MeshVertex>.stride * verts.count, options: .storageModeShared)!
        let ib = device.makeBuffer(bytes: idx, length: MemoryLayout<UInt16>.stride * idx.count, options: .storageModeShared)!
        vb.label = "Stone \(type.id)"
        return StoneMesh(vertices: vb, indices: ib, indexCount: idx.count, footprint: foot, top: top)
    }

    private static func icosphere(subdivisions: Int) -> ([SIMD3<Float>], [SIMD3<UInt32>]) {
        let t: Float = (1 + sqrt(5)) / 2
        var p: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ].map { normalize($0) }
        var f: [SIMD3<UInt32>] = [
            SIMD3(0, 11, 5), SIMD3(0, 5, 1), SIMD3(0, 1, 7), SIMD3(0, 7, 10), SIMD3(0, 10, 11),
            SIMD3(1, 5, 9), SIMD3(5, 11, 4), SIMD3(11, 10, 2), SIMD3(10, 7, 6), SIMD3(7, 1, 8),
            SIMD3(3, 9, 4), SIMD3(3, 4, 2), SIMD3(3, 2, 6), SIMD3(3, 6, 8), SIMD3(3, 8, 9),
            SIMD3(4, 9, 5), SIMD3(2, 4, 11), SIMD3(6, 2, 10), SIMD3(8, 6, 7), SIMD3(9, 8, 1),
        ]
        for _ in 0..<subdivisions {
            var cache: [UInt64: UInt32] = [:]
            func mid(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                if let m = cache[key] { return m }
                p.append(normalize((p[Int(a)] + p[Int(b)]) * 0.5))
                let i = UInt32(p.count - 1)
                cache[key] = i
                return i
            }
            var next: [SIMD3<UInt32>] = []
            next.reserveCapacity(f.count * 4)
            for tri in f {
                let a = mid(tri.x, tri.y), b = mid(tri.y, tri.z), c = mid(tri.z, tri.x)
                next += [SIMD3(tri.x, a, c), SIMD3(tri.y, b, a), SIMD3(tri.z, c, b), SIMD3(a, b, c)]
            }
            f = next
        }
        return (p, f)
    }
}

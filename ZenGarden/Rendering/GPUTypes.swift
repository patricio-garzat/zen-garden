import simd

// Every struct here has an identical twin in the .metal files. They only use 16-byte
// vector members so Swift and Metal agree on layout without a bridging header.

/// One imprint of a tool on the heightmap. Coordinates are in heightmap texels.
/// - rake:     a = (center.xy, dir.xy)  b = (halfWidth, tineSpacing, depth, strength)  c = (0, alongHalf, seed, 0)
/// - smooth:   a = (center.xy, 0, 0)    b = (radius, 0, 0, strength)                   c = (1, 0, 0, 0)
/// - stoneRim: a = (center.xy, 0, 0)    b = (radiusX, radiusY, rimHeight, rimWidth)    c = (2, 0, cos, sin)
/// - rings:    a = (center.xy, 0, 0)    b = (innerRadius, spacing, depth, strength)    c = (3, currentRadius, ringCount, 0)
struct Stamp {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>
}

enum StampKind: Float {
    case rake = 0, smooth = 1, stoneRim = 2, rings = 3
}

struct StampBatch {
    var count: UInt32 = 0
    var originX: UInt32 = 0
    var originY: UInt32 = 0
    var stoneCount: UInt32 = 0
    var sizeX: UInt32 = 0
    var sizeY: UInt32 = 0
    var pad0: UInt32 = 0
    var pad1: UInt32 = 0
}

/// Elliptical stone footprint in texels: a = (center.xy, radius.xy), b = (cos, sin, 0, 0).
struct Footprint {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
}

struct DeriveParams {
    var rect: SIMD4<Int32>      // x, y, width, height
    var light: SIMD4<Float>     // direction to the sun (xyz), shadow steps (w)
    var misc: SIMD4<Float>      // texel size (world), cavity scale, 0, 0
}

struct SweepParams {
    var a: SIMD4<Float>         // front (texel y), ridge width (texels), ridge height (world), 0
    var b: SIMD4<UInt32>        // first row, row count, stone count, 0
}

struct GridParams {
    var rect: SIMD4<UInt32>     // x, y, width, height
    var v: SIMD4<Float>
}

struct SceneUniforms {
    var viewProj = matrix_identity_float4x4
    var invViewProj = matrix_identity_float4x4
    var cameraPos = SIMD4<Float>(0, 0, 1, 1)
    var camRight = SIMD4<Float>(1, 0, 0, 0)
    var camUp = SIMD4<Float>(0, 1, 0, 0)
    var sunDir = SIMD4<Float>(0, 0, 1, 0)
    var sunColor = SIMD4<Float>(1, 1, 1, 1)
    var skyColor = SIMD4<Float>(0.3, 0.3, 0.3, 1)
    var groundColor = SIMD4<Float>(0.2, 0.2, 0.2, 1)
    var sandAlbedo = SIMD4<Float>(0.8, 0.75, 0.65, 1)
    var bgTop = SIMD4<Float>(0.8, 0.8, 0.8, 1)
    var bgBottom = SIMD4<Float>(0.7, 0.7, 0.7, 1)
    var garden = SIMD4<Float>(0.5, 0.95, 0.065, 0.04)    // halfW, halfL, frame width, frame height
    var params = SIMD4<Float>(1, 1, 0, 0)                 // normal strength, AO strength, stone count, time
    var hm = SIMD4<Float>(768, 1459, 0.0013, 100)        // width, height, texel size, cavity scale
    var misc = SIMD4<Float>(1, 0, 1, 0)                   // glints, dark, grain strength, 0
}

struct StoneGPU {
    var model = matrix_identity_float4x4
    var n0 = SIMD4<Float>(1, 0, 0, 0)
    var n1 = SIMD4<Float>(0, 1, 0, 0)
    var n2 = SIMD4<Float>(0, 0, 1, 0)
    var colorA = SIMD4<Float>(0.3, 0.3, 0.3, 1)
    var colorB = SIMD4<Float>(0.4, 0.4, 0.4, 1)
    var colorC = SIMD4<Float>(0.6, 0.6, 0.6, 1)
    var material = SIMD4<Float>(0, 0, 0, 0)   // flecks, moss, veins, seed
    var foot = SIMD4<Float>(0, 0, 0.05, 0.05) // world center.xy, radius.xy
    var rot = SIMD4<Float>(1, 0, 0.05, 0)     // cos, sin, top height, lift
    var state = SIMD4<Float>(1, 1, 0, 0)      // alpha, grounded, bottom z, 0
}

struct MeshVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD4<Float>
}

struct ParticleGPU {
    var posSize: SIMD4<Float>
    var color: SIMD4<Float>
}

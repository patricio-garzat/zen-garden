import Foundation
import simd

// MARK: - Matrices

extension simd_float4x4 {
    /// Right-handed perspective projection with Metal's 0...1 depth range.
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(target - eye)
        let s = normalize(cross(f, up))
        let u = cross(s, f)
        return simd_float4x4(columns: (
            SIMD4<Float>(s.x, u.x, -f.x, 0),
            SIMD4<Float>(s.y, u.y, -f.y, 0),
            SIMD4<Float>(s.z, u.z, -f.z, 0),
            SIMD4<Float>(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)
        ))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func rotationZ(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func scale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
    }
}

// MARK: - Scalar helpers

@inline(__always) func clampf(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }
@inline(__always) func saturate(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) func lerpf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

@inline(__always) func smoothstepf(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = saturate((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}

/// Frame-rate independent exponential approach (critically damped feel, never overshoots).
@inline(__always) func damp(_ current: Float, _ target: Float, rate: Float, dt: Float) -> Float {
    current + (target - current) * (1 - exp(-rate * dt))
}

@inline(__always) func damp(_ current: SIMD2<Float>, _ target: SIMD2<Float>, rate: Float, dt: Float) -> SIMD2<Float> {
    current + (target - current) * (1 - exp(-rate * dt))
}

/// Wraps an angle difference into -pi...pi.
@inline(__always) func wrapAngle(_ a: Float) -> Float {
    var x = a.truncatingRemainder(dividingBy: 2 * .pi)
    if x > .pi { x -= 2 * .pi }
    if x < -.pi { x += 2 * .pi }
    return x
}

enum Ease {
    static func outCubic(_ t: Float) -> Float { let u = 1 - saturate(t); return 1 - u * u * u }
    static func inOutCubic(_ t: Float) -> Float {
        let x = saturate(t)
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func inOutSine(_ t: Float) -> Float { -(cos(.pi * saturate(t)) - 1) / 2 }
    static func outExpo(_ t: Float) -> Float { t >= 1 ? 1 : 1 - pow(2, -10 * saturate(t)) }
}

/// CSS-style cubic-bezier timing curve (used to match the official BluBer intro exactly).
struct CubicBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    func callAsFunction(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        if x == 0 || x == 1 { return x }
        // Solve bezierX(s) = x with Newton, falling back to bisection.
        var s = x
        for _ in 0..<8 {
            let err = bx(s) - x
            if abs(err) < 1e-6 { return by(s) }
            let d = dbx(s)
            if abs(d) < 1e-6 { break }
            s -= err / d
        }
        var lo = 0.0, hi = 1.0
        s = x
        for _ in 0..<30 {
            let v = bx(s)
            if abs(v - x) < 1e-6 { break }
            if v < x { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return by(s)
    }

    private func bx(_ s: Double) -> Double { let u = 1 - s; return 3 * u * u * s * x1 + 3 * u * s * s * x2 + s * s * s }
    private func by(_ s: Double) -> Double { let u = 1 - s; return 3 * u * u * s * y1 + 3 * u * s * s * y2 + s * s * s }
    private func dbx(_ s: Double) -> Double { let u = 1 - s; return 3 * u * u * x1 + 6 * u * s * (x2 - x1) + 3 * s * s * (1 - x2) }
}

// MARK: - Deterministic random

/// SplitMix64: fast, seedable, good enough for procedural content.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * unit() }
}

// MARK: - Procedural noise (CPU side, used for stone meshes)

enum Noise {
    @inline(__always) static func hash(_ x: Int32, _ y: Int32, _ z: Int32, _ seed: Int32) -> Float {
        var h = UInt32(bitPattern: x &* 374761393 &+ y &* 668265263 &+ z &* 2147483647 &+ seed &* 144665)
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
    }

    static func value3(_ p: SIMD3<Float>, seed: Int32) -> Float {
        let i = floor(p), f = p - i
        let u = f * f * (3 - 2 * f)
        let x = Int32(i.x), y = Int32(i.y), z = Int32(i.z)
        func h(_ a: Int32, _ b: Int32, _ c: Int32) -> Float { hash(x + a, y + b, z + c, seed) }
        let x00 = lerpf(h(0, 0, 0), h(1, 0, 0), u.x), x10 = lerpf(h(0, 1, 0), h(1, 1, 0), u.x)
        let x01 = lerpf(h(0, 0, 1), h(1, 0, 1), u.x), x11 = lerpf(h(0, 1, 1), h(1, 1, 1), u.x)
        return lerpf(lerpf(x00, x10, u.y), lerpf(x01, x11, u.y), u.z)
    }

    static func fbm3(_ p: SIMD3<Float>, seed: Int32, octaves: Int = 4) -> Float {
        var sum: Float = 0, amp: Float = 0.5, q = p, norm: Float = 0
        for o in 0..<octaves {
            sum += amp * value3(q, seed: seed &+ Int32(o) &* 31)
            norm += amp
            amp *= 0.5
            q *= 2.03
        }
        return sum / norm
    }
}

extension SIMD2 where Scalar == Float {
    var lengthValue: Float { simd_length(self) }
}

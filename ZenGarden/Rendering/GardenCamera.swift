import CoreGraphics
import simd

/// Fixed camera, slightly tilted from straight above. It never moves while playing, so the
/// mapping from finger to sand stays perfectly predictable.
struct GardenCamera {
    var viewProj = matrix_identity_float4x4
    var invViewProj = matrix_identity_float4x4
    var position = SIMD3<Float>(0, 0, 3)
    var right = SIMD3<Float>(1, 0, 0)
    var up = SIMD3<Float>(0, 1, 0)
    private(set) var viewSize = CGSize(width: 1, height: 1)

    static let tilt: Float = 20 * .pi / 180
    static let fovY: Float = 22 * .pi / 180

    /// Fits the whole garden (sand + frame) inside the area left free by the insets (points).
    mutating func fit(viewSize: CGSize, top: CGFloat, bottom: CGFloat, side: CGFloat,
                      gardenHalf: SIMD2<Float>, frameWidth: Float, frameHeight: Float) {
        guard viewSize.width > 1, viewSize.height > 1 else { return }
        self.viewSize = viewSize
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let proj = simd_float4x4.perspective(fovY: Self.fovY, aspect: w / h, near: 0.05, far: 40)
        let ext = gardenHalf + frameWidth
        var corners: [SIMD4<Float>] = []
        for sx in [-1, 1] as [Float] {
            for sy in [-1, 1] as [Float] {
                corners.append(SIMD4(sx * ext.x, sy * ext.y, frameHeight, 1))
                corners.append(SIMD4(sx * ext.x, sy * ext.y, -0.03, 1))
            }
        }
        let yTop = 1 - 2 * Float(top) / h
        let yBot = -1 + 2 * Float(bottom) / h
        let xLim = 1 - 2 * Float(side) / w
        let toCam = SIMD3<Float>(0, -sin(Self.tilt), cos(Self.tilt))

        func view(_ dist: Float, _ ty: Float) -> (simd_float4x4, SIMD3<Float>, simd_float4x4) {
            let target = SIMD3<Float>(0, ty, 0)
            let eye = target + toCam * dist
            let v = simd_float4x4.lookAt(eye: eye, target: target, up: SIMD3(0, 1, 0))
            return (proj * v, eye, v)
        }

        func bounds(_ vp: simd_float4x4) -> (Float, Float, Float, Float) {
            var minX = Float.infinity, maxX = -Float.infinity, minY = Float.infinity, maxY = -Float.infinity
            for c in corners {
                let p = vp * c
                let x = p.x / p.w, y = p.y / p.w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
            return (minX, maxX, minY, maxY)
        }

        // Smallest distance at which everything fits, with the garden centred in the free area.
        var lo: Float = 0.5, hi: Float = 25, bestTy: Float = 0
        for _ in 0..<36 {
            let d = (lo + hi) / 2
            var ty: Float = 0
            for _ in 0..<8 {
                let (vp, _, _) = view(d, ty)
                let b = bounds(vp)
                let centre = (b.2 + b.3) / 2
                ty += (centre - (yTop + yBot) / 2) * d * 0.25
            }
            let b = bounds(view(d, ty).0)
            let fits = b.0 >= -xLim && b.1 <= xLim && b.2 >= yBot && b.3 <= yTop
            if fits { hi = d; bestTy = ty } else { lo = d }
        }
        let (vp, eye, v) = view(hi, bestTy)
        viewProj = vp
        invViewProj = vp.inverse
        position = eye
        right = SIMD3(v.columns.0.x, v.columns.1.x, v.columns.2.x)
        up = SIMD3(v.columns.0.y, v.columns.1.y, v.columns.2.y)
    }

    /// Where a screen point (in points) hits the horizontal plane at height `z`.
    func ground(_ p: CGPoint, z: Float = 0) -> SIMD2<Float> {
        let x = Float(p.x / viewSize.width) * 2 - 1
        let y = 1 - Float(p.y / viewSize.height) * 2
        var n = invViewProj * SIMD4(x, y, 0, 1); n /= n.w
        var f = invViewProj * SIMD4(x, y, 1, 1); f /= f.w
        let d = SIMD3(f.x - n.x, f.y - n.y, f.z - n.z)
        guard abs(d.z) > 1e-6 else { return SIMD2(n.x, n.y) }
        let t = (z - n.z) / d.z
        return SIMD2(n.x + d.x * t, n.y + d.y * t)
    }

    /// Screen position (points) of a world point.
    func project(_ w: SIMD3<Float>) -> CGPoint {
        let p = viewProj * SIMD4(w, 1)
        let x = p.x / p.w, y = p.y / p.w
        return CGPoint(x: CGFloat((x + 1) / 2) * viewSize.width, y: CGFloat((1 - y) / 2) * viewSize.height)
    }
}

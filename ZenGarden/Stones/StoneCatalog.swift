import simd
import SwiftUI

/// The five starting stones. Shapes are generated procedurally (StoneMeshFactory), so adding
/// a new stone is just a new entry here.
struct StoneType {
    let id: Int
    let nameEN: String
    let nameES: String
    /// Ellipsoid radii before displacement (x, y, height), world units.
    let radii: SIMD3<Float>
    /// Displacement amplitude and frequency of the rocky surface.
    let roughness: Float
    let frequency: Float
    /// Ridged facets (0 = smooth river stone).
    let facets: Float
    let seed: Int32
    /// Linear-space colours: base, variation, accent (flecks / veins).
    let colorA: SIMD3<Float>
    let colorB: SIMD3<Float>
    let colorC: SIMD3<Float>
    /// flecks, moss, veins
    let material: SIMD3<Float>

    var name: String { T(nameEN, nameES) }
    var isLarge: Bool { max(radii.x, radii.y) > 0.07 }

    /// sRGB colours for the UI thumbnails.
    var uiBase: Color { Color(linear: colorB) }
    var uiShade: Color { Color(linear: colorA * 0.75) }
}

enum StoneCatalog {
    static let all: [StoneType] = [
        StoneType(id: 0, nameEN: "River", nameES: "Río",
                  radii: SIMD3(0.072, 0.052, 0.030), roughness: 0.05, frequency: 1.6, facets: 0, seed: 11,
                  colorA: SIMD3(0.20, 0.19, 0.17), colorB: SIMD3(0.33, 0.31, 0.28), colorC: SIMD3(0.55, 0.53, 0.50),
                  material: SIMD3(0.25, 0, 0.15)),
        StoneType(id: 1, nameEN: "Mountain", nameES: "Montaña",
                  radii: SIMD3(0.060, 0.052, 0.082), roughness: 0.15, frequency: 2.1, facets: 0.18, seed: 23,
                  colorA: SIMD3(0.16, 0.155, 0.15), colorB: SIMD3(0.27, 0.26, 0.25), colorC: SIMD3(0.62, 0.60, 0.57),
                  material: SIMD3(1.0, 0, 0)),
        StoneType(id: 2, nameEN: "Basalt", nameES: "Basalto",
                  radii: SIMD3(0.058, 0.050, 0.036), roughness: 0.10, frequency: 2.8, facets: 0.1, seed: 37,
                  colorA: SIMD3(0.035, 0.033, 0.032), colorB: SIMD3(0.07, 0.066, 0.062), colorC: SIMD3(0.16, 0.15, 0.14),
                  material: SIMD3(0.3, 0, 0)),
        StoneType(id: 3, nameEN: "Moss", nameES: "Musgo",
                  radii: SIMD3(0.085, 0.068, 0.048), roughness: 0.12, frequency: 1.9, facets: 0.05, seed: 53,
                  colorA: SIMD3(0.13, 0.12, 0.105), colorB: SIMD3(0.21, 0.195, 0.17), colorC: SIMD3(0.4, 0.38, 0.35),
                  material: SIMD3(0.2, 1.0, 0)),
        StoneType(id: 4, nameEN: "Slate", nameES: "Pizarra",
                  radii: SIMD3(0.090, 0.050, 0.022), roughness: 0.07, frequency: 3.6, facets: 0.3, seed: 71,
                  colorA: SIMD3(0.42, 0.39, 0.355), colorB: SIMD3(0.55, 0.52, 0.48), colorC: SIMD3(0.30, 0.28, 0.255),
                  material: SIMD3(0.1, 0, 0.8)),
    ]
}

extension Color {
    /// Builds a SwiftUI colour from linear RGB.
    init(linear c: SIMD3<Float>) {
        func enc(_ x: Float) -> Double {
            let v = max(0, min(1, x))
            return Double(v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055)
        }
        self.init(.sRGB, red: enc(c.x), green: enc(c.y), blue: enc(c.z), opacity: 1)
    }
}

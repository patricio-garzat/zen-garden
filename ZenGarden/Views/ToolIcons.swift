import SwiftUI

/// Line icons for the garden tools, drawn in a 24×24 grid.
struct ToolIcon: View {
    enum Kind { case fine, wide, wave, smoother, stones, smoothAll }
    let kind: Kind
    var size: CGFloat = 26
    var lineWidth: CGFloat = 1.6

    init(_ kind: Kind, size: CGFloat = 26) {
        self.kind = kind
        self.size = size
    }

    init(tool: ToolKind, size: CGFloat = 26) {
        switch tool {
        case .fineRake: kind = .fine
        case .wideRake: kind = .wide
        case .waveRake: kind = .wave
        case .smoother: kind = .smoother
        }
        self.size = size
    }

    var body: some View {
        Canvas { ctx, sz in
            let k = sz.width / 24
            ctx.scaleBy(x: k, y: k)
            let style = StrokeStyle(lineWidth: lineWidth * 24 / sz.width, lineCap: .round, lineJoin: .round)
            ctx.stroke(path, with: .foreground, style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var path: Path {
        var p = Path()
        switch kind {
        case .fine:
            p.move(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 12, y: 10))
            p.move(to: CGPoint(x: 4, y: 10)); p.addLine(to: CGPoint(x: 20, y: 10))
            for i in 0..<7 {
                let x = 5 + CGFloat(i) * (14.0 / 6.0)
                p.move(to: CGPoint(x: x, y: 10)); p.addLine(to: CGPoint(x: x, y: 15))
            }
            p.move(to: CGPoint(x: 5, y: 19)); p.addLine(to: CGPoint(x: 19, y: 19))
        case .wide:
            p.move(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 12, y: 9))
            p.move(to: CGPoint(x: 3.5, y: 9)); p.addLine(to: CGPoint(x: 20.5, y: 9))
            for x in [5.0, 9.7, 14.3, 19.0] as [CGFloat] {
                p.move(to: CGPoint(x: x, y: 9)); p.addLine(to: CGPoint(x: x, y: 16))
            }
            p.move(to: CGPoint(x: 4, y: 20)); p.addLine(to: CGPoint(x: 20, y: 20))
        case .wave:
            for row in 0..<3 {
                let y = 7 + CGFloat(row) * 5
                p.move(to: CGPoint(x: 3, y: y))
                p.addCurve(to: CGPoint(x: 12, y: y), control1: CGPoint(x: 6, y: y - 3.2), control2: CGPoint(x: 9, y: y - 3.2))
                p.addCurve(to: CGPoint(x: 21, y: y), control1: CGPoint(x: 15, y: y + 3.2), control2: CGPoint(x: 18, y: y + 3.2))
            }
        case .smoother:
            p.move(to: CGPoint(x: 12, y: 3)); p.addLine(to: CGPoint(x: 12, y: 9))
            p.addRoundedRect(in: CGRect(x: 4, y: 9, width: 16, height: 4), cornerSize: CGSize(width: 2, height: 2))
            p.move(to: CGPoint(x: 6, y: 18)); p.addLine(to: CGPoint(x: 18, y: 18))
            p.move(to: CGPoint(x: 8.5, y: 21)); p.addLine(to: CGPoint(x: 15.5, y: 21))
        case .stones:
            p.move(to: CGPoint(x: 4, y: 15))
            p.addCurve(to: CGPoint(x: 11, y: 8), control1: CGPoint(x: 4, y: 10.5), control2: CGPoint(x: 7, y: 8))
            p.addCurve(to: CGPoint(x: 18, y: 14.5), control1: CGPoint(x: 15, y: 8), control2: CGPoint(x: 18, y: 10.5))
            p.addCurve(to: CGPoint(x: 11, y: 19), control1: CGPoint(x: 18, y: 18), control2: CGPoint(x: 14.5, y: 19))
            p.addCurve(to: CGPoint(x: 4, y: 15), control1: CGPoint(x: 7, y: 19), control2: CGPoint(x: 4, y: 18))
            p.closeSubpath()
            p.move(to: CGPoint(x: 15.5, y: 6.5))
            p.addCurve(to: CGPoint(x: 20.5, y: 9.5), control1: CGPoint(x: 18, y: 5.5), control2: CGPoint(x: 20.5, y: 7))
            p.move(to: CGPoint(x: 2.5, y: 21.5)); p.addLine(to: CGPoint(x: 21.5, y: 21.5))
        case .smoothAll:
            p.addRoundedRect(in: CGRect(x: 3, y: 3.5, width: 18, height: 17), cornerSize: CGSize(width: 2.5, height: 2.5))
            p.move(to: CGPoint(x: 6, y: 10)); p.addLine(to: CGPoint(x: 18, y: 10))
            p.move(to: CGPoint(x: 12, y: 12.5)); p.addLine(to: CGPoint(x: 12, y: 17))
            p.move(to: CGPoint(x: 9.8, y: 14.8)); p.addLine(to: CGPoint(x: 12, y: 17)); p.addLine(to: CGPoint(x: 14.2, y: 14.8))
        }
        return p
    }
}

/// A small drawing of a stone for the tray (soft shading, organic outline).
struct StoneThumb: View {
    let type: StoneType
    var size: CGFloat = 46

    var body: some View {
        Canvas { ctx, sz in
            let aspect = CGFloat(type.radii.y / type.radii.x)
            let tall = CGFloat(min(1.15, 0.55 + type.radii.z / type.radii.x * 0.9))
            let w = sz.width * 0.82
            let h = min(sz.height * 0.8, w * max(0.45, aspect * 0.55 + tall * 0.35))
            let c = CGPoint(x: sz.width / 2, y: sz.height * 0.52)
            var shape = Path()
            let seed = Double(type.seed)
            for i in 0...48 {
                let a = Double(i) / 48 * 2 * .pi
                let r = 1 + 0.06 * sin(3 * a + seed) + 0.04 * sin(5 * a + seed * 2) * Double(1 + type.facets * 3)
                let p = CGPoint(x: c.x + cos(a) * w / 2 * r, y: c.y + sin(a) * h / 2 * r)
                if i == 0 { shape.move(to: p) } else { shape.addLine(to: p) }
            }
            shape.closeSubpath()
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - w * 0.46, y: c.y + h * 0.18, width: w * 1.0, height: h * 0.55)),
                     with: .color(.black.opacity(0.18)))
            ctx.fill(shape, with: .radialGradient(Gradient(colors: [type.uiBase, type.uiShade]),
                                                  center: CGPoint(x: c.x - w * 0.18, y: c.y - h * 0.25),
                                                  startRadius: 0, endRadius: w * 0.75))
            if type.material.y > 0.5 {
                var moss = Path()
                moss.addEllipse(in: CGRect(x: c.x - w * 0.3, y: c.y - h * 0.42, width: w * 0.5, height: h * 0.32))
                ctx.fill(moss, with: .color(Color(red: 0.36, green: 0.45, blue: 0.24).opacity(0.85)))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

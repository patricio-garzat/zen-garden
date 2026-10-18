import SwiftUI

/// Minimal SVG path-data parser (M, L, H, V, C, S, Q, T, Z; absolute and relative).
/// Used to draw the official BluBer logo from its original path data, untouched.
enum SVGPath {
    private enum Token { case cmd(Character), num(CGFloat) }

    static func parse(_ d: String) -> Path {
        let tokens = tokenize(d)
        var path = Path()
        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint?
        var lastWasCubic = false, lastWasQuad = false

        func num() -> CGFloat? {
            guard i < tokens.count, case let .num(v) = tokens[i] else { return nil }
            i += 1
            return v
        }
        func pt(_ rel: Bool) -> CGPoint? {
            guard let x = num(), let y = num() else { return nil }
            return rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
        }

        while i < tokens.count {
            if case let .cmd(c) = tokens[i] { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            switch cmd {
            case "M", "m":
                guard let p = pt(rel) else { i += 1; continue }
                path.move(to: p); cur = p; start = p
                cmd = rel ? "l" : "L"
                lastWasCubic = false; lastWasQuad = false
            case "L", "l":
                guard let p = pt(rel) else { i += 1; continue }
                path.addLine(to: p); cur = p
                lastWasCubic = false; lastWasQuad = false
            case "H", "h":
                guard let x = num() else { i += 1; continue }
                cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); path.addLine(to: cur)
                lastWasCubic = false; lastWasQuad = false
            case "V", "v":
                guard let y = num() else { i += 1; continue }
                cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); path.addLine(to: cur)
                lastWasCubic = false; lastWasQuad = false
            case "C", "c":
                let base = cur
                guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num() else { i += 1; continue }
                let c1 = rel ? CGPoint(x: base.x + x1, y: base.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = rel ? CGPoint(x: base.x + x2, y: base.y + y2) : CGPoint(x: x2, y: y2)
                let p = rel ? CGPoint(x: base.x + x, y: base.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: p, control1: c1, control2: c2)
                cur = p; lastCtrl = c2; lastWasCubic = true; lastWasQuad = false
            case "S", "s":
                let base = cur
                guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { i += 1; continue }
                let c1 = lastWasCubic && lastCtrl != nil ? CGPoint(x: 2 * cur.x - lastCtrl!.x, y: 2 * cur.y - lastCtrl!.y) : cur
                let c2 = rel ? CGPoint(x: base.x + x2, y: base.y + y2) : CGPoint(x: x2, y: y2)
                let p = rel ? CGPoint(x: base.x + x, y: base.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: p, control1: c1, control2: c2)
                cur = p; lastCtrl = c2; lastWasCubic = true; lastWasQuad = false
            case "Q", "q":
                let base = cur
                guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { i += 1; continue }
                let c = rel ? CGPoint(x: base.x + x1, y: base.y + y1) : CGPoint(x: x1, y: y1)
                let p = rel ? CGPoint(x: base.x + x, y: base.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: p, control: c)
                cur = p; lastCtrl = c; lastWasQuad = true; lastWasCubic = false
            case "T", "t":
                guard let p = pt(rel) else { i += 1; continue }
                let c = lastWasQuad && lastCtrl != nil ? CGPoint(x: 2 * cur.x - lastCtrl!.x, y: 2 * cur.y - lastCtrl!.y) : cur
                path.addQuadCurve(to: p, control: c)
                cur = p; lastCtrl = c; lastWasQuad = true; lastWasCubic = false
            case "Z", "z":
                path.closeSubpath(); cur = start
                lastWasCubic = false; lastWasQuad = false
                if i < tokens.count, case .num = tokens[i] { i += 1 }   // malformed: skip
            default:
                i += 1
            }
        }
        return path
    }

    private static func tokenize(_ d: String) -> [Token] {
        var out: [Token] = []
        var numStr = ""
        var hasDot = false, hasExp = false
        func flush() {
            if !numStr.isEmpty, let v = Double(numStr) { out.append(.num(CGFloat(v))) }
            numStr = ""; hasDot = false; hasExp = false
        }
        var prev: Character = " "
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                flush(); out.append(.cmd(ch))
            } else if ch == "-" || ch == "+" {
                if prev == "e" || prev == "E" { numStr.append(ch) } else { flush(); numStr.append(ch) }
            } else if ch == "." {
                if hasDot && !hasExp { flush() }
                numStr.append(ch); hasDot = true
            } else if ch == "e" || ch == "E" {
                numStr.append(ch); hasExp = true
            } else if ch.isNumber {
                numStr.append(ch)
            } else {
                flush()
            }
            prev = ch
        }
        flush()
        return out
    }
}

import SwiftUI

/// The studio intro (≈4 s on white), identical in every BluBer game. Same timeline and easing
/// as blubergames-site/brand/intro/bluber-intro.html, drawn from the official logo paths.
/// Its sounds come from this game: a breath of sand as "BluBer" rises, a stone as the bear looks up.
struct BluBerIntroView: View {
    var onFinish: () -> Void

    @State private var start = Date()
    @State private var finished = false
    private let reduceMotion = UIAccessibility.isReduceMotionEnabled
    private static let art = Art()

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            TimelineView(.animation(paused: finished)) { tl in
                let t = reduceMotion ? 4.0 : min(4.0, tl.date.timeIntervalSince(start))
                Canvas { ctx, size in Self.art.draw(ctx, size: size, t: t) }
            }
            .ignoresSafeArea()
            .accessibilityLabel("BluBer Games")
        }
        .onAppear {
            start = Date()
            let total = reduceMotion ? 2.2 : 4.25
            if !reduceMotion {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    AudioManager.shared.play(.introSwish, volume: 0.75)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) {
                    AudioManager.shared.play(.stoneSmall, volume: 0.45)
                    HapticsManager.shared.stoneImpact(size: 0.4, strength: 0.5)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + total) {
                finished = true
                onFinish()
            }
        }
    }

    /// Pre-parsed paths and the animation.
    struct Art {
        let body, side, leg, ear, nose, eye: Path
        let letters: [Path]
        let games: [Path]
        let lettersUnion: Path
        let bearBox: CGRect
        let eyeBox: CGRect
        let allBox: CGRect
        let gamesShift: [CGFloat]

        init() {
            func p(_ d: String) -> Path { SVGPath.parse(d).offsetBy(dx: BluBerLogo.offsetX, dy: 0) }
            body = p(BluBerLogo.body); side = p(BluBerLogo.side); leg = p(BluBerLogo.leg)
            ear = p(BluBerLogo.ear); nose = p(BluBerLogo.nose); eye = p(BluBerLogo.eye)
            letters = BluBerLogo.letters.map(p)
            games = BluBerLogo.games.map(p)
            var u = Path()
            letters.forEach { u.addPath($0) }
            lettersUnion = u
            bearBox = [body, side, leg, ear, nose, eye].map(\.boundingRect).reduce(CGRect.null) { $0.union($1) }
            eyeBox = eye.boundingRect
            let gb = games.map(\.boundingRect)
            allBox = ([bearBox] + letters.map(\.boundingRect) + gb).reduce(CGRect.null) { $0.union($1) }
            let cx = (gb[0].minX + gb[4].maxX) / 2
            gamesShift = gb.map { (cx - $0.midX) * 0.75 }
        }

        static let easeOut = CubicBezier(x1: 0.16, y1: 1, x2: 0.3, y2: 1)
        static let inOut = CubicBezier(x1: 0.65, y1: 0, x2: 0.35, y2: 1)
        static let zoom = CubicBezier(x1: 0.22, y1: 0.6, x2: 0.2, y2: 1)
        static let fade = CubicBezier(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
        static let blink = CubicBezier(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

        private func progress(_ t: Double, _ delay: Double, _ dur: Double) -> Double {
            min(1, max(0, (t - delay) / dur))
        }

        func draw(_ base: GraphicsContext, size: CGSize, t: Double) {
            var ctx = base
            // Logo about 200 pt wide, centred (brand guide).
            let vb = BluBerLogo.viewBox
            let k = 200 / vb.width
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.scaleBy(x: k, y: k)
            ctx.translateBy(x: -vb.midX, y: -vb.midY)

            // 0 · Slow approach of the whole composition.
            let s = 0.955 + 0.045 * Self.zoom(t / 4.0)
            ctx.translateBy(x: allBox.midX, y: allBox.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -allBox.midX, y: -allBox.midY)

            // 1 · Bear fades in (no bounce), then 5 · lifts its head and blinks.
            var bear = ctx
            let fb = Self.fade(progress(t, 0.25, 1.0))
            bear.opacity = fb
            let origin = CGPoint(x: bearBox.midX, y: bearBox.maxY)
            bear.translateBy(x: origin.x, y: origin.y)
            if t >= 2.7 && t < 3.7 {
                let p = Self.inOut((t - 2.7) / 1.0)
                let a: Double
                if p < 0.45 { a = -2.6 * p / 0.45 } else if p < 0.65 { a = -2.6 } else { a = -2.6 * (1 - (p - 0.65) / 0.35) }
                bear.rotate(by: .degrees(a))
            } else {
                let sc = 0.965 + 0.035 * fb
                bear.translateBy(x: 0, y: 3 * (1 - fb))
                bear.scaleBy(x: sc, y: sc)
            }
            bear.translateBy(x: -origin.x, y: -origin.y)
            bear.fill(body, with: .color(BluBerLogo.ice))
            bear.fill(side, with: .color(BluBerLogo.sea))
            bear.fill(leg, with: .color(BluBerLogo.sea))
            bear.fill(ear, with: .color(BluBerLogo.sea))
            bear.fill(nose, with: .color(BluBerLogo.navy))
            var eyeCtx = bear
            if t >= 3.25 && t < 3.45 {
                let p = Self.blink((t - 3.25) / 0.2)
                let sy = p < 0.5 ? 1 - 0.88 * (p / 0.5) : 0.12 + 0.88 * ((p - 0.5) / 0.5)
                eyeCtx.translateBy(x: eyeBox.midX, y: eyeBox.midY)
                eyeCtx.scaleBy(x: 1, y: sy)
                eyeCtx.translateBy(x: -eyeBox.midX, y: -eyeBox.midY)
            }
            eyeCtx.fill(eye, with: .color(BluBerLogo.navy))

            // 2 · "BluBer" rises letter by letter from its baseline.
            var word = ctx
            word.clip(to: Path(BluBerLogo.baseClip))
            for (i, l) in letters.enumerated() {
                let p = Self.easeOut(progress(t, 1.2 + Double(i) * 0.07, 0.76))
                word.fill(l.offsetBy(dx: 0, dy: 54 * (1 - p)), with: .color(BluBerLogo.navy))
            }

            // 4 · A shine sweeps across "BluBer".
            if t > 2.8 && t < 3.7 {
                var shine = ctx
                shine.clip(to: lettersUnion)
                let p = Self.inOut((t - 2.8) / 0.9)
                let r = BluBerLogo.sweepRect
                shine.translateBy(x: 360 * p + r.midX, y: r.midY)
                shine.concatenate(CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(-18 * Double.pi / 180)), d: 1, tx: 0, ty: 0))
                shine.translateBy(x: -r.midX, y: -r.midY)
                let g = Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.6), location: 0.5),
                    .init(color: .white.opacity(0), location: 1),
                ])
                shine.fill(Path(r), with: .linearGradient(g, startPoint: CGPoint(x: r.minX, y: r.midY), endPoint: CGPoint(x: r.maxX, y: r.midY)))
            }

            // 3 · "GAMES" opens from the centre.
            for (i, g) in games.enumerated() {
                let order = Double(abs(i - 2))
                let p = Self.easeOut(progress(t, 1.95 + order * 0.07, 0.8))
                var gc = ctx
                gc.opacity = p
                gc.fill(g.offsetBy(dx: gamesShift[i] * (1 - p), dy: 0), with: .color(BluBerLogo.ice))
            }
        }
    }
}

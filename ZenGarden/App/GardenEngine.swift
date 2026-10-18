import MetalKit
import Photos
import simd
import UIKit

/// Coordinates the garden: simulation, rendering, stones, grains, sound and touch.
/// Everything here runs on the main thread (MTKView draws on the main run loop).
final class GardenEngine {
    // World layout. The sand is 1.0 wide (about one metre) and 2.0 long.
    static let gardenHalf = SIMD2<Float>(0.5, 1.0)
    static let frameWidth: Float = 0.065
    static let frameHeight: Float = 0.04

    let ui = GardenUIState()
    let sim: SandSimulation
    let stones: StoneManager
    let particles = ParticleSystem()
    private(set) var controller: RakeController!
    private(set) var renderer: GardenRenderer?
    private(set) weak var view: GardenMTKView?

    private let audio = AudioManager.shared
    private let haptics = HapticsManager.shared
    private let progression = GameProgression.shared
    private let store = GardenStore.shared

    var inputEnabled = false
    var tool: ToolKind = .fineRake { didSet { ui.tool = tool } }
    private(set) var quality: QualityLevel = .balanced
    private var autoLevel: QualityLevel = .balanced
    private(set) var time: Float = 0
    private var dark = false
    private var idleFrames = 0

    // Current document (stones + metadata; sand lives on the GPU).
    private(set) var currentDoc = GardenDocument(name: "Garden")
    private var hasOpenedUserGarden = false

    // Strokes
    private var actionPending = false
    private var strokeOnset: Float = 0
    private var strokeSeed: Float = 0
    private var rng = SeededRandom(seed: UInt64(Date().timeIntervalSince1970))
    private var newStones = Set<UUID>()
    private var ringAfterLanding: UUID?

    // Animations
    private struct RingAnim {
        var center: SIMD2<Float>, r0: Float, spacing: Float, depth: Float, count: Float
        var t: Float = 0, duration: Float, lastTick = 0, finalFrames = 0
    }
    private struct SweepAnim { var t: Float = 0; var duration: Float; var previousFront: Float }
    private struct BlendAnim { var t: Float = 0; var duration: Float }
    private struct ScriptStep { let at: Float; let run: () -> Void }

    private var rings: [RingAnim] = []
    private var sweep: SweepAnim?
    private var blend: BlendAnim?
    private var script: [ScriptStep] = []
    private var scriptTime: Float = 0

    private var autosaveWork: DispatchWorkItem?
    private var gpuSamples: [Double] = []

    init() {
        sim = SandSimulation(half: Self.gardenHalf, resolution: QualityLevel.balanced.resolution)
        stones = StoneManager(device: MetalContext.shared.device, gardenHalf: Self.gardenHalf, frameWidth: Self.frameWidth)
        controller = RakeController(engine: self)
        applyQualitySetting()
    }

    // MARK: - View

    func attach(_ view: GardenMTKView) {
        view.engine = self
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = false          // lets us capture frames for thumbnails and photos
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let r = GardenRenderer(engine: self, view: view)
        view.delegate = r
        renderer = r
        self.view = view
        applyLighting()
        applyQualitySetting()
        layoutChanged()
    }

    var acceptsTouches: Bool { inputEnabled && sweep == nil && blend == nil }

    func wake() {
        idleFrames = 0
        if view?.isPaused == true { view?.isPaused = false }
    }

    func layoutChanged() {
        guard let view, let renderer else { return }
        let s = view.bounds.size
        guard s.width > 10, s.height > 10 else { return }
        let insets = view.safeAreaInsets
        renderer.camera.fit(viewSize: s, top: insets.top + 50, bottom: insets.bottom + 86, side: 10,
                            gardenHalf: Self.gardenHalf, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight)
        wake()
    }

    func ground(_ p: CGPoint, z: Float = 0) -> SIMD2<Float> {
        renderer?.camera.ground(p, z: z) ?? .zero
    }

    // MARK: - Appearance & quality

    func setDark(_ isDark: Bool) {
        guard isDark != dark || renderer?.uniforms.bgTop.x == 0.8 else { return }
        dark = isDark
        applyLighting()
    }

    private func applyLighting() {
        guard let renderer else { return }
        var u = renderer.uniforms
        let sun: SIMD3<Float>
        if dark {
            // Evening light: low warm sun, cool sky.
            sun = normalize(SIMD3<Float>(-0.70, 0.50, 0.45))
            u.sunColor = SIMD4(0.56, 0.42, 0.30, 1)
            u.skyColor = SIMD4(0.085, 0.095, 0.13, 1)
            u.groundColor = SIMD4(0.06, 0.05, 0.045, 1)
            u.bgTop = SIMD4(0.030, 0.028, 0.026, 1)
            u.bgBottom = SIMD4(0.013, 0.012, 0.011, 1)
            u.misc.y = 1
        } else {
            sun = normalize(SIMD3<Float>(-0.60, 0.55, 0.58))
            u.sunColor = SIMD4(0.92, 0.83, 0.70, 1)
            u.skyColor = SIMD4(0.30, 0.32, 0.36, 1)
            u.groundColor = SIMD4(0.30, 0.27, 0.23, 1)
            u.bgTop = SIMD4(0.78, 0.74, 0.68, 1)
            u.bgBottom = SIMD4(0.66, 0.62, 0.56, 1)
            u.misc.y = 0
        }
        u.sunDir = SIMD4(sun, 0)
        u.sandAlbedo = SIMD4(0.83, 0.77, 0.655, 1)
        u.garden = SIMD4(Self.gardenHalf.x, Self.gardenHalf.y, Self.frameWidth, Self.frameHeight)
        u.params.x = 1.0      // normal strength
        u.params.y = 1.6      // cavity AO strength
        renderer.uniforms = u
        sim.light = sun
        particles.color = SIMD3(0.80, 0.74, 0.63)
        wake()
    }

    func applyQualitySetting() {
        let level: QualityLevel
        switch SettingsManager.shared.quality {
        case .auto: level = autoLevel
        case .eco: level = .eco
        case .balanced: level = .balanced
        case .ultra: level = .ultra
        }
        setQuality(level)
    }

    private func setQuality(_ level: QualityLevel) {
        let changed = level != quality
        quality = level
        if changed || sim.width != level.resolution {
            sim.configure(resolution: level.resolution, preserveContent: true)
        }
        sim.shadowSteps = level.shadowSteps
        sim.maxUndo = level.undoDepth
        particles.capacity = level.particleCap
        renderer?.uniforms.misc.x = level.glints
        renderer?.uniforms.misc.z = level == .eco ? 0.6 : 1.0
        if let view {
            let native = view.traitCollection.displayScale
            view.contentScaleFactor = level == .eco ? min(2, native) : native
        }
        ui.activeQuality = level
        refreshUndoUI()
        wake()
    }

    var shouldMeasureGPU: Bool { SettingsManager.shared.quality == .auto && quality > .eco }

    /// Automatic quality: drops one level after a sustained run of slow frames.
    func reportGPUTime(_ ms: Double) {
        guard shouldMeasureGPU else { gpuSamples.removeAll(); return }
        gpuSamples.append(ms)
        guard gpuSamples.count >= 120 else { return }
        let avg = gpuSamples.reduce(0, +) / Double(gpuSamples.count)
        gpuSamples.removeAll()
        if avg > 13.5, let lower = QualityLevel(rawValue: quality.rawValue - 1) {
            autoLevel = lower
            applyQualitySetting()
        }
    }

    // MARK: - Frame

    func frameUpdate(dt: Float) {
        time += dt
        runScript(dt)
        controller.update(dt: dt)
        for e in stones.update(dt: dt) { handle(e) }
        updateRings(dt)
        updateSweep(dt)
        updateBlend(dt)
        particles.update(dt: dt)
        sim.footprints = stones.footprints(sim: sim)

        if ui.stoneCount != stones.count { ui.stoneCount = stones.count }
        let busy = sweep != nil || blend != nil
        if ui.busy != busy { ui.busy = busy }

        let animating = controller.isActive || stones.isAnimating || particles.count > 0 || !rings.isEmpty
            || sweep != nil || blend != nil || !script.isEmpty || sim.hasPendingWork || renderer?.captureHandler != nil
        if animating { idleFrames = 0 } else { idleFrames += 1 }
        if idleFrames > 20 { view?.isPaused = true }
    }

    // MARK: - Strokes

    func strokeBegan() {
        actionPending = true
        strokeOnset = 1
        strokeSeed = rng.range(0, 100)
        ui.interacting = true
        let sharp: Float = tool == .fineRake ? 0.35 : (tool == .smoother ? 0.05 : 0.18)
        haptics.beginContinuous(intensity: 0, sharpness: sharp)
    }

    /// Converts a head movement into stamps. Steps are small enough that neither the centre
    /// nor the outer tines ever skip a texel, even in tight turns.
    func emitToolStamps(from h0: SIMD2<Float>, angle a0: Float, to h1: SIMD2<Float>, angle a1: Float) {
        if actionPending { actionPending = false; beginAction() }
        let spec = tool.spec
        let tw = sim.texelWorld
        let t0 = sim.toTexel(h0), t1 = sim.toTexel(h1)
        let segLen = simd_length(t1 - t0)

        if tool == .smoother {
            let R = spec.radius / tw
            let step: Float = 1.0
            let steps = min(400, max(1, Int(ceil(segLen / step))))
            // Strength per stamp so that one full pass removes `passFlatten` of the relief.
            let covering = max(1, 1.4 * R / step)
            let k = 1 - pow(1 - spec.passFlatten, 1 / covering)
            for i in 1...steps {
                let c = t0 + (t1 - t0) * (Float(i) / Float(steps))
                sim.addStamp(Stamp(a: SIMD4(c.x, c.y, 0, 0), b: SIMD4(R, 0, 0, k), c: SIMD4(StampKind.smooth.rawValue, 0, 0, 0)), radius: R + 1)
            }
            return
        }

        let W = spec.halfWidth / tw, S = spec.spacing / tw
        let dA = wrapAngle(a1 - a0)
        let steps = min(500, max(1, Int(ceil(max(segLen, W * abs(dA)) / 0.7))))
        let radius = (W * W + 4).squareRoot() + 2
        for i in 1...steps {
            let f = Float(i) / Float(steps)
            let c = t0 + (t1 - t0) * f
            let a = a0 + dA * f
            sim.addStamp(Stamp(a: SIMD4(c.x, c.y, cos(a), sin(a)),
                               b: SIMD4(W, S, spec.depth, spec.strength),
                               c: SIMD4(StampKind.rake.rawValue, 0.9, strokeSeed, 0)), radius: radius)
        }
    }

    func strokeFeedback(dt: Float, moved: Float, ticks: Int) {
        let s = controller.speed
        strokeOnset = max(0, strokeOnset - dt / 0.2)
        let head = controller.headPosition
        let pan = clampf(head.x / Self.gardenHalf.x, -1, 1) * 0.55
        let profile: ScrapeProfile
        switch tool {
        case .fineRake: profile = .fine
        case .wideRake: profile = .wide
        case .waveRake: profile = .wave
        case .smoother: profile = .smoother
        }
        audio.setScrape(voice: 0, profile: profile, intensity: s, pan: pan, onset: strokeOnset * s)

        if tool == .smoother {
            haptics.updateContinuous(intensity: 0.04 + 0.13 * s, sharpness: 0.05)
        } else {
            let base: Float = tool == .wideRake ? 0.09 : 0.06
            haptics.updateContinuous(intensity: base + 0.22 * s, sharpness: tool == .fineRake ? 0.35 : 0.18)
            if ticks > 0 { haptics.grain(0.12 + 0.25 * s) }
        }

        // A few grains thrown from the tines.
        if moved > 0 {
            let spec = tool.spec
            let expected = moved * (tool == .smoother ? 60 : 140) * (quality == .eco ? 0.5 : 1)
            var n = Int(expected)
            if particles.random < expected - Float(n) { n += 1 }
            n = min(n, 4)
            let a = controller.headAngle
            let d = SIMD2(cos(a), sin(a)), nrm = SIMD2(-sin(a), cos(a))
            for _ in 0..<n {
                let u: Float
                if spec.tines > 0 {
                    let k = Float(Int(particles.random * Float(spec.tines)))
                    u = -spec.halfWidth + spec.spacing * (k + 0.5)
                } else {
                    u = (particles.random * 2 - 1) * spec.radius * 0.8
                }
                particles.spray(at: head + nrm * u + d * 0.004, direction: d, lateral: nrm, speed: s)
            }
            progression.record { $0.distance += Double(moved); $0.secondsRaking += Double(dt) }
        }
    }

    func strokeEnded() {
        audio.stopScrape(voice: 0)
        haptics.endContinuous()
        if controller.stampedThisStroke {
            progression.record { $0.strokes += 1 }
            scheduleAutosave()
        }
        actionPending = false
        ui.interacting = false
    }

    // MARK: - Actions

    /// Records an undo step. Call before any change to the sand or the stones.
    func beginAction() {
        sim.pushUndo(stones: stones.states)
        refreshUndoUI()
        scheduleAutosave()
    }

    private func refreshUndoUI() {
        if ui.canUndo != sim.canUndo { ui.canUndo = sim.canUndo }
        if ui.canRedo != sim.canRedo { ui.canRedo = sim.canRedo }
    }

    func select(_ newTool: ToolKind) {
        guard newTool != tool else { return }
        tool = newTool
        audio.play(.toolSelect, volume: 0.8)
        haptics.selection()
    }

    func undo() {
        stopAnimations()
        guard let restored = sim.undo(currentStones: stones.states) else { return }
        stones.restore(restored)
        refreshUndoUI()
        audio.play(.uiTap, volume: 0.7)
        haptics.selection()
        scheduleAutosave()
        wake()
    }

    func redo() {
        stopAnimations()
        guard let restored = sim.redo(currentStones: stones.states) else { return }
        stones.restore(restored)
        refreshUndoUI()
        audio.play(.uiTap, volume: 0.7)
        haptics.selection()
        scheduleAutosave()
        wake()
    }

    private func stopAnimations() {
        rings.removeAll()
        if sweep != nil { sweep = nil; audio.stopScrape(voice: 1); haptics.endContinuous() }
    }

    func addStone(type: Int) {
        guard stones.count < StoneManager.maxStones else {
            showToast(T("The garden holds up to 16 stones", "El jardín admite hasta 16 piedras"), symbol: "circle.grid.3x3")
            return
        }
        beginAction()
        let p = stones.freeSpot(rng: &rng)
        if let st = stones.add(type: type, at: p, rotation: rng.range(0, 2 * .pi), scale: rng.range(0.92, 1.08)) {
            newStones.insert(st.id)
        }
        haptics.uiTap()
        wake()
    }

    func grabStone(_ id: UUID) {
        beginAction()
        stones.grab(id)
        audio.play(.stoneLift, volume: 0.7)
        haptics.stoneLift()
        ui.interacting = true
    }

    func dragStone(_ id: UUID, to p: SIMD2<Float>) { stones.drag(id, to: p) }
    func rotateStone(_ id: UUID, by d: Float) { stones.rotate(id, by: d) }

    func releaseStone(_ id: UUID, tapped: Bool) {
        let removing = stones.release(id)
        if removing {
            audio.play(.stoneLift, volume: 0.9)
            haptics.stoneLift()
        } else if tapped && tool == .waveRake {
            ringAfterLanding = id
        }
        ui.interacting = false
        scheduleAutosave()
    }

    private func handle(_ e: StoneManager.Event) {
        switch e {
        case let .landed(st, strength):
            let type = StoneCatalog.all[st.type]
            imprint(st, strength: strength)
            let size: Float = type.isLarge ? 1 : 0.55
            audio.play(type.isLarge ? .stoneLarge : .stoneSmall, volume: 0.5 + 0.5 * strength,
                       pan: clampf(st.x / Self.gardenHalf.x, -1, 1) * 0.5, minInterval: 0.05)
            haptics.stoneImpact(size: size, strength: strength)
            particles.puff(at: st.position, radii: stones.footprintRadii(st), rotation: st.rotation,
                           amount: quality == .eco ? 4 : Int(6 + 6 * strength))
            if newStones.remove(st.id) != nil { progression.record { $0.stonesPlaced += 1 } }
            if ringAfterLanding == st.id {
                ringAfterLanding = nil
                ripple(at: st.position, around: st)
            }
        case .removed:
            scheduleAutosave()
        }
    }

    /// The little rim of sand a stone pushes out when it lands.
    private func imprint(_ st: StoneState, strength: Float) {
        let tw = sim.texelWorld
        let c = sim.toTexel(st.position)
        let r = stones.footprintRadii(st) / tw
        let rimW = max(2.5, max(r.x, r.y) * 0.14)
        let amp = 0.0009 + 0.0008 * strength
        sim.addStamp(Stamp(a: SIMD4(c.x, c.y, 0, 0), b: SIMD4(r.x, r.y, amp, rimW),
                           c: SIMD4(StampKind.stoneRim.rawValue, 0, cos(st.rotation), sin(st.rotation))),
                     radius: max(r.x, r.y) * 1.3 + rimW * 3)
    }

    // MARK: - Ripples

    /// Concentric ripples growing outward: around a stone, or from a single touch.
    func ripple(at p: SIMD2<Float>, around stone: StoneState?, rings count: Float = ToolSpec.ringCount,
                duration: Float = 1.6, instant: Bool = false) {
        beginAction()
        let tw = sim.texelWorld
        let centre = stone?.position ?? p
        var r0: Float = 0
        if let stone {
            let r = stones.footprintRadii(stone)
            r0 = max(r.x, r.y) * 1.18 + ToolSpec.ringSpacing * 0.4
        }
        var anim = RingAnim(center: sim.toTexel(centre), r0: r0 / tw, spacing: ToolSpec.ringSpacing / tw,
                            depth: ToolSpec.ringDepth, count: count, duration: duration)
        if instant || UIAccessibility.isReduceMotionEnabled { anim.t = duration }
        rings.append(anim)
        progression.record { $0.ripples += 1 }
        wake()
    }

    private func updateRings(_ dt: Float) {
        guard !rings.isEmpty else { return }
        var loudest: Float = 0
        var pan: Float = 0
        for i in rings.indices.reversed() {
            var a = rings[i]
            a.t += dt
            let p = min(1, a.t / a.duration)
            let rMax = a.r0 + a.count * a.spacing
            let start = a.r0 > 0 ? a.r0 : a.spacing * 0.3
            let R = start + (rMax + a.spacing - start) * Ease.outCubic(p)
            sim.addStamp(Stamp(a: SIMD4(a.center.x, a.center.y, 0, 0), b: SIMD4(a.r0, a.spacing, a.depth, 0.5),
                               c: SIMD4(StampKind.rings.rawValue, R, a.count, 0)),
                         radius: min(R, rMax + a.spacing) + 3)
            let ring = Int((R - a.r0) / a.spacing)
            if ring > a.lastTick && ring <= Int(a.count) {
                a.lastTick = ring
                haptics.ringTick()
            }
            loudest = max(loudest, sin(.pi * p) * 0.85)
            pan = clampf((a.center.x / Float(sim.width)) * 2 - 1, -1, 1) * 0.4
            if p >= 1 {
                a.finalFrames += 1
                if a.finalFrames > 4 { rings.remove(at: i); continue }
            }
            rings[i] = a
        }
        if rings.isEmpty, sweep == nil { audio.stopScrape(voice: 1) }
        else if sweep == nil { audio.setScrape(voice: 1, profile: .rings, intensity: loudest, pan: pan) }
    }

    // MARK: - Smooth everything

    func smoothAll() {
        guard sweep == nil, blend == nil else { return }
        controller.cancelAll()
        rings.removeAll()
        beginAction()
        sim.beginSweep()
        let ridge = 0.012 / sim.texelWorld
        sweep = SweepAnim(duration: 1.7, previousFront: Float(sim.height) + ridge * 3 + 4)
        haptics.beginContinuous(intensity: 0, sharpness: 0.05)
        progression.record { $0.smooths += 1 }
        wake()
    }

    /// Removes the stones and smooths the sand: a fresh garden.
    func newGarden() {
        guard sweep == nil, blend == nil else { return }
        controller.cancelAll()
        rings.removeAll()
        beginAction()
        stones.removeAll(animated: true)
        sim.beginSweep()
        let ridge = 0.012 / sim.texelWorld
        sweep = SweepAnim(duration: 1.7, previousFront: Float(sim.height) + ridge * 3 + 4)
        haptics.beginContinuous(intensity: 0, sharpness: 0.05)
        currentDoc = GardenDocument(name: T("Garden", "Jardín"))
        wake()
    }

    private func updateSweep(_ dt: Float) {
        guard var s = sweep else { return }
        s.t += dt
        let p = min(1, s.t / s.duration)
        let ridge = 0.012 / sim.texelWorld
        let startFront = Float(sim.height) + ridge * 3 + 4
        let endFront = -ridge * 4 - 6
        let front = startFront + (endFront - startFront) * Ease.inOutSine(p)
        sim.sweepFrame(front: front, previousFront: s.previousFront, ridgeWidth: ridge, ridgeHeight: 0.0011)
        s.previousFront = front

        let env = pow(sin(.pi * p), 0.6)
        audio.setScrape(voice: 1, profile: .sweep, intensity: env * 0.95)
        haptics.updateContinuous(intensity: 0.05 + 0.1 * env, sharpness: 0.05)

        // Grains spilling over the board.
        let y = (front / Float(sim.height)) * 2 * Self.gardenHalf.y - Self.gardenHalf.y
        if abs(y) < Self.gardenHalf.y {
            let n = quality == .eco ? 1 : 3
            for _ in 0..<n {
                let x = (particles.random * 2 - 1) * Self.gardenHalf.x * 0.95
                particles.spray(at: SIMD2(x, y - 0.006), direction: SIMD2(0, -1), lateral: SIMD2(1, 0), speed: 0.4)
            }
        }

        if p >= 1 {
            sweep = nil
            audio.stopScrape(voice: 1)
            haptics.endContinuous()
            // Stones keep a soft contact rim.
            for st in stones.states { imprint(st, strength: 0.4) }
            scheduleAutosave()
        } else {
            sweep = s
        }
    }

    // MARK: - Opening gardens

    private func updateBlend(_ dt: Float) {
        guard var b = blend else { return }
        b.t += dt
        let p = min(1, b.t / b.duration)
        sim.blendFrame(Ease.inOutCubic(p))
        if p >= 1 {
            blend = nil
            sim.clearHistory()
            refreshUndoUI()
        } else {
            blend = b
        }
    }

    /// Cross-fades the sand and swaps the stones to show `doc`.
    func open(_ doc: GardenDocument, heights: Data) {
        controller.cancelAll()
        stopAnimations()
        currentDoc = doc
        sim.beginBlend(to: heights, width: doc.heightWidth, height: doc.heightHeight)
        blend = BlendAnim(duration: UIAccessibility.isReduceMotionEnabled ? 0.2 : 1.0)
        stones.transition(to: doc.stones)
        audio.play(.gardenSwap, volume: 0.8)
        wake()
    }

    /// The first time the player enters Free Garden, their last garden comes back.
    func enterFreeGarden() {
        inputEnabled = true
        guard !hasOpenedUserGarden else { return }
        hasOpenedUserGarden = true
        if let (doc, data) = store.loadCurrent() {
            open(doc, heights: data)
        }
    }

    // MARK: - Intro

    /// Game intro: a stone settles in the middle of fresh sand and ripples spread around it.
    func playIntro(done: @escaping () -> Void) {
        inputEnabled = false
        stones.removeAll(animated: false)
        sim.clearFlat()
        sim.clearHistory()
        rings.removeAll()
        let reduce = UIAccessibility.isReduceMotionEnabled
        scriptTime = 0
        script = [
            ScriptStep(at: 0.35) { [weak self] in
                guard let self else { return }
                self.ringAfterLanding = nil
                if let st = self.stones.add(type: 0, at: SIMD2(0, 0.12), rotation: 0.45, scale: 1.25, dropFrom: reduce ? 0.002 : 0.08) {
                    self.introStone = st.id
                }
            },
            ScriptStep(at: 1.0) { [weak self] in
                guard let self, let id = self.introStone, let st = self.stones.state(id) else { return }
                self.ripple(at: st.position, around: st, rings: 7, duration: 1.9, instant: reduce)
                self.sim.clearHistory()
            },
            ScriptStep(at: 3.2) { [weak self] in
                self?.sim.clearHistory()
                self?.refreshUndoUI()
                done()
            },
        ]
        wake()
    }

    private var introStone: UUID?

    private func runScript(_ dt: Float) {
        guard !script.isEmpty else { return }
        scriptTime += dt
        while let first = script.first, first.at <= scriptTime {
            script.removeFirst()
            first.run()
        }
    }

    // MARK: - Saving

    func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveCurrent() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Saves the garden in progress so it is there next time (also on going to background).
    func saveCurrent() {
        guard hasOpenedUserGarden else { return }
        autosaveWork?.cancel()
        var doc = currentDoc
        doc.stones = stones.states
        doc.modified = Date()
        sim.readHeights { [store] data, w, h in
            doc.heightWidth = w
            doc.heightHeight = h
            store.saveCurrent(doc, heights: data)
        }
        wake()
    }

    /// Saves the garden to the gallery (with a thumbnail).
    func saveToGallery() {
        var doc = currentDoc
        if doc.galleryID == nil {
            doc.galleryID = UUID()
            doc.created = Date()
            doc.name = "\(T("Garden", "Jardín")) \(store.galleryCount() + 1)"
        }
        doc.stones = stones.states
        doc.modified = Date()
        currentDoc = doc

        var heights: Data?
        var image: CGImage?
        let group = DispatchGroup()
        group.enter()
        sim.readHeights { data, w, h in
            doc.heightWidth = w
            doc.heightHeight = h
            heights = data
            group.leave()
        }
        group.enter()
        captureGarden(maxWidth: 600) { img in image = img; group.leave() }
        wake()
        group.notify(queue: .main) { [weak self] in
            guard let self, let heights else { return }
            self.store.saveToGallery(doc, heights: heights, thumbnail: image)
            self.store.saveCurrent(doc, heights: heights)
            self.progression.record { $0.gardensSaved += 1 }
            self.audio.play(.uiTap)
            self.haptics.selection()
            self.showToast(T("Garden saved", "Jardín guardado"), symbol: "checkmark")
        }
    }

    /// Opens a garden from the gallery.
    func openFromGallery(_ id: UUID) {
        guard let (doc, data) = store.loadGallery(id) else { return }
        hasOpenedUserGarden = true
        open(doc, heights: data)
    }

    /// Saves an image of the garden to the photo library (asks for permission the first time).
    func exportToPhotos() {
        captureGarden(maxWidth: nil) { [weak self] image in
            guard let self, let image else { return }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async {
                        self.showToast(T("Allow photo access in Settings", "Permite el acceso a Fotos en Ajustes"), symbol: "photo")
                    }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: UIImage(cgImage: image))
                }) { ok, _ in
                    DispatchQueue.main.async {
                        if ok {
                            self.haptics.selection()
                            self.showToast(T("Saved to Photos", "Guardado en Fotos"), symbol: "photo")
                        }
                    }
                }
            }
        }
    }

    /// Captures the next frame, cropped to the garden.
    private func captureGarden(maxWidth: CGFloat?, _ done: @escaping (CGImage?) -> Void) {
        guard let renderer, let view else { done(nil); return }
        renderer.captureHandler = { image in
            guard let image else { done(nil); return }
            let scale = CGFloat(image.width) / max(view.bounds.width, 1)
            let ext = Self.gardenHalf + Self.frameWidth
            var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for sx in [-1, 1] as [Float] {
                for sy in [-1, 1] as [Float] {
                    for z in [Self.frameHeight, -0.03] as [Float] {
                        let p = renderer.camera.project(SIMD3(sx * ext.x, sy * ext.y, z))
                        minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
                    }
                }
            }
            let pad: CGFloat = 6
            let rect = CGRect(x: (minX - pad) * scale, y: (minY - pad) * scale,
                              width: (maxX - minX + 2 * pad) * scale, height: (maxY - minY + 2 * pad) * scale)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
            guard var cropped = image.cropping(to: rect) else { done(image); return }
            if let maxWidth, CGFloat(cropped.width) > maxWidth {
                let k = maxWidth / CGFloat(cropped.width)
                let size = CGSize(width: maxWidth, height: (CGFloat(cropped.height) * k).rounded())
                let r = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
                if let scaled = r.image(actions: { _ in UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size)) }).cgImage {
                    cropped = scaled
                }
            }
            done(cropped)
        }
        wake()
    }

    func showToast(_ text: String, symbol: String) {
        ui.toast = GardenUIState.Toast(text: text, symbol: symbol)
    }

    // MARK: - Data

    func resetEverything() {
        stopAnimations()
        controller.cancelAll()
        stones.removeAll(animated: false)
        sim.clearFlat()
        sim.clearHistory()
        currentDoc = GardenDocument(name: T("Garden", "Jardín"))
        refreshUndoUI()
        wake()
    }

    // MARK: - App lifecycle

    func suspend() {
        controller.cancelAll()
        if hasOpenedUserGarden, let (data, w, h) = sim.readHeightsNow() {
            autosaveWork?.cancel()
            var doc = currentDoc
            doc.stones = stones.states
            doc.modified = Date()
            doc.heightWidth = w
            doc.heightHeight = h
            store.saveCurrent(doc, heights: data, synchronous: true)
        }
        audio.stopScrape(voice: 0)
        audio.stopScrape(voice: 1)
        view?.isPaused = true
    }

    func resume() { wake() }
}

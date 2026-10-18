import Metal
import simd
import Foundation

/// GPU heightmap of the sand plus everything that edits it.
///
/// Callers queue work (stamps, sweeps, undo copies...) at any time on the main thread;
/// `encode(into:)` turns the queue into one compute pass per frame, in order, and then
/// re-derives the lighting texture only for the rectangle that actually changed.
final class SandSimulation {
    struct Snapshot {
        let texture: MTLTexture
        let stones: [StoneState]
    }

    private enum Op {
        case stamps([Stamp], [Float])
        case toHalf(MTLTexture, MTLTexture)
        case fromHalf(MTLTexture, MTLTexture)
        case initFlat
        case sweep(SweepParams)
        case blend(Float)
        case upload(MTLBuffer, MTLTexture, Int, Int)
        case resample(MTLTexture, MTLTexture)
        case download(MTLBuffer)
    }

    private let ctx = MetalContext.shared
    let half: SIMD2<Float>

    private(set) var width = 0
    private(set) var height = 0
    private(set) var heightTex: MTLTexture!
    private(set) var surfaceTex: MTLTexture!
    private var scratchA: MTLTexture!
    private var scratchB: MTLTexture!

    /// Direction toward the sun (world space). Changing it re-derives the whole surface.
    var light = SIMD3<Float>(-0.6, 0.55, 0.58) { didSet { markAllDirty() } }
    var shadowSteps = 8 { didSet { markAllDirty() } }
    /// Resting stones, in texels. The rake and the board never touch the sand below them.
    var footprints: [Footprint] = []
    var maxUndo = 12

    private var ops: [Op] = []
    private var pendingStamps: [Stamp] = []
    private var pendingRadii: [Float] = []
    private var dirty: (x0: Int, y0: Int, x1: Int, y1: Int)?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var pool: [MTLTexture] = []
    private var readbacks: [(MTLBuffer, (Data, Int, Int) -> Void)] = []

    private let pInit, pApply, pDerive, pToHalf, pFromHalf, pSweep, pBlend, pUpload, pDownload, pResample: MTLComputePipelineState

    init(half: SIMD2<Float>, resolution: Int) {
        self.half = half
        pInit = ctx.computePipeline("initSand")
        pApply = ctx.computePipeline("applyStamps")
        pDerive = ctx.computePipeline("deriveSurface")
        pToHalf = ctx.computePipeline("copyToHalf")
        pFromHalf = ctx.computePipeline("copyFromHalf")
        pSweep = ctx.computePipeline("sweepSmooth")
        pBlend = ctx.computePipeline("blendHeights")
        pUpload = ctx.computePipeline("uploadHalf")
        pDownload = ctx.computePipeline("downloadHalf")
        pResample = ctx.computePipeline("resampleHalf")
        configure(resolution: resolution, preserveContent: false)
    }

    // MARK: - Geometry

    var texelWorld: Float { 2 * half.x / Float(width) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasPendingWork: Bool { !ops.isEmpty || !pendingStamps.isEmpty || dirty != nil }

    func toTexel(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((p.x + half.x) / (2 * half.x) * Float(width), (p.y + half.y) / (2 * half.y) * Float(height))
    }

    func toTexel(length l: Float) -> Float { l / texelWorld }

    /// Height-map resolution changes with the quality level. Content is resampled, history dropped.
    func configure(resolution: Int, preserveContent: Bool) {
        let newW = max(64, resolution)
        let newH = max(64, Int((Float(newW) * half.y / half.x).rounded()))
        if newW == width && newH == height { return }
        let old = heightTex, oldW = width, oldH = height

        width = newW
        height = newH
        heightTex = ctx.makeTexture(.r32Float, newW, newH, label: "Sand height")
        surfaceTex = ctx.makeTexture(.rgba16Float, newW, newH, label: "Sand surface")
        scratchA = makeHalf(label: "Scratch A")
        scratchB = makeHalf(label: "Scratch B")
        undoStack.removeAll()
        redoStack.removeAll()
        pool.removeAll()

        if preserveContent, let old {
            let tmp = ctx.makeTexture(.r16Float, oldW, oldH, label: "Resample source")
            enqueue(.toHalf(old, tmp))
            enqueue(.resample(tmp, scratchA))
            enqueue(.fromHalf(scratchA, heightTex))
        } else {
            enqueue(.initFlat)
        }
        markAllDirty()
    }

    private func makeHalf(label: String) -> MTLTexture {
        ctx.makeTexture(.r16Float, width, height, label: label)
    }

    // MARK: - Editing

    func addStamp(_ stamp: Stamp, radius: Float) {
        pendingStamps.append(stamp)
        pendingRadii.append(radius)
    }

    func clearFlat() {
        enqueue(.initFlat)
        markAllDirty()
    }

    func beginSweep() {
        enqueue(.toHalf(heightTex, scratchA))
    }

    /// One frame of the "smooth everything" board. `front` and `previousFront` are texel rows.
    func sweepFrame(front: Float, previousFront: Float, ridgeWidth: Float, ridgeHeight: Float) {
        let y0 = max(0, Int(floor(front - ridgeWidth * 3 - 3)))
        let y1 = min(height - 1, Int(ceil(previousFront + 3)))
        guard y0 <= y1 else { return }
        let p = SweepParams(a: SIMD4(front, ridgeWidth, ridgeHeight, 0),
                            b: SIMD4(UInt32(y0), UInt32(y1 - y0 + 1), UInt32(footprints.count), 0))
        enqueue(.sweep(p))
        markDirty(0, y0, width - 1, y1)
    }

    /// Prepares a cross-fade from the current sand to `heights` (half floats, `w` x `h`).
    func beginBlend(to heights: Data, width w: Int, height h: Int) {
        enqueue(.toHalf(heightTex, scratchA))
        stageUpload(heights, w, h, into: scratchB)
    }

    func blendFrame(_ t: Float) {
        enqueue(.blend(t))
        markAllDirty()
    }

    /// Replaces the sand immediately.
    func load(heights: Data, width w: Int, height h: Int) {
        stageUpload(heights, w, h, into: scratchB)
        enqueue(.fromHalf(scratchB, heightTex))
        markAllDirty()
    }

    private func stageUpload(_ data: Data, _ w: Int, _ h: Int, into target: MTLTexture) {
        guard w > 0, h > 0, data.count >= w * h * 2,
              let buffer = data.withUnsafeBytes({ ctx.device.makeBuffer(bytes: $0.baseAddress!, length: w * h * 2, options: .storageModeShared) })
        else { return }
        if w == width && h == height {
            enqueue(.upload(buffer, target, w, h))
        } else {
            let tmp = ctx.makeTexture(.r16Float, w, h, label: "Upload")
            enqueue(.upload(buffer, tmp, w, h))
            enqueue(.resample(tmp, target))
        }
    }

    /// Reads the heightmap back (half floats). The callback runs on the main queue.
    func readHeights(_ done: @escaping (Data, Int, Int) -> Void) {
        guard let buffer = ctx.device.makeBuffer(length: width * height * 2, options: .storageModeShared) else { return }
        enqueue(.download(buffer))
        readbacks.append((buffer, done))
    }

    /// Runs all queued work and reads the heightmap back right away (used when the app leaves).
    func readHeightsNow() -> (Data, Int, Int)? {
        guard let buffer = ctx.device.makeBuffer(length: width * height * 2, options: .storageModeShared),
              let cb = ctx.queue.makeCommandBuffer() else { return nil }
        enqueue(.download(buffer))
        encode(into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return (Data(bytes: buffer.contents(), count: buffer.length), width, height)
    }

    // MARK: - Undo / redo

    func pushUndo(stones: [StoneState]) {
        let tex = takeTexture()
        enqueue(.toHalf(heightTex, tex))
        undoStack.append(Snapshot(texture: tex, stones: stones))
        if undoStack.count > maxUndo { pool.append(undoStack.removeFirst().texture) }
        for s in redoStack { pool.append(s.texture) }
        redoStack.removeAll()
    }

    func undo(currentStones: [StoneState]) -> [StoneState]? {
        guard let snap = undoStack.popLast() else { return nil }
        let tex = takeTexture()
        enqueue(.toHalf(heightTex, tex))
        redoStack.append(Snapshot(texture: tex, stones: currentStones))
        enqueue(.fromHalf(snap.texture, heightTex))
        pool.append(snap.texture)
        markAllDirty()
        return snap.stones
    }

    func redo(currentStones: [StoneState]) -> [StoneState]? {
        guard let snap = redoStack.popLast() else { return nil }
        let tex = takeTexture()
        enqueue(.toHalf(heightTex, tex))
        undoStack.append(Snapshot(texture: tex, stones: currentStones))
        enqueue(.fromHalf(snap.texture, heightTex))
        pool.append(snap.texture)
        markAllDirty()
        return snap.stones
    }

    func clearHistory() {
        for s in undoStack { pool.append(s.texture) }
        for s in redoStack { pool.append(s.texture) }
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func takeTexture() -> MTLTexture {
        pool.popLast() ?? makeHalf(label: "Undo snapshot")
    }

    // MARK: - Dirty tracking

    func markAllDirty() { markDirty(0, 0, width - 1, height - 1) }

    private func markDirty(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
        if let d = dirty {
            dirty = (min(d.x0, x0), min(d.y0, y0), max(d.x1, x1), max(d.y1, y1))
        } else {
            dirty = (x0, y0, x1, y1)
        }
    }

    // MARK: - Encoding

    private func flushStamps() {
        guard !pendingStamps.isEmpty else { return }
        ops.append(.stamps(pendingStamps, pendingRadii))
        pendingStamps.removeAll(keepingCapacity: true)
        pendingRadii.removeAll(keepingCapacity: true)
    }

    private func enqueue(_ op: Op) {
        flushStamps()
        ops.append(op)
    }

    func encode(into cb: MTLCommandBuffer) {
        flushStamps()
        guard !ops.isEmpty || dirty != nil else { return }
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.label = "Sand"
        for op in ops { encode(op, enc) }
        ops.removeAll(keepingCapacity: true)
        if let d = dirty {
            encodeDerive(enc, d)
            dirty = nil
        }
        enc.endEncoding()

        if !readbacks.isEmpty {
            let pending = readbacks
            readbacks.removeAll()
            let w = width, h = height
            cb.addCompletedHandler { _ in
                let results = pending.map { (Data(bytes: $0.0.contents(), count: $0.0.length), $0.1) }
                DispatchQueue.main.async { for (data, done) in results { done(data, w, h) } }
            }
        }
    }

    private func encode(_ op: Op, _ enc: MTLComputeCommandEncoder) {
        switch op {
        case .initFlat:
            enc.setComputePipelineState(pInit)
            enc.setTexture(heightTex, index: 0)
            dispatch(enc, pInit, width, height)

        case let .toHalf(src, dst):
            enc.setComputePipelineState(pToHalf)
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            dispatch(enc, pToHalf, dst.width, dst.height)

        case let .fromHalf(src, dst):
            enc.setComputePipelineState(pFromHalf)
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            dispatch(enc, pFromHalf, dst.width, dst.height)

        case let .resample(src, dst):
            enc.setComputePipelineState(pResample)
            enc.setTexture(src, index: 0)
            enc.setTexture(dst, index: 1)
            dispatch(enc, pResample, dst.width, dst.height)

        case let .upload(buffer, dst, w, h):
            var g = GridParams(rect: SIMD4(0, 0, UInt32(w), UInt32(h)), v: .zero)
            enc.setComputePipelineState(pUpload)
            enc.setBuffer(buffer, offset: 0, index: 0)
            enc.setBytes(&g, length: MemoryLayout<GridParams>.stride, index: 1)
            enc.setTexture(dst, index: 0)
            dispatch(enc, pUpload, w, h)

        case let .download(buffer):
            enc.setComputePipelineState(pDownload)
            enc.setTexture(heightTex, index: 0)
            enc.setBuffer(buffer, offset: 0, index: 0)
            dispatch(enc, pDownload, width, height)

        case let .blend(t):
            var g = GridParams(rect: .zero, v: SIMD4(t, 0, 0, 0))
            enc.setComputePipelineState(pBlend)
            enc.setTexture(scratchA, index: 0)
            enc.setTexture(scratchB, index: 1)
            enc.setTexture(heightTex, index: 2)
            enc.setBytes(&g, length: MemoryLayout<GridParams>.stride, index: 0)
            dispatch(enc, pBlend, width, height)

        case let .sweep(params):
            var p = params
            enc.setComputePipelineState(pSweep)
            enc.setTexture(scratchA, index: 0)
            enc.setTexture(heightTex, index: 1)
            enc.setBytes(&p, length: MemoryLayout<SweepParams>.stride, index: 0)
            setFootprints(enc, index: 1)
            dispatch(enc, pSweep, width, Int(params.b.y))

        case let .stamps(stamps, radii):
            encodeStamps(stamps, radii, enc)
        }
    }

    private func setFootprints(_ enc: MTLComputeCommandEncoder, index: Int) {
        var fps = footprints.isEmpty ? [Footprint(a: .zero, b: .zero)] : footprints
        enc.setBytes(&fps, length: MemoryLayout<Footprint>.stride * fps.count, index: index)
    }

    /// Stamps go to the GPU in chunks of 64 (small enough for setBytes) with a tight bounding box each.
    private func encodeStamps(_ stamps: [Stamp], _ radii: [Float], _ enc: MTLComputeCommandEncoder) {
        enc.setComputePipelineState(pApply)
        enc.setTexture(heightTex, index: 0)
        setFootprints(enc, index: 2)
        let chunk = 64
        var i = 0
        while i < stamps.count {
            let n = min(chunk, stamps.count - i)
            var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
            var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
            for j in i..<(i + n) {
                let c = SIMD2(stamps[j].a.x, stamps[j].a.y), r = radii[j]
                minX = min(minX, c.x - r); maxX = max(maxX, c.x + r)
                minY = min(minY, c.y - r); maxY = max(maxY, c.y + r)
            }
            let x0 = max(0, Int(floor(minX))), y0 = max(0, Int(floor(minY)))
            let x1 = min(width - 1, Int(ceil(maxX))), y1 = min(height - 1, Int(ceil(maxY)))
            if x0 <= x1 && y0 <= y1 {
                var batch = StampBatch(count: UInt32(n), originX: UInt32(x0), originY: UInt32(y0),
                                       stoneCount: UInt32(footprints.count),
                                       sizeX: UInt32(x1 - x0 + 1), sizeY: UInt32(y1 - y0 + 1))
                stamps.withUnsafeBufferPointer { buf in
                    enc.setBytes(buf.baseAddress! + i, length: MemoryLayout<Stamp>.stride * n, index: 0)
                }
                enc.setBytes(&batch, length: MemoryLayout<StampBatch>.stride, index: 1)
                dispatch(enc, pApply, x1 - x0 + 1, y1 - y0 + 1)
                markDirty(x0, y0, x1, y1)
            }
            i += n
        }
    }

    private func encodeDerive(_ enc: MTLComputeCommandEncoder, _ d: (x0: Int, y0: Int, x1: Int, y1: Int)) {
        let m = shadowSteps + 6
        let x0 = max(0, d.x0 - m), y0 = max(0, d.y0 - m)
        let x1 = min(width - 1, d.x1 + m), y1 = min(height - 1, d.y1 + m)
        guard x0 <= x1, y0 <= y1 else { return }
        var p = DeriveParams(rect: SIMD4(Int32(x0), Int32(y0), Int32(x1 - x0 + 1), Int32(y1 - y0 + 1)),
                             light: SIMD4(normalize(light), Float(shadowSteps)),
                             misc: SIMD4(texelWorld, 100, 0, 0))
        enc.setComputePipelineState(pDerive)
        enc.setTexture(heightTex, index: 0)
        enc.setTexture(surfaceTex, index: 1)
        enc.setBytes(&p, length: MemoryLayout<DeriveParams>.stride, index: 0)
        dispatch(enc, pDerive, x1 - x0 + 1, y1 - y0 + 1)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pipe: MTLComputePipelineState, _ w: Int, _ h: Int) {
        guard w > 0, h > 0 else { return }
        let side = pipe.maxTotalThreadsPerThreadgroup >= 256 ? 16 : 8
        let tg = MTLSize(width: side, height: side, depth: 1)
        let groups = MTLSize(width: (w + side - 1) / side, height: (h + side - 1) / side, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
    }
}

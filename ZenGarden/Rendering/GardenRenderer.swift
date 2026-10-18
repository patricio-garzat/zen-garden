import MetalKit
import simd

/// Draws the garden each frame and runs the sand simulation's GPU work first.
final class GardenRenderer: NSObject, MTKViewDelegate {
    private let ctx = MetalContext.shared
    private unowned let engine: GardenEngine

    private var bgPipe: MTLRenderPipelineState!
    private var sandPipe: MTLRenderPipelineState!
    private var framePipe: MTLRenderPipelineState!
    private var stonePipe: MTLRenderPipelineState!
    private var grainPipe: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!
    private var depthRead: MTLDepthStencilState!
    private var depthOff: MTLDepthStencilState!

    private var frameBuffer: MTLBuffer!
    private var frameVertexCount = 0
    private var grainTexture: MTLTexture!
    private var particleBuffers: [MTLBuffer] = []
    private var frameIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var lastTime: CFTimeInterval = 0

    var camera = GardenCamera()
    var uniforms = SceneUniforms()
    /// Called on the main queue with the next rendered frame.
    var captureHandler: ((CGImage?) -> Void)?

    init(engine: GardenEngine, view: MTKView) {
        self.engine = engine
        super.init()
        buildPipelines(view)
        let (fb, count) = FrameMesh.make(device: ctx.device, half: GardenEngine.gardenHalf,
                                         width: GardenEngine.frameWidth, height: GardenEngine.frameHeight)
        frameBuffer = fb
        frameVertexCount = count
        grainTexture = makeGrainTexture()
        particleBuffers = (0..<3).map { _ in
            ctx.device.makeBuffer(length: MemoryLayout<ParticleGPU>.stride * 256, options: .storageModeShared)!
        }
    }

    private func buildPipelines(_ view: MTKView) {
        let lib = ctx.library
        func pipe(_ vs: String, _ fs: String, blend: Bool) -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: vs)
            d.fragmentFunction = lib.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            do { return try ctx.device.makeRenderPipelineState(descriptor: d) } catch {
                fatalError("Pipeline \(vs)/\(fs): \(error)")
            }
        }
        bgPipe = pipe("bgVertex", "bgFragment", blend: false)
        sandPipe = pipe("sandVertex", "sandFragment", blend: false)
        framePipe = pipe("frameVertex", "frameFragment", blend: false)
        stonePipe = pipe("stoneVertex", "stoneFragment", blend: true)
        grainPipe = pipe("grainVertex", "grainFragment", blend: true)

        func depth(_ compare: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return ctx.device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(.less, true)
        depthRead = depth(.less, false)
        depthOff = depth(.always, false)
    }

    /// 256² tile of random grain data (normal jitter, albedo, glint seed), mipmapped.
    private func makeGrainTexture() -> MTLTexture {
        let size = 256
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size, mipmapped: true)
        d.usage = .shaderRead
        let tex = ctx.device.makeTexture(descriptor: d)!
        var rng = SeededRandom(seed: 2024)
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            // Sum of uniforms ≈ gaussian, centred on 128.
            let gx = (rng.unit() + rng.unit() + rng.unit()) / 3
            let gy = (rng.unit() + rng.unit() + rng.unit()) / 3
            bytes[i * 4 + 0] = UInt8(clampf(gx * 255, 0, 255))
            bytes[i * 4 + 1] = UInt8(clampf(gy * 255, 0, 255))
            bytes[i * 4 + 2] = UInt8(rng.unit() * 255)
            bytes[i * 4 + 3] = UInt8(rng.unit() * 255)
        }
        tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: bytes, bytesPerRow: size * 4)
        if let cb = ctx.queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex)
            blit.endEncoding()
            cb.commit()
        }
        return tex
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        engine.layoutChanged()
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTime == 0 ? Float(1.0 / 60.0) : min(Float(now - lastTime), 1.0 / 20.0)
        lastTime = now

        engine.frameUpdate(dt: dt)

        inflight.wait()
        guard let cb = ctx.queue.makeCommandBuffer() else { inflight.signal(); return }
        let sem = inflight
        let measure = engine.shouldMeasureGPU
        cb.addCompletedHandler { [weak engine] buffer in
            sem.signal()
            if measure {
                let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                DispatchQueue.main.async { engine?.reportGPUTime(ms) }
            }
        }

        engine.sim.encode(into: cb)

        guard let rpd = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            cb.commit()
            return
        }

        // Uniforms
        var u = uniforms
        u.viewProj = camera.viewProj
        u.invViewProj = camera.invViewProj
        u.cameraPos = SIMD4(camera.position, 1)
        u.camRight = SIMD4(camera.right, 0)
        u.camUp = SIMD4(camera.up, 0)
        u.hm = SIMD4(Float(engine.sim.width), Float(engine.sim.height), engine.sim.texelWorld, 100)
        var stones = engine.stones.gpuData()
        u.params.z = Float(stones.count)
        u.params.w = engine.time
        let stoneBytes: Int
        if stones.isEmpty {
            stones = [StoneGPU()]
            stoneBytes = MemoryLayout<StoneGPU>.stride
        } else {
            stoneBytes = MemoryLayout<StoneGPU>.stride * stones.count
        }
        let size = MemoryLayout<SceneUniforms>.stride

        // Table
        enc.setRenderPipelineState(bgPipe)
        enc.setDepthStencilState(depthOff)
        enc.setFragmentBytes(&u, length: size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // Sand
        enc.setRenderPipelineState(sandPipe)
        enc.setDepthStencilState(depthWrite)
        enc.setVertexBytes(&u, length: size, index: 0)
        enc.setFragmentBytes(&u, length: size, index: 0)
        enc.setFragmentBytes(&stones, length: stoneBytes, index: 1)
        enc.setFragmentTexture(engine.sim.surfaceTex, index: 0)
        enc.setFragmentTexture(grainTexture, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Frame
        enc.setRenderPipelineState(framePipe)
        enc.setVertexBuffer(frameBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: size, index: 1)
        enc.setFragmentBytes(&u, length: size, index: 0)
        enc.setFragmentBytes(&stones, length: stoneBytes, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: frameVertexCount)

        // Stones (opaque ones first, fading ones last)
        if u.params.z > 0 {
            enc.setRenderPipelineState(stonePipe)
            let order = stones.indices.sorted { (stones[$0].state.x >= 0.999 ? 0 : 1) < (stones[$1].state.x >= 0.999 ? 0 : 1) }
            let states = engine.stones.stones
            for i in order where i < states.count {
                var g = stones[i]
                let mesh = engine.stones.meshes[states[i].state.type]
                enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: size, index: 1)
                enc.setVertexBytes(&g, length: MemoryLayout<StoneGPU>.stride, index: 2)
                enc.setFragmentBytes(&u, length: size, index: 0)
                enc.setFragmentBytes(&g, length: MemoryLayout<StoneGPU>.stride, index: 1)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint16,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0)
            }
        }

        // Sand grains
        let pb = particleBuffers[frameIndex]
        let n = engine.particles.write(to: pb)
        if n > 0 {
            enc.setRenderPipelineState(grainPipe)
            enc.setDepthStencilState(depthRead)
            enc.setVertexBuffer(pb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: size, index: 1)
            enc.setFragmentBytes(&u, length: size, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
        enc.endEncoding()

        if let handler = captureHandler, !view.framebufferOnly {
            captureHandler = nil
            capture(drawable.texture, cb, handler)
        }

        cb.present(drawable)
        cb.commit()
        frameIndex = (frameIndex + 1) % particleBuffers.count
    }

    private func capture(_ tex: MTLTexture, _ cb: MTLCommandBuffer, _ handler: @escaping (CGImage?) -> Void) {
        let w = tex.width, h = tex.height
        guard let buffer = ctx.device.makeBuffer(length: w * h * 4, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { handler(nil); return }
        blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: w * 4, destinationBytesPerImage: w * h * 4)
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            let data = Data(bytes: buffer.contents(), count: w * h * 4)
            let image: CGImage? = {
                guard let provider = CGDataProvider(data: data as CFData) else { return nil }
                let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
                return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            }()
            DispatchQueue.main.async { handler(image) }
        }
    }
}

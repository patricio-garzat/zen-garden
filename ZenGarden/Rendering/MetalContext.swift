import Metal

/// Shared Metal device, queue and shader library.
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Zen Garden needs Metal.")
        }
        self.device = device
        self.queue = queue
        self.library = library
        queue.label = "Zen Garden"
    }

    func computePipeline(_ name: String) -> MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else { fatalError("Missing kernel \(name)") }
        do { return try device.makeComputePipelineState(function: function) } catch {
            fatalError("Kernel \(name) failed to compile: \(error)")
        }
    }

    func makeTexture(_ format: MTLPixelFormat, _ width: Int, _ height: Int,
                     usage: MTLTextureUsage = [.shaderRead, .shaderWrite], label: String) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        guard let t = device.makeTexture(descriptor: d) else { fatalError("Out of GPU memory") }
        t.label = label
        return t
    }
}

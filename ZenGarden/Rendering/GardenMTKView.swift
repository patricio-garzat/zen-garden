import MetalKit
import SwiftUI

/// The Metal view. Forwards touches to the engine.
final class GardenMTKView: MTKView {
    weak var engine: GardenEngine?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        engine?.layoutChanged()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        engine?.layoutChanged()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine, engine.acceptsTouches else { return }
        engine.wake()
        engine.controller.touchesBegan(touches, in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine, engine.acceptsTouches else { return }
        engine.wake()
        engine.controller.touchesMoved(touches, event: event, in: self)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine else { return }
        engine.controller.touchesEnded(touches, in: self, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let engine else { return }
        engine.controller.touchesEnded(touches, in: self, cancelled: true)
    }
}

struct GardenMetalView: UIViewRepresentable {
    let engine: GardenEngine

    func makeUIView(context: Context) -> GardenMTKView {
        let v = GardenMTKView(frame: .zero, device: MetalContext.shared.device)
        engine.attach(v)
        return v
    }

    func updateUIView(_ uiView: GardenMTKView, context: Context) {}
}

import SwiftUI
import SceneKit

struct VolumetricCoreView: NSViewRepresentable {

    let state: CoreState

    func makeCoordinator() -> CoreSceneController {
        CoreSceneController()
    }

    func makeNSView(context: Context) -> VolumetricSceneView {
        let sceneView = VolumetricSceneView(frame: .zero, options: nil)
        context.coordinator.attach(to: sceneView)
        return sceneView
    }

    func updateNSView(_ nsView: VolumetricSceneView, context: Context) {
        context.coordinator.updateState(state)
    }

    static func dismantleNSView(_ nsView: VolumetricSceneView, coordinator: CoreSceneController) {
        coordinator.teardown()
    }
}

final class VolumetricSceneView: SCNView {

    override var acceptsFirstResponder: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

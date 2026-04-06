import AppKit
import SceneKit

enum CoreState: Equatable {
    case standby
    case thinking
    case executing
    case error
}

extension CoreState {
    init(sessionStatus: AgentSessionStatus) {
        switch sessionStatus {
        case .queued, .preparing, .reviewing:
            self = .thinking
        case .running:
            self = .executing
        case .completed:
            self = .standby
        case .failed, .cancelled:
            self = .error
        }
    }
}

final class CoreSceneController: NSObject, SCNSceneRendererDelegate {

    let rootNode = SCNNode()
    let coreNode = SCNNode()
    let smokeNode = SCNNode()
    let sparksNode = SCNNode()
    let cameraNode = SCNNode()
    let lightNode = SCNNode()
    let emissiveLightNode = SCNNode()

    private let scene = SCNScene()
    private let vortexFieldNode = SCNNode()
    private let instabilityFieldNode = SCNNode()

    private weak var sceneView: SCNView?
    private var ringNodes: [SCNNode] = []
    private var ringBaseAngles: [SCNVector3] = []
    private var coreMaterials: [SCNMaterial] = []
    private let smokeSystem = SCNParticleSystem()
    private let sparksSystem = SCNParticleSystem()

    private var currentState: CoreState = .standby
    private var lastUpdateTime: TimeInterval?
    private var accumulatedRotation = SCNVector3Zero
    private var currentRotationVelocity = CoreDynamics.standby.rotationVelocity
    private var targetRotationVelocity = CoreDynamics.standby.rotationVelocity
    private var currentScale: CGFloat = 1.0
    private var targetScale: CGFloat = 1.0
    private var activeDynamics = CoreDynamics.standby

    private static let deepBlue = StudioColorTokens.AppKit.accentPrimary
    private static let mutedPurple = StudioColorTokens.AppKit.accentMuted
    private static let faultBlue = StudioColorTokens.AppKit.warningPrimary
    private static let neutralHighlight = StudioColorTokens.AppKit.textPrimary
    private static let smokeTint = StudioColorTokens.AppKit.accentMuted.withAlphaComponent(0.09)

    func attach(to sceneView: SCNView) {
        self.sceneView = sceneView

        configureScene()
        configureView(sceneView)
        applyDynamics(CoreDynamics.standby)
    }

    func teardown() {
        sceneView?.delegate = nil
        sceneView?.scene = nil
        sceneView = nil
        lastUpdateTime = nil
    }

    func updateState(_ state: CoreState) {
        guard currentState != state else { return }

        currentState = state
        let dynamics = dynamics(for: state)
        applyDynamics(dynamics)
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let camera = cameraNode.camera,
              let light = lightNode.light else {
            return
        }

        let deltaTime: CGFloat
        if let lastUpdateTime {
            deltaTime = max(1.0 / 240.0, min(CGFloat(time - lastUpdateTime), 1.0 / 30.0))
        } else {
            deltaTime = 1.0 / 60.0
        }
        self.lastUpdateTime = time

        let rotationSmoothing = smoothingFactor(for: deltaTime, response: 4.5)
        currentRotationVelocity = interpolate(currentRotationVelocity, toward: targetRotationVelocity, factor: rotationSmoothing)

        let rotationPulse = 1 + (activeDynamics.rotationPulseAmplitude * CGFloat(sin(time * 0.31)))
        accumulatedRotation.x += currentRotationVelocity.x * deltaTime * rotationPulse
        accumulatedRotation.y += currentRotationVelocity.y * deltaTime * rotationPulse
        accumulatedRotation.z += currentRotationVelocity.z * deltaTime * rotationPulse

        currentScale = interpolate(currentScale, toward: targetScale, factor: smoothingFactor(for: deltaTime, response: 5.5))
        let scaleVector = SCNVector3(repeating: currentScale)

        var resolvedRotation = SCNVector3(
            accumulatedRotation.x + activeDynamics.rotationOscillation.x * CGFloat(sin(time * 0.43)),
            accumulatedRotation.y + activeDynamics.rotationOscillation.y * CGFloat(sin((time * 0.29) + 0.8)),
            accumulatedRotation.z + activeDynamics.rotationOscillation.z * CGFloat(cos((time * 0.37) - 0.45))
        )

        if currentState == .error {
            resolvedRotation.x += CGFloat(sin(time * 4.2) * 0.028)
            resolvedRotation.z += CGFloat(cos(time * 3.6) * 0.018)
        }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        coreNode.eulerAngles = resolvedRotation
        coreNode.scale = scaleVector
        updateRingDrift(time: time)
        applyEmissive(for: time, light: light)
        camera.focusDistance = CGFloat(distance(from: cameraNode.presentation.position, to: coreNode.presentation.worldPosition))
        camera.bloomIntensity = activeDynamics.bloomIntensity
        SCNTransaction.commit()
    }

    private func applyDynamics(_ dynamics: CoreDynamics) {
        activeDynamics = dynamics
        targetRotationVelocity = dynamics.rotationVelocity
        targetScale = dynamics.targetScale

        configureParticleSystems(for: dynamics)
        configureFields(for: dynamics)
        lightNode.light?.intensity = dynamics.baseLightIntensity
    }

    private func configureScene() {
        scene.rootNode.addChildNode(rootNode)
        rootNode.addChildNode(coreNode)
        rootNode.addChildNode(smokeNode)
        rootNode.addChildNode(sparksNode)
        rootNode.addChildNode(cameraNode)
        rootNode.addChildNode(lightNode)
        rootNode.addChildNode(emissiveLightNode)
        rootNode.addChildNode(vortexFieldNode)
        rootNode.addChildNode(instabilityFieldNode)

        scene.background.contents = NSColor.clear
        scene.physicsWorld.gravity = SCNVector3Zero

        configureCoreGeometry()
        configureCamera()
        configureLighting()
        configureSmoke()
        configureSparks()
        configureFields(for: .standby)
    }

    private func configureView(_ sceneView: SCNView) {
        sceneView.scene = scene
        sceneView.pointOfView = cameraNode
        sceneView.delegate = self
        sceneView.backgroundColor = NSColor.clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = true
        sceneView.preferredFramesPerSecond = 60
        sceneView.autoenablesDefaultLighting = false
        sceneView.allowsCameraControl = false
        sceneView.loops = true
        sceneView.isPlaying = true
        sceneView.wantsLayer = true
        sceneView.layer?.isOpaque = false
    }

    private func configureCoreGeometry() {
        ringNodes.removeAll()
        ringBaseAngles.removeAll()
        coreMaterials.removeAll()

        if configureBundledCoreGeometry() {
            return
        }

        let ringConfigurations: [SCNVector3] = [
            SCNVector3(0.0, 0.0, 0.0),
            SCNVector3(0.92, 0.28, 0.44),
            SCNVector3(-0.74, 0.62, -0.58)
        ]

        for orientation in ringConfigurations {
            let torus = SCNTorus(ringRadius: 0.88, pipeRadius: 0.072)
            torus.ringSegmentCount = 160
            torus.pipeSegmentCount = 52

            let material = makeCoreMaterial()
            torus.firstMaterial = material
            coreMaterials.append(material)

            let node = SCNNode(geometry: torus)
            node.eulerAngles = orientation
            ringNodes.append(node)
            ringBaseAngles.append(orientation)
            coreNode.addChildNode(node)
        }
    }

    private func configureBundledCoreGeometry() -> Bool {
        for assetName in ["Studio.92GeneratedCore", "Studio.92CoreAsset"] {
            guard let assetURL = Bundle.main.url(forResource: assetName, withExtension: "usdz"),
                  let assetScene = try? SCNScene(url: assetURL, options: nil),
                  let importedRoot = assetScene.rootNode.childNode(withName: "root", recursively: true) else {
                continue
            }

            let preferredNames = Set(["CORE_RIG", "CORE_MAIN", "Torus"])
            let preferredNodes = importedRoot.childNodes.filter { preferredNames.contains($0.name ?? "") }
            let filteredNodes = preferredNodes.isEmpty
                ? importedRoot.childNodes.filter { $0.name != "_materials" && $0.name != "Cube" }
                : preferredNodes
            guard !filteredNodes.isEmpty else { continue }

            let assetRoot = SCNNode()
            assetRoot.name = "CORE_ASSET_ROOT"
            assetRoot.position = SCNVector3Zero
            assetRoot.scale = SCNVector3(repeating: 1.0)
            filteredNodes.forEach { assetRoot.addChildNode($0.clone()) }
            coreNode.addChildNode(assetRoot)

            coreMaterials = collectPreparedMaterials(in: assetRoot)
            let animatedNodes = assetRoot.childNodes.filter { $0.name != "_materials" }
            ringNodes = animatedNodes.isEmpty ? [assetRoot] : animatedNodes
            ringBaseAngles = ringNodes.map(\.eulerAngles)

            if !coreMaterials.isEmpty {
                return true
            }
        }

        return false
    }

    private func configureCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 31
        camera.zNear = 0.1
        camera.zFar = 40
        camera.wantsDepthOfField = true
        camera.focusDistance = 7.2
        camera.fStop = 2.15
        camera.apertureBladeCount = 6
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.bloomThreshold = 0.94
        camera.bloomIntensity = 0.035
        camera.bloomBlurRadius = 10
        camera.vignettingIntensity = 0.20
        camera.vignettingPower = 0.45

        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 7.2)
        cameraNode.look(at: SCNVector3Zero)
    }

    private func configureLighting() {
        let keyLight = SCNLight()
        keyLight.type = .spot
        keyLight.intensity = CoreDynamics.standby.baseLightIntensity
        keyLight.temperature = 6500
        keyLight.castsShadow = true
        keyLight.color = Self.neutralHighlight
        keyLight.spotInnerAngle = 18
        keyLight.spotOuterAngle = 44
        keyLight.attenuationStartDistance = 2.2
        keyLight.attenuationEndDistance = 12
        keyLight.shadowSampleCount = 32
        keyLight.shadowRadius = 7
        keyLight.shadowColor = StudioColorTokens.AppKit.backgroundPrimary.withAlphaComponent(0.28)
        keyLight.zNear = 0.1
        keyLight.zFar = 18

        lightNode.light = keyLight
        lightNode.position = SCNVector3(1.45, 1.95, 4.6)
        lightNode.look(at: SCNVector3(0, 0.02, 0))

        let emissiveLight = SCNLight()
        emissiveLight.type = .omni
        emissiveLight.intensity = 0
        emissiveLight.temperature = 6200
        emissiveLight.color = Self.deepBlue
        emissiveLight.castsShadow = false
        emissiveLight.attenuationStartDistance = 0.05
        emissiveLight.attenuationEndDistance = 1.55

        emissiveLightNode.light = emissiveLight
        emissiveLightNode.position = SCNVector3(0, 0, 0.08)
    }

    private func configureSmoke() {
        smokeSystem.loops = true
        smokeSystem.birthRate = activeDynamics.smokeBirthRate
        smokeSystem.particleLifeSpan = 2.2
        smokeSystem.particleLifeSpanVariation = 0.45
        smokeSystem.particleVelocity = 0.04
        smokeSystem.particleVelocityVariation = 0.025
        smokeSystem.particleSize = 0.12
        smokeSystem.particleSizeVariation = 0.05
        smokeSystem.particleColor = Self.smokeTint
        smokeSystem.particleColorVariation = SCNVector4(0.015, 0.015, 0.02, 0.02)
        smokeSystem.blendMode = .alpha
        smokeSystem.emitterShape = SCNSphere(radius: 0.42)
        smokeSystem.birthLocation = .volume
        smokeSystem.birthDirection = .constant
        smokeSystem.emittingDirection = SCNVector3(0.20, 0.74, -0.16)
        smokeSystem.spreadingAngle = 12
        smokeSystem.orientationMode = .billboardScreenAligned
        smokeSystem.particleImage = Self.makeSmokeParticleImage(size: 192)
        smokeSystem.particleAngleVariation = 8
        smokeSystem.particleAngularVelocity = 0.03
        smokeSystem.particleAngularVelocityVariation = 0.05
        smokeSystem.particleMass = 0.012
        smokeSystem.particleMassVariation = 0.004
        smokeSystem.dampingFactor = 0.52
        smokeSystem.speedFactor = 0.52
        smokeSystem.acceleration = SCNVector3(0.018, 0.055, -0.012)
        smokeSystem.isLightingEnabled = true

        smokeNode.addParticleSystem(smokeSystem)
    }

    private func configureSparks() {
        let emitterShape = SCNTorus(ringRadius: 0.78, pipeRadius: 0.06)
        emitterShape.ringSegmentCount = 96
        emitterShape.pipeSegmentCount = 24

        sparksSystem.loops = true
        sparksSystem.birthRate = 0
        sparksSystem.particleLifeSpan = 0.28
        sparksSystem.particleLifeSpanVariation = 0.10
        sparksSystem.particleVelocity = 0.52
        sparksSystem.particleVelocityVariation = 0.16
        sparksSystem.particleSize = 0.014
        sparksSystem.particleSizeVariation = 0.007
        sparksSystem.particleColor = Self.neutralHighlight.withAlphaComponent(0.78)
        sparksSystem.blendMode = .additive
        sparksSystem.emitterShape = emitterShape
        sparksSystem.birthLocation = .surface
        sparksSystem.birthDirection = .random
        sparksSystem.spreadingAngle = 18
        sparksSystem.orientationMode = .billboardScreenAligned
        sparksSystem.particleImage = Self.makeParticleImage(
            size: 96,
            centerColor: StudioColorTokens.AppKit.textPrimary,
            edgeColor: NSColor.clear
        )
        sparksSystem.particleAngularVelocity = 0
        sparksSystem.particleMass = 0.01
        sparksSystem.dampingFactor = 0.16
        sparksSystem.speedFactor = 0.92

        sparksNode.addParticleSystem(sparksSystem)
    }

    private func configureFields(for dynamics: CoreDynamics) {
        let vortexField = vortexFieldNode.physicsField ?? SCNPhysicsField.vortex()
        vortexField.strength = dynamics.vortexStrength
        vortexField.falloffExponent = 2.2
        vortexField.minimumDistance = 0.05
        vortexField.direction = SCNVector3(0.08, 1, -0.05)
        vortexField.halfExtent = SCNVector3(repeating: dynamics.vortexExtent)
        vortexFieldNode.physicsField = vortexField

        let instabilityField = instabilityFieldNode.physicsField ?? SCNPhysicsField.noiseField(smoothness: 0.82, animationSpeed: 0.35)
        instabilityField.strength = dynamics.instabilityStrength
        instabilityField.halfExtent = SCNVector3(repeating: max(dynamics.vortexExtent, 0.8))
        instabilityField.minimumDistance = 0.1
        instabilityFieldNode.physicsField = instabilityField
    }

    private func configureParticleSystems(for dynamics: CoreDynamics) {
        smokeSystem.birthRate = dynamics.smokeBirthRate
        smokeSystem.particleVelocity = dynamics.smokeVelocity
        smokeSystem.speedFactor = dynamics.smokeSpeed
        sparksSystem.birthRate = dynamics.sparkBirthRate
    }

    private func updateRingDrift(time: TimeInterval) {
        for (index, ring) in ringNodes.enumerated() {
            let base = ringBaseAngles[index]
            let phase = time * activeDynamics.ringOrbitSpeed * (1 + Double(index) * 0.18)
            let wobble = activeDynamics.ringWobble
            let driftX = CGFloat(sin(phase) * Double(wobble) * 0.18)
            let driftY = CGFloat(cos((phase * 0.62) + Double(index) * 0.4) * Double(wobble) * 0.12)
            let driftZ = CGFloat(sin((phase * 0.88) - Double(index) * 0.3) * Double(wobble) * 0.26)

            ring.eulerAngles = SCNVector3(
                base.x + driftX,
                base.y + driftY,
                base.z + driftZ
            )
        }
    }

    private func applyEmissive(for time: TimeInterval, light: SCNLight) {
        let materialIntensity: CGFloat
        let sourceLightIntensity: CGFloat
        let emissiveColor: NSColor

        switch currentState {
        case .standby:
            emissiveColor = StudioColorTokens.AppKit.backgroundPrimary
            materialIntensity = 0
            sourceLightIntensity = 0
        case .thinking:
            let pulse = CGFloat(0.5 + 0.5 * sin(time * 1.35))
            emissiveColor = Self.mutedPurple
            materialIntensity = 0.028 + 0.040 * pulse
            sourceLightIntensity = 28 + 26 * pulse
        case .executing:
            let pulse = CGFloat(0.5 + 0.5 * sin(time * 2.4))
            emissiveColor = Self.deepBlue
            materialIntensity = 0.055 + 0.070 * pulse
            sourceLightIntensity = 54 + 42 * pulse
        case .error:
            let pulse = CGFloat(0.5 + 0.5 * sin(time * 3.2))
            emissiveColor = Self.faultBlue
            materialIntensity = 0.045 + 0.060 * pulse
            sourceLightIntensity = 40 + 36 * pulse
        }

        let resolvedColor = emissiveColor.scaled(brightness: materialIntensity)
        for material in coreMaterials {
            material.emission.contents = resolvedColor
        }

        light.color = Self.neutralHighlight
        light.intensity = activeDynamics.baseLightIntensity
        emissiveLightNode.light?.color = emissiveColor
        emissiveLightNode.light?.intensity = sourceLightIntensity
    }

    private func collectPreparedMaterials(in rootNode: SCNNode) -> [SCNMaterial] {
        var materials: [SCNMaterial] = []
        let allNodes = [rootNode] + rootNode.childNodes(passingTest: { _, _ in true })

        for node in allNodes {
            guard let geometry = node.geometry else { continue }
            let resolvedMaterials = geometry.materials.isEmpty
                ? [makeCoreMaterial()]
                : geometry.materials.map { makeCoreMaterial(from: $0) }
            geometry.materials = resolvedMaterials
            materials.append(contentsOf: resolvedMaterials)
        }

        return materials
    }

    private func makeCoreMaterial(from source: SCNMaterial? = nil) -> SCNMaterial {
        let material = (source?.copy() as? SCNMaterial) ?? SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = source?.diffuse.contents ?? StudioColorTokens.AppKit.backgroundPrimary
        material.metalness.contents = 0.96
        material.roughness.contents = Self.makeDirectionalRoughnessMap(size: 256)
        material.roughness.contentsTransform = SCNMatrix4MakeScale(1.6, 5.4, 1)
        material.roughness.wrapS = .repeat
        material.roughness.wrapT = .repeat
        material.normal.contents = Self.makeAnisotropicNormalMap(size: 256)
        material.normal.intensity = 0.22
        material.normal.contentsTransform = SCNMatrix4MakeScale(1.4, 6.2, 1)
        material.normal.wrapS = .repeat
        material.normal.wrapT = .repeat
        material.emission.contents = StudioColorTokens.AppKit.backgroundPrimary
        material.shaderModifiers = [
            .surface: Self.coreSurfaceShader,
            .fragment: Self.coreFinishShader
        ]
        material.isDoubleSided = false
        return material
    }

    private func dynamics(for state: CoreState) -> CoreDynamics {
        switch state {
        case .standby:
            return .standby
        case .thinking:
            return CoreDynamics(
                rotationVelocity: SCNVector3(0.009, 0.034, 0.006),
                targetScale: 1.01,
                smokeBirthRate: 8,
                smokeVelocity: 0.05,
                smokeSpeed: 0.58,
                sparkBirthRate: 0,
                vortexStrength: 0.28,
                instabilityStrength: 0,
                ringWobble: 0.045,
                ringOrbitSpeed: 0.38,
                baseLightIntensity: 350,
                bloomIntensity: 0.045,
                vortexExtent: 0.92,
                rotationPulseAmplitude: 0.05,
                rotationOscillation: SCNVector3(0.014, 0.022, 0.010)
            )
        case .executing:
            return CoreDynamics(
                rotationVelocity: SCNVector3(0.012, 0.048, 0.008),
                targetScale: 1.03,
                smokeBirthRate: 12,
                smokeVelocity: 0.07,
                smokeSpeed: 0.68,
                sparkBirthRate: 44,
                vortexStrength: 0.58,
                instabilityStrength: 0,
                ringWobble: 0.065,
                ringOrbitSpeed: 0.55,
                baseLightIntensity: 360,
                bloomIntensity: 0.055,
                vortexExtent: 1.10,
                rotationPulseAmplitude: 0.07,
                rotationOscillation: SCNVector3(0.018, 0.026, 0.012)
            )
        case .error:
            return CoreDynamics(
                rotationVelocity: SCNVector3(0.010, 0.036, 0.007),
                targetScale: 1.015,
                smokeBirthRate: 7,
                smokeVelocity: 0.044,
                smokeSpeed: 0.54,
                sparkBirthRate: 0,
                vortexStrength: 0.12,
                instabilityStrength: 0.12,
                ringWobble: 0.08,
                ringOrbitSpeed: 0.42,
                baseLightIntensity: 355,
                bloomIntensity: 0.05,
                vortexExtent: 0.84,
                rotationPulseAmplitude: 0.08,
                rotationOscillation: SCNVector3(0.020, 0.028, 0.014)
            )
        }
    }

    private func smoothingFactor(for deltaTime: CGFloat, response: CGFloat) -> CGFloat {
        1 - exp(-response * deltaTime)
    }

    private func interpolate(_ current: CGFloat, toward target: CGFloat, factor: CGFloat) -> CGFloat {
        current + (target - current) * factor
    }

    private func interpolate(_ current: SCNVector3, toward target: SCNVector3, factor: CGFloat) -> SCNVector3 {
        let resolvedX = current.x + (target.x - current.x) * factor
        let resolvedY = current.y + (target.y - current.y) * factor
        let resolvedZ = current.z + (target.z - current.z) * factor
        return SCNVector3(resolvedX, resolvedY, resolvedZ)
    }

    private func distance(from lhs: SCNVector3, to rhs: SCNVector3) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        let dz = lhs.z - rhs.z
        let squaredDistance = (dx * dx) + (dy * dy) + (dz * dz)
        return squaredDistance.squareRoot()
    }

    private static func makeParticleImage(size: CGFloat, centerColor: NSColor, edgeColor: NSColor) -> NSImage {
        let imageSize = NSSize(width: size, height: size)
        let image = NSImage(size: imageSize)

        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: imageSize)
        NSColor.clear.setFill()
        rect.fill()

        let gradient = NSGradient(colors: [centerColor, edgeColor])
        gradient?.draw(in: NSBezierPath(ovalIn: rect), relativeCenterPosition: .zero)

        return image
    }

    private static func makeSmokeParticleImage(size: CGFloat) -> NSImage {
        let imageSize = NSSize(width: size, height: size)
        let image = NSImage(size: imageSize)
        let rect = NSRect(origin: .zero, size: imageSize)

        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.clear.setFill()
        rect.fill()

        let wispRects: [(NSRect, CGFloat, CGFloat)] = [
            (NSRect(x: size * 0.36, y: size * 0.10, width: size * 0.16, height: size * 0.76), -10, 0.85),
            (NSRect(x: size * 0.44, y: size * 0.16, width: size * 0.12, height: size * 0.58), 8, 0.52),
            (NSRect(x: size * 0.28, y: size * 0.22, width: size * 0.10, height: size * 0.42), -18, 0.34)
        ]

        for (wispRect, angle, alpha) in wispRects {
            guard let gradient = NSGradient(colors: [
                StudioColorTokens.AppKit.textPrimary.withAlphaComponent(0),
                StudioColorTokens.AppKit.textPrimary.withAlphaComponent(alpha * 0.38),
                StudioColorTokens.AppKit.textPrimary.withAlphaComponent(alpha * 0.14),
                StudioColorTokens.AppKit.textPrimary.withAlphaComponent(0)
            ]) else {
                continue
            }

            let path = NSBezierPath(
                roundedRect: wispRect,
                xRadius: wispRect.width * 0.52,
                yRadius: wispRect.width * 0.52
            )

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            gradient.draw(in: path, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }

        return image
    }

    private static func makeDirectionalRoughnessMap(size: Int) -> NSImage {
        makeTexture(size: size) { u, v in
            let stripe = 0.5 + 0.5 * sin((v * 156) + (u * 18))
            let crosswave = 0.5 + 0.5 * sin((u * 31) - (v * 22))
            let grain = fract(sin((u * 127.1) + (v * 311.7)) * 43758.5453)
            let pattern = max(0, min(1, (stripe * 0.52) + (crosswave * 0.20) + (grain * 0.28)))
            let roughness = 0.20 + (0.30 * pattern)
            let channel = UInt8(roughness * 255)
            return (channel, channel, channel, 255)
        }
    }

    private static func makeAnisotropicNormalMap(size: Int) -> NSImage {
        makeTexture(size: size) { u, v in
            let striation = sin((v * 168) + (u * 14))
            let micro = sin((v * 312) - (u * 9))
            let grain = (fract(sin((u * 53.1) + (v * 171.7)) * 24634.6345) * 2) - 1

            let nx = (striation * 0.16) + (micro * 0.05) + (grain * 0.03)
            let ny = (grain * 0.05) + (micro * 0.02)
            let nz = sqrt(max(0.32, 1 - (nx * nx) - (ny * ny)))

            let r = UInt8(max(0, min(255, Int(((nx * 0.5) + 0.5) * 255))))
            let g = UInt8(max(0, min(255, Int(((ny * 0.5) + 0.5) * 255))))
            let b = UInt8(max(0, min(255, Int(((nz * 0.5) + 0.5) * 255))))
            return (r, g, b, 255)
        }
    }

    private static func makeTexture(size: Int, pixel: (_ u: Double, _ v: Double) -> (UInt8, UInt8, UInt8, UInt8)) -> NSImage {
        let bytesPerRow = size * 4
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bytesPerRow,
            bitsPerPixel: 32
        ), let bitmapData = representation.bitmapData else {
            return NSImage(size: NSSize(width: size, height: size))
        }

        for y in 0..<size {
            for x in 0..<size {
                let u = Double(x) / Double(max(size - 1, 1))
                let v = Double(y) / Double(max(size - 1, 1))
                let (r, g, b, a) = pixel(u, v)
                let offset = (y * bytesPerRow) + (x * 4)
                bitmapData[offset] = r
                bitmapData[offset + 1] = g
                bitmapData[offset + 2] = b
                bitmapData[offset + 3] = a
            }
        }

        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(representation)
        return image
    }

    private static func fract(_ value: Double) -> Double {
        value - floor(value)
    }

    private static let coreSurfaceShader = """
    #pragma body
    float radialDistance = length(_surface.position.xyz);
    float stripe = 0.5 + 0.5 * sin((_surface.diffuseTexcoord.y * 120.0) + (_surface.position.y * 16.0));
    float crosswave = 0.5 + 0.5 * sin((_surface.position.x * 9.0) - (_surface.position.z * 11.0));
    float grain = fract(sin(dot(_surface.position.xyz, float3(31.17, 17.73, 27.91))) * 43758.5453);
    float roughPattern = clamp((stripe * 0.48) + (crosswave * 0.22) + (grain * 0.30), 0.0, 1.0);
    _surface.roughness = mix(0.20, 0.50, roughPattern);
    _surface.metalness = 0.96;

    float innerMask = 1.0 - smoothstep(0.86, 0.98, radialDistance);
    float channelMask = smoothstep(0.42, 0.88, stripe);
    _surface.emission.rgb *= innerMask * mix(0.52, 1.0, channelMask);
    """

    private static let coreFinishShader = """
    #pragma body
    float3 normalDirection = normalize(_surface.normal);
    float3 viewDirection = normalize(-_surface.view);
    float edge = pow(saturate(1.0 - dot(normalDirection, viewDirection)), 4.6);
    float brushed = 0.5 + 0.5 * sin((_surface.position.y * 18.0) + (_surface.position.x * 6.0));
    float directional = pow(saturate(dot(reflect(-viewDirection, normalDirection), normalize(float3(0.18, 0.96, 0.20)))), 22.0);
    float sheen = directional * (0.028 + (brushed * 0.042));
    float3 edgeTint = mix(float3(0.04, 0.07, 0.15), float3(0.08, 0.05, 0.13), brushed);
    _output.color.rgb += edgeTint * (edge * 0.08);
    _output.color.rgb += edgeTint * sheen;
    _output.color.rgb *= 1.0 - ((1.0 - edge) * 0.06);
    """
}

private struct CoreDynamics {
    let rotationVelocity: SCNVector3
    let targetScale: CGFloat
    let smokeBirthRate: CGFloat
    let smokeVelocity: CGFloat
    let smokeSpeed: CGFloat
    let sparkBirthRate: CGFloat
    let vortexStrength: CGFloat
    let instabilityStrength: CGFloat
    let ringWobble: CGFloat
    let ringOrbitSpeed: Double
    let baseLightIntensity: CGFloat
    let bloomIntensity: CGFloat
    let vortexExtent: CGFloat
    let rotationPulseAmplitude: CGFloat
    let rotationOscillation: SCNVector3

    static let standby = CoreDynamics(
        rotationVelocity: SCNVector3(0.006, 0.022, 0.004),
        targetScale: 1.0,
        smokeBirthRate: 5,
        smokeVelocity: 0.036,
        smokeSpeed: 0.48,
        sparkBirthRate: 0,
        vortexStrength: 0,
        instabilityStrength: 0,
        ringWobble: 0.028,
        ringOrbitSpeed: 0.24,
        baseLightIntensity: 340,
        bloomIntensity: 0.035,
        vortexExtent: 0.7,
        rotationPulseAmplitude: 0.03,
        rotationOscillation: SCNVector3(0.012, 0.018, 0.008)
    )
}

private extension NSColor {
    func scaled(brightness: CGFloat) -> NSColor {
        let clamped = max(0, min(brightness, 1))
        let rgb = usingColorSpace(.deviceRGB) ?? self
        return NSColor(
            red: rgb.redComponent * clamped,
            green: rgb.greenComponent * clamped,
            blue: rgb.blueComponent * clamped,
            alpha: 1
        )
    }
}

private extension SCNVector3 {
    init(repeating value: CGFloat) {
        self.init(value, value, value)
    }
}

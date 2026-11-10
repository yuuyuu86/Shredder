import RealityKit
import SwiftUI

/// RealityKit で描く 3D シュレッダー（仕様 14）。
/// マットアルミの角丸ボディ、上部の細長い投入口、小さなステータス LED で構成する。
struct ShredderStage: View {
    let phase: ShredderPhase
    let settings: ShredderSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var scene = ShredderScene()

    var body: some View {
        RealityView { content in
            scene.build(dark: colorScheme == .dark)
            content.add(scene.root)
            content.add(scene.camera)
        } update: { _ in
            scene.apply(phase, animated: settings.animationEnabled && !reduceMotion, effects: settings.completionEffectEnabled)
        }
        .accessibilityHidden(true)
    }
}

/// シーン内のエンティティを保持し、状態の変化に合わせてアニメーションさせる。
@MainActor
final class ShredderScene {
    let root = Entity()
    let camera = PerspectiveCamera()
    private let body = Entity()
    private var led = ModelEntity()
    private var paper = ModelEntity()
    private var shreds = Entity()
    private var lastPhase: ShredderPhase?
    private var built = false

    // 寸法（メートル）。
    private let width: Float = 0.30
    private let height: Float = 0.24
    private let depth: Float = 0.18

    func build(dark: Bool) {
        guard !built else { return }
        built = true

        camera.camera.fieldOfViewInDegrees = 32
        camera.position = [0.22, 0.24, 0.62]
        camera.look(at: [0, 0.02, 0], from: camera.position, relativeTo: nil)

        // 本体（マットアルミニウム / スペースブラック）。
        var aluminum = PhysicallyBasedMaterial()
        aluminum.baseColor = .init(tint: dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.82, alpha: 1))
        aluminum.metallic = 0.85
        aluminum.roughness = 0.42
        let shell = ModelEntity(
            mesh: .generateBox(width: width, height: height, depth: depth, cornerRadius: 0.028),
            materials: [aluminum]
        )
        body.addChild(shell)

        // 上面の細長い投入口。
        let slot = ModelEntity(
            mesh: .generateBox(width: width * 0.72, height: 0.004, depth: 0.014, cornerRadius: 0.002),
            materials: [SimpleMaterial(color: NSColor(white: 0.05, alpha: 1), roughness: 0.9, isMetallic: false)]
        )
        slot.position = [0, height / 2 + 0.0005, -0.01]
        body.addChild(slot)

        // 前面下部の分割ライン（ゴミ受け）。
        let seam = ModelEntity(
            mesh: .generateBox(width: width * 0.98, height: 0.002, depth: 0.001),
            materials: [SimpleMaterial(color: NSColor(white: 0.35, alpha: 1), roughness: 0.8, isMetallic: false)]
        )
        seam.position = [0, -height * 0.18, depth / 2 + 0.0005]
        body.addChild(seam)

        // ステータス LED。
        led = ModelEntity(mesh: .generateSphere(radius: 0.0055), materials: [UnlitMaterial(color: Self.ledIdle)])
        led.position = [width / 2 - 0.03, height / 2 - 0.03, depth / 2 + 0.001]
        body.addChild(led)

        // 投入される紙（ファイル）。
        var paperMaterial = PhysicallyBasedMaterial()
        paperMaterial.baseColor = .init(tint: .white)
        paperMaterial.roughness = 1.0
        paper = ModelEntity(mesh: .generateBox(width: 0.11, height: 0.15, depth: 0.002, cornerRadius: 0.004), materials: [paperMaterial])
        paper.position = [0, height / 2 + 0.11, -0.01]
        paper.isEnabled = false
        body.addChild(paper)

        // 裁断された紙片のパーティクル。
        shreds.position = [0, -height / 2 + 0.02, depth / 2 + 0.01]
        body.addChild(shreds)

        root.addChild(body)

        let key = DirectionalLight()
        key.light.intensity = 3_000
        key.look(at: .zero, from: [0.4, 0.8, 0.6], relativeTo: nil)
        root.addChild(key)
        let fill = PointLight()
        fill.light.intensity = 9_000
        fill.position = [-0.4, 0.2, 0.5]
        root.addChild(fill)
    }

    func apply(_ phase: ShredderPhase, animated: Bool, effects: Bool) {
        guard phase != lastPhase else { return }
        let previous = lastPhase
        lastPhase = phase

        switch phase {
        case .idle:
            setLED(Self.ledIdle)
            reset(animated: animated)
        case .hovering:
            setLED(Self.ledHover)
            if animated {
                // 投入口が反応し、本体がわずかに動く。
                body.move(to: Transform(scale: [1.02, 1.02, 1.02], rotation: simd_quatf(angle: 0.04, axis: [0, 1, 0])), relativeTo: root, duration: 0.25, timingFunction: .easeOut)
            }
        case .analyzing, .confirming:
            setLED(Self.ledBusy)
            showPaper(animated: animated)
        case .deleting:
            setLED(Self.ledBusy)
            showPaper(animated: animated)
        case .success:
            // 成功時のみ吸い込み・裁断・紙片・LED を再生する（仕様 14.3）。
            setLED(effects ? Self.ledSuccess : Self.ledIdle)
            if previous == .deleting || previous == .confirming {
                shred(animated: animated, effects: effects)
            }
        case .error:
            // エラー時は成功演出を再生しない。
            setLED(Self.ledError)
            paper.isEnabled = false
            reset(animated: animated)
        }
    }

    // MARK: - Animations

    private func showPaper(animated: Bool) {
        guard !paper.isEnabled else { return }
        paper.isEnabled = true
        var start = paper.transform
        start.translation = [0, height / 2 + 0.2, -0.01]
        paper.transform = start
        var end = start
        end.translation = [0, height / 2 + 0.085, -0.01]
        if animated {
            paper.move(to: end, relativeTo: body, duration: 0.45, timingFunction: .easeOut)
        } else {
            paper.transform = end
        }
    }

    private func shred(animated: Bool, effects: Bool) {
        guard animated else {
            paper.isEnabled = false
            return
        }
        paper.isEnabled = true
        var inside = paper.transform
        inside.translation = [0, height / 2 - 0.08, -0.01]
        inside.scale = [1, 0.4, 1]
        paper.move(to: inside, relativeTo: body, duration: 0.7, timingFunction: .easeIn)

        // 裁断中の振動。
        let shake = Transform(scale: .one, rotation: simd_quatf(angle: 0.012, axis: [0, 0, 1]), translation: [0.002, 0, 0])
        body.move(to: shake, relativeTo: root, duration: 0.08)
        Task { @MainActor in
            for step in 0..<6 {
                try? await Task.sleep(for: .milliseconds(90))
                let sign: Float = step.isMultiple(of: 2) ? -1 : 1
                body.move(to: Transform(scale: .one, rotation: simd_quatf(angle: 0.012 * sign, axis: [0, 0, 1]), translation: [0.002 * sign, 0, 0]), relativeTo: root, duration: 0.08)
            }
            body.move(to: Transform.identity, relativeTo: root, duration: 0.15)
            paper.isEnabled = false
        }

        if effects { burstShreds() }
    }

    private func burstShreds() {
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = [width * 0.7, 0.002, 0.01]
        emitter.speed = 0.25
        emitter.speedVariation = 0.12
        emitter.emissionDirection = [0, -0.4, 1]
        emitter.burstCount = 220
        emitter.burstCountVariation = 40
        emitter.mainEmitter.birthRate = 0
        emitter.mainEmitter.lifeSpan = 1.4
        emitter.mainEmitter.size = 0.007
        emitter.mainEmitter.sizeVariation = 0.003
        emitter.mainEmitter.acceleration = [0, -0.9, 0]
        emitter.mainEmitter.angularSpeed = 6
        emitter.mainEmitter.angularSpeedVariation = 4
        emitter.mainEmitter.color = .constant(.single(.white))
        emitter.mainEmitter.billboardMode = .free(axis: [0, 1, 0], variation: 1)
        emitter.burst()
        shreds.components.set(emitter)
    }

    private func reset(animated: Bool) {
        paper.isEnabled = false
        if animated {
            body.move(to: Transform.identity, relativeTo: root, duration: 0.25, timingFunction: .easeInOut)
        } else {
            body.transform = .identity
        }
    }

    private func setLED(_ color: NSColor) {
        led.model?.materials = [UnlitMaterial(color: color)]
    }

    static let ledIdle = NSColor(red: 0.55, green: 0.85, blue: 0.6, alpha: 1)
    static let ledHover = NSColor(red: 0.35, green: 0.65, blue: 1, alpha: 1)
    static let ledBusy = NSColor(red: 1, green: 0.72, blue: 0.2, alpha: 1)
    static let ledSuccess = NSColor(red: 0.2, green: 1, blue: 0.4, alpha: 1)
    static let ledError = NSColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
}

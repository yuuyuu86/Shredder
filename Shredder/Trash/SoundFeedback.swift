import AppKit
import AVFoundation
import Foundation
import Observation

/// シュレッダーのサウンドフィードバック（仕様 14.4）。項目ごとに設定でオン・オフできる。
/// システム全体の音量・ミュート設定に従い、通知音量ではなく通常の出力で鳴らす。
@MainActor
@Observable
final class SoundFeedback {
    var shredderSoundEnabled = true
    var dragReactionEnabled = true
    var completionEnabled = true

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var shredBuffer: AVAudioPCMBuffer?
    @ObservationIgnored private var tickBuffer: AVAudioPCMBuffer?
    @ObservationIgnored private var started = false

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        shredBuffer = Self.makeShredSound(format: format)
        tickBuffer = Self.makeTick(format: format)
    }

    /// 裁断音（ノイズに低いうなりを重ねて合成）。
    func playShredding() {
        guard shredderSoundEnabled, let shredBuffer else { return }
        play(shredBuffer)
    }

    /// ドラッグ時の小さな反応音。
    func playDragReaction() {
        guard dragReactionEnabled, let tickBuffer else { return }
        play(tickBuffer)
    }

    func playCompletion() {
        guard completionEnabled else { return }
        NSSound(named: "Glass")?.play()
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        do {
            if !started {
                try engine.start()
                started = true
            }
            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            player.play()
        } catch {
            // 音が鳴らせなくても削除処理には影響させない。
        }
    }

    static func makeShredSound(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let duration = 1.1
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        var generator = SystemRandomNumberGenerator()
        var smoothed: Float = 0
        for frame in 0..<Int(frames) {
            let t = Double(frame) / format.sampleRate
            let envelope = Float(min(t / 0.05, 1) * min((duration - t) / 0.25, 1))
            let noise = Float.random(in: -1...1, using: &generator)
            smoothed = smoothed * 0.6 + noise * 0.4
            let hum = Float(sin(2 * .pi * 95 * t) * 0.35 + sin(2 * .pi * 190 * t) * 0.15)
            // 紙を裁断する断続的な感じを出すため 22Hz で振幅を揺らす。
            let chop = Float(0.65 + 0.35 * sin(2 * .pi * 22 * t))
            data[frame] = (smoothed * 0.35 * chop + hum * 0.25) * envelope * 0.6
        }
        return buffer
    }

    static func makeTick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.06)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let data = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) {
            let t = Double(frame) / format.sampleRate
            data[frame] = Float(sin(2 * .pi * 880 * t) * exp(-t * 60)) * 0.25
        }
        return buffer
    }
}

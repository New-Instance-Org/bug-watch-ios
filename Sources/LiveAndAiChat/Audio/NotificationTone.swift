import Foundation
import AVFoundation

/// Procedurally-synthesised two-note chirp (E5 → A5) matching the web
/// `core/sound.ts` and Android `NotificationTone.kt`. No bundled audio
/// asset — PCM is generated on the fly and pushed through an
/// `AVAudioEngine` pipeline.
///
/// Audio session category is `.ambient` so playback respects the user's
/// silent-mode switch and never ducks other audio.
public final class NotificationTone {

    public static let shared = NotificationTone()

    public var isEnabled: Bool = true

    private let sampleRate: Double = 44_100
    private let note1Hz: Double = 659.25
    private let note2Hz: Double = 880.0
    private let note1Ms: Int = 120
    private let note2Ms: Int = 180
    private let gapMs: Int = 80
    private let gain: Float = 0.12

    private let queue = DispatchQueue(label: "cloud.newinstance.liveandaichat.tone", qos: .userInitiated)

    private init() {}

    public func play() {
        guard isEnabled else { return }
        queue.async { [weak self] in
            self?.playInternal()
        }
    }

    private func playInternal() {
        let totalFrames = AVAudioFrameCount(Double(note1Ms + gapMs + note2Ms) * sampleRate / 1000.0)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return }
        buffer.frameLength = totalFrames
        guard let channel = buffer.floatChannelData?[0] else { return }

        // Silence first.
        for i in 0..<Int(totalFrames) { channel[i] = 0 }

        let note1Samples = Int(sampleRate * Double(note1Ms) / 1000.0)
        let gapSamples = Int(sampleRate * Double(gapMs) / 1000.0)
        let note2Samples = Int(sampleRate * Double(note2Ms) / 1000.0)

        synthesize(into: channel, offset: 0, length: note1Samples, freq: note1Hz)
        synthesize(
            into: channel,
            offset: note1Samples + gapSamples,
            length: note2Samples,
            freq: note2Hz
        )

        // Set up a transient engine. Released after playback completes
        // (the strong references survive in the closure until then).
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            #if canImport(UIKit)
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            #endif
            try engine.start()
        } catch {
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: []) { [engine] in
            // Tear down engine on completion. AVAudioEngine retains the
            // capture closure, so referencing `engine` here keeps it
            // alive for the duration of playback.
            engine.stop()
        }
        player.play()
    }

    private func synthesize(
        into buffer: UnsafeMutablePointer<Float>,
        offset: Int,
        length: Int,
        freq: Double
    ) {
        let attackSamples = Int(sampleRate * 0.010)  // 10 ms
        let decayTau = Double(length) / 4.0
        let omega = 2.0 * Double.pi * freq / sampleRate
        for i in 0..<length {
            let attackEnv = i < attackSamples ? Double(i) / Double(max(1, attackSamples)) : 1.0
            let decayEnv = exp(-Double(i) / decayTau)
            let sample = sin(omega * Double(i)) * Double(gain) * attackEnv * decayEnv
            buffer[offset + i] = Float(sample)
        }
    }
}

//
//  SynthClickEngine.swift
//  Tactile
//

import AVFoundation

/// Synthesized click sounds in the styles keyboard people describe switches
/// with: thock, clack, cream, silky, bubble. Each is generated in code (a
/// short tonal body plus shaped noise), so pitch is adjustable and every
/// click can vary slightly for a natural feel. No audio files involved.
@MainActor
final class SynthClickEngine {
    static let shared = SynthClickEngine()

    enum Style: String, CaseIterable {
        case thock
        case clack
        case cream
        case silky
        case bubble

        static let prefix = "synth:"

        var identifier: String { Self.prefix + rawValue }

        var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

        init?(identifier: String) {
            guard identifier.hasPrefix(Self.prefix) else { return nil }
            self.init(rawValue: String(identifier.dropFirst(Self.prefix.count)))
        }
    }

    private let sampleRate = 44_100.0
    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var nextPlayer = 0
    private var running = false

    /// Rendered buffers keyed by style and quantized pitch, so repeated
    /// clicks cost nothing.
    private var cache: [String: AVAudioPCMBuffer] = [:]

    private init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for _ in 0..<4 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
    }

    /// Plays one click. `pitch` is a multiplier (0.5-2.0); `vary` adds a
    /// small random pitch offset per click.
    func play(_ style: Style, volume: Double, pitch: Double, vary: Bool) {
        guard startIfNeeded() else { return }
        var effective = max(0.4, min(pitch, 2.5))
        if vary { effective *= Double.random(in: 0.93...1.08) }
        guard let buffer = buffer(for: style, pitch: effective) else { return }

        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = Float(max(0, min(volume, 1)))
        player.scheduleBuffer(buffer, at: nil)
        if !player.isPlaying { player.play() }
    }

    private func startIfNeeded() -> Bool {
        guard !running else { return true }
        do {
            try engine.start()
            running = true
            return true
        } catch {
            return false
        }
    }

    // MARK: - Synthesis

    private func buffer(for style: Style, pitch: Double) -> AVAudioPCMBuffer? {
        // Quantize the pitch so variation reuses a small set of buffers.
        let quantized = (pitch * 40).rounded() / 40
        let key = "\(style.rawValue)@\(quantized)"
        if let cached = cache[key] { return cached }

        let samples = render(style, pitch: quantized)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = buffer
        return buffer
    }

    /// Builds one click: a pitched body (a sine with a frequency glide) plus
    /// filtered noise, each with its own exponential decay, then a soft clip.
    private func render(_ style: Style, pitch: Double) -> [Float] {
        struct Recipe {
            var duration: Double
            var startHz: Double
            var endHz: Double
            var toneTau: Double
            var toneMix: Double
            var noiseTau: Double
            var noiseMix: Double
            var noiseLowpassHz: Double
            var noiseHighpass: Bool
            var attack: Double
        }

        let recipe: Recipe
        switch style {
        case .thock:
            recipe = Recipe(duration: 0.09, startHz: 180, endHz: 92, toneTau: 0.024, toneMix: 0.9,
                            noiseTau: 0.010, noiseMix: 0.35, noiseLowpassHz: 500, noiseHighpass: false, attack: 0.0015)
        case .clack:
            recipe = Recipe(duration: 0.045, startHz: 1900, endHz: 1500, toneTau: 0.007, toneMix: 0.5,
                            noiseTau: 0.006, noiseMix: 0.9, noiseLowpassHz: 6500, noiseHighpass: true, attack: 0.0004)
        case .cream:
            recipe = Recipe(duration: 0.065, startHz: 330, endHz: 235, toneTau: 0.017, toneMix: 0.8,
                            noiseTau: 0.012, noiseMix: 0.30, noiseLowpassHz: 950, noiseHighpass: false, attack: 0.003)
        case .silky:
            recipe = Recipe(duration: 0.055, startHz: 260, endHz: 220, toneTau: 0.012, toneMix: 0.25,
                            noiseTau: 0.016, noiseMix: 0.8, noiseLowpassHz: 620, noiseHighpass: false, attack: 0.005)
        case .bubble:
            recipe = Recipe(duration: 0.05, startHz: 280, endHz: 640, toneTau: 0.013, toneMix: 1.0,
                            noiseTau: 0.004, noiseMix: 0.08, noiseLowpassHz: 900, noiseHighpass: false, attack: 0.001)
        }

        let count = Int(recipe.duration * sampleRate)
        var out = [Float](repeating: 0, count: count)

        var phase = 0.0
        var lowpassState = 0.0
        var previousRaw = 0.0
        var highpassState = 0.0
        let lowpassAlpha = 1 - exp(-2 * .pi * recipe.noiseLowpassHz * pitch / sampleRate)
        var generator = SystemRandomNumberGenerator()

        for i in 0..<count {
            let t = Double(i) / sampleRate
            let progress = t / recipe.duration

            // Tonal body: frequency glides start -> end over the click.
            let hz = (recipe.startHz + (recipe.endHz - recipe.startHz) * min(progress * 2.2, 1)) * pitch
            phase += 2 * .pi * hz / sampleRate
            let tone = sin(phase) * exp(-t / recipe.toneTau) * recipe.toneMix

            // Noise body: white noise through a one-pole lowpass (and an
            // optional highpass for the sharp clack character).
            let white = Double.random(in: -1...1, using: &generator)
            lowpassState += lowpassAlpha * (white - lowpassState)
            var noise = lowpassState
            if recipe.noiseHighpass {
                highpassState = 0.995 * (highpassState + white - previousRaw)
                previousRaw = white
                noise = highpassState
            }
            noise *= exp(-t / recipe.noiseTau) * recipe.noiseMix

            var sample = tone + noise
            if t < recipe.attack { sample *= t / recipe.attack }
            // Soft clip keeps stacked components from ever cracking.
            out[i] = Float(tanh(sample * 1.4) * 0.85)
        }
        return out
    }
}

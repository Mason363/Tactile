//
//  WaveformPlayer.swift
//  Tactile
//

import Foundation

/// Plays a waveform's pulses through an engine with precise timing.
/// Starting a new waveform cancels any pulses still pending from the last
/// one — during fast sweeps the newest element always wins.
@MainActor
final class WaveformPlayer {
    private var timers: [Timer] = []
    private var engine: FeedbackEngine?

    func play(_ waveform: HapticWaveform, on engine: FeedbackEngine) {
        cancel()
        self.engine = engine
        var fireAt: TimeInterval = 0
        for (index, step) in waveform.steps.enumerated() {
            let strength = step.strength
            if index == 0 {
                engine.tick(strength)
            } else {
                let timer = Timer(timeInterval: fireAt, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.engine?.tick(strength)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            }
            fireAt += max(step.gapMs, 10) / 1000
        }
    }

    func cancel() {
        for timer in timers { timer.invalidate() }
        timers.removeAll()
    }
}

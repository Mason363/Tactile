//
//  WaveformPlayer.swift
//  Tactile
//

import Foundation

/// Plays a waveform's pulses through an engine with precise timing.
/// Starting a new waveform cancels any pulses still pending from the last
/// one - during fast sweeps the newest element always wins.
@MainActor
final class WaveformPlayer {
    private var timers: [Timer] = []
    private var engine: FeedbackEngine?

    func play(_ waveform: HapticWaveform, on engine: FeedbackEngine) {
        cancel()
        self.engine = engine
        var fireAt: TimeInterval = 0
        for (index, step) in waveform.steps.enumerated() {
            if index == 0 {
                Self.fire(step, on: engine)
            } else {
                let timer = Timer(timeInterval: fireAt, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let engine = self?.engine else { return }
                        Self.fire(step, on: engine)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                timers.append(timer)
            }
            fireAt += max(step.advanceMs, 10) / 1000
        }
    }

    /// A held note where the trackpad can sound one, a tap everywhere else.
    /// The phone and the public engine have no way to play a pitch, so a
    /// note degrades to a tap of the same strength rather than silence.
    @MainActor
    private static func fire(_ step: WaveformStep, on engine: FeedbackEngine) {
        if let hz = step.hz, let actuator = engine as? ActuatorHapticEngine {
            actuator.playTone(hz: hz, level: step.level, milliseconds: step.toneMs ?? 120)
        } else {
            engine.tick(step.effectiveStrength)
        }
    }

    func cancel() {
        for timer in timers { timer.invalidate() }
        timers.removeAll()
    }
}

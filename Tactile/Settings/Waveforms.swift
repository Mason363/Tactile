//
//  Waveforms.swift
//  Tactile
//

import Foundation

/// One pulse in a waveform: a strength, then a pause before the next pulse.
struct WaveformStep: Codable, Identifiable {
    var id = UUID()
    var strength: FeedbackPattern
    /// Pause after this pulse before the next one, in milliseconds.
    var gapMs: Double
    /// Fine strength, 0-100. When set it wins over `strength`, playing at
    /// the nearest level the trackpad supports. Optional so waveforms saved
    /// before it existed still decode.
    var percent: Double?
    /// A held note instead of a tap: the pitch the trackpad's motor sounds,
    /// in hertz. The motor plays roughly 90 Hz and up. Optional, and nil
    /// means a tap, so waveforms saved before notes existed still decode.
    var hz: Double?
    /// How long the note is held, in milliseconds.
    var toneMs: Double?

    private enum CodingKeys: String, CodingKey { case strength, gapMs, percent, hz, toneMs }

    /// A held note rather than a tap.
    var isTone: Bool { hz != nil }

    /// How long this step occupies before the next one starts. A tap is
    /// instant, so its gap is the whole wait; a note has to finish first.
    var advanceMs: Double { max(gapMs, isTone ? (toneMs ?? 0) : 0) }

    /// 0...1 for the loudness of a note, from the fine percent when set.
    var level: Double { (percent ?? Double(effectiveStrength.toneLevel * 100)) / 100 }

    /// The level to actually play: percent mapped onto the supported
    /// strengths, or the coarse strength when no percent is set.
    var effectiveStrength: FeedbackPattern {
        guard let percent else { return strength }
        if percent <= 40 { return .alignment }
        if percent <= 75 { return .generic }
        return .levelChange
    }
}

/// A user-composed haptic with a name, made in the Studio pane and offered
/// in every waveform picker.
struct CustomHaptic: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var waveform: HapticWaveform
}

/// A haptic waveform: an ordered sequence of pulses. Everything Tactile
/// plays - taps, shakes, ramps, state pulses - is one of these.
struct HapticWaveform: Codable, Equatable {
    var steps: [WaveformStep]

    static func == (lhs: HapticWaveform, rhs: HapticWaveform) -> Bool {
        lhs.steps.count == rhs.steps.count && zip(lhs.steps, rhs.steps).allSatisfy {
            $0.strength == $1.strength && $0.gapMs == $1.gapMs && $0.percent == $1.percent
                && $0.hz == $1.hz && $0.toneMs == $1.toneMs
        }
    }

    static func single(_ strength: FeedbackPattern) -> HapticWaveform {
        HapticWaveform(steps: [WaveformStep(strength: strength, gapMs: 0)])
    }

    /// Total play time, for UI display.
    var durationMs: Double {
        steps.dropLast().reduce(0) { $0 + $1.advanceMs } + (steps.last?.toneMs ?? 0)
    }
}

/// Built-in waveforms. A category's waveform that matches a preset shows the
/// preset's name in pickers; anything else shows as Custom.
enum WaveformPreset: String, CaseIterable, Identifiable {
    case lightTap
    case tap
    case firmTap
    case doubleTap
    case tripleTap
    case rampUp
    case rampDown
    case shake
    case heartbeat
    /// Three deliberate knocks: the notification feel.
    case knock
    /// Two short buzzes, like a phone ringing: the call feel.
    case ring

    var id: String { rawValue }

    var nameLocalizationKey: String { "waveform.preset.\(rawValue).name" }

    func localizedName(using localizer: Localizer) -> String {
        localizer.string(nameLocalizationKey)
    }

    var waveform: HapticWaveform {
        func step(_ s: FeedbackPattern, _ gap: Double) -> WaveformStep {
            WaveformStep(strength: s, gapMs: gap)
        }
        /// A held note: the trackpad's motor sounding a pitch, which is what
        /// a buzz actually is. Before the motor was understood as a tone
        /// generator these were faked with strings of taps.
        func note(_ hz: Double, _ milliseconds: Double, _ gap: Double, _ percent: Double = 70) -> WaveformStep {
            WaveformStep(strength: .levelChange, gapMs: gap, percent: percent, hz: hz, toneMs: milliseconds)
        }
        switch self {
        case .lightTap: return HapticWaveform(steps: [step(.alignment, 0)])
        case .tap: return HapticWaveform(steps: [step(.generic, 0)])
        case .firmTap: return HapticWaveform(steps: [step(.levelChange, 0)])
        case .doubleTap: return HapticWaveform(steps: [step(.generic, 90), step(.generic, 0)])
        case .tripleTap: return HapticWaveform(steps: [step(.generic, 70), step(.generic, 70), step(.generic, 0)])
        case .rampUp: return HapticWaveform(steps: [step(.alignment, 60), step(.generic, 60), step(.levelChange, 0)])
        case .rampDown: return HapticWaveform(steps: [step(.levelChange, 60), step(.generic, 60), step(.alignment, 0)])
        // A rough low note: what four fast taps were reaching for.
        case .shake: return HapticWaveform(steps: [note(110, 180, 0, 80)])
        case .heartbeat: return HapticWaveform(steps: [step(.levelChange, 120), step(.alignment, 0)])
        case .knock: return HapticWaveform(steps: [step(.levelChange, 150), step(.levelChange, 150), step(.levelChange, 0)])
        case .ring:
            // Two buzzes with a pause between, like a phone ringing. Real
            // notes now, rather than taps fast enough to blur into one.
            return HapticWaveform(steps: [note(180, 140, 170, 75), note(180, 140, 0, 75)])
        }
    }

    static func matching(_ waveform: HapticWaveform) -> WaveformPreset? {
        allCases.first { $0.waveform == waveform }
    }
}

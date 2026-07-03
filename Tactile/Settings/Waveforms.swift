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

    private enum CodingKeys: String, CodingKey { case strength, gapMs }
}

/// A haptic waveform: an ordered sequence of pulses. Everything Tactile
/// plays - taps, shakes, ramps, state pulses - is one of these.
struct HapticWaveform: Codable, Equatable {
    var steps: [WaveformStep]

    static func == (lhs: HapticWaveform, rhs: HapticWaveform) -> Bool {
        lhs.steps.count == rhs.steps.count && zip(lhs.steps, rhs.steps).allSatisfy {
            $0.strength == $1.strength && $0.gapMs == $1.gapMs
        }
    }

    static func single(_ strength: FeedbackPattern) -> HapticWaveform {
        HapticWaveform(steps: [WaveformStep(strength: strength, gapMs: 0)])
    }

    /// Total play time, for UI display.
    var durationMs: Double {
        steps.dropLast().reduce(0) { $0 + $1.gapMs }
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .lightTap: return "Light Tap"
        case .tap: return "Tap"
        case .firmTap: return "Firm Tap"
        case .doubleTap: return "Double Tap"
        case .tripleTap: return "Triple Tap"
        case .rampUp: return "Ramp Up"
        case .rampDown: return "Ramp Down"
        case .shake: return "Shake"
        case .heartbeat: return "Heartbeat"
        }
    }

    var waveform: HapticWaveform {
        func step(_ s: FeedbackPattern, _ gap: Double) -> WaveformStep {
            WaveformStep(strength: s, gapMs: gap)
        }
        switch self {
        case .lightTap: return HapticWaveform(steps: [step(.alignment, 0)])
        case .tap: return HapticWaveform(steps: [step(.generic, 0)])
        case .firmTap: return HapticWaveform(steps: [step(.levelChange, 0)])
        case .doubleTap: return HapticWaveform(steps: [step(.generic, 90), step(.generic, 0)])
        case .tripleTap: return HapticWaveform(steps: [step(.generic, 70), step(.generic, 70), step(.generic, 0)])
        case .rampUp: return HapticWaveform(steps: [step(.alignment, 60), step(.generic, 60), step(.levelChange, 0)])
        case .rampDown: return HapticWaveform(steps: [step(.levelChange, 60), step(.generic, 60), step(.alignment, 0)])
        case .shake: return HapticWaveform(steps: [step(.levelChange, 45), step(.levelChange, 45), step(.levelChange, 45), step(.levelChange, 0)])
        case .heartbeat: return HapticWaveform(steps: [step(.levelChange, 120), step(.alignment, 0)])
        }
    }

    static func matching(_ waveform: HapticWaveform) -> WaveformPreset? {
        allCases.first { $0.waveform == waveform }
    }
}

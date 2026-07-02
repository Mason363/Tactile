//
//  AudioFeedbackEngine.swift
//  Tactile
//

import AppKit

/// Optional quiet click sound so users on external mice — who can't feel the
/// trackpad — still get hover feedback. Off by default.
@MainActor
final class AudioFeedbackEngine: FeedbackEngine {
    /// System sounds that work as short hover clicks.
    static let availableSounds = ["Pop", "Tink", "Bottle", "Glass", "Morse", "Purr"]

    var volume: Double = 0.5
    var soundName: String = "Pop"

    func tick(_ pattern: FeedbackPattern) {
        guard let sound = NSSound(named: soundName)?.copy() as? NSSound else { return }
        sound.volume = Float(volume)
        sound.play()
    }
}

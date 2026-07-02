//
//  AudioFeedbackEngine.swift
//  Tactile
//

import AppKit

/// Optional quiet click sound so users on external mice — who can't feel the
/// trackpad — still get hover feedback. Off by default.
@MainActor
final class AudioFeedbackEngine: FeedbackEngine {
    var volume: Double = 0.5

    func tick(_ pattern: FeedbackPattern) {
        guard let sound = NSSound(named: "Tink")?.copy() as? NSSound else { return }
        sound.volume = Float(volume)
        sound.play()
    }
}

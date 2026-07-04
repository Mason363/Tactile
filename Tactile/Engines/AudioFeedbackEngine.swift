//
//  AudioFeedbackEngine.swift
//  Tactile
//

import AppKit
import UniformTypeIdentifiers

/// Optional quiet click sound so users on external mice - who can't feel the
/// trackpad - still get hover feedback. Off by default.
///
/// Sounds are either system sounds (by name) or user-imported audio files,
/// stored in Application Support and referenced as "custom:<filename>".
@MainActor
final class AudioFeedbackEngine: FeedbackEngine {
    /// System sounds that work as short hover clicks.
    static let availableSounds = ["Pop", "Tink", "Bottle", "Glass", "Morse", "Purr"]

    /// Synthesized click styles, generated in code with adjustable pitch.
    static let synthSounds = SynthClickEngine.Style.allCases.map(\.identifier)

    private static let customPrefix = "custom:"

    var volume: Double = 0.5
    var soundName: String = "Pop"
    /// Pitch multiplier for synthesized styles (files and system sounds
    /// play as recorded).
    var pitch: Double = 1.0
    /// Small random pitch change per click, synthesized styles only.
    var varyTone: Bool = false

    /// Imported files are read from disk once and kept; each tick plays a
    /// copy so rapid hovers can overlap.
    private var cachedCustom: (name: String, sound: NSSound)?

    func tick(_ pattern: FeedbackPattern) {
        if let style = SynthClickEngine.Style(identifier: soundName) {
            SynthClickEngine.shared.play(style, volume: volume, pitch: pitch, vary: varyTone)
            return
        }
        guard let sound = loadSound()?.copy() as? NSSound else { return }
        sound.volume = Float(volume)
        sound.play()
    }

    private func loadSound() -> NSSound? {
        guard let filename = Self.customFilename(from: soundName) else {
            return NSSound(named: soundName)
        }
        if let cachedCustom, cachedCustom.name == filename {
            return cachedCustom.sound
        }
        let url = Self.soundsDirectory.appendingPathComponent(filename)
        guard let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        cachedCustom = (filename, sound)
        return sound
    }

    // MARK: - Imported sound library

    /// `~/Library/Application Support/Tactile/Sounds`, created on demand.
    static var soundsDirectory: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tactile/Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Imported sound files, as "custom:<filename>" identifiers.
    static func customSounds() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: soundsDirectory.path)) ?? []
        return files
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { customPrefix + $0 }
    }

    /// Copies an audio file into the library; returns its identifier. A file
    /// with the same name replaces the previous import.
    static func importSound(from url: URL) -> String? {
        let destination = soundsDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return nil
        }
        // Reject files NSSound can't play rather than importing a dud.
        guard NSSound(contentsOf: destination, byReference: true) != nil else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return customPrefix + url.lastPathComponent
    }

    static func removeSound(_ identifier: String) {
        guard let filename = customFilename(from: identifier) else { return }
        try? FileManager.default.removeItem(at: soundsDirectory.appendingPathComponent(filename))
    }

    static func customFilename(from identifier: String) -> String? {
        guard identifier.hasPrefix(customPrefix) else { return nil }
        return String(identifier.dropFirst(customPrefix.count))
    }

    /// Human name for any identifier: system name as-is, filename sans extension.
    static func displayName(for identifier: String) -> String {
        if let style = SynthClickEngine.Style(identifier: identifier) { return style.displayName }
        guard let filename = customFilename(from: identifier) else { return identifier }
        return (filename as NSString).deletingPathExtension
    }
}

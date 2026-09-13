//
//  SoundAlerts.swift
//  Tactile
//

import AppKit

/// One app whose sounds should be felt, with its own waveform. `repeats`
/// keeps tapping while the sound goes on, the way a phone keeps vibrating
/// while it rings.
struct SoundAlertRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var bundleID: String
    var waveform: HapticWaveform
    var repeats: Bool
}

/// Feels an app start making sound: a call ringing, a timer going off, a
/// video starting in a background tab. For anyone who might not hear it.
///
/// Driven entirely by snapshots of which apps are playing (from
/// AudioProcessMonitor), so it needs no audio access. An app counts as
/// starting when it wasn't playing in the previous snapshot; whatever was
/// already playing when watching began is not news.
@MainActor
final class SoundAlertCenter {
    struct Configuration: Equatable {
        var enabled = false
        var rules: [SoundAlertRule] = []
        var otherApps = false
        var otherAppsWaveform = WaveformPreset.doubleTap.waveform
        var skipFrontmost = true
    }

    var configuration = Configuration() {
        didSet {
            if !configuration.enabled { stopAllRepeats() }
        }
    }

    /// Plays an alert waveform.
    var fire: ((HapticWaveform) -> Void)?

    /// Apps that ring through system services rather than their own
    /// process: an incoming FaceTime or phone call plays from the call
    /// daemons, so those count as the app.
    private static let callServices: [String: [String]] = [
        "com.apple.FaceTime": ["com.apple.TelephonyUtilities", "com.apple.avconferenced"],
        "com.apple.mobilephone": ["com.apple.TelephonyUtilities", "com.apple.avconferenced"],
    ]

    /// Apps playing in the last snapshot: owner bundle ID -> one of its clients.
    private var playing: [String: AudioProcessMonitor.Client] = [:]
    private var hasBaseline = false
    private var lastAlert: [String: CFTimeInterval] = [:]
    /// Repeating alerts by owner, with the app they alert for.
    private var repeating: [String: (timer: Timer, app: String)] = [:]

    /// Feed every snapshot of the playing clients.
    func update(playing clients: Set<AudioProcessMonitor.Client>) {
        var now: [String: AudioProcessMonitor.Client] = [:]
        for client in clients {
            guard let owner = client.appBundleID ?? client.processBundleID else { continue }
            if now[owner] == nil { now[owner] = client }
        }
        let previous = playing
        playing = now
        for owner in previous.keys where now[owner] == nil { stopRepeating(owner) }
        guard hasBaseline else {
            hasBaseline = true
            return
        }
        for (owner, client) in now where previous[owner] == nil {
            started(owner, client)
        }
    }

    /// Switching to the app means its sound was noticed: stop repeating.
    func frontmostChanged(to bundleID: String?) {
        guard let bundleID else { return }
        for (owner, entry) in repeating where owner == bundleID || entry.app == bundleID {
            stopRepeating(owner)
        }
    }

    /// Forgets the baseline, e.g. when the monitor stops.
    func reset() {
        playing = [:]
        hasBaseline = false
        stopAllRepeats()
    }

    private func started(_ owner: String, _ client: AudioProcessMonitor.Client) {
        guard configuration.enabled, let match = match(owner, client) else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if configuration.skipFrontmost, frontmost == match.app || frontmost == owner { return }
        let now = CACurrentMediaTime()
        // Apps open and close their audio between sounds; the same app
        // starting again within a few seconds is the same moment.
        if let last = lastAlert[match.app], now - last < 3 { return }
        lastAlert[match.app] = now
        fire?(match.waveform)
        if match.repeats { startRepeating(owner, app: match.app, match.waveform) }
    }

    /// An app's own rule wins (matching its helpers and, for calls, the
    /// system call services); otherwise any Dock app, when that's on.
    private func match(_ owner: String, _ client: AudioProcessMonitor.Client) -> (app: String, waveform: HapticWaveform, repeats: Bool)? {
        let names = [owner, client.processBundleID].compactMap { $0 }
        for rule in configuration.rules {
            let aliases = [rule.bundleID] + (Self.callServices[rule.bundleID] ?? [])
            let matches = names.contains { name in
                aliases.contains { name == $0 || name.hasPrefix($0 + ".") }
            }
            if matches { return (rule.bundleID, rule.waveform, rule.repeats) }
        }
        if configuration.otherApps, client.isRegularApp {
            return (owner, configuration.otherAppsWaveform, false)
        }
        return nil
    }

    /// Every 2.5 s while the sound keeps playing, for up to 30 s, until you
    /// switch to the app.
    private func startRepeating(_ owner: String, app: String, _ waveform: HapticWaveform) {
        stopRepeating(owner)
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                guard self.configuration.enabled,
                      self.playing[owner] != nil,
                      CACurrentMediaTime() - began < 30,
                      frontmost != app, frontmost != owner
                else {
                    self.stopRepeating(owner)
                    return
                }
                self.fire?(waveform)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeating[owner] = (timer, app)
    }

    private func stopRepeating(_ owner: String) {
        repeating.removeValue(forKey: owner)?.timer.invalidate()
    }

    private func stopAllRepeats() {
        for entry in repeating.values { entry.timer.invalidate() }
        repeating = [:]
    }
}

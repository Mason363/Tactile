//
//  MusicSettingsView.swift
//  Tactile
//

import SwiftUI

/// Feel the music: the switch, a live readout of what it feels, how strong
/// the vibration and the hum under it are, and how it stays out of the way.
struct MusicSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        let localizer = localization.localizer
        Form {
            Section {
                Toggle(localizer.string("settings.music.enable"), isOn: $settings.musicHapticsEnabled)
                Text(verbatim: localizer.string("settings.music.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.musicHapticsEnabled {
                    MusicStatusRow(music: controller.music)
                }
            }

            Section(localizer.string("settings.music.feel.section")) {
                LabeledSlider(
                    title: localizer.string("settings.music.intensity"),
                    value: $settings.musicIntensity,
                    range: 0...1,
                    step: 0.05,
                    format: { localizer.format("format.percent.integer", arguments: [Int(($0 * 100).rounded())]) },
                    caption: vibrationAvailable ? nil : localizer.string("settings.music.intensity.standard-help")
                )
                LabeledSlider(
                    title: localizer.string("settings.music.texture"),
                    value: $settings.musicTexture,
                    range: 0...1,
                    step: 0.05,
                    format: { localizer.format("format.percent.integer", arguments: [Int(($0 * 100).rounded())]) },
                    caption: localizer.string("settings.music.texture.explanation")
                )
                .disabled(!vibrationAvailable)
                .opacity(vibrationAvailable ? 1 : 0.45)
            }
            .disabled(!settings.musicHapticsEnabled)
            .opacity(settings.musicHapticsEnabled ? 1 : 0.45)

            Section(localizer.string("settings.music.manners.section")) {
                Toggle(localizer.string("settings.music.pause-navigating"), isOn: $settings.musicPauseWhileNavigating)
                Text(verbatim: localizer.string("settings.music.pause-navigating.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(localizer.string("settings.music.pause-calls"), isOn: $settings.musicPauseDuringCalls)
                LabeledSlider(
                    title: localizer.string("settings.music.timing"),
                    value: $settings.musicSyncOffsetMs,
                    range: -100...200,
                    step: 10,
                    format: { timing($0, localizer) },
                    caption: localizer.string("settings.music.timing.explanation")
                )
            }
            .disabled(!settings.musicHapticsEnabled)
            .opacity(settings.musicHapticsEnabled ? 1 : 0.45)

            Section {
                Label(localizer.string("settings.music.privacy"), systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { controller.music.refreshPermission() }
    }

    /// A true vibration needs the trackpad actuator: enhanced haptics, or
    /// a specific trackpad chosen as the device.
    private var vibrationAvailable: Bool {
        ActuatorHapticEngine.hasHapticTrackpad
            && settings.hapticDevice != .iphone
            && (settings.useEnhancedHaptics || settings.hapticDevice.isTrackpadSpecific)
    }

    private func timing(_ milliseconds: Double, _ localizer: Localizer) -> String {
        let value = Int(milliseconds.rounded())
        if value == 0 { return localizer.string("settings.music.timing.auto") }
        return value > 0
            ? localizer.format("format.settings.music.timing.later", arguments: [value])
            : localizer.format("format.settings.music.timing.earlier", arguments: [-value])
    }
}

/// What music haptics feels right now, with a dot that swells with the
/// music, and the permission action when one is needed.
private struct MusicStatusRow: View {
    @ObservedObject var music: MusicHaptics
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        let localizer = localization.localizer
        HStack(spacing: 10) {
            MusicMeter(level: music.level, lit: music.status == .feeling)
            Text(verbatim: text(localizer))
                .foregroundStyle(isProblem ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            switch music.status {
            case .needsPermission:
                Button(localizer.string("settings.music.allow")) { music.requestPermission() }
            case .denied, .hearingNothing:
                Button(localizer.string("settings.music.open-settings")) { AudioCapturePermission.openSystemSettings() }
            default:
                EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var isProblem: Bool {
        switch music.status {
        case .denied, .hearingNothing, .unavailable: return true
        default: return false
        }
    }

    private func text(_ localizer: Localizer) -> String {
        switch music.status {
        case .off:
            return localizer.string("settings.music.status.off")
        case .needsPermission:
            return localizer.string("settings.music.status.needs-permission")
        case .denied:
            return localizer.string("settings.music.status.denied")
        case .waiting:
            return localizer.string("settings.music.status.waiting")
        case .listening:
            if let source = music.sourceName {
                return localizer.format("format.settings.music.status.listening-to", arguments: [source])
            }
            return localizer.string("settings.music.status.listening")
        case .feeling:
            if let source = music.sourceName {
                return localizer.format("format.settings.music.status.feeling-source", arguments: [source])
            }
            return localizer.string("settings.music.status.feeling")
        case .talk:
            return localizer.string("settings.music.status.talk")
        case .pausedForCursor:
            return localizer.string("settings.music.status.paused-cursor")
        case .pausedForCall:
            return localizer.string("settings.music.status.paused-call")
        case .hearingNothing:
            return localizer.string("settings.music.status.hearing-nothing")
        case .unavailable:
            return localizer.string("settings.music.status.unavailable")
        }
    }
}

/// Swells with the music while it's felt.
private struct MusicMeter: View {
    let level: Float
    let lit: Bool

    var body: some View {
        Circle()
            .fill(lit ? Color.accentColor : Color.secondary.opacity(0.35))
            .frame(width: 10, height: 10)
            .scaleEffect(lit ? 1 + 0.8 * CGFloat(level) : 1)
            .animation(.easeOut(duration: 0.1), value: level)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

//
//  WaveformUI.swift
//  Tactile
//

import SwiftUI

/// Plays waveform previews in settings through the engine the user has
/// actually selected, so "Try" matches reality.
@MainActor
enum HapticPreview {
    private static let player = WaveformPlayer()

    static func play(_ waveform: HapticWaveform, enhanced: Bool) {
        let engine: FeedbackEngine
        // Previews land where the pipeline would: the Coast phone when it
        // is the reachable target, a haptic mouse when the hand is on it,
        // else the chosen trackpad through the actuator (a specific choice
        // routes there even without enhanced haptics), else the system
        // engine.
        if PhoneHapticEngine.shared.isCurrentTarget {
            engine = PhoneHapticEngine.shared
        } else if MouseHapticEngine.shared.carriesTick {
            engine = MouseHapticEngine.shared
        } else if let actuator = ActuatorHapticEngine.shared,
                  enhanced || actuator.target.isTrackpadSpecific {
            engine = actuator
        } else {
            engine = SystemHapticEngine()
        }
        player.play(waveform, on: engine)
    }
}

extension Localizer {
    /// "3 pulses · 240 ms", or just "1 pulse" where there is no length.
    func waveformSummary(pulses: Int, milliseconds: Double) -> String {
        let count = plural("waveform.pulse-count", count: pulses)
        guard milliseconds >= 1 else { return count }
        return count + " · " + format("format.waveform.duration-ms", arguments: [Int(milliseconds)])
    }
}

/// One waveform, wherever a haptic is chosen: a button to feel it, and a
/// chip that shows its shape and name and opens the choices. The choices
/// are the presets and the saved haptics, each drawn and felt on a click,
/// and a way into the editor for anything else.
struct WaveformControl: View {
    @Binding var waveform: HapticWaveform
    var accessibilityName: String

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @Environment(\.isEnabled) private var isEnabled
    @State private var showChoices = false
    @State private var showEditor = false

    /// What the waveform is called: a preset's name, a saved haptic's, or
    /// Custom for one edited in place.
    private var name: String {
        if let preset = WaveformPreset.matching(waveform) {
            return preset.localizedName(using: localization.localizer)
        }
        if let saved = settings.customHaptics.first(where: { $0.waveform == waveform }) {
            return saved.name
        }
        return localization.localizer.string("waveform.custom")
    }

    var body: some View {
        let localizer = localization.localizer
        HStack(spacing: 6) {
            Button {
                HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(localizer.string("waveform.try"))
            .accessibilityLabel(Text(verbatim: localizer.format("a11y.waveform.try", arguments: [accessibilityName])))

            Button {
                showChoices = true
            } label: {
                HStack(spacing: 7) {
                    WaveformGlyph(waveform: waveform)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 14)
                    Text(verbatim: name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(width: 152, height: 24)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: localizer.format("a11y.waveform.for", arguments: [accessibilityName])))
            .accessibilityValue(Text(verbatim: name))
            .popover(isPresented: $showChoices, arrowEdge: .bottom) {
                WaveformChoices(waveform: $waveform) {
                    showChoices = false
                    showEditor = true
                }
                .environmentObject(settings)
                .environmentObject(localization)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .sheet(isPresented: $showEditor) {
            HapticEditor(title: accessibilityName, waveform: waveform) { waveform = $0 }
                .environmentObject(settings)
                .environmentObject(localization)
        }
    }
}

/// The choices behind a waveform chip: every preset and saved haptic as a
/// small card with its shape. A click picks it and plays it, so several
/// can be compared without closing anything.
private struct WaveformChoices: View {
    @Binding var waveform: HapticWaveform
    var edit: () -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    private let columns = Array(repeating: GridItem(.fixed(100), spacing: 8), count: 3)

    var body: some View {
        let localizer = localization.localizer
        VStack(alignment: .leading, spacing: 10) {
            heading(localizer.string("waveform.choices.presets"))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(WaveformPreset.allCases) { preset in
                    card(preset.localizedName(using: localizer), preset.waveform)
                }
            }
            if !settings.customHaptics.isEmpty {
                heading(localizer.string("waveform.choices.mine"))
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(settings.customHaptics) { haptic in
                        card(haptic.name, haptic.waveform)
                    }
                }
            }
            Divider()
            Button(action: edit) {
                Label(localizer.string("waveform.choices.edit"), systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(14)
        .frame(width: 344)
    }

    private func heading(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func card(_ name: String, _ choice: HapticWaveform) -> some View {
        let chosen = choice == waveform
        return Button {
            waveform = choice
            HapticPreview.play(choice, enhanced: settings.useEnhancedHaptics)
        } label: {
            VStack(spacing: 5) {
                WaveformGlyph(waveform: choice)
                    .foregroundStyle(chosen ? Color.white : Color.accentColor)
                    .frame(width: 64, height: 22)
                Text(verbatim: name)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(chosen ? Color.white : Color.primary)
            }
            .frame(width: 100, height: 54)
            .background(chosen ? Color.accentColor : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

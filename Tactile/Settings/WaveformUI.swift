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
        // is the reachable target, else the chosen trackpad through the
        // actuator (a specific choice routes there even without enhanced
        // haptics), else the system engine.
        if PhoneHapticEngine.shared.isCurrentTarget {
            engine = PhoneHapticEngine.shared
        } else if let actuator = ActuatorHapticEngine.shared,
                  enhanced || actuator.target.isTrackpadSpecific {
            engine = actuator
        } else {
            engine = SystemHapticEngine()
        }
        player.play(waveform, on: engine)
    }
}

/// Makes one step a held note instead of a tap, with its pitch and length.
/// The trackpad's motor sounds a pitch only through the actuator; the phone
/// and the public engine fall back to a tap of the same strength.
struct NoteControls: View {
    @Binding var step: WaveformStep

    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        let localizer = localization.localizer
        HStack(spacing: 8) {
            Toggle(localizer.string("waveform.note"), isOn: isNote)
                .toggleStyle(.checkbox)
                .accessibilityLabel(Text(verbatim: localizer.string("waveform.tap-or-note")))

            if step.isTone {
                Text(verbatim: localizer.string("waveform.pitch"))
                    .foregroundStyle(.secondary)
                Slider(value: pitch, in: 90...500, step: 5)
                    .accessibilityLabel(Text(verbatim: localizer.string("waveform.pitch")))
                Text(verbatim: localizer.format("format.settings.vibration.hz", arguments: [Int(step.hz ?? 200)]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)

                Text(verbatim: localizer.string("waveform.length"))
                    .foregroundStyle(.secondary)
                Slider(value: length, in: 40...400, step: 10)
                    .accessibilityLabel(Text(verbatim: localizer.string("waveform.length")))
                Text(verbatim: localizer.format("format.waveform.duration-ms", arguments: [Int(step.toneMs ?? 120)]))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            } else {
                Spacer()
            }
        }
        .font(.caption)
    }

    private var isNote: Binding<Bool> {
        Binding(
            get: { step.isTone },
            set: { on in
                step.hz = on ? (step.hz ?? 200) : nil
                step.toneMs = on ? (step.toneMs ?? 120) : nil
            }
        )
    }

    private var pitch: Binding<Double> {
        Binding(get: { step.hz ?? 200 }, set: { step.hz = $0 })
    }

    private var length: Binding<Double> {
        Binding(get: { step.toneMs ?? 120 }, set: { step.toneMs = $0 })
    }
}

private enum WaveformChoice: Hashable {
    case preset(WaveformPreset)
    case saved(UUID)
    case custom
}

/// Preset picker + editor + try button for one waveform binding. The whole
/// customization story hangs off this one control.
struct WaveformControl: View {
    @Binding var waveform: HapticWaveform
    var accessibilityName: String

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @State private var showEditor = false

    private var choice: Binding<WaveformChoice> {
        Binding(
            get: {
                if let preset = WaveformPreset.matching(waveform) { return .preset(preset) }
                if let saved = settings.customHaptics.first(where: { $0.waveform == waveform }) { return .saved(saved.id) }
                return .custom
            },
            set: { newValue in
                switch newValue {
                case .preset(let preset):
                    waveform = preset.waveform
                case .saved(let id):
                    if let haptic = settings.customHaptics.first(where: { $0.id == id }) {
                        waveform = haptic.waveform
                    }
                case .custom:
                    break
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Picker(localization.localizer.format(
                "a11y.waveform.for",
                arguments: [accessibilityName]
            ), selection: choice) {
                ForEach(WaveformPreset.allCases) { preset in
                    Text(verbatim: preset.localizedName(using: localization.localizer))
                        .tag(WaveformChoice.preset(preset))
                }
                if !settings.customHaptics.isEmpty {
                    Divider()
                    ForEach(settings.customHaptics) { haptic in
                        Text(verbatim: haptic.name).tag(WaveformChoice.saved(haptic.id))
                    }
                }
                Text(verbatim: localization.localizer.string("waveform.custom"))
                    .tag(WaveformChoice.custom)
            }
            .labelsHidden()
            .fixedSize()

            Button(localization.localizer.string("waveform.edit")) {
                showEditor = true
            }
            .accessibilityLabel(Text(verbatim: localization.localizer.format(
                "a11y.waveform.edit",
                arguments: [accessibilityName]
            )))

            Button(localization.localizer.string("waveform.try")) {
                HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
            }
            .accessibilityLabel(Text(verbatim: localization.localizer.format(
                "a11y.waveform.try",
                arguments: [accessibilityName]
            )))
        }
        .sheet(isPresented: $showEditor) {
            WaveformEditorView(waveform: $waveform, title: accessibilityName)
                .environmentObject(settings)
                .environmentObject(localization)
        }
    }
}

/// The composer: edit a waveform pulse by pulse.
struct WaveformEditorView: View {
    @Binding var waveform: HapticWaveform
    var title: String

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: localization.localizer.format(
                "format.waveform.title",
                arguments: [title]
            ))
                .font(.headline)
            Text(verbatim: localization.localizer.string("settings.studio.waveform-note"))
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($waveform.steps) { $step in
                    VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Picker(localization.localizer.string("waveform.strength"), selection: $step.strength) {
                            ForEach(FeedbackPattern.allCases) { pattern in
                                Text(verbatim: pattern.localizedName(using: localization.localizer))
                                    .tag(pattern)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        if step.id != waveform.steps.last?.id {
                            Slider(value: $step.gapMs, in: 20...400, step: 10) {
                                Text(verbatim: localization.localizer.string("waveform.pause-after-pulse"))
                            }
                            Text(verbatim: localization.localizer.format(
                                "format.waveform.duration-ms",
                                arguments: [Int(step.gapMs)]
                            ))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                        } else {
                            Spacer()
                        }

                        Button {
                            waveform.steps.removeAll { $0.id == step.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(waveform.steps.count <= 1)
                        .accessibilityLabel(Text(verbatim: localization.localizer.string(
                            "a11y.waveform.remove-pulse"
                        )))
                    }
                    NoteControls(step: $step)
                    }
                }
            }
            .frame(minHeight: 160)

            HStack {
                Button {
                    var last = waveform.steps[waveform.steps.count - 1]
                    last.gapMs = max(last.gapMs, 80)
                    waveform.steps[waveform.steps.count - 1] = last
                    waveform.steps.append(WaveformStep(strength: .generic, gapMs: 0))
                } label: {
                    Label(localization.localizer.string("waveform.add-pulse"), systemImage: "plus")
                }
                .disabled(waveform.steps.count >= 8)

                Spacer()

                Button(localization.localizer.string("waveform.play")) {
                    HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
                }

                Button(localization.localizer.string("dialog.done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }
}

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
        if enhanced, let actuator = ActuatorHapticEngine.shared {
            engine = actuator
        } else {
            engine = SystemHapticEngine()
        }
        player.play(waveform, on: engine)
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
            Picker("Waveform for \(accessibilityName)", selection: choice) {
                ForEach(WaveformPreset.allCases) { preset in
                    Text(preset.displayName).tag(WaveformChoice.preset(preset))
                }
                if !settings.customHaptics.isEmpty {
                    Divider()
                    ForEach(settings.customHaptics) { haptic in
                        Text(haptic.name).tag(WaveformChoice.saved(haptic.id))
                    }
                }
                Text("Custom").tag(WaveformChoice.custom)
            }
            .labelsHidden()
            .fixedSize()

            Button("Edit") {
                showEditor = true
            }
            .accessibilityLabel("Edit waveform for \(accessibilityName)")

            Button("Try") {
                HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
            }
            .accessibilityLabel("Try waveform for \(accessibilityName)")
        }
        .sheet(isPresented: $showEditor) {
            WaveformEditorView(waveform: $waveform, title: accessibilityName)
                .environmentObject(settings)
        }
    }
}

/// The composer: edit a waveform pulse by pulse.
struct WaveformEditorView: View {
    @Binding var waveform: HapticWaveform
    var title: String

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waveform: \(title)")
                .font(.headline)
            Text("A waveform is a sequence of pulses. Set each pulse's strength and the pause before the next one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach($waveform.steps) { $step in
                    HStack {
                        Picker("Strength", selection: $step.strength) {
                            ForEach(FeedbackPattern.allCases) { pattern in
                                Text(pattern.displayName).tag(pattern)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()

                        if step.id != waveform.steps.last?.id {
                            Slider(value: $step.gapMs, in: 20...400, step: 10) {
                                Text("Pause after pulse")
                            }
                            Text("\(Int(step.gapMs)) ms")
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
                        .accessibilityLabel("Remove pulse")
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
                    Label("Add Pulse", systemImage: "plus")
                }
                .disabled(waveform.steps.count >= 8)

                Spacer()

                Button("Play") {
                    HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
                }

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 380)
    }
}

//
//  PlaygroundView.swift
//  Tactile
//

import SwiftUI

/// A canvas of sample controls to feel your configuration on. Tactile
/// suppresses its own windows in the real pipeline (so settings don't buzz
/// while you tune them), so the playground plays each control's configured
/// waveform directly on hover — the same waveforms the pipeline would use.
struct PlaygroundView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var checkedOn = true
    @State private var checkedOff = false
    @State private var sliderValue = 0.4
    @State private var text = ""
    @State private var pickedTab = "One"

    var body: some View {
        Form {
            Section {
                Text("Hover these to feel your configuration. Tactile stays silent in its own windows, so the playground plays your configured waveforms directly.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Buttons") {
                HStack(spacing: 12) {
                    Button("Button") {}
                        .feelOnHover { play(.button) }
                    Button("Delete") {}
                        .feelOnHover { HapticPreview.play(settings.dangerWaveform, enhanced: settings.useEnhancedHaptics) }
                    Button("Link-style") {}
                        .feelOnHover { play(.link) }
                }
                Text("\"Delete\" plays the danger waveform.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("State") {
                Toggle("A checked checkbox", isOn: $checkedOn)
                    .toggleStyle(.checkbox)
                    .feelOnHover { play(.toggle, appendState: checkedOn) }
                Toggle("An unchecked checkbox", isOn: $checkedOff)
                    .toggleStyle(.checkbox)
                    .feelOnHover { play(.toggle, appendState: checkedOff) }
                Picker("Tabs", selection: $pickedTab) {
                    Text("One").tag("One")
                    Text("Two").tag("Two")
                    Text("Three").tag("Three")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .feelOnHover { play(.tab, appendState: true) }
                Text("With state awareness on, the checked box and the selected tab add a confirmation pulse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Other Elements") {
                Slider(value: $sliderValue) { Text("A slider") }
                    .feelOnHover { play(.slider) }
                TextField("A text field", text: $text)
                    .feelOnHover { play(.textField) }
                Text("These play their category waveform here regardless of whether the category is enabled, so you can preview them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func play(_ category: FeedbackCategory, appendState: Bool = false) {
        var waveform = settings.categoryWaveforms[category] ?? .single(category.defaultPattern)
        if appendState, settings.stateAware, var last = waveform.steps.last {
            last.gapMs = max(last.gapMs, 110)
            waveform.steps[waveform.steps.count - 1] = last
            waveform.steps.append(WaveformStep(strength: .alignment, gapMs: 0))
        }
        HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
    }
}

private extension View {
    /// Runs the action once when the pointer enters the view.
    func feelOnHover(_ action: @escaping () -> Void) -> some View {
        onHover { inside in
            if inside { action() }
        }
    }
}

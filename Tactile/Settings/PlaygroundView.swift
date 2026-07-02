//
//  PlaygroundView.swift
//  Tactile
//

import SwiftUI

/// A canvas of real controls to hover while tuning. These are ordinary
/// SwiftUI controls, so the actual pipeline — accessibility hit-testing and
/// all — is what makes them tick.
struct PlaygroundView: View {
    @State private var checkedOn = true
    @State private var checkedOff = false
    @State private var sliderValue = 0.4
    @State private var text = ""
    @State private var pickedTab = "One"

    var body: some View {
        Form {
            Section {
                Text("Move the cursor over these controls to feel your current configuration. They're real controls — the full pipeline handles them, exactly like any other app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Buttons") {
                HStack(spacing: 12) {
                    Button("Button") {}
                    Button("Delete") {}
                    Button("Disabled") {}.disabled(true)
                }
                Text("\"Delete\" plays the danger waveform; \"Disabled\" is felt only if Feel Disabled Controls is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("State") {
                Toggle("A checked checkbox", isOn: $checkedOn)
                    .toggleStyle(.checkbox)
                Toggle("An unchecked checkbox", isOn: $checkedOff)
                    .toggleStyle(.checkbox)
                Picker("Tabs", selection: $pickedTab) {
                    Text("One").tag("One")
                    Text("Two").tag("Two")
                    Text("Three").tag("Three")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("With state awareness on, the checked box and the selected tab add a confirmation pulse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Other Elements") {
                Slider(value: $sliderValue) { Text("A slider") }
                TextField("A text field", text: $text)
                Text("Sliders and text fields are off by default in Triggers — turn them on to feel these.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

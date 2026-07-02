//
//  ContextSettingsView.swift
//  Tactile
//

import SwiftUI

/// Contextual and spatial feel: danger elements, state awareness, hover-out,
/// screen edges, and window boundaries.
struct ContextSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Danger") {
                HStack {
                    Toggle("Warn on dangerous elements", isOn: $settings.dangerEnabled)
                    Spacer()
                    WaveformControl(waveform: $settings.dangerWaveform, accessibilityName: "dangerous elements")
                        .disabled(!settings.dangerEnabled)
                }
                Text("Window close buttons, and controls labeled with destructive words like Delete, Remove, or Reset, play this waveform instead of their normal one. Keyword detection is English-only for now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("State") {
                Toggle("Feel checked and selected state", isOn: $settings.stateAware)
                Text("Checked checkboxes, switches that are on, and the selected tab get an extra light pulse — hover tells you the state, not just the presence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Feel disabled controls", isOn: $settings.feelDisabled)
                Text("Disabled controls give a single light pulse instead of silence, so you know something is there but inactive.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hover Out") {
                HStack {
                    Toggle("Play when leaving an element", isOn: $settings.hapticOnExit)
                    Spacer()
                    WaveformControl(waveform: $settings.exitWaveform, accessibilityName: "leaving an element")
                        .disabled(!settings.hapticOnExit)
                }
                Text("Marks both edges of a control so you can feel its extent. Moving directly from one control to the next plays only the new element's waveform.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Spatial") {
                HStack {
                    Toggle("Screen edges", isOn: $settings.screenEdgesEnabled)
                    Spacer()
                    WaveformControl(waveform: $settings.edgeWaveform, accessibilityName: "screen edges")
                        .disabled(!settings.screenEdgesEnabled)
                }
                Text("Bump once when the cursor reaches an outer edge of the screen. Edges between two displays stay silent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Toggle("Window boundaries", isOn: $settings.windowBoundsEnabled)
                    Spacer()
                    WaveformControl(waveform: $settings.boundaryWaveform, accessibilityName: "window boundaries")
                        .disabled(!settings.windowBoundsEnabled)
                }
                Text("Play when the cursor crosses from one window into another — a physical map of your screen layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

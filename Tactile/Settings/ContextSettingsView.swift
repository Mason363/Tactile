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
            Section {
                HStack {
                    Toggle("Warn on dangerous elements", isOn: $settings.dangerEnabled)
                    Spacer()
                    WaveformControl(waveform: $settings.dangerWaveform, accessibilityName: "dangerous elements")
                        .disabled(!settings.dangerEnabled)
                }
            } header: {
                Text("Danger")
            } footer: {
                Text("Close buttons and controls labeled Delete, Remove, Reset, and the like play this warning instead of their normal feel. English labels only, for now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Feel checked and selected state", isOn: $settings.stateAware)
                Toggle("Feel disabled controls", isOn: $settings.feelDisabled)
            } header: {
                Text("State")
            } footer: {
                Text("Checked boxes and selected tabs add a confirmation pulse; disabled controls give a single light pulse instead of silence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("Play when leaving an element", isOn: $settings.hapticOnExit)
                    Spacer()
                    WaveformControl(waveform: $settings.exitWaveform, accessibilityName: "leaving an element")
                        .disabled(!settings.hapticOnExit)
                }
            } header: {
                Text("Hover Out")
            } footer: {
                Text("Marks both edges of a control so you can feel its extent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("Screen edges", isOn: $settings.screenEdgesEnabled)
                    Spacer()
                    WaveformControl(waveform: $settings.edgeWaveform, accessibilityName: "screen edges")
                        .disabled(!settings.screenEdgesEnabled)
                }
                HStack {
                    Toggle("Window boundaries", isOn: $settings.windowBoundsEnabled)
                    Spacer()
                    WaveformControl(waveform: $settings.boundaryWaveform, accessibilityName: "window boundaries")
                        .disabled(!settings.windowBoundsEnabled)
                }
            } header: {
                Text("Spatial")
            } footer: {
                Text("Bump at screen edges and when crossing between windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

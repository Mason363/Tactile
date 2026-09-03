//
//  ContextSettingsView.swift
//  Tactile
//

import SwiftUI

/// Contextual and spatial feel: danger elements, state awareness, hover-out,
/// screen edges, and window boundaries.
struct ContextSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        Form {
            Section {
                HStack {
                    Toggle("settings.context.danger.toggle", isOn: $settings.dangerEnabled)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.dangerWaveform,
                        accessibilityName: localization.localizer.string("a11y.context.dangerous-elements")
                    )
                        .disabled(!settings.dangerEnabled)
                }
            } header: {
                Text("settings.context.danger.title")
            } footer: {
                Text("settings.context.danger.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("settings.context.state.checked-selected", isOn: $settings.stateAware)
                Toggle("settings.context.state.disabled", isOn: $settings.feelDisabled)
            } header: {
                Text("settings.context.state.title")
            } footer: {
                Text("settings.context.state.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("settings.context.hover-out.toggle", isOn: $settings.hapticOnExit)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.exitWaveform,
                        accessibilityName: localization.localizer.string("a11y.context.leaving-element")
                    )
                        .disabled(!settings.hapticOnExit)
                }
            } header: {
                Text("settings.context.hover-out.title")
            } footer: {
                Text("settings.context.hover-out.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("settings.context.scrolling.toggle", isOn: $settings.scrollHapticsEnabled)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.scrollWaveform,
                        accessibilityName: localization.localizer.string("a11y.context.scrolling")
                    )
                        .disabled(!settings.scrollHapticsEnabled)
                }
                LabeledSlider(
                    title: localization.localizer.string("settings.context.scrolling.tick-every"),
                    value: $settings.scrollLines,
                    range: 1...20,
                    step: 1,
                    format: { value in
                        localization.localizer.format(
                            "format.lines",
                            Int(value)
                        )
                    },
                    caption: nil
                )
                .disabled(!settings.scrollHapticsEnabled)
            } header: {
                Text("settings.context.scrolling.title")
            } footer: {
                Text("settings.context.scrolling.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Toggle("settings.context.spatial.screen-edges", isOn: $settings.screenEdgesEnabled)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.edgeWaveform,
                        accessibilityName: localization.localizer.string("a11y.context.screen-edges")
                    )
                        .disabled(!settings.screenEdgesEnabled)
                }
                HStack {
                    Toggle("settings.context.spatial.window-boundaries", isOn: $settings.windowBoundsEnabled)
                    Spacer()
                    WaveformControl(
                        waveform: $settings.boundaryWaveform,
                        accessibilityName: localization.localizer.string("a11y.context.window-boundaries")
                    )
                        .disabled(!settings.windowBoundsEnabled)
                }
            } header: {
                Text("settings.context.spatial.title")
            } footer: {
                Text("settings.context.spatial.footer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

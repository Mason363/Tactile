//
//  HapticStudioView.swift
//  Tactile
//

import SwiftUI

/// Compose, name, and save haptics. Saved haptics appear in every waveform
/// picker across the app, and each pulse's strength is set as a percentage.
struct HapticStudioView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    @State private var editing: CustomHaptic?

    var body: some View {
        Form {
            Section {
                if settings.customHaptics.isEmpty {
                    Text(verbatim: localization.localizer.string("settings.studio.empty"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.customHaptics) { haptic in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: haptic.name)
                                Text(verbatim: localization.localizer.plural(
                                    "waveform.pulse-count",
                                    count: haptic.waveform.steps.count
                                ) + " · " + localization.localizer.format(
                                    "format.waveform.duration-ms",
                                    arguments: [Int(haptic.waveform.durationMs)]
                                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(localization.localizer.string("settings.studio.try")) {
                                HapticPreview.play(haptic.waveform, enhanced: settings.useEnhancedHaptics)
                            }
                            Button(localization.localizer.string("settings.studio.edit")) { editing = haptic }
                            Button {
                                var copy = haptic
                                copy.id = UUID()
                                copy.name = localization.localizer.format(
                                    "format.settings.studio.copied-name",
                                    arguments: [haptic.name]
                                )
                                settings.customHaptics.append(copy)
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(verbatim: localization.localizer.format(
                                "a11y.settings.studio.duplicate",
                                arguments: [haptic.name]
                            )))
                            Button {
                                settings.customHaptics.removeAll { $0.id == haptic.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text(verbatim: localization.localizer.format(
                                "a11y.settings.studio.delete",
                                arguments: [haptic.name]
                            )))
                        }
                    }
                }

                Button {
                    editing = CustomHaptic(
                        name: "",
                        waveform: HapticWaveform(steps: [WaveformStep(strength: .generic, gapMs: 0, percent: 60)])
                    )
                } label: {
                    Label(localization.localizer.string("settings.studio.new-haptic"), systemImage: "plus")
                }
            } header: {
                Text(verbatim: localization.localizer.string("settings.studio.saved-haptics"))
            } footer: {
                Text(verbatim: localization.localizer.string("settings.studio.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { haptic in
            HapticComposer(
                haptic: haptic,
                onSave: { saved in
                    if let index = settings.customHaptics.firstIndex(where: { $0.id == saved.id }) {
                        settings.customHaptics[index] = saved
                    } else {
                        settings.customHaptics.append(saved)
                    }
                }
            )
            .environmentObject(settings)
            .environmentObject(localization)
        }
    }
}

/// The composer sheet: pulse-by-pulse strength (in percent) and spacing.
private struct HapticComposer: View {
    @State var haptic: CustomHaptic
    var onSave: (CustomHaptic) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: haptic.name.isEmpty
                ? localization.localizer.string("settings.studio.new-haptic")
                : haptic.name)
                .font(.headline)

            TextField(localization.localizer.string("settings.studio.name"), text: $haptic.name)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach($haptic.waveform.steps) { $step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: localization.localizer.format(
                                "format.waveform.pulse-number",
                                arguments: [index(of: step.id) + 1]
                            ))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                haptic.waveform.steps.removeAll { $0.id == step.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .disabled(haptic.waveform.steps.count <= 1)
                            .accessibilityLabel(Text(verbatim: localization.localizer.string(
                                "a11y.waveform.remove-pulse"
                            )))
                        }
                        HStack {
                            Text(verbatim: localization.localizer.string("waveform.strength"))
                                .frame(width: 64, alignment: .leading)
                            Slider(value: percentBinding($step), in: 0...100, step: 1)
                            Text(verbatim: localization.localizer.format(
                                "format.waveform.percent",
                                arguments: [Int(step.percent ?? 60)]
                            ))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        if step.id != haptic.waveform.steps.last?.id {
                            HStack {
                                Text(verbatim: localization.localizer.string("waveform.pause"))
                                    .frame(width: 64, alignment: .leading)
                                Slider(value: $step.gapMs, in: 10...500, step: 5)
                                Text(verbatim: localization.localizer.format(
                                    "format.waveform.duration-ms",
                                    arguments: [Int(step.gapMs)]
                                ))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 220)

            Text(verbatim: localization.localizer.string("settings.studio.strength-note"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    var last = haptic.waveform.steps[haptic.waveform.steps.count - 1]
                    last.gapMs = max(last.gapMs, 80)
                    haptic.waveform.steps[haptic.waveform.steps.count - 1] = last
                    haptic.waveform.steps.append(WaveformStep(strength: .generic, gapMs: 0, percent: 60))
                } label: {
                    Label(localization.localizer.string("waveform.add-pulse"), systemImage: "plus")
                }
                .disabled(haptic.waveform.steps.count >= 16)

                Spacer()

                Button(localization.localizer.string("waveform.play")) {
                    HapticPreview.play(haptic.waveform, enhanced: settings.useEnhancedHaptics)
                }

                Button(localization.localizer.string("dialog.cancel")) { dismiss() }

                Button(localization.localizer.string("dialog.save")) {
                    if haptic.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        haptic.name = localization.localizer.string("settings.studio.default-name")
                    }
                    onSave(haptic)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
    }

    private func index(of id: UUID) -> Int {
        haptic.waveform.steps.firstIndex { $0.id == id } ?? 0
    }

    private func percentBinding(_ step: Binding<WaveformStep>) -> Binding<Double> {
        Binding(
            get: { step.wrappedValue.percent ?? 60 },
            set: { step.wrappedValue.percent = $0 }
        )
    }
}

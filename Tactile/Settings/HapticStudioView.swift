//
//  HapticStudioView.swift
//  Tactile
//

import SwiftUI

/// Compose, name, and save haptics. Saved haptics appear in every waveform
/// picker across the app, and each pulse's strength is set as a percentage.
struct HapticStudioView: View {
    @EnvironmentObject private var settings: SettingsStore

    @State private var editing: CustomHaptic?

    var body: some View {
        Form {
            Section {
                if settings.customHaptics.isEmpty {
                    Text("Nothing here yet. Compose your first haptic.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settings.customHaptics) { haptic in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(haptic.name)
                                Text("\(haptic.waveform.steps.count) pulse\(haptic.waveform.steps.count == 1 ? "" : "s") · \(Int(haptic.waveform.durationMs)) ms")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Try") {
                                HapticPreview.play(haptic.waveform, enhanced: settings.useEnhancedHaptics)
                            }
                            Button("Edit") { editing = haptic }
                            Button {
                                var copy = haptic
                                copy.id = UUID()
                                copy.name = haptic.name + " Copy"
                                settings.customHaptics.append(copy)
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Duplicate \(haptic.name)")
                            Button {
                                settings.customHaptics.removeAll { $0.id == haptic.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(haptic.name)")
                        }
                    }
                }

                Button {
                    editing = CustomHaptic(
                        name: "",
                        waveform: HapticWaveform(steps: [WaveformStep(strength: .generic, gapMs: 0, percent: 60)])
                    )
                } label: {
                    Label("New Haptic", systemImage: "plus")
                }
            } header: {
                Text("Saved haptics")
            } footer: {
                Text("Anything saved here shows up in every waveform menu: elements, keyboard, danger, scrolling, all of them.")
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
        }
    }
}

/// The composer sheet: pulse-by-pulse strength (in percent) and spacing.
private struct HapticComposer: View {
    @State var haptic: CustomHaptic
    var onSave: (CustomHaptic) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(haptic.name.isEmpty ? "New Haptic" : haptic.name)
                .font(.headline)

            TextField("Name", text: $haptic.name)
                .textFieldStyle(.roundedBorder)

            List {
                ForEach($haptic.waveform.steps) { $step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Pulse \(index(of: step.id) + 1)")
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
                            .accessibilityLabel("Remove pulse")
                        }
                        HStack {
                            Text("Strength")
                                .frame(width: 64, alignment: .leading)
                            Slider(value: percentBinding($step), in: 0...100, step: 1)
                            Text("\(Int(step.percent ?? 60))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        if step.id != haptic.waveform.steps.last?.id {
                            HStack {
                                Text("Pause")
                                    .frame(width: 64, alignment: .leading)
                                Slider(value: $step.gapMs, in: 10...500, step: 5)
                                Text("\(Int(step.gapMs)) ms")
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

            Text("Strength plays at the nearest level your trackpad supports.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    var last = haptic.waveform.steps[haptic.waveform.steps.count - 1]
                    last.gapMs = max(last.gapMs, 80)
                    haptic.waveform.steps[haptic.waveform.steps.count - 1] = last
                    haptic.waveform.steps.append(WaveformStep(strength: .generic, gapMs: 0, percent: 60))
                } label: {
                    Label("Add Pulse", systemImage: "plus")
                }
                .disabled(haptic.waveform.steps.count >= 16)

                Spacer()

                Button("Play") {
                    HapticPreview.play(haptic.waveform, enhanced: settings.useEnhancedHaptics)
                }

                Button("Cancel") { dismiss() }

                Button("Save") {
                    if haptic.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        haptic.name = "My Haptic"
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

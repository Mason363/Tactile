//
//  HapticStudioView.swift
//  Tactile
//

import SwiftUI

/// The haptics you have made, and the presets to start more from, as a
/// gallery: each one drawn, felt on a click, and opened in the editor.
/// Saved haptics appear in every waveform chooser across the app.
///
/// Built on a plain scroll view, never a Form: SwiftUI folds buttons inside
/// a Form into an inert group, and these cards are buttons worth feeling.
struct HapticStudioView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    @State private var editing: CustomHaptic?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        let localizer = localization.localizer
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(verbatim: localizer.string("settings.studio.saved-haptics"))
                        .font(.headline)
                    Spacer()
                    Button {
                        editing = CustomHaptic(name: "", waveform: WaveformPreset.tap.waveform)
                    } label: {
                        Label(localizer.string("settings.studio.new-haptic"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                if settings.customHaptics.isEmpty {
                    Text(verbatim: localizer.string("settings.studio.empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(settings.customHaptics) { haptic in
                            HapticCard(name: haptic.name, waveform: haptic.waveform) {
                                iconButton("pencil", "a11y.settings.studio.edit", haptic.name) { editing = haptic }
                                Menu {
                                    Button(localizer.string("settings.studio.duplicate")) { duplicate(haptic) }
                                    Button(localizer.string("settings.studio.delete"), role: .destructive) {
                                        settings.customHaptics.removeAll { $0.id == haptic.id }
                                    }
                                } label: {
                                    // The label goes on the image: one set
                                    // on the menu itself is not carried.
                                    Image(systemName: "ellipsis")
                                        .accessibilityLabel(Text(verbatim: localizer.format(
                                            "a11y.settings.studio.more", arguments: [haptic.name]
                                        )))
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                        }
                    }
                }

                Text(verbatim: localizer.string("settings.studio.presets"))
                    .font(.headline)
                    .padding(.top, 10)

                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(WaveformPreset.allCases) { preset in
                        let name = preset.localizedName(using: localizer)
                        HapticCard(name: name, waveform: preset.waveform) {
                            iconButton("plus.square.on.square", "a11y.settings.studio.customize", name) {
                                editing = CustomHaptic(
                                    name: localizer.format("format.settings.studio.copied-name", arguments: [name]),
                                    waveform: preset.waveform
                                )
                            }
                        }
                    }
                }

                Text(verbatim: localizer.string("settings.studio.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .sheet(item: $editing) { haptic in
            StudioEditor(haptic: haptic) { saved in
                if let index = settings.customHaptics.firstIndex(where: { $0.id == saved.id }) {
                    settings.customHaptics[index] = saved
                } else {
                    settings.customHaptics.append(saved)
                }
            }
            .environmentObject(settings)
            .environmentObject(localization)
        }
    }

    private func duplicate(_ haptic: CustomHaptic) {
        var copy = haptic
        copy.id = UUID()
        copy.name = localization.localizer.format("format.settings.studio.copied-name", arguments: [haptic.name])
        settings.customHaptics.append(copy)
    }

    private func iconButton(_ symbol: String, _ labelKey: String, _ name: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(verbatim: localization.localizer.format(labelKey, arguments: [name])))
        .help(localization.localizer.format(labelKey, arguments: [name]))
    }
}

/// One haptic in the gallery: its shape, which plays it on a click, then
/// its name, its size, and whatever actions the caller gives it.
private struct HapticCard<Actions: View>: View {
    let name: String
    let waveform: HapticWaveform
    @ViewBuilder var actions: Actions

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        let localizer = localization.localizer
        VStack(alignment: .leading, spacing: 8) {
            Button {
                HapticPreview.play(waveform, enhanced: settings.useEnhancedHaptics)
            } label: {
                WaveformGlyph(waveform: waveform)
                    .foregroundStyle(Color.accentColor)
                    .frame(height: 36)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: localizer.format("a11y.settings.studio.try", arguments: [name])))

            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: name)
                        .lineLimit(1)
                    Text(verbatim: localizer.waveformSummary(pulses: waveform.steps.count, milliseconds: waveform.durationMs))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                actions
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The editor for a named haptic. Holds the name while it is being typed,
/// and gives an unnamed haptic the default name on save.
private struct StudioEditor: View {
    let haptic: CustomHaptic
    var onSave: (CustomHaptic) -> Void

    @EnvironmentObject private var localization: LocalizationController
    @State private var name: String

    init(haptic: CustomHaptic, onSave: @escaping (CustomHaptic) -> Void) {
        self.haptic = haptic
        self.onSave = onSave
        _name = State(initialValue: haptic.name)
    }

    var body: some View {
        HapticEditor(title: name, name: $name, waveform: haptic.waveform) { waveform in
            var saved = haptic
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            saved.name = trimmed.isEmpty ? localization.localizer.string("settings.studio.default-name") : trimmed
            saved.waveform = waveform
            onSave(saved)
        }
    }
}

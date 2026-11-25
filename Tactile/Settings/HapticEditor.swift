//
//  HapticEditor.swift
//  Tactile
//

import Combine
import SwiftUI

/// The one place a haptic is made or changed, whether it is a control's
/// own waveform or a named haptic in the Studio. Three ways in, all ending
/// on the same timeline: start from a preset, tap a rhythm out by hand, or
/// click pulses onto the timeline and drag them into shape. Every change
/// can be felt at once.
struct HapticEditor: View {
    /// What is being edited, as the heading.
    let title: String
    /// The haptic's own name, where it has one (the Studio). Nil when a
    /// control's waveform is edited in place.
    var name: Binding<String>?
    var onSave: (HapticWaveform) -> Void

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var localization: LocalizationController
    @Environment(\.dismiss) private var dismiss

    @State private var pulses: [TimedPulse]
    @State private var selection: UUID?
    @StateObject private var recorder = TapRecorder()

    init(title: String, name: Binding<String>? = nil, waveform: HapticWaveform,
         onSave: @escaping (HapticWaveform) -> Void) {
        self.title = title
        self.name = name
        self.onSave = onSave
        _pulses = State(initialValue: waveform.pulses)
    }

    var body: some View {
        let localizer = localization.localizer
        VStack(alignment: .leading, spacing: 14) {
            if let name {
                TextField(localizer.string("settings.studio.name"), text: name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
            } else {
                Text(verbatim: title)
                    .font(.title3.bold())
            }

            templates

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.05))
                if recorder.isArmed {
                    TapStage(recorder: recorder)
                } else {
                    WaveformTimeline(pulses: $pulses, selection: $selection, onSettle: feel)
                }
            }
            .frame(height: 210)

            tools

            // A fixed height, so the sheet holds still as the selection
            // and the tap pad come and go.
            ZStack(alignment: .topLeading) {
                Color.clear
                inspector
            }
            .frame(height: 88)

            Divider()

            HStack {
                Button(action: play) {
                    Label(localizer.string("waveform.play"), systemImage: "play.fill")
                }
                .disabled(recorder.isArmed)

                Spacer()

                Button(localizer.string("dialog.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(localizer.string(name == nil ? "dialog.done" : "dialog.save")) {
                    onSave(HapticWaveform(pulses: pulses))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recorder.isArmed)
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear {
            recorder.onFinish = { recorded in
                withAnimation(.snappy(duration: 0.25)) { pulses = recorded }
                selection = nil
                play()
            }
        }
        .onDisappear { recorder.cancel() }
    }

    // MARK: - Sections

    /// Presets and saved haptics to start from. Picking one replaces what
    /// is on the timeline and plays it.
    private var templates: some View {
        let localizer = localization.localizer
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: localizer.string("waveform.editor.start-from"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WaveformPreset.allCases) { preset in
                        template(preset.localizedName(using: localizer), preset.waveform)
                    }
                    ForEach(settings.customHaptics) { haptic in
                        template(haptic.name, haptic.waveform)
                    }
                }
            }
        }
        .disabled(recorder.isArmed)
    }

    private func template(_ name: String, _ waveform: HapticWaveform) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) { pulses = waveform.pulses }
            selection = nil
            play()
        } label: {
            VStack(spacing: 4) {
                WaveformGlyph(waveform: waveform)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 18)
                Text(verbatim: name)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: name))
    }

    private var tools: some View {
        let localizer = localization.localizer
        return HStack(spacing: 8) {
            Button {
                if recorder.isArmed { recorder.finish() } else { recorder.arm() }
            } label: {
                Label(
                    localizer.string(recorder.isArmed ? "waveform.editor.tap-done" : "waveform.editor.tap-it-out"),
                    systemImage: recorder.isArmed ? "stop.fill" : "hand.tap.fill"
                )
            }

            Button(action: addPulse) {
                Label(localizer.string("waveform.add-pulse"), systemImage: "plus")
            }
            .disabled(recorder.isArmed || pulses.count >= WaveformLimits.pulses)

            Button {
                var first = TimedPulse(time: 0)
                first.setLevel(0.6)
                withAnimation(.snappy(duration: 0.25)) { pulses = [first] }
                selection = first.id
            } label: {
                Label(localizer.string("waveform.editor.clear"), systemImage: "trash")
            }
            .disabled(recorder.isArmed || pulses.count <= 1)

            Spacer()

            Text(verbatim: localizer.waveformSummary(pulses: pulses.count, milliseconds: pulses.duration))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The selected pulse, as ordinary controls: everything the timeline
    /// does by dragging, without the dragging.
    @ViewBuilder
    private var inspector: some View {
        let localizer = localization.localizer
        if recorder.isArmed {
            EmptyView()
        } else if let index = pulses.firstIndex(where: { $0.id == selection }) {
            let pulse = pulses[index]
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(verbatim: localizer.format("format.waveform.pulse-number", arguments: [index + 1]))
                        .font(.callout.weight(.semibold))
                        .frame(minWidth: 58, alignment: .leading)

                    Picker(localizer.string("waveform.tap-or-note"), selection: isNote(pulse.id)) {
                        Text(verbatim: localizer.string("waveform.tap")).tag(false)
                        Text(verbatim: localizer.string("waveform.note")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 130)

                    slider(localizer.string("waveform.strength"),
                           value: field(pulse.id, get: { $0.level * 100 }, set: { $0.setLevel($1 / 100) }, fallback: 60),
                           in: 5...100, step: 1,
                           shows: localizer.format("format.waveform.percent", arguments: [Int((pulse.level * 100).rounded())]))

                    Button {
                        pulses.removeAll { $0.id == pulse.id }
                        pulses = pulses.settled()
                        selection = nil
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(pulses.count <= 1)
                    .accessibilityLabel(Text(verbatim: localizer.string("a11y.waveform.remove-pulse")))
                }

                if pulse.isTone {
                    HStack(spacing: 12) {
                        slider(localizer.string("waveform.pitch"),
                               value: field(pulse.id, get: { $0.hz ?? 180 }, set: { $0.hz = $1 }, fallback: 180),
                               in: WaveformLimits.pitch, step: 5,
                               shows: localizer.format("format.settings.vibration.hz", arguments: [Int(pulse.hz ?? 180)]))
                        slider(localizer.string("waveform.length"),
                               value: field(pulse.id, get: { $0.toneMs ?? 120 }, set: { $0.toneMs = $1 }, fallback: 120, settles: true),
                               in: WaveformLimits.noteLength, step: 10,
                               shows: localizer.format("format.waveform.duration-ms", arguments: [Int(pulse.toneMs ?? 120)]))
                    }
                    Text(verbatim: localizer.string("waveform.note.hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text(verbatim: localizer.string("waveform.editor.hint"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, shows text: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: title)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: step) {
                Text(verbatim: title)
            }
            .labelsHidden()
            .accessibilityValue(text)
            Text(verbatim: text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
        }
        .font(.callout)
    }

    // MARK: - Editing

    /// A binding into one pulse by identity, so a pulse that has just been
    /// removed is never reached for by position.
    private func field(_ id: UUID, get: @escaping (TimedPulse) -> Double,
                       set: @escaping (inout TimedPulse, Double) -> Void,
                       fallback: Double, settles: Bool = false) -> Binding<Double> {
        Binding(
            get: { pulses.first(where: { $0.id == id }).map(get) ?? fallback },
            set: { value in
                guard let index = pulses.firstIndex(where: { $0.id == id }) else { return }
                set(&pulses[index], value)
                if settles { pulses = pulses.settled() }
            }
        )
    }

    private func isNote(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { pulses.first(where: { $0.id == id })?.isTone ?? false },
            set: { on in
                guard let index = pulses.firstIndex(where: { $0.id == id }) else { return }
                pulses[index].hz = on ? (pulses[index].hz ?? 180) : nil
                pulses[index].toneMs = on ? (pulses[index].toneMs ?? 120) : nil
                // A tap that becomes a note pushes what follows it back.
                withAnimation(.snappy(duration: 0.2)) { pulses = pulses.settled() }
                if let pulse = pulses.first(where: { $0.id == id }) { feel(pulse) }
            }
        )
    }

    private func addPulse() {
        var pulse = TimedPulse(time: min(pulses.duration + 100, WaveformLimits.time))
        pulse.setLevel(pulses.last?.level ?? 0.6)
        withAnimation(.snappy(duration: 0.2)) { pulses = (pulses + [pulse]).settled() }
        selection = pulse.id
        feel(pulse)
    }

    private func play() {
        HapticPreview.play(HapticWaveform(pulses: pulses), enhanced: settings.useEnhancedHaptics)
    }

    /// Plays one pulse on its own, as it was just placed or changed.
    private func feel(_ pulse: TimedPulse) {
        var alone = pulse
        alone.time = 0
        HapticPreview.play(HapticWaveform(pulses: [alone]), enhanced: settings.useEnhancedHaptics)
    }
}

/// What the canvas becomes while a rhythm is being tapped: the pad, what
/// to do on it, and a dot for each tap so far.
private struct TapStage: View {
    @ObservedObject var recorder: TapRecorder
    @EnvironmentObject private var localization: LocalizationController

    var body: some View {
        let localizer = localization.localizer
        ZStack {
            TapPad(recorder: recorder, label: localizer.string("a11y.waveform.tap-pad"))
            VStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.accentColor)
                Text(verbatim: localizer.string("waveform.editor.tap-prompt"))
                    .font(.headline)
                Text(verbatim: localizer.string("waveform.editor.tap-hint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                HStack(spacing: 5) {
                    ForEach(recorder.taps.indices, id: \.self) { _ in
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(height: 10)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

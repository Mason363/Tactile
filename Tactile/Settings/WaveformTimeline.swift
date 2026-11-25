//
//  WaveformTimeline.swift
//  Tactile
//
//  A waveform as a picture: pulses along time, as tall as they are strong.
//  The same drawing is the small glyph beside every waveform control and
//  the canvas the editor is built on, where a click adds a pulse and a drag
//  shapes it.
//

import AppKit
import QuartzCore
import Combine
import SwiftUI

// MARK: - Pulses in time

/// One pulse placed in time: the editor's view of a `WaveformStep`, which
/// itself only knows the pause that follows it.
struct TimedPulse: Identifiable, Equatable {
    var id = UUID()
    /// Milliseconds from the start of the waveform.
    var time: Double
    var strength: FeedbackPattern = .generic
    /// Fine strength, 0-100. Nil on a pulse nobody has reshaped, so a
    /// preset that is opened and left alone still matches the preset.
    var percent: Double?
    var hz: Double?
    var toneMs: Double?

    var isTone: Bool { hz != nil }

    /// Height on the timeline, 0...1; also how loud a note is.
    var level: Double { (percent ?? strength.toneLevel * 100) / 100 }

    /// Milliseconds the pulse occupies: a note's length, nothing for a tap.
    var length: Double { isTone ? (toneMs ?? 120) : 0 }

    var end: Double { time + length }

    /// Sets the fine strength and the coarse one it plays as on devices
    /// that only have three.
    mutating func setLevel(_ level: Double) {
        let value = (min(max(level, 0.05), 1) * 100).rounded()
        percent = value
        strength = value <= 40 ? .alignment : value <= 75 ? .generic : .levelChange
    }
}

enum WaveformLimits {
    static let pulses = 16
    /// The latest a pulse may start, in milliseconds.
    static let time = 3000.0
    static let pitch = 90.0...500.0
    static let noteLength = 40.0...400.0
}

extension Array where Element == TimedPulse {
    /// In order, starting at zero, and no pulse beginning before the one
    /// ahead of it is over.
    func settled() -> [TimedPulse] {
        var result = sorted { $0.time < $1.time }
        guard let first = result.first?.time else { return result }
        for index in result.indices { result[index].time -= first }
        for index in result.indices.dropFirst() {
            let earliest = result[index - 1].time + Swift.max(result[index - 1].length, 10)
            result[index].time = Swift.max(result[index].time, earliest)
        }
        return result
    }

    /// Milliseconds from the first pulse to the end of the last.
    var duration: Double { map(\.end).max() ?? 0 }
}

extension HapticWaveform {
    /// The steps laid out in time.
    var pulses: [TimedPulse] {
        var time = 0.0
        return steps.map { step in
            defer { time += max(step.advanceMs, 10) }
            return TimedPulse(id: step.id, time: time, strength: step.strength,
                              percent: step.percent, hz: step.hz, toneMs: step.toneMs)
        }
    }

    /// Back to steps: each pulse's pause is the distance to the next one.
    init(pulses: [TimedPulse]) {
        let ordered = pulses.settled()
        self.init(steps: ordered.enumerated().map { index, pulse in
            let gap = index + 1 < ordered.count ? ordered[index + 1].time - pulse.time : 0
            var step = WaveformStep(strength: pulse.strength, gapMs: gap.rounded(),
                                    percent: pulse.percent, hz: pulse.hz, toneMs: pulse.toneMs)
            step.id = pulse.id
            return step
        })
    }
}

// MARK: - Glyph

/// A waveform drawn small: a stem per tap, a block per note. Takes the
/// foreground style it is given.
struct WaveformGlyph: View {
    let waveform: HapticWaveform

    var body: some View {
        Canvas { context, size in
            let pulses = waveform.pulses
            let total = pulses.duration
            let usable = size.width - 6
            // Up to 400 ms keeps one scale, so a tap and a double tap read
            // as different lengths; longer ones are fitted to the width.
            let scale = usable / max(total, 400)
            let origin = 3 + (usable - total * scale) / 2
            // Even the lightest pulse keeps a visible stem.
            let stroke = min(max(size.height / 8, 2), 3.5)
            for pulse in pulses {
                let x = origin + pulse.time * scale
                let height = (0.3 + 0.7 * pulse.level) * (size.height - 2)
                if pulse.isTone {
                    let rect = CGRect(x: x, y: size.height - height,
                                      width: max(4, pulse.length * scale), height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .foreground)
                } else {
                    var stem = Path()
                    stem.move(to: CGPoint(x: x, y: size.height - 1))
                    stem.addLine(to: CGPoint(x: x, y: size.height - height))
                    context.stroke(stem, with: .foreground, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Timeline

/// The editor's canvas. Click empty space to add a pulse where the pointer
/// is; drag a pulse sideways to move it in time and up or down to change
/// its strength; drag the end of a note to change how long it holds.
/// Everything here can also be done from the inspector below it and from
/// the keyboard, so nothing depends on dragging.
struct WaveformTimeline: View {
    @Binding var pulses: [TimedPulse]
    @Binding var selection: UUID?
    /// A pulse was added or let go of: the moment to feel it.
    var onSettle: (TimedPulse) -> Void

    @EnvironmentObject private var localization: LocalizationController
    /// The span shown, held still during a drag so the scale does not
    /// shift under the pointer.
    @State private var heldSpan: Double?
    /// Where inside the pulse a drag took hold.
    @State private var grip: CGSize?
    @FocusState private var focused: Bool

    private static let space = "waveform-timeline"
    private static let margins = EdgeInsets(top: 14, leading: 24, bottom: 24, trailing: 24)

    /// Milliseconds across the canvas: room for what is there plus a
    /// little more to grow into.
    private static func span(of pulses: [TimedPulse]) -> Double {
        min(max(600, pulses.duration + 160), WaveformLimits.time + 160)
    }

    var body: some View {
        GeometryReader { proxy in
            let margins = Self.margins
            let plot = CGRect(x: margins.leading, y: margins.top,
                              width: proxy.size.width - margins.leading - margins.trailing,
                              height: proxy.size.height - margins.top - margins.bottom)
            let span = heldSpan ?? Self.span(of: pulses)
            ZStack(alignment: .topLeading) {
                grid(plot: plot, span: span)
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { add(at: $0.location, plot: plot, span: span) })
                ForEach(Array(pulses.enumerated()), id: \.element.id) { index, pulse in
                    pulseView(pulse, number: index + 1, plot: plot, span: span)
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.delete, .deleteForward, .leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            nudge(press.key) ? .handled : .ignored
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: localization.localizer.string("a11y.waveform.timeline")))
    }

    // MARK: Drawing

    private func grid(plot: CGRect, span: Double) -> some View {
        let localizer = localization.localizer
        return Canvas { context, _ in
            let faint = GraphicsContext.Shading.color(.primary.opacity(0.07))
            // Time marks.
            let step: Double = span <= 900 ? 100 : span <= 1800 ? 200 : 500
            var time = 0.0
            while time <= span {
                let x = plot.minX + time / span * plot.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: faint, lineWidth: 1)
                let label = Text(verbatim: localizer.format("format.waveform.duration-ms", arguments: [Int(time)]))
                    .font(.caption2).foregroundStyle(.tertiary)
                context.draw(label, at: CGPoint(x: x, y: plot.maxY + 5), anchor: .top)
                time += step
            }
            // The three strengths a tap can play at, as bands.
            for (level, pattern) in [(0.40, FeedbackPattern.alignment), (0.75, .generic), (1.0, .levelChange)] {
                let y = plot.maxY - level * plot.height
                if level < 1 {
                    var line = Path()
                    line.move(to: CGPoint(x: plot.minX, y: y))
                    line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                }
                let name = Text(verbatim: pattern.localizedName(using: localizer))
                    .font(.caption2).foregroundStyle(.tertiary)
                context.draw(name, at: CGPoint(x: plot.maxX - 2, y: y + 3), anchor: .topTrailing)
            }
            var baseline = Path()
            baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
            baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
            context.stroke(baseline, with: .color(.primary.opacity(0.25)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pulseView(_ pulse: TimedPulse, number: Int, plot: CGRect, span: Double) -> some View {
        let selected = selection == pulse.id
        let x = plot.minX + pulse.time / span * plot.width
        let y = plot.maxY - pulse.level * plot.height
        let tint = Color.accentColor
        if pulse.isTone {
            let width = max(12, pulse.length / span * plot.width)
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(selected ? 0.75 : 0.5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.primary : tint, lineWidth: selected ? 2 : 1))
                .frame(width: width, height: max(plot.maxY - y, 6))
                .contentShape(Rectangle())
                .gesture(move(pulse, plot: plot, span: span, anchor: CGPoint(x: x, y: y)))
                .modifier(PulseAccessibility(pulse: pulse, number: number, select: { select(pulse) }, adjust: adjust))
                .position(x: x + width / 2, y: (plot.maxY + y) / 2)
            // The end of the note: drag it to hold longer or shorter.
            Capsule()
                .fill(selected ? Color.primary : tint)
                .frame(width: 4, height: min(max(plot.maxY - y - 8, 6), 26))
                .padding(.horizontal, 5)
                .contentShape(Rectangle())
                .gesture(stretch(pulse, plot: plot, span: span))
                .position(x: x + width, y: (plot.maxY + y) / 2)
                .accessibilityHidden(true)
        } else {
            Capsule()
                .fill(tint.opacity(selected ? 1 : 0.7))
                .frame(width: 3, height: max(plot.maxY - y, 2))
                .position(x: x, y: (plot.maxY + y) / 2)
                .allowsHitTesting(false)
            Circle()
                .fill(tint)
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: selected ? 2 : 0))
                .frame(width: 16, height: 16)
                .padding(5)
                .contentShape(Rectangle())
                .gesture(move(pulse, plot: plot, span: span, anchor: CGPoint(x: x, y: y)))
                .modifier(PulseAccessibility(pulse: pulse, number: number, select: { select(pulse) }, adjust: adjust))
                .position(x: x, y: y)
        }
    }

    // MARK: Editing

    private func select(_ pulse: TimedPulse) {
        selection = pulse.id
        focused = true
    }

    private func add(at point: CGPoint, plot: CGRect, span: Double) {
        focused = true
        guard pulses.count < WaveformLimits.pulses else { return }
        var pulse = TimedPulse(time: Self.snap((point.x - plot.minX) / plot.width * span))
        pulse.time = min(max(pulse.time, 0), WaveformLimits.time)
        pulse.setLevel((plot.maxY - point.y) / plot.height)
        withAnimation(.snappy(duration: 0.2)) { pulses = (pulses + [pulse]).settled() }
        selection = pulse.id
        onSettle(pulse)
    }

    /// Moves a pulse in time and strength. A press that never travels is
    /// a click, which only selects.
    private func move(_ pulse: TimedPulse, plot: CGRect, span: Double, anchor: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let index = pulses.firstIndex(where: { $0.id == pulse.id }) else { return }
                if grip == nil {
                    heldSpan = span
                    grip = CGSize(width: value.startLocation.x - anchor.x, height: value.startLocation.y - anchor.y)
                    select(pulse)
                }
                guard let grip, hypot(value.translation.width, value.translation.height) > 2 else { return }
                let time = (value.location.x - grip.width - plot.minX) / plot.width * span
                pulses[index].time = min(max(Self.snap(time), 0), WaveformLimits.time)
                pulses[index].setLevel((plot.maxY - (value.location.y - grip.height)) / plot.height)
            }
            .onEnded { value in
                let moved = hypot(value.translation.width, value.translation.height) > 2
                grip = nil
                withAnimation(.snappy(duration: 0.2)) {
                    pulses = pulses.settled()
                    heldSpan = nil
                }
                if moved, let settled = pulses.first(where: { $0.id == pulse.id }) { onSettle(settled) }
            }
    }

    /// Changes how long a note holds by dragging its end.
    private func stretch(_ pulse: TimedPulse, plot: CGRect, span: Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard let index = pulses.firstIndex(where: { $0.id == pulse.id }) else { return }
                if heldSpan == nil {
                    heldSpan = span
                    select(pulse)
                }
                let end = (value.location.x - plot.minX) / plot.width * span
                let length = Self.snap(end - pulses[index].time)
                pulses[index].toneMs = min(max(length, WaveformLimits.noteLength.lowerBound), WaveformLimits.noteLength.upperBound)
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.2)) {
                    pulses = pulses.settled()
                    heldSpan = nil
                }
                if let settled = pulses.first(where: { $0.id == pulse.id }) { onSettle(settled) }
            }
    }

    /// Strength up or down a notch, for VoiceOver's adjust gesture.
    private func adjust(_ pulse: TimedPulse, by amount: Double) {
        guard let index = pulses.firstIndex(where: { $0.id == pulse.id }) else { return }
        pulses[index].setLevel(pulses[index].level + amount)
    }

    /// Arrow keys move the selected pulse, Delete removes it.
    private func nudge(_ key: KeyEquivalent) -> Bool {
        guard let index = pulses.firstIndex(where: { $0.id == selection }) else { return false }
        switch key {
        case .delete, .deleteForward:
            guard pulses.count > 1 else { return false }
            pulses.remove(at: index)
            pulses = pulses.settled()
            selection = pulses[min(index, pulses.count - 1)].id
        case .leftArrow:
            pulses[index].time = max(pulses[index].time - 10, 0)
            pulses = pulses.settled()
        case .rightArrow:
            pulses[index].time = min(pulses[index].time + 10, WaveformLimits.time)
            pulses = pulses.settled()
        case .upArrow:
            pulses[index].setLevel(pulses[index].level + 0.05)
        case .downArrow:
            pulses[index].setLevel(pulses[index].level - 0.05)
        default:
            return false
        }
        return true
    }

    private static func snap(_ milliseconds: Double) -> Double {
        (milliseconds / 5).rounded() * 5
    }
}

/// A pulse as VoiceOver meets it: its number, its strength and time, a
/// press to select it, and the adjust gesture for its strength.
private struct PulseAccessibility: ViewModifier {
    @EnvironmentObject private var localization: LocalizationController
    let pulse: TimedPulse
    let number: Int
    let select: () -> Void
    let adjust: (TimedPulse, Double) -> Void

    func body(content: Content) -> some View {
        let localizer = localization.localizer
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: localizer.format("format.waveform.pulse-number", arguments: [number])))
            .accessibilityValue(Text(verbatim: localizer.format(
                "format.waveform.pulse-value",
                arguments: [Int((pulse.level * 100).rounded()), Int(pulse.time.rounded())]
            )))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { select() }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(pulse, 0.05)
                case .decrement: adjust(pulse, -0.05)
                @unknown default: break
                }
            }
    }
}

// MARK: - Tapping a rhythm

/// Collects a rhythm tapped on the pad and turns it into pulses: when each
/// press began, how hard it got, and how long it was held.
final class TapRecorder: ObservableObject {
    struct Tap {
        /// Seconds from the first press.
        var start: TimeInterval
        var end: TimeInterval?
        /// The hardest the press got before the deep click, 0...1.
        var peak = 0.0
        /// The press went through to the deep click.
        var deep = false
        /// The device reported pressure at all (a mouse does not).
        var hasPressure = false
    }

    @Published private(set) var isArmed = false
    @Published private(set) var taps: [Tap] = []

    /// Called with the finished rhythm a moment after the last tap.
    var onFinish: (([TimedPulse]) -> Void)?

    /// How long after the last release the rhythm counts as finished.
    private static let rest: TimeInterval = 1.1
    /// A press held this long becomes a note rather than a tap.
    private static let hold: TimeInterval = 0.25

    private var origin: TimeInterval?
    private var finishTimer: Timer?

    func arm() {
        finishTimer?.invalidate()
        taps = []
        origin = nil
        isArmed = true
    }

    func cancel() {
        finishTimer?.invalidate()
        isArmed = false
        taps = []
    }

    func down() {
        guard isArmed, taps.count < WaveformLimits.pulses else { return }
        finishTimer?.invalidate()
        let now = CACurrentMediaTime()
        if origin == nil { origin = now }
        taps.append(Tap(start: now - (origin ?? now)))
    }

    func pressure(_ pressure: Double, stage: Int) {
        guard isArmed, var tap = taps.last, tap.end == nil else { return }
        tap.hasPressure = true
        if stage >= 2 {
            tap.deep = true
        } else {
            tap.peak = max(tap.peak, pressure)
        }
        taps[taps.count - 1] = tap
    }

    func up() {
        guard isArmed, var tap = taps.last, tap.end == nil, let origin else { return }
        tap.end = CACurrentMediaTime() - origin
        taps[taps.count - 1] = tap
        let timer = Timer(timeInterval: Self.rest, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        finishTimer = timer
    }

    /// Ends the recording now and hands over what was tapped.
    func finish() {
        guard isArmed else { return }
        finishTimer?.invalidate()
        isArmed = false
        let pulses = Self.pulses(from: taps)
        if !pulses.isEmpty { onFinish?(pulses) }
    }

    private static func pulses(from taps: [Tap]) -> [TimedPulse] {
        taps.map { tap in
            var pulse = TimedPulse(time: (tap.start * 1000).rounded())
            // A light press is a light pulse, the deep click a firm one;
            // a device with no pressure to report gets the middle.
            pulse.setLevel(tap.hasPressure ? (tap.deep ? 0.9 : 0.25 + 0.5 * tap.peak) : 0.6)
            let held = (tap.end ?? tap.start) - tap.start
            if held >= hold {
                pulse.hz = 180
                pulse.toneMs = min(max((held * 1000).rounded(), WaveformLimits.noteLength.lowerBound),
                                   WaveformLimits.noteLength.upperBound)
            }
            return pulse
        }.settled()
    }
}

/// The surface a rhythm is tapped on. AppKit, because only an `NSView`
/// hears how hard a Force Touch press is. The space bar taps too, and
/// VoiceOver's press counts as one quick tap.
struct TapPad: NSViewRepresentable {
    let recorder: TapRecorder
    var label: String

    func makeNSView(context: Context) -> PadView {
        let view = PadView()
        view.recorder = recorder
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ view: PadView, context: Context) {
        view.recorder = recorder
        view.setAccessibilityLabel(label)
    }

    final class PadView: NSView {
        var recorder: TapRecorder?

        override var acceptsFirstResponder: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Ready for the space bar without a click first.
            window?.makeFirstResponder(self)
        }

        override func mouseDown(with event: NSEvent) { recorder?.down() }

        override func mouseUp(with event: NSEvent) { recorder?.up() }

        override func pressureChange(with event: NSEvent) {
            recorder?.pressure(Double(event.pressure), stage: event.stage)
        }

        override func keyDown(with event: NSEvent) {
            guard event.keyCode == 49 else { return super.keyDown(with: event) }
            if !event.isARepeat { recorder?.down() }
        }

        override func keyUp(with event: NSEvent) {
            guard event.keyCode == 49 else { return super.keyUp(with: event) }
            recorder?.up()
        }

        override func accessibilityPerformPress() -> Bool {
            recorder?.down()
            recorder?.up()
            return true
        }
    }
}

//
//  FeedbackController.swift
//  Tactile
//

import AppKit
import os
import QuartzCore

/// Decides what a resolved element should feel like, and plays it.
///
/// Feedback fires once per element *enter* — never continuously — and only
/// when the element's category is enabled, its app isn't excluded, the rate
/// limit allows it, and any dwell delay has elapsed. What plays is a
/// waveform chosen by context: the category's own waveform, the danger
/// waveform for destructive controls, with an extra confirmation pulse for
/// checked/selected state. Leaving a fired element can play an exit
/// waveform, and window-boundary crossings and screen edges have theirs.
@MainActor
final class FeedbackController {
    var config: FeedbackConfig

    /// Feeds the cursor monitor's skip region after each resolution.
    var onSkipRegionUpdate: ((CGRect?) -> Void)?

    /// Tells the visual hover indicator what the cursor is over (and where,
    /// in accessibility coordinates). Only called when the hovered element
    /// actually changes.
    var onHoverState: ((HoverKind, CGRect?) -> Void)?

    private let haptics = SystemHapticEngine()
    private let audio = AudioFeedbackEngine()
    private let player = WaveformPlayer()

    private var lastElement: AXUIElement?
    private var lastWindow: AXUIElement?
    /// Set when the current element fired, so hover-out knows to play.
    private var firedForCurrentElement = false
    /// Frame and app of the control that last fired, kept while the cursor
    /// stays inside it. Web apps re-render controls on hover (ripple and
    /// shadow wrappers), minting new accessibility nodes for the same visual
    /// control — so element identity churns under a resting cursor. Anything
    /// resolved inside this region that nests with it is still the same
    /// control: no re-fire, no hover-out.
    private var activeFireRegion: (frame: CGRect, pid: pid_t)?
    private var lastTickTime: CFTimeInterval = 0
    private var dwellTimer: Timer?
    private var vibrateTimer: Timer?
    private var vibrateStep = 0
    /// True while the actuator's continuous buzz thread is running.
    private var buzzing = false

    /// Enhanced haptics when enabled and supported, public engine otherwise.
    private var hapticEngine: FeedbackEngine {
        if config.useEnhancedHaptics, let actuator = ActuatorHapticEngine.shared {
            return actuator
        }
        return haptics
    }

    private let log = Logger(subsystem: "com.masonchen.Tactile", category: "feedback")

    init(config: FeedbackConfig) {
        self.config = config
    }

    func handle(point: CGPoint, resolved: ResolvedElement?) {
        if let region = activeFireRegion, !region.frame.insetBy(dx: -2, dy: -2).contains(point) {
            activeFireRegion = nil
        }

        guard let resolved else {
            // A transient hit-test failure while still inside the fired
            // control (common while web apps re-render on hover) is not an
            // exit — keep the current feel.
            if activeFireRegion != nil { return }
            onSkipRegionUpdate?(Self.jitterBox(around: point))
            onHoverState?(.none, nil)
            leaveCurrentElement(enteringFiringElement: false)
            lastElement = nil
            return
        }

        handleWindowBoundary(resolved)

        let rawCategory = ClickabilityClassifier.classify(
            role: resolved.role,
            subrole: resolved.subrole,
            actions: resolved.actions
        )

        log.debug("hit role=\(resolved.role, privacy: .public) subrole=\(resolved.subrole ?? "-", privacy: .public) category=\(rawCategory?.rawValue ?? "none", privacy: .public) app=\(resolved.bundleID ?? "?", privacy: .public)")

        // Reject "clickable" elements that are clearly containers: Electron
        // and web apps mark window-sized groups as pressable, and treating
        // one as a control both fires a bogus tick and — worse — caches a
        // window-sized skip region that silences the whole app until the
        // cursor leaves it.
        let controlSized = resolved.frame.map(Self.isControlSized) ?? false
        let category = controlSized ? rawCategory : nil

        // Clickable leaf elements can cache their whole frame — the cursor
        // can't reveal anything deeper inside them. Anything else (groups,
        // windows, text) only gets a small box around the cursor: containers
        // report frames that span their children, and caching those would
        // blind the pipeline to controls inside them.
        if category != nil, let frame = resolved.frame, !frame.isEmpty {
            onSkipRegionUpdate?(frame)
        } else {
            onSkipRegionUpdate?(Self.jitterBox(around: point))
        }

        // Same element as last time — nothing to do. This is what makes
        // feedback fire on enter (and exit) only.
        if let lastElement, CFEqual(lastElement, resolved.element) { return }

        // Still inside the frame that fired, and the new element nests with
        // it (its own label, an inert overlay, a re-rendered wrapper, or a
        // container spanning it): same logical control, stay quiet.
        if let region = activeFireRegion, resolved.pid == region.pid {
            let grown = region.frame.insetBy(dx: -2, dy: -2)
            let nests = resolved.frame.map { frame in
                grown.contains(frame) || frame.insetBy(dx: -2, dy: -2).contains(region.frame)
            } ?? true
            if nests {
                lastElement = resolved.element
                return
            }
        }

        emitHoverState(category: category, resolved: resolved)

        let firesOnEnter = category.map { willFire($0, resolved: resolved) } ?? false
        leaveCurrentElement(enteringFiringElement: firesOnEnter)
        lastElement = resolved.element

        guard let category, !isExcluded(resolved.bundleID) else { return }

        // Disabled controls: optional single light pulse instead of silence,
        // so you can feel that something is there but inactive.
        if !resolved.enabled {
            if config.feelDisabled, config.enabledCategories.contains(category), passesFocusFilter(category, resolved) {
                play(.single(.alignment), reason: "disabled")
            }
            return
        }

        guard firesOnEnter else { return }

        let waveform = styledWaveform(for: category, resolved: resolved)
        let firedRegion = resolved.frame.map { (frame: $0, pid: resolved.pid) }
        if config.dwellDelay > 0 {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: config.dwellDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.play(waveform)
                    self.firedForCurrentElement = true
                    self.activeFireRegion = firedRegion
                    self.startVibrationIfEnabled()
                }
            }
        } else {
            play(waveform)
            firedForCurrentElement = true
            activeFireRegion = firedRegion
            startVibrationIfEnabled()
        }
    }

    // MARK: - Browser bridge

    /// Feedback driven by the Chrome extension instead of the accessibility
    /// tree. The extension reports the real DOM, so it reaches `<div>` controls
    /// AX never sees, and it already emits one event per element enter — so
    /// this reuses the same waveform selection, playback, vibration, and
    /// hover-out as the AX path, just fed from semantics rather than an
    /// `AXUIElement`. AppController suppresses the AX path while this is hot, so
    /// the two never both fire.
    func handleBridge(_ message: BridgeMessage) {
        guard message.type == "hover",
              let raw = message.el,
              let category = FeedbackCategory(rawValue: raw)
        else {
            // "leave" (or a malformed hover): end the current element, playing
            // the hover-out waveform if one fired.
            onHoverState?(.none, nil)
            leaveCurrentElement(enteringFiringElement: false)
            lastElement = nil
            return
        }

        let enabled = message.enabled ?? true
        let passes = config.enabledCategories.contains(category)
            && bridgeFocusOK(category)
            && bridgeSimpleOK(message)
        leaveCurrentElement(enteringFiringElement: enabled && passes)
        lastElement = nil

        // The extension doesn't report frames, so the element outline can't
        // follow it — but the cursor circle's color still can.
        if passes {
            let kind: HoverKind = !enabled ? .disabled : ((message.danger ?? false) ? .danger : .clickable)
            onHoverState?(kind, nil)
        } else {
            onHoverState?(.none, nil)
        }

        guard passes else { return }

        if !enabled {
            if config.feelDisabled { play(.single(.alignment), reason: "disabled") }
            return
        }

        let waveform = bridgeWaveform(category: category, isOn: message.on, isDanger: message.danger ?? false)
        if config.dwellDelay > 0 {
            dwellTimer = Timer.scheduledTimer(withTimeInterval: config.dwellDelay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.play(waveform)
                    self.firedForCurrentElement = true
                    self.startVibrationIfEnabled()
                }
            }
        } else {
            play(waveform, reason: "bridge")
            firedForCurrentElement = true
            startVibrationIfEnabled()
        }
    }

    /// Danger and checked-state styling for a bridge element, mirroring
    /// `styledWaveform` but from the extension's precomputed flags.
    private func bridgeWaveform(category: FeedbackCategory, isOn: Bool?, isDanger: Bool) -> HapticWaveform {
        if config.dangerEnabled, isDanger { return config.dangerWaveform }
        var waveform = config.waveforms[category] ?? .single(category.defaultPattern)
        if config.stateAware, isOn == true, var last = waveform.steps.last {
            last.gapMs = max(last.gapMs, 110)
            waveform.steps[waveform.steps.count - 1] = last
            waveform.steps.append(WaveformStep(strength: .alignment, gapMs: 0))
        }
        return waveform
    }

    /// The focused-window quiet mode, applied to web content: the page is the
    /// frontmost window's content, so only the button restriction is meaningful.
    private func bridgeFocusOK(_ category: FeedbackCategory) -> Bool {
        guard config.focusedWindowButtonsOnly else { return true }
        return category == .button
    }

    /// Simple mode for web content: the extension decides which targets are
    /// primary (result-title links, prominent labeled controls) from the real
    /// DOM, so here we just honor its flag.
    private func bridgeSimpleOK(_ message: BridgeMessage) -> Bool {
        guard config.simpleMode else { return true }
        return message.primary ?? false
    }

    /// Called by the pipeline when the cursor touches an outer screen edge.
    func screenEdgeBump() {
        guard config.screenEdgesEnabled else { return }
        play(config.edgeWaveform, reason: "edge")
    }

    /// Forgets the current element so re-entering it ticks again.
    func reset() {
        lastElement = nil
        lastWindow = nil
        firedForCurrentElement = false
        activeFireRegion = nil
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopVibration()
        player.cancel()
    }

    // MARK: - Waveform selection

    /// Danger context overrides the category waveform; checked/selected
    /// state appends a confirmation pulse.
    private func styledWaveform(for category: FeedbackCategory, resolved: ResolvedElement) -> HapticWaveform {
        if config.dangerEnabled, ContextDetector.isDanger(title: resolved.title, subrole: resolved.subrole) {
            return config.dangerWaveform
        }

        var waveform = config.waveforms[category] ?? .single(category.defaultPattern)
        if config.stateAware, resolved.isOn == true, var last = waveform.steps.last {
            last.gapMs = max(last.gapMs, 110)
            waveform.steps[waveform.steps.count - 1] = last
            waveform.steps.append(WaveformStep(strength: .alignment, gapMs: 0))
        }
        return waveform
    }

    /// Reduces a resolution to what the visual indicator shows: nothing,
    /// clickable, destructive, or disabled.
    private func emitHoverState(category: FeedbackCategory?, resolved: ResolvedElement) {
        guard let onHoverState else { return }
        guard let category, config.enabledCategories.contains(category), passesSimpleMode(category, resolved) else {
            onHoverState(.none, nil)
            return
        }
        let kind: HoverKind
        if !resolved.enabled {
            kind = .disabled
        } else if ContextDetector.isDanger(title: resolved.title, subrole: resolved.subrole) {
            kind = .danger
        } else {
            kind = .clickable
        }
        onHoverState(kind, resolved.frame)
    }

    private func willFire(_ category: FeedbackCategory, resolved: ResolvedElement) -> Bool {
        resolved.enabled
            && config.enabledCategories.contains(category)
            && !isExcluded(resolved.bundleID)
            && passesFocusFilter(category, resolved)
            && passesSimpleMode(category, resolved)
    }

    /// Quiet mode: when on, only buttons in the focused window get through.
    private func passesFocusFilter(_ category: FeedbackCategory, _ resolved: ResolvedElement) -> Bool {
        guard config.focusedWindowButtonsOnly else { return true }
        return category == .button && resolved.isInFocusedWindow
    }

    /// Simple mode: cut the noise to the primary targets. Fire only for
    /// well-labeled, reasonably sized links, buttons, tabs, toggles, and menu
    /// items — dropping icon-only controls (three-dot menus, favicons),
    /// sliders, text fields, and the ambiguous generic-pressable bucket. The
    /// browser extension makes a sharper call for web pages (see handleBridge);
    /// this is the best the accessibility tree alone allows.
    private func passesSimpleMode(_ category: FeedbackCategory, _ resolved: ResolvedElement) -> Bool {
        guard config.simpleMode else { return true }
        switch category {
        case .slider, .textField, .genericPressable:
            return false
        case .link, .button, .tab, .toggle, .menuItem:
            break
        }
        // Must carry a real text label — this is what drops icon-only controls.
        let label = (resolved.title ?? "").unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        guard label >= 2 else { return false }
        // And not be a tiny control.
        if let f = resolved.frame, min(f.width, f.height) < 14 { return false }
        return true
    }

    private func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return config.excludedBundleIDs.contains(bundleID)
    }

    // MARK: - Transitions

    /// Ends the current element, playing the hover-out waveform when
    /// configured. Skipped when the cursor lands directly on another firing
    /// element — one transition, one feel.
    private func leaveCurrentElement(enteringFiringElement: Bool) {
        dwellTimer?.invalidate()
        dwellTimer = nil
        stopVibration()
        if config.hapticOnExit, !enteringFiringElement, firedForCurrentElement {
            play(config.exitWaveform, reason: "exit")
        }
        firedForCurrentElement = false
    }

    /// A window change under the cursor is a spatial boundary worth feeling.
    private func handleWindowBoundary(_ resolved: ResolvedElement) {
        guard config.windowBoundsEnabled else { return }
        defer { if resolved.window != nil { lastWindow = resolved.window } }
        guard let window = resolved.window, let lastWindow, !CFEqual(lastWindow, window) else { return }
        play(config.boundaryWaveform, reason: "boundary")
    }

    // MARK: - Playback

    private func play(_ waveform: HapticWaveform, reason: StaticString = "enter") {
        let now = CACurrentMediaTime()
        guard config.rateLimitInterval == 0 || now - lastTickTime >= config.rateLimitInterval else { return }
        lastTickTime = now
        log.debug("fire reason=\(reason, privacy: .public) steps=\(waveform.steps.count, privacy: .public)")

        player.play(waveform, on: hapticEngine)
        if config.audioEnabled {
            audio.volume = config.audioVolume
            audio.soundName = config.audioSoundName
            audio.tick(waveform.steps.first?.strength ?? .generic)
        }
    }

    // MARK: - Hover vibration

    /// A stream of rapid pulses reads as a continuous buzz. Pulses go
    /// straight to the actuator with their own strength setting — the rate
    /// limit governs discrete events, and the click sound stays out of it
    /// entirely. The vibration mode shapes the gaps between pulses.
    private func startVibrationIfEnabled() {
        guard config.vibrateOnHover else { return }
        stopVibration()
        // With the actuator available, the buzz runs on its own thread — the
        // only way to hold pulse rates high enough (up to 250/sec) to feel
        // like one continuous vibration instead of a series of taps.
        if config.useEnhancedHaptics, let actuator = ActuatorHapticEngine.shared {
            let gaps = config.vibrationMode.gaps(base: max(config.vibrateInterval, 0.004))
            actuator.startBuzz(config.vibratePattern, gaps: gaps)
            buzzing = true
            return
        }
        scheduleNextVibratePulse()
    }

    private func scheduleNextVibratePulse() {
        let gaps = config.vibrationMode.gaps(base: max(config.vibrateInterval, 0.03))
        let gap = gaps[vibrateStep % gaps.count]
        vibrateStep += 1

        let timer = Timer(timeInterval: gap, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.vibrateTimer != nil else { return }
                self.hapticEngine.tick(self.config.vibratePattern)
                self.scheduleNextVibratePulse()
            }
        }
        // .common keeps the buzz alive during menu and drag tracking.
        RunLoop.main.add(timer, forMode: .common)
        vibrateTimer = timer
    }

    private func stopVibration() {
        if buzzing {
            ActuatorHapticEngine.shared?.stopBuzz()
            buzzing = false
        }
        vibrateTimer?.invalidate()
        vibrateTimer = nil
        vibrateStep = 0
    }

    /// Minimal hysteresis for positions that didn't resolve to a clickable
    /// element — absorbs jitter without hiding nearby controls.
    private static func jitterBox(around point: CGPoint) -> CGRect {
        CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
    }

    /// Plausible bounds for an individual control. Generous enough for wide
    /// menu items, banner links, and big tiles, but rejects the window-sized
    /// "pressable" containers Electron apps report.
    private static func isControlSized(_ frame: CGRect) -> Bool {
        frame.width <= 900 && frame.height <= 350 && frame.width * frame.height <= 160_000
    }
}

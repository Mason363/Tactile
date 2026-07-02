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

    private let haptics = SystemHapticEngine()
    private let audio = AudioFeedbackEngine()
    private let player = WaveformPlayer()

    private var lastElement: AXUIElement?
    private var lastWindow: AXUIElement?
    /// Set when the current element fired, so hover-out knows to play.
    private var firedForCurrentElement = false
    private var lastTickTime: CFTimeInterval = 0
    private var dwellTimer: Timer?
    private var vibrateTimer: Timer?
    private var vibrateStep = 0

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
        guard let resolved else {
            onSkipRegionUpdate?(Self.jitterBox(around: point))
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

        let firesOnEnter = category.map { willFire($0, resolved: resolved) } ?? false
        leaveCurrentElement(enteringFiringElement: firesOnEnter)
        lastElement = resolved.element

        guard let category, !isExcluded(resolved.bundleID) else { return }

        // Disabled controls: optional single light pulse instead of silence,
        // so you can feel that something is there but inactive.
        if !resolved.enabled {
            if config.feelDisabled, config.enabledCategories.contains(category), passesFocusFilter(category, resolved) {
                play(.single(.alignment))
            }
            return
        }

        guard firesOnEnter else { return }

        let waveform = styledWaveform(for: category, resolved: resolved)
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
            play(waveform)
            firedForCurrentElement = true
            startVibrationIfEnabled()
        }
    }

    /// Called by the pipeline when the cursor touches an outer screen edge.
    func screenEdgeBump() {
        guard config.screenEdgesEnabled else { return }
        play(config.edgeWaveform)
    }

    /// Forgets the current element so re-entering it ticks again.
    func reset() {
        lastElement = nil
        lastWindow = nil
        firedForCurrentElement = false
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

    private func willFire(_ category: FeedbackCategory, resolved: ResolvedElement) -> Bool {
        resolved.enabled
            && config.enabledCategories.contains(category)
            && !isExcluded(resolved.bundleID)
            && passesFocusFilter(category, resolved)
    }

    /// Quiet mode: when on, only buttons in the focused window get through.
    private func passesFocusFilter(_ category: FeedbackCategory, _ resolved: ResolvedElement) -> Bool {
        guard config.focusedWindowButtonsOnly else { return true }
        return category == .button && resolved.isInFocusedWindow
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
            play(config.exitWaveform)
        }
        firedForCurrentElement = false
    }

    /// A window change under the cursor is a spatial boundary worth feeling.
    private func handleWindowBoundary(_ resolved: ResolvedElement) {
        guard config.windowBoundsEnabled else { return }
        defer { if resolved.window != nil { lastWindow = resolved.window } }
        guard let window = resolved.window, let lastWindow, !CFEqual(lastWindow, window) else { return }
        play(config.boundaryWaveform)
    }

    // MARK: - Playback

    private func play(_ waveform: HapticWaveform) {
        let now = CACurrentMediaTime()
        guard config.rateLimitInterval == 0 || now - lastTickTime >= config.rateLimitInterval else { return }
        lastTickTime = now

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
